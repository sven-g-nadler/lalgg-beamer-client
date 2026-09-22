#!/usr/bin/env bash
# Runs as the 'kiosk' user on tty1 (from ~/.bash_profile).
# Starts cage (single-window Wayland compositor) with Chromium in kiosk mode and
# relaunches the whole session whenever it exits: a browser crash costs ~3 s of black.
set -u

CONF=/etc/lalgg-beamer/config.env
STATE_DIR=/var/lib/lalgg-beamer
MANAGE_URL="https://manage.lal.gg"
[ -r "$CONF" ] && . "$CONF"                     # MANAGE_URL, KIOSK_EXTRA_FLAGS, ...

# Where the browser lands. The agent exposes device identity on localhost; the
# lal.gg page detects that and shows the pairing code instead of a plain player.
START_URL="${KIOSK_START_URL:-$MANAGE_URL/beamer/device}"

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
  --disk-cache-size=2147483648
  --enable-features=VaapiVideoDecodeLinuxGL
  --ignore-gpu-blocklist
  ${KIOSK_EXTRA_FLAGS:-}
)

while :; do
  # `cage` without -s: no VT switching from inside the session. The PIN console
  # lives on tty2 and is reached via the agent's "console" command or Alt+F2 only
  # when KIOSK_ALLOW_VT_SWITCH=1 (default: 1, so a technician can get to the PIN).
  CAGE_FLAGS=(-d)
  [ "${KIOSK_ALLOW_VT_SWITCH:-1}" = "1" ] && CAGE_FLAGS+=(-s)

  cage "${CAGE_FLAGS[@]}" -- chromium "${CHROMIUM_FLAGS[@]}" "$START_URL" \
    >>"$STATE_DIR/kiosk.log" 2>&1
  rc=$?
  printf '%s kiosk session ended (rc=%s), restarting\n' "$(date -Is)" "$rc" >>"$STATE_DIR/kiosk.log"
  # keep the log from growing forever on a box that runs for months
  tail -n 2000 "$STATE_DIR/kiosk.log" > "$STATE_DIR/kiosk.log.tmp" && mv "$STATE_DIR/kiosk.log.tmp" "$STATE_DIR/kiosk.log"
  sleep 3
done
