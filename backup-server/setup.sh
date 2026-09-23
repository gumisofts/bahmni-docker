#!/bin/bash
# One-time setup of the backup server on the cloud host (run as root):
#
#   sudo backup-server/setup.sh --public-url https://hms.gumisofts.com/restic [options]
#
# Starts an append-only restic rest-server on 127.0.0.1:8000, publishes it through the existing
# nginx site under the path of --public-url, and schedules retention/integrity jobs (prune.sh).
# Then enrol each hospital with backup-server/add_site.sh <site>.
#
# Options:
#   --public-url URL       URL the hospitals will reach the server at (required; the path becomes the nginx location)
#   --nginx-site FILE      nginx server file to add the location to (default: /etc/nginx/sites-available/bahmni)
#   --no-nginx             do not touch nginx (you publish 127.0.0.1:8000 yourself)
#   --data-dir DIR         where repositories live (default: /srv/bahmni-backups)
set -o pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR=/etc/bahmni-backup
PUBLIC_URL=""; NGINX_SITE=/etc/nginx/sites-available/bahmni; NO_NGINX=0; DATA_DIR=/srv/bahmni-backups
while [[ $# -gt 0 ]]; do
  case "$1" in
    --public-url) PUBLIC_URL="${2%/}"; shift 2 ;;
    --nginx-site) NGINX_SITE="$2"; shift 2 ;;
    --no-nginx) NO_NGINX=1; shift ;;
    --data-dir) DATA_DIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown option $1"; exit 1 ;;
  esac
done
log() { printf '%s [INFO] %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()  { printf '%s [ OK ] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '%s [FAIL] %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }
[[ "$(id -u)" == 0 ]] || die "run as root (sudo)"
[[ -n "$PUBLIC_URL" ]] || die "--public-url is required, e.g. https://hms.gumisofts.com/restic"
command -v docker >/dev/null || die "docker is required"
[[ "$PUBLIC_URL" =~ ^https?://[^/]+(/.*)?$ ]] || die "--public-url must be an absolute URL"
LOCATION="${BASH_REMATCH[1]:-/}"; LOCATION="${LOCATION%/}/"

install -d -m 0700 "$DATA_DIR" "$CONF_DIR" "$CONF_DIR/keys" "$CONF_DIR/sites"
cat >"$CONF_DIR/server.env" <<EOF
PUBLIC_URL=$PUBLIC_URL
DATA_DIR=$DATA_DIR
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=12
EOF
chmod 600 "$CONF_DIR/server.env"
DOCKER_GW="$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true)"
printf 'BACKUP_DATA_DIR=%s\nREST_SERVER_BIND_GW=%s\n' "$DATA_DIR" "${DOCKER_GW:-127.0.0.2}" >"$HERE/.env"

log "starting rest-server ..."
(cd "$HERE" && docker compose up -d 2>&1 | grep -vE 'obsolete') || die "docker compose up failed"
for _ in $(seq 1 20); do curl -s -o /dev/null http://127.0.0.1:8000/ && break; sleep 1; done
code="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8000/probe/config)"
[[ "$code" == 401 ]] && ok "rest-server is up and requires authentication" || die "rest-server answered HTTP $code on 127.0.0.1:8000"

if [[ "$NO_NGINX" == 0 ]]; then
  command -v nginx >/dev/null || die "nginx not found; use --no-nginx and publish 127.0.0.1:8000 yourself"
  [[ -f "$NGINX_SITE" ]] || die "nginx site $NGINX_SITE not found (use --nginx-site)"
  cat >/etc/nginx/snippets/bahmni-backup.conf <<EOF
# restic rest-server for hospital backups (installed by backup-server/setup.sh)
location $LOCATION {
    proxy_pass http://127.0.0.1:8000/;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    client_max_body_size 0;
    proxy_request_buffering off;
    proxy_read_timeout 600s;
    proxy_send_timeout 600s;
}
EOF
  if grep -q 'snippets/bahmni-backup.conf' "$NGINX_SITE"; then
    ok "nginx site already includes the backup location"
  else
    cp -p "$NGINX_SITE" "$NGINX_SITE.bak.$(date +%Y%m%d%H%M%S)"
    # add the include right after every server_name line, i.e. once per server block
    sed -i 's|^\(\s*\)server_name .*;$|&\n\1include snippets/bahmni-backup.conf;|' "$NGINX_SITE"
    if nginx -t >/dev/null 2>&1; then
      systemctl reload nginx && ok "nginx: added 'include snippets/bahmni-backup.conf' to $NGINX_SITE and reloaded"
    else
      cp -p "$(ls -t "$NGINX_SITE".bak.* | head -1)" "$NGINX_SITE"
      die "nginx -t failed after editing $NGINX_SITE; original restored. Add 'include snippets/bahmni-backup.conf;' to the server block manually."
    fi
  fi
  code="$(curl -s -o /dev/null -w '%{http_code}' "$PUBLIC_URL/probe/config")"
  [[ "$code" == 401 ]] && ok "$PUBLIC_URL answers through nginx (HTTP 401 = auth required, as expected)" \
                       || echo "WARN: $PUBLIC_URL/probe/config answered HTTP $code - check DNS/Cloudflare/WAF (expected 401)"
fi

cat >/etc/cron.d/bahmni-backup-prune <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 6 * * * root $HERE/prune.sh >> /var/log/bahmni-backup-prune.log 2>&1
EOF
chmod 644 /etc/cron.d/bahmni-backup-prune
printf '/var/log/bahmni-backup-prune.log {\n  monthly\n  rotate 12\n  compress\n  missingok\n  notifempty\n}\n' >/etc/logrotate.d/bahmni-backup-prune
ok "retention job scheduled daily at 06:00 (/etc/cron.d/bahmni-backup-prune)"

cat <<EOF

Backup server ready.
  repositories : $DATA_DIR/<site>
  site secrets : $CONF_DIR/sites/<site>.env (keep this host's backups of /etc/bahmni-backup safe!)
  next         : sudo $HERE/add_site.sh <site-name>      # once per hospital
                 sudo $HERE/prune.sh --status             # who backed up when
EOF
