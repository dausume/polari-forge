#!/bin/bash
# posture.sh — `pol forge posture`: the public posture, one row each, OK/WARN,
# then ONE line. Reads the rendered app.ini, the compose file and (when the forge
# runs) the container's real limits and port bindings. Exit 0 = all OK, 2 = a WARN.
#   registration   DISABLE_REGISTRATION = true, no OpenID sign-up, no external-only door
#   anon-read      REQUIRE_SIGNIN_VIEW = false (anyone reads; nobody signs up)
#   indexer        REPO_INDEXER_ENABLED = false
#   mem-limit      a memory limit ≤ 512 MiB (compose file; the live container too)
#   ports          every published port bound to 127.0.0.1
#   secrets        forge.env + app.ini mode 600
#   admin-token    .generated/forge/token mode 600
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
case "${1:-}" in -h|--help|help) sed -n '2,12p' "$0"; exit 0 ;; esac

INI="$GEN/app.ini"
[ -f "$INI" ] || die "not rendered — pol forge render"
NOK=0; NWARN=0; SUMMARY=()
row() {  # row NAME OK|WARN DETAIL
    if [ "$2" = OK ]; then NOK=$((NOK+1)); printf "  ${F_GREEN}OK  ${F_NC} %-13s %s\n" "$1" "$3"
    else NWARN=$((NWARN+1)); printf "  ${F_YELLOW}WARN${F_NC} %-13s %s\n" "$1" "$3"; fi
    SUMMARY+=("$1 $2")
}
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

reg="$(lc "$(ini_get service DISABLE_REGISTRATION "$INI")")"
oid="$(lc "$(ini_get openid ENABLE_OPENID_SIGNUP "$INI")")"
ext="$(lc "$(ini_get service ALLOW_ONLY_EXTERNAL_REGISTRATION "$INI")")"
if [ "$reg" = true ] && [ "$oid" != true ] && [ "$ext" != true ]; then row registration OK "off (no sign-up of any kind)"
else row registration WARN "DISABLE_REGISTRATION=$reg ENABLE_OPENID_SIGNUP=${oid:-unset} ALLOW_ONLY_EXTERNAL_REGISTRATION=${ext:-unset}"; fi

anon="$(lc "$(ini_get service REQUIRE_SIGNIN_VIEW "$INI")")"
[ "$anon" = false ] && row anon-read OK "anonymous READ (REQUIRE_SIGNIN_VIEW=false)" \
                    || row anon-read WARN "REQUIRE_SIGNIN_VIEW=${anon:-unset} — the public route needs anonymous read"

idx="$(lc "$(ini_get indexer REPO_INDEXER_ENABLED "$INI")")"
[ "$idx" = false ] && row indexer OK "repo indexer off" || row indexer WARN "REPO_INDEXER_ENABLED=${idx:-unset}"

# memory limit: declared …
decl="$(awk '/^[[:space:]]*memory:/{print $2; exit}' "$COMPOSE_FILE" 2>/dev/null)"
to_mib() { case "$1" in *[Gg]) echo $(( ${1%[Gg]} * 1024 )) ;; *[Mm]) echo "${1%[Mm]}" ;; [0-9]*) echo $(( $1 / 1048576 )) ;; *) echo 0 ;; esac; }
CTR="$(forge_ctr)"
live=''
[ -n "$CTR" ] && live="$(docker inspect -f '{{.HostConfig.Memory}}' "$CTR" 2>/dev/null || true)"
dm="$(to_mib "${decl:-0}")"
if [ -z "$decl" ] || [ "$dm" -le 0 ] || [ "$dm" -gt 512 ]; then
    row mem-limit WARN "compose declares ${decl:-no} memory limit (want ≤ 512M)"
elif [ -n "$CTR" ] && { [ -z "$live" ] || [ "$live" = 0 ] || [ $((live/1048576)) -gt 512 ]; }; then
    row mem-limit WARN "declared $decl but the running container has ${live:-no} limit"
else
    row mem-limit OK "$decl${live:+ (live $((live/1048576)) MiB)}"
fi

# ports: live bindings when running, else the compose file
bad=''; seen=''
if [ -n "$CTR" ]; then
    binds="$(docker inspect -f '{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}{{.HostIp}}:{{.HostPort}}->{{$p}} {{end}}{{end}}' "$CTR" 2>/dev/null || true)"
    for b in $binds; do seen+="$b "; case "$b" in 127.0.0.1:*) ;; *) bad+="$b " ;; esac; done
else
    while IFS= read -r p; do
        p="$(printf '%s' "$p" | sed -E 's/^[[:space:]]*-[[:space:]]*//; s/"//g')"
        [ -n "$p" ] || continue
        seen+="$p "; case "$p" in 127.0.0.1:*) ;; *) bad+="$p " ;; esac
    done < <(awk '/^[[:space:]]*ports:/{f=1;next} f&&/^[[:space:]]*-/{print;next} f{f=0}' "$COMPOSE_FILE")
fi
if [ -z "$seen" ]; then row ports WARN "no published ports found"
elif [ -n "$bad" ]; then row ports WARN "not loopback: ${bad% }"
else row ports OK "loopback only: ${seen% }"; fi

m1="$(stat -c %a "$GEN/forge.env" 2>/dev/null || echo none)"; m2="$(stat -c %a "$INI" 2>/dev/null || echo none)"
[ "$m1" = 600 ] && [ "$m2" = 600 ] && row secrets OK "forge.env 600 · app.ini 600" || row secrets WARN "forge.env $m1 · app.ini $m2 (want 600)"

if [ -f "$GEN/token" ]; then
    mt="$(stat -c %a "$GEN/token")"
    [ "$mt" = 600 ] && row admin-token OK "token 600" || row admin-token WARN "token mode $mt (want 600)"
else
    row admin-token WARN "no token file yet (pol forge up)"
fi

total=$((NOK+NWARN))
if [ "$NWARN" = 0 ]; then
    printf "${F_BOLD}posture: OK %d/%d${F_NC} — registration off · anonymous read · indexer off · %s · loopback · secrets+token 600\n" "$NOK" "$total" "${decl:-?}"
    exit 0
fi
printf "${F_BOLD}posture: WARN %d/%d${F_NC} —" "$NWARN" "$total"
for s in "${SUMMARY[@]}"; do case "$s" in *WARN) printf ' %s' "${s% WARN}" ;; esac; done; echo
exit 2
