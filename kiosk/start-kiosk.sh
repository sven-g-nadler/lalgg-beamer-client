#!/usr/bin/env bash
# Runs as the 'kiosk' user on tty1 (from ~/.bash_profile).
# Starts cage (single-window Wayland compositor) with Chromium in kiosk mode and
# relaunches the whole session whenever it exits: a browser crash costs ~3 s of black.
set -u

# Everything the session prints goes to the journal (journalctl -t lalgg-kiosk): the
# state dir is root-owned and journald handles rotation on a box that runs for months.
exec > >(systemd-cat -t lalgg-kiosk) 2>&1

STATE_DIR=/var/lib/lalgg-beamer
INFO_URL=http://127.0.0.1:8484/info

# Settings come from the agent, not from config.env: that file is root-only because it
# holds the device token, and this script runs as the unprivileged kiosk user. The agent
# publishes the non-secret subset under "kiosk" in /info. Re-read on every restart so a
# URL changed from lal.gg or the console takes effect with the next browser restart.
# Defaults apply if the agent is not up (yet).
load_settings() {
  START_URL="https://manage.lal.gg/beamer/device"
  KIOSK_EXTRA_FLAGS=""
  KIOSK_ALLOW_VT_SWITCH=1
  local info tries=0
  until info="$(curl -sf -m 2 "$INFO_URL")" || [ $((++tries)) -ge 10 ]; do sleep 1; done
  [ -n "${info:-}" ] || { echo "agent not reachable at $INFO_URL, using defaults"; return; }
  START_URL="$(jq -r '.kiosk.start_url // empty' <<<"$info")"
  KIOSK_EXTRA_FLAGS="$(jq -r '.kiosk.extra_flags // empty' <<<"$info")"
  [ "$(jq -r '.kiosk.allow_vt_switch' <<<"$info")" = "true" ] || KIOSK_ALLOW_VT_SWITCH=0
  [ -n "$START_URL" ] || START_URL="https://manage.lal.gg/beamer/device"
}

export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export XDG_SESSION_TYPE=wayland
export MOZ_ENABLE_WAYLAND=1
# wlroots: log less, never bother with a cursor on a display nobody touches
export WLR_NO_HARDWARE_CURSORS=1
export WLR_XCURSOR_SIZE=1

CHROMIUM_FLAGS=(
  --kiosk
  --ozone-platform=wayland
  --user-data-dir="$STATE_DIR/chromium"
  --no-first-run
  --noerrdialogs
  --disable-infobars
  --disable-session-crashed-bubble
  --disable-features=TranslateUI,MediaRouter
  --autoplay-policy=no-user-gesture-required
  --overscroll-history-navigation=0
  --disable-pinch
  --password-store=basic
  --check-for-update-interval=31536000
  --disk-cache-dir="$STATE_DIR/chromium/cache"
  --disk-cache-size=2147483647   # must fit int32; Chromium ignores the flag otherwise
  --enable-features=VaapiVideoDecodeLinuxGL
  --ignore-gpu-blocklist
)

while :; do
  load_settings
  # `cage` without -s: no VT switching from inside the session. The PIN console
  # lives on tty2 and is reached via the agent's "console" command or Alt+F2 only
  # when KIOSK_ALLOW_VT_SWITCH=1 (default: 1, so a technician can get to the PIN).
  CAGE_FLAGS=(-d)
  [ "$KIOSK_ALLOW_VT_SWITCH" = "1" ] && CAGE_FLAGS+=(-s)

  echo "starting kiosk: $START_URL ${KIOSK_EXTRA_FLAGS:+(extra flags: $KIOSK_EXTRA_FLAGS)}"
  # shellcheck disable=SC2086  # extra flags are intentionally word-split
  cage "${CAGE_FLAGS[@]}" -- chromium "${CHROMIUM_FLAGS[@]}" $KIOSK_EXTRA_FLAGS "$START_URL"
  rc=$?
  printf 'kiosk session ended (rc=%s), restarting in 3 s\n' "$rc"
  sleep 3
done
