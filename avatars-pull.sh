#!/usr/bin/env bash
# Capture the live avatar images from the SUB/WAVE LXC into ./avatars/.
#
# Run this after uploading new persona art via admin -> Personas, then commit, so
# the repo holds the canon images. (A UI upload also sets the persona `avatar` field
# in the live settings.json — run ./pull.sh too so a later ./push.sh doesn't blank it.)
# Reaches LXC 107 via the PVE host (ssh + pct exec).
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] && source .env || true
PVE_SSH="${PVE_SSH:-root@100.110.0.9}"
SUBWAVE_CTID="${SUBWAVE_CTID:-107}"
AVATAR_DIR="${SUBWAVE_AVATAR_DIR:-/opt/subwave/state/persona-avatars}"

mkdir -p avatars
echo "Pull avatars <- CT ${SUBWAVE_CTID}:${AVATAR_DIR}"
ssh -n "$PVE_SSH" "pct exec ${SUBWAVE_CTID} -- tar -cf - -C '${AVATAR_DIR}' ." | tar -xf - -C avatars
echo "Pulled:"
ls -1 avatars/*.webp 2>/dev/null | sed 's#^#  #'
echo "Review with 'git status', then commit."
