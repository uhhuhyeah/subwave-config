#!/usr/bin/env bash
# Copy the canon avatar images in ./avatars/ onto the SUB/WAVE LXC.
#
# These images are NOT handled by push.sh — that syncs config/settings.json via the
# admin API only. The persona `avatar` field in settings.json names the file (e.g.
# "p_sophie.webp"); this script puts the actual .webp on disk in the controller's
# persona-avatars dir so the UI can serve it. Use after a rebuild, or to restore
# canon from the repo. Reaches LXC 107 via the PVE host (ssh + pct exec), the same
# path the rest of the homelab uses for this container.
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] && source .env || true
PVE_SSH="${PVE_SSH:-root@100.110.0.9}"
SUBWAVE_CTID="${SUBWAVE_CTID:-107}"
AVATAR_DIR="${SUBWAVE_AVATAR_DIR:-/opt/subwave/state/persona-avatars}"

shopt -s nullglob
files=(avatars/*.webp)
[ ${#files[@]} -gt 0 ] || { echo "No avatars/*.webp to push." >&2; exit 1; }

echo "Push ${#files[@]} avatar(s) -> CT ${SUBWAVE_CTID}:${AVATAR_DIR}"
printf '  %s\n' "${files[@]##*/}"
read -r -p "Proceed? [Y/n] " reply
case "$reply" in n|N|no|NO) echo "Aborted."; exit 0 ;; esac

# COPYFILE_DISABLE stops macOS bsdtar adding AppleDouble/xattr headers that make
# GNU tar on the LXC emit "Ignoring unknown extended header" warnings.
COPYFILE_DISABLE=1 tar -C avatars -cf - "${files[@]##*/}" \
  | ssh "$PVE_SSH" "pct exec ${SUBWAVE_CTID} -- tar -xf - -C '${AVATAR_DIR}'"
echo "Done. Each persona's avatar field in settings.json must name its file (push.sh)."
