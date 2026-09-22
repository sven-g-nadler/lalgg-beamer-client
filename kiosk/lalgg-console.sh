#!/usr/bin/env bash
# PIN-protected local console. Runs as root on tty2 (lalgg-console.service).
# The only thing a person at the box can do without lal.gg: network, display output,
# reboot, and - for technicians - a shell. Three wrong PINs = 60 s lockout.
set -u
CONF=/etc/lalgg-beamer/config.env
LIB_DIR=/usr/local/lib/lalgg-beamer

load_conf() { [ -r "$CONF" ] && . "$CONF"; }
pin_ok() {
  local pin; load_conf
  read -r -s -p "PIN: " pin; echo
  [ "$(printf '%s' "$pin" | sha256sum | cut -d' ' -f1)" = "${CONSOLE_PIN_SHA256:-}" ]
}

banner() {
  clear
  echo "lal.gg beamer client  $(cat "$LIB_DIR/VERSION" 2>/dev/null || echo dev)   host: $(hostname)"
  echo "management: ${MANAGE_URL:-?}    enrolled: $([ -n "${DEVICE_TOKEN:-}" ] && echo yes || echo no)"
  echo "----------------------------------------------------------------------"
}

show_status() {
  banner
  echo "IP addresses:"; ip -br -4 addr | awk '$2=="UP"{print "  "$1"  "$3}'
  echo
  echo "Displays (kernel connectors):"
  for c in /sys/class/drm/card*-*; do
    [ -e "$c/status" ] || continue
    printf '  %-14s %s' "$(basename "$c" | sed 's/^card[0-9]*-//')" "$(cat "$c/status")"
    [ -r "$c/enabled" ] && printf '  (%s)' "$(cat "$c/enabled")"
    echo
  done
  echo
  echo "Agent: $(systemctl is-active lalgg-agent)   Pairing/info: curl -s http://127.0.0.1:8484/info"
  echo; read -r -p "Enter to continue" _
}

configure_displays() {
  banner
  echo "Output selection is done via the kernel command line (video=...), which works"
  echo "for every compositor and survives updates. Current setting:"
  grep -o 'video=[^ ]*' /etc/default/grub 2>/dev/null | tr '\n' ' '; echo
  echo
  echo "Connectors:"
  for c in /sys/class/drm/card*-*; do
    [ -e "$c/status" ] && echo "  $(basename "$c" | sed 's/^card[0-9]*-//')  $(cat "$c/status")"
  done
  echo
  echo "Examples:  HDMI-A-1:1920x1080@60      force a mode on HDMI-A-1"
  echo "           DP-1:d                    disable DP-1 (built-in panel: eDP-1:d)"
  echo "Enter one or more 'CONNECTOR:MODE' items separated by spaces, or empty to keep:"
  read -r spec
  [ -z "$spec" ] && return
  local args=""; for s in $spec; do args="$args video=$s"; done
  sed -i 's/ video=[^ "]*//g' /etc/default/grub
  sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1$args\"/" /etc/default/grub
  update-grub && echo "written - takes effect after reboot" || echo "update-grub failed"
  read -r -p "Enter to continue" _
}

set_management_url() {
  banner; load_conf
  read -r -p "Management URL [${MANAGE_URL:-https://manage.lal.gg}]: " url
  [ -z "$url" ] && return
  sed -i "s|^MANAGE_URL=.*|MANAGE_URL=$url|" "$CONF"
  systemctl restart lalgg-agent; pkill -u kiosk cage 2>/dev/null
  echo "saved, kiosk restarting"; sleep 2
}

enroll_manually() {
  banner
  echo "Manual enrollment (until the lal.gg pairing flow exists): paste the device"
  echo "token and device id an admin created in Directus. Empty = cancel."
  read -r -p "Directus URL [${DIRECTUS_URL:-https://directus.lockandload.ch}]: " durl
  read -r -p "Device id (uuid): " did
  read -r -s -p "Device token: " tok; echo
  [ -z "$did" ] || [ -z "$tok" ] && return
  sed -i -e "s|^DIRECTUS_URL=.*|DIRECTUS_URL=${durl:-${DIRECTUS_URL:-https://directus.lockandload.ch}}|" \
         -e "s|^DEVICE_ID=.*|DEVICE_ID=$did|" -e "s|^DEVICE_TOKEN=.*|DEVICE_TOKEN=$tok|" "$CONF"
  systemctl restart lalgg-agent; echo "agent restarted"; sleep 2
}

menu() {
  load_conf; banner
  cat <<'EOF'
  1) Status (IP, displays, agent)
  2) Network (Wi-Fi / Ethernet)         nmtui
  3) Display outputs
  4) Management URL
  5) Enroll manually (device id + token)
  6) Restart browser
  7) Reboot
  8) Update client from GitHub Releases
  9) Shell (technician)
  0) Lock console
EOF
  read -r -p "> " choice
  case "$choice" in
    1) show_status ;;
    2) nmtui ;;
    3) configure_displays ;;
    4) set_management_url ;;
    5) enroll_manually ;;
    6) pkill -u kiosk cage; echo "browser restarting"; sleep 2 ;;
    7) systemctl reboot ;;
    8) "$LIB_DIR/update.sh"; read -r -p "Enter to continue" _ ;;
    9) echo "type 'exit' to return"; bash -l ;;
    0) return 1 ;;
  esac
  return 0
}

fails=0
while :; do
  clear
  echo "lal.gg beamer client - console locked"
  if pin_ok; then
    fails=0
    while menu; do :; done
  else
    fails=$((fails+1)); echo "wrong PIN"
    if [ "$fails" -ge 3 ]; then echo "locked for 60 s"; sleep 60; fails=0; else sleep 2; fi
  fi
done
