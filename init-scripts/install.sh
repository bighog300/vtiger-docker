#!/usr/bin/env bash
set -euo pipefail
DB_HOST="${DB_HOST:-mysql}"; DB_PORT="${DB_PORT:-3306}"; DB_NAME="${DB_NAME:-vtiger}"
DB_USER="${DB_USER:-vtiger}"; DB_PASSWORD="${DB_PASSWORD:-vtigerpass}"
ADMIN_PASS="${VTIGER_ADMIN_PASSWORD:-Admin@1234}"; ADMIN_EMAIL="${VTIGER_ADMIN_EMAIL:-admin@example.com}"
TIMEZONE="${VTIGER_TIMEZONE:-UTC}"; CURRENCY="${VTIGER_CURRENCY:-USD}"; COMPANY="${VTIGER_COMPANY_NAME:-VEMS}"
APP_ROOT="/app"; INSTALL_PORT=8181; COOKIE_JAR="/tmp/vtiger-install-cookies.txt"
BASE_URL="http://127.0.0.1:${INSTALL_PORT}"
log() { echo "[vtiger-install] $*"; }
err() { echo "[vtiger-install] ERROR: $*" >&2; }

log "Rendering config.inc.php..."
export DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD VTIGER_SITE_URL="${VTIGER_SITE_URL:-http://localhost}"
export VTIGER_TIMEZONE="${TIMEZONE}" VTIGER_LANGUAGE="${VTIGER_LANGUAGE:-en_us}" VTIGER_CURRENCY="${CURRENCY}"
export VTIGER_COMPANY_NAME="${COMPANY}" VTIGER_ADMIN_EMAIL="${ADMIN_EMAIL}"
export VTIGER_ADMIN_USER="${VTIGER_ADMIN_USER:-admin}" VTIGER_ADMIN_PASSWORD="${ADMIN_PASS}"
envsubst < /build/config.inc.php.tpl > "${APP_ROOT}/config.inc.php"
chown www-data:www-data "${APP_ROOT}/config.inc.php"

log "Waiting for MySQL..."
for i in $(seq 1 60); do
  mysqladmin ping -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" -p"${DB_PASSWORD}" --silent 2>/dev/null && break
  [ "$i" = "60" ] && { err "MySQL not ready."; exit 1; }
  sleep 2
done
log "MySQL ready."

log "Starting Apache on port ${INSTALL_PORT}..."
printf "ServerName localhost\nListen 127.0.0.1:%s\nDocumentRoot %s\n<Directory %s>\n    AllowOverride All\n    Require all granted\n</Directory>\nErrorLog /tmp/install-apache-error.log\nCustomLog /tmp/install-apache-access.log combined\n" \
  "${INSTALL_PORT}" "${APP_ROOT}" "${APP_ROOT}" > /tmp/install-apache.conf
apache2 -f /tmp/install-apache.conf -k start 2>/tmp/install-apache-start.log || {
  err "Apache failed: $(cat /tmp/install-apache-start.log)"; exit 1; }
for i in $(seq 1 30); do
  curl -sf "${BASE_URL}/index.php" -o /dev/null 2>/dev/null && break
  [ "$i" = "30" ] && { err "Apache not ready."; cat /tmp/install-apache-error.log; exit 1; }
  sleep 2
done
log "Apache ready."
rm -f "${COOKIE_JAR}"

case "${CURRENCY}" in USD) CN="USA, Dollars";; EUR) CN="Euro Member Countries, Euro";;
  GBP) CN="United Kingdom, Pounds";; AUD) CN="Australia, Dollars";;
  CAD) CN="Canada, Dollars";; *) CN="USA, Dollars";; esac

log "Step5: posting DB and admin config..."
STEP5=$(curl -sf -c "${COOKIE_JAR}" -b "${COOKIE_JAR}" --max-time 120 \
  -d "module=Install&view=Index&mode=Step5&db_type=mysqli" \
  --data-urlencode "db_hostname=${DB_HOST}:${DB_PORT}" \
  --data-urlencode "db_username=${DB_USER}" --data-urlencode "db_password=${DB_PASSWORD}" \
  --data-urlencode "db_name=${DB_NAME}" -d "create_db=" \
  --data-urlencode "currency_name=${CN}" \
  --data-urlencode "password=${ADMIN_PASS}" --data-urlencode "retype_password=${ADMIN_PASS}" \
  --data-urlencode "admin_email=${ADMIN_EMAIL}" -d "firstname=VEMS&lastname=Admin" \
  --data-urlencode "timezone=${TIMEZONE}" -d "dateformat=yyyy-mm-dd&default_language=en_us" \
  "${BASE_URL}/index.php")
log "Step5 posted."

log "Step6: posting confirmation..."
STEP6=$(curl -sf -c "${COOKIE_JAR}" -b "${COOKIE_JAR}" --max-time 60 \
  -d "module=Install&view=Index&mode=Step6" "${BASE_URL}/index.php")
log "Step6 posted."

AUTH_KEY=""
for BODY in "${STEP5}" "${STEP6}"; do
  AK=$(echo "${BODY}" | grep -oP 'name="auth_key"\s+value="\K[^"]+' | head -1 || true)
  [ -n "${AK}" ] && { AUTH_KEY="${AK}"; break; }
done
if [ -z "${AUTH_KEY}" ]; then
  err "Could not extract auth_key."; echo "${STEP5:0:500}"; echo "${STEP6:0:500}"
  apache2 -f /tmp/install-apache.conf -k stop 2>/dev/null; exit 1
fi
log "auth_key: ${AUTH_KEY}"

log "Step7: triggering schema creation (1-3 minutes)..."
curl -sf -c "${COOKIE_JAR}" -b "${COOKIE_JAR}" --max-time 600 \
  -d "module=Install&view=Index&mode=Step7" \
  --data-urlencode "auth_key=${AUTH_KEY}" \
  --data-urlencode "myname=${COMPANY}" --data-urlencode "myemail=${ADMIN_EMAIL}" \
  -d "industry=Technology" "${BASE_URL}/index.php" > /dev/null
log "Step7 complete."

apache2 -f /tmp/install-apache.conf -k stop 2>/dev/null
log "Install Apache stopped."

TC=$(mysql -N -s -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" -p"${DB_PASSWORD}" \
  -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}'
      AND table_name IN ('vtiger_users','vtiger_tab','vtiger_version');")
[ "${TC}" -lt 2 ] && { err "Schema verification failed (${TC} tables)."; exit 1; }
log "Schema verified: ${TC} core tables. Install complete."
