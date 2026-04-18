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
  local previous_step_label=""
  local current_step_label=""
  local previous_step_mode=""
  local current_step_mode=""
  local step_index
  local form_action
  local form_url
  local post_args=()

  add_or_replace_field() {
    local field_name="$1"
    local field_value="$2"
    local i
    for ((i=${#post_args[@]}-1; i>=0; i--)); do
      if [ "${post_args[$i]}" = "--data-urlencode" ] && [ $((i+1)) -lt ${#post_args[@]} ]; then
        case "${post_args[$((i+1))]}" in
          "${field_name}="*)
            post_args[$((i+1))]="${field_name}=${field_value}"
            return 0
            ;;
        esac
      fi
    done
    post_args+=(--data-urlencode "${field_name}=${field_value}")
  }

  extract_form_action() {
    perl -0777 -ne '
      if (/<form[^>]*action=["'"'"'"'"'"'"'"'"']([^"'"'"'"'"'"'"'"'"']+)["'"'"'"'"'"'"'"'"'][^>]*>/is) {
        $action = $1;
        $action =~ s/&amp;/&/g;
        print $action;
      }' "$1"
  }

  extract_form_action_for_mode() {
    local html_file="$1"
    local mode_value="$2"
    perl -0777 -ne '
      my ($html, $mode) = @ARGV;
      while ($html =~ m{(<form\b[^>]*>.*?</form>)}sig) {
        my $form = $1;
        next unless $form =~ /name=["'"'"']mode["'"'"'][^>]*value=["'"'"']\Q$mode\E["'"'"']/i
          || $form =~ /value=["'"'"']\Q$mode\E["'"'"'][^>]*name=["'"'"']mode["'"'"']/i;
        if ($form =~ /<form[^>]*action=["'"'"']([^"'"'"']+)["'"'"'][^>]*>/i) {
          my $action = $1;
          $action =~ s/&amp;/&/g;
          print $action;
          last;
        }
      }
    ' "${html_file}" "${mode_value}"
  }

  extract_step_label() {
    local html_file="$1"
    perl -0777 -ne '
      sub decode {
        my ($s) = @_;
        $s =~ s/&nbsp;/ /g;
        $s =~ s/&amp;/&/g;
        $s =~ s/&quot;/"/g;
        $s =~ s/&#39;/'"'"'/g;
        $s =~ s/&lt;/</g;
        $s =~ s/&gt;/>/g;
        $s =~ s/<script\b[^>]*>.*?<\/script>//gis;
        $s =~ s/<style\b[^>]*>.*?<\/style>//gis;
        $s =~ s/<[^>]+>/ /g;
        $s =~ s/\s+/ /g;
        $s =~ s/^\s+|\s+$//g;
        return $s;
      }

      my $html = $_;
      my $label = "";

      if ($html =~ /<li[^>]*class=["'"'"'"'"'"'"'"'"'][^"'"'"'"'"'"'"'"'"']*(?:active|current)[^"'"'"'"'"'"'"'"'"']*["'"'"'"'"'"'"'"'"'][^>]*>(.*?)<\/li>/is) {
        $label = decode($1);
      }
      if (!$label && $html =~ /<h[1-4][^>]*>(.*?)<\/h[1-4]>/is) {
        $label = decode($1);
      }
      if (!$label && $html =~ /<title[^>]*>(.*?)<\/title>/is) {
        $label = decode($1);
      }

      my $text = decode($html);
      my @known = (
        "Welcome", "License", "Requirements", "Pre-Installation",
        "System Configuration", "Database Information", "Database Configuration",
        "Configure Database", "Company Details", "Confirmation", "Installation",
        "Completed", "Finish"
      );
      if (!$label) {
        for my $k (@known) {
          if ($text =~ /\Q$k\E/i) {
            $label = $k;
            last;
          }
        }
      }

      $label = "Unknown" if !$label;
      $label =~ s/\s+/ /g;
      $label =~ s/^\s+|\s+$//g;
      print $label;
    ' "${html_file}"
  }

  extract_hidden_mode() {
    perl -0777 -ne '
      if (/<input\b[^>]*name=["'"'"'"'"'"'"'"'"']mode["'"'"'"'"'"'"'"'"'][^>]*value=["'"'"'"'"'"'"'"'"']([^"'"'"'"'"'"'"'"'"']+)["'"'"'"'"'"'"'"'"']/i) {
        print $1;
      } elsif (/<input\b[^>]*value=["'"'"'"'"'"'"'"'"']([^"'"'"'"'"'"'"'"'"']+)["'"'"'"'"'"'"'"'"'][^>]*name=["'"'"'"'"'"'"'"'"']mode["'"'"'"'"'"'"'"'"']/i) {
        print $1;
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

  append_hidden_fields_for_mode() {
    local html_file="$1"
    local mode_value="$2"
    while IFS='=' read -r name value; do
      [ -z "${name}" ] && continue
      post_args+=(--data-urlencode "${name}=${value}")
    done < <(perl -0777 -ne '
      my ($html, $mode) = @ARGV;
      while ($html =~ m{(<form\b[^>]*>.*?</form>)}sig) {
        my $form = $1;
        next unless $form =~ /name=["'"'"']mode["'"'"'][^>]*value=["'"'"']\Q$mode\E["'"'"']/i
          || $form =~ /value=["'"'"']\Q$mode\E["'"'"'][^>]*name=["'"'"']mode["'"'"']/i;
        while ($form =~ /<input[^>]*type=["'"'"']hidden["'"'"'][^>]*>/ig) {
          my $tag = $&;
          next unless $tag =~ /name=["'"'"']([^"'"'"']+)["'"'"']/i;
          my $name = $1;
          my $value = "";
          $value = $1 if $tag =~ /value=["'"'"']([^"'"'"']*)["'"'"']/i;
          print "$name=$value\n";
        }
        last;
      }
    ' "${html_file}" "${mode_value}")
  }

  append_checkbox_fields() {
    local html_file="$1"
    while IFS='=' read -r name value; do
      [ -z "${name}" ] && continue
      post_args+=(--data-urlencode "${name}=${value}")
    done < <(perl -0777 -ne '
      while (/<input\b[^>]*type=["'"'"'"'"'"'"'"'"']checkbox["'"'"'"'"'"'"'"'"'][^>]*>/ig) {
        my $tag = $&;
        next unless $tag =~ /name=["'"'"'"'"'"'"'"'"']([^"'"'"'"'"'"'"'"'"']+)["'"'"'"'"'"'"'"'"']/i;
        my $name = $1;
        my $value = "on";
        $value = $1 if $tag =~ /value=["'"'"'"'"'"'"'"'"']([^"'"'"'"'"'"'"'"'"']*)["'"'"'"'"'"'"'"'"']/i;
        my $include = 0;
        $include = 1 if $tag =~ /\bchecked\b/i;
        $include = 1 if $tag =~ /\brequired\b/i;
        $include = 1 if $tag =~ /(accept|agree|license|terms)/i;
        print "$name=$value\n" if $include;
      }' "${html_file}")
  }

  append_radio_fields() {
    local html_file="$1"
    while IFS='=' read -r name value; do
      [ -z "${name}" ] && continue
      post_args+=(--data-urlencode "${name}=${value}")
    done < <(perl -0777 -ne '
      my %picked = ();
      while (/<input\b[^>]*type=["'"'"'"'"'"'"'"'"']radio["'"'"'"'"'"'"'"'"'][^>]*>/ig) {
        my $tag = $&;
        next unless $tag =~ /name=["'"'"'"'"'"'"'"'"']([^"'"'"'"'"'"'"'"'"']+)["'"'"'"'"'"'"'"'"']/i;
        my $name = $1;
        my $value = "";
        $value = $1 if $tag =~ /value=["'"'"'"'"'"'"'"'"']([^"'"'"'"'"'"'"'"'"']*)["'"'"'"'"'"'"'"'"']/i;
        if (!exists $picked{$name}) {
          $picked{$name} = $value;
        }
        if ($tag =~ /\bchecked\b/i) {
          $picked{$name} = $value;
        }
      }
      for my $name (sort keys %picked) {
        print "$name=$picked{$name}\n";
      }
    ' "${html_file}")
  }

  append_select_fields() {
    local html_file="$1"
    while IFS='=' read -r name value; do
      [ -z "${name}" ] && continue
      post_args+=(--data-urlencode "${name}=${value}")
    done < <(perl -0777 -ne '
      while (/<select\b[^>]*name=["'"'"'"'"'"'"'"'"']([^"'"'"'"'"'"'"'"'"']+)["'"'"'"'"'"'"'"'"'][^>]*>(.*?)<\/select>/sig) {
        my ($name, $body) = ($1, $2);
        my $selected = "";
        if ($body =~ /<option\b[^>]*selected[^>]*value=["'"'"'"'"'"'"'"'"']([^"'"'"'"'"'"'"'"'"']*)["'"'"'"'"'"'"'"'"']/i) {
          $selected = $1;
        } elsif ($body =~ /<option\b[^>]*value=["'"'"'"'"'"'"'"'"']([^"'"'"'"'"'"'"'"'"']*)["'"'"'"'"'"'"'"'"']/i) {
          $selected = $1;
        }
        print "$name=$selected\n";
      }
    ' "${html_file}")
  }

  append_visible_text_fields() {
    local html_file="$1"
    while IFS='=' read -r name value; do
      [ -z "${name}" ] && continue
      post_args+=(--data-urlencode "${name}=${value}")
    done < <(perl -0777 -ne '
      while (/<input\b[^>]*type=["'"'"'"'"'"'"'"'"'](?:text|email|url|number|password)["'"'"'"'"'"'"'"'"'][^>]*>/ig) {
        my $tag = $&;
        next unless $tag =~ /name=["'"'"'"'"'"'"'"'"']([^"'"'"'"'"'"'"'"'"']+)["'"'"'"'"'"'"'"'"']/i;
        next if $tag =~ /\bdisabled\b/i;
        my $name = $1;
        my $value = "";
        $value = $1 if $tag =~ /value=["'"'"'"'"'"'"'"'"']([^"'"'"'"'"'"'"'"'"']*)["'"'"'"'"'"'"'"'"']/i;
        print "$name=$value\n";
      }
    ' "${html_file}")
  }

  append_next_submit_field() {
    local html_file="$1"
    while IFS='=' read -r name value; do
      [ -z "${name}" ] && continue
      post_args+=(--data-urlencode "${name}=${value}")
      break
    done < <(perl -0777 -ne '
      my @candidates = ();
      while (/<input\b[^>]*type=["'"'"'"'"'"'"'"'"']submit["'"'"'"'"'"'"'"'"'][^>]*>/ig) {
        my $tag = $&;
        next unless $tag =~ /name=["'"'"'"'"'"'"'"'"']([^"'"'"'"'"'"'"'"'"']+)["'"'"'"'"'"'"'"'"']/i;
        my $name = $1;
        my $value = "";
        $value = $1 if $tag =~ /value=["'"'"'"'"'"'"'"'"']([^"'"'"'"'"'"'"'"'"']*)["'"'"'"'"'"'"'"'"']/i;
        push @candidates, "$name=$value";
      }
      while (/<button\b[^>]*type=["'"'"'"'"'"'"'"'"']submit["'"'"'"'"'"'"'"'"'][^>]*>(.*?)<\/button>/ig) {
        my $tag = $&;
        my $text = $1 // "";
        next unless $tag =~ /name=["'"'"'"'"'"'"'"'"']([^"'"'"'"'"'"'"'"'"']+)["'"'"'"'"'"'"'"'"']/i;
        my $name = $1;
        my $value = "";
        $value = $1 if $tag =~ /value=["'"'"'"'"'"'"'"'"']([^"'"'"'"'"'"'"'"'"']*)["'"'"'"'"'"'"'"'"']/i;
        $value = $text if $value eq "";
        $text =~ s/<[^>]+>/ /g;
        $text =~ s/\s+/ /g;
        push @candidates, "$name=$value|$text";
      }

      my $best = "";
      for my $c (@candidates) {
        my $probe = $c;
        if ($probe =~ /(next|continue|install|start|proceed|finish)/i) {
          ($best = $c) =~ s/\|.*$//;
          last;
        }
        $best = $c unless $best;
      }

      if ($best) {
        $best =~ s/\|.*$//;
        print "$best\n";
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

  append_step2_controls() {
    local html_file="$1"
    while IFS='=' read -r name value; do
      [ -z "${name}" ] && continue
      post_args+=(--data-urlencode "${name}=${value}")
    done < <(perl -0777 -ne '
      my $html = $_;
      while ($html =~ m{(<form\b[^>]*>.*?</form>)}sig) {
        my $form = $1;
        next unless $form =~ /name=["'"'"']mode["'"'"'][^>]*value=["'"'"']Step2["'"'"']/i
          || $form =~ /value=["'"'"']Step2["'"'"'][^>]*name=["'"'"']mode["'"'"']/i;

        while ($form =~ /<input\b[^>]*type=["'"'"']checkbox["'"'"'][^>]*>/ig) {
          my $tag = $&;
          next unless $tag =~ /name=["'"'"']([^"'"'"']+)["'"'"']/i;
          my $name = $1;
          next unless $name =~ /(accept|agree|license|terms)/i || $tag =~ /(accept|agree|license|terms)/i;
          my $value = "on";
          $value = $1 if $tag =~ /value=["'"'"']([^"'"'"']*)["'"'"']/i;
          print "$name=$value\n";
          last;
        }

        my @candidates = ();
        while ($form =~ /<input\b[^>]*type=["'"'"']submit["'"'"'][^>]*>/ig) {
          my $tag = $&;
          next unless $tag =~ /name=["'"'"']([^"'"'"']+)["'"'"']/i;
          my $name = $1;
          my $value = "";
          $value = $1 if $tag =~ /value=["'"'"']([^"'"'"']*)["'"'"']/i;
          push @candidates, "$name=$value";
        }
        while ($form =~ /<button\b[^>]*type=["'"'"']submit["'"'"'][^>]*>(.*?)<\/button>/ig) {
          my $tag = $&;
          my $text = $1 // "";
          next unless $tag =~ /name=["'"'"']([^"'"'"']+)["'"'"']/i;
          my $name = $1;
          my $value = "";
          $value = $1 if $tag =~ /value=["'"'"']([^"'"'"']*)["'"'"']/i;
          $text =~ s/<[^>]+>/ /g;
          $text =~ s/\s+/ /g;
          $text =~ s/^\s+|\s+$//g;
          $value = $text if $value eq "";
          push @candidates, "$name=$value|$text";
        }
        my $best = "";
        for my $c (@candidates) {
          my $probe = $c;
          if ($probe =~ /(next|continue|agree|install|start|proceed)/i) {
            ($best = $c) =~ s/\|.*$//;
            last;
          }
          $best = $c unless $best;
        }
        if ($best) {
          $best =~ s/\|.*$//;
          print "$best\n";
        }
        last;
      }
    ' "${html_file}")
  }

  log_payload_field_names() {
    local label="$1"
    local pair
    local names=()
    local value
    for ((i=0; i<${#post_args[@]}; i++)); do
      if [ "${post_args[$i]}" = "--data-urlencode" ] && [ $((i+1)) -lt ${#post_args[@]} ]; then
        pair="${post_args[$((i+1))]}"
        names+=("${pair%%=*}")
      fi
    done
    if [ ${#names[@]} -eq 0 ]; then
      log "${label} payload fields: (none)"
      return
    fi
    log "${label} payload fields (${#names[@]}):"
    for name in "${names[@]}"; do
      if [[ "${name}" =~ (pass|password|token|secret|key|csrf) ]]; then
        value="<masked>"
      else
        value="<set>"
      fi
      log "  - ${name}=${value}"
    done
  }

  append_step_specific_fields() {
    local step_label="$1"

    case "${step_label}" in
      *Welcome*|*License*)
        add_or_replace_field "accept_license" "on"
        add_or_replace_field "agreement" "on"
        add_or_replace_field "mode" "Requirements"
        ;;
      *Requirement*|*Pre-Installation*)
        add_or_replace_field "mode" "Configuration"
        ;;
      *Database*|*Configuration*)
        add_or_replace_field "db_type" "mysqli"
        add_or_replace_field "db_hostname" "${DB_HOST}"
        add_or_replace_field "db_port" "${DB_PORT}"
        add_or_replace_field "dbname" "${DB_NAME}"
        add_or_replace_field "dbusername" "${DB_USER}"
        add_or_replace_field "dbpassword" "${DB_PASSWORD}"
        add_or_replace_field "site_URL" "${VTIGER_SITE_URL}"
        ;;
      *Company*|*Admin*|*Details*)
        add_or_replace_field "admin_name" "${VTIGER_ADMIN_USER}"
        add_or_replace_field "admin_password" "${VTIGER_ADMIN_PASSWORD}"
        add_or_replace_field "confirm_admin_password" "${VTIGER_ADMIN_PASSWORD}"
        add_or_replace_field "admin_email" "${VTIGER_ADMIN_EMAIL}"
        add_or_replace_field "timezone" "${VTIGER_TIMEZONE}"
        add_or_replace_field "default_language" "${VTIGER_LANGUAGE}"
        add_or_replace_field "default_currency" "${VTIGER_CURRENCY}"
        add_or_replace_field "company_name" "${VTIGER_COMPANY_NAME}"
        ;;
      *Confirm*|*Installation*|*Final*|*Finish*)
        add_or_replace_field "install" "on"
        add_or_replace_field "mode" "Install"
        ;;
    esac
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
  previous_step_label=$(extract_step_label "${body_file}" || true)
  previous_step_label="${previous_step_label:-Unknown}"
  previous_step_mode=$(extract_hidden_mode "${body_file}" || true)
  previous_step_mode="${previous_step_mode:-Unknown}"
  log "Installer visible step: ${previous_step_label}"
  log "Installer mode marker: ${previous_step_mode}"

  for step_index in $(seq 1 8); do
    form_action=""
    if [ "${previous_step_mode}" = "Step2" ]; then
      form_action=$(extract_form_action_for_mode "${body_file}" "Step2" || true)
    fi
    [ -n "${form_action}" ] || form_action=$(extract_form_action "${body_file}" || true)
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
    if [ "${previous_step_mode}" = "Step2" ]; then
      append_hidden_fields_for_mode "${body_file}" "Step2"
      append_csrf_field "${body_file}"
      append_step2_controls "${body_file}"
      add_or_replace_field "module" "Install"
      add_or_replace_field "view" "Index"
      log_payload_field_names "Step2"
    else
      append_hidden_fields "${body_file}"
      append_csrf_field "${body_file}"
      append_checkbox_fields "${body_file}"
      append_radio_fields "${body_file}"
      append_select_fields "${body_file}"
      append_visible_text_fields "${body_file}"
      append_next_submit_field "${body_file}"
      add_or_replace_field "module" "Install"
      add_or_replace_field "view" "Index"
      append_step_specific_fields "${previous_step_label}"
      log_payload_field_names "Step ${step_index}"
    fi

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
    current_step_label=$(extract_step_label "${body_file}" || true)
    current_step_label="${current_step_label:-Unknown}"
    current_step_mode=$(extract_hidden_mode "${body_file}" || true)
    current_step_mode="${current_step_mode:-Unknown}"
    log "Installer visible step after submit: ${current_step_label}"
    log "Installer mode marker after submit: ${current_step_mode}"

    if grep -qi 'Invalid request' "${body_file}"; then
      err "Installer rejected step ${step_index} as Invalid request."
      return 1
    fi
    if [ "${current_step_label}" = "${previous_step_label}" ] && [ "${current_step_mode}" = "${previous_step_mode}" ]; then
      err "Installer made no progress: still on step '${current_step_label}' (mode '${current_step_mode}') after POST ${step_index}."
      return 1
    fi

    current_url="${form_url}"
    previous_step_label="${current_step_label}"
    previous_step_mode="${current_step_mode}"
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
