# lalgg-beamer-client

A self-provisioning, locked-down display appliance for the **lal.gg Beamer module**.
Flash it (or run the install script on a stock Debian box), plug it into a projector and
the network, and it boots straight into a fullscreen browser that dials **outbound-only**
into lal.gg, shows a pairing code, and does nothing else until an Org Admin claims it.

From then on the box is managed from the lal.gg web app: which event and playlist it
shows, online status, hardware info, reboot, update. Nothing on site, no inbound ports,
no third-party fleet service.

> **Status: v0.1 pre-alpha.** Installer, kiosk session, local console and agent exist and
> are meant to be tested in a VM first. The device API on the lal.gg side is a
> *proposal* (see [`docs/device-api.md`](docs/device-api.md)) and does not exist yet; the
> same goes for the `manage.lal.gg` hostname used as the default everywhere. Until it is
> live, set `KIOSK_START_URL` in `/etc/lalgg-beamer/config.env` to test the kiosk.

## How it works

```
+---------------------------- appliance -------------------------------+
|                                                                      |
|  tty1: kiosk user, autologin -> cage (Wayland kiosk compositor)      |
|        -> chromium --kiosk  https://manage.lal.gg/beamer/device      |
|           ^ managed policies: URL allow-list, no devtools, no        |
|             downloads, no sign-in, autoplay on                       |
|                                                                      |
|  tty2: PIN-protected local console (network, display, reboot, shell) |
|                                                                      |
|  lalgg-agent (root, systemd):                                        |
|     127.0.0.1:8484  -> /info for the web page (pairing code, HW)     |
|     outbound HTTPS  -> heartbeat, pick up commands, self-update      |
+----------------------------------------------------------------------+
                    | all traffic outbound, HTTPS, client-initiated
                    v
              lal.gg  /  directus.lockandload.ch
```

Three parts, deliberately separate:

| Part | Where | Job |
|---|---|---|
| **Kiosk session** | `kiosk/` | `cage` + Chromium in kiosk mode with a watchdog loop. The browser *is* the player: the slideshow, caching, transitions and the pairing screen are the lal.gg web app. |
| **Agent** | `agent/` | Small Python (stdlib only) service. Reports hardware and status, executes `reboot`/`restart-browser`/`update`, serves `/info` on localhost so the web page knows it is on a managed device. |
| **Local console** | `kiosk/lalgg-console.sh` | The only thing reachable at the box: a PIN prompt on tty2 that opens a menu for Wi-Fi/Ethernet, display output, reboot, and (for technicians) a shell. |

Everything else (playlists, themes, scheduling, which device shows what) lives in lal.gg.

## Quick start (Debian 12/13, x86_64 or Raspberry Pi OS Lite 64-bit)

Fresh minimal install, network up, then as root:

```bash
apt-get install -y git
git clone https://github.com/sven-g-nadler/lalgg-beamer-client /opt/lalgg-beamer-client
/opt/lalgg-beamer-client/install/install.sh
reboot
```

The installer asks for a console PIN and the management URL (default
`https://manage.lal.gg`). On reboot the box shows the pairing screen.

Unattended (preseed, CI, `ssh` without a tty): pass both as environment variables instead,
`LALGG_CONSOLE_PIN=1234 LALGG_MANAGE_URL=https://manage.lal.gg install/install.sh`. They are
only read on the first run; an existing `/etc/lalgg-beamer/config.env` is never overwritten.

**Test it in a VM first**: Hyper-V or VirtualBox with a plain Debian netinst, EFI on,
2 GB RAM. Everything works there except hardware video decoding.

## Repository layout

```
install/install.sh        idempotent installer for a stock Debian
kiosk/start-kiosk.sh      cage + chromium launcher with watchdog
kiosk/lalgg-console.sh    PIN-protected tty2 console
kiosk/chromium-policy.json  managed browser policies (allow-list, lockdown)
agent/lalgg_agent.py      the agent (Python 3.11+, no dependencies)
agent/lalgg-agent.service systemd unit
agent/update.sh           self-update from GitHub Releases
config/lalgg-beamer.env.example  all settings, one file
docs/architecture.md      boot sequence, components, decisions
docs/device-api.md        PROPOSED contract with lal.gg / Directus
docs/threat-model.md      what the lockdown does and does not defend against
```

## Roadmap

- **v0.1** install script over stock Debian, VM-tested. *(this)*
- **v0.2** enrollment flow wired to the lal.gg device API once it exists; read-only root
  filesystem; hardware video decode flags per platform.
- **v0.3** unattended installer ISO (Debian netinst + preseed) built by GitHub Actions and
  attached to Releases.
- **v0.4** flashable Raspberry Pi image via `pi-gen`.

## License

To be decided before the repo moves to the `lockandloadch` org (MIT or AGPL-3.0).
