#!/bin/bash
# Restore a whole Bahmni Standard site from the off-site restic repository (disaster recovery).
#
#   scripts/restore_from_cloud.sh --list                 show available snapshots
#   scripts/restore_from_cloud.sh [--snapshot ID] [--yes] restore latest (or ID) into THIS installation
#
# Prerequisites: a fresh install (scripts/install.sh) using the SAME .env secrets as the site that
# was backed up, or the original server. Everything currently in this installation is replaced:
# all databases are dropped and re-created from the dumps, all data volumes are overwritten.
set -o pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAP=latest; YES=0; LIST=0; WAIT=1200
while [[ $# -gt 0 ]]; do
  case "$1" in
    --snapshot) SNAP="$2"; shift 2 ;;
    --list) LIST=1; shift ;;
    --yes) YES=1; shift ;;
    --wait-timeout) WAIT="$2"; shift 2 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

need docker python3 curl
load_env
[[ -n "${BACKUP_REPOSITORY:-}" && -n "${BACKUP_PASSWORD:-}" ]] || die "BACKUP_REPOSITORY / BACKUP_PASSWORD are empty in $ENV_FILE"
STAGE="$COMPOSE_DIR/backup-artifacts/latest"
mkdir -p "$STAGE"
restic() { compose run --rm -T backup "$@"; }

if [[ "$LIST" == 1 ]]; then restic snapshots --group-by host; exit 0; fi

info="$(restic snapshots "$SNAP" --json 2>/dev/null)" || die "cannot read the repository"
[[ "$(jget '0.short_id' <<<"$info")" != "" ]] || die "snapshot '$SNAP' not found (use --list)"
SNAP_ID="$(jget '0.short_id' <<<"$info")"
cat <<EOF

Snapshot to restore : $SNAP_ID  taken $(jget '0.time' <<<"$info")  from host '$(jget '0.hostname' <<<"$info")'  tags $(jget '0.tags' <<<"$info")
Target installation : $(compose config --format json 2>/dev/null | jget name) in $COMPOSE_DIR

  !! Every database and data volume of the target installation will be REPLACED. !!
EOF
if [[ "$YES" != 1 ]]; then read -r -p "Type 'restore' to continue: " a; [[ "$a" == restore ]] || exit 1; fi
START=$SECONDS

# --- 1. stop the applications, keep only the databases ------------------------------------------
log "stopping all services ..."
compose stop >/dev/null 2>&1
DBS=()
for s in openmrsdb reportsdb openelisdb odoodb pacsdb metabasedb; do service_enabled "$s" && DBS+=("$s"); done
log "starting databases: ${DBS[*]}"
compose up -d --no-deps "${DBS[@]}" 2>&1 | grep -vE 'obsolete' || true
for s in "${DBS[@]}"; do
  case "$s" in
    openmrsdb|reportsdb) wait_for_mysql "$s" 300 || die "$s did not start" ;;
    openelisdb) wait_for_postgres "$s" "$OPENELIS_DB_USER" 300 || die "$s did not start" ;;
    odoodb) wait_for_postgres "$s" "$ODOO_DB_USER" 300 || die "$s did not start" ;;
    pacsdb) wait_for_postgres "$s" postgres 300 || die "$s did not start" ;;
    metabasedb) wait_for_postgres "$s" "$METABASE_DB_USER" 300 || die "$s did not start" ;;
  esac
done

# --- 2. fetch the dumps -------------------------------------------------------------------------
log "restoring database dumps from snapshot $SNAP_ID ..."
rm -f "$STAGE"/*.sql "$STAGE"/manifest.json
restic restore "$SNAP_ID" --target / --include /data/db-dumps/latest >/dev/null || die "restic restore of the dumps failed"
[[ -f "$STAGE/manifest.json" ]] || die "snapshot has no manifest.json - not a backup made by backup_to_cloud.sh"
python3 - "$STAGE/manifest.json" <<'EOF'
import json, sys
m = json.load(open(sys.argv[1]))
print(f"  backup made {m['created']} on '{m['hostname']}' (site {m['site']}, complete={m['complete']})")
for k, v in m["dumps"].items():
    print(f"  {k:22s} {v/1048576:8.1f} MiB")
EOF

# --- 3. load the dumps --------------------------------------------------------------------------
ERRORS=0
load_mysql() { # SERVICE FILE
  [[ -f "$STAGE/$2" ]] || { warn "$2 missing in the backup - skipped"; return; }
  log "loading $2 into $1 ..."
  if compose exec -T -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$1" mysql -uroot <"$STAGE/$2"; then ok "$2 loaded"
  else warn "$2 FAILED to load"; ERRORS=$((ERRORS + 1)); fi
}
load_postgres() { # SERVICE SUPERUSER DB FILE
  [[ -f "$STAGE/$4" ]] || { warn "$4 missing in the backup - skipped"; return; }
  log "loading $4 into $1 ..."
  psql_c "$1" "$2" postgres "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$3' AND pid <> pg_backend_pid();" >/dev/null 2>&1
  local err; err="$(mktemp)"
  compose exec -T "$1" psql -q -U "$2" -d postgres -f - <"$STAGE/$4" 2>"$err" >/dev/null
  local n; n="$(grep -c '^ERROR' "$err")"
  if [[ "$n" == 0 ]]; then ok "$4 loaded"
  else warn "$4 loaded with $n error(s):"; grep '^ERROR' "$err" | head -5 | sed 's/^/    /'; ERRORS=$((ERRORS + 1)); fi
  rm -f "$err"
}
for s in "${DBS[@]}"; do
  case "$s" in
    openmrsdb)  load_mysql openmrsdb openmrs.sql ;;
    reportsdb)  load_mysql reportsdb reports.sql ;;
    openelisdb) load_postgres openelisdb "$OPENELIS_DB_USER" "$OPENELIS_DB_NAME" openelis.sql ;;
    odoodb)     load_postgres odoodb "$ODOO_DB_USER" "$ODOO_DB_NAME" odoo.sql ;;
    pacsdb)     load_postgres pacsdb postgres "$DCM4CHEE_DB_NAME" dcm4chee.sql
                load_postgres pacsdb postgres "$PACS_INTEGRATION_DB_NAME" pacs_integration.sql ;;
    metabasedb) load_postgres metabasedb "$METABASE_DB_USER" "$METABASE_DB_NAME" metabase.sql ;;
  esac
done

# --- 4. data volumes ----------------------------------------------------------------------------
log "restoring data volumes (patient documents, images, DICOM archive, Odoo files, ...) ..."
out="$(restic restore "$SNAP_ID" --target / --include /data/volumes --delete 2>&1)"; rc=$?
grep -vE '^\s*$' <<<"$out" | tail -4 | sed 's/^/  /'
[[ $rc == 0 ]] || die "restic restore of the volumes failed"

# --- 5. start everything and re-apply site configuration ----------------------------------------
log "starting all services ..."
compose up -d 2>&1 | grep -vE 'obsolete' || true
"$COMPOSE_DIR/scripts/bootstrap-site.sh" --wait-timeout "$WAIT" || { warn "bootstrap reported failures - re-run scripts/bootstrap-site.sh"; ERRORS=$((ERRORS + 1)); }
omrs "$OPENMRS_ADMIN_USER" "$OPENMRS_ADMIN_PASSWORD" POST /searchindexupdate '{}' >/dev/null
[[ "$OMRS_CODE" =~ ^20[04]$ ]] && ok "OpenMRS patient search index rebuild started" || warn "could not trigger the OpenMRS search index rebuild (HTTP $OMRS_CODE); use Admin -> Search Index"

# --- 6. verify ----------------------------------------------------------------------------------
echo
log "verification (backup manifest vs restored data):"
verify() { # LABEL EXPECTED ACTUAL
  if [[ "$2" == n/a || -z "$2" ]]; then printf '  %-22s backup=%-8s restored=%s\n' "$1" "$2" "$3"
  elif [[ "$2" == "$3" ]]; then printf '  %-22s %s  match\n' "$1" "$3"
  else printf '  %-22s backup=%s restored=%s  MISMATCH\n' "$1" "$2" "$3"; ERRORS=$((ERRORS + 1)); fi
}
m_get() { jget "counts.$1" <"$STAGE/manifest.json"; }
verify "OpenMRS patients"  "$(m_get openmrs_patients)"  "$(mysql_root openmrsdb "$OPENMRS_DB_NAME" "SELECT count(*) FROM patient WHERE voided=0;" 2>/dev/null | tr -d '[:space:]')"
service_enabled openelisdb && verify "OpenELIS patients" "$(m_get openelis_patients)" "$(psql_c openelisdb "$OPENELIS_DB_USER" "$OPENELIS_DB_NAME" "SELECT count(*) FROM clinlims.patient;" 2>/dev/null | tr -d '[:space:]')"
service_enabled odoodb && verify "Odoo sale orders" "$(m_get odoo_sale_orders)" "$(psql_c odoodb "$ODOO_DB_USER" "$ODOO_DB_NAME" "SELECT count(*) FROM sale_order;" 2>/dev/null | tr -d '[:space:]')"
service_enabled pacsdb && verify "dcm4chee studies" "$(m_get dcm4chee_studies)" "$(psql_c pacsdb postgres "$DCM4CHEE_DB_NAME" "SELECT count(*) FROM study;" 2>/dev/null | tr -d '[:space:]')"
echo
if [[ "$ERRORS" == 0 ]]; then ok "RESTORE COMPLETE in $((SECONDS - START))s - log in and spot-check a few patients"
else die "restore finished with $ERRORS problem(s) after $((SECONDS - START))s - review the messages above"; fi
