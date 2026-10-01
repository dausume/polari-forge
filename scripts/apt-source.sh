#!/bin/bash
# apt-source.sh — `pol forge apt-source [<owner>]`: the two things a person needs
# to install Polari debs from the forge's Debian registry: the key fetch and the
# `deb` line. Distribution/component match the old reprepro route (stable/main).
# Knobs: FORGE_ROOT_URL (the public address on production), FORGE_APT_DIST,
# FORGE_APT_COMPONENT.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
case "${1:-}" in -h|--help|help) sed -n '2,6p' "$0"; exit 0 ;; esac
owner="${1:-$FORGE_OWNER}"
dist="${FORGE_APT_DIST:-stable}"; comp="${FORGE_APT_COMPONENT:-main}"
base="${FORGE_ROOT_URL}api/packages/$owner/debian"
say "sudo curl -fsSL ${base}/repository.key -o /etc/apt/keyrings/polari-forge.asc"
say "echo \"deb [signed-by=/etc/apt/keyrings/polari-forge.asc] ${base} ${dist} ${comp}\" | sudo tee /etc/apt/sources.list.d/polari-forge.list"
