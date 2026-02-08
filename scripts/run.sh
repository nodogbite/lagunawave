#!/usr/bin/env bash
set -euo pipefail

BUNDLE_ID="com.nodogbite.lagunawave"
APP_NAME="LagunaWave"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Quit existing instance if running
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  echo "Quitting running $APP_NAME..."
  osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || killall "$APP_NAME" 2>/dev/null || true
  sleep 1
fi

"$ROOT_DIR/scripts/build.sh"

# Reset privacy permissions so ad-hoc signed dev builds get fresh prompts
# (not needed for production Developer ID builds where the identity is stable)
tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || true
tccutil reset Microphone "$BUNDLE_ID" 2>/dev/null || true

open "$ROOT_DIR/build/LagunaWave.app"
