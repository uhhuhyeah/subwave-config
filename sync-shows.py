#!/usr/bin/env python3
"""Sync config/settings.json's `shows` array to the live station, one upsert each.

Split out of push.sh because `shows` cannot travel inside POST /api/settings on
v1.15.0 at all. That route builds the show schema with `personaIds: []`,
intending "roster unknown, so don't check host membership" — but the schema
checks it with `ctx.personaIds.includes(v)`, and `[].includes(x)` is always
false. So every show is rejected with "must reference an existing persona",
including the live config posted straight back unchanged.
(controller/src/schemas/show.ts documents `personaIds: null` as the unchecked
sentinel; controller/src/settings/patch-registry.ts passes `[]` instead.)

POST /api/shows is the way in: it rebuilds the roster per request from the live
personas, upserts one show, and runs the same validateShowsStrict. Revisit when
upstream fixes the settings route. Found on v1.15.0, 2026-09-10.

Never deletes: a show that exists live but not locally is reported, not removed.

Usage: sync-shows.py <settings.json>   (reads SUBWAVE_URL/_ADMIN_USER/_ADMIN_PASS)
"""
import json
import os
import subprocess
import sys

try:
    USER = os.environ["SUBWAVE_ADMIN_USER"]
    PASS = os.environ["SUBWAVE_ADMIN_PASS"]
    URL = os.environ["SUBWAVE_URL"]
except KeyError as e:
    sys.exit(f"missing env var {e} (source .env with `set -a`)")


def api(method, path, body=None):
    cmd = ["curl", "-sS", "-u", f"{USER}:{PASS}", "-X", method, f"{URL}{path}"]
    if body is not None:
        cmd += ["-H", "Content-Type: application/json", "--data-binary", json.dumps(body)]
    out = subprocess.run(cmd, capture_output=True, text=True).stdout
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return {"error": f"non-JSON response: {out[:200]}"}


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)

    want = {s["id"]: s for s in json.load(open(sys.argv[1]))["shows"]}
    live_resp = api("GET", "/api/settings")
    if "error" in live_resp:
        sys.exit(f"  could not read live shows: {live_resp['error']}")
    live = {s["id"]: s for s in live_resp["values"]["shows"]}

    updated = failed = 0
    for sid, show in want.items():
        if live.get(sid) == show:
            continue
        result = api("POST", "/api/shows", {"show": show})
        if "error" in result:
            print(f"  FAILED {sid}: {result['error']}")
            failed += 1
        else:
            print(f"  updated {show.get('name', sid)}")
            updated += 1

    orphans = sorted(set(live) - set(want))
    if orphans:
        print(f"  NOTE: {len(orphans)} show(s) live but not local: {', '.join(orphans)}")
        print("        DELETE /api/shows/<id> removes one; this script never deletes.")

    current = len(want) - updated - failed
    print(f"  shows: {updated} updated, {current} already current, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
