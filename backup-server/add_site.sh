#!/bin/bash
# Enrol a hospital (site) on the backup server and print the values for its bahmni-standard/.env.
#
#   sudo backup-server/add_site.sh <site-name> [--rotate]
#
# Creates the rest-server user, the repository key and stores both in /etc/bahmni-backup/sites/<site>.env.
# --rotate issues new credentials for an existing site (the old ones stop working; the data stays).
set -o pipefail
CONF_DIR=/etc/bahmni-backup
SITE="${1:-}"; ROTATE=0
[[ "${2:-}" == --rotate ]] && ROTATE=1
die() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
[[ "$(id -u)" == 0 ]] || die "run as root (sudo)"
[[ -f "$CONF_DIR/server.env" ]] || die "run backup-server/setup.sh first"
# shellcheck disable=SC1091
. "$CONF_DIR/server.env"
[[ "$SITE" =~ ^[a-z0-9][a-z0-9-]{1,40}$ ]] || die "usage: add_site.sh <site-name>   (lowercase letters, digits, dashes)"
docker inspect bahmni-backup-server >/dev/null 2>&1 || die "rest-server container is not running (backup-server/setup.sh)"

SITE_FILE="$CONF_DIR/sites/$SITE.env"
KEY_FILE="$CONF_DIR/keys/$SITE.key"
if [[ -f "$SITE_FILE" && "$ROTATE" == 0 ]]; then
  echo "site '$SITE' already exists; showing its configuration (use --rotate for new credentials):"
  echo; cat "$SITE_FILE"; exit 0
fi

rand() { openssl rand -base64 96 | tr -dc 'A-Za-z0-9' | head -c "$1"; }
HTTP_PW="$(rand 32)"
if [[ -f "$KEY_FILE" ]]; then
  KEY="$(cat "$KEY_FILE")"   # the repository key must not change once data exists
else
  KEY="$(rand 40)"
  (umask 077 && printf '%s' "$KEY" >"$KEY_FILE")
fi
docker exec bahmni-backup-server create_user "$SITE" "$HTTP_PW" >/dev/null 2>&1 || die "create_user failed"
install -d -m 0700 "$DATA_DIR/$SITE"
# rest-server re-reads .htpasswd every few seconds; 404 = authenticated, repository not initialised yet
for _ in $(seq 1 20); do
  code="$(curl -s -o /dev/null -w '%{http_code}' -u "$SITE:$HTTP_PW" "http://127.0.0.1:8000/$SITE/config")"
  [[ "$code" == 404 || "$code" == 200 ]] && break; sleep 1
done
[[ "$code" == 404 || "$code" == 200 ]] || die "the new credentials are not accepted by rest-server (HTTP $code)"

REPO="rest:${PUBLIC_URL%%://*}://$SITE:$HTTP_PW@${PUBLIC_URL#*://}/$SITE"
(umask 077 && cat >"$SITE_FILE" <<EOF
# generated $(date -Iseconds) by add_site.sh - paste into bahmni-standard/.env on the hospital server
BACKUP_SITE_NAME=$SITE
BACKUP_REPOSITORY=$REPO
BACKUP_PASSWORD=$KEY
EOF
)
cat <<EOF

Site '$SITE' enrolled. On the hospital server either pass these to scripts/install.sh
  --site-name $SITE --backup-repo '$REPO' --backup-password '$KEY'
or add them to bahmni-standard/.env and run: scripts/backup_to_cloud.sh --init --install-cron

$(cat "$SITE_FILE")

A copy is kept in $SITE_FILE (root only). Without BACKUP_PASSWORD the backups cannot be decrypted.
If this site runs on this very server (e.g. the cloud demo), it can skip the public URL and use:
  BACKUP_REPOSITORY=rest:http://$SITE:$HTTP_PW@host.docker.internal:8000/$SITE
EOF
