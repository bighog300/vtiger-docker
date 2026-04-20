#!/usr/bin/env bash
set -euo pipefail
log() { echo "[vtiger-export] $*"; }
OUTPUT="${1:-/output/schema.sql}"
log "Dumping ${DB_NAME} to ${OUTPUT}..."
mysqldump -h"${DB_HOST}" -P"${DB_PORT}" -uroot -p"${DB_ROOT_PASSWORD}" \
  --no-tablespaces --single-transaction --routines --triggers "${DB_NAME}" > "${OUTPUT}"
log "Done: $(wc -l < "${OUTPUT}") lines written."
