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
    pol forge mirror <owner/repo>    pull-mirror one GitHub repo (POST /api/v1/repos/migrate, mirror, 8h);
                                     skips a repo already there; the forge-side owner is an org of the same name
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
reprepro route's) · `FORGE_KEEP` · `FORGE_FOREST`.

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

## Not yet (deliberately)

- **Not wired into `pol prod` profiles.** frg-2 (the pipeline reads the forge) and frg-3 (the forge routes + publish)
  do that, including dropping `ports:` in swarm (a swarm publish ignores the host IP) and sitting behind pol-proxy.
- The whole forest is not mirrored by frg-0 — frg-1 does that on the box he chooses.
- No releases are published here yet — frg-3.
