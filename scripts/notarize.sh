#!/usr/bin/env bash
set -euo pipefail

APP_NAME="LagunaWave"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/${APP_NAME}.app"
ZIP_PATH="$BUILD_DIR/${APP_NAME}.zip"

if [ -z "${CODESIGN_IDENTITY:-}" ]; then
  echo "CODESIGN_IDENTITY not set. Example:" >&2
  echo "  export CODESIGN_IDENTITY=\"Developer ID Application: Your Name (TEAMID)\"" >&2
  exit 1
fi

"$ROOT_DIR/scripts/build.sh"

# Stage to a temp directory for zipping and submission to avoid
# file-provider extended attributes contaminating the zip.
STAGE_DIR=$(mktemp -d)
STAGE_APP="$STAGE_DIR/${APP_NAME}.app"
trap 'rm -rf "$STAGE_DIR"' EXIT
ditto "$APP_DIR" "$STAGE_APP"
xattr -cr "$STAGE_APP"

sign_metallibs() {
  local signer="$1"
  shopt -s nullglob
  local libs=("$STAGE_APP/Contents/MacOS"/*.metallib)
  shopt -u nullglob
  if [ ${#libs[@]} -gt 0 ]; then
    for lib in "${libs[@]}"; do
      codesign --force --sign "$signer" "$lib"
    done
  fi
}

sign_metallibs "$CODESIGN_IDENTITY"

codesign --verify --deep --strict "$STAGE_APP"

rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$STAGE_APP" "$ZIP_PATH"

if [ -n "${NOTARYTOOL_PROFILE:-}" ]; then
  xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
else
  if [ -z "${APPLE_ID:-}" ] || [ -z "${APPLE_ID_PASSWORD:-}" ] || [ -z "${TEAM_ID:-}" ]; then
    echo "Set NOTARYTOOL_PROFILE or APPLE_ID, APPLE_ID_PASSWORD, TEAM_ID" >&2
    exit 1
  fi
  xcrun notarytool submit "$ZIP_PATH" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_ID_PASSWORD" \
    --team-id "$TEAM_ID" \
    --wait
fi

xcrun stapler staple "$STAGE_APP"
xcrun stapler validate "$STAGE_APP" || true

# Copy stapled app back to build directory
rm -rf "$APP_DIR"
ditto "$STAGE_APP" "$APP_DIR"

echo "Notarized and stapled: $APP_DIR"
echo "Notarized zip: $ZIP_PATH"
