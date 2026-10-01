#!/bin/bash
# token.sh — `pol forge token [--new]`: the admin API token in .generated/forge/token (600).
# Kept while GET /api/v1/user accepts it; minted again (scopes: all) when it is
# missing or refused, or with --new. Prints the file path, never the token.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
NEW=0; QUIET=0
for a in "$@"; do case "$a" in --new) NEW=1 ;; --quiet) QUIET=1 ;; -h|--help|help) sed -n '2,4p' "$0"; exit 0 ;; esac; done
need_ctr
umask 077; mkdir -p "$GEN"

if [ "$NEW" = 0 ] && [ -s "$GEN/token" ]; then
    api GET /api/v1/user
    if [ "$API_CODE" = 200 ]; then
        chmod 600 "$GEN/token"
        okl "admin token valid, kept: $GEN/token (mode 600)"
        exit 0
    fi
fi
name="pol-forge-$(date +%Y%m%d%H%M%S)"
tok="$(docker exec -u git "$CTR" forgejo admin user generate-access-token \
        --username "$FORGE_ADMIN" --token-name "$name" --scopes all --raw 2>/dev/null | tail -n1 | tr -d '[:space:]')"
[ -n "$tok" ] || die "could not mint an admin token for $FORGE_ADMIN"
printf '%s\n' "$tok" > "$GEN/token"; chmod 600 "$GEN/token"
okl "admin token minted ($name): $GEN/token (mode 600)"
