#!/bin/bash
# render.sh — `pol forge render`: secrets once, then app.ini + container.env.
#
#   .generated/forge/forge.env      the secrets, made ONCE, mode 600, never printed:
#                                   SECRET_KEY INTERNAL_TOKEN ADMIN_PASSWORD = `openssl rand -hex 32`;
#                                   JWT_SECRET LFS_JWT_SECRET = 32 random bytes, base64url (Forgejo's shape)
#   .generated/forge/container.env  USER_UID / USER_GID — the only env the container gets
#   .generated/forge/app.ini        config/app.ini.template filled in bash (no jinja,
#                                   no envsubst dependency), mode 600
# Re-running keeps the secrets and re-renders the rest (knob changes apply on the next up).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
case "${1:-}" in -h|--help|help) sed -n '2,11p' "$0"; exit 0 ;; esac

umask 077
mkdir -p "$GEN"
chmod 700 "$GEN" 2>/dev/null || true

# The two JWT secrets must be 32 bytes in base64url WITHOUT padding (43 chars): Forgejo
# rejects anything else and silently writes a fresh one into app.ini at start (found
# live in frg-0 — a hex value was replaced on every boot). The rest are `-hex 32`.
b64url32() { openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n'; }
if [ ! -s "$GEN/forge.env" ]; then
    command -v openssl >/dev/null || die "openssl is needed to generate the forge's secrets"
    {
        echo "# polari-forge secrets — generated $(date -Is) by render.sh. NEVER commit, NEVER print."
        for k in SECRET_KEY INTERNAL_TOKEN ADMIN_PASSWORD; do printf '%s=%s\n' "$k" "$(openssl rand -hex 32)"; done
        for k in JWT_SECRET LFS_JWT_SECRET; do printf '%s=%s\n' "$k" "$(b64url32)"; done
    } > "$GEN/forge.env"
    okl "secrets generated: $GEN/forge.env (mode 600)"
else
    # repair a JWT secret in the wrong shape (an older render), keeping every other secret
    for k in JWT_SECRET LFS_JWT_SECRET; do
        if ! grep -qE "^$k=[A-Za-z0-9_-]{43}\$" "$GEN/forge.env"; then
            grep -v "^$k=" "$GEN/forge.env" > "$GEN/forge.env.new" || true
            printf '%s=%s\n' "$k" "$(b64url32)" >> "$GEN/forge.env.new"
            mv "$GEN/forge.env.new" "$GEN/forge.env"
            okl "$k regenerated in the base64url shape Forgejo requires"
        fi
    done
    okl "secrets kept: $GEN/forge.env"
fi
chmod 600 "$GEN/forge.env"
load_secrets

# Forgejo refuses to run as root: a root host user maps to 1000.
uid="$(id -u)"; gid="$(id -g)"
[ "$uid" = 0 ] && uid=1000 && gid=1000
printf 'USER_UID=%s\nUSER_GID=%s\n' "$uid" "$gid" > "$GEN/container.env"
chmod 600 "$GEN/container.env"

# ---------------------------------------------------------------- app.ini
ROOT_URL="$FORGE_ROOT_URL"; DOMAIN="$FORGE_DOMAIN"; SSH_DOMAIN="${FORGE_SSH_DOMAIN:-$FORGE_DOMAIN}"
HTTP_PORT=3000; SSH_PORT="$FORGE_SSH_PORT"
shopt -u patsub_replacement 2>/dev/null || true   # bash 5.2: '&' in a replacement must stay literal
tmpl="$FORGE_DIR/config/app.ini.template"
[ -f "$tmpl" ] || die "missing $tmpl"
out=""
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        *'${'*)
            for v in ROOT_URL DOMAIN SSH_DOMAIN HTTP_PORT SSH_PORT SECRET_KEY INTERNAL_TOKEN JWT_SECRET LFS_JWT_SECRET; do
                line="${line//\$\{$v\}/${!v}}"
            done ;;
    esac
    out+="$line"$'\n'
done < "$tmpl"
# a placeholder left over (or filled with nothing) is a refusal, not a warning
left="$(printf '%s' "$out" | grep -v '^[[:space:]]*;' | grep -n '\${' || true)"
[ -z "$left" ] || die "unfilled placeholders in app.ini: $left"
empty="$(printf '%s' "$out" | grep -nE '^(SECRET_KEY|INTERNAL_TOKEN|JWT_SECRET|LFS_JWT_SECRET|ROOT_URL|DOMAIN)[[:space:]]*=[[:space:]]*$' || true)"
[ -z "$empty" ] || die "empty values in app.ini: $empty"
printf '%s' "$out" > "$GEN/app.ini"
chmod 600 "$GEN/app.ini"
okl "rendered $GEN/app.ini (ROOT_URL $ROOT_URL · http 127.0.0.1:$FORGE_HTTP_PORT · ssh 127.0.0.1:$FORGE_SSH_PORT · USER_UID $uid)"
