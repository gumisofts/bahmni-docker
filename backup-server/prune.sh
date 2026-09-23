#!/bin/bash
# Retention, integrity checks and status for every enrolled site (runs daily from cron, as root).
#
#   backup-server/prune.sh            apply retention (KEEP_* from /etc/bahmni-backup/server.env); on Sundays also verify repositories
#   backup-server/prune.sh --status   show last snapshot per site and warn when a site has not backed up for 36 h
#   backup-server/prune.sh --check    verify all repositories now
#
# Retention runs here, not on the hospitals: their credentials are append-only so a compromised
# hospital server cannot destroy its own history.
set -o pipefail
CONF_DIR=/etc/bahmni-backup
RESTIC_IMAGE="${RESTIC_IMAGE:-restic/restic:0.18.1}"
MODE=prune
case "${1:-}" in --status) MODE=status ;; --check) MODE=check ;; -h|--help) sed -n '2,10p' "$0"; exit 0 ;; esac
die() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
[[ "$(id -u)" == 0 ]] || die "run as root"
[[ -f "$CONF_DIR/server.env" ]] || die "run backup-server/setup.sh first"
# shellcheck disable=SC1091
. "$CONF_DIR/server.env"
KEEP_DAILY="${KEEP_DAILY:-7}"; KEEP_WEEKLY="${KEEP_WEEKLY:-4}"; KEEP_MONTHLY="${KEEP_MONTHLY:-12}"

restic() { # SITE args...
  local site="$1"; shift
  docker run --rm -v "$DATA_DIR/$site:/repo" -v "$CONF_DIR/keys/$site.key:/key:ro" \
    -e RESTIC_CACHE_DIR=/cache -v bahmni-backup-prune-cache:/cache \
    "$RESTIC_IMAGE" -r /repo --password-file /key "$@"
}

echo "=== $(date -Iseconds) $MODE"
rc=0
for f in "$CONF_DIR"/sites/*.env; do
  [[ -f "$f" ]] || { echo "no sites enrolled yet"; break; }
  site="$(basename "$f" .env)"
  if [[ ! -f "$DATA_DIR/$site/config" ]]; then echo "$site: repository not initialised yet (site never ran backup_to_cloud.sh --init)"; continue; fi
  latest="$(restic "$site" snapshots --latest 1 --json 2>/dev/null | python3 -c 'import json,sys,datetime
s=json.load(sys.stdin)
if not s: print("none 0"); raise SystemExit
t=datetime.datetime.fromisoformat(s[0]["time"].replace("Z","+00:00"))
age=(datetime.datetime.now(datetime.timezone.utc)-t).total_seconds()/3600
print(t.astimezone().strftime("%Y-%m-%d %H:%M"), f"{age:.0f}", ",".join(s[0].get("tags") or []))')"
  read -r when age tags <<<"$latest"
  size="$(du -sh "$DATA_DIR/$site" 2>/dev/null | cut -f1)"
  flag=""; (( ${age:-0} > 36 )) && { flag="  <-- WARNING: no backup for ${age}h"; rc=1; }
  [[ "$tags" == *incomplete* ]] && { flag="$flag  <-- last backup INCOMPLETE"; rc=1; }
  printf '%-20s last snapshot %s (%sh ago)  repo %s%s\n' "$site" "$when" "$age" "$size" "$flag"
  case "$MODE" in
    prune)
      restic "$site" forget --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" --keep-monthly "$KEEP_MONTHLY" --prune 2>&1 | grep -E 'snapshots have been removed|to delete|remaining|error|Error' | sed "s/^/    /"
      if [[ "$(date +%u)" == 7 ]]; then
        restic "$site" check --read-data-subset=5% 2>&1 | tail -2 | sed "s/^/    /" || rc=1
      fi ;;
    check)
      restic "$site" check --read-data-subset=5% 2>&1 | tail -2 | sed "s/^/    /" || rc=1 ;;
  esac
done
exit $rc
