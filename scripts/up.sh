#!/bin/bash
# up.sh — `pol forge up`: render (if needed) → create → seed app.ini into the
# volume → start → wait for /api/v1/version → the admin user (first run) → the
# admin API token (.generated/forge/token, 600). Idempotent. Prints no secret.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
case "${1:-}" in -h|--help|help) sed -n '2,4p' "$0"; exit 0 ;; esac
refuse_if_service   # frg-2: a forge that is a pol prod stack service is pol prod's to start

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

# wait for the API, then the admin user on first run (password from forge.env — never on screen)
bash "$FORGE_DIR/scripts/ready.sh"

# the admin token — kept while it still works
bash "$FORGE_DIR/scripts/token.sh" --quiet
okl "up — the volume is $VOLUME; nothing of the forge's content is in this tree"
