# Architecture

## Goal

A box you can hand to any org running events on lal.gg: flash or install, connect
projector and network, done. Everything about *what* it shows is decided in lal.gg;
the box only has to (1) reach the web, (2) show one browser window reliably for days,
(3) accept a handful of management commands, (4) resist casual tampering.

## Boot sequence

1. **systemd** starts `NetworkManager`, `seatd`, `lalgg-agent.service`,
   `lalgg-console.service` (tty2) and `getty@tty1` with autologin for `kiosk`.
2. `kiosk`'s `~/.bash_profile` `exec`s `start-kiosk.sh` on tty1.
3. `start-kiosk.sh` loops forever: `cage -- chromium --kiosk <MANAGE_URL>/beamer/device`.
   If Chromium or cage dies, the loop restarts them after 3 s.
4. The page loads from lal.gg and calls `http://127.0.0.1:8484/info`.
   - Not enrolled → it renders the pairing screen (code from the agent).
   - Enrolled → it renders the assigned playlist like the normal player.
5. The agent, once enrolled, heartbeats to Directus and executes commands.

Nothing in this sequence needs a local account password, a display manager, X11, or a
desktop environment. The installed footprint is ~600 MB on top of a netinst Debian.

## Components and why

| Choice | Alternative considered | Why this one |
|---|---|---|
| **cage** (wlroots kiosk compositor) | sway kiosk config, X11 + openbox, Weston kiosk-shell | One binary, one window, no config, blocks VT switching unless asked, Wayland (tear-free, no xrandr scripts). Sway is the upgrade path if runtime output switching is ever needed. |
| **Chromium** from Debian | Firefox kiosk, WPE/Cog | Managed policies (`/etc/chromium/policies/managed`) give a real lockdown with a JSON file; best video decode support on x86 and Pi; identical to what the lal.gg team tests against. |
| **Agent in Python stdlib** | Go binary, Node | Zero dependencies on a stock Debian, readable by everyone on the team, no build step. If it ever needs to be faster or smaller it is ~300 lines to port. |
| **Output selection via kernel `video=`** | `wlr-randr`, sway `output` blocks | Works for every compositor, survives updates, no runtime protocol dependency. Costs a reboot to change, which is acceptable for a device that is set up once. |
| **Polling Directus** | WebSocket subscription | Works today with no server change; the agent's 30 s poll is trivial load. Switch to `subscribe` when the instance enables WebSockets. |
| **Self-update from GitHub Releases** | balena, apt repo, unattended-upgrades | No third party, no infrastructure, checksummed tarball, the same idempotent installer runs again. |

## What is deliberately *not* on the box

- No content, no slideshow logic, no cache management: the web app does all of it
  (service worker + Cache API for media), so a laptop opening the same URL behaves the
  same way.
- No inbound network service. The agent binds `127.0.0.1` only. `ss -ltn` on a finished
  box shows exactly that one loopback port.
- No admin credentials. See `docs/device-api.md` §1.
- No SSH by default. If a team wants it, they enable it with their own keys; the console
  can do it (menu 9 → shell).

## State on disk

```
/etc/lalgg-beamer/config.env        settings + device token (0600 root)
/var/lib/lalgg-beamer/chromium/     browser profile + 2 GB disk cache (kiosk user)
/var/lib/lalgg-beamer/pairing_secret  only while unenrolled
/var/lib/lalgg-beamer/kiosk.log     last 2000 lines of session restarts
/usr/local/lib/lalgg-beamer/        the installed scripts + VERSION
```

Everything under `/var/lib/lalgg-beamer` is safe to delete: the box re-pairs.

## Planned (not in v0.1)

- **Read-only root** with a tmpfs overlay so a pulled power cable cannot corrupt the
  filesystem; only `/var/lib/lalgg-beamer` and `/etc/lalgg-beamer` stay writable.
  On Raspberry Pi OS this is `raspi-config`'s overlay option; on Debian x86 it is an
  initramfs overlay hook. Needs testing per platform before it goes into the installer.
- **Preseeded installer ISO** so no one types `apt-get` on a box (Debian netinst +
  `preseed.cfg` running `install.sh` in `late_command`), built in GitHub Actions.
- **Hardware video decode flags per platform** (VA-API on Intel/AMD, V4L2 on Pi),
  detected by the installer and written to `KIOSK_EXTRA_FLAGS`.
- **Screenshot command** (`grim` under cage) so an admin can see what the wall shows.
- **Watchdog** via systemd `WatchdogSec` for the agent and a hardware watchdog on boxes
  that have one.
