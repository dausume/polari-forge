#!/bin/bash
# mirror.sh — `pol forge mirror <owner/repo> | --forest`: pull-mirror GitHub repos
# onto the forge (POST /api/v1/repos/migrate, mirror: true, interval 8h). The
# forge-side owner is an organisation of the same name, made on first use.
# Idempotent: a repo already on the forge is skipped, never re-imported.
# --forest mirrors every owner/repo line of forest.txt (# comments allowed).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
case "${1:-}" in ''|-h|--help|help) sed -n '2,6p' "$0"; [ -n "${1:-}" ]; exit $? ;; esac
[ -s "$GEN/token" ] || die "no admin token — pol forge up (or pol forge token)"

ensure_org() {
    local o="$1"
    api GET "/api/v1/orgs/$o"
    [ "$API_CODE" = 200 ] && return 0
    api POST /api/v1/orgs "{\"username\":\"$o\",\"visibility\":\"public\",\"repo_admin_change_team_access\":false}"
    case "$API_CODE" in 201|422) return 0 ;; esac
    die "could not create organisation $o on the forge (HTTP $API_CODE): $API_BODY"
}

mirror_one() {
    local spec="$1" owner repo
    case "$spec" in */*) ;; *) die "expected owner/repo, got '$spec'" ;; esac
    owner="${spec%%/*}"; repo="${spec#*/}"; repo="${repo%.git}"
    case "$owner$repo" in *[!A-Za-z0-9._-]*) die "refusing a name with odd characters: $spec" ;; esac
    api GET "/api/v1/repos/$owner/$repo"
    if [ "$API_CODE" = 200 ]; then
        say "skip   $owner/$repo — already on the forge (mirror: $(printf '%s' "$API_BODY" | jget mirror))"
        return 0
    fi
    ensure_org "$owner"
    local body
    body="$(printf '{"clone_addr":"%s/%s/%s.git","repo_owner":"%s","repo_name":"%s","mirror":true,"mirror_interval":"8h","private":false,"service":"git","wiki":false,"issues":false,"pull_requests":false,"releases":false,"labels":false,"milestones":false,"lfs":false,"description":"mirror of %s/%s/%s"}' \
        "$FORGE_GITHUB" "$owner" "$repo" "$owner" "$repo" "$FORGE_GITHUB" "$owner" "$repo")"
    api POST /api/v1/repos/migrate "$body"
    case "$API_CODE" in
        201) say "mirror $owner/$repo ← $FORGE_GITHUB/$owner/$repo (empty: $(printf '%s' "$API_BODY" | jget empty))" ;;
        409) say "skip   $owner/$repo — already exists (409)" ;;
        *)   die "migrate $owner/$repo failed (HTTP $API_CODE): $API_BODY" ;;
    esac
}

if [ "$1" = --forest ]; then
    list="${FORGE_FOREST:-$FORGE_DIR/forest.txt}"
    [ -f "$list" ] || die "missing $list"
    n=0
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"; line="$(printf '%s' "$line" | tr -d '[:space:]')"
        [ -n "$line" ] || continue
        mirror_one "$line"; n=$((n+1))
    done < "$list"
    okl "forest: $n repos considered from $(basename "$list")"
else
    mirror_one "$1"
fi
