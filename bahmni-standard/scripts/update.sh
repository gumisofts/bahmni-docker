#!/bin/bash
# Upgrade an installed site to the latest commit of the repository without losing the server .env.
#
#   scripts/update.sh [--no-restart] [--branch NAME]
#
# The tracked .env is a secret-free template; the server keeps its real values in the same file
# (marked skip-worktree). This script: records every key whose value differs from the current
# template, pulls, re-applies those values on top of the new template, then pulls images,
# recreates changed containers and re-runs bootstrap-site.sh. New template keys are listed so
# you can review them.
# Self-contained on purpose (no lib.sh) so it can be fetched and run on a server that predates it.
set -o pipefail
COMPOSE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(git -C "$COMPOSE_DIR" rev-parse --show-toplevel 2>/dev/null)" || { echo "not a git checkout"; exit 1; }
REL_ENV="$(realpath --relative-to="$REPO_DIR" "$COMPOSE_DIR/.env")"
ENV_FILE="$COMPOSE_DIR/.env"
RESTART=1; BRANCH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-restart) RESTART=0; shift ;;
    --branch) BRANCH="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option $1"; exit 1 ;;
  esac
done
log() { printf '%s [INFO] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '%s [FAIL] %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

cd "$REPO_DIR" || exit 1
[[ -f "$ENV_FILE" ]] || die "missing $ENV_FILE"
dirty="$(git status --porcelain | grep -v " $REL_ENV$" | grep -vE '^\?\?' || true)"
[[ -z "$dirty" ]] || die "uncommitted changes in the checkout, refusing to update:"$'\n'"$dirty"

# read KEY=VALUE pairs (raw values, comments and blanks ignored) into an associative array
declare -A OLD_T NEW_T CUR
read_env() { # ARRAYNAME < file
  local -n arr="$1"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    arr["${line%%=*}"]="${line#*=}"
  done
}
read_env OLD_T < <(git show "HEAD:$REL_ENV")
read_env CUR <"$ENV_FILE"

bak="$COMPOSE_DIR/.env.bak.$(date +%Y%m%d%H%M%S)"
cp -p "$ENV_FILE" "$bak" && chmod 600 "$bak"
log "server .env backed up to $bak"

# site-specific values = keys missing from the template or with a different value
declare -A OVERRIDE
for k in "${!CUR[@]}"; do
  [[ -v OLD_T[$k] && "${OLD_T[$k]}" == "${CUR[$k]}" ]] || OVERRIDE["$k"]="${CUR[$k]}"
done
log "${#OVERRIDE[@]} site-specific values will be re-applied"

old_head="$(git rev-parse --short HEAD)"
git update-index --no-skip-worktree "$REL_ENV"
git checkout -- "$REL_ENV"
if ! git pull -q --ff-only ${BRANCH:+origin "$BRANCH"}; then
  cp "$bak" "$ENV_FILE"; git update-index --skip-worktree "$REL_ENV"
  die "git pull failed; .env restored from backup"
fi
read_env NEW_T <"$ENV_FILE"

tmp="$(mktemp)"
cp "$ENV_FILE" "$tmp"
for k in "${!OVERRIDE[@]}"; do
  KEY="$k" VAL="${OVERRIDE[$k]}" awk '
    BEGIN { k = ENVIRON["KEY"]; v = ENVIRON["VAL"] }
    index($0, k "=") == 1 { if (!done) { print k "=" v; done = 1 }; next }
    { print }
    END { if (!done) print k "=" v }' "$tmp" >"$tmp.2" && mv "$tmp.2" "$tmp"
done
cat "$tmp" >"$ENV_FILE"; rm -f "$tmp"
chmod 600 "$ENV_FILE"
git update-index --skip-worktree "$REL_ENV"
log "updated $old_head -> $(git rev-parse --short HEAD); .env merged"

new_keys=()
for k in "${!NEW_T[@]}"; do [[ -v OLD_T[$k] ]] || new_keys+=("$k=${NEW_T[$k]}"); done
if [[ ${#new_keys[@]} -gt 0 ]]; then
  echo
  echo "New settings arrived with this update (template defaults shown). Review them in $ENV_FILE:"
  printf '  %s\n' "${new_keys[@]}" | sort
  echo
fi

if [[ "$RESTART" == 1 ]]; then
  cd "$COMPOSE_DIR" || exit 1
  log "pulling images and recreating changed containers ..."
  docker compose --env-file "$ENV_FILE" pull -q 2>&1 | grep -viE 'obsolete|^$' || true
  docker compose --env-file "$ENV_FILE" up -d --remove-orphans 2>&1 | grep -vE 'obsolete' || true
  if [[ -x scripts/bootstrap-site.sh ]]; then
    if [[ ${#new_keys[@]} -gt 0 ]]; then
      log "skipping bootstrap-site.sh because new settings need review first; run it afterwards"
    else
      scripts/bootstrap-site.sh
    fi
  fi
fi
log "update complete"
