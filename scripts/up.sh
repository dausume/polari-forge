#!/bin/bash
# up.sh — `pol forge up`: render (if needed) → create → seed app.ini into the
# volume → start → wait for /api/v1/version → the admin user (first run) → the
# admin API token (.generated/forge/token, 600). Idempotent. Prints no secret.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
case "${1:-}" in -h|--help|help) sed -n '2,4p' "$0"; exit 0 ;; esac

[ -s "$GEN/app.ini" ] && [ -s "$GEN/forge.env" ] || bash "$FORGE_DIR/scripts/render.sh"
load_secrets

docker image inspect "$IMAGE" >/dev/null 2>&1 || { say "pulling $IMAGE"; docker pull "$IMAGE" >/dev/null; }

compose up --no-start >/dev/null 2>&1 || compose up --no-start
cid="$(compose ps -a -q "$SERVICE" | head -n1)"
[ -n "$cid" ] || die "compose created no container"

# Seed app.ini INTO the volume (see compose/forge.yml for why it is not mounted):
# a tar stream with numeric ownership = USER_UID, so the file is the git user's,
# mode 600, whatever user runs this.
. "$GEN/container.env"
seed="$GEN/.seed"; rm -rf "$seed"; mkdir -p "$seed/gitea/conf"
cp "$GEN/app.ini" "$seed/gitea/conf/app.ini"; chmod 600 "$seed/gitea/conf/app.ini"
running="$(forge_ctr)"
if [ -n "$running" ] && [ "$(docker exec "$running" sha256sum /data/gitea/conf/app.ini 2>/dev/null | cut -d' ' -f1)" = "$(sha256sum "$GEN/app.ini" | cut -d' ' -f1)" ]; then
    rm -rf "$seed"; okl "running; app.ini in the volume is the rendered one — no restart"
    running=keep
else
    tar -C "$seed" --numeric-owner --owner="$USER_UID" --group="$USER_GID" -cf - gitea \
        | docker cp -a - "$cid:/data/" >/dev/null
    rm -rf "$seed"
fi
if [ "$running" = keep ]; then
    :   # nothing changed
elif [ -n "$running" ]; then
    compose restart "$SERVICE" >/dev/null 2>&1   # pick up a re-rendered app.ini
else
    compose up -d >/dev/null 2>&1 || compose up -d
fi

# wait for the API
waited=0; ver=''
while [ "$waited" -lt "${FORGE_WAIT_S:-120}" ]; do
    api GET /api/v1/version
    if [ "$API_CODE" = 200 ]; then ver="$(printf '%s' "$API_BODY" | jget version)"; break; fi
    sleep 2; waited=$((waited+2))
done
[ -n "$ver" ] || die "the forge did not answer /api/v1/version within ${FORGE_WAIT_S:-120}s — pol forge status"
okl "Forgejo $ver answering on $FORGE_API (ROOT_URL $FORGE_ROOT_URL)"

CTR="$(forge_ctr)"
# the admin user, first run only (password from forge.env — never on screen)
if docker exec -u git "$CTR" forgejo admin user list --admin 2>/dev/null | awk 'NR>1{print $2}' | grep -qx "$FORGE_ADMIN"; then
    okl "admin user $FORGE_ADMIN present"
else
    # the password goes over stdin, not the docker client's argv
    printf '%s' "$ADMIN_PASSWORD" | docker exec -i -u git "$CTR" sh -c \
        'forgejo admin user create --admin --username "$1" --password "$(cat)" --email "$1@forge.invalid" --must-change-password=false' \
        sh "$FORGE_ADMIN" >/dev/null || die "could not create the admin user"
    okl "admin user $FORGE_ADMIN created (password: ADMIN_PASSWORD in $GEN/forge.env)"
fi

# the admin token — kept while it still works
bash "$FORGE_DIR/scripts/token.sh" --quiet
okl "up — the volume is $VOLUME; nothing of the forge's content is in this tree"
