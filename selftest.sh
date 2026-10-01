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
  ps)      [ -f "$S/running" ] && echo "$CID"; exit 0 ;;
  stats)   echo "${FAKE_STATS:-94.2MiB / 512MiB|0.50%}"; exit 0 ;;
  cp)      # docker cp -a - <cid>:/data/  — record the tar's listing, never its secrets
           tar -tvf - --numeric-owner > "$S/cp.list"; exit 0 ;;
  inspect) case "$*" in
             *HostConfig.Memory*)   echo "${FAKE_MEM-536870912}" ;;
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
             *"admin user list"*)          echo "ID   Username     Email"; [ -f "$S/admin" ] && echo "1    polari-admin x@forge.invalid" ;;
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
    -H) case "$2" in @*) f="${2#@}"; AUTH="$(cat "$f" 2>/dev/null)" ;; esac; shift ;;
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
  "GET /api/v1/orgs/"*)    grep -qx "${PATHONLY#/api/v1/orgs/}" "$S/orgs" 2>/dev/null && r 200 '{}' || r 404 '{}' ;;
  "POST /api/v1/orgs")     o="$(printf '%s' "$D" | python3 -c 'import json,sys;print(json.load(sys.stdin)["username"])')"; echo "$o" >> "$S/orgs"; r 201 '{}' ;;
  "POST /api/v1/repos/migrate")
                           printf '%s\n' "$D" >> "$S/migrate.log"
                           printf '%s' "$D" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["repo_owner"]+"/"+d["repo_name"])' >> "$S/repos"
                           r 201 '{"mirror":true,"empty":false}' ;;
  "GET /api/v1/repos/"*)   grep -qx "${PATHONLY#/api/v1/repos/}" "$S/repos" 2>/dev/null && r 200 '{"mirror":true,"empty":false}' || r 404 '{}' ;;
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
    for v in up down status render token mirror meter retention posture apt-source selftest; do has "pol forge help lists $v" "$v" "$out"; done
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
