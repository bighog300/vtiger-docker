#!/usr/bin/env bash
# build.sh — full vtiger 8.3.0 Docker build pipeline
set -euo pipefail

IMAGE="${IMAGE:-ghcr.io/${GITHUB_REPOSITORY_OWNER:-bighog300}/vtigercrm}"
VERSION="${VERSION:-8.3.0}"
NO_PUSH=false
for arg in "$@"; do [ "$arg" = "--no-push" ] && NO_PUSH=true; done
log() { echo "[vtiger-build] $*"; }

# Step 1: Start MySQL
log "Starting MySQL..."
docker compose -f docker-compose.build.yml up -d mysql

log "Waiting for MySQL to be healthy..."
for i in $(seq 1 60); do
  docker inspect vtiger-build-mysql --format='{{.State.Health.Status}}' 2>/dev/null | grep -q healthy && { log "MySQL healthy."; break; }
  [ "$i" = "60" ] && { log "ERROR: MySQL never became healthy."; exit 1; }
  sleep 3
done

# Step 2: Build installer image
log "Building installer image..."
docker compose -f docker-compose.build.yml build installer

# Step 3: Run installer
log "Running installer (this may take several minutes)..."
if ! docker compose -f docker-compose.build.yml up --no-deps --exit-code-from installer installer; then
  log "ERROR: Installer failed."
  docker logs vtiger-build-installer 2>&1 | tail -60
  docker compose -f docker-compose.build.yml down -v
  exit 1
fi
log "Installer completed successfully."

# Step 4: Export schema while MySQL is still running
log "Exporting schema.sql..."
docker exec vtiger-build-mysql mysqldump \
  -uroot -pbuildroot \
  --no-tablespaces --single-transaction --routines --triggers \
  vtiger > schema.sql
LINES=$(wc -l < schema.sql)
log "Schema exported: ${LINES} lines."
if [ "${LINES}" -lt 100 ]; then
  log "ERROR: schema.sql too small (${LINES} lines) — dump may have failed."
  docker compose -f docker-compose.build.yml down -v
  exit 1
fi

# Step 5: Tear down build stack
log "Tearing down build stack..."
docker compose -f docker-compose.build.yml down -v

# Step 6: Build final runtime image with schema.sql baked in
log "Building runtime image ${IMAGE}:${VERSION}..."
docker build --target runtime \
  -t "${IMAGE}:${VERSION}" \
  -t "${IMAGE}:latest" \
  .
log "Build complete: ${IMAGE}:${VERSION}"

if [ "${NO_PUSH}" = true ]; then
  log "Skipping push (--no-push)."
  log "To push: docker push ${IMAGE}:${VERSION} && docker push ${IMAGE}:latest"
  exit 0
fi

# Step 7: Push
log "Pushing ${IMAGE}:${VERSION} and ${IMAGE}:latest..."
docker push "${IMAGE}:${VERSION}"
docker push "${IMAGE}:latest"
log "Done. Published: ${IMAGE}:${VERSION}"
