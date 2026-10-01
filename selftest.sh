#!/bin/bash
# polari-forge/selftest.sh — frg-0's own tests. No docker, no network, no forge:
# the scripts run in a sandbox copy of this project (its own git repo) with PATH
# shims for `docker` and `curl` that answer like a running Forgejo. Ends with
# THE CLEAN-TREE RULE: after a simulated run that writes everything a run writes
# (and the leftovers a bind mount would leave), `git status --porcelain` in the
# project is EMPTY — every generated path is gitignored.
#
#   selftest.sh [-v] [--help]      → prints N/N and exits non-zero on a miss
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERBOSE=0
case "${1:-}" in -v) VERBOSE=1 ;; --help|-h) sed -n '2,9p' "$0"; exit 0 ;; esac

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); [ "$VERBOSE" = 1 ] && printf '  ok   %s\n' "$1" || true; }
bad()  { FAIL=$((FAIL+1)); printf '  MISS %s\n     expected: %s\n     got: %s\n' "$1" "$2" "${3//$'\n'/ | }"; }
has()  { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "…$2…" "$3" ;; esac; }
hasnt(){ case "$3" in *"$2"*) bad "$1" "NOT …$2…" "$3" ;; *) ok "$1" ;; esac; }
eq()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }

# ---------------------------------------------------------------- the sandbox project
P="$T/proj"; mkdir -p "$P"
( cd "$HERE" && git ls-files -co --exclude-standard 2>/dev/null || find . -type f -not -path './.git/*' -not -path './.generated/*' ) \
    | while IFS= read -r f; do mkdir -p "$P/$(dirname "$f")"; cp -p "$HERE/$f" "$P/$f"; done
# make sure the tree under test has the files even outside a git checkout
for f in .gitignore compose/forge.yml config/app.ini.template forest.txt keep.txt; do [ -f "$P/$f" ] || cp "$HERE/$f" "$P/$f"; done
git -C "$P" init -q -b dev 2>/dev/null || git -C "$P" init -q
git -C "$P" -c user.email=t@forge.invalid -c user.name=selftest add -A
git -C "$P" -c user.email=t@forge.invalid -c user.name=selftest commit -qm sandbox
eq "sandbox starts clean" "" "$(git -C "$P" status --porcelain)"

S="$T/state"; mkdir -p "$S" "$T/bin"
export FAKE_STATE="$S" FORGE_WAIT_S=4
G="$P/.generated/forge"

# ---------------------------------------------------------------- the shims
cat > "$T/bin/docker" <<'SH'
#!/bin/bash
S="$FAKE_STATE"; printf '%s\n' "$*" >> "$S/docker.log"
CID=fakecid0123456789
case "$1" in
  image)   exit 0 ;;
  pull)    exit 0 ;;
  volume)  exit 0 ;;
  # FAKE_SWARM=1: the forge runs as a pol prod stack task (frg-2) — no compose container,
  # a container labelled com.docker.swarm.service.name=polari-lean_forge, the service exists
  ps)      if [ -n "${FAKE_SWARM:-}" ]; then
               case "$*" in *"com.docker.swarm.service.name=polari-lean_forge"*) [ -f "$S/running" ] && echo "$CID" ;; esac
           else
               case "$*" in *com.docker.swarm*) ;; *) [ -f "$S/running" ] && echo "$CID" ;; esac
           fi; exit 0 ;;
  service) [ -n "${FAKE_SWARM:-}" ] || exit 1
           case "$*" in *Endpoint.Ports*) printf '%s' "${FAKE_SVC_PORTS:-}" ;; esac; exit 0 ;;
  stats)   echo "${FAKE_STATS:-94.2MiB / 512MiB|0.50%}"; exit 0 ;;
  cp)      # docker cp -a - <cid>:/data/  — record the tar's listing, never its secrets
           tar -tvf - --numeric-owner > "$S/cp.list"; exit 0 ;;
  inspect) case "$*" in
             *HostConfig.Memory*)   echo "${FAKE_MEM-536870912}" ;;
             *swarm.service.name*)  echo polari-lean_forge ;;
             *PortBindings*)        echo "${FAKE_BINDS-127.0.0.1:2222->22/tcp 127.0.0.1:3300->3000/tcp }" ;;
             *Health*)              echo healthy ;;
           esac; exit 0 ;;
  compose) shift
           while [ $# -gt 0 ]; do case "$1" in -f|--project-name|-p) shift 2 ;; *) break ;; esac; done
           case "$1" in
             up)      case "$*" in *-d*) touch "$S/running" ;; esac ;;
             ps)      echo "$CID" ;;
             down)    rm -f "$S/running" ;;
           esac; exit 0 ;;
  exec)    case "$*" in
             # the swarm home's API route: docker exec -i <task> curl … -H @- http://localhost:3000/…
             *" curl "*)                   echo "exec curl" >> "$S/exec-curl.log"
                                           while [ $# -gt 0 ] && [ "$1" != curl ]; do shift; done; shift
                                           exec "$(dirname "$0")/curl" "$@" ;;
             *"admin user list"*)         echo "ID   Username     Email"; [ -f "$S/admin" ] && echo "1    polari-admin x@forge.invalid" ;;
             *"admin user create"*)        cat > /dev/null; touch "$S/admin"; echo "created" ;;
             *generate-access-token*)      echo "faketoken0123456789abcdef" ;;
             *memory.peak*)                echo "${FAKE_PEAK:-480247808}" ;;
             *sha256sum*)                  echo "${FAKE_SHA:-0}  /data/gitea/conf/app.ini" ;;
             *"du -sm"*)                   printf '51\n40\n2\n3\n1\n1\n13\n' ;;
           esac; exit 0 ;;
esac
exit 0
SH
cat > "$T/bin/curl" <<'SH'
#!/bin/bash
# a scripted Forgejo: answers on stdout as `body\ncode` (the callers use -w '\n%{http_code}')
S="$FAKE_STATE"; M=GET; D=''; AUTH=''; URL=''
printf '%s\n' "$*" >> "$S/curl.log"
while [ $# -gt 0 ]; do
  case "$1" in
    -X) M="$2"; shift ;;
    --data) D="$2"; shift ;;
    -H) case "$2" in @-) AUTH="$(cat)" ;; @*) f="${2#@}"; AUTH="$(cat "$f" 2>/dev/null)" ;; esac; shift ;;
    -w|-o) shift ;;
    -*) ;;
    *) URL="$1" ;;
  esac; shift
done
P="/${URL#*://*/}"; PATHONLY="${P%%\?*}"
r() { printf '%s\n%s' "$2" "$1"; exit 0; }
case "$M $PATHONLY" in
  "GET /api/v1/version")   r 200 '{"version":"11.0.16+gitea-1.22.0"}' ;;
  "GET /api/v1/user")      case "$AUTH" in *faketoken*) r 200 '{"login":"polari-admin"}' ;; *) r 401 '{"message":"token is required"}' ;; esac ;;
esac
case "$AUTH" in *faketoken*) ;; *) r 401 '{"message":"token is required"}' ;; esac
case "$M $PATHONLY" in
  "GET /api/v1/orgs/"*"/repos")
                           o="${PATHONLY#/api/v1/orgs/}"; o="${o%/repos}"
                           case "$P" in *page=1) ;; *) r 200 '[]' ;; esac
                           items=''
                           if [ -f "$S/repos" ]; then
                               while IFS= read -r fr; do
                                   case "$fr" in
                                     "$o/"*) if grep -qxF "$fr" "$S/nonmirror" 2>/dev/null
                                             then items="${items}{\"full_name\":\"$fr\",\"mirror\":false},"
                                             else items="${items}{\"full_name\":\"$fr\",\"mirror\":true},"; fi ;;
                                   esac
                               done < "$S/repos"
                           fi
                           r 200 "[${items%,}]" ;;
  "GET /api/v1/orgs/"*)    grep -qx "${PATHONLY#/api/v1/orgs/}" "$S/orgs" 2>/dev/null && r 200 '{}' || r 404 '{}' ;;
  "POST /api/v1/orgs")     o="$(printf '%s' "$D" | python3 -c 'import json,sys;print(json.load(sys.stdin)["username"])')"; echo "$o" >> "$S/orgs"; r 201 '{}' ;;
  "POST /api/v1/repos/migrate")
                           printf '%s\n' "$D" >> "$S/migrate.log"
                           printf '%s' "$D" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["repo_owner"]+"/"+d["repo_name"])' >> "$S/repos"
                           r 201 '{"mirror":true,"empty":false}' ;;
  "POST /api/v1/repos/"*"/mirror-sync")
                           r 200 '{}' ;;
  "DELETE /api/v1/repos/"*)
                           orp="${PATHONLY#/api/v1/repos/}"
                           if grep -qxF "$orp" "$S/repos" 2>/dev/null; then
                               grep -vxF "$orp" "$S/repos" > "$S/repos.tmp" 2>/dev/null || true
                               mv "$S/repos.tmp" "$S/repos"
                               echo "$orp" >> "$S/repo_dropped"
                               r 204 ''
                           else
                               r 404 '{}'
                           fi ;;
  "GET /api/v1/repos/"*)   orp="${PATHONLY#/api/v1/repos/}"
                           if grep -qxF "$orp" "$S/nonmirror" 2>/dev/null; then r 200 '{"mirror":false,"empty":false}'
                           elif grep -qxF "$orp" "$S/repos" 2>/dev/null; then r 200 '{"mirror":true,"empty":false}'
                           else r 404 '{}'
                           fi ;;
  "GET /api/v1/packages/"*/files)
                           rest="${PATHONLY#/api/v1/packages/*/debian/}"; n="${rest%%/*}"; v="${rest#*/}"; v="${v%/files}"
                           r 200 "[{\"name\":\"${n}_${v}_amd64.deb\"}]" ;;
  "GET /api/v1/packages/"*)
                           case "$P" in *page=1*|*limit=1) r 200 "$(cat "${FAKE_PKGS:-/dev/null}" 2>/dev/null || echo '[]')" ;; *) r 200 '[]' ;; esac ;;
  "DELETE /api/packages/"*|"DELETE /api/v1/packages/"*)
                           echo "$PATHONLY" >> "$S/deleted"; r 204 '' ;;
esac
r 404 '{"message":"not in the fake"}'
SH
chmod +x "$T/bin/docker" "$T/bin/curl"
export PATH="$T/bin:$PATH"
run() { bash "$P/scripts/$1.sh" "${@:2}" 2>&1; }

# ---------------------------------------------------------------- render
out="$(run render)"
has "render reports secrets generated" "secrets generated" "$out"
INI="$G/app.ini"
eq  "app.ini rendered" yes "$([ -s "$INI" ] && echo yes || echo no)"
# shellcheck disable=SC1091
source "$P/scripts/_lib.sh"
eq "[service] DISABLE_REGISTRATION = true"   true    "$(ini_get service DISABLE_REGISTRATION "$INI")"
eq "[service] REQUIRE_SIGNIN_VIEW = false"   false   "$(ini_get service REQUIRE_SIGNIN_VIEW "$INI")"
eq "[packages] ENABLED = true"               true    "$(ini_get packages ENABLED "$INI")"
eq "[indexer] REPO_INDEXER_ENABLED = false"  false   "$(ini_get indexer REPO_INDEXER_ENABLED "$INI")"
eq "[database] DB_TYPE = sqlite3"            sqlite3 "$(ini_get database DB_TYPE "$INI")"
eq "[server] LFS_START_SERVER = false"       false   "$(ini_get server LFS_START_SERVER "$INI")"
eq "[mirror] DEFAULT_INTERVAL = 168h (weekly — his ruling)" 168h "$(ini_get mirror DEFAULT_INTERVAL "$INI")"
eq "[security] INSTALL_LOCK = true"          true    "$(ini_get security INSTALL_LOCK "$INI")"
eq "[other] SHOW_FOOTER_VERSION = false"     false   "$(ini_get other SHOW_FOOTER_VERSION "$INI")"
eq "[cron.update_checker] ENABLED = false"   false   "$(ini_get cron.update_checker ENABLED "$INI")"
eq "[server] ROOT_URL filled"                "http://127.0.0.1:3300/" "$(ini_get server ROOT_URL "$INI")"
eq "[server] SSH_PORT = the loopback 2222"   2222    "$(ini_get server SSH_PORT "$INI")"
eq "no \${…} left in app.ini"                ""      "$(grep -v '^[[:space:]]*;' "$INI" | grep '\${' || true)"
sk="$(sed -n 's/^SECRET_KEY=//p' "$G/forge.env")"
eq "SECRET_KEY is 64 hex chars"              64      "${#sk}"
eq "[security] SECRET_KEY = the generated one" "$sk" "$(ini_get security SECRET_KEY "$INI")"
v="$(ini_get security INTERNAL_TOKEN "$INI")"; eq "[security] INTERNAL_TOKEN filled (64 hex)" 64 "${#v}"
for k in oauth2:JWT_SECRET server:LFS_JWT_SECRET; do
    v="$(ini_get "${k%%:*}" "${k#*:}" "$INI")"
    eq "[${k%%:*}] ${k#*:} = 43-char base64url (Forgejo rewrites any other shape)" yes \
       "$(printf '%s' "$v" | grep -qE '^[A-Za-z0-9_-]{43}$' && echo yes || echo no)"
done
# an older render's hex JWT secret is repaired, the other secrets kept
sed -i 's/^JWT_SECRET=.*/JWT_SECRET=deadbeef/' "$G/forge.env"
out="$(run render)"; has "render repairs a wrong-shaped JWT_SECRET" "JWT_SECRET regenerated" "$out"
eq "…keeping SECRET_KEY" "$sk" "$(sed -n 's/^SECRET_KEY=//p' "$G/forge.env")"
eq "…forge.env still mode 600" 600 "$(stat -c %a "$G/forge.env")"
eq "forge.env mode 600"      600 "$(stat -c %a "$G/forge.env")"
eq "app.ini mode 600"        600 "$(stat -c %a "$INI")"
eq "container.env mode 600"  600 "$(stat -c %a "$G/container.env")"
has "container.env carries USER_UID" "USER_UID=" "$(cat "$G/container.env")"
hasnt "container.env carries no secret" "SECRET_KEY" "$(cat "$G/container.env")"
hasnt "render never prints a secret" "$sk" "$out"
run render >/dev/null
eq "a second render keeps the secrets" "$sk" "$(sed -n 's/^SECRET_KEY=//p' "$G/forge.env")"
# an unfilled placeholder is a refusal
cp "$P/config/app.ini.template" "$T/tmpl.bak"
printf '[x]\nY = ${NOT_A_KNOB}\n' >> "$P/config/app.ini.template"
out="$(run render || true)"; has "render refuses an unfilled placeholder" "unfilled placeholders" "$out"
cp "$T/tmpl.bak" "$P/config/app.ini.template"; run render >/dev/null

# ---------------------------------------------------------------- up
out="$(run up)"
has "up waits for the API and names the version" "Forgejo 11.0.16" "$out"
has "up creates the admin on first run" "admin user polari-admin created" "$out"
for k in SECRET_KEY INTERNAL_TOKEN JWT_SECRET LFS_JWT_SECRET ADMIN_PASSWORD; do
    v="$(sed -n "s/^$k=//p" "$G/forge.env")"
    hasnt "up never echoes $k" "$v" "$out"
    hasnt "the docker client never sees $k in argv" "$v" "$(cat "$S/docker.log")"
done
eq "token file written"  faketoken0123456789abcdef "$(cat "$G/token")"
eq "token file mode 600" 600 "$(stat -c %a "$G/token")"
hasnt "up never echoes the token" "faketoken" "$out"
has "app.ini seeded into the volume at gitea/conf/app.ini" "gitea/conf/app.ini" "$(cat "$S/cp.list")"
uid="$(sed -n 's/^USER_UID=//p' "$G/container.env")"
has "the seeded app.ini is owned by USER_UID, mode 600" "-rw------- $uid/" "$(grep 'app.ini' "$S/cp.list")"
has "up uses the project's compose file + project name" "compose -f $P/compose/forge.yml --project-name polari-forge up" "$(cat "$S/docker.log")"
out="$(run up)"
has "a second up finds the admin" "admin user polari-admin present" "$out"
has "a second up keeps a working token" "admin token valid, kept" "$out"
eq "the admin was created once" 1 "$(grep -c 'admin user create' "$S/docker.log")"
has "an up on a running forge with a changed app.ini restarts it" "restart forge" "$(cat "$S/docker.log")"
: > "$S/docker.log"
out="$(FAKE_SHA="$(sha256sum "$INI" | cut -d' ' -f1)" run up)"
has "an up with app.ini unchanged does not restart" "no restart" "$out"
hasnt "…no restart, no re-seed" "restart" "$(grep -v 'admin user' "$S/docker.log")"

# ---------------------------------------------------------------- status
out="$(run status)"
has "status: running + health" "running (healthy)" "$out"
has "status: the volume" "polari-forge_forge-data" "$out"

# ---------------------------------------------------------------- mirror
out="$(run mirror dausume/polari-cli)"
has "mirror a new repo" "mirror dausume/polari-cli" "$out"
body="$(tail -n1 "$S/migrate.log")"
has "migrate body: the GitHub clone address" '"clone_addr":"https://github.com/dausume/polari-cli.git"' "$body"
has "migrate body: mirror true"              '"mirror":true' "$body"
has "migrate body: owner"                    '"repo_owner":"dausume"' "$body"
has "migrate body: name"                     '"repo_name":"polari-cli"' "$body"
has "migrate body: 168h interval (weekly)"   '"mirror_interval":"168h"' "$body"
has "migrate body: public"                   '"private":false' "$body"
has "the forge-side org was made" "dausume" "$(cat "$S/orgs")"
out="$(run mirror dausume/polari-cli)"
has "an existing repo is skipped" "skip   dausume/polari-cli" "$out"
eq "…and not migrated twice" 1 "$(wc -l < "$S/migrate.log")"
out="$(run mirror nonsense || true)"; has "mirror refuses a spec without owner/" "expected owner/repo" "$out"
printf '# a comment\ndausume/polari-cli\n\ndausume/Isle-Mesh  # trailing comment\ndausume/polari-node\n' > "$T/forest.txt"
out="$(FORGE_FOREST="$T/forest.txt" run mirror --forest)"
has "--forest reads the list" "forest: 3 repos considered" "$out"
eq "--forest migrated only the two new ones" 3 "$(wc -l < "$S/migrate.log")"
has "--forest: Isle-Mesh mirrored" '"repo_name":"Isle-Mesh"' "$(cat "$S/migrate.log")"
eq "forest.txt names the 13 public repos" 13 "$(grep -cv '^[[:space:]]*\(#\|$\)' "$P/forest.txt")"
out="$(run mirror --forest)"
eq "--forest on the shipped list: 13 considered" "13" "$(printf '%s' "$out" | sed -n 's/.*forest: \([0-9]*\) repos.*/\1/p')"
hasnt "the token never rides curl's argv" "faketoken" "$(cat "$S/curl.log")"

# ---------------------------------------------------------------- links: none yet
out="$(run links)"
has "links (none yet)" "no links" "$out"

# ---------------------------------------------------------------- hold levels: mirror (bare + hold=mirror), primary, link
printf 'dausume/polari-cli\ndausume/hold-primary-1 hold=primary\ndausume/hold-link-1 hold=link\ndausume/polari-cli hold=link\n' > "$T/forest-hold.txt"
out="$(FORGE_FOREST="$T/forest-hold.txt" run mirror --forest)"
has "hold=: a bare line (no hold=) defaults to mirror, already there → skip" "skip   dausume/polari-cli" "$out"
has "hold=primary: recognised, not yet implemented" "hold=primary" "$out"
has "hold=primary: the note says treated as mirror" "treated as mirror" "$out"
has "hold=primary: still migrated (treated as mirror)" '"repo_name":"hold-primary-1"' "$(cat "$S/migrate.log")"
has "hold=link: not migrated, printed as not held" "link   dausume/hold-link-1 → https://github.com/dausume/hold-link-1 (not held)" "$out"
hasnt "hold=link: never migrated" '"repo_name":"hold-link-1"' "$(cat "$S/migrate.log")"
has "hold=link on an ALREADY-held repo warns" "link   dausume/polari-cli is already held on the forge" "$out"
has "…and names the drop command" "pol forge mirror --drop dausume/polari-cli" "$out"
has "--forest: 4 repos considered" "forest: 4 repos considered" "$out"
eq "links.txt holds the two hold=link lines" 2 "$(grep -c . "$G/links.txt")"
has "links.txt: hold-link-1" "dausume/hold-link-1 https://github.com/dausume/hold-link-1" "$(cat "$G/links.txt")"
has "links.txt: polari-cli (recorded, with the warn, since its line said link)" "dausume/polari-cli https://github.com/dausume/polari-cli" "$(cat "$G/links.txt")"

out="$(run links)"
has "links: prints hold-link-1" "link   dausume/hold-link-1 → https://github.com/dausume/hold-link-1 (not held)" "$out"
has "links: prints polari-cli" "link   dausume/polari-cli → https://github.com/dausume/polari-cli (not held)" "$out"
has "links: a count line" "2 linked (not held)" "$out"
printf 'dausume/bogus hold=bogus\n' > "$T/forest-bad.txt"
out="$(FORGE_FOREST="$T/forest-bad.txt" run mirror --forest || true)"
has "forest.txt: an unknown hold= value is refused" "unknown hold=bogus" "$out"

# ---------------------------------------------------------------- --sync --forest skips hold=link lines
: > "$S/curl.log"
out="$(FORGE_FOREST="$T/forest-hold.txt" run mirror --sync --forest)"
has "--sync --forest: synced vs skipped" "forest: sync asked for 2 repos (2 link entries skipped)" "$out"
eq "--sync --forest: exactly 2 mirror-sync calls (link lines never fetched)" 2 "$(grep -c mirror-sync "$S/curl.log")"

# ---------------------------------------------------------------- --drop (refuses a non-mirror, deletes a mirror)
printf 'dausume/legacy-primary\n' >> "$S/repos"
printf 'dausume/legacy-primary\n' >> "$S/nonmirror"
out="$(run mirror --drop dausume/legacy-primary || true)"
has "--drop refuses a non-mirror" "refusing to drop dausume/legacy-primary — it is not a mirror" "$out"
hasnt "--drop: nothing was deleted" "dausume/legacy-primary" "$(cat "$S/repo_dropped" 2>/dev/null || true)"
has "--drop: a refused repo stays on the forge" "dausume/legacy-primary" "$(cat "$S/repos")"
out="$(run mirror --drop dausume/hold-primary-1)"
has "--drop deletes a mirror" "dropped dausume/hold-primary-1" "$out"
has "--drop: DELETE was sent" "dausume/hold-primary-1" "$(cat "$S/repo_dropped")"
hasnt "--drop: removed from the forge" "dausume/hold-primary-1" "$(cat "$S/repos")"
out="$(run mirror --drop dausume/not-on-the-forge || true)"
has "--drop refuses a repo that is not on the forge" "is not on the forge" "$out"

# ---------------------------------------------------------------- meter
out="$(run meter)"
line="$(printf '%s\n' "$out" | head -n1)"
jv() { printf '%s' "$line" | python3 -c 'import json,sys; d=json.load(sys.stdin)
v=d
for k in sys.argv[1].split("."): v=v[k]
print(v)' "$1"; }
eq "meter: rss_mib from docker stats" 94.2  "$(jv rss_mib)"
eq "meter: peak_mib from memory.peak" 458.0 "$(jv peak_mib)"
eq "meter: cpu_pct"                   0.5   "$(jv cpu_pct)"
eq "meter: data_mib total"            51    "$(jv data_mib)"
eq "meter: areas.git"                 40    "$(jv areas.git)"
eq "meter: areas.packages"            2     "$(jv areas.packages)"
eq "meter: areas.db"                  3     "$(jv areas.db)"
eq "meter: repos"                     13    "$(jv repos)"
eq "meter: held (mirrors on the forge, via the org's repo listing)" 13 "$(jv held)"
eq "meter: linked (hold=link lines in links.txt)" 2 "$(jv linked)"
eq "meter: primary (not implemented this slice)" 0 "$(jv primary)"
exp="$(printf '  %-14s %s' held 13)";   has "meter: table shows held"    "$exp" "$out"
exp="$(printf '  %-14s %s' linked 2)";  has "meter: table shows linked"  "$exp" "$out"
exp="$(printf '  %-14s %s' primary 0)"; has "meter: table shows primary" "$exp" "$out"
has "meter: a table" "data (total)   51 MiB" "$out"
eq "meter: one line appended to meter.jsonl" 1 "$(wc -l < "$G/meter.jsonl")"
out="$(FAKE_PEAK=max run meter --json)"
eq "meter: peak null when memory.peak is unreadable" None "$(line="$out"; jv peak_mib)"

# ---------------------------------------------------------------- retention
python3 - "$T/pkgs.json" <<'PY'
import json, sys
rows = [{"id": i, "name": "polari-core", "version": "1.%d" % i, "created_at": "2026-09-%02dT00:00:00Z" % (10 + i)} for i in range(1, 6)]
rows += [{"id": 10 + i, "name": "polari-isle", "version": "0.%d" % i, "created_at": "2026-09-%02dT00:00:00Z" % (10 + i)} for i in range(1, 5)]
rows += [{"id": 20, "name": "polari-old", "version": "9.0", "created_at": "2026-08-01T00:00:00Z"}]
json.dump(rows, open(sys.argv[1], "w"))
PY
printf 'polari-core@1.1   # pinned\npolari-isle\n' > "$T/keep.txt"
export FAKE_PKGS="$T/pkgs.json"
out="$(FORGE_KEEP="$T/keep.txt" run retention 3 --dry-run)"
has "retention dry-run: counts" "9 kept, 1 would be deleted" "$out"
eq  "retention dry-run deletes nothing" no "$([ -s "$S/deleted" ] && echo yes || echo no)"
has "keeps the newest 3 (1.5)" "KEEP   polari-core                              1.5" "$out"
has "keeps a keep.txt pin (1.1)" "keep.txt@" "$out"
has "a keep.txt name keeps every version of it" "KEEP   polari-isle                              0.1                      keep.txt" "$out"
has "deletes 1.2" "DELETE polari-core                              1.2" "$out"
out="$(FORGE_KEEP="$T/keep.txt" run retention 3)"
has "retention: real run" "9 kept, 1 deleted" "$out"
dl="$(cat "$S/deleted")"
has "deletes through the Debian door (index rebuilt)" "/api/packages/dausume/debian/pool/stable/main/polari-core/1.2/amd64" "$dl"
hasnt "keeps the third-newest (1.3)" "polari-core/1.3/" "$dl"
hasnt "a one-version package is its own newest" "polari-old" "$dl"
eq "exactly one delete" 1 "$(wc -l < "$S/deleted")"
hasnt "never deletes the pinned 1.1" "polari-core/1.1/" "$dl"
hasnt "never deletes a keep.txt package" "polari-isle" "$dl"
has "retention reports packages MiB before/after" "packages 2 MiB → 2 MiB" "$out"
out="$(run retention 0 || true)"; has "retention refuses K=0" "at least 1" "$out"
out="$(run retention abc || true)"; has "retention refuses a non-number" "usage: retention" "$out"

# ---------------------------------------------------------------- posture
out="$(run posture)"; rc=0; run posture >/dev/null || rc=$?
has "posture: all OK" "posture: OK 7/7" "$out"
eq  "posture exits 0 when all OK" 0 "$rc"
for r in registration anon-read indexer mem-limit ports secrets admin-token; do has "posture row: $r" "$r" "$out"; done
out="$(FAKE_BINDS='0.0.0.0:3300->3000/tcp 127.0.0.1:2222->22/tcp ' run posture || true)"
has "posture flags a 0.0.0.0 port" "not loopback: 0.0.0.0:3300->3000/tcp" "$out"
has "posture: WARN line" "posture: WARN" "$out"
cp "$P/compose/forge.yml" "$T/forge.yml.bak"
sed -i '/memory: 512M/d' "$P/compose/forge.yml"
out="$(FAKE_MEM=0 run posture || true)"
has "posture flags a missing mem limit" "compose declares no memory limit" "$out"
cp "$T/forge.yml.bak" "$P/compose/forge.yml"
out="$(FAKE_MEM=0 run posture || true)"
has "posture flags a live container without the limit" "the running container has 0 limit" "$out"
rm -f "$S/running"
sed -i 's/"127.0.0.1:${FORGE_HTTP_PORT:-3300}:3000"/"0.0.0.0:3300:3000"/' "$P/compose/forge.yml"
out="$(run posture || true)"
has "posture (not running) reads the compose ports" "not loopback: 0.0.0.0:3300:3000" "$out"
cp "$T/forge.yml.bak" "$P/compose/forge.yml"
chmod 644 "$G/token"; out="$(run posture || true)"; has "posture flags a loose token mode" "token mode 644" "$out"; chmod 600 "$G/token"
touch "$S/running"

# ---------------------------------------------------------------- frg-2: the swarm home (a pol prod stack service)
eq "the ONE pin: _lib.sh's IMAGE is read from compose/forge.yml" \
   "$(awk '/^[[:space:]]*image:/{print $2; exit}' "$P/compose/forge.yml")" "$(bash -c "source '$P/scripts/_lib.sh'; echo \"\$IMAGE\"")"
out="$(FAKE_SWARM=1 bash -c "source '$P/scripts/_lib.sh'; echo \"ctr=\$(forge_ctr) mode=\$(forge_mode) compose=\$(compose_ctr)\"")"
eq "swarm: forge_ctr resolves the TASK by com.docker.swarm.service.name=<stack>_forge" "ctr=fakecid0123456789 mode=swarm compose=" "$out"
out="$(FAKE_SWARM=1 FORGE_STACK=polari-prod bash -c "source '$P/scripts/_lib.sh'; echo \"ctr=\$(forge_ctr)\"")"
eq "swarm: FORGE_STACK narrows the stacks searched" "ctr=" "$out"
out="$(bash -c "source '$P/scripts/_lib.sh'; echo \"mode=\$(forge_mode)\"")"
eq "compose: the home forge's container wins (mode compose)" "mode=compose" "$out"
: > "$S/curl.log"; rm -f "$S/exec-curl.log"
out="$(FAKE_SWARM=1 run status)"
has "swarm status: running, mode swarm" "— swarm — container fakecid0123" "$out"
has "swarm status: the API through docker exec (no published port)" "docker exec fakecid01234 → http://localhost:3000 (no published port)" "$out"
has "swarm status: ssh not exposed" "ssh not exposed — https only" "$out"
has "swarm status: the version came back through the exec route" "Forgejo 11.0.16" "$out"
eq "swarm: the API went through docker exec … curl (not the host's curl to a port)" yes "$([ -s "$S/exec-curl.log" ] && echo yes || echo no)"
has "swarm: …to localhost:3000 inside the task" "http://localhost:3000/api/v1/version" "$(cat "$S/curl.log")"
hasnt "swarm: …never the host port 3300" "127.0.0.1:3300" "$(cat "$S/curl.log")"
# the token from the vault (FORGE_TOKEN, no file) — through stdin, never argv
mv "$G/token" "$T/token.bak"
: > "$S/docker.log"; : > "$S/curl.log"
out="$(FAKE_SWARM=1 FORGE_TOKEN=faketoken0123456789abcdef run meter --json)"
eq "swarm meter: held counted with the vault's token (FORGE_TOKEN)" 13 "$(line="$out"; jv held)"
hasnt "swarm: the token never rides docker's argv" "faketoken" "$(cat "$S/docker.log")"
hasnt "swarm: …nor curl's" "faketoken" "$(cat "$S/curl.log")"
out="$(FAKE_SWARM=1 FORGE_TOKEN=faketoken0123456789abcdef run token)"
has "swarm token: the vault's token is valid → kept, named as the vault" "kept: the vault (forge ADMIN_TOKEN)" "$out"
out="$(FAKE_SWARM=1 FORGE_TOKEN=faketoken0123456789abcdef run status)"
has "swarm status: token in the vault" "token:   the vault (forge ADMIN_TOKEN)" "$out"
out="$(FAKE_SWARM=1 FORGE_TOKEN=faketoken0123456789abcdef run posture || true)"
has "swarm posture: ports — none published (behind pol-proxy)" "none published (behind pol-proxy)" "$out"
has "swarm posture: the service named" "service polari-lean_forge" "$out"
has "swarm posture: admin token in the vault" "in the vault (forge ADMIN_TOKEN)" "$out"
has "swarm posture: OK 7/7, no published port" "posture: OK 7/7" "$out"
hasnt "swarm posture: no loopback row (that is the compose home's)" "loopback only" "$out"
out="$(FAKE_SWARM=1 FAKE_SVC_PORTS='3000->3000 ' FORGE_TOKEN=faketoken0123456789abcdef run posture || true)"
has "swarm posture: a published port is a WARN (ingress = every interface)" "published on every interface (swarm ingress): 3000->3000" "$out"
mv "$T/token.bak" "$G/token"
# not running, answered on: the rendered stack file is read
rm -f "$S/running"
printf 'services:\n  forge:\n    image: x\n' > "$T/stack-ok.yml"
printf 'services:\n  forge:\n    image: x\n    ports:\n      - published: 3300\n        target: 3000\n' > "$T/stack-bad.yml"
out="$(FORGE_PROD=on FORGE_STACK_FILES="$T/stack-ok.yml" run posture || true)"
has "prod posture (no task): the rendered stack publishes nothing → OK" "none published (behind pol-proxy)" "$out"
out="$(FORGE_PROD=on FORGE_STACK_FILES="$T/stack-bad.yml" run posture || true)"
has "prod posture (no task): a ports: in the rendered stack → WARN" "published on every interface (swarm ingress): 3300" "$out"
out="$(FORGE_PROD=on run status || true)"
has "prod status (no task): points at pol prod" "the pol prod service has no running task here" "$out"
touch "$S/running"
# up/down refuse on a swarm; ready.sh (pol prod apply's admin step) works through the task
out="$(FAKE_SWARM=1 run up || true)"
has "swarm: pol forge up refuses" "this forge is a pol prod service — pol prod apply / pol prod down" "$out"
out="$(FAKE_SWARM=1 run down || true)"
has "swarm: pol forge down refuses" "this forge is a pol prod service — pol prod apply / pol prod down" "$out"
out="$(FORGE_PROD=on run up 2>&1 || true)"
hasnt "answered on but the home compose container runs → the compose home wins (up allowed)" "pol prod service" "$out"
rm -f "$S/admin"; : > "$S/docker.log"
out="$(FAKE_SWARM=1 FORGE_PASSWORD_WHERE='the vault (forge ADMIN_PASSWORD)' run ready)"
has "swarm ready: waits for the API through the task" "answering on docker exec" "$out"
has "swarm ready: creates the admin in the task" "admin user polari-admin created (password: ADMIN_PASSWORD in the vault (forge ADMIN_PASSWORD))" "$out"
ap="$(sed -n 's/^ADMIN_PASSWORD=//p' "$G/forge.env")"
hasnt "swarm ready: the admin password never in docker's argv" "$ap" "$(cat "$S/docker.log")"
# render knobs for the production home
FORGE_DISABLE_SSH=true FORGE_TRUSTED_PROXIES=10.0.0.0/8 FORGE_ROOT_URL=https://forge.example.invalid/ FORGE_DOMAIN=forge.example.invalid run render >/dev/null
eq "render: FORGE_DISABLE_SSH=true → [server] DISABLE_SSH = true (no ssh clone URL advertised)" true "$(ini_get server DISABLE_SSH "$INI")"
eq "render: FORGE_TRUSTED_PROXIES → the overlay range" 10.0.0.0/8 "$(ini_get security REVERSE_PROXY_TRUSTED_PROXIES "$INI")"
eq "render: ROOT_URL https://forge.<D>/" https://forge.example.invalid/ "$(ini_get server ROOT_URL "$INI")"
run render >/dev/null
eq "render: the defaults keep the home forge's app.ini (DISABLE_SSH false)" false "$(ini_get server DISABLE_SSH "$INI")"
eq "render: …and loopback-only proxy trust" "127.0.0.0/8,::1/128" "$(ini_get security REVERSE_PROXY_TRUSTED_PROXIES "$INI")"
out="$(FORGE_APT_URL=https://apt.example.invalid run apt-source)"
has "apt-source: production's apt.<D> line (FORGE_APT_URL)" 'deb [signed-by=/etc/apt/keyrings/polari-forge.asc] https://apt.example.invalid stable main' "$out"
has "apt-source: the key at apt.<D>/repository.key" 'https://apt.example.invalid/repository.key' "$out"

# ---------------------------------------------------------------- apt-source
out="$(run apt-source dausume)"
has "apt-source: the deb line" 'deb [signed-by=/etc/apt/keyrings/polari-forge.asc] http://127.0.0.1:3300/api/packages/dausume/debian stable main' "$out"
has "apt-source: the key URL" 'http://127.0.0.1:3300/api/packages/dausume/debian/repository.key' "$out"
out="$(FORGE_ROOT_URL=https://forge.example.org run apt-source)"
has "apt-source: the public ROOT_URL + default owner" 'https://forge.example.org/api/packages/dausume/debian stable main' "$out"

# ---------------------------------------------------------------- down
out="$(run down)"; has "down keeps the volume" "volume polari-forge_forge-data kept" "$out"
hasnt "down never removes volumes" "down -v" "$(cat "$S/docker.log")"

# ---------------------------------------------------------------- the compose file
cf="$(grep -v '^[[:space:]]*#' "$P/compose/forge.yml")"   # the YAML, not the comments
has   "compose: the pinned digest" "forgejo:11@sha256:946243edbab116d5bb78b73ea68af6f3d69229ba1b1ed958dd82c3481167f3e0" "$cf"
has   "compose: a NAMED volume" "forge-data:/data" "$cf"
has   "compose: 512M limit" "memory: 512M" "$cf"
has   "compose: http on loopback" '127.0.0.1:${FORGE_HTTP_PORT:-3300}:3000' "$cf"
has   "compose: ssh on loopback" '127.0.0.1:${FORGE_SSH_PORT:-2222}:22' "$cf"
hasnt "compose: no user: override (rootful image)" $'\n    user:' "$cf"
hasnt "compose: no container_name (swarm-clean)" "container_name" "$cf"
hasnt "compose: no bind mount into the project" "- ./" "$cf"
hasnt "compose: no 0.0.0.0" "0.0.0.0" "$cf"

# ---------------------------------------------------------------- the CLI front door
CLI="$HERE/../polari-cli/scripts/forge.sh"
if [ -f "$CLI" ]; then
    mkdir -p "$T/nosuite"; touch "$T/nosuite/setup-polari-security.sh"   # a suite WITHOUT the submodule
    out="$(POL_SUITE_ROOT="$T/nosuite" bash "$CLI" status 2>&1 || true)"
    has "pol forge refuses when the submodule is not checked out" "polari-forge is not checked out" "$out"
    out="$(POL_SUITE_ROOT="$T/nosuite" bash "$CLI" help 2>&1)"
    for v in up down status render token mirror meter retention posture apt-source links selftest; do has "pol forge help lists $v" "$v" "$out"; done
    has "pol forge help: mirror --drop" "mirror --drop" "$out"
fi

# ---------------------------------------------------------------- THE CLEAN-TREE RULE
# what a run writes that we have not already written, plus what a careless bind
# mount of the volume into the project would leave behind
mkdir -p "$P/data/gitea/conf" "$P/data/git/repositories/dausume/polari-cli.git" "$P/secrets" "$P/gitea/log" "$P/git"
touch "$P/data/gitea/forgejo.db" "$P/data/gitea/conf/app.ini" "$P/forgejo.db" "$P/gitea.db-wal" "$P/x.sqlite" "$P/y.sqlite3-journal" \
      "$P/app.ini" "$P/server.pem" "$P/repository.key" "$P/secrets/token" "$P/gitea/log/forgejo.log" "$P/git/HEAD" "$P/meter.jsonl" "$P/forge.env"
eq "THE CLEAN-TREE RULE: git status --porcelain is empty after a run" "" "$(git -C "$P" status --porcelain)"
eq "…and the run really wrote under .generated/" yes "$([ -s "$G/meter.jsonl" ] && [ -s "$G/token" ] && echo yes || echo no)"
eq "…and the authored files are still tracked (none ignored by accident)" "" \
   "$(cd "$HERE" && for f in README.md COST.md LICENSE .gitignore compose/forge.yml config/app.ini.template forest.txt keep.txt polari-app.json selftest.sh scripts/*.sh; do [ -f "$f" ] && git check-ignore -q "$f" 2>/dev/null && echo "$f"; done)"

echo "polari-forge selftest: $PASS/$((PASS+FAIL))"
[ "$FAIL" = 0 ]
