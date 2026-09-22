#!/usr/bin/env bash
# Self-update from GitHub Releases. Triggered by the "update" command from lal.gg or
# from the local console. Expects each release to carry
#   lalgg-beamer-client-<tag>.tar.gz   and   lalgg-beamer-client-<tag>.tar.gz.sha256
# (built by .github/workflows/release.yml - to be added with v0.2).
set -euo pipefail
CONF=/etc/lalgg-beamer/config.env
LIB_DIR=/usr/local/lib/lalgg-beamer
[ -r "$CONF" ] && . "$CONF"
REPO="${UPDATE_REPO:-sven-g-nadler/lalgg-beamer-client}"
API="https://api.github.com/repos/$REPO/releases/latest"

current="$(cat "$LIB_DIR/VERSION" 2>/dev/null || echo dev)"
tag="$(curl -fsSL "$API" | jq -r .tag_name)"
[ -n "$tag" ] && [ "$tag" != "null" ] || { echo "no release found for $REPO"; exit 1; }
if [ "$tag" = "$current" ]; then echo "already on $tag"; exit 0; fi

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
base="https://github.com/$REPO/releases/download/$tag/lalgg-beamer-client-$tag.tar.gz"
echo "downloading $tag"
curl -fsSL -o "$work/pkg.tar.gz" "$base"
curl -fsSL -o "$work/pkg.sha256" "$base.sha256"
( cd "$work" && sed 's# .*#  pkg.tar.gz#' pkg.sha256 | sha256sum -c - ) || { echo "checksum mismatch, aborting"; exit 1; }

mkdir -p "$work/src" && tar -xzf "$work/pkg.tar.gz" -C "$work/src" --strip-components=1
# the installer is idempotent and keeps config.env
"$work/src/install/install.sh"
echo "$tag" > "$LIB_DIR/VERSION"
echo "updated $current -> $tag"
pkill -u kiosk cage 2>/dev/null || true
