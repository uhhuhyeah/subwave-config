#!/usr/bin/env bash
# Fetch the LIVE docker-compose.yml off the SUB/WAVE LXC into ./deploy/ so drift
# against the tracked copy is visible as a git diff.
#
# Why this exists: /opt/subwave/docker-compose.yml used to be hand-edited on the
# LXC and tracked nowhere. Because upgrades here are image-first (bump
# SUBWAVE_VERSION in .env, pull, up -d), the compose file itself never moved —
# so when upstream SPLIT the acoustic analyzer out of tts-heavy into its own
# `analyzer` service (v0.34.0), our stack silently lost its analysis backend and
# nothing noticed for three weeks. Tracking the file makes that class of drift a
# reviewable diff instead of an invisible regression.
#
# The tracked copy is deliberately kept BYTE-IDENTICAL to the upstream release's
# docker-compose.yml (currently v1.2.0). All local configuration lives in the
# LXC's .env, which this repo does not track (it holds secrets). Keeping zero
# drift is the point: `git diff` after a pull tells you exactly what an upgrade
# changed, and reconciling against a new release stays a clean diff.
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] && source .env || true
PVE_SSH="${PVE_SSH:-root@100.110.0.9}"
SUBWAVE_CTID="${SUBWAVE_CTID:-107}"
STACK_DIR="${SUBWAVE_STACK_DIR:-/opt/subwave}"

mkdir -p deploy
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

ssh -n "$PVE_SSH" "pct exec ${SUBWAVE_CTID} -- cat '${STACK_DIR}/docker-compose.yml'" > "$tmp"
[ -s "$tmp" ] || { echo "Fetched an empty file — aborting without touching deploy/." >&2; exit 1; }

if [ -f deploy/docker-compose.yml ] && diff -q deploy/docker-compose.yml "$tmp" >/dev/null; then
  echo "No drift: live docker-compose.yml matches deploy/docker-compose.yml."
  exit 0
fi

if [ -f deploy/docker-compose.yml ]; then
  echo "Drift detected (< tracked | > live):"
  diff deploy/docker-compose.yml "$tmp" || true
  echo
fi

cp "$tmp" deploy/docker-compose.yml
echo "Wrote deploy/docker-compose.yml from CT ${SUBWAVE_CTID}. Review with 'git diff'."
