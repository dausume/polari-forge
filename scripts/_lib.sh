#!/bin/bash
# scripts/_lib.sh — shared by every forge script (sourced, never run).
#
# Paths: the project dir is the parent of scripts/ (FORGE_DIR overrides, for the
# selftest's sandbox). Everything a run writes goes under $GEN (gitignored) or
# into the named volume — never anywhere else in this tree.
#
# Knobs (env): FORGE_HTTP_PORT (3300) FORGE_SSH_PORT (2222) FORGE_ROOT_URL
#   (http://127.0.0.1:$FORGE_HTTP_PORT/) FORGE_DOMAIN (localhost) FORGE_OWNER
#   (dausume) FORGE_GITHUB (https://github.com) FORGE_ADMIN (polari-admin)
#   FORGE_WAIT_S (120)

#
# Two homes for the same forge (frg-2):
#   compose  `pol forge up` on this box — loopback ports, the project's own volume
#   swarm    a `pol prod` stack service (POL_PROD_FORGE=on) — NO published ports;
#            reached by `docker exec <task> curl localhost:3000` (api() below), the
#            volume polari_forge_data. `pol forge` (polari-cli/scripts/forge.sh)
#            exports FORGE_PROD=on + FORGE_GEN/ROOT_URL/VOLUME/… for it.
#   Knobs for the swarm home: FORGE_STACK (polari-lean polari-prod — the stacks
#   searched for <stack>_forge), FORGE_VOLUME, FORGE_TOKEN (the admin token read
#   from the vault by forge.sh — never on argv), FORGE_PROD, FORGE_STACK_FILES.

FORGE_DIR="${FORGE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
GEN="${FORGE_GEN:-$FORGE_DIR/.generated/forge}"
COMPOSE_FILE="$FORGE_DIR/compose/forge.yml"
PROJECT=polari-forge
SERVICE=forge
VOLUME="${FORGE_VOLUME:-${PROJECT}_forge-data}"
# THE ONE PIN is compose/forge.yml's image: line (pol prod reads the same line for the stack)
IMAGE="$(awk '/^[[:space:]]*image:[[:space:]]*/{print $2; exit}' "$COMPOSE_FILE" 2>/dev/null)"
IMAGE="${IMAGE:-codeberg.org/forgejo/forgejo:11@sha256:946243edbab116d5bb78b73ea68af6f3d69229ba1b1ed958dd82c3481167f3e0}"
FORGE_STACK="${FORGE_STACK:-polari-lean polari-prod}"
FORGE_API_EXPLICIT="${FORGE_API:+1}"

FORGE_HTTP_PORT="${FORGE_HTTP_PORT:-3300}"
FORGE_SSH_PORT="${FORGE_SSH_PORT:-2222}"
FORGE_ROOT_URL="${FORGE_ROOT_URL:-http://127.0.0.1:${FORGE_HTTP_PORT}/}"
case "$FORGE_ROOT_URL" in */) ;; *) FORGE_ROOT_URL="$FORGE_ROOT_URL/" ;; esac
FORGE_DOMAIN="${FORGE_DOMAIN:-localhost}"
FORGE_OWNER="${FORGE_OWNER:-dausume}"
FORGE_GITHUB="${FORGE_GITHUB:-https://github.com}"
FORGE_ADMIN="${FORGE_ADMIN:-polari-admin}"
# the API is always reached on loopback from this box, whatever ROOT_URL says
FORGE_API="${FORGE_API:-http://127.0.0.1:${FORGE_HTTP_PORT}}"

if [ -t 1 ]; then
    F_RED='\033[0;31m'; F_GREEN='\033[0;32m'; F_YELLOW='\033[1;33m'; F_BOLD='\033[1m'; F_NC='\033[0m'
else
    F_RED=''; F_GREEN=''; F_YELLOW=''; F_BOLD=''; F_NC=''
fi
say()  { printf '%s\n' "$*"; }
okl()  { printf "${F_GREEN}[ OK ]${F_NC} %s\n" "$*"; }
warn() { printf "${F_YELLOW}[WARN]${F_NC} %s\n" "$*"; }
die()  { printf "${F_RED}[FAIL]${F_NC} %s\n" "$*" >&2; exit 1; }

compose() { docker compose -f "$COMPOSE_FILE" --project-name "$PROJECT" "$@"; }

# the running container's id ('' when there is none): the compose container first
# (the home forge), else the swarm task of <stack>_forge (a pol prod service)
compose_ctr() {
    docker ps -q --filter "label=com.docker.compose.project=$PROJECT" \
                 --filter "label=com.docker.compose.service=$SERVICE" 2>/dev/null | head -n1
}
swarm_ctr() {
    local st c
    for st in $FORGE_STACK; do
        c="$(docker ps -q --filter "label=com.docker.swarm.service.name=${st}_${SERVICE}" 2>/dev/null | head -n1)"
        [ -n "$c" ] && { printf '%s\n' "$c"; return 0; }
    done
    return 0
}
forge_ctr() { local c; c="$(compose_ctr)"; [ -n "$c" ] && { printf '%s\n' "$c"; return 0; }; swarm_ctr; }
# compose | swarm | none — which home the RUNNING forge has
forge_mode() {
    if [ -n "$(compose_ctr)" ]; then echo compose
    elif [ -n "$(swarm_ctr)" ]; then echo swarm
    else echo none; fi
}
# the forge is a pol prod stack service: answered on (FORGE_PROD=on, set by forge.sh from
# the prod answers), or a swarm task / service of that name exists here
forge_is_service() {
    [ -n "$(compose_ctr)" ] && return 1
    [ "${FORGE_PROD:-off}" = on ] && return 0
    [ -n "$(swarm_ctr)" ] && return 0
    local st; for st in $FORGE_STACK; do docker service inspect "${st}_${SERVICE}" >/dev/null 2>&1 && return 0; done
    return 1
}
refuse_if_service() {
    forge_is_service && die "this forge is a pol prod service — pol prod apply / pol prod down"
    return 0
}
need_ctr() { CTR="$(forge_ctr)"; [ -n "$CTR" ] || { forge_is_service && die "the forge service has no running task here — pol prod status"; die "the forge is not running — pol forge up"; }; }

# load the generated secrets (never printed)
load_secrets() {
    [ -f "$GEN/forge.env" ] || die "not rendered yet — pol forge render"
    # shellcheck disable=SC1091
    set -a; . "$GEN/forge.env"; set +a
}

# the admin token: the file (compose home), else FORGE_TOKEN (the swarm home — forge.sh
# reads it from the vault, `forge ADMIN_TOKEN`); '' when neither
token() { if [ -s "$GEN/token" ]; then cat "$GEN/token"; elif [ -n "${FORGE_TOKEN:-}" ]; then printf '%s\n' "$FORGE_TOKEN"; fi; return 0; }
token_where() { if [ -s "$GEN/token" ]; then echo "$GEN/token (mode $(stat -c %a "$GEN/token"))"; elif [ -n "${FORGE_TOKEN:-}" ]; then echo "the vault (forge ADMIN_TOKEN)"; else echo none; fi; }

# the API transport: host = curl $FORGE_API (the compose home's loopback port);
# exec = `docker exec -i <swarm task> curl http://localhost:3000` — the swarm home
# publishes NO port, and this needs neither DNS, the certificate nor the proxy.
# An explicit FORGE_API always means host.
# api_resolve (call it bare — no subshell) sets API_VIA host|exec and _SWARM_CTR; a found
# task is remembered for the rest of the run, an absent one is asked again next call
_SWARM_CTR=''; API_VIA=host
api_resolve() {
    API_VIA=host
    [ -n "$FORGE_API_EXPLICIT" ] && return 0
    [ -n "$_SWARM_CTR" ] || { [ -z "$(compose_ctr)" ] && _SWARM_CTR="$(swarm_ctr)"; }
    [ -n "$_SWARM_CTR" ] && API_VIA=exec
    return 0
}
api_where() { api_resolve; [ "$API_VIA" = exec ] && echo "docker exec ${_SWARM_CTR:0:12} → http://localhost:3000 (no published port)" || echo "$FORGE_API"; }

# api METHOD PATH [JSON] → sets API_CODE and API_BODY (no subshell: call it bare).
# The token travels in a header read from a process substitution (host) or from
# docker exec's stdin (exec), so it never appears in argv / ps.
api() {
    local m="$1" p="$2" d="${3:-}" out tok
    tok="$(token)"
    local args=(-sS -X "$m" -H 'Accept: application/json' -w '\n%{http_code}')
    [ -n "$d" ] && args+=(-H 'Content-Type: application/json' --data "$d")
    api_resolve
    if [ "$API_VIA" = exec ]; then
        out="$( { [ -z "$tok" ] || printf 'Authorization: token %s\n' "$tok"; } | docker exec -i "$_SWARM_CTR" curl "${args[@]}" -H @- "http://localhost:3000$p" 2>/dev/null)" || out=$'\n000'
    else
    # the process substitution must sit on curl's own command line (its fd closes after the statement)
    out="$(curl "${args[@]}" -H @<([ -n "$tok" ] && printf 'Authorization: token %s\n' "$tok") "$FORGE_API$p" 2>/dev/null)" || out=$'\n000'
    fi
    API_CODE="${out##*$'\n'}"
    API_BODY="${out%$'\n'*}"
    [ "$API_BODY" = "$API_CODE" ] && API_BODY=''
    return 0
}

# jget KEY  (stdin JSON → value; '' when absent)
jget() { python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
v=d
for k in sys.argv[1].split("."):
    v = v.get(k) if isinstance(v, dict) else None
print("" if v is None else (json.dumps(v) if isinstance(v,(dict,list,bool)) else v))' "$1"; }

# ini_get SECTION KEY FILE  (section '' = the top of the file)
ini_get() {
    awk -v s="$1" -v k="$2" '
        /^[ \t]*[;#]/ { next }
        /^[ \t]*\[/ { cur=$0; gsub(/^[ \t]*\[|\][ \t]*$/, "", cur); next }
        cur == s {
            line=$0; i=index(line, "=")
            if (i == 0) next
            key=substr(line, 1, i-1); val=substr(line, i+1)
            gsub(/^[ \t]+|[ \t]+$/, "", key); gsub(/^[ \t]+|[ \t]+$/, "", val)
            if (key == k) { print val; exit }
        }' "$3"
}
