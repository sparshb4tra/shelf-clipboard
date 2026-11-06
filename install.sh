#!/bin/bash
# Shelf installer. Downloads the latest release, installs it to /Applications and clears the
# quarantine flag so a self-signed build opens without the Gatekeeper dance.
#
#   curl -fsSL https://raw.githubusercontent.com/sparshb4tra/shelf-clipboard/main/install.sh | bash
set -euo pipefail

REPO="sparshb4tra/shelf-clipboard"
APP="Shelf.app"
DEST="/Applications/${APP}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "→ downloading the latest Shelf release"
URL="https://github.com/${REPO}/releases/latest/download/Shelf.zip"
curl -fsSL "$URL" -o "$TMP/Shelf.zip" || {
  echo "download failed. grab it manually from https://github.com/${REPO}/releases/latest" >&2
  exit 1
}

echo "→ unzipping"
ditto -x -k "$TMP/Shelf.zip" "$TMP"

[ -d "$TMP/$APP" ] || { echo "Shelf.app missing from the archive" >&2; exit 1; }

echo "→ installing to /Applications"
pkill -f "${APP}/Contents/MacOS/Shelf" 2>/dev/null || true
sleep 0.4
rm -rf "$DEST"
mv "$TMP/$APP" "$DEST"

echo "→ clearing the quarantine flag"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "→ launching"
open "$DEST"

cat <<'DONE'

Shelf is installed.

One more step: press option-V, pick a clip, hit return. macOS will ask for
Accessibility the first time — that permission is what lets Shelf paste back
into the app you came from. Enable it in System Settings → Privacy & Security →
Accessibility.

Menu bar icon: position (bottom / left / right / floating window), clear
history, launch at login.
DONE
