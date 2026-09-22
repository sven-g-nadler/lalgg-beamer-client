# Changelog

## v0.1.0 (unreleased)

- Debian installer: cage + Chromium kiosk, autologin, managed browser policies with URL allow-list
- PIN-protected local console on tty2 (network, display outputs, management URL, manual enrollment, reboot, update, shell)
- Agent: `/info` on localhost, heartbeat + command loop against Directus, self-update from GitHub Releases
- Docs: architecture, proposed device API for lal.gg, threat model
- Installer: non-interactive mode via `LALGG_CONSOLE_PIN` / `LALGG_MANAGE_URL` (for preseed, CI and ssh without a tty); aborts instead of writing a PIN-less config; management URL must be https
- Kiosk: log to the journal (`journalctl -t lalgg-kiosk`) instead of a root-owned file the kiosk user could not write, which kept cage from ever starting
- Agent: report the CPU model name instead of the numeric x86 `model` field
- Kiosk: read the start URL and `KIOSK_*` settings from the agent's `/info` (new `kiosk` block) instead of `config.env`, which the kiosk user cannot read; before, `MANAGE_URL`, `KIOSK_START_URL` and `KIOSK_EXTRA_FLAGS` never reached the browser
- Chromium policy: drop the hard-coded `HomepageLocation`/`RestoreOnStartupURLs`, which would have overridden a changed management URL
