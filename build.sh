#!/usr/bin/env bash
# build.sh — full vtiger 8.3.0 Docker build pipeline
set -euo pipefail

IMAGE="ghcr.io/bighog300/vtigercrm"
VERSION="8.3.0"
NO_PUSH=false
for arg in "$@"; do [ "$arg" = "--no-push" ] && NO_PUSH=true; done
log() { echo "[vtiger-build] $*"; }

# Step 1: Start MySQL and run installer (don't abort-on-exit so MySQL stays up for dump)
log "Starting MySQL..."
docker compose -f docker-compose.build.yml up -d mysql
log "Waiting for MySQL to be healthy..."
for i in $(seq 1 60); do
  docker inspect vtiger-build-mysql --format='{{.State.Health.Status}}' 2>/dev/null | grep -q healthy && { log "MySQL healthy."; break; }
  [ "$i" = "60" ] && { log "ERROR: MySQL never became healthy."; exit 1; }
  sleep 3
done

log "Building and running installer..."
docker compose -f docker-compose.build.yml up --build installer
INSTALLER_EXIT=$(docker inspect vtiger-build-installer --format='{{.State.ExitCode}}' 2>/dev/null || echo 1)
if [ "${INSTALLER_EXIT}" != "0" ]; then
  log "ERROR: Installer exited with code ${INSTALLER_EXIT}."
  docker logs vtiger-build-installer 2>&1 | tail -60
  docker compose -f docker-compose.build.yml down -v
  exit 1
fi
log "Installer completed successfully."

# Step 2: Export schema while MySQL is still running
log "Exporting schema..."
docker exec vtiger-build-mysql mysqldump \
  -uroot -pbuildroot \
  --no-tablespaces --single-transaction --routines --triggers \
  vtiger > schema.sql
LINES=$(wc -l < schema.sql)
log "Schema exported: ${LINES} lines."
if [ "${LINES}" -lt 100 ]; then
  log "ERROR: schema.sql too small — dump failed."
  docker compose -f docker-compose.build.yml down -v
  exit 1
fi

# Step 3: Tear down build stack
log "Tearing down build stack..."
docker compose -f docker-compose.build.yml down -v

# Step 4: Build final runtime image with schema.sql baked in
log "Building runtime image ${IMAGE}:${VERSION}..."
docker build --target runtime -t "${IMAGE}:${VERSION}" -t "${IMAGE}:latest" .
log "Build complete."

# Step 5: Push
if [ "${NO_PUSH}" = true ]; then
  log "Skipping push (--no-push). To push: docker push ${IMAGE}:${VERSION}"
  exit 0
fi
log "Pushing to ghcr.io..."
docker push "${IMAGE}:${VERSION}"
docker push "${IMAGE}:latest"
log "Done. Image: ${IMAGE}:${VERSION}"
