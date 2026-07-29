#!/usr/bin/env bash
# doctor.sh — remote health sweep for SUB/WAVE (LXC 107), the homelab analogue
# of the official `subwave doctor` CLI task (controller/cli/src/doctor.ts).
#
# Why a script instead of the CLI: the upstream CLI operates a *local*
# docker-compose stack (it shells `docker compose` against the local daemon and
# probes localhost). Our station runs in LXC 107, which has no node/npm and a
# single hand-rolled docker-compose.yml. So this mirrors doctor's *check set*
# but runs it the homelab way — API probes over the tailnet, and host/docker/
# state/log checks via the PVE host + `pct exec`, the same path avatars-*.sh use.
#
# Read-only. Makes no changes. Exit 0 if nothing failed, 1 if any FAIL.
#
# Usage:  ./doctor.sh            # full sweep, pretty output
#         ./doctor.sh --quiet    # only the summary tally line
#
# Env (defaults shown; override in .env or inline):
#   SUBWAVE_URL=http://192.168.1.18:7700
#   PVE_SSH=root@100.110.0.9   SUBWAVE_CTID=107   SUBWAVE_STACK_DIR=/opt/subwave
set -uo pipefail
cd "$(dirname "$0")"
[ -f .env ] || { echo "Missing .env (copy .env.example and fill it in)" >&2; exit 1; }
source .env

PVE_SSH="${PVE_SSH:-root@100.110.0.9}"
SUBWAVE_CTID="${SUBWAVE_CTID:-107}"
SUBWAVE_STACK_DIR="${SUBWAVE_STACK_DIR:-/opt/subwave}"
SUBWAVE_URL="${SUBWAVE_URL:-http://192.168.1.18:7700}"
QUIET=0; [ "${1:-}" = "--quiet" ] && QUIET=1

# --- rendering -------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_FAIL=$'\033[31m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_OK=; C_WARN=; C_FAIL=; C_DIM=; C_BOLD=; C_OFF=
fi
n_ok=0; n_warn=0; n_fail=0; n_skip=0
first_unhappy=""

section() { [ "$QUIET" = 1 ] && return; printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_OFF"; }

# finding <ok|warn|fail|skip> <label> <detail> [hint]
finding() {
  local st="$1" label="$2" detail="${3:-}" hint="${4:-}"
  case "$st" in
    ok)   n_ok=$((n_ok+1));   local sym="${C_OK}✓${C_OFF}" ;;
    warn) n_warn=$((n_warn+1)); local sym="${C_WARN}‼${C_OFF}" ;;
    fail) n_fail=$((n_fail+1)); local sym="${C_FAIL}✗${C_OFF}" ;;
    skip) n_skip=$((n_skip+1)); local sym="${C_DIM}·${C_OFF}" ;;
  esac
  if [ "$st" = fail ] || [ "$st" = warn ]; then
    [ -z "$first_unhappy" ] && first_unhappy="${label}: ${detail}${hint:+ — ${hint}}"
  fi
  [ "$QUIET" = 1 ] && return
  printf '  %s %-22s %s%s%s\n' "$sym" "$label" "$C_DIM" "$detail" "$C_OFF"
  [ -n "$hint" ] && printf '      %s↳ %s%s\n' "$C_DIM" "$hint" "$C_OFF"
}

# --- remote sweep (one SSH round-trip: docker, compose, state, content, logs)
# Emits pipe-delimited records the Mac side parses. Runs inside CT 107 as root,
# so it can read Liquidsoap's 0600 radio.log (the host operator can't).
REMOTE=$(ssh -o ConnectTimeout=15 "$PVE_SSH" "pct exec ${SUBWAVE_CTID} -- bash -s '${SUBWAVE_STACK_DIR}'" 2>/dev/null <<'REMOTE_EOF'
set -uo pipefail
STACK="${1:-/opt/subwave}"; cd "$STACK" 2>/dev/null || { echo "R|fatal|stack dir $STACK missing"; exit 0; }

# docker daemon
if docker info >/dev/null 2>&1; then echo "R|docker|ok|reachable"; else echo "R|docker|fail|no response"; fi

# compose services (Service|State)
ps=$(docker compose ps --format '{{.Service}}|{{.State}}' 2>/dev/null)
if [ -z "$ps" ]; then echo "R|stack|down"; else
  echo "R|stack|up"
  while IFS='|' read -r svc state; do [ -n "$svc" ] && echo "R|svc|${svc}|${state}"; done <<< "$ps"
fi

# Acoustic-analysis backend, probed FROM THE CONTROLLER (the only view that
# matters — the controller is what calls it). This check exists because upstream
# moved analysis out of tts-heavy into a standalone `analyzer` service in v0.34.0
# and this stack silently ran without any backend for three weeks: "service
# running" was green the whole time because the service simply wasn't defined,
# and the controller degrades to NULL analysis without erroring. So assert
# reachability AND the CLAP capability, not just that a container exists.
if ! docker compose ps --services 2>/dev/null | grep -qx analyzer; then
  echo "R|analyzer|fail|no 'analyzer' service in docker-compose.yml|Acoustic analysis has NO backend. Port the analyzer service from the upstream compose (subwave-config/deploy)."
else
  # </dev/null is REQUIRED: this whole script is fed to `bash -s` over ssh via a
  # heredoc, and `docker compose exec -T` reads stdin — without this it swallows
  # the remaining script and every later check silently vanishes (22 ok -> 14 ok).
  # Same stdin-consumption class as the 2026-06-04 push.sh bug.
  ah=$(docker compose exec -T controller sh -c 'curl -s -m 8 http://analyzer:8080/health' 2>/dev/null </dev/null)
  if [ -z "$ah" ]; then
    echo "R|analyzer|fail|unreachable from controller|Service defined but not answering — docker compose logs analyzer"
  else
    aud=$(printf '%s' "$ah" | grep -o '"analyze_audio_capable":[^,}]*' | cut -d: -f2)
    case "$aud" in
      *true*) echo "R|analyzer|ok|reachable · CLAP audio-capable" ;;
      *)      echo "R|analyzer|warn|reachable but NOT CLAP-capable (lean flavour?)|Set ANALYZER_HEAVY=1 in .env for subwave-analyzer-heavy, then recreate." ;;
    esac
  fi
fi

# state dir + required subdirs (mirror CLI: voice jingles sessions logs archive)
if [ ! -d state ]; then echo "R|state|fail|missing"
elif [ ! -w state ]; then echo "R|state|fail|not writable"
else echo "R|state|ok|writable"
  for sub in voice jingles sessions logs archive; do
    if [ ! -e "state/$sub" ]; then echo "R|statesub|${sub}|warn|missing — created on first write"
    elif [ ! -w "state/$sub" ]; then echo "R|statesub|${sub}|fail|not writable"
    else echo "R|statesub|${sub}|ok|writable"; fi
  done
fi

# content: auto.m3u (autonomous fallback playlist)
if [ ! -f state/auto.m3u ]; then echo "R|auto|warn|missing — written on first auto-refresh"
else
  c=$(grep -cE '^[^#[:space:]]' state/auto.m3u 2>/dev/null || echo 0)
  [ "$c" -gt 0 ] && echo "R|auto|ok|${c} entries" || echo "R|auto|warn|empty — fallback has nothing to play"
fi

# content: jingles.m3u (+ verify each referenced file exists)
if [ ! -f state/jingles.m3u ]; then echo "R|jingles|warn|missing — run scripts/generate-jingles.sh"
else
  total=0; missing=0; firstmiss=""
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue;; esac
    total=$((total+1))
    f="${line#/var/sub-wave/jingles/}"
    if [ ! -f "state/jingles/$f" ]; then missing=$((missing+1)); [ -z "$firstmiss" ] && firstmiss="$f"; fi
  done < state/jingles.m3u
  if [ "$total" -eq 0 ]; then echo "R|jingles|warn|empty — no station idents"
  elif [ "$missing" -eq 0 ]; then echo "R|jingles|ok|${total} jingles, all present"
  else echo "R|jingles|warn|${total} listed, ${missing} missing on disk|first: ${firstmiss}"; fi
fi

# logs: radio.log tail — scan last 200 lines for error-shaped entries
if [ ! -f state/logs/radio.log ]; then echo "R|radiolog|skip|no log yet — Liquidsoap writes it on boot"
else
  tail=$(tail -c 65536 state/logs/radio.log 2>/dev/null | tail -n 200)
  if [ -z "$tail" ]; then echo "R|radiolog|skip|unreadable"
  else
    errs=$(printf '%s\n' "$tail" | grep -ciE '\[error\]|connection refused|permission denied|failed to connect' || true)
    if [ "${errs:-0}" -gt 0 ]; then
      sample=$(printf '%s\n' "$tail" | grep -iE '\[error\]|connection refused|permission denied|failed to connect' | head -1 | cut -c1-100)
      echo "R|radiolog|warn|${errs} error-shaped line(s) in last 200|${sample}"
    else echo "R|radiolog|ok|no recent errors"; fi
  fi
fi
REMOTE_EOF
)

ssh_ok=1; [ -z "$REMOTE" ] && ssh_ok=0

# Determine stack state (drives whether we run the live API probes)
STACK_UP=0
printf '%s\n' "$REMOTE" | grep -q '^R|stack|up' && STACK_UP=1

# --- Host -----------------------------------------------------------------
section "Host (PVE ${PVE_SSH} → CT ${SUBWAVE_CTID})"
if [ "$ssh_ok" = 0 ]; then
  finding fail "ssh + pct exec" "no response from ${PVE_SSH}" "Check Tailscale / 'ssh ${PVE_SSH}' and that CT ${SUBWAVE_CTID} is running."
else
  finding ok "ssh + pct exec" "reachable"
  while IFS='|' read -r _ key st detail; do
    [ "$key" = docker ] && finding "$st" "docker daemon" "$detail" \
      "$([ "$st" = fail ] && echo 'dockerd down in CT 107 — pct exec 107 systemctl status docker')"
  done < <(printf '%s\n' "$REMOTE" | grep '^R|docker|')
fi

# --- Compose --------------------------------------------------------------
section "Compose (${SUBWAVE_STACK_DIR})"
if [ "$ssh_ok" = 0 ]; then
  finding skip "services" "host unreachable"
elif [ "$STACK_UP" = 0 ]; then
  finding fail "stack" "no containers running" "cd ${SUBWAVE_STACK_DIR} && docker compose up -d"
else
  while IFS='|' read -r _ _ svc state; do
    [ -z "$svc" ] && continue
    case "$state" in
      running) finding ok "service · ${svc}" "$state" ;;
      restarting) finding warn "service · ${svc}" "$state" "could be a crash loop — check logs" ;;
      *) finding fail "service · ${svc}" "$state" "docker compose logs ${svc}" ;;
    esac
  done < <(printf '%s\n' "$REMOTE" | grep '^R|svc|')

  # Acoustic-analysis backend (see the remote probe for why this is its own check)
  if printf '%s\n' "$REMOTE" | grep -q '^R|analyzer|'; then
    while IFS='|' read -r _ _ st detail hint; do
      finding "$st" "analyzer · acoustic analysis" "$detail" "$hint"
    done < <(printf '%s\n' "$REMOTE" | grep '^R|analyzer|')
  fi
fi

# --- Controller (live API over the tailnet) -------------------------------
section "Controller (${SUBWAVE_URL})"
if [ "$STACK_UP" = 0 ]; then
  finding skip "/api/health" "stack down"
  finding skip "/api/now-playing" "stack down"
else
  health=$(curl -fsS -m 4 "${SUBWAVE_URL}/api/health" 2>/dev/null || true)
  hstatus=$(printf '%s' "$health" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("status","?"))' 2>/dev/null || echo "")
  if [ "$hstatus" = "on-air" ]; then finding ok "/api/health" "on-air"
  elif [ -n "$hstatus" ]; then finding warn "/api/health" "responded but status=${hstatus}"
  else finding fail "/api/health" "no response" "Controller unreachable — pct exec ${SUBWAVE_CTID} -- docker compose logs controller"; fi

  np=$(curl -fsS -m 4 "${SUBWAVE_URL}/api/now-playing" 2>/dev/null || true)
  if [ -n "$np" ]; then
    read -r online listeners title artist < <(printf '%s' "$np" | python3 -c '
import json,sys
d=json.load(sys.stdin); np=d.get("nowPlaying") or {}
print(int(bool(d.get("streamOnline"))), (d.get("listeners") or {}).get("current",0) if isinstance(d.get("listeners"),dict) else (d.get("listeners") or 0), (np.get("title") or "?"), (np.get("artist") or "?"))
' 2>/dev/null || echo "0 0 ? ?")
    if [ "$online" = 1 ]; then finding ok "/api/now-playing" "stream online · ${listeners} listener(s) · ${title} — ${artist}"
    else finding warn "/api/now-playing" "responding but stream offline" "Liquidsoap may not be on Icecast yet — give it 10s."; fi
  else finding fail "/api/now-playing" "no response"; fi

  ob=$(curl -fsS -m 4 "${SUBWAVE_URL}/api/onboarding/status" 2>/dev/null || true)
  needs=$(printf '%s' "$ob" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("needsSetup"))' 2>/dev/null || echo "")
  case "$needs" in
    False) finding ok "setup" "complete" ;;
    True)  finding fail "setup" "incomplete — Navidrome + LLM not configured" "Open ${SUBWAVE_URL}/onboarding" ;;
    *)     finding skip "setup" "status endpoint unreachable" ;;
  esac

  # admin creds reachable? (auth-gated endpoint should 200 with our .env creds)
  if [ -n "${SUBWAVE_ADMIN_USER:-}" ] && [ -n "${SUBWAVE_ADMIN_PASS:-}" ]; then
    code=$(curl -s -o /dev/null -m 4 -w '%{http_code}' -u "${SUBWAVE_ADMIN_USER}:${SUBWAVE_ADMIN_PASS}" "${SUBWAVE_URL}/api/settings" 2>/dev/null || echo 000)
    case "$code" in
      200) finding ok "admin auth" "settings API accepts .env creds" ;;
      401|403) finding fail "admin auth" "rejected (${code})" "SUBWAVE_ADMIN_USER/PASS in .env don't match the controller's" ;;
      *) finding warn "admin auth" "unexpected ${code}" ;;
    esac
  else finding warn "admin auth" "no creds in .env to test"; fi
fi

# --- Icecast (stream) -----------------------------------------------------
section "Icecast"
if [ "$STACK_UP" = 0 ]; then
  finding skip "/stream.mp3" "stack down"
else
  # The stream is endless, so curl always trips -m and exits non-zero; it still
  # prints the -w line (code+type known once headers arrive), so read that.
  sout=$(curl -s -o /dev/null -m 3 -w '%{http_code} %{content_type}' "${SUBWAVE_URL}/stream.mp3" 2>/dev/null)
  read -r scode sct <<< "${sout:-000 -}"
  if [ "$scode" = 200 ] && printf '%s' "$sct" | grep -qi 'audio/mpeg'; then finding ok "/stream.mp3" "200 · ${sct}"
  elif [ "$scode" = 200 ]; then finding warn "/stream.mp3" "200 but content-type=${sct}"
  else finding fail "/stream.mp3" "${scode} · ${sct}" "Icecast may be down — docker compose logs broadcast"; fi
fi

# --- State / Content / Logs (from the remote sweep) -----------------------
section "State"
if [ "$ssh_ok" = 0 ]; then finding skip "state/" "host unreachable"; else
  while IFS='|' read -r _ _ st detail; do finding "$st" "state/" "$detail"; done < <(printf '%s\n' "$REMOTE" | grep '^R|state|')
  while IFS='|' read -r _ _ sub st detail; do finding "$st" "state/${sub}" "$detail"; done < <(printf '%s\n' "$REMOTE" | grep '^R|statesub|')
fi

section "Content"
if [ "$ssh_ok" = 0 ]; then finding skip "playlists" "host unreachable"; else
  while IFS='|' read -r _ _ st detail hint; do finding "$st" "auto.m3u" "$detail" "$hint"; done < <(printf '%s\n' "$REMOTE" | grep '^R|auto|')
  while IFS='|' read -r _ _ st detail hint; do finding "$st" "jingles.m3u" "$detail" "$hint"; done < <(printf '%s\n' "$REMOTE" | grep '^R|jingles|')
fi

section "Logs"
if [ "$ssh_ok" = 0 ]; then finding skip "radio.log" "host unreachable"; else
  while IFS='|' read -r _ _ st detail hint; do finding "$st" "radio.log tail" "$detail" "$hint"; done < <(printf '%s\n' "$REMOTE" | grep '^R|radiolog|')
fi

# --- summary --------------------------------------------------------------
printf '\n%s%d ok · %d warn · %d fail · %d skip%s\n' \
  "$C_BOLD" "$n_ok" "$n_warn" "$n_fail" "$n_skip" "$C_OFF"
if [ "$n_fail" -gt 0 ]; then
  printf '%sfirst issue → %s%s\n' "$C_FAIL" "$first_unhappy" "$C_OFF"; exit 1
elif [ "$n_warn" -gt 0 ]; then
  printf '%sfirst note → %s%s\n' "$C_WARN" "$first_unhappy" "$C_OFF"
fi
exit 0
