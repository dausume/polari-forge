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

FORGE_DIR="${FORGE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
GEN="${FORGE_GEN:-$FORGE_DIR/.generated/forge}"
COMPOSE_FILE="$FORGE_DIR/compose/forge.yml"
PROJECT=polari-forge
SERVICE=forge
VOLUME="${PROJECT}_forge-data"
IMAGE="codeberg.org/forgejo/forgejo:11@sha256:946243edbab116d5bb78b73ea68af6f3d69229ba1b1ed958dd82c3481167f3e0"

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

# the running container's id ('' when there is none)
forge_ctr() {
    docker ps -q --filter "label=com.docker.compose.project=$PROJECT" \
                 --filter "label=com.docker.compose.service=$SERVICE" 2>/dev/null | head -n1
}
need_ctr() { CTR="$(forge_ctr)"; [ -n "$CTR" ] || die "the forge is not running — pol forge up"; }

# load the generated secrets (never printed)
load_secrets() {
    [ -f "$GEN/forge.env" ] || die "not rendered yet — pol forge render"
    # shellcheck disable=SC1091
    set -a; . "$GEN/forge.env"; set +a
}

token() { [ -f "$GEN/token" ] && cat "$GEN/token" || true; }

# api METHOD PATH [JSON] → sets API_CODE and API_BODY (no subshell: call it bare).
# The token travels in a header read from a process substitution, so it never
# appears in argv / ps.
api() {
    local m="$1" p="$2" d="${3:-}" out tok
    tok="$(token)"
    local args=(-sS -X "$m" -H 'Accept: application/json' -w '\n%{http_code}')
    [ -n "$d" ] && args+=(-H 'Content-Type: application/json' --data "$d")
    # the process substitution must sit on curl's own command line (its fd closes after the statement)
    out="$(curl "${args[@]}" -H @<([ -n "$tok" ] && printf 'Authorization: token %s\n' "$tok") "$FORGE_API$p" 2>/dev/null)" || out=$'\n000'
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
