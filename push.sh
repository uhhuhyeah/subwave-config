#!/usr/bin/env bash
# Push config/settings.json to the SUB/WAVE controller via the admin API.
# Shows a diff vs the live config first and asks before applying. Applies LIVE
# (POST /api/settings) — no container restart, unlike editing settings.json by
# hand. Mixer-only fields (stream/archive) may flag requiresRestart; everything
# else (personas, shows, schedule, llm, tts, ...) takes effect immediately.
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] || { echo "Missing .env (copy .env.example and fill it in)" >&2; exit 1; }
source .env

LOCAL=config/settings.json
[ -f "$LOCAL" ] || { echo "No $LOCAL — run ./pull.sh first" >&2; exit 1; }

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
RESP="$(curl -sS -u "${SUBWAVE_ADMIN_USER}:${SUBWAVE_ADMIN_PASS}" \
  -X POST -H 'Content-Type: application/json' --data @"$LOCAL" \
  "${SUBWAVE_URL}/api/settings")"
echo "$RESP" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    if "error" in d: print("ERROR:", d["error"]); sys.exit(1)
    print("Applied. requiresRestart:", d.get("requiresRestart", False))
    if d.get("requiresRestart"): print("  (mixer settings changed — run a mixer restart from admin if needed)")
except Exception:
    print("Unexpected response:", sys.stdin.read()[:300])'
