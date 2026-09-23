#!/bin/bash
# Nightly off-site backup: dump every database, then push dumps + data volumes to the restic
# repository configured in .env (BACKUP_REPOSITORY / BACKUP_PASSWORD), deduplicated and encrypted.
#
#   scripts/backup_to_cloud.sh                 run a backup now
#   scripts/backup_to_cloud.sh --init          verify the repository (create it on first use)
#   scripts/backup_to_cloud.sh --check         show the latest snapshots in the repository
#   scripts/backup_to_cloud.sh --install-cron ["0 1 * * *"]   schedule the nightly run
#   scripts/backup_to_cloud.sh --dumps-only    only write the SQL dumps to backup-artifacts/latest
#
# Restore with scripts/restore_from_cloud.sh. Retention is applied on the backup server
# (backup-server/prune.sh), because the hospital's credentials are append-only by design.
set -o pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MODE=run; SCHEDULE="0 1 * * *"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --init) MODE=init; shift ;;
    --check) MODE=check; shift ;;
    --dumps-only) MODE=dumps; shift ;;
    --install-cron) MODE=cron; [[ -n "${2:-}" && "$2" != --* ]] && { SCHEDULE="$2"; shift; }; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

need docker python3
load_env
STAGE="$COMPOSE_DIR/backup-artifacts/latest"
LOG_DIR="$COMPOSE_DIR/backup-artifacts"
mkdir -p "$STAGE"

restic() { compose run --rm -T backup "$@"; }

require_repo_config() {
  [[ -n "${BACKUP_REPOSITORY:-}" && -n "${BACKUP_PASSWORD:-}" ]] \
    || die "BACKUP_REPOSITORY / BACKUP_PASSWORD are empty in $ENV_FILE - get them from backup-server/add_site.sh"
}

repo_preflight() { # fail fast on an unreachable/misconfigured rest: server instead of restic's 15-minute retry loop
  [[ "$BACKUP_REPOSITORY" == rest:* ]] || return 0
  local url="${BACKUP_REPOSITORY#rest:}" code
  code="$(compose run --rm -T --entrypoint sh backup -c 'wget -q -S -O /dev/null --timeout=15 "$0/config" 2>&1 | sed -n "s|.*HTTP/[0-9.]* \([0-9]*\).*|\1|p" | tail -1' "${url%/}" 2>/dev/null | tr -d '\r')"
  case "$code" in
    200|404) return 0 ;;
    401|403) die "the backup server rejected the credentials in BACKUP_REPOSITORY (HTTP $code)" ;;
    *) die "backup server unreachable at $(sed -E 's#//[^/@]*@#//#' <<<"$url") (HTTP ${code:-none}) - check the URL, DNS and firewall" ;;
  esac
}

ensure_repo() {
  repo_preflight
  if restic cat config >/dev/null 2>&1; then ok "repository reachable: $(sed -E 's#//[^/@]*@#//#' <<<"$BACKUP_REPOSITORY")"; return 0; fi
  log "repository not initialised yet - creating it"
  restic init >/dev/null || die "cannot initialise the repository (wrong BACKUP_PASSWORD, wrong URL, or the server is unreachable)"
  chg "repository created"
}

# --- database dumps ----------------------------------------------------------------------------
DUMP_OK=1
dump_mysql() { # SERVICE DB FILE
  local out="$STAGE/$3.tmp"
  if compose exec -T -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$1" mysqldump -uroot --single-transaction --routines --triggers --events \
       --no-tablespaces --set-gtid-purged=OFF --add-drop-database --databases "$2" >"$out" 2>"$out.err" \
     && tail -c 200 "$out" | grep -q 'Dump completed'; then
    mv "$out" "$STAGE/$3"; rm -f "$out.err"; ok "dumped $2 ($(du -h "$STAGE/$3" | cut -f1))"
  else
    warn "dump of $2 FAILED: $(head -c 300 "$out.err" 2>/dev/null)"; rm -f "$out"; DUMP_OK=0
  fi
}
dump_postgres() { # SERVICE SUPERUSER DB FILE
  local out="$STAGE/$4.tmp"
  if compose exec -T "$1" pg_dump -U "$2" -d "$3" --create --clean --if-exists >"$out" 2>"$out.err" \
     && tail -c 200 "$out" | grep -q 'database dump complete'; then
    mv "$out" "$STAGE/$4"; rm -f "$out.err"; ok "dumped $3 ($(du -h "$STAGE/$4" | cut -f1))"
  else
    warn "dump of $3 FAILED: $(head -c 300 "$out.err" 2>/dev/null)"; rm -f "$out"; DUMP_OK=0
  fi
}
dump_if_running() { # SERVICE then dump args
  local svc="$1"; shift
  if ! service_enabled "$svc"; then return; fi
  if ! service_running "$svc"; then warn "$svc is not running - its database was NOT dumped"; DUMP_OK=0; return; fi
  "$@"
}

count_or_na() { "$@" 2>/dev/null | tr -d '[:space:]' || echo "n/a"; }

write_dumps() {
  rm -f "$STAGE"/*.sql "$STAGE"/*.tmp "$STAGE"/*.err
  dump_if_running openmrsdb  dump_mysql openmrsdb "$OPENMRS_DB_NAME" openmrs.sql
  dump_if_running reportsdb  dump_mysql reportsdb "$REPORTS_DB_NAME" reports.sql
  dump_if_running openelisdb dump_postgres openelisdb "$OPENELIS_DB_USER" "$OPENELIS_DB_NAME" openelis.sql
  dump_if_running odoodb     dump_postgres odoodb "$ODOO_DB_USER" "$ODOO_DB_NAME" odoo.sql
  dump_if_running pacsdb     dump_postgres pacsdb postgres "$DCM4CHEE_DB_NAME" dcm4chee.sql
  dump_if_running pacsdb     dump_postgres pacsdb postgres "$PACS_INTEGRATION_DB_NAME" pacs_integration.sql
  dump_if_running metabasedb dump_postgres metabasedb "$METABASE_DB_USER" "$METABASE_DB_NAME" metabase.sql

  # Row counts let restore_from_cloud.sh prove the restored data matches what was backed up.
  local patients elis_patients orders studies
  patients="$(count_or_na mysql_root openmrsdb "$OPENMRS_DB_NAME" "SELECT count(*) FROM patient WHERE voided=0;")"
  elis_patients="$(count_or_na psql_c openelisdb "$OPENELIS_DB_USER" "$OPENELIS_DB_NAME" "SELECT count(*) FROM clinlims.patient;")"
  orders="$(count_or_na psql_c odoodb "$ODOO_DB_USER" "$ODOO_DB_NAME" "SELECT count(*) FROM sale_order;")"
  studies="$(count_or_na psql_c pacsdb postgres "$DCM4CHEE_DB_NAME" "SELECT count(*) FROM study;")"
  SITE="$BACKUP_SITE_NAME" PROJECT="$(compose config --format json 2>/dev/null | jget name)" STAGE="$STAGE" COMPLETE="$DUMP_OK" \
  PATIENTS="$patients" ELIS="$elis_patients" ORDERS="$orders" STUDIES="$studies" \
  GIT="$(git -C "$COMPOSE_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)" python3 - <<'EOF'
import datetime, json, os, socket
stage = os.environ["STAGE"]
dumps = {f: os.path.getsize(os.path.join(stage, f)) for f in sorted(os.listdir(stage)) if f.endswith(".sql")}
manifest = {
    "site": os.environ["SITE"] or socket.gethostname(),
    "hostname": socket.gethostname(),
    "compose_project": os.environ["PROJECT"],
    "git_commit": os.environ["GIT"],
    "created": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "complete": os.environ["COMPLETE"] == "1",
    "dumps": dumps,
    "counts": {"openmrs_patients": os.environ["PATIENTS"], "openelis_patients": os.environ["ELIS"],
               "odoo_sale_orders": os.environ["ORDERS"], "dcm4chee_studies": os.environ["STUDIES"]},
}
with open(os.path.join(stage, "manifest.json"), "w") as fh:
    json.dump(manifest, fh, indent=2)
print(f"manifest: {len(dumps)} dumps, patients={manifest['counts']['openmrs_patients']}, "
      f"lab patients={manifest['counts']['openelis_patients']}, sale orders={manifest['counts']['odoo_sale_orders']}, "
      f"studies={manifest['counts']['dcm4chee_studies']}")
EOF
}

# --- modes ------------------------------------------------------------------------------------
case "$MODE" in
  init)
    require_repo_config; ensure_repo ;;
  check)
    require_repo_config
    restic snapshots --latest 5 --group-by host ;;
  dumps)
    write_dumps ;;
  cron)
    require_repo_config
    owner="$(stat -c %U "$ENV_FILE")"
    line="cd $COMPOSE_DIR && ./scripts/backup_to_cloud.sh >> backup-artifacts/backup.log 2>&1"
    if [[ "$(id -u)" == 0 ]]; then
      printf 'SHELL=/bin/bash\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n%s %s %s\n' "$SCHEDULE" "$owner" "$line" >/etc/cron.d/bahmni-backup
      chmod 644 /etc/cron.d/bahmni-backup
      printf '%s/backup-artifacts/backup.log {\n  weekly\n  rotate 12\n  compress\n  missingok\n  notifempty\n}\n' "$COMPOSE_DIR" >/etc/logrotate.d/bahmni-backup
      chg "nightly backup scheduled in /etc/cron.d/bahmni-backup ($SCHEDULE, as $owner)"
    else
      ( crontab -l 2>/dev/null | grep -v 'backup_to_cloud.sh'; echo "$SCHEDULE $line" ) | crontab -
      chg "nightly backup scheduled in $(id -un)'s crontab ($SCHEDULE)"
    fi ;;
  run)
    require_repo_config
    exec 9>"$LOG_DIR/.backup.lock"
    flock -n 9 || die "another backup is still running"
    START=$SECONDS
    log "=== backup of site '${BACKUP_SITE_NAME:-$(hostname)}' started $(date -Iseconds)"
    ensure_repo
    write_dumps
    tag=complete; [[ "$DUMP_OK" == 1 ]] || tag=incomplete
    log "uploading to the repository ..."
    out="$(restic backup /data --host "${BACKUP_SITE_NAME:-$(hostname)}" --tag bahmni --tag "$tag" \
             --exclude '/data/db-dumps/*.log' --exclude '/data/db-dumps/.backup.lock' --exclude '/data/db-dumps/latest/*.tmp' 2>&1)"; rc=$?
    grep -vE '^\s*$|obsolete' <<<"$out" | sed 's/^/  /'
    [[ $rc == 0 ]] || die "restic backup FAILED after $((SECONDS - START))s"
    snap="$(restic snapshots --latest 1 --json 2>/dev/null | jget '0.short_id')"
    if [[ "$DUMP_OK" == 1 ]]; then
      ok "BACKUP OK snapshot=$snap duration=$((SECONDS - START))s"
    else
      warn "BACKUP INCOMPLETE snapshot=$snap duration=$((SECONDS - START))s - at least one database was not dumped (see above)"
      exit 1
    fi ;;
esac
