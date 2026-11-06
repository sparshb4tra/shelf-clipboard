#!/bin/zsh
# Builds Shelf.app from main.swift and installs it to /Applications.
#
#   ./build.sh                          build, install, relaunch
#   SHELF_SKIP_INSTALL=1 ./build.sh     build only (CI, or just trying it out)
#   SHELF_SIGN_IDENTITY=... ./build.sh  sign with a specific identity
#
# Signing note: macOS ties the Accessibility grant to the app's code identity. A stable
# certificate (any self-signed cert in your login keychain, or a Developer ID) keeps that
# grant across rebuilds. Ad-hoc signing changes the identity every build, so macOS
# silently revokes the grant and asks again on each launch.
set -e
cd "$(dirname "$0")"

APP_NAME="Shelf"
BUNDLE="${APP_NAME}.app"

command -v swiftc >/dev/null 2>&1 || {
  echo "swiftc not found. install the xcode command line tools: xcode-select --install" >&2
  exit 1
}

echo "compiling"
swiftc -O main.swift -o "${APP_NAME}" -framework AppKit -framework Carbon

rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"
cp "${APP_NAME}" "${BUNDLE}/Contents/MacOS/${APP_NAME}"
cp Info.plist "${BUNDLE}/Contents/Info.plist"

IDENTITY="${SHELF_SIGN_IDENTITY:-}"
if [ -z "${IDENTITY}" ]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
  elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Local Self-Signed"; then
    IDENTITY="Local Self-Signed"
  fi
fi

if [ -n "${IDENTITY}" ]; then
  echo "signing with ${IDENTITY}"
  codesign --force --deep --sign "${IDENTITY}" "${BUNDLE}" >/dev/null 2>&1
else
  echo "no certificate found, signing ad-hoc. accessibility has to be re-granted after each rebuild."
  codesign --force --deep --sign - "${BUNDLE}" >/dev/null 2>&1
fi

if [ "${SHELF_SKIP_INSTALL:-0}" = "1" ]; then
  echo "built ${BUNDLE} (not installed)"
  exit 0
fi

pkill -f "${APP_NAME}.app/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
sleep 0.5
rm -rf "/Applications/${BUNDLE}"
cp -R "${BUNDLE}" "/Applications/${BUNDLE}"
xattr -dr com.apple.quarantine "/Applications/${BUNDLE}" 2>/dev/null || true
open "/Applications/${BUNDLE}"
echo "installed /Applications/${BUNDLE}"
