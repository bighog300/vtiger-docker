#!/usr/bin/env bash
set -euo pipefail

DB_HOST="${DB_HOST:-mysql}"; DB_PORT="${DB_PORT:-3306}"; DB_NAME="${DB_NAME:-vtiger}"
DB_USER="${DB_USER:-vtiger}"; DB_PASSWORD="${DB_PASSWORD:-vtigerpass}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-buildroot}"
ADMIN_PASS="${VTIGER_ADMIN_PASSWORD:-Admin@1234}"; ADMIN_EMAIL="${VTIGER_ADMIN_EMAIL:-admin@example.com}"
TIMEZONE="${VTIGER_TIMEZONE:-UTC}"; CURRENCY="${VTIGER_CURRENCY:-USD}"; COMPANY="${VTIGER_COMPANY_NAME:-VEMS}"
APP_ROOT="/app"; INSTALL_PORT=8181; COOKIE_JAR="/tmp/vtiger-install-cookies.txt"
BASE_URL="http://127.0.0.1:${INSTALL_PORT}"
log() { echo "[vtiger-install] $*"; }
err() { echo "[vtiger-install] ERROR: $*" >&2; }

log "Rendering config.inc.php..."
export DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD
export VTIGER_SITE_URL="${VTIGER_SITE_URL:-http://localhost}" VTIGER_TIMEZONE="${TIMEZONE}"
export VTIGER_LANGUAGE="${VTIGER_LANGUAGE:-en_us}" VTIGER_CURRENCY="${CURRENCY}"
export VTIGER_COMPANY_NAME="${COMPANY}" VTIGER_ADMIN_EMAIL="${ADMIN_EMAIL}"
export VTIGER_ADMIN_USER="${VTIGER_ADMIN_USER:-admin}" VTIGER_ADMIN_PASSWORD="${ADMIN_PASS}"
envsubst < /build/config.inc.php.tpl > "${APP_ROOT}/config.inc.php"
chown www-data:www-data "${APP_ROOT}/config.inc.php"

log "Waiting for MySQL root ping..."
for i in $(seq 1 90); do
  mysqladmin ping -h"${DB_HOST}" -P"${DB_PORT}" -uroot -p"${DB_ROOT_PASSWORD}" --silent 2>/dev/null && { log "MySQL ready (attempt ${i})."; break; }
  log "Attempt ${i}/90 — retrying in 3s..."
  [ "$i" = "90" ] && { err "MySQL not ready after 90 attempts."; exit 1; }
  sleep 3
done

log "Waiting for app user grants..."
for i in $(seq 1 30); do
  mysql -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" -p"${DB_PASSWORD}" -e "SELECT 1;" "${DB_NAME}" >/dev/null 2>&1 && { log "App user ready."; break; }
  [ "$i" = "30" ] && { err "App user not accessible."; exit 1; }
  sleep 2
done

log "Starting Apache on port ${INSTALL_PORT}..."
a2enmod rewrite php8.2 2>/dev/null || true
printf "ServerName localhost\nListen 127.0.0.1:%s\nDocumentRoot %s\n<Directory %s>\n    AllowOverride All\n    Require all granted\n    DirectoryIndex index.php\n</Directory>\n<FilesMatch \"\\.php\$\">\n    SetHandler application/x-httpd-php\n</FilesMatch>\nErrorLog /tmp/install-apache-error.log\nCustomLog /tmp/install-apache-access.log combined\n" \
  "${INSTALL_PORT}" "${APP_ROOT}" "${APP_ROOT}" > /tmp/install-apache.conf

apache2 -f /tmp/install-apache.conf -k start 2>/tmp/install-apache-start.log || {
  err "Apache failed: $(cat /tmp/install-apache-start.log)"; exit 1; }

log "Waiting for Apache..."
for i in $(seq 1 30); do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/index.php" 2>/dev/null || echo 0)
  [ "${STATUS}" != "0" ] && [ "${STATUS}" != "000" ] && { log "Apache ready HTTP ${STATUS}."; break; }
  [ "$i" = "30" ] && { err "Apache not ready."; cat /tmp/install-apache-error.log; exit 1; }
  sleep 2
done
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
  "${BASE_URL}/index.php" || true)
log "Step5 posted (${#STEP5} bytes)."

log "Step6: posting confirmation..."
STEP6=$(curl -sf -c "${COOKIE_JAR}" -b "${COOKIE_JAR}" --max-time 60 \
  -d "module=Install&view=Index&mode=Step6" "${BASE_URL}/index.php" || true)
log "Step6 posted (${#STEP6} bytes)."

AUTH_KEY=""
for BODY in "${STEP5}" "${STEP6}"; do
  AK=$(echo "${BODY}" | grep -oP 'name="auth_key"\s+value="\K[^"]+' | head -1 || true)
  [ -n "${AK}" ] && { AUTH_KEY="${AK}"; break; }
done
if [ -z "${AUTH_KEY}" ]; then
  err "Could not extract auth_key."
  err "Step5: ${STEP5:0:800}"
  err "Step6: ${STEP6:0:800}"
  apache2 -f /tmp/install-apache.conf -k stop 2>/dev/null
  exit 1
fi
log "auth_key: ${AUTH_KEY}"

log "Step7: triggering schema creation (1-3 minutes)..."
STEP7=$(curl -sf -c "${COOKIE_JAR}" -b "${COOKIE_JAR}" --max-time 600 \
  -d "module=Install&view=Index&mode=Step7" \
  --data-urlencode "auth_key=${AUTH_KEY}" \
  --data-urlencode "myname=${COMPANY}" --data-urlencode "myemail=${ADMIN_EMAIL}" \
  -d "industry=Technology" "${BASE_URL}/index.php" || true)
log "Step7 complete (${#STEP7} bytes)."

apache2 -f /tmp/install-apache.conf -k stop 2>/dev/null || true
log "Install Apache stopped."

TC=$(mysql -N -s -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" -p"${DB_PASSWORD}" \
  -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}'
      AND table_name IN ('vtiger_users','vtiger_tab','vtiger_version');" 2>/dev/null || echo 0)

if [ "${TC}" -lt 2 ]; then
  err "Schema verification failed — ${TC} core table(s) found."
  err "Step7: ${STEP7:0:1000}"
  exit 1
fi
log "Schema verified: ${TC} core tables. Install complete."
