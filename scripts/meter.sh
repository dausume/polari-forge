#!/bin/bash
# meter.sh — `pol forge meter [--json]`: THE STORAGE METER. One JSON line
#   {at, rss_mib, peak_mib, cpu_pct, data_mib, areas:{git,packages,db,attachments,log},
#    repos, packages, held, linked, primary}
# appended to .generated/forge/meter.jsonl and printed as a table (--json: the
# line only). rss/cpu from `docker stats`; peak from the container's cgroup
# memory.peak (null when unreadable); sizes from `du -sm` inside the container.
# held = repos on the forge that are mirrors (GET /api/v1/orgs/<owner>/repos, paginated);
# linked = lines in .generated/forge/links.txt (hold=link, not held — pol forge links);
# primary = 0 for now (his ruling 2026-09-30: not implemented this slice).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
JSON=0
case "${1:-}" in --json) JSON=1 ;; -h|--help|help) sed -n '2,10p' "$0"; exit 0 ;; esac
need_ctr
mkdir -p "$GEN"

stats="$(docker stats --no-stream --format '{{.MemUsage}}|{{.CPUPerc}}' "$CTR" 2>/dev/null || echo '|')"
peak="$(docker exec "$CTR" cat /sys/fs/cgroup/memory.peak 2>/dev/null || true)"
# one exec for every area (missing path → 0)
sizes="$(docker exec "$CTR" sh -c '
  for p in /data /data/git/repositories /data/gitea/packages /data/gitea/forgejo.db /data/gitea/attachments /data/gitea/log; do
    if [ -e "$p" ]; then du -sm "$p" | cut -f1; else echo 0; fi
  done
  find /data/git/repositories -mindepth 2 -maxdepth 2 -type d -name "*.git" 2>/dev/null | wc -l' 2>/dev/null || true)"
# package versions (every type) under the owner, counted page by page
pk=0
if [ -s "$GEN/token" ]; then
    page=1
    while [ "$page" -le 200 ]; do
        api GET "/api/v1/packages/$FORGE_OWNER?limit=50&page=$page"
        [ "$API_CODE" = 200 ] || break
        c="$(printf '%s' "$API_BODY" | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin)))
except Exception: print(0)')"
        [ "$c" -gt 0 ] || break
        pk=$((pk+c)); page=$((page+1))
    done
fi

# held: repos under FORGE_OWNER that are mirrors, counted page by page
held=0
if [ -s "$GEN/token" ]; then
    page=1
    while [ "$page" -le 200 ]; do
        api GET "/api/v1/orgs/$FORGE_OWNER/repos?limit=50&page=$page"
        [ "$API_CODE" = 200 ] || break
        read -r c m <<<"$(printf '%s' "$API_BODY" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: d=[]
print(len(d), sum(1 for r in d if r.get("mirror")))')"
        [ -n "${c:-}" ] && [ "$c" -gt 0 ] || break
        held=$((held+m)); page=$((page+1))
    done
fi
# linked: lines in links.txt (hold=link entries — not held)
linked=0
if [ -s "$GEN/links.txt" ]; then
    linked="$(grep -cve '^[[:space:]]*$' "$GEN/links.txt" || true)"
    linked="${linked:-0}"
fi
primary=0   # not implemented this slice (his ruling 2026-09-30)

line="$(STATS="$stats" PEAK="$peak" SIZES="$sizes" PK="${pk:-0}" HELD="$held" LINKED="$linked" PRIMARY="$primary" python3 - <<'PY'
import json, os, re, datetime
def mib(s):
    m = re.match(r'\s*([\d.]+)\s*([KMGT]?i?B)', s or '')
    if not m: return None
    v, u = float(m.group(1)), m.group(2)
    f = {'B': 1/1048576, 'KiB': 1/1024, 'KB': 1/1024, 'kB': 1/1024, 'MiB': 1, 'MB': 1, 'GiB': 1024, 'GB': 1024, 'TiB': 1048576, 'TB': 1048576}.get(u, 1)
    return round(v * f, 1)
mem, _, cpu = os.environ['STATS'].partition('|')
peak = os.environ['PEAK'].strip()
sz = [l.strip() for l in os.environ['SIZES'].splitlines() if l.strip()]
n = lambda i: int(sz[i]) if len(sz) > i and sz[i].isdigit() else None
print(json.dumps({
    'at': datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat(),
    'rss_mib': mib(mem.split('/')[0]),
    'peak_mib': round(int(peak) / 1048576, 1) if peak.isdigit() else None,
    'cpu_pct': float(cpu.strip().rstrip('%')) if re.match(r'\s*[\d.]+%', cpu or '') else None,
    'data_mib': n(0),
    'areas': {'git': n(1), 'packages': n(2), 'db': n(3), 'attachments': n(4), 'log': n(5)},
    'repos': n(6),
    'packages': int(os.environ['PK']) if os.environ['PK'].isdigit() else 0,
    'held': int(os.environ['HELD']) if os.environ['HELD'].isdigit() else 0,
    'linked': int(os.environ['LINKED']) if os.environ['LINKED'].isdigit() else 0,
    'primary': int(os.environ['PRIMARY']) if os.environ['PRIMARY'].isdigit() else 0,
}, separators=(',', ':')))
PY
)"
printf '%s\n' "$line" >> "$GEN/meter.jsonl"
if [ "$JSON" = 1 ]; then printf '%s\n' "$line"; exit 0; fi
printf '%s\n' "$line"
printf '%s' "$line" | python3 -c '
import json, sys
d = json.load(sys.stdin); a = d["areas"]
f = lambda v, u="": "—" if v is None else "%s%s" % (v, u)
rows = [("at", d["at"]), ("rss", f(d["rss_mib"], " MiB")), ("peak", f(d["peak_mib"], " MiB")),
        ("cpu", f(d["cpu_pct"], " %")), ("data (total)", f(d["data_mib"], " MiB"))]
rows += [("  " + k, f(a[k], " MiB")) for k in ("git", "packages", "db", "attachments", "log")]
rows += [("repos", f(d["repos"])), ("packages", f(d["packages"]))]
rows += [("held", f(d["held"])), ("linked", f(d["linked"])), ("primary", f(d["primary"]))]
for k, v in rows: print("  %-14s %s" % (k, v))'
say "  (appended to $GEN/meter.jsonl)"
