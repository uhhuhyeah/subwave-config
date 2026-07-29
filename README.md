# subwave-config

Git-tracked mirror of the **SUB/WAVE** station config running on Proxmox (LXC 107 on `pve01`). Sibling to `glance-start-page`, but synced through the admin **API** rather than copying files, so changes apply live with no container restart.

- **Live config:** the `values` object behind `GET/POST /api/settings` on the controller
- **Local copy:** `config/settings.json` (personas, shows, weekly schedule, llm/tts/embedding, station/weather/theme, mixer settings)
- **Full documentation:** [SUBWAVE AI Radio](obsidian://open?vault=sync-vault&file=04%20-%20Life%2FHomelab%2FSUBWAVE%20AI%20Radio) in Obsidian

## What this is and isn't

- **Tracked:** the human-authored station config (`config/settings.json`) and the canon persona **avatar images** (`avatars/*.webp`).
- **Not tracked, by design:**
  - **Secrets.** API keys (OpenRouter / OpenAI / ElevenLabs / Navidrome / admin) live in `/opt/subwave/.env` on the LXC. The API masks them, so they never reach this repo. The admin password used by the sync scripts lives in this repo's `.env` (gitignored).
  - **Runtime state.** `library.db` (music + embeddings), queue/session/now-playing, logs, downloaded voice models. All regenerable / churning; not config.
- **Separate repo:** the picker-fix *source overlay* is its own git checkout at `/opt/subwave-src` on the LXC (branch `fix/recency-window`). That's code; this is config.

## Edit workflow

```bash
cp .env.example .env   # first time: fill in SUBWAVE_ADMIN_PASS
./pull.sh              # fetch live config -> config/settings.json
$EDITOR config/settings.json
git add config/settings.json && git commit -m "..."
./push.sh              # diff vs live, confirm, apply (no restart)
```

- `pull.sh` — `GET /api/settings`, writes the `values` object to `config/settings.json` (sorted, stable for diffs).
- `push.sh` — diffs local vs live, prompts `[Y/n]`, then `POST /api/settings` (applies live). Mixer-only fields may flag `requiresRestart`; personas / shows / schedule / llm / tts apply immediately.

Most edits you'd make here (personas, the weekly show schedule, LLM/TTS choices) apply with zero downtime. This is the safe way to version and roll back the station's programming.

## Persona avatars

Avatar *images* aren't part of `/api/settings`, so `push.sh`/`pull.sh` don't touch them. The persona `avatar` field in `settings.json` only names the file (e.g. `p_sophie.webp`); the actual `.webp` lives on the LXC at `/opt/subwave/state/persona-avatars/`. The canon copies are committed here under `avatars/`, with two helper scripts (file-copy to CT 107 via the PVE host, `ssh` + `pct exec`):

```bash
./avatars-pull.sh   # capture live avatars -> avatars/ (after a UI upload), then commit
./avatars-push.sh   # restore avatars/ -> the LXC (after a rebuild, or to revert art)
```

Gotcha: uploading art via **admin → Personas** also sets the persona's `avatar` field in the *live* `settings.json`. After a UI upload, run **both** `./avatars-pull.sh` (grab the image) **and** `./pull.sh` (grab the field) before any later `./push.sh`, or the push will blank the `avatar` field. Override the target with `PVE_SSH` / `SUBWAVE_CTID` / `SUBWAVE_AVATAR_DIR` in `.env` if the host or container id ever changes.

## Deployment / compose (`deploy/docker-compose.yml`)

The stack file itself (`/opt/subwave/docker-compose.yml`) used to be hand-edited on the LXC and tracked nowhere. Because upgrades here are **image-first** — bump `SUBWAVE_VERSION` in the LXC `.env`, pull, `up -d` — the compose file never moved, so when upstream **split the acoustic analyzer out of `tts-heavy` into its own `analyzer` service (v0.34.0)**, this stack silently lost its analysis backend and nothing noticed for three weeks. Tracking the file turns that class of drift into a reviewable `git diff`.

```bash
./compose-pull.sh   # fetch the live compose -> deploy/ (shows drift), then commit
./compose-push.sh   # deploy/ -> the LXC, then recreate containers
```

**The tracked copy is deliberately byte-identical to the upstream release's `docker-compose.yml`** (currently v1.2.0 — verify with `git -C ~/code/subwave show v1.2.0:docker-compose.yml | diff - deploy/docker-compose.yml`). All local configuration lives in the LXC's `.env`, which this repo does not track because it holds secrets. Keeping zero drift is the point: reconciling against a new release stays a clean diff instead of a merge.

Notes:

- `compose-push.sh` **recreates containers**, so the Icecast stream drops for ~30–60s. It diffs, confirms, backs up (`docker-compose.yml.bak-<stamp>`), validates with `docker compose config`, and restores the backup automatically if validation fails.
- **`tts-heavy` is deliberately not enabled.** It is profile-gated upstream (`profiles: ["tts-heavy"]`) and existed on this station only to host the CLAP analyzer. Every persona uses cloud (ElevenLabs) TTS and `tts.heavyEnabled` is `false`, so its Chatterbox/PocketTTS engines were dead weight — it was holding ~6 GiB resident. Bring it back with `PROFILES="tts-heavy" ./compose-push.sh`.
- **`--remove-orphans` will not remove a profile-gated service you left out.** `tts-heavy` is still *defined* in the file, so compose treats it as known rather than orphaned. To actually take it down: `docker compose --profile tts-heavy rm -sf tts-heavy`.
- The analyzer flavour is chosen by **`ANALYZER_HEAVY=1`** in the LXC `.env` — that selects `subwave-analyzer-heavy` (CLAP "sounds-like" + Demucs). Unset gives the lean librosa-only image, which would leave sonic journeys without embeddings. `doctor.sh` asserts the CLAP capability specifically, not just that a container is running.

## Health check (`doctor.sh`)

```bash
./doctor.sh            # full sweep, ok/warn/fail/skip tally (exit 1 on any fail)
./doctor.sh --quiet    # just the summary line — handy for a quick "is it up?"
```

A read-only health sweep — the homelab analogue of the upstream `subwave doctor` CLI task (`controller/cli/src/doctor.ts`). The official CLI only operates a *local* docker-compose stack (it shells `docker compose` against the local daemon and probes `localhost`); LXC 107 has no node/npm and runs a single hand-rolled `docker-compose.yml`, so this script mirrors doctor's **check set** but runs it our way: live API probes over the tailnet + host/docker/state/log checks via the PVE host and `pct exec` (the same path the `avatars-*.sh` scripts use).

It checks, in order: **Host** (ssh + `pct exec` reachable, docker daemon up), **Compose** (stack up, per-service state), **Controller** (`/api/health` on-air, `/api/now-playing` stream + listeners, onboarding/setup complete, admin creds accepted), **Icecast** (`/stream.mp3` serving `audio/mpeg`), **State** (state dir + `voice/jingles/sessions/logs/archive` writable), **Content** (`auto.m3u` + `jingles.m3u` populated, jingle files present), **Logs** (`radio.log` tail scanned for error-shaped lines). Makes no changes. Run it after an upgrade or whenever something looks off. Targets are overridable via `.env` (`PVE_SSH` / `SUBWAVE_CTID` / `SUBWAVE_STACK_DIR` / `SUBWAVE_URL`).

## Schedule (`schedule.sh`)

```bash
./schedule.sh            # weekly grid + per-persona hours + open slots (from the local config)
./schedule.sh --pull     # pull live config first, then render
./schedule.sh -p Hannah  # highlight one persona + list the empty hours adjacent to their shows
./schedule.sh --gaps     # just the open-slots summary
```

A read-only view of `config/settings.json`'s `schedule` — the 24h × 7d grid (host initial + show name), per-persona hour totals with each persona's shows, and the open slots as contiguous runs. It reads the **local mirror** by default (fast, offline); `--pull` refreshes from the API first. Hours are shown in the station's own `timezone` (printed in the header) — the same clock the scheduler keys off, so what you see is what airs. `-p <name>` bolds a persona's cells and adds a **candidate-extensions** list: the empty hour immediately before/after each of their blocks — the "where could this DJ naturally grow" finder. Colour auto-disables when piped or under `NO_COLOR`.

## Reaching the LXC

`SUBWAVE_URL=http://192.168.1.18:7700` works on the Brookgrass LAN and from any Tailscale device (pve01 subnet-routes `192.168.1.0/24`). The `/api/*` prefix is stripped by Caddy and proxied to the controller (`:7701`).

## Rollback

```bash
git log -- config/settings.json
git checkout <sha> -- config/settings.json
./push.sh
```
