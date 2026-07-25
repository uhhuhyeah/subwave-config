#!/usr/bin/env bash
# schedule.sh — render SUB/WAVE's weekly programming grid from the station
# config, so "who's on when / where are the gaps" is one command instead of a
# hand-rolled Python one-liner every time.
#
# Reads config/settings.json (the local mirror) by default; pass --pull to
# fetch live first (runs pull.sh). Read-only either way — never writes config.
#
# What it shows: the 24h x 7d grid (host initial + show), per-persona hour
# totals with their shows, and the open slots — with --persona it also lists
# the empty hours *adjacent* to that persona's blocks (the "next natural slot"
# finder). Hours are in the station's own timezone (printed in the header).
#
# Usage:  ./schedule.sh                 # grid + totals + gaps, from local copy
#         ./schedule.sh --pull          # pull live config first, then render
#         ./schedule.sh -p Hannah       # highlight Hannah + show her adjacent gaps
#         ./schedule.sh --gaps          # just the open-slots summary
#         ./schedule.sh --pull -p Cara  # combine freely
#
# Env (defaults shown; override in .env or inline):
#   SUBWAVE_URL=http://192.168.1.18:7700   (only used by --pull)
set -uo pipefail
cd "$(dirname "$0")"

PULL=0 GAPS_ONLY=0 PERSONA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pull)        PULL=1 ;;
    --gaps)        GAPS_ONLY=1 ;;
    -p|--persona)  shift; PERSONA="${1:-}" ;;
    -h|--help)     sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

if [ "$PULL" = 1 ]; then
  ./pull.sh >&2 || { echo "pull failed; rendering last local copy" >&2; }
fi

[ -f config/settings.json ] || { echo "config/settings.json not found — run ./pull.sh first" >&2; exit 1; }

USE_COLOR=0
[ -t 1 ] && [ -z "${NO_COLOR:-}" ] && USE_COLOR=1

SW_COLOR="$USE_COLOR" SW_PERSONA="$PERSONA" SW_GAPS_ONLY="$GAPS_ONLY" \
python3 - config/settings.json <<'PY'
import json, os, sys

path = sys.argv[1]
d = json.load(open(path))
color   = os.environ.get("SW_COLOR") == "1"
want    = os.environ.get("SW_PERSONA", "").strip().lower()
gaps_only = os.environ.get("SW_GAPS_ONLY") == "1"

shows = {s["id"]: s for s in d.get("shows", [])}
pname = {p["id"]: p["name"] for p in d.get("personas", [])}
sched = d.get("schedule", {})
tz    = d.get("timezone") or "(unset → container TZ)"
DAYS  = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]  # schedule key "0"=Sun (JS getDay)

# Stable per-persona colour (skips black/white); dim for empty cells.
PALETTE = [36, 32, 35, 33, 34, 31, 92, 95]  # cyan green magenta yellow blue red …
pids = list(pname)
pcol = {pid: PALETTE[i % len(PALETTE)] for i, pid in enumerate(pids)}

def c(s, code=None, *, dim=False, bold=False):
    if not color:
        return s
    pre = ""
    if bold: pre += "\033[1m"
    if dim:  pre += "\033[2m"
    if code: pre += f"\033[{code}m"
    return f"{pre}{s}\033[0m" if pre else s

def cell(pid, text, highlight):
    code = pcol.get(pid)
    return c(text, code, bold=highlight)

# --- resolve the wanted persona (name or id, case-insensitive prefix) ---
want_pid = None
if want:
    for pid, nm in pname.items():
        if nm.lower() == want or pid.lower() == want or nm.lower().startswith(want):
            want_pid = pid; break
    if not want_pid:
        print(f"no persona matching {want!r}; known: {', '.join(pname.values())}", file=sys.stderr)
        sys.exit(2)

# --- build a normalized [day][hour] -> show_id grid ---
grid = [[sched.get(str(day), [None]*24)[h] for h in range(24)] for day in range(7)]

def render_grid():
    print(c(f"SUB/WAVE weekly schedule  ·  timezone {tz}", bold=True))
    header = "     " + "".join(f"{DAYS[i]:>10}" for i in range(7))
    print(c(header, dim=True))
    for h in range(24):
        # skip the always-empty small hours to keep it compact, unless something's there
        row_ids = [grid[day][h] for day in range(7)]
        if not any(row_ids) and h < 5:
            continue
        line = f"{h:02d}   "
        for day in range(7):
            sid = grid[day][h]
            if not sid:
                line += c(f"{'·':>10}", dim=True)
            else:
                sh = shows.get(sid, {})
                pid = sh.get("personaId")
                label = f"{pname.get(pid,'?')[0]}:{sh.get('name','?'):>7.7}"[:10].rjust(10)
                line += cell(pid, label, highlight=(pid == want_pid))
        print(line)
    if color:
        key = "  ".join(cell(pid, pname[pid], pid == want_pid) for pid in pids)
        print(c("\nkey: ", dim=True) + key)

def render_totals():
    from collections import Counter, defaultdict
    hours = Counter(); byshow = defaultdict(Counter)
    for day in range(7):
        for h in range(24):
            sid = grid[day][h]
            if sid:
                pid = shows.get(sid, {}).get("personaId")
                hours[pid] += 1
                byshow[pid][shows[sid]["name"]] += 1
    total = sum(hours.values())
    print(c(f"\nProgrammed hours  ·  {total} of 168  ·  {168-total} open", bold=True))
    for pid, n in hours.most_common():
        head = cell(pid, f"  {pname.get(pid,pid):8} {n:3} h", pid == want_pid)
        detail = " · ".join(f"{s} {x}" for s, x in byshow[pid].most_common())
        print(f"{head}  {c(detail, dim=True)}")
    dark = [pname[pid] for pid in pids if pid not in hours]
    if dark:
        print(c(f"  off air: {', '.join(dark)}", dim=True))

def contiguous_runs(hourset):
    """Given a set of hours, yield (start,end_exclusive) contiguous runs."""
    for h in sorted(hourset):
        if h-1 not in hourset:
            start = h
        if h+1 not in hourset:
            yield (start, h+1)

def render_gaps():
    print(c("\nOpen slots", bold=True))
    for day in range(7):
        empties = {h for h in range(24) if not grid[day][h]}
        runs = [f"{a:02d}:00–{b:02d}:00" for a, b in contiguous_runs(empties)]
        print(f"  {DAYS[day]}  " + c(", ".join(runs) if runs else "(full)", dim=True))

def render_adjacent():
    # empty hours immediately before/after the wanted persona's blocks
    print(c(f"\nGaps adjacent to {pname[want_pid]}'s shows  (candidate extensions)", bold=True))
    found = False
    for day in range(7):
        mine = [h for h in range(24) if (sid := grid[day][h]) and shows[sid].get("personaId") == want_pid]
        if not mine:
            continue
        lo, hi = min(mine), max(mine)
        # walk outward from the contiguous-ish block; report the single empty hour on each side
        before = lo-1
        after  = hi+1
        for edge, lbl in ((before, "before"), (after, "after")):
            if 0 <= edge < 24 and not grid[day][edge]:
                sh = shows[grid[day][lo if lbl=='before' else hi]]["name"]
                print(f"  {DAYS[day]} {edge:02d}:00–{edge+1:02d}:00  {c(lbl+' '+sh, dim=True)}")
                found = True
    if not found:
        print(c("  none — her blocks are boxed in by other shows", dim=True))

if gaps_only:
    render_gaps()
else:
    render_grid()
    render_totals()
    render_gaps()
    if want_pid:
        render_adjacent()
PY
