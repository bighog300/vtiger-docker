#!/usr/bin/env bash
set -euo pipefail

log() { echo "[vtiger-ui-install] $*"; }
err() { echo "[vtiger-ui-install] ERROR: $*" >&2; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

VTIGER_REPO_URL="${VTIGER_REPO_URL:-https://github.com/bighog300/vtigercrm.git}"
VTIGER_REPO_REF="${VTIGER_REPO_REF:-}"
IMAGE_NAME="${IMAGE_NAME:-vtiger-ui-installer}"
WEB_CONTAINER_NAME="${WEB_CONTAINER_NAME:-vtiger-ui}"
MYSQL_SERVICE_NAME="${MYSQL_SERVICE_NAME:-mysql}"
APP_PORT="${APP_PORT:-8080}"
DB_HOST="${DB_HOST:-mysql}"
DB_PORT="${DB_PORT:-3306}"
DB_NAME="${DB_NAME:-${DB_DATABASE:-vtiger}}"
DB_USER="${DB_USER:-vtiger}"
DB_PASSWORD="${DB_PASSWORD:-vtigerpass}"

usage() {
  cat <<EOF
Usage: ./install-ui.sh [--build-only] [--restart] [--help]

Builds the browser-installable vtiger image from:
  ${VTIGER_REPO_URL}

Environment overrides:
  VTIGER_REPO_URL   Git repo to clone inside Docker build
  VTIGER_REPO_REF   Optional branch/tag/commit-ish for git clone --branch
  IMAGE_NAME        Docker image tag to build (default: vtiger-ui-installer)
  WEB_CONTAINER_NAME  Running web container name (default: vtiger-ui)
  MYSQL_SERVICE_NAME  Compose service to start for MySQL (default: mysql)
  APP_PORT          Host port for Apache (default: 8080)
  DB_HOST           Hostname the web container uses for MySQL (default: mysql)
  DB_PORT           MySQL port (default: 3306)
  DB_NAME           Database name (default: vtiger)
  DB_USER           Database user (default: vtiger)
  DB_PASSWORD       Database password (default: vtigerpass)

Examples:
  ./install-ui.sh
  VTIGER_REPO_REF=main ./install-ui.sh
  APP_PORT=8081 ./install-ui.sh
EOF
}

BUILD_ONLY=false
RESTART=false
for arg in "$@"; do
  case "$arg" in
    --build-only) BUILD_ONLY=true ;;
    --restart) RESTART=true ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown argument: $arg"; usage; exit 1 ;;
  esac
done

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "Missing required command: $1"; exit 1; }
}

require_cmd docker

if ! docker compose version >/dev/null 2>&1; then
  err "docker compose plugin is required."
  exit 1
fi

log "Starting MySQL service '${MYSQL_SERVICE_NAME}'..."
docker compose up -d "$MYSQL_SERVICE_NAME"

log "Resolving compose network..."
NETWORK_NAME="$(docker compose ps -q "$MYSQL_SERVICE_NAME" | xargs -r docker inspect --format '{{range $k,$v := .NetworkSettings.Networks}}{{println $k}}{{end}}' | head -n1)"
if [ -z "$NETWORK_NAME" ]; then
  err "Could not resolve Docker network for compose service '${MYSQL_SERVICE_NAME}'."
  exit 1
fi
log "Using network: ${NETWORK_NAME}"

log "Waiting for MySQL to report healthy..."
MYSQL_CONTAINER_ID="$(docker compose ps -q "$MYSQL_SERVICE_NAME")"
if [ -z "$MYSQL_CONTAINER_ID" ]; then
  err "MySQL container is not running."
  exit 1
fi
for i in $(seq 1 60); do
  STATUS="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$MYSQL_CONTAINER_ID" 2>/dev/null || true)"
  if [ "$STATUS" = "healthy" ] || [ "$STATUS" = "running" ]; then
    log "MySQL is ready enough (status: ${STATUS})."
    break
  fi
  if [ "$i" -eq 60 ]; then
    err "MySQL did not become ready in time (last status: ${STATUS})."
    exit 1
  fi
  sleep 2
done

BUILD_ARGS=(--target builder -t "$IMAGE_NAME" --build-arg "VTIGER_REPO_URL=$VTIGER_REPO_URL")
if [ -n "$VTIGER_REPO_REF" ]; then
  BUILD_ARGS+=(--build-arg "VTIGER_REPO_REF=$VTIGER_REPO_REF")
fi

log "Building image '$IMAGE_NAME' from '${VTIGER_REPO_URL}'..."
docker build "${BUILD_ARGS[@]}" .

if [ "$BUILD_ONLY" = true ]; then
  log "Build complete. Skipping container start because --build-only was set."
  exit 0
fi

if docker ps -a --format '{{.Names}}' | grep -Fxq "$WEB_CONTAINER_NAME"; then
  if [ "$RESTART" = true ]; then
    log "Removing existing container '${WEB_CONTAINER_NAME}'..."
    docker rm -f "$WEB_CONTAINER_NAME" >/dev/null
  else
    err "Container '${WEB_CONTAINER_NAME}' already exists. Re-run with --restart or remove it first."
    exit 1
  fi
fi

log "Starting vtiger web container '${WEB_CONTAINER_NAME}' on http://localhost:${APP_PORT} ..."
docker run --rm -d   --name "$WEB_CONTAINER_NAME"   --network "$NETWORK_NAME"   -p "${APP_PORT}:80"   -e DB_HOST="$DB_HOST"   -e DB_PORT="$DB_PORT"   -e DB_NAME="$DB_NAME"   -e DB_USER="$DB_USER"   -e DB_PASSWORD="$DB_PASSWORD"   "$IMAGE_NAME"   bash -lc '''
    apt-get update &&
    apt-get install -y --no-install-recommends rsync &&
    rsync -a /app/ /var/www/html/ &&
    rm -f /var/www/html/config.inc.php &&
    mkdir -p /var/www/html/cache /var/www/html/logs /var/www/html/storage /var/www/html/user_privileges /var/www/html/test &&
    chown -R www-data:www-data /var/www/html &&
    find /var/www/html -type d -exec chmod 755 {} \; &&
    find /var/www/html -type f -exec chmod 644 {} \; &&
    chmod -R ug+rwX /var/www/html/cache /var/www/html/logs /var/www/html/storage /var/www/html/user_privileges /var/www/html/test &&
    a2enmod rewrite >/dev/null 2>&1 || true &&
    echo "ServerName localhost" >/etc/apache2/conf-available/servername.conf &&
    a2enconf servername >/dev/null 2>&1 || true &&
    apache2-foreground
  '''

cat <<EOF

vtiger web container is up.

Open the installer in your browser:
  http://localhost:${APP_PORT}/index.php?module=Install&view=Index

Database settings for the installer:
  Host: ${DB_HOST}
  Port: ${DB_PORT}
  Database: ${DB_NAME}
  User: ${DB_USER}
  Password: ${DB_PASSWORD}

Useful commands:
  docker logs -f ${WEB_CONTAINER_NAME}
  docker compose logs -f ${MYSQL_SERVICE_NAME}
  docker rm -f ${WEB_CONTAINER_NAME}
  docker compose down
EOF
