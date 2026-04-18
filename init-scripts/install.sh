#!/usr/bin/env bash
set -euo pipefail

log() { echo "[vtiger-install] $*"; }
err() { echo "[vtiger-install] ERROR: $*" >&2; }

APP_ROOT="${APP_ROOT:-/app}"
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

prepare_install_state() {
  log "Preparing clean installer state (no pre-rendered app config)..."
  rm -f "${CONFIG_FILE}"

  local writable_paths=(
    "${APP_ROOT}/logs"
    "${APP_ROOT}/cache"
    "${APP_ROOT}/storage"
    "${APP_ROOT}/user_privileges"
    "${APP_ROOT}/test"
  )

  for path in "${writable_paths[@]}"; do
    mkdir -p "${path}"
  done

  chown -R www-data:www-data "${writable_paths[@]}" 2>/dev/null || true
  chmod -R u+rwX,g+rwX "${writable_paths[@]}" 2>/dev/null || true
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
    php_admin_flag display_errors Off
    php_admin_value error_reporting "E_ALL & ~E_WARNING & ~E_NOTICE"

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
  local install_url="${internal_url}/index.php?module=Install&view=Index"
  local cookie_jar="/tmp/vtiger-install-cookies.txt"
  local headers_file="/tmp/vtiger-install-headers.txt"
  local body_file="/tmp/vtiger-install-body.html"
  local current_url="${install_url}"
  local step_index
  local form_action
  local form_url
  local post_args=()

  extract_form_action() {
    perl -0777 -ne '
      if (/<form[^>]*action=["'"'"'"'"'"'"'"'"']([^"'"'"'"'"'"'"'"'"']+)["'"'"'"'"'"'"'"'"'][^>]*>/is) {
        $action = $1;
        $action =~ s/&amp;/&/g;
        print $action;
      }' "$1"
  }

  append_hidden_fields() {
    local html_file="$1"
    while IFS='=' read -r name value; do
      [ -z "${name}" ] && continue
      post_args+=(--data-urlencode "${name}=${value}")
    done < <(perl -0777 -ne '
      while (/<input[^>]*type=["'"'"'"'"'"'"'"'"']hidden["'"'"'"'"'"'"'"'"'][^>]*>/ig) {
        $tag = $&;
        next unless $tag =~ /name=["'"'"'"'"'"'"'"'"']([^"'"'"'"'"'"'"'"'"']+)["'"'"'"'"'"'"'"'"']/i;
        $name = $1;
        $value = "";
        $value = $1 if $tag =~ /value=["'"'"'"'"'"'"'"'"']([^"'"'"'"'"'"'"'"'"']*)["'"'"'"'"'"'"'"'"']/i;
        print "$name=$value\n";
      }' "${html_file}")
  }

  append_first_submit_field() {
    local html_file="$1"
    while IFS='=' read -r name value; do
      [ -z "${name}" ] && continue
      post_args+=(--data-urlencode "${name}=${value}")
      break
    done < <(perl -0777 -ne '
      if (/<input[^>]*type=["'"'"'"'"'"'"'"'"']submit["'"'"'"'"'"'"'"'"'][^>]*>/is) {
        $tag = $&;
        if ($tag =~ /name=["'"'"'"'"'"'"'"'"']([^"'"'"'"'"'"'"'"'"']+)["'"'"'"'"'"'"'"'"']/i) {
          $name = $1;
          $value = "";
          $value = $1 if $tag =~ /value=["'"'"'"'"'"'"'"'"']([^"'"'"'"'"'"'"'"'"']*)["'"'"'"'"'"'"'"'"']/i;
          print "$name=$value\n";
        }
      }' "${html_file}")
  }

  append_csrf_field() {
    local html_file="$1"
    local csrf_name=""
    local csrf_value=""

    csrf_name=$(perl -0777 -ne 'if(/csrfMagicName\s*=\s*["'"'"'"'"'"'"'"'"']([^"'"'"'"'"'"'"'"'"']+)["'"'"'"'"'"'"'"'"']/i){print $1}' "${html_file}")
    csrf_value=$(perl -0777 -ne 'if(/csrfMagicToken\s*=\s*["'"'"'"'"'"'"'"'"']([^"'"'"'"'"'"'"'"'"']+)["'"'"'"'"'"'"'"'"']/i){print $1}' "${html_file}")

    if [ -n "${csrf_name}" ] && [ -n "${csrf_value}" ]; then
      post_args+=(--data-urlencode "${csrf_name}=${csrf_value}")
    fi
  }

  print_response_diagnostics() {
    local html_file="$1"
    local step_label="$2"
    local title
    local page_kind
    local errors

    title=$(sed -n 's:.*<title[^>]*>\(.*\)</title>.*:\1:Ip' "${html_file}" | head -1 | sed 's/[[:space:]]\+/ /g' || true)
    [ -n "${title}" ] || title="(no <title> found)"

    if grep -qiE 'installation completed|login|dashboard' "${html_file}"; then
      page_kind="success/redirect target"
    elif grep -qiE 'requirement|prerequisite|php configuration|permissions' "${html_file}"; then
      page_kind="requirements/prerequisite page"
    elif grep -qiE 'step[[:space:]]*[0-9]|installation wizard|install vtiger' "${html_file}"; then
      page_kind="installer step page"
    elif grep -qiE 'error|exception|fatal|warning' "${html_file}"; then
      page_kind="error page"
    else
      page_kind="unclassified page"
    fi

    errors=$(grep -iE 'error|exception|fatal|warning|failed' "${html_file}" | head -10 | sed 's/<[^>]*>//g' || true)

    log "${step_label} diagnostics:"
    log "  Page title: ${title}"
    log "  Page type: ${page_kind}"
    if [ -n "${errors}" ]; then
      log "  Error-like text (first lines):"
      echo "${errors}" | sed 's/^/[vtiger-install]    /'
    fi
    log "  Body excerpt:"
    sed -n '1,40p' "${html_file}" | sed 's/<[^>]*>//g' | sed '/^[[:space:]]*$/d' | head -12 | sed 's/^/[vtiger-install]    /' || true
  }

  log "Waiting for Apache on ${internal_url}..."
  for i in $(seq 1 60); do
    if curl -sS -o /dev/null "${internal_url}/" 2>/dev/null; then
      log "Apache responding (attempt ${i})."
      break
    fi
    [ "$i" = "60" ] && { err "Apache never responded on ${internal_url}."; exit 1; }
    sleep 2
  done

  rm -f "${cookie_jar}" "${headers_file}" "${body_file}" /tmp/vtiger-install-response.html /tmp/vtiger-install-step-*.html
  log "Loading installer entry page: ${install_url}"
  HTTP_CODE=$(curl -sS -D "${headers_file}" -c "${cookie_jar}" -b "${cookie_jar}" \
    --max-time 120 --referer "${install_url}" -o "${body_file}" -w '%{http_code}' "${install_url}" 2>/dev/null || true)
  cp "${body_file}" /tmp/vtiger-install-step-0-get.html
  cp "${body_file}" /tmp/vtiger-install-response.html
  log "Installer entry HTTP response code: ${HTTP_CODE}"
  print_response_diagnostics "${body_file}" "Step 1 (GET)"

  for step_index in $(seq 1 8); do
    form_action=$(extract_form_action "${body_file}" || true)
    if [ -z "${form_action}" ]; then
      log "No installer form action found after step ${step_index}; assuming wizard finished or redirected."
      break
    fi

    if [[ "${form_action}" =~ ^https?:// ]]; then
      form_url="${form_action}"
    else
      form_url="${internal_url}/${form_action#/}"
    fi
    log "Submitting installer step ${step_index} to ${form_url} (site_URL=${VTIGER_SITE_URL})..."

    post_args=()
    append_hidden_fields "${body_file}"
    append_csrf_field "${body_file}"
    append_first_submit_field "${body_file}"
    post_args+=(
      --data-urlencode "module=Install"
      --data-urlencode "view=Index"
      --data-urlencode "accept_license=on"
      --data-urlencode "dbname=${DB_NAME}"
      --data-urlencode "dbusername=${DB_USER}"
      --data-urlencode "dbpassword=${DB_PASSWORD}"
      --data-urlencode "db_type=mysqli"
      --data-urlencode "db_hostname=${DB_HOST}"
      --data-urlencode "db_port=${DB_PORT}"
      --data-urlencode "site_URL=${VTIGER_SITE_URL}"
      --data-urlencode "admin_name=${VTIGER_ADMIN_USER}"
      --data-urlencode "admin_password=${VTIGER_ADMIN_PASSWORD}"
      --data-urlencode "confirm_admin_password=${VTIGER_ADMIN_PASSWORD}"
      --data-urlencode "admin_email=${VTIGER_ADMIN_EMAIL}"
      --data-urlencode "timezone=${VTIGER_TIMEZONE}"
      --data-urlencode "default_language=${VTIGER_LANGUAGE}"
      --data-urlencode "default_currency=${VTIGER_CURRENCY}"
      --data-urlencode "company_name=${VTIGER_COMPANY_NAME}"
    )

    # Do not use -f or -L: vtiger may redirect to VTIGER_SITE_URL on success, which can be
    # unreachable from inside the installer container. Verify success via DB instead.
    HTTP_CODE=$(curl -sS -D "${headers_file}" -c "${cookie_jar}" -b "${cookie_jar}" \
      --max-time 300 -H 'Content-Type: application/x-www-form-urlencoded' \
      --referer "${current_url}" \
      -o "${body_file}" -w '%{http_code}' \
      "${post_args[@]}" \
      "${form_url}" 2>/dev/null || true)
    cp "${body_file}" "/tmp/vtiger-install-step-${step_index}-post.html"
    cp "${body_file}" /tmp/vtiger-install-response.html
    log "Installer submit HTTP response code: ${HTTP_CODE}"
    print_response_diagnostics "${body_file}" "Step $((step_index + 1)) (POST)"

    if grep -qi 'Invalid request' "${body_file}"; then
      err "Installer rejected step ${step_index} as Invalid request."
      return 1
    fi

    current_url="${form_url}"
  done
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
  prepare_install_state
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
