#!/bin/bash
# down.sh — `pol forge down`: stop + remove the container. The volume (the
# forge's content: repos, packages, database, keys) is KEPT; removing it is a
# person's deliberate act: docker volume rm polari-forge_forge-data
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
case "${1:-}" in -h|--help|help) sed -n '2,4p' "$0"; exit 0 ;; esac
compose down >/dev/null 2>&1 || compose down
okl "forge down — volume $VOLUME kept (docker volume rm $VOLUME to discard the content)"
