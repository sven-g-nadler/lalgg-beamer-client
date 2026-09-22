# Threat model

The appliance sits in a hall full of technically curious people for four days. The goal
is not to build a secure enclave: the box is an internet kiosk that holds one low-value
token. The goal is that **the display keeps showing what the org admins chose**, and
that fiddling with the box gains nobody anything beyond a blank screen.

## Assumptions

- The box is physically reachable (HDMI, USB, power, keyboard on a table).
- The network is the event's LAN with internet; it may be hostile-ish (other players).
- A determined attacker with time and a screwdriver can take the disk out. Accepted.
- The value at risk is the device token (§4 of `device-api.md`: read its own row, update
  its heartbeat, read public playlists) and the annoyance of a hijacked screen.

## Attacker classes and controls

| Who | What they try | Control | Status |
|---|---|---|---|
| Bored player with a keyboard | Alt+F4, Ctrl+T, F11, Ctrl+Shift+I, URL bar | Chromium `--kiosk`; devtools disabled by policy; new tabs/windows blocked; URL allow-list means even an escaped navigation lands on lal.gg or nothing | v0.1 |
| Same | Ctrl+Alt+F2… to a login prompt | tty3–6 masked; tty2 is the PIN console; tty1 is the kiosk with no shell behind it (`exec`) | v0.1 |
| Same | Guess the PIN | 3 tries → 60 s lockout; PIN stored as sha256 only | v0.1 |
| Same | Plug in a USB stick and boot from it | BIOS/UEFI boot order + firmware password (documented setup step, not scriptable) | doc |
| Same | Pull power to "reset" it | Watchdog loop + autologin bring it back; read-only root (planned) prevents fs corruption | v0.2 |
| Same | Unplug network | Page keeps the last cached playlist playing (web-app concern); agent backs off and reconnects | web app |
| Player on the LAN | Port-scan the box | Nothing listens except `127.0.0.1:8484`; no SSH by default | v0.1 |
| Player on the LAN | Spoof the management server (DNS/ARP) | HTTPS with system CA store; `MANAGE_URL` and `DIRECTUS_URL` are https-only; no plaintext fallback | v0.1 |
| Someone with a photo of the pairing code | Claim the device into their own org | Claim needs Org Admin + 2FA on lal.gg; finishing enrollment needs the random secret only the page on the box can read | design (`device-api.md` §3) |
| Someone who steals the box | Use the token | Token scoped to one row; revoke from the admin panel; no admin credentials on disk | v0.1 |
| Someone who steals the box | Read the disk | Config is 0600 root; no disk encryption (a kiosk needs to boot unattended). Accepted: the token is low-value and revocable | accepted |
| Malicious slide content | Escape the page, hit other sites | Same-origin as the app; URL allow-list; no downloads, no popups, no file dialogs | v0.1 |

## Explicit non-goals

- Protecting the box against its physical owner or against forensics.
- Preventing someone from unplugging HDMI and plugging in their own laptop. That is a
  venue/cable problem; the admin panel will show the device still online and unchanged.
- Secure boot / measured boot. Possible later with Debian's signed shim, not needed
  for the value at risk.

## Operational rules that matter more than code

- Set a **firmware password** and disable USB boot on every box before an event.
- Keep the **console PIN** per org, not per box, and change it after staff turnover.
- **Revoke** lost boxes in the panel immediately; that is one click and makes the token
  useless.
- Prefer **Ethernet**: no Wi-Fi credentials on the box, no deauth games, no captive portals.
