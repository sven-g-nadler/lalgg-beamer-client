#!/usr/bin/env bash
# lalgg-beamer-client installer for Debian 12/13 (x86_64) and Raspberry Pi OS Lite (64-bit).
# Idempotent: safe to re-run after a git pull to pick up changes.
#
# What it does:
#   1. installs cage (Wayland kiosk compositor), chromium, network-manager, python3
#   2. creates the unprivileged 'kiosk' user with autologin on tty1
#   3. installs the kiosk launcher, managed Chromium policies, the agent and the console
#   4. locks the remaining ttys down (PIN console on tty2, nothing else)
#   5. writes /etc/lalgg-beamer/config.env (management URL, console PIN hash)
#
# Non-interactive use (preseed late_command, CI, remote install over ssh without a tty):
#   LALGG_CONSOLE_PIN=1234 LALGG_MANAGE_URL=https://manage.lal.gg install/install.sh
# Both are only read on first install (when config.env does not exist yet). Without a
# PIN and without a terminal the installer aborts instead of writing a config with no PIN.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR=/usr/local/lib/lalgg-beamer
CONF_DIR=/etc/lalgg-beamer
CONF="$CONF_DIR/config.env"
STATE_DIR=/var/lib/lalgg-beamer
KIOSK_USER=kiosk
DEFAULT_MANAGE_URL="https://manage.lal.gg"

log()  { printf '\033[1;32m[lalgg]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[lalgg] %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root"
. /etc/os-release
case "${ID:-}" in
  debian|raspbian) ;;
  *) die "this installer targets Debian / Raspberry Pi OS (found: ${ID:-unknown})" ;;
esac

# ---------------------------------------------------------------------------
# 1. packages
# ---------------------------------------------------------------------------
log "installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  cage chromium network-manager python3 curl ca-certificates jq \
  fonts-noto-core fonts-noto-color-emoji \
  libgl1-mesa-dri mesa-vulkan-drivers \
  alsa-utils pipewire-audio wireplumber \
  seatd dbus-user-session

# NetworkManager owns the network on the box (needed by the console's nmtui).
systemctl enable --now NetworkManager >/dev/null
systemctl enable --now seatd >/dev/null

# ---------------------------------------------------------------------------
# 2. kiosk user, no sudo, no password
# ---------------------------------------------------------------------------
if ! id -u "$KIOSK_USER" >/dev/null 2>&1; then
  log "creating user $KIOSK_USER"
  useradd --create-home --shell /bin/bash --comment "lal.gg beamer kiosk" "$KIOSK_USER"
fi
usermod -aG video,render,input,audio "$KIOSK_USER" 2>/dev/null || true
passwd -l "$KIOSK_USER" >/dev/null
# the session runs from ~/.bash_profile; nothing else may execute there
install -o "$KIOSK_USER" -g "$KIOSK_USER" -m 0644 /dev/stdin "/home/$KIOSK_USER/.bash_profile" <<'EOF'
# managed by lalgg-beamer-client - do not edit
if [ -z "${WAYLAND_DISPLAY:-}" ] && [ "$(tty)" = "/dev/tty1" ]; then
  exec /usr/local/lib/lalgg-beamer/start-kiosk.sh
fi
EOF

# ---------------------------------------------------------------------------
# 3. files
# ---------------------------------------------------------------------------
log "installing files to $LIB_DIR"
install -d -m 0755 "$LIB_DIR" "$CONF_DIR" "$STATE_DIR" /etc/chromium/policies/managed
install -m 0755 "$REPO_DIR/kiosk/start-kiosk.sh"     "$LIB_DIR/start-kiosk.sh"
install -m 0755 "$REPO_DIR/kiosk/lalgg-console.sh"   "$LIB_DIR/lalgg-console.sh"
install -m 0755 "$REPO_DIR/agent/lalgg_agent.py"     "$LIB_DIR/lalgg_agent.py"
install -m 0755 "$REPO_DIR/agent/update.sh"          "$LIB_DIR/update.sh"
install -m 0644 "$REPO_DIR/kiosk/chromium-policy.json" /etc/chromium/policies/managed/lalgg.json
install -m 0644 "$REPO_DIR/agent/lalgg-agent.service" /etc/systemd/system/lalgg-agent.service
install -d -o "$KIOSK_USER" -g "$KIOSK_USER" -m 0700 "$STATE_DIR/chromium"
printf '%s\n' "$(git -C "$REPO_DIR" describe --tags --always 2>/dev/null || echo dev)" > "$LIB_DIR/VERSION"

# ---------------------------------------------------------------------------
# 4. configuration (asked once, kept on re-run)
# ---------------------------------------------------------------------------
if [ ! -f "$CONF" ]; then
  log "first-time configuration"
  MANAGE_URL="${LALGG_MANAGE_URL:-$DEFAULT_MANAGE_URL}"
  PIN="${LALGG_CONSOLE_PIN:-}"
  if [ -n "$PIN" ]; then
    [[ "$PIN" =~ ^[0-9]{4,8}$ ]] || die "LALGG_CONSOLE_PIN must be 4-8 digits"
  elif { : </dev/tty; } 2>/dev/null; then
    # interactive: ask on the controlling terminal, not stdin (may be a pipe)
    if [ -z "${LALGG_MANAGE_URL:-}" ]; then
      read -r -p "Management URL [$DEFAULT_MANAGE_URL]: " MANAGE_URL </dev/tty
      MANAGE_URL="${MANAGE_URL:-$DEFAULT_MANAGE_URL}"
    fi
    while :; do
      read -r -s -p "Console PIN (4-8 digits): " PIN </dev/tty; echo
      [[ "$PIN" =~ ^[0-9]{4,8}$ ]] && break
      echo "PIN must be 4-8 digits."
    done
  else
    die "no terminal and LALGG_CONSOLE_PIN not set: cannot ask for the console PIN"
  fi
  case "$MANAGE_URL" in
    https://*) ;;
    *) die "management URL must start with https:// (got: $MANAGE_URL)" ;;
  esac
  PIN_HASH="$(printf '%s' "$PIN" | sha256sum | cut -d' ' -f1)"
  sed -e "s|^MANAGE_URL=.*|MANAGE_URL=$MANAGE_URL|" \
      -e "s|^CONSOLE_PIN_SHA256=.*|CONSOLE_PIN_SHA256=$PIN_HASH|" \
      "$REPO_DIR/config/lalgg-beamer.env.example" > "$CONF"
  chmod 0600 "$CONF"
else
  log "keeping existing $CONF"
fi

# ---------------------------------------------------------------------------
# 5. autologin on tty1, PIN console on tty2, nothing on the rest
# ---------------------------------------------------------------------------
log "configuring ttys"
install -d /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $KIOSK_USER --noclear %I \$TERM
EOF

cat > /etc/systemd/system/lalgg-console.service <<EOF
[Unit]
Description=lal.gg beamer local console (PIN protected)
After=systemd-user-sessions.service
Conflicts=getty@tty2.service

[Service]
ExecStart=$LIB_DIR/lalgg-console.sh
StandardInput=tty
StandardOutput=tty
TTYPath=/dev/tty2
TTYReset=yes
TTYVHangup=yes
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF

# logind: only tty1+tty2, no spare login prompts
install -d /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/lalgg.conf <<'EOF'
[Login]
NAutoVTs=2
ReserveVT=2
EOF
systemctl disable getty@tty2.service >/dev/null 2>&1 || true
for n in 3 4 5 6; do systemctl mask "getty@tty$n.service" >/dev/null 2>&1 || true; done

# no console blanking, quiet boot
if [ -f /etc/default/grub ] && ! grep -q consoleblank /etc/default/grub; then
  # Debian already ships "quiet"; only add what is missing
  extra="consoleblank=0"
  grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=.*\bquiet\b' /etc/default/grub || extra="$extra quiet"
  sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1 $extra\"/" /etc/default/grub
  update-grub >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# 6. services
# ---------------------------------------------------------------------------
systemctl daemon-reload
systemctl enable lalgg-agent.service lalgg-console.service >/dev/null
systemctl restart lalgg-agent.service lalgg-console.service

log "done. Reboot to start the kiosk. Pairing code and hardware info: curl -s http://127.0.0.1:8484/info"
