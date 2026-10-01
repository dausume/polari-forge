# What the forge costs

Every Polari engine carries a **measured** cost before it is built on (his rule, 2026-09-26). This is the forge's.

## The measurement (2026-09-30, the home dev box)

| | |
|---|---|
| image | `codeberg.org/forgejo/forgejo:11@sha256:946243ed…3f0` (Forgejo 11.0.16, GPL-3.0-or-later) |
| idle RSS | **94 MiB** |
| peak RSS | **455 MiB** — during Debian package signing (the registry signs its `Release` index on upload) |
| git, the whole forest | **51 MB** of packed history for every public repo (full history kept — retention never touches git) |
| Debian registry | proven with a real deb: upload → signed index → `repository.key` |
| memory limit | **512 MiB** (`deploy.resources.limits.memory`) — the peak fits under it with room |
| verdict | feasible on the 2 GB droplet next to the lean stack, with the limit |

frg-0's own live proof (one repo mirrored, five probe debs uploaded, retention run) read: RSS 110–159 MiB, cgroup peak
257–275 MiB, data 4 MiB.

## How `pol forge meter` reports

One JSON line per run, appended to `.generated/forge/meter.jsonl` (gitignored) and printed as a table:

    {"at":"…","rss_mib":110.4,"peak_mib":256.7,"cpu_pct":0.06,"data_mib":4,
     "areas":{"git":1,"packages":1,"db":3,"attachments":1,"log":1},"repos":1,"packages":0}

| field | from |
|---|---|
| `rss_mib`, `cpu_pct` | `docker stats --no-stream` (memory usage excludes page cache) |
| `peak_mib` | the container's cgroup `memory.peak` (since the container started); `null` when unreadable |
| `data_mib` | `du -sm /data` inside the container — the whole volume |
| `areas.git` | `/data/git/repositories` |
| `areas.packages` | `/data/gitea/packages` (the registry blobs — what `pol forge retention` trims) |
| `areas.db` | `/data/gitea/forgejo.db` (sqlite) |
| `areas.attachments`, `areas.log` | `/data/gitea/attachments`, `/data/gitea/log` |
| `repos` | `*.git` directories under the repositories root |
| `packages` | package versions owned by `FORGE_OWNER` (all types), counted through the API |

`du -sm` rounds up to whole MiB, so an empty area reads 1. Re-measure after the forest is mirrored (frg-1) and after
the first real release lands in the registry (frg-3); the numbers above are the ones to beat.
