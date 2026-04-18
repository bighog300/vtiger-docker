#!/usr/bin/env bash
set -euo pipefail

log() { echo "[vtiger-install] $*"; }
err() { echo "[vtiger-install] ERROR: $*" >&2; }

APP_ROOT="${APP_ROOT:-/app}"
CONFIG_TEMPLATE="${CONFIG_TEMPLATE:-/build/config.inc.php.tpl}"
CONFIG_FILE="${APP_ROOT}/config.inc.php"
INSTALL_PORT="${INSTALL_PORT:-8181}"

DB_HOST="${DB_HOST:-mysql}"
DB_PORT="${DB_PORT:-3306}"
DB_NAME="${DB_NAME:-vtiger}"
DB_USER="${DB_USER:-vtiger}"
DB_PASSWORD="${DB_PASSWORD:-vtigerpass}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-root}"

# Public-facing site URL stored in vtiger config — NOT used for the internal curl install request.
VTIGER_SITE_URL="${VTIGER_SITE_URL:-http://localhost:8080}"
VTIGER_ADMIN_USER="${VTIGER_ADMIN_USER:-admin}"
VTIGER_ADMIN_PASSWORD="${VTIGER_ADMIN_PASSWORD:-Admin@1234}"
VTIGER_ADMIN_EMAIL="${VTIGER_ADMIN_EMAIL:-admin@example.com}"
VTIGER_TIMEZONE="${VTIGER_TIMEZONE:-UTC}"
VTIGER_LANGUAGE="${VTIGER_LANGUAGE:-en_us}"
VTIGER_CURRENCY="${VTIGER_CURRENCY:-USD}"
VTIGER_COMPANY_NAME="${VTIGER_COMPANY_NAME:-VEMS}"

wait_for_mysql() {
  log "Waiting for MySQL root ping..."
  for i in $(seq 1 90); do
    if mysqladmin ping -h"${DB_HOST}" -P"${DB_PORT}" -uroot -p"${DB_ROOT_PASSWORD}" --silent >/dev/null 2>&1; then
      log "MySQL ready (attempt ${i})."
      return 0
    fi
    log "Attempt ${i}/90 — retrying in 3s..."
    sleep 3
  done
  err "MySQL never became ready."
  return 1
}

wait_for_app_user() {
  log "Waiting for app user grants..."
  for i in $(seq 1 60); do
    if mysql -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" -p"${DB_PASSWORD}" -e "USE \`${DB_NAME}\`;" >/dev/null 2>&1; then
      log "App user ready."
      return 0
    fi
    sleep 2
  done
  err "App user credentials/grants not ready."
  return 1
}

render_config() {
  log "Rendering config.inc.php..."
  export DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD
  export VTIGER_SITE_URL VTIGER_ADMIN_USER VTIGER_ADMIN_PASSWORD VTIGER_ADMIN_EMAIL
  export VTIGER_TIMEZONE VTIGER_LANGUAGE VTIGER_CURRENCY VTIGER_COMPANY_NAME

  mkdir -p "$(dirname "${CONFIG_FILE}")"
  envsubst < "${CONFIG_TEMPLATE}" > "${CONFIG_FILE}"
}

start_apache() {
  log "Starting Apache on 127.0.0.1:${INSTALL_PORT}..."

  a2enmod rewrite >/dev/null 2>&1 || true
  a2dissite 000-default >/dev/null 2>&1 || true

  cat > /etc/apache2/ports.conf <<PORTS
Listen 127.0.0.1:${INSTALL_PORT}
PORTS

  cat > /etc/apache2/sites-available/vtiger-install.conf <<VHOST
<VirtualHost 127.0.0.1:${INSTALL_PORT}>
    ServerName localhost
    DocumentRoot ${APP_ROOT}

    <Directory ${APP_ROOT}>
        AllowOverride All
        Require all granted
        DirectoryIndex index.php
    </Directory>

    ErrorLog /tmp/install-apache-error.log
    CustomLog /tmp/install-apache-access.log combined
</VirtualHost>
VHOST

  a2ensite vtiger-install >/dev/null 2>&1 || true

  apache2ctl -k start 2>/tmp/install-apache-start.log || {
    err "Apache failed to start: $(cat /tmp/install-apache-start.log)"
    exit 1
  }
}

stop_apache() {
  apache2ctl -k stop >/dev/null 2>&1 || true
}

run_install() {
  local internal_url="http://127.0.0.1:${INSTALL_PORT}"
  local install_url="${internal_url}/index.php?module=Users&action=Install"

  log "Waiting for Apache on ${internal_url}..."
  for i in $(seq 1 60); do
    if curl -sS -o /dev/null "${internal_url}/" 2>/dev/null; then
      log "Apache responding (attempt ${i})."
      break
    fi
    [ "$i" = "60" ] && { err "Apache never responded on ${internal_url}."; exit 1; }
    sleep 2
  done

  log "Submitting installer to ${install_url} (site_URL=${VTIGER_SITE_URL})..."
  # Do not use -f or -L: vtiger redirects to VTIGER_SITE_URL on success, which may be
  # unreachable from inside the installer container. Verify success via DB instead.
  HTTP_CODE=$(curl -sS -o /tmp/vtiger-install-response.html -w '%{http_code}' \
    --max-time 300 \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "dbname=${DB_NAME}" \
    --data-urlencode "dbusername=${DB_USER}" \
    --data-urlencode "dbpassword=${DB_PASSWORD}" \
    --data-urlencode "db_type=mysqli" \
    --data-urlencode "db_hostname=${DB_HOST}" \
    --data-urlencode "db_port=${DB_PORT}" \
    --data-urlencode "site_URL=${VTIGER_SITE_URL}" \
    --data-urlencode "admin_name=${VTIGER_ADMIN_USER}" \
    --data-urlencode "admin_password=${VTIGER_ADMIN_PASSWORD}" \
    --data-urlencode "confirm_admin_password=${VTIGER_ADMIN_PASSWORD}" \
    --data-urlencode "admin_email=${VTIGER_ADMIN_EMAIL}" \
    --data-urlencode "timezone=${VTIGER_TIMEZONE}" \
    --data-urlencode "default_language=${VTIGER_LANGUAGE}" \
    --data-urlencode "default_currency=${VTIGER_CURRENCY}" \
    --data-urlencode "company_name=${VTIGER_COMPANY_NAME}" \
    "${install_url}" 2>/dev/null || true)
  log "Installer HTTP response code: ${HTTP_CODE}"
}

verify_schema() {
  log "Verifying database schema..."
  local table_count
  table_count=$(mysql -N -s \
    -h"${DB_HOST}" -P"${DB_PORT}" \
    -uroot -p"${DB_ROOT_PASSWORD}" \
    -e "SELECT COUNT(*) FROM information_schema.tables
        WHERE table_schema='${DB_NAME}'
        AND table_name IN ('vtiger_users','vtiger_tab','vtiger_version','vtiger_field');" \
    2>/dev/null || echo 0)
  if [ "${table_count}" -lt 4 ]; then
    err "Schema verification failed: expected 4 core tables, found ${table_count}."
    if [ -f /tmp/vtiger-install-response.html ]; then
      grep -iE 'error|fail|exception' /tmp/vtiger-install-response.html | head -20 || true
    fi
    exit 1
  fi
  log "Schema verified: ${table_count}/4 core tables present."
}

main() {
  render_config
  wait_for_mysql
  wait_for_app_user
  start_apache

  trap 'stop_apache' EXIT

  run_install
  log "Installer request completed."

  verify_schema
  log "Installation successful."
}

main "$@"
