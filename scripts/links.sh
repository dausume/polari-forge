#!/bin/bash
# links.sh — `pol forge links`: print what we do NOT hold and where it is — the
# hold=link lines of forest.txt, as recorded by `pol forge mirror --forest` in
# .generated/forge/links.txt (owner/repo <space> github URL, one per line).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
case "${1:-}" in -h|--help|help) sed -n '2,4p' "$0"; exit 0 ;; esac

if [ ! -s "$GEN/links.txt" ]; then
    say "no links — nothing is hold=link in forest.txt yet, or pol forge mirror --forest has not run"
    exit 0
fi
n=0
while IFS=' ' read -r repo url; do
    [ -n "$repo" ] || continue
    say "link   $repo → $url (not held)"
    n=$((n+1))
done < "$GEN/links.txt"
okl "$n linked (not held)"
