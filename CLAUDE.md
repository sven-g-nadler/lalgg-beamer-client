# CLAUDE.md — lalgg-beamer-client

Auto-loaded into every Claude Code session in this repo. Read this first, then
`docs/architecture.md`, `docs/device-api.md` and `docs/threat-model.md`.

## What this is

A self-provisioning, locked-down Linux appliance (Debian + cage + Chromium kiosk + a
small Python agent) that shows the **lal.gg Beamer module** on a projector and is managed
from the lal.gg web app: outbound-only, no fleet service, no local server at events.
Owner: Sven Nadler (`sven-g-nadler`), Lock and Load cofounder. Will move to the
`lockandloadch` GitHub org once he can create repos there.

## Relationship to the main project

- The web app and backend live in `lockandloadch/lockandload.ch-3.0` (Vue 3 + Directus,
  cloned locally at `C:\Users\svenn\OneDrive\privat\_Code\LaL\lockandload.ch-3.0`). Its
  `CLAUDE.md` and `docs/` are canonical for anything on that side; Fabrizio reviews there
  and wants **an issue before any change**.
- The Beamer module already exists there (issue #29: `beamer_slide_templates`,
  `beamer_playlists`, `beamer_playlist_items`, player at `/beamer/:playlistId`). This
  repo only covers the **device**. The server-side pieces this device needs
  (`beamer_devices`, the "Beamer Device" policy, `/beamer/claim` + `/beamer/pair`) are a
  *proposal* in `docs/device-api.md` and must become an issue in the main repo before
  they are built. Keep the agent's field names and that document in sync.
- Production Directus: `https://directus.lockandload.ch` (one instance, no staging;
  anything the agent writes lands in production data).

## Conventions

- Target: Debian 12/13 x86_64 and Raspberry Pi OS Lite 64-bit. Test in a Hyper-V or
  VirtualBox VM first; hardware video decode is the only thing that differs on metal.
- Shell scripts: `bash`, `set -euo pipefail` where a failure must abort, `bash -n` before
  committing. Agent: Python 3.11+ **standard library only**, `python3 -m py_compile`.
  LF line endings everywhere (`.gitattributes` enforces it; the checkout is on Windows).
- `install/install.sh` must stay **idempotent**: `update.sh` re-runs it on every release.
  Never overwrite `/etc/lalgg-beamer/config.env` if it exists.
- The agent binds `127.0.0.1` only. Do not add listeners on other interfaces.
- No admin credentials on the box, ever. Enrollment hands the device its own scoped token.
- Secrets never go in git (`.gitignore` covers `*.env`); the example config is the only
  env file committed.
- Commit messages: short imperative subject, body explains *why*. Update `CHANGELOG.md`
  under "unreleased" with every user-visible change.

## Roadmap (see README)

v0.1 installer + kiosk + console + agent (this) → v0.2 read-only root, enrollment wired
to the real lal.gg endpoints, per-platform video flags → v0.3 preseeded Debian installer
ISO built in GitHub Actions → v0.4 Raspberry Pi image via `pi-gen`.

## Open decisions

- License (MIT vs AGPL-3.0) before the org transfer.
- Display selection stays kernel `video=` (reboot to change) unless someone needs runtime
  switching; then move from cage to sway with an `output` config.
- `KIOSK_ALLOW_VT_SWITCH` default 1 (technician can reach the PIN console at the box).
