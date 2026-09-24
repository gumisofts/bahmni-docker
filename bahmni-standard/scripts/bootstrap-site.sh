#!/bin/bash
# Post-install configuration for a Bahmni Standard site. Idempotent: safe to re-run at any time.
#
# Applies everything that the stock images leave unconfigured or with default passwords:
#   openmrs-accounts   admin login + service-account passwords from .env, rotate leftover stock passwords
#   openmrs-settings   PACS query configuration
#   db-auth            MySQL native password / Postgres md5 for the atomfeed console's legacy JDBC drivers
#   pacs               pacs-integration modality + order type (radiology orders -> dcm4chee worklist)
#   pacs-codes         'PACS Procedure Code' mappings for every radiology orderable
#   odoo               proxy_mode/list_db/master password, admin + emrsync passwords, sales shop + order types
#   openelis           admin + atomfeed passwords
#   dcm4chee           web console admin password
#   metabase           first-run setup + admin account
#
# Usage: scripts/bootstrap-site.sh [--only stage,stage] [--wait-timeout SECONDS]
set -o pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ONLY=""
WAIT_TIMEOUT=900
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) ONLY="$2"; shift 2 ;;
    --wait-timeout) WAIT_TIMEOUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

need docker curl python3 openssl
load_env
for v in OPENMRS_ADMIN_USER OPENMRS_ADMIN_PASSWORD OPENMRS_ATOMFEED_USER OPENMRS_ATOMFEED_PASSWORD \
         REPORTS_OPENMRS_SERVICE_USER REPORTS_OPENMRS_SERVICE_PASSWORD MYSQL_ROOT_PASSWORD; do
  [[ -n "${!v:-}" ]] || die "$v is not set in $ENV_FILE"
done

FAILED=()
CHANGED=0
stage_wanted() { [[ -z "$ONLY" || ",$ONLY," == *",$1,"* ]]; }
fail_stage() { warn "$*"; FAILED+=("$1"); }

# Stock Bahmni passwords. Writing them into a site that already has real ones would be a downgrade,
# so a stage refuses to run while its credentials still carry the template value (install.sh replaces them all).
declare -A STOCK_PASSWORDS=(
  [OPENMRS_ADMIN_PASSWORD]=Admin123 [OPENMRS_ATOMFEED_PASSWORD]=Admin123 [REPORTS_OPENMRS_SERVICE_PASSWORD]=Admin123
  [OPENELIS_ADMIN_PASSWORD]='adminADMIN!' [OPENELIS_ATOMFEED_PASSWORD]='AdminadMIN*'
  [ODOO_ADMIN_PASSWORD]=admin [ODOO_ATOMFEED_PASSWORD]=Admin123 [ODOO_MASTER_PASSWORD]=admin
  [DCM4CHEE_ADMIN_PASSWORD]=admin
)
real_passwords() { # STAGE VAR... -> 0 when every VAR is set and differs from its stock value
  local stage="$1" v bad=(); shift
  for v in "$@"; do
    [[ -z "${!v:-}" || "${!v}" == "${STOCK_PASSWORDS[$v]:-}" ]] && bad+=("$v")
  done
  [[ ${#bad[@]} == 0 ]] && return 0
  fail_stage "$stage" "${bad[*]} still empty or at the stock default in $ENV_FILE - set real values first"
  return 1
}

# ---------------------------------------------------------------------------------------------
# OpenMRS
# ---------------------------------------------------------------------------------------------
wait_openmrs() {
  wait_for_http "OpenMRS" "$OPENMRS_URL/ws/rest/v1/session" '^200$' "$WAIT_TIMEOUT"
}

clear_openmrs_lockouts() {
  mysql_root openmrsdb "$OPENMRS_DB_NAME" \
    "DELETE FROM user_property WHERE property IN ('lockoutTimestamp','loginAttempts');" >/dev/null 2>&1 || true
}

# omrs_user_uuid ADMIN_USER ADMIN_PASS LOGIN -> uuid of the user whose username or systemId equals LOGIN
omrs_user_uuid() {
  omrs "$1" "$2" GET "/user?q=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$3")&v=custom:(uuid,username,systemId)" |
    python3 -c '
import json, sys
login = sys.argv[1]
for u in json.load(sys.stdin).get("results", []):
    if login in (u.get("username"), u.get("systemId")):
        print(u["uuid"]); break' "$3"
}

# set_openmrs_password ADMIN_USER ADMIN_PASS LOGIN NEW_PASSWORD LABEL
set_openmrs_password() {
  local au="$1" ap="$2" login="$3" pw="$4" label="$5" uuid
  if omrs_auth_ok "$login" "$pw"; then ok "OpenMRS $label '$login' password is set"; return 0; fi
  uuid="$(omrs_user_uuid "$au" "$ap" "$login")"
  [[ -n "$uuid" ]] || { fail_stage openmrs-accounts "OpenMRS user '$login' not found"; return 1; }
  omrs "$au" "$ap" POST "/password/$uuid" "{\"newPassword\":\"$pw\"}" >/dev/null
  [[ "$OMRS_CODE" == 200 ]] || { fail_stage openmrs-accounts "setting password for '$login' failed (HTTP $OMRS_CODE)"; return 1; }
  clear_openmrs_lockouts
  omrs_auth_ok "$login" "$pw" || { fail_stage openmrs-accounts "'$login' cannot log in after password change"; return 1; }
  chg "OpenMRS $label '$login' password set"; CHANGED=$((CHANGED + 1))
}

stage_openmrs_accounts() {
  real_passwords openmrs-accounts OPENMRS_ADMIN_PASSWORD OPENMRS_ATOMFEED_PASSWORD REPORTS_OPENMRS_SERVICE_PASSWORD || return
  wait_openmrs || { fail_stage openmrs-accounts "OpenMRS did not come up"; return; }
  clear_openmrs_lockouts
  local uuid stock_user=superman stock_pw=Admin123
  if omrs_auth_ok "$OPENMRS_ADMIN_USER" "$OPENMRS_ADMIN_PASSWORD"; then
    ok "OpenMRS admin login '$OPENMRS_ADMIN_USER' works"
  elif omrs_auth_ok "$stock_user" "$stock_pw"; then
    uuid="$(omrs_user_uuid "$stock_user" "$stock_pw" "$stock_user")"
    [[ -n "$uuid" ]] || { fail_stage openmrs-accounts "cannot resolve the '$stock_user' user"; return; }
    if [[ "$OPENMRS_ADMIN_USER" != "$stock_user" ]]; then
      omrs "$stock_user" "$stock_pw" POST "/user/$uuid" "{\"username\":\"$OPENMRS_ADMIN_USER\"}" >/dev/null
      [[ "$OMRS_CODE" == 200 ]] || { fail_stage openmrs-accounts "renaming '$stock_user' failed (HTTP $OMRS_CODE)"; return; }
    fi
    omrs "$OPENMRS_ADMIN_USER" "$stock_pw" POST "/password/$uuid" \
         "{\"oldPassword\":\"$stock_pw\",\"newPassword\":\"$OPENMRS_ADMIN_PASSWORD\"}" >/dev/null
    [[ "$OMRS_CODE" == 200 ]] || { fail_stage openmrs-accounts "setting the admin password failed (HTTP $OMRS_CODE)"; return; }
    clear_openmrs_lockouts
    omrs_auth_ok "$OPENMRS_ADMIN_USER" "$OPENMRS_ADMIN_PASSWORD" || { fail_stage openmrs-accounts "admin login broken after password change"; return; }
    chg "OpenMRS admin account is now '$OPENMRS_ADMIN_USER' with the configured password"; CHANGED=$((CHANGED + 1))
  else
    fail_stage openmrs-accounts "cannot log in to OpenMRS as '$OPENMRS_ADMIN_USER' nor as stock '$stock_user' - fix OPENMRS_ADMIN_* in .env"
    return
  fi
  local au="$OPENMRS_ADMIN_USER" ap="$OPENMRS_ADMIN_PASSWORD"
  set_openmrs_password "$au" "$ap" "$OPENMRS_ATOMFEED_USER" "$OPENMRS_ATOMFEED_PASSWORD" "integration account"
  set_openmrs_password "$au" "$ap" "$REPORTS_OPENMRS_SERVICE_USER" "$REPORTS_OPENMRS_SERVICE_PASSWORD" "reports account"

  # Any other account that still accepts the stock password gets a random one.
  local managed=" $au $OPENMRS_ATOMFEED_USER $REPORTS_OPENMRS_SERVICE_USER daemon "
  while IFS=$'\t' read -r uuid login retired; do
    [[ -z "$login" || "$retired" == "True" || "$managed" == *" $login "* ]] && continue
    if omrs_auth_ok "$login" "$stock_pw"; then
      omrs "$au" "$ap" POST "/password/$uuid" "{\"newPassword\":\"$(rand_password 24)\"}" >/dev/null
      [[ "$OMRS_CODE" == 200 ]] && { chg "OpenMRS user '$login' still had the stock password - replaced with a random one"; CHANGED=$((CHANGED + 1)); } \
                                || fail_stage openmrs-accounts "could not rotate stock password of '$login' (HTTP $OMRS_CODE)"
    fi
  done < <(omrs "$au" "$ap" GET "/user?v=custom:(uuid,username,systemId,retired)&limit=200" |
           python3 -c '
import json, sys
for u in json.load(sys.stdin).get("results", []):
    print("\t".join([u["uuid"], u.get("username") or u.get("systemId") or "", str(u.get("retired"))]))')
  clear_openmrs_lockouts
}

stage_openmrs_settings() {
  wait_openmrs || { fail_stage openmrs-settings "OpenMRS did not come up"; return; }
  local want="DCM4CHEE@dcm4chee:11112" au="$OPENMRS_ADMIN_USER" ap="$OPENMRS_ADMIN_PASSWORD" row uuid cur
  row="$(omrs "$au" "$ap" GET "/systemsetting?q=pacsquery.pacsConfig&v=custom:(uuid,property,value)" |
         python3 -c '
import json, sys
for s in json.load(sys.stdin).get("results", []):
    if s["property"] == "pacsquery.pacsConfig":
        print(s["uuid"] + "\t" + (s.get("value") or "")); break')"
  uuid="${row%%$'\t'*}"; cur="${row#*$'\t'}"
  [[ -n "$uuid" ]] || { fail_stage openmrs-settings "global property pacsquery.pacsConfig not found (PACS query module missing?)"; return; }
  if [[ "$cur" == "$want" ]]; then ok "OpenMRS pacsquery.pacsConfig = $want"; return; fi
  omrs "$au" "$ap" POST "/systemsetting/$uuid" "{\"value\":\"$want\"}" >/dev/null
  [[ "$OMRS_CODE" == 200 ]] && { chg "OpenMRS pacsquery.pacsConfig set to $want"; CHANGED=$((CHANGED + 1)); } \
                            || fail_stage openmrs-settings "could not set pacsquery.pacsConfig (HTTP $OMRS_CODE)"
}

# ---------------------------------------------------------------------------------------------
# Database authentication for the atomfeed console (MySQL Connector 5.1 / PostgreSQL JDBC 9.4)
# ---------------------------------------------------------------------------------------------
ensure_mysql_native_password() { # USER PASSWORD
  local plugin
  plugin="$(mysql_root openmrsdb mysql "SELECT plugin FROM mysql.user WHERE user='$1' AND host='%';")" || { fail_stage db-auth "cannot query mysql.user"; return; }
  [[ "$plugin" == mysql_native_password ]] && { ok "MySQL user '$1' uses mysql_native_password"; return; }
  mysql_root openmrsdb mysql "ALTER USER '$1'@'%' IDENTIFIED WITH mysql_native_password BY '$2';" >/dev/null \
    && { chg "MySQL user '$1' switched to mysql_native_password"; CHANGED=$((CHANGED + 1)); RESTART_CONSOLE=1; } \
    || fail_stage db-auth "ALTER USER '$1' failed"
}

ensure_pg_md5() { # SERVICE SUPERUSER ROLE PASSWORD
  local svc="$1" su="$2" role="$3" pw="$4" hba stored
  hba="$(compose exec -T "$svc" sh -c 'cat "$PGDATA/pg_hba.conf"' 2>/dev/null)" || { fail_stage db-auth "cannot read pg_hba.conf in $svc"; return; }
  if grep -q scram-sha-256 <<<"$hba"; then
    compose exec -T "$svc" sh -c 'sed -i "s/scram-sha-256/md5/g" "$PGDATA/pg_hba.conf"' \
      && psql_c "$svc" "$su" postgres "SELECT pg_reload_conf();" >/dev/null \
      && { chg "$svc: pg_hba.conf switched from scram-sha-256 to md5"; CHANGED=$((CHANGED + 1)); RESTART_CONSOLE=1; } \
      || { fail_stage db-auth "$svc: could not update pg_hba.conf"; return; }
  fi
  stored="$(psql_c "$svc" "$su" postgres "SELECT left(rolpassword,3) FROM pg_authid WHERE rolname='$role';")" || { fail_stage db-auth "$svc: cannot read pg_authid"; return; }
  if [[ "$stored" == md5 ]]; then ok "$svc: role '$role' password stored as md5"; return; fi
  psql_c "$svc" "$su" postgres "SET password_encryption='md5'; ALTER ROLE \"$role\" PASSWORD '$pw';" >/dev/null \
    && { chg "$svc: role '$role' password re-stored as md5"; CHANGED=$((CHANGED + 1)); RESTART_CONSOLE=1; } \
    || fail_stage db-auth "$svc: ALTER ROLE $role failed"
}

stage_db_auth() {
  RESTART_CONSOLE=0
  wait_for_mysql openmrsdb "$WAIT_TIMEOUT" || { fail_stage db-auth "openmrsdb not ready"; return; }
  ensure_mysql_native_password "$OPENMRS_DB_USERNAME" "$OPENMRS_DB_PASSWORD"
  if service_enabled odoodb; then
    wait_for_postgres odoodb "$ODOO_DB_USER" "$WAIT_TIMEOUT" && ensure_pg_md5 odoodb "$ODOO_DB_USER" "$ODOO_DB_USER" "$ODOO_DB_PASSWORD"
  fi
  if service_enabled openelisdb; then
    wait_for_postgres openelisdb "$OPENELIS_DB_USER" "$WAIT_TIMEOUT" && ensure_pg_md5 openelisdb "$OPENELIS_DB_USER" "$OPENELIS_DB_USER" "$OPENELIS_DB_PASSWORD"
  fi
  if service_enabled pacsdb; then
    wait_for_postgres pacsdb postgres "$WAIT_TIMEOUT" && ensure_pg_md5 pacsdb postgres "$PACS_INTEGRATION_DB_USERNAME" "$PACS_INTEGRATION_DB_PASSWORD"
  fi
  if [[ "$RESTART_CONSOLE" == 1 ]] && service_enabled atomfeed-console; then
    compose restart atomfeed-console >/dev/null 2>&1 && log "atomfeed-console restarted to pick up the new DB authentication"
  fi
}

# ---------------------------------------------------------------------------------------------
# PACS
# ---------------------------------------------------------------------------------------------
stage_pacs() {
  service_enabled pacs-integration || { ok "pacs-integration not enabled - skipped"; return; }
  wait_for_postgres pacsdb postgres "$WAIT_TIMEOUT" || { fail_stage pacs "pacsdb not ready"; return; }
  local start=$SECONDS q="psql_c pacsdb $PACS_INTEGRATION_DB_USERNAME $PACS_INTEGRATION_DB_NAME"
  log "waiting for pacs-integration schema ..."
  until [[ "$($q "SELECT count(*) FROM information_schema.tables WHERE table_name IN ('modality','order_type');" 2>/dev/null)" == 2 ]]; do
    (( SECONDS - start >= WAIT_TIMEOUT )) && { fail_stage pacs "pacs-integration never created its tables"; return; }
    sleep 5
  done
  local before after
  before="$($q "SELECT (SELECT count(*) FROM modality WHERE name='dcm4chee') + (SELECT count(*) FROM order_type WHERE name='Radiology Order');")"
  $q "INSERT INTO modality (name, description, ip, port, timeout)
        SELECT 'dcm4chee', 'dcm4chee PACS (HL7 MWL)', 'dcm4chee', 2575, 20000
        WHERE NOT EXISTS (SELECT 1 FROM modality WHERE name = 'dcm4chee');
      INSERT INTO order_type (name, modality_id)
        SELECT 'Radiology Order', m.id FROM modality m
        WHERE m.name = 'dcm4chee' AND NOT EXISTS (SELECT 1 FROM order_type WHERE name = 'Radiology Order');" >/dev/null \
    || { fail_stage pacs "seeding pacs_integration modality/order_type failed"; return; }
  after="$($q "SELECT (SELECT count(*) FROM modality WHERE name='dcm4chee') + (SELECT count(*) FROM order_type WHERE name='Radiology Order');")"
  if [[ "$before" == 2 ]]; then ok "pacs-integration: dcm4chee modality + 'Radiology Order' type present"
  elif [[ "$after" == 2 ]]; then chg "pacs-integration: seeded dcm4chee modality + 'Radiology Order' type"; CHANGED=$((CHANGED + 1))
  else fail_stage pacs "pacs-integration seed incomplete ($after/2 rows)"; fi
}

stage_pacs_codes() {
  service_enabled pacs-integration || { ok "pacs-integration not enabled - skipped"; return; }
  wait_openmrs || { fail_stage pacs-codes "OpenMRS did not come up"; return; }
  local out
  if out="$(OPENMRS_URL="$OPENMRS_URL" OPENMRS_USER="$OPENMRS_ADMIN_USER" OPENMRS_PASSWORD="$OPENMRS_ADMIN_PASSWORD" \
            python3 "$COMPOSE_DIR/scripts/add_pacs_procedure_codes.py" 2>&1)"; then
    if grep -qE 'done: [1-9][0-9]* added' <<<"$out"; then chg "PACS procedure codes: $(tail -1 <<<"$out")"; CHANGED=$((CHANGED + 1))
    else ok "PACS procedure codes: $(tail -1 <<<"$out")"; fi
  else
    fail_stage pacs-codes "add_pacs_procedure_codes.py failed: $(tail -3 <<<"$out" | tr '\n' ' ')"
  fi
}

# ---------------------------------------------------------------------------------------------
# Odoo
# ---------------------------------------------------------------------------------------------
odoo_conf_get() { compose exec -T odoo sh -c "sed -n 's/^$1 *= *//p' /etc/odoo/odoo.conf" 2>/dev/null | tr -d '\r'; }

odoo_conf_set() { # KEY VALUE -> returns 0 if changed
  [[ "$(odoo_conf_get "$1")" == "$2" ]] && return 1
  compose exec -T odoo sh -c "f=/etc/odoo/odoo.conf; if grep -qE '^$1 *=' \$f; then sed -i 's|^$1 *=.*|$1 = $2|' \$f; else sed -i '/^\[options\]/a $1 = $2' \$f; fi"
}

stage_odoo() {
  service_enabled odoo || { ok "odoo not enabled - skipped"; return; }
  real_passwords odoo ODOO_ADMIN_PASSWORD ODOO_ATOMFEED_PASSWORD ODOO_MASTER_PASSWORD || return
  local url="http://127.0.0.1:${ODOO_HOST_PORT}" restart=0 k owner
  # The filestore volume is created root-owned (odoodb mounts it first, the odoo image has no such
  # directory), so Odoo's first start dies with PermissionError until it is handed to the odoo user.
  owner="$(compose exec -T -u root odoo stat -c %U /var/lib/odoo/filestore 2>/dev/null | tr -d '\r')"
  if [[ -n "$owner" && "$owner" != odoo ]]; then
    compose exec -T -u root odoo chown -R odoo:odoo /var/lib/odoo/filestore && compose restart odoo >/dev/null 2>&1 \
      && { chg "odoo: filestore volume was owned by $owner - handed to odoo and Odoo restarted"; CHANGED=$((CHANGED + 1)); sleep 10; } \
      || { fail_stage odoo "could not fix the filestore volume ownership"; return; }
  fi
  wait_for_http "Odoo" "$url/web/login" '^200$' "$WAIT_TIMEOUT" || { fail_stage odoo "Odoo did not come up"; return; }
  for k in "proxy_mode True" "list_db False" "admin_passwd $ODOO_MASTER_PASSWORD"; do
    # shellcheck disable=SC2086
    if odoo_conf_set $k; then chg "odoo.conf: ${k%% *} updated"; CHANGED=$((CHANGED + 1)); restart=1; fi
  done
  if [[ "$restart" == 1 ]]; then
    log "restarting Odoo to apply odoo.conf (this takes a few minutes) ..."
    compose restart odoo >/dev/null 2>&1
    sleep 15
    wait_for_http "Odoo" "$url/web/login" '^200$' "$WAIT_TIMEOUT" || { fail_stage odoo "Odoo did not come back after restart"; return; }
  else
    ok "odoo.conf: proxy_mode, list_db and admin_passwd are set"
  fi
  local out
  if out="$(ODOO_URL="$url" ODOO_DB="$ODOO_DB_NAME" ODOO_ADMIN_PASSWORD="$ODOO_ADMIN_PASSWORD" \
            ODOO_ATOMFEED_USER="$ODOO_ATOMFEED_USER" ODOO_ATOMFEED_PASSWORD="$ODOO_ATOMFEED_PASSWORD" \
            python3 "$COMPOSE_DIR/scripts/odoo_bootstrap.py" 2>&1)"; then
    sed 's/^/  /' <<<"$out"
    grep -q '^\[DONE\]' <<<"$out" && CHANGED=$((CHANGED + 1))
  else
    sed 's/^/  /' <<<"$out"
    fail_stage odoo "odoo_bootstrap.py failed"
  fi
}

# ---------------------------------------------------------------------------------------------
# OpenELIS
# ---------------------------------------------------------------------------------------------
elis_login_ok() { # USER PASSWORD - the feed endpoint answers 200 only with a valid session
  local jar; jar="$(mktemp)"
  curl -sk -o /dev/null -c "$jar" --max-time 30 --data-urlencode "loginName=$1" --data-urlencode "password=$2" \
       "https://127.0.0.1:${PROXY_HTTPS_PORT}/openelis/ValidateLogin.do"
  local code; code="$(http_code "https://127.0.0.1:${PROXY_HTTPS_PORT}/openelis/ws/feed/patient/recent" -b "$jar")"
  rm -f "$jar"
  [[ "$code" == 200 ]]
}

set_elis_password() { # LOGIN PASSWORD
  if elis_login_ok "$1" "$2"; then ok "OpenELIS '$1' password is set"; return; fi
  local enc
  enc="$(compose exec -T openelis java -cp /run/bahmni-lab/bahmni-lab/WEB-INF/lib/crypto.jar phl.util.Crypto encStr "$2" 2>/dev/null |
         sed -n 's/^Encrypted string is: //p' | tr -d '\r')"
  [[ -n "$enc" ]] || { fail_stage openelis "could not encrypt the OpenELIS password for '$1'"; return; }
  local n
  n="$(psql_c openelisdb "$OPENELIS_DB_USER" "$OPENELIS_DB_NAME" \
       "UPDATE clinlims.login_user SET password='$enc', password_expired_dt='2099-12-31', account_locked='N', account_disabled='N' WHERE login_name='$1' RETURNING 1;" | grep -c 1)"
  [[ "$n" -ge 1 ]] || { fail_stage openelis "OpenELIS user '$1' not found"; return; }
  elis_login_ok "$1" "$2" && { chg "OpenELIS '$1' password set"; CHANGED=$((CHANGED + 1)); } \
                          || fail_stage openelis "OpenELIS '$1' cannot log in after the password change"
}

stage_openelis() {
  service_enabled openelis || { ok "openelis not enabled - skipped"; return; }
  real_passwords openelis OPENELIS_ADMIN_PASSWORD OPENELIS_ATOMFEED_PASSWORD || return
  wait_for_http "OpenELIS" "https://127.0.0.1:${PROXY_HTTPS_PORT}/openelis/LoginPage.do" '^200$' "$WAIT_TIMEOUT" || { fail_stage openelis "OpenELIS did not come up"; return; }
  local start=$SECONDS
  until [[ "$(psql_c openelisdb "$OPENELIS_DB_USER" "$OPENELIS_DB_NAME" "SELECT count(*) FROM clinlims.login_user WHERE login_name IN ('admin','$OPENELIS_ATOMFEED_USER');" 2>/dev/null)" == 2 ]]; do
    (( SECONDS - start >= WAIT_TIMEOUT )) && { fail_stage openelis "OpenELIS users were never created"; return; }
    sleep 5
  done
  set_elis_password admin "$OPENELIS_ADMIN_PASSWORD"
  set_elis_password "$OPENELIS_ATOMFEED_USER" "$OPENELIS_ATOMFEED_PASSWORD"
}

# ---------------------------------------------------------------------------------------------
# dcm4chee (web console login; the PACS itself is not password protected on the DICOM port)
# ---------------------------------------------------------------------------------------------
stage_dcm4chee() {
  service_enabled dcm4chee || { ok "dcm4chee not enabled - skipped"; return; }
  real_passwords dcm4chee DCM4CHEE_ADMIN_PASSWORD || return
  wait_for_postgres pacsdb postgres "$WAIT_TIMEOUT" || { fail_stage dcm4chee "pacsdb not ready"; return; }
  local q="psql_c pacsdb $DCM4CHEE_DB_USERNAME $DCM4CHEE_DB_NAME" start=$SECONDS want stored
  log "waiting for dcm4chee schema ..."
  until [[ "$($q "SELECT count(*) FROM users WHERE user_id='admin';" 2>/dev/null)" == 1 ]]; do
    (( SECONDS - start >= WAIT_TIMEOUT )) && { fail_stage dcm4chee "dcm4chee never created its admin user"; return; }
    sleep 5
  done
  want="$(printf '%s' "$DCM4CHEE_ADMIN_PASSWORD" | openssl dgst -sha1 -binary | base64)"
  stored="$($q "SELECT passwd FROM users WHERE user_id='admin';")"
  if [[ "$stored" == "$want" ]]; then ok "dcm4chee admin password is set"
  else
    if [[ "$stored" != "$(printf '%s' admin | openssl dgst -sha1 -binary | base64)" ]]; then
      warn "dcm4chee admin password is neither the stock one nor the configured one - overwriting it"
    fi
    $q "UPDATE users SET passwd='$want' WHERE user_id='admin';" >/dev/null \
      && { chg "dcm4chee admin password set"; CHANGED=$((CHANGED + 1)); } \
      || fail_stage dcm4chee "could not update the dcm4chee admin password"
  fi
  # other stock accounts whose password equals their user name (e.g. user/user) get a random password
  while IFS='|' read -r uid pw; do
    [[ -z "$uid" || "$uid" == admin ]] && continue
    if [[ "$pw" == "$(printf '%s' "$uid" | openssl dgst -sha1 -binary | base64)" ]]; then
      $q "UPDATE users SET passwd='$(printf '%s' "$(rand_password 24)" | openssl dgst -sha1 -binary | base64)' WHERE user_id='$uid';" >/dev/null \
        && { chg "dcm4chee account '$uid' still had password '$uid' - replaced with a random one"; CHANGED=$((CHANGED + 1)); }
    fi
  done < <($q "SELECT user_id, passwd FROM users;")
}

# ---------------------------------------------------------------------------------------------
# Metabase
# ---------------------------------------------------------------------------------------------
stage_metabase() {
  service_enabled metabase || { ok "metabase not enabled - skipped"; return; }
  local base="https://127.0.0.1:${PROXY_HTTPS_PORT}/metabase/api" start=$SECONDS setup code
  wait_for_http "Metabase" "$base/health" '^200$' "$WAIT_TIMEOUT" || { fail_stage metabase "Metabase did not come up"; return; }
  setup="$(curl -sk --max-time 20 "$base/session/properties" | jget 'has-user-setup')"
  if [[ "$setup" != "True" ]]; then
    log "running Metabase first-time setup ..."
    compose exec -T metabase bash /app/scripts/metabase/metabase_init.sh >/dev/null 2>&1 || true
    until [[ "$(curl -sk --max-time 20 "$base/session/properties" | jget 'has-user-setup')" == "True" ]]; do
      (( SECONDS - start >= 300 )) && { fail_stage metabase "Metabase setup did not complete"; return; }
      sleep 5
    done
    chg "Metabase initial setup completed"; CHANGED=$((CHANGED + 1))
  fi
  code="$(http_code "$base/session" -H 'Content-Type: application/json' \
          -d "{\"username\":\"$METABASE_ADMIN_EMAIL\",\"password\":\"$METABASE_ADMIN_PASSWORD\"}")"
  [[ "$code" == 200 ]] && ok "Metabase admin '$METABASE_ADMIN_EMAIL' can log in" \
                       || fail_stage metabase "Metabase admin login failed (HTTP $code) - METABASE_ADMIN_PASSWORD differs from the one used at first setup"
}

# ---------------------------------------------------------------------------------------------
STAGES=(openmrs-accounts openmrs-settings db-auth pacs pacs-codes odoo openelis dcm4chee metabase)
for s in "${STAGES[@]}"; do
  stage_wanted "$s" || continue
  echo "== $s"
  "stage_${s//-/_}"
done

echo
if [[ ${#FAILED[@]} -gt 0 ]]; then
  die "bootstrap finished with failures in: $(printf '%s ' "${FAILED[@]}" | xargs -n1 | sort -u | tr '\n' ' ')"
fi
ok "bootstrap complete ($CHANGED change(s) applied)"
