#!/bin/bash
# status.sh — `pol forge status`: container (compose or swarm task), health, version, URL, volume, token.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
case "${1:-}" in -h|--help|help) sed -n '2p' "$0"; exit 0 ;; esac

CTR="$(forge_ctr)"
if [ -z "$CTR" ]; then
    if forge_is_service; then warn "forge: the pol prod service has no running task here (pol prod status)"; else warn "forge: not running (pol forge up)"; fi
    docker volume inspect "$VOLUME" >/dev/null 2>&1 && say "volume:  $VOLUME (present)" || say "volume:  $VOLUME (absent)"
    exit 3
fi
health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$CTR" 2>/dev/null || echo '?')"
api GET /api/v1/version
ver="$( [ "$API_CODE" = 200 ] && printf '%s' "$API_BODY" | jget version || echo "no answer ($API_CODE)")"
say "forge:   running ($health) — $(forge_mode) — container ${CTR:0:12}"
say "version: Forgejo $ver"
if [ "$(forge_mode)" = swarm ]; then
    say "url:     $FORGE_ROOT_URL  (api $(api_where) · ssh not exposed — https only)"
else
    say "url:     $FORGE_ROOT_URL  (api $FORGE_API · ssh 127.0.0.1:$FORGE_SSH_PORT)"
fi
say "volume:  $VOLUME"
w="$(token_where)"; [ "$w" = none ] && say "token:   none (pol forge token)" || say "token:   $w"
[ "$API_CODE" = 200 ]
