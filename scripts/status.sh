#!/bin/bash
# status.sh — `pol forge status`: container, health, version, URL, volume, token.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
case "${1:-}" in -h|--help|help) sed -n '2p' "$0"; exit 0 ;; esac

CTR="$(forge_ctr)"
if [ -z "$CTR" ]; then
    warn "forge: not running (pol forge up)"
    docker volume inspect "$VOLUME" >/dev/null 2>&1 && say "volume:  $VOLUME (present)" || say "volume:  $VOLUME (absent)"
    exit 3
fi
health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$CTR" 2>/dev/null || echo '?')"
api GET /api/v1/version
ver="$( [ "$API_CODE" = 200 ] && printf '%s' "$API_BODY" | jget version || echo "no answer ($API_CODE)")"
say "forge:   running ($health) — container ${CTR:0:12}"
say "version: Forgejo $ver"
say "url:     $FORGE_ROOT_URL  (api $FORGE_API · ssh 127.0.0.1:$FORGE_SSH_PORT)"
say "volume:  $VOLUME"
if [ -s "$GEN/token" ]; then say "token:   $GEN/token (mode $(stat -c %a "$GEN/token"))"; else say "token:   none (pol forge token)"; fi
[ "$API_CODE" = 200 ]
