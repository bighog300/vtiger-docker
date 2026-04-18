#!/usr/bin/env bash
# build.sh
#
# Full vtiger 8.3.0 Docker build pipeline.
#
# What this does:
#   1. Brings up MySQL + vtiger installer via docker-compose.build.yml
#   2. Installer POSTs through the vtiger web wizard → schema created in MySQL
#   3. export-schema.sh dumps the DB → schema.sql in this directory
#   4. Brings down the build stack
#   5. Builds the final runtime image (schema.sql baked in)
#   6. Tags and pushes to ghcr.io/bighog300/vtigercrm
#
# Usage:
#   ./build.sh              # builds and pushes :latest and :8.3.0
#   ./build.sh --no-push    # builds only, skips push
#
set -euo pipefail

IMAGE="ghcr.io/bighog300/vtigercrm"
VERSION="8.3.0"
NO_PUSH=false

for arg in "$@"; do
  [ "$arg" = "--no-push" ] && NO_PUSH=true
done

log() { echo "[vtiger-build] $*"; }

# ---------------------------------------------------------------------------
# Step 1: Run installer against a temporary MySQL
# ---------------------------------------------------------------------------
log "Starting build stack (MySQL + installer)..."
docker compose -f docker-compose.build.yml up --build --abort-on-container-exit installer

# Check installer exited cleanly
INSTALLER_EXIT=$(docker inspect vtiger-build-installer --format='{{.State.ExitCode}}' 2>/dev/null || echo "1")
if [ "$INSTALLER_EXIT" != "0" ]; then
  log "ERROR: Installer exited with code ${INSTALLER_EXIT}."
  log "Logs:"
  docker logs vtiger-build-installer 2>&1 | tail -50
  docker compose -f docker-compose.build.yml down -v
  exit 1
fi
log "Installer completed successfully."

# ---------------------------------------------------------------------------
# Step 2: Export schema from the build MySQL
# ---------------------------------------------------------------------------
log "Exporting schema from build MySQL..."
docker exec vtiger-build-mysql mysqldump \
  -uroot -pbuildroot \
  --no-tablespaces \
  --single-transaction \
  --routines \
  --triggers \
  vtiger > schema.sql

SCHEMA_LINES=$(wc -l < schema.sql)
log "Schema exported: ${SCHEMA_LINES} lines → schema.sql"

if [ "$SCHEMA_LINES" -lt 100 ]; then
  log "ERROR: schema.sql looks too small — dump may have failed."
  docker compose -f docker-compose.build.yml down -v
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 3: Tear down build stack
# ---------------------------------------------------------------------------
log "Tearing down build stack..."
docker compose -f docker-compose.build.yml down -v

# ---------------------------------------------------------------------------
# Step 4: Build final runtime image (schema.sql is now present)
# ---------------------------------------------------------------------------
log "Building final runtime image ${IMAGE}:${VERSION}..."
docker build \
  --target runtime \
  -t "${IMAGE}:${VERSION}" \
  -t "${IMAGE}:latest" \
  .

log "Build complete: ${IMAGE}:${VERSION}"

# ---------------------------------------------------------------------------
# Step 5: Push to ghcr.io
# ---------------------------------------------------------------------------
if [ "$NO_PUSH" = true ]; then
  log "Skipping push (--no-push specified)."
  log "To push manually: docker push ${IMAGE}:${VERSION} && docker push ${IMAGE}:latest"
  exit 0
fi

log "Pushing to ghcr.io..."
log "Ensure you are logged in: echo \$GITHUB_TOKEN | docker login ghcr.io -u bighog300 --password-stdin"
docker push "${IMAGE}:${VERSION}"
docker push "${IMAGE}:latest"

log "Done. Image available at ${IMAGE}:${VERSION}"
