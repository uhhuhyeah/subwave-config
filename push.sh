#!/usr/bin/env bash
# Push config/settings.json to the SUB/WAVE controller via the admin API.
# Shows a diff vs the live config first and asks before applying. Applies LIVE
# (POST /api/settings) — no container restart, unlike editing settings.json by
# hand. Mixer-only fields (stream/archive) may flag requiresRestart; everything
# else (personas, shows, schedule, llm, tts, ...) takes effect immediately.
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] || { echo "Missing .env (copy .env.example and fill it in)" >&2; exit 1; }
# -a so the vars reach sync-shows.py, which reads them from the environment.
set -a; source .env; set +a

LOCAL=config/settings.json
[ -f "$LOCAL" ] || { echo "No $LOCAL — run ./pull.sh first" >&2; exit 1; }

# GET /api/settings serves fields that POST /api/settings rejects outright
# ("unknown settings keys"), so the file pull.sh writes is not directly
# postable. Both are DERIVED, not config: minTrackSeconds is computed from the
# crossfade (settings.minTrackSeconds(s)) and boundaryFadeMinTrackSeconds is a
# constant the server exposes so the admin UI's hint matches its own
# validation. Neither has a stored value to round-trip, so dropping them from
# the payload loses nothing. Found on v1.15.0, 2026-09-10.
READONLY_KEYS='minTrackSeconds boundaryFadeMinTrackSeconds'

TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
echo "Fetching live config for diff..."
curl -fsS -u "${SUBWAVE_ADMIN_USER}:${SUBWAVE_ADMIN_PASS}" "${SUBWAVE_URL}/api/settings" \
  | python3 -c 'import json,sys; json.dump(json.load(sys.stdin)["values"], sys.stdout, indent=2, sort_keys=True); print()' > "$TMP"

# Normalise local to the same formatting so the diff is real (not whitespace).
LOCALN="$(mktemp)"; trap 'rm -f "$TMP" "$LOCALN"' EXIT
python3 -c 'import json,sys; json.dump(json.load(open(sys.argv[1])), sys.stdout, indent=2, sort_keys=True); print()' "$LOCAL" > "$LOCALN"

if diff -q "$TMP" "$LOCALN" >/dev/null; then
  echo "Live config already matches config/settings.json. Nothing to push."
  exit 0
fi

echo
echo "Diff (live -> local):"
echo "----------------------------------------"
diff -u "$TMP" "$LOCALN" || true
echo "----------------------------------------"
echo

read -r -p "Apply local -> SUB/WAVE (live)? [Y/n] " reply
case "$reply" in n|N|no|NO) echo "Aborted."; exit 0 ;; esac

echo "Applying..."
PAYLOAD="$(mktemp)"; trap 'rm -f "$TMP" "$LOCALN" "$PAYLOAD"' EXIT
python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split(): d.pop(k, None)
d.pop("shows", None)
json.dump(d, sys.stdout)' "$LOCAL" "$READONLY_KEYS" > "$PAYLOAD"

# Shows first, one upsert each, so a failure here stops before the bulk write.
# See sync-shows.py for why shows cannot ride inside POST /api/settings.
echo "Syncing shows via POST /api/shows..."
./sync-shows.py "$LOCAL"

RESP="$(curl -sS -u "${SUBWAVE_ADMIN_USER}:${SUBWAVE_ADMIN_PASS}" \
  -X POST -H 'Content-Type: application/json' --data @"$PAYLOAD" \
  "${SUBWAVE_URL}/api/settings")"
echo "$RESP" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    if "error" in d: print("ERROR:", d["error"]); sys.exit(1)
    print("Applied. requiresRestart:", d.get("requiresRestart", False))
    if d.get("requiresRestart"): print("  (mixer settings changed — run a mixer restart from admin if needed)")
except Exception:
    print("Unexpected response:", sys.stdin.read()[:300])'
