#!/bin/bash
# ready.sh — wait for the running forge to answer /api/v1/version, then make sure
# the admin user exists (first run: created with ADMIN_PASSWORD from forge.env,
# over stdin — never on screen, never in argv). Called by up.sh (compose home) and
# by `pol prod apply` (the swarm home: the task appears after `docker stack deploy`,
# so this also waits for the container itself). Prints no secret.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
case "${1:-}" in -h|--help|help) sed -n '2,6p' "$0"; exit 0 ;; esac
load_secrets

waited=0; ver=''
while [ "$waited" -lt "${FORGE_WAIT_S:-120}" ]; do
    if [ -n "$(forge_ctr)" ]; then
        api GET /api/v1/version
        if [ "$API_CODE" = 200 ]; then ver="$(printf '%s' "$API_BODY" | jget version)"; break; fi
    fi
    sleep 2; waited=$((waited+2))
done
[ -n "$ver" ] || die "the forge did not answer /api/v1/version within ${FORGE_WAIT_S:-120}s — pol forge status"
okl "Forgejo $ver answering on $(api_where) (ROOT_URL $FORGE_ROOT_URL)"

CTR="$(forge_ctr)"
if docker exec -u git "$CTR" forgejo admin user list --admin 2>/dev/null | awk 'NR>1{print $2}' | grep -qx "$FORGE_ADMIN"; then
    okl "admin user $FORGE_ADMIN present"
else
    # the password goes over stdin, not the docker client's argv
    printf '%s' "$ADMIN_PASSWORD" | docker exec -i -u git "$CTR" sh -c \
        'forgejo admin user create --admin --username "$1" --password "$(cat)" --email "$1@forge.invalid" --must-change-password=false' \
        sh "$FORGE_ADMIN" >/dev/null || die "could not create the admin user"
    okl "admin user $FORGE_ADMIN created (password: ADMIN_PASSWORD in ${FORGE_PASSWORD_WHERE:-$GEN/forge.env})"
fi
