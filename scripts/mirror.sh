#!/bin/bash
# mirror.sh — `pol forge mirror <owner/repo> | --forest | --sync [<owner/repo>|--forest] | --drop <owner/repo>`:
# pull-mirror GitHub repos onto the forge (POST /api/v1/repos/migrate, mirror: true, interval 168h = his ruling
# 2026-09-30: a WEEKLY check for changes; --sync asks for a fetch right now, e.g. after a release). The
# forge-side owner is an organisation of the same name, made on first use.
# Idempotent: a repo already on the forge is skipped, never re-imported.
#
# --forest honours forest.txt's hold= field (his ruling 2026-09-30; default mirror when absent):
#   mirror   migrated as today
#   primary  NOT implemented this slice — treated as mirror, with one printed note
#   link     NOT migrated — recorded in .generated/forge/links.txt instead (pol forge links)
# --sync --forest skips link lines (nothing to fetch for a repo that is not held).
# --drop <owner/repo> removes a repo from the forge, but only when it IS a mirror — never a
# primary/non-mirror repo, which is refused with the reason.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
case "${1:-}" in ''|-h|--help|help) sed -n '2,14p' "$0"; [ -n "${1:-}" ]; exit $? ;; esac
[ -s "$GEN/token" ] || die "no admin token — pol forge up (or pol forge token)"

ensure_org() {
    local o="$1"
    api GET "/api/v1/orgs/$o"
    [ "$API_CODE" = 200 ] && return 0
    api POST /api/v1/orgs "{\"username\":\"$o\",\"visibility\":\"public\",\"repo_admin_change_team_access\":false}"
    case "$API_CODE" in 201|422) return 0 ;; esac
    die "could not create organisation $o on the forge (HTTP $API_CODE): $API_BODY"
}

split_spec() {  # split_spec <owner/repo> → sets OW, RP (validated); dies on nonsense
    local spec="$1"
    case "$spec" in */*) ;; *) die "expected owner/repo, got '$spec'" ;; esac
    OW="${spec%%/*}"; RP="${spec#*/}"; RP="${RP%.git}"
    case "$OW$RP" in *[!A-Za-z0-9._-]*) die "refusing a name with odd characters: $spec" ;; esac
}

mirror_one() {
    local spec="$1" OW RP
    split_spec "$spec"
    api GET "/api/v1/repos/$OW/$RP"
    if [ "$API_CODE" = 200 ]; then
        say "skip   $OW/$RP — already on the forge (mirror: $(printf '%s' "$API_BODY" | jget mirror))"
        return 0
    fi
    ensure_org "$OW"
    local body
    body="$(printf '{"clone_addr":"%s/%s/%s.git","repo_owner":"%s","repo_name":"%s","mirror":true,"mirror_interval":"168h","private":false,"service":"git","wiki":false,"issues":false,"pull_requests":false,"releases":false,"labels":false,"milestones":false,"lfs":false,"description":"mirror of %s/%s/%s"}' \
        "$FORGE_GITHUB" "$OW" "$RP" "$OW" "$RP" "$FORGE_GITHUB" "$OW" "$RP")"
    api POST /api/v1/repos/migrate "$body"
    case "$API_CODE" in
        201) say "mirror $OW/$RP ← $FORGE_GITHUB/$OW/$RP (empty: $(printf '%s' "$API_BODY" | jget empty))" ;;
        409) say "skip   $OW/$RP — already exists (409)" ;;
        *)   die "migrate $OW/$RP failed (HTTP $API_CODE): $API_BODY" ;;
    esac
}

link_one() {  # link_one <owner/repo> — NOT held: record the pointer, warn if it is actually held
    local spec="$1" OW RP url
    split_spec "$spec"
    url="$FORGE_GITHUB/$OW/$RP"
    api GET "/api/v1/repos/$OW/$RP"
    if [ "$API_CODE" = 200 ]; then
        warn "link   $OW/$RP is already held on the forge — pol forge mirror --drop $OW/$RP would remove it"
    fi
    mkdir -p "$GEN"
    [ -f "$GEN/links.txt" ] && grep -v "^$OW/$RP " "$GEN/links.txt" > "$GEN/links.txt.tmp" 2>/dev/null && mv "$GEN/links.txt.tmp" "$GEN/links.txt" || rm -f "$GEN/links.txt.tmp"
    printf '%s %s\n' "$OW/$RP" "$url" >> "$GEN/links.txt"
    say "link   $OW/$RP → $url (not held)"
}

drop_one() {  # drop_one <owner/repo> — DELETE, but only a mirror; a non-mirror is refused
    local spec="$1" OW RP is_mirror
    split_spec "$spec"
    api GET "/api/v1/repos/$OW/$RP"
    case "$API_CODE" in
        404) die "$OW/$RP is not on the forge" ;;
        200) ;;
        *)   die "could not check $OW/$RP (HTTP $API_CODE): $API_BODY" ;;
    esac
    is_mirror="$(printf '%s' "$API_BODY" | jget mirror)"
    case "$is_mirror" in
        true) ;;
        *) die "refusing to drop $OW/$RP — it is not a mirror (mirror: ${is_mirror:-false}); --drop never removes a primary/non-mirror repo" ;;
    esac
    api DELETE "/api/v1/repos/$OW/$RP"
    case "$API_CODE" in
        200|204) okl "dropped $OW/$RP — was a mirror, removed from the forge" ;;
        *)       die "drop $OW/$RP failed (HTTP $API_CODE): $API_BODY" ;;
    esac
}

sync_one() {  # sync_one <owner/repo> — ask the forge to fetch this mirror now (weekly otherwise)
    local owner="${1%%/*}" repo="${1##*/}"
    api POST "/api/v1/repos/$owner/$repo/mirror-sync" ""
    case "$API_CODE" in 200) okl "sync   $owner/$repo — fetch queued (the weekly check would have waited)" ;;
        404) warn "sync   $owner/$repo is not on the forge — pol forge mirror $owner/$repo" ;;
        *)   die "sync $owner/$repo failed (HTTP $API_CODE): $API_BODY" ;; esac
}

# forest_lines prints "<owner/repo> <hold>" per non-comment line of forest.txt (hold
# defaults to mirror when the line carries no hold=... field).
forest_lines() {
    local list="${FORGE_FOREST:-$FORGE_DIR/forest.txt}"; [ -f "$list" ] || die "missing $list"
    local line spec hold tok
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        set -f; set -- $line; set +f
        spec="${1:-}"; [ -n "$spec" ] || continue
        hold=mirror; shift
        for tok in "$@"; do case "$tok" in hold=*) hold="${tok#hold=}" ;; esac; done
        case "$hold" in primary|mirror|link) ;; *) die "$list: unknown hold=$hold for $spec (want primary|mirror|link)" ;; esac
        printf '%s %s\n' "$spec" "$hold"
    done < "$list"
}

if [ "$1" = --drop ]; then
    shift; [ -n "${1:-}" ] || die "usage: pol forge mirror --drop <owner/repo>"
    drop_one "$1"
    exit 0
fi
if [ "$1" = --sync ]; then
    shift; [ -n "${1:-}" ] || die "usage: pol forge mirror --sync <owner/repo> | --sync --forest"
    if [ "$1" = --forest ]; then
        n=0; skipped=0
        while read -r spec hold; do
            if [ "$hold" = link ]; then skipped=$((skipped+1)); continue; fi
            sync_one "$spec"; n=$((n+1))
        done < <(forest_lines)
        okl "forest: sync asked for $n repos ($skipped link entries skipped)"
    else sync_one "$1"; fi
    exit 0
fi
if [ "$1" = --forest ]; then
    n=0
    while read -r spec hold; do
        case "$hold" in
            mirror)  mirror_one "$spec" ;;
            primary) say "note   $spec: hold=primary — not yet: treated as mirror"; mirror_one "$spec" ;;
            link)    link_one "$spec" ;;
        esac
        n=$((n+1))
    done < <(forest_lines)
    okl "forest: $n repos considered from $(basename "${FORGE_FOREST:-$FORGE_DIR/forest.txt}")"
else
    mirror_one "$1"
fi
