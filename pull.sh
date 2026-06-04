#!/usr/bin/env bash
# Pull SUB/WAVE's live config (personas, shows, schedule, llm/tts/embedding,
# station/weather/theme) from the controller API into config/settings.json.
# Overwrites the local copy. Secrets (API keys) are masked by the API and never
# land in the repo. Commit local edits first if you have unsaved ones.
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] || { echo "Missing .env (copy .env.example and fill it in)" >&2; exit 1; }
source .env

echo "Pulling ${SUBWAVE_URL}/api/settings -> config/settings.json"
curl -fsS -u "${SUBWAVE_ADMIN_USER}:${SUBWAVE_ADMIN_PASS}" "${SUBWAVE_URL}/api/settings" \
  | python3 -c 'import json,sys; json.dump(json.load(sys.stdin)["values"], open("config/settings.json","w"), indent=2, sort_keys=True); open("config/settings.json","a").write("\n")'
echo "Done ($(wc -c < config/settings.json | tr -d ' ') bytes)."
