#!/usr/bin/env bash
# Deploy ./deploy/docker-compose.yml to the SUB/WAVE LXC and apply it.
#
# Unlike push.sh (admin API, live, no restart), this one RECREATES CONTAINERS —
# including broadcast, which drops the Icecast stream for ~30-60s. It always
# confirms before applying, and it shows you the diff first.
#
# Profiles: tts-heavy is profile-gated upstream (`profiles: ["tts-heavy"]`) and is
# DELIBERATELY LEFT OFF here. It existed on this station only to host the CLAP
# analyzer; upstream moved that into the `analyzer` service in v0.34.0, and every
# persona uses cloud (ElevenLabs) TTS with tts.heavyEnabled=false, so its
# Chatterbox/PocketTTS engines are dead weight (~6 GiB resident). To bring it
# back, pass PROFILES="tts-heavy" to this script.
#
# --remove-orphans clears containers this compose file no longer defines at all.
# It does NOT remove a profile-gated service you simply left out of PROFILES —
# tts-heavy is still *defined* in the file, so compose considers it known, not
# orphaned, and leaves it running. Verified the hard way 2026-07-29. To actually
# take it down:  docker compose --profile tts-heavy rm -sf tts-heavy
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] && source .env || true
PVE_SSH="${PVE_SSH:-root@100.110.0.9}"
SUBWAVE_CTID="${SUBWAVE_CTID:-107}"
STACK_DIR="${SUBWAVE_STACK_DIR:-/opt/subwave}"
PROFILES="${PROFILES:-}"

LOCAL=deploy/docker-compose.yml
[ -f "$LOCAL" ] || { echo "Missing $LOCAL — run compose-pull.sh first." >&2; exit 1; }

profile_args=""
for p in $PROFILES; do profile_args="$profile_args --profile $p"; done

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# -n so this pre-confirmation SSH call can't eat piped stdin (the 2026-06-04 bug
# that broke `echo y | ./push.sh` across the other config repos).
ssh -n "$PVE_SSH" "pct exec ${SUBWAVE_CTID} -- cat '${STACK_DIR}/docker-compose.yml'" > "$tmp" 2>/dev/null || true

if diff -q "$tmp" "$LOCAL" >/dev/null 2>&1; then
  echo "Live docker-compose.yml already matches $LOCAL — nothing to push."
  exit 0
fi

echo "Changes to apply (< live | > new):"
diff "$tmp" "$LOCAL" || true
echo
echo "Target : CT ${SUBWAVE_CTID}:${STACK_DIR}/docker-compose.yml"
echo "Apply  : docker compose${profile_args} up -d --remove-orphans"
echo "Profiles enabled: ${PROFILES:-<none>}"
echo
echo "*** This RECREATES containers. The broadcast stream will drop briefly. ***"
read -r -p "Proceed? [y/N] " reply
case "$reply" in y|Y|yes|YES) ;; *) echo "Aborted."; exit 0 ;; esac

stamp="$(date +%Y%m%d-%H%M%S)"
echo "==> Backing up live compose to docker-compose.yml.bak-${stamp}"
ssh -n "$PVE_SSH" "pct exec ${SUBWAVE_CTID} -- cp -a '${STACK_DIR}/docker-compose.yml' '${STACK_DIR}/docker-compose.yml.bak-${stamp}'"

echo "==> Copying new compose"
ssh "$PVE_SSH" "pct exec ${SUBWAVE_CTID} -- tee '${STACK_DIR}/docker-compose.yml' >/dev/null" < "$LOCAL"

echo "==> Validating (docker compose config)"
if ! ssh -n "$PVE_SSH" "pct exec ${SUBWAVE_CTID} -- bash -c 'cd ${STACK_DIR} && docker compose${profile_args} config -q'"; then
  echo "!! Validation FAILED — restoring the backup and leaving containers untouched." >&2
  ssh -n "$PVE_SSH" "pct exec ${SUBWAVE_CTID} -- cp -a '${STACK_DIR}/docker-compose.yml.bak-${stamp}' '${STACK_DIR}/docker-compose.yml'"
  exit 1
fi

echo "==> Pulling any newly referenced images"
ssh -n "$PVE_SSH" "pct exec ${SUBWAVE_CTID} -- bash -c 'cd ${STACK_DIR} && docker compose${profile_args} pull'" 2>&1 | tail -5

echo "==> Applying"
ssh -n "$PVE_SSH" "pct exec ${SUBWAVE_CTID} -- bash -c 'cd ${STACK_DIR} && docker compose${profile_args} up -d --remove-orphans'" 2>&1 | tail -25

echo
echo "Done. Rollback: cp ${STACK_DIR}/docker-compose.yml.bak-${stamp} over it and re-apply."
echo "Now run ./doctor.sh"
