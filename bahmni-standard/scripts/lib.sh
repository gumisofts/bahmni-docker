#!/bin/bash
# Shared helpers for the bahmni-standard operational scripts. Source this file; do not execute it.
# Every script that sources it runs from the compose directory (bahmni-standard/).

COMPOSE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$COMPOSE_DIR/.env}"
cd "$COMPOSE_DIR" || exit 1

_ts() { date '+%H:%M:%S'; }
log()  { printf '%s [INFO] %s\n' "$(_ts)" "$*"; }
ok()   { printf '%s [ OK ] %s\n' "$(_ts)" "$*"; }
chg()  { printf '%s [DONE] %s\n' "$(_ts)" "$*"; }
warn() { printf '%s [WARN] %s\n' "$(_ts)" "$*" >&2; }
die()  { printf '%s [FAIL] %s\n' "$(_ts)" "$*" >&2; exit 1; }

need() { for t in "$@"; do command -v "$t" >/dev/null 2>&1 || die "'$t' is required but not installed"; done; }

load_env() {
  [[ -f "$ENV_FILE" ]] || die "missing $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
  PROXY_HTTPS_PORT="${PROXY_HTTPS_PORT:-8443}"
  ODOO_HOST_PORT="${ODOO_HOST_PORT:-8069}"
  OPENMRS_URL="https://127.0.0.1:${PROXY_HTTPS_PORT}/openmrs"
}

compose() { docker compose --progress quiet --env-file "$ENV_FILE" "$@"; }

# Services enabled by COMPOSE_PROFILES (docker compose config honours the profiles from .env).
# The list is captured once: piping compose straight into grep -q races with pipefail (SIGPIPE).
service_enabled() {
  [[ -n "${_SERVICES:-}" ]] || _SERVICES="$(compose config --services 2>/dev/null)"
  grep -qx "$1" <<<"$_SERVICES"
}
service_running() { [[ -n "$(compose ps -q --status running "$1" 2>/dev/null)" ]]; }

# --- .env editing -----------------------------------------------------------------------------

env_get() { # KEY [FILE]
  local f="${2:-$ENV_FILE}"
  grep -E "^${1}=" "$f" | tail -1 | cut -d= -f2- | sed -E "s/^(['\"])(.*)\1$/\2/"
}

env_set() { # KEY VALUE [FILE] - replace the line or append it; keeps file ownership and mode
  local f="${3:-$ENV_FILE}" tmp
  tmp="$(mktemp)"
  KEY="$1" VAL="$2" awk '
    BEGIN { k = ENVIRON["KEY"]; v = ENVIRON["VAL"] }
    index($0, k "=") == 1 { if (!done) { print k "=" v; done = 1 }; next }
    { print }
    END { if (!done) print k "=" v }' "$f" >"$tmp" && cat "$tmp" >"$f"
  rm -f "$tmp"
}

rand_password() { # [LENGTH] - alphanumeric with at least one digit, lower and upper case
  local n="${1:-24}" p
  while :; do
    p="$(openssl rand -base64 96 | tr -dc 'A-Za-z0-9' | head -c "$n")"
    [[ "$p" =~ [0-9] && "$p" =~ [a-z] && "$p" =~ [A-Z] ]] && { printf '%s' "$p"; return; }
  done
}

# --- HTTP -------------------------------------------------------------------------------------

http_code() { # URL [curl args...]
  local url="$1"; shift
  curl -sk -o /dev/null -w '%{http_code}' --max-time 20 "$@" "$url" 2>/dev/null || echo 000
}

wait_for_http() { # LABEL URL CODE_REGEX TIMEOUT_SEC [curl args...]
  local label="$1" url="$2" re="$3" timeout="$4"; shift 4
  local start=$SECONDS code
  log "waiting for $label ..."
  while :; do
    code="$(http_code "$url" "$@")"
    [[ "$code" =~ $re ]] && { ok "$label is up (HTTP $code, $((SECONDS - start))s)"; return 0; }
    (( SECONDS - start >= timeout )) && { warn "$label not up after ${timeout}s (last HTTP $code)"; return 1; }
    sleep 5
  done
}

# JSON field extraction without jq: jget 'results.0.uuid' < json
jget() {
  python3 -c '
import json, sys
d = json.load(sys.stdin)
for k in sys.argv[1].split("."):
    if not k:
        continue
    d = d[int(k)] if isinstance(d, list) else d.get(k)
    if d is None:
        break
if d is None:
    print("")
elif isinstance(d, (dict, list)):
    print(json.dumps(d))
else:
    print(d)' "$1"
}

# --- OpenMRS REST ------------------------------------------------------------------------------

# omrs USER PASS METHOD PATH [JSON] -> prints body, sets OMRS_CODE
omrs() {
  local u="$1" p="$2" m="$3" path="$4" body="${5:-}" out
  out="$(curl -sk --max-time 120 -u "$u:$p" -X "$m" -H 'Content-Type: application/json' \
        -H 'User-Agent: bahmni-ops/1.0' ${body:+-d "$body"} -w '\n%{http_code}' "$OPENMRS_URL/ws/rest/v1$path")"
  OMRS_CODE="${out##*$'\n'}"
  printf '%s' "${out%$'\n'*}"
}

omrs_auth_ok() { # USER PASS
  omrs "$1" "$2" GET /session | grep -q '"authenticated":true'
}

# --- databases (all run inside the DB containers; postgres images trust local socket logins) --

mysql_root() { # SERVICE DB SQL  (root; -N -s = raw rows)
  compose exec -T -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$1" mysql -N -s -uroot "$2" -e "$3"
}

psql_c() { # SERVICE USER DB SQL  (single value / rows, unaligned)
  compose exec -T "$1" psql -v ON_ERROR_STOP=1 -qtA -U "$2" -d "$3" -c "$4"
}

# Readiness is probed over TCP on purpose: during first-start initialisation the official images run a
# temporary server that only listens on the unix socket, and touching it would race the seed import.
wait_for_mysql() { # SERVICE TIMEOUT
  local start=$SECONDS
  log "waiting for $1 ..."
  until compose exec -T -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$1" mysqladmin -h127.0.0.1 -uroot ping --silent >/dev/null 2>&1; do
    (( SECONDS - start >= $2 )) && return 1
    sleep 3
  done
  ok "$1 is up"
}

wait_for_postgres() { # SERVICE USER TIMEOUT
  local start=$SECONDS
  log "waiting for $1 ..."
  until compose exec -T "$1" pg_isready -q -h 127.0.0.1 -U "$2" >/dev/null 2>&1; do
    (( SECONDS - start >= $3 )) && return 1
    sleep 3
  done
  ok "$1 is up"
}
