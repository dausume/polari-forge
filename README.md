# polari-forge — the self-hosted forge

Polari's own forge: git hosting for the forest and the Debian package registry people install Polari from. It runs
[Forgejo](https://forgejo.org) (GPL-3.0-or-later), pinned by digest, and is driven only through `pol forge …`.
CICD_PIPELINE_PLAN §12 (frg-0..4) is the plan this sub-project builds.

## The three rules (his rulings, 2026-09-27/30)

1. **DUAL ROUTE, ALWAYS.** GitHub is the *online-availability* route; this forge is the *self-sustaining* route and,
   on production, **the default for people** — "the average person should go through us". Neither replaces the
   other. Everything the forge does is designed to be exercised against both: a repo is on GitHub *and* on the forge,
   a release is published to both, an update can be taken from either (`pol prod update --source github|forge`).

2. **THE PROJECT IS THE CAPABILITY, NEVER THE CONTENT.** This repository holds setup and mechanisms only. The
   repositories the forge hosts, their git history, its packages, its database, sessions, keys, and the rendered
   config with its secrets all live in the forge's **volume** (or under `.generated/`) and are gitignored. A forge
   whose repo contained the repos it hosts would be recursive. `selftest.sh` proves it: after a simulated run that
   writes everything a run writes, `git status --porcelain` here is empty — and frg-0's live proof checked the same
   on a real forge.

3. **FORGEJO, PINNED, REPLACING REPREPRO.** `codeberg.org/forgejo/forgejo:11@sha256:946243ed…3f0`, measured on the
   home dev box before anything was built on it (`COST.md`: idle 94 MiB, peak 455 MiB while signing packages, 51 MB of
   git for the whole forest). Its Debian package registry **replaces the reprepro apt route**: it serves the same debs
   from the same release pool, signed with the forge's own key.

And two that follow:

- **Full git history is kept** (the whole forest packs to ~50 MB). **Retention applies to packages/releases only**:
  the newest K=3 versions per package, plus anything `keep.txt` names.
- **Public posture by default**: registration OFF, anonymous READ only, no open sign-up (no OpenID sign-up, no
  external-only door), repo indexer OFF, memory limit 512 MiB, cron trimmed, Actions off, no phone-home.
  `pol forge posture` prints it as OK/WARN rows and one line.

## What is here, and what is in the volume

| here (tracked) | in the volume `polari-forge_forge-data` or `.generated/forge/` (never tracked) |
|---|---|
| `compose/forge.yml` — one swarm-clean service, named volume, loopback ports, 512M | `/data/git/repositories` — the hosted repos and their history |
| `config/app.ini.template` — the posture, with `${VAR}` placeholders | `/data/gitea/packages` — the registry's blobs |
| `scripts/*.sh` — the implementation `pol forge` calls | `/data/gitea/forgejo.db` — sqlite: users, orgs, tokens, package index |
| `forest.txt` — the 13 public repos `mirror --forest` mirrors | `/data/ssh`, the registry's signing key, sessions, queues, logs |
| `keep.txt` — packages retention never deletes | `/data/gitea/conf/app.ini` — the rendered config, copied in by `up` |
| `selftest.sh` — fake docker + fake curl, incl. the clean-tree rule | `.generated/forge/forge.env` — the secrets (600) |
| `polari-app.json` — the service manifest (security stanza, cost) | `.generated/forge/app.ini`, `container.env`, `token` (600), `meter.jsonl` |
| `COST.md`, `README.md`, `LICENSE` (GPL-3.0) | |

**Why app.ini is copied in, not mounted.** The image's setup step rewrites `/data/gitea/conf/app.ini` in place
(`environment-to-ini`) and Forgejo writes to it, so a read-only mount fails; a bind mount would also break
swarm-cleanness. `up` renders it, then — between `docker compose up --no-start` and the start — streams it into the
volume as a tar owned by `USER_UID`, mode 600 (`docker cp -a`), on every `up`. A pre-supplied app.ini with
`INSTALL_LOCK = true` skips the web installer.

**Why there is no `user:` line.** The forgejo image is rootful: its entrypoint starts as root, renumbers its `git`
user to `USER_UID`/`USER_GID` and drops to it under s6. Ownership is set that way (`container.env`, written by
`render`: the host UID, or 1000 when the host user is root — Forgejo refuses to run as root). There is no writable
bind mount, so nothing root-owned can land on the host (CLAUDE.md's gotcha).

**Secrets stay out of the container's environment.** `forge.env` (generated once, mode 600, never printed:
`openssl rand -hex 32`, except the two JWT secrets, which must be 32 bytes base64url — Forgejo silently replaces any
other shape in app.ini at boot, found in frg-0's live run) feeds only the render and the admin creation; the container's `env_file` is `container.env`
(`USER_UID`/`USER_GID`), so `docker inspect` shows no secret. The admin password reaches `forgejo admin user create`
over stdin; the API token travels in a curl header read from a process substitution, never on argv.

## The verbs

    pol forge render                 secrets once + app.ini + container.env (.generated/forge/)
    pol forge up                     render if needed, start on 127.0.0.1:3300 (ssh 127.0.0.1:2222), wait for
                                     /api/v1/version, the admin user on first run, the admin token
    pol forge down                   stop; the volume is KEPT (docker volume rm polari-forge_forge-data discards it)
    pol forge status                 running/health, version, URL, volume, token
    pol forge token [--new]          check the admin token, mint one when missing/refused
    pol forge mirror <owner/repo>    pull-mirror one GitHub repo (POST /api/v1/repos/migrate, mirror, WEEKLY check — his ruling; a fetch moves only deltas);
                                     skips a repo already there; the forge-side owner is an org of the same name
    pol forge mirror --sync <owner/repo> | --sync --forest   ask for a fetch NOW (after a release) instead of the weekly check
    pol forge mirror --forest        every line of forest.txt
    pol forge meter [--json]         THE STORAGE METER (COST.md)
    pol forge retention <K> [--dry-run] [--owner <o>]
                                     Debian registry: keep the newest K per package + keep.txt, delete the rest
    pol forge posture                the public posture, OK/WARN rows + one line (exit 2 on a WARN)
    pol forge apt-source [<owner>]   the two lines a person needs (below)
    pol forge selftest [-v]          the unit checks; green before anything ships

Knobs (env): `FORGE_HTTP_PORT` (3300) · `FORGE_SSH_PORT` (2222) · `FORGE_ROOT_URL` (`http://127.0.0.1:3300/`; the
public address on production) · `FORGE_DOMAIN` (localhost) · `FORGE_OWNER` (dausume) · `FORGE_GITHUB`
(`https://github.com`) · `FORGE_ADMIN` (polari-admin) · `FORGE_APT_DIST`/`FORGE_APT_COMPONENT` (stable/main, the old
reprepro route's) · `FORGE_KEEP` · `FORGE_FOREST`. The production home (frg-2, set by `pol forge`/`pol prod`):
`FORGE_DISABLE_SSH` (false) · `FORGE_TRUSTED_PROXIES` (`127.0.0.0/8,::1/128`) · `FORGE_STACK` (`polari-lean
polari-prod`) · `FORGE_VOLUME` · `FORGE_TOKEN` · `FORGE_APT_URL` · `FORGE_PROD` · `FORGE_STACK_FILES`.

**Retention deletes through the Debian registry's own door** (`DELETE /api/packages/<owner>/debian/pool/<dist>/<comp>/<name>/<version>/<arch>`),
so the signed `Packages`/`Release` index is rebuilt. The generic `/api/v1/packages/…` DELETE removes the version but
leaves it **listed** in the apt index (found in frg-0's live run) — apt would then 404 on it; it is only the fallback,
with a warning. "Newest" means most recently uploaded.

## How a person adds the apt source

Two lines (`pol forge apt-source dausume` prints them with this forge's address):

    sudo curl -fsSL https://<forge>/api/packages/dausume/debian/repository.key -o /etc/apt/keyrings/polari-forge.asc
    echo "deb [signed-by=/etc/apt/keyrings/polari-forge.asc] https://<forge>/api/packages/dausume/debian stable main" | sudo tee /etc/apt/sources.list.d/polari-forge.list

then `sudo apt update && sudo apt install <package>`. The key is the forge's own — no GitHub signing key involved.

## The dual route, concretely

| | GitHub (online availability) | the forge (self-sustaining; the default on production) |
|---|---|---|
| code | `github.com/dausume/<repo>` | `<forge>/dausume/<repo>` — a pull mirror today (frg-1: mirror or primary, `push-all-dev.sh --remote both`) |
| debs | GitHub release assets | the Debian registry, `apt install` with the forge's key (frg-3) |
| updates | `pol prod update --source github` | `pol prod update --source forge` |

## On production (frg-2) — the forge as a `pol prod` service

His ruling: the forge lives ON PRODUCTION as the default distribution point ("the average person should go
through us"; GitHub is the secondary route) and replaces the reprepro apt route. One answer switches it on:
`POL_PROD_FORGE=on` (the guide asks it right after the logins step; the `distribution-server` and `public-server`
profiles answer `on`, `local-instance`/`demo-server` `off`; an answers file written before the answer existed
means `off`). `POL_PROD_FORGE_OWNER` (default `dausume` — the owner the pipeline's `forgejo-*` routes publish
under) is the owner whose Debian registry `apt.<domain>` serves.

What `pol prod apply` then does, in order:

1. **secrets → the vault, once.** The five secrets (`SECRET_KEY`, `INTERNAL_TOKEN`, `JWT_SECRET`, `LFS_JWT_SECRET`,
   `ADMIN_PASSWORD`) are generated by `scripts/render.sh` (one generator) on the first apply and written to the
   vault section `[forge]`; every later apply re-assembles `.generated/forge/forge.env` (600) FROM the vault (the
   vault wins over a drifted file) and writes nothing back unless a key is missing.
2. **app.ini** rendered for `https://forge.<domain>/` (`PROTOCOL http` on :3000 behind pol-proxy, `DISABLE_SSH =
   true`, the overlay `10.0.0.0/8` as the trusted proxy range) into the suite's `.generated/forge/app.ini` (600,
   gitignored by the suite's `.generated/` rule).
3. **names + proxy + certificate**: `forge.<domain>` (the UI, the API, git over https — 1 GiB bodies for a deb/image
   upload) and `apt.<domain>` (a read-only rewrite: `apt.<d>/<x>` → `forge:3000/api/packages/<owner>/debian/<x>`) —
   both join the names table, the nginx config and the Let's Encrypt SANs; with the forge on, the static `/srv/apt`
   block is gone.
4. **the stack service** `forge` (compose profile `forge` in the suite's `docker-compose.{lean,prod}.yml`): the image
   is THE pin read from `compose/forge.yml` at render time, the named volume `polari_forge_data` (a fixed name), NO
   published ports (pol-proxy reaches `forge:3000` over the overlay), 512M, healthcheck as here, restart on-failure,
   pinned to the manager.
5. **the volume seed**, before `docker stack deploy`: a one-shot container of the pinned image copies app.ini into
   `polari_forge_data` (owner USER_UID, 600) over stdin — skipped when the file there is already the rendered one.
6. after the deploy: `scripts/ready.sh` waits for the task and creates the admin user (password from the vault, over
   stdin); the admin token is minted once and kept in the vault (`forge ADMIN_TOKEN`), never in a file.
7. **the re-measure gate**: `pol forge meter`'s line (appended to `.generated/forge/meter.jsonl`) and one verdict
   against the VM's available memory (`free -m`): **WARN when less than 2 × the 512 MiB limit is available**. The
   ruling is to re-measure on the droplet BEFORE the forge faces the web — read this line on the first apply.

The line people add (`pol forge apt-source` prints it on production):

    sudo curl -fsSL https://apt.<domain>/repository.key -o /etc/apt/keyrings/polari-forge.asc
    echo "deb [signed-by=/etc/apt/keyrings/polari-forge.asc] https://apt.<domain> stable main" | sudo tee /etc/apt/sources.list.d/polari-forge.list

**ssh clone is NOT exposed in this slice — https only** (`git clone https://forge.<domain>/<owner>/<repo>.git`).

`pol forge` on a swarm: with `POL_PROD_FORGE=on` in the answers and no compose forge running here, `pol forge
status|posture|meter|mirror|retention|links|apt-source|token` act on the stack service — the container is the swarm
task (`com.docker.swarm.service.name=<stack>_forge`), the API is reached by **`docker exec <task> curl
http://localhost:3000`** (no published port, no DNS or certificate needed; the token goes over stdin), the token is
read from the vault. `pol forge up|down|render` refuse: "this forge is a pol prod service — pol prod apply / pol
prod down". `posture` shows `ports: none published (behind pol-proxy)` there instead of the loopback row.
`pol prod status` adds the forge row (replicas, version, held repos, whether `apt.<domain>/repository.key` answers a
PGP block); `pol prod verify` adds `https://forge.<domain>/api/v1/version` (200) and
`https://apt.<domain>/dists/stable/Release` (200, or 404 = "empty — publish first", not a failure). The forge is in
the os-security `swarm-lean`/`swarm-full` scenarios (warn-only, complain mode, like every other service).

## Not yet (deliberately)

- **ssh on production** — https only until a slice publishes 22 deliberately (and the posture row learns it).
- **The pipeline reading the forge** (poll/checkout/promotion against it) — a later slice; frg-2 put the forge on production.
- The whole forest is not mirrored by frg-0 — frg-1 does that on the box he chooses.
- No releases are published here yet — frg-3.
