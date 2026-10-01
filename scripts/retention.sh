#!/bin/bash
# retention.sh — `pol forge retention <K> [--dry-run] [--owner <o>]`: package RETENTION.
# Git history is never trimmed (the whole forest packs to ~50 MB). The Debian
# registry is: per package the newest K versions are kept, plus everything
# keep.txt names — a line `name` keeps every version of that package, a line
# `name@version` keeps that one. The rest is deleted through the API.
# --dry-run prints what would go and deletes nothing. Bytes before/after come
# from the meter (packages area).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
K=''; DRY=0; OWNER="$FORGE_OWNER"; TYPE="${FORGE_RETENTION_TYPE:-debian}"
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY=1 ;;
        --owner) OWNER="$2"; shift ;;
        -h|--help|help) sed -n '2,8p' "$0"; exit 0 ;;
        *) K="$1" ;;
    esac; shift
done
case "$K" in ''|*[!0-9]*) die "usage: retention <K> [--dry-run] [--owner <o>] — K = versions kept per package (e.g. 3)" ;; esac
[ "$K" -ge 1 ] || die "K must be at least 1 (retention never empties a package)"
[ -s "$GEN/token" ] || die "no admin token — pol forge up"
KEEP="${FORGE_KEEP:-$FORGE_DIR/keep.txt}"

pkgs_mib() { bash "$FORGE_DIR/scripts/meter.sh" --json 2>/dev/null | jget areas.packages; }
before="$(pkgs_mib || true)"

# every version of every package of this type, all pages
all='[]'; page=1
while [ "$page" -le 400 ]; do
    api GET "/api/v1/packages/$OWNER?type=$TYPE&limit=50&page=$page"
    [ "$API_CODE" = 200 ] || die "listing packages of $OWNER failed (HTTP $API_CODE): $API_BODY"
    n="$(printf '%s' "$API_BODY" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
    [ "$n" -gt 0 ] || break
    all="$(ALL="$all" PAGE="$API_BODY" python3 -c 'import json,os; print(json.dumps(json.loads(os.environ["ALL"])+json.loads(os.environ["PAGE"])))')"
    page=$((page+1))
done

plan="$(ALL="$all" K="$K" KEEPF="$KEEP" python3 - <<'PY'
import json, os
rows = json.loads(os.environ['ALL']); K = int(os.environ['K'])
keep_names, keep_pins = set(), set()
try:
    for l in open(os.environ['KEEPF']):
        l = l.split('#', 1)[0].strip()
        if not l: continue
        if '@' in l: keep_pins.add(tuple(l.split('@', 1)))
        else: keep_names.add(l)
except FileNotFoundError:
    pass
by = {}
for r in rows: by.setdefault(r['name'], []).append(r)
for name in sorted(by):
    vs = sorted(by[name], key=lambda r: (r.get('created_at') or '', r.get('id') or 0), reverse=True)
    for i, r in enumerate(vs):
        v = r['version']
        if i < K: why = 'newest-%d' % (i + 1)
        elif name in keep_names: why = 'keep.txt'
        elif (name, v) in keep_pins: why = 'keep.txt@'
        else: why = ''
        print('%s\t%s\t%s' % ('KEEP' if why else 'DELETE', name, v) + ('\t' + why if why else ''))
PY
)"
kept="$(printf '%s\n' "$plan" | grep -c '^KEEP' || true)"
gone="$(printf '%s\n' "$plan" | grep -c '^DELETE' || true)"
[ -n "$plan" ] && printf '%s\n' "$plan" | awk -F'\t' '{printf "  %-6s %-40s %-24s %s\n",$1,$2,$3,$4}'

if [ "$DRY" = 1 ]; then
    okl "retention K=$K ($OWNER/$TYPE) DRY-RUN: $kept kept, $gone would be deleted — nothing deleted (packages ${before:-?} MiB)"
    exit 0
fi
# Debian: delete through the registry's OWN door (pool/<dist>/<comp>/<name>/<version>/<arch>) so the
# signed Packages/Release index is rebuilt. The generic /api/v1/packages DELETE removes the version but
# leaves it LISTED in the apt index (found live 2026-09-30) — apt would then 404 on it. The generic door
# is only the fallback, with a warning naming that consequence.
DIST="${FORGE_APT_DIST:-stable}"; COMP="${FORGE_APT_COMPONENT:-main}"
deleted=0
while IFS=$'\t' read -r verdict name ver _; do
    [ "$verdict" = DELETE ] || continue
    done_one=0
    if [ "$TYPE" = debian ]; then
        api GET "/api/v1/packages/$OWNER/debian/$name/$ver/files"
        archs="$(printf '%s' "$API_BODY" | python3 -c 'import json,sys
try: fs=json.load(sys.stdin)
except Exception: fs=[]
print(" ".join(sorted({f["name"].rsplit("_",1)[-1][:-4] for f in fs if f.get("name","").endswith(".deb")})))')"
        for arch in $archs; do
            api DELETE "/api/packages/$OWNER/debian/pool/$DIST/$COMP/$name/$ver/$arch"
            case "$API_CODE" in 204|200) done_one=1 ;; esac
        done
    fi
    if [ "$done_one" = 0 ]; then
        api DELETE "/api/v1/packages/$OWNER/$TYPE/$name/$ver"
        case "$API_CODE" in
            204|200) done_one=1
                     if [ "$TYPE" = debian ]; then warn "$name $ver was not in $DIST/$COMP — removed by the generic door; that distribution's apt index may still list it"; fi ;;
            *) warn "delete $name $ver failed (HTTP $API_CODE)" ;;
        esac
    fi
    if [ "$done_one" = 1 ]; then deleted=$((deleted+1)); fi
done <<< "$plan"
after="$(pkgs_mib || true)"
okl "retention K=$K ($OWNER/$TYPE): $kept kept, $deleted deleted — packages ${before:-?} MiB → ${after:-?} MiB"
