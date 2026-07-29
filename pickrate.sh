#!/usr/bin/env bash
# Measure the DJ picker's real success rate from the station's event log.
#
# Why this exists: the admin Stats screen reports JSON-validity, not pick-acceptance
# (the "Stats-UI trap" in the vault dev log), and the controller's docker logs are
# lost on every container recreate. state/logs/events-*.jsonl is the only durable
# record of whether a pick actually landed, so this reads that.
#
# Reads `llm` events of kind djAgentPick / djAgentRepick / pickNextTrack and reports
# ok:fail per day, plus the distinct error strings. A djAgentPick failure means the
# DJ agent never produced a usable pick and the station fell back to the pool — it
# is not audible, but a rising rate means the model's structured-output emission is
# degrading. Known baseline (0.46.0-1.2.0, measured 2026-07-29 over 369 attempts /
# 12 days): ~12% failure. Dominant mode is "agent did not call the done tool before
# stopping" (34/44), which fails FAST (~15s); only 9/44 exhaust llm.agentTimeoutMs.
# Count only djAgentPick in the denominator — including djAgentRepick/pickNextTrack
# halves the apparent rate (a mistake made once already).
#
#   ./pickrate.sh              # last 7 days
#   ./pickrate.sh 14           # last 14 days
#   ./pickrate.sh 7 --errors   # also list the distinct failure strings
#
# Note picks batch on AUTO_QUEUE_REFRESH_MINUTES (60), so a few minutes of samples
# means nothing — give any change a couple of days before reading it.
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] && source .env || true
PVE_SSH="${PVE_SSH:-root@100.110.0.9}"
SUBWAVE_CTID="${SUBWAVE_CTID:-107}"
SUBWAVE_STACK_DIR="${SUBWAVE_STACK_DIR:-/opt/subwave}"

DAYS="${1:-7}"
case "$DAYS" in ''|*[!0-9]*) echo "Usage: $0 [days] [--errors]" >&2; exit 2 ;; esac
SHOW_ERRORS=0
for a in "$@"; do [ "$a" = "--errors" ] && SHOW_ERRORS=1; done

# The remote python is piped to `python3 -` on stdin, so nothing inside it may read
# stdin (see doctor.sh for the same trap biting a `docker compose exec`).
ssh -o ConnectTimeout=15 "$PVE_SSH" \
  "pct exec ${SUBWAVE_CTID} -- python3 - '${SUBWAVE_STACK_DIR}/state/logs' '${DAYS}' '${SHOW_ERRORS}'" <<'PYEOF'
import glob, json, os, sys, collections, datetime

logdir, days, show_errors = sys.argv[1], int(sys.argv[2]), sys.argv[3] == "1"
files = sorted(glob.glob(os.path.join(logdir, "events-*.jsonl")))[-days:]
if not files:
    print("No event logs found in %s" % logdir); sys.exit(0)

KINDS = ("djAgentPick", "djAgentRepick", "pickNextTrack")
per_day = collections.OrderedDict()
errors = collections.Counter()
ms_ok, ms_fail = [], []

for f in files:
    day = os.path.basename(f)[7:17]
    c = collections.Counter()
    with open(f, errors="replace") as fh:
        for line in fh:
            try: e = json.loads(line)
            except Exception: continue
            if e.get("type") != "llm": continue
            k = str(e.get("kind", ""))
            if k not in KINDS: continue
            ok = bool(e.get("ok"))
            c[k + (":ok" if ok else ":FAIL")] += 1
            if k == "djAgentPick":
                (ms_ok if ok else ms_fail).append(e.get("ms") or 0)
                if not ok: errors[str(e.get("error"))[:120]] += 1
    if c: per_day[day] = c

print("DJ picker success rate — last %d day-logs in %s\n" % (len(files), logdir))
print("%-12s %6s %6s %6s   %s" % ("day", "picks", "ok", "fail", "rate"))
tot_ok = tot_fail = 0
for day, c in per_day.items():
    ok, fail = c["djAgentPick:ok"], c["djAgentPick:FAIL"]
    n = ok + fail
    tot_ok += ok; tot_fail += fail
    rate = ("%5.1f%%" % (100.0 * fail / n)) if n else "    —"
    print("%-12s %6d %6d %6d   %s fail" % (day, n, ok, fail, rate))

n = tot_ok + tot_fail
print("\n%-12s %6d %6d %6d   %s fail" % ("TOTAL", n, tot_ok, tot_fail,
      ("%5.1f%%" % (100.0 * tot_fail / n)) if n else "    —"))

def med(v):
    v = sorted(x for x in v if x)
    return v[len(v)//2] if v else 0
print("\ndjAgentPick latency: median ok %dms · median failed %dms" % (med(ms_ok), med(ms_fail)))
print("  (a failure pinned near llm.agentTimeoutMs means the native attempt ate the")
print("   whole shared deadline, starving the done-tool retry — see repo ISSUES.md)")

if errors:
    print("\ndistinct failure modes:" if show_errors else "\ntop failure mode:")
    for msg, count in errors.most_common(None if show_errors else 1):
        print("  %5d  %s" % (count, msg))
    if not show_errors and len(errors) > 1:
        print("  (%d more — re-run with --errors)" % (len(errors) - 1))
PYEOF
