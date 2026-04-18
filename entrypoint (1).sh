#!/usr/bin/env bash
set -euo pipefail
DB_HOST="${DB_HOST:-mysql}"; DB_PORT="${DB_PORT:-3306}"; DB_NAME="${DB_NAME:-vtiger}"
DB_USER="${DB_USER:-vtiger}"; DB_PASSWORD="${DB_PASSWORD:-vtigerpass}"
APP_ROOT="/var/www/html"; SCHEMA_FILE="/opt/vtiger/schema.sql"
log() { echo "[vtiger-entrypoint] $*"; }

log "Rendering config.inc.php..."
envsubst < /opt/vtiger/config.inc.php.tpl > "${APP_ROOT}/config.inc.php"
chown www-data:www-data "${APP_ROOT}/config.inc.php"

log "Waiting for MySQL..."
for i in $(seq 1 60); do
  mysqladmin ping -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" -p"${DB_PASSWORD}" --silent 2>/dev/null && break
  [ "$i" = "60" ] && { log "ERROR: MySQL not ready."; exit 1; }
  sleep 2
done
log "MySQL ready."

TC=$(mysql -N -s -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" -p"${DB_PASSWORD}" \
  -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}'
      AND table_name IN ('vtiger_users','vtiger_tab','vtiger_version');" 2>/dev/null || echo 0)

if [ "${TC}" -lt 2 ]; then
  log "Importing schema (~5 seconds)..."
  mysql -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" -p"${DB_PASSWORD}" "${DB_NAME}" < "${SCHEMA_FILE}"
  log "Schema imported."
else
  log "Schema already present (${TC} tables). Skipping import."
fi

chown -R www-data:www-data \
  "${APP_ROOT}/storage" "${APP_ROOT}/logs" "${APP_ROOT}/cache" \
  "${APP_ROOT}/user_privileges" 2>/dev/null || true

log "Starting Apache..."
exec apache2-foreground
