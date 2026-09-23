#!/bin/bash
# Install Bahmni Standard on a fresh Ubuntu server (hospital on-premises or cloud).
#
#   sudo scripts/install.sh --site-name hospitalA --hostname hms.hospitala.local [options]
#
# What it does: installs Docker if needed, writes a server-only .env with generated secrets,
# pulls the images, starts the stack in the right order, applies scripts/bootstrap-site.sh,
# and (when --backup-repo is given) initialises the off-site backup + nightly cron.
#
# Options:
#   --site-name NAME        short id for this installation, used in backups (default: hostname -s)
#   --hostname FQDN         name browsers will use, e.g. hms.hospitala.local (default: this host's IP)
#                           Odoo (billing) is served on erp-<hostname>; both names must resolve to this server.
#   --admin-user LOGIN      OpenMRS admin login (default: hms-admin)
#   --admin-password PW     password for the human admin logins (OpenMRS, OpenELIS, Odoo, dcm4chee, Metabase);
#                           prompted if omitted
#   --behind-proxy          bind to 127.0.0.1:8080/8443 for a host reverse proxy instead of 0.0.0.0:80/443
#   --http-port/--https-port/--dicom-port N
#   --backup-repo URL       restic repository (from backup-server/add_site.sh on the cloud server)
#   --backup-password PW    restic repository key
#   --load-images FILE      docker load an offline image bundle before starting
#   --project-name NAME     docker compose project name (default: directory name)
#   --wait-timeout SEC      how long to wait for each service (default 1200)
#   --yes                   do not ask for confirmation
set -o pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SITE_NAME="" HOSTNAME_FQDN="" ADMIN_USER="hms-admin" ADMIN_PW="" BEHIND_PROXY=0
HTTP_PORT="" HTTPS_PORT="" DICOM="11112" BACKUP_REPO="" BACKUP_PW="" LOAD_IMAGES="" PROJECT="" YES=0 WAIT=1200
while [[ $# -gt 0 ]]; do
  case "$1" in
    --site-name) SITE_NAME="$2"; shift 2 ;;
    --hostname) HOSTNAME_FQDN="$2"; shift 2 ;;
    --admin-user) ADMIN_USER="$2"; shift 2 ;;
    --admin-password) ADMIN_PW="$2"; shift 2 ;;
    --behind-proxy) BEHIND_PROXY=1; shift ;;
    --http-port) HTTP_PORT="$2"; shift 2 ;;
    --https-port) HTTPS_PORT="$2"; shift 2 ;;
    --dicom-port) DICOM="$2"; shift 2 ;;
    --backup-repo) BACKUP_REPO="$2"; shift 2 ;;
    --backup-password) BACKUP_PW="$2"; shift 2 ;;
    --load-images) LOAD_IMAGES="$2"; shift 2 ;;
    --project-name) PROJECT="$2"; shift 2 ;;
    --wait-timeout) WAIT="$2"; shift 2 ;;
    --yes) YES=1; shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

# --- preflight --------------------------------------------------------------------------------
[[ "$(uname -s)" == Linux ]] || die "Linux only"
IS_ROOT=0; [[ "$(id -u)" == 0 ]] && IS_ROOT=1
OWNER="${SUDO_USER:-$(id -un)}"

if grep -qE '^SITE_INSTALLED=' "$ENV_FILE"; then
  die "this directory is already installed ($(env_get SITE_INSTALLED)). Use scripts/update.sh to upgrade or scripts/bootstrap-site.sh to re-apply configuration."
fi

if ! command -v docker >/dev/null 2>&1; then
  [[ "$IS_ROOT" == 1 ]] || die "Docker is not installed; run this script with sudo so it can install it"
  log "installing Docker Engine from download.docker.com ..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq && apt-get install -y -qq ca-certificates curl gnupg >/dev/null
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  # shellcheck disable=SC1091
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME:-$VERSION_CODENAME} stable" >/etc/apt/sources.list.d/docker.list
  apt-get update -qq && apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
  systemctl enable --now docker
  ok "Docker installed: $(docker --version)"
fi
need docker curl openssl python3
docker compose version >/dev/null 2>&1 || die "docker compose plugin missing"
if [[ "$IS_ROOT" == 1 && "$OWNER" != root ]] && ! id -nG "$OWNER" | grep -qw docker; then
  usermod -aG docker "$OWNER" && ok "added $OWNER to the docker group (log out and in again for it to apply)"
fi

if [[ "$BEHIND_PROXY" == 1 ]]; then
  BIND="127.0.0.1"; HTTP_PORT="${HTTP_PORT:-8080}"; HTTPS_PORT="${HTTPS_PORT:-8443}"
else
  BIND="0.0.0.0"; HTTP_PORT="${HTTP_PORT:-80}"; HTTPS_PORT="${HTTPS_PORT:-443}"
fi
SITE_NAME="${SITE_NAME:-$(hostname -s)}"
[[ "$SITE_NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "--site-name must be lowercase letters, digits and dashes"
PRIMARY_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
HOSTNAME_FQDN="${HOSTNAME_FQDN:-$PRIMARY_IP}"
ODOO_PORT="$(env_get ODOO_HOST_PORT)"; ODOO_PORT="${ODOO_PORT:-8069}"
DCM_WEB_PORT="$(env_get DCM4CHEE_WEB_HOST_PORT)"; DCM_WEB_PORT="${DCM_WEB_PORT:-8055}"

busy=""
listening="$(ss -Hltn 2>/dev/null | awk '{print $4}')"
for p in "$HTTP_PORT" "$HTTPS_PORT" "$DICOM" "$ODOO_PORT" "$DCM_WEB_PORT"; do
  grep -qE "[:.]${p}$" <<<"$listening" && busy="$busy $p"
done
[[ -z "$busy" ]] || die "port(s)$busy already in use on this host. Stop the other service or pass --behind-proxy / --http-port / --https-port / --dicom-port."

if [[ -z "$ADMIN_PW" ]]; then
  [[ "$YES" == 1 ]] && die "--admin-password is required with --yes"
  while :; do
    read -r -s -p "Password for the admin logins (OpenMRS, OpenELIS, Odoo, dcm4chee, Metabase): " ADMIN_PW; echo
    read -r -s -p "Repeat: " ADMIN_PW2; echo
    [[ "$ADMIN_PW" == "$ADMIN_PW2" && ${#ADMIN_PW} -ge 8 ]] && break
    echo "Passwords differ or are shorter than 8 characters, try again."
  done
fi
[[ "$ADMIN_PW" =~ [0-9] && "$ADMIN_PW" =~ [a-z] && "$ADMIN_PW" =~ [A-Z] && ${#ADMIN_PW} -ge 8 ]] \
  || die "OpenMRS requires at least 8 characters with upper case, lower case and a digit"
case "$ADMIN_PW" in *\'*|*\"*|*\\*|*\$*|*\`*) die "the admin password must not contain quotes, backslashes, \$ or backticks" ;; esac

cat <<EOF

Bahmni Standard will be installed with:
  site name          $SITE_NAME
  EMR address        https://$HOSTNAME_FQDN$( [[ "$HTTPS_PORT" != 443 ]] && echo ":$HTTPS_PORT" )   (Odoo: https://erp-$HOSTNAME_FQDN)
  bind               $BIND:$HTTP_PORT / $BIND:$HTTPS_PORT   DICOM $BIND:$DICOM
  admin login        $ADMIN_USER
  off-site backups   $( [[ -n "$BACKUP_REPO" ]] && echo "enabled -> $(sed -E 's#//[^/@]*@#//#' <<<"$BACKUP_REPO")" || echo "not configured (add later with scripts/backup_to_cloud.sh --install-cron)" )
  compose project    ${PROJECT:-$(basename "$COMPOSE_DIR")}
EOF
if [[ "$YES" != 1 ]]; then read -r -p "Continue? [y/N] " a; [[ "$a" =~ ^[Yy] ]] || exit 1; fi

# --- .env -------------------------------------------------------------------------------------
log "writing server configuration to $ENV_FILE"
env_set BIND_IP "$BIND"
env_set PROXY_HTTP_PORT "$HTTP_PORT"
env_set PROXY_HTTPS_PORT "$HTTPS_PORT"
env_set DICOM_PORT "$DICOM"
[[ -n "$PROJECT" ]] && env_set COMPOSE_PROJECT_NAME "$PROJECT"
env_set METABASE_SITE_URL "https://$HOSTNAME_FQDN$( [[ "$HTTPS_PORT" != 443 ]] && echo ":$HTTPS_PORT" )/metabase"
env_set OPENMRS_ADMIN_USER "$ADMIN_USER"
for k in OPENMRS_ADMIN_PASSWORD OPENELIS_ADMIN_PASSWORD ODOO_ADMIN_PASSWORD DCM4CHEE_ADMIN_PASSWORD METABASE_ADMIN_PASSWORD; do
  env_set "$k" "$ADMIN_PW"
done
# Database passwords are fixed at first start, so they are generated before anything runs.
# OPENELIS_DB_PASSWORD is deliberately left alone: bahmni/openelis hardcodes 'clinlims' (BAH-3394); the DB is not exposed outside the docker network.
for k in MYSQL_ROOT_PASSWORD OPENMRS_DB_PASSWORD REPORTS_DB_PASSWORD ODOO_DB_PASSWORD \
         PACS_DB_ROOT_PASSWORD DCM4CHEE_DB_PASSWORD PACS_INTEGRATION_DB_PASSWORD METABASE_DB_PASSWORD MART_DB_PASSWORD \
         OPENMRS_ATOMFEED_PASSWORD OPENELIS_ATOMFEED_PASSWORD ODOO_ATOMFEED_PASSWORD REPORTS_OPENMRS_SERVICE_PASSWORD \
         ODOO_MASTER_PASSWORD SNOWSTORM_LITE_ADMIN_PASSWORD; do
  env_set "$k" "$(rand_password 24)"
done
env_set BACKUP_SITE_NAME "$SITE_NAME"
[[ -n "$BACKUP_REPO" ]] && env_set BACKUP_REPOSITORY "$BACKUP_REPO"
[[ -n "$BACKUP_PW" ]] && env_set BACKUP_PASSWORD "$BACKUP_PW"
chmod 600 "$ENV_FILE"
mkdir -p backup-artifacts
if [[ "$IS_ROOT" == 1 ]]; then chown "$OWNER" "$ENV_FILE" backup-artifacts; fi
if git -C "$COMPOSE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # The server .env must never be committed or clobbered by git pull; scripts/update.sh knows how to merge it.
  git -C "$COMPOSE_DIR" update-index --skip-worktree .env 2>/dev/null || true
fi
load_env
ok ".env written (keep a copy of it in your password manager - it holds every secret of this site)"

# --- images -----------------------------------------------------------------------------------
if [[ -n "$LOAD_IMAGES" ]]; then
  log "loading images from $LOAD_IMAGES ..."
  docker load -q -i "$LOAD_IMAGES" | tail -1
fi
log "pulling images (skipped for images already present) ..."
for attempt in 1 2 3; do
  out="$(compose pull -q 2>&1)"; rc=$?
  grep -viE 'obsolete|^$|Pulling|Pulled' <<<"$out" || true
  [[ $rc == 0 ]] && break
  [[ $attempt -lt 3 ]] && { warn "pull failed (network hiccup?), retrying in 20s ..."; sleep 20; }
done
missing="$(compose config --images | while read -r img; do docker image inspect "$img" >/dev/null 2>&1 || echo "$img"; done)"
[[ -z "$missing" ]] || die "images not available (no internet? use --load-images):"$'\n'"$missing"

# --- start ------------------------------------------------------------------------------------
# From here on the generated database passwords are baked into the data volumes, so a re-run must not regenerate them.
env_set SITE_INSTALLED "$(date -Iseconds)_by_$OWNER"
# OpenMRS first: the other services log in to it, and their stock credentials would lock the
# admin account before we can change it. bootstrap sets the passwords, then everything else starts.
log "starting OpenMRS (first start runs database migrations, allow 5-15 minutes) ..."
compose up -d openmrsdb openmrs proxy 2>&1 | grep -vE 'obsolete|^ (Container|Volume|Network) ' || true
"$COMPOSE_DIR/scripts/bootstrap-site.sh" --only openmrs-accounts --wait-timeout "$WAIT" || die "OpenMRS did not come up correctly; check: docker compose logs openmrs"
log "starting all services ..."
# compose gives up on dependants when a database is slow to become healthy; a second 'up' is idempotent
for attempt in 1 2 3; do
  out="$(compose up -d 2>&1)"; rc=$?
  grep -vE 'obsolete|^ (Container|Volume|Network) ' <<<"$out" || true
  [[ $rc == 0 ]] && break
  [[ $attempt -lt 3 ]] && { warn "some services did not start yet, retrying in 30s ..."; sleep 30; }
done
"$COMPOSE_DIR/scripts/bootstrap-site.sh" --wait-timeout "$WAIT" || warn "some bootstrap steps failed - re-run scripts/bootstrap-site.sh after checking the logs"

# --- backups ----------------------------------------------------------------------------------
if [[ -n "$BACKUP_REPO" ]]; then
  "$COMPOSE_DIR/scripts/backup_to_cloud.sh" --init && "$COMPOSE_DIR/scripts/backup_to_cloud.sh" --install-cron \
    && "$COMPOSE_DIR/scripts/backup_to_cloud.sh" \
    || warn "backup setup failed - fix BACKUP_* in .env and run scripts/backup_to_cloud.sh --init --install-cron"
fi

# --- firewall ---------------------------------------------------------------------------------
if [[ "$IS_ROOT" == 1 ]] && command -v ufw >/dev/null 2>&1 && [[ "$(ufw status 2>/dev/null)" == "Status: active"* ]]; then
  ufw allow "$HTTP_PORT"/tcp >/dev/null; ufw allow "$HTTPS_PORT"/tcp >/dev/null; ufw allow "$DICOM"/tcp >/dev/null
  ok "ufw: opened $HTTP_PORT, $HTTPS_PORT and $DICOM"
fi

# --- summary ----------------------------------------------------------------------------------
SUMMARY="$COMPOSE_DIR/install-summary.txt"
{
cat <<EOF
Bahmni Standard - installation summary ($(date))
=================================================
Site name:        $SITE_NAME
EMR / all apps:   https://$HOSTNAME_FQDN$( [[ "$HTTPS_PORT" != 443 ]] && echo ":$HTTPS_PORT" )/
Billing (Odoo):   https://erp-$HOSTNAME_FQDN$( [[ "$HTTPS_PORT" != 443 ]] && echo ":$HTTPS_PORT" )/
Lab (OpenELIS):   https://$HOSTNAME_FQDN$( [[ "$HTTPS_PORT" != 443 ]] && echo ":$HTTPS_PORT" )/openelis
PACS console:     https://$HOSTNAME_FQDN$( [[ "$HTTPS_PORT" != 443 ]] && echo ":$HTTPS_PORT" )/dcm4chee-web3
Analytics:        https://$HOSTNAME_FQDN$( [[ "$HTTPS_PORT" != 443 ]] && echo ":$HTTPS_PORT" )/metabase
DICOM endpoint:   $PRIMARY_IP:$DICOM  AE title DCM4CHEE   (configure this on X-ray/CT/ultrasound machines)

Logins (same password for all, the one you entered):
  OpenMRS/EMR  $ADMIN_USER        Odoo  admin        OpenELIS  admin
  dcm4chee     admin              Metabase  $METABASE_ADMIN_EMAIL
All other secrets (databases, service accounts, Odoo master password, backup key) are in:
  $ENV_FILE   <- back this file up to a password manager; a restore is impossible without it.

Next steps:
  1. DNS: point $HOSTNAME_FQDN and erp-$HOSTNAME_FQDN to $PRIMARY_IP on the hospital DNS server (or in each PC's hosts file).
  2. The proxy uses a self-signed certificate; staff will see a browser warning once per PC unless you install a proper certificate.
  3. In the EMR go to Admin -> create the hospital's locations, wards, beds, providers and user accounts.
  4. Backups: $( [[ -n "$BACKUP_REPO" ]] && echo "nightly at 01:00 to $(sed -E 's#//[^/@]*@#//#' <<<"$BACKUP_REPO"); test a restore with scripts/restore_from_cloud.sh --list" || echo "NOT configured - run scripts/backup_to_cloud.sh --install-cron after adding BACKUP_* to .env" )
  5. Re-run scripts/bootstrap-site.sh any time; upgrade with scripts/update.sh.
EOF
} | tee "$SUMMARY"
chmod 600 "$SUMMARY"; [[ "$IS_ROOT" == 1 ]] && chown "$OWNER" "$SUMMARY"
ok "installation finished (summary saved to $SUMMARY)"
