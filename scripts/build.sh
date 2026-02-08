#!/usr/bin/env bash
set -euo pipefail

# --- Prerequisites ---
if ! xcode-select -p &>/dev/null; then
  echo "Error: Xcode Command Line Tools not installed." >&2
  echo "  Install with: xcode-select --install" >&2
  exit 1
fi

if ! xcrun -sdk macosx metal --version &>/dev/null; then
  echo "Error: Metal Toolchain not installed (required by MLX at runtime)." >&2
  echo "  Install with: xcodebuild -downloadComponent MetalToolchain" >&2
  echo "  Or run: scripts/setup.sh" >&2
  exit 1
fi

APP_NAME="LagunaWave"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/${APP_NAME}.app"
BIN_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"
PLIST="$ROOT_DIR/Resources/Info.plist"
ENTITLEMENTS="$ROOT_DIR/Resources/Entitlements.plist"
BIN_SRC="$ROOT_DIR/.build/release/$APP_NAME"

swift build -c release

if [ ! -f "$BIN_SRC" ]; then
  echo "Build output not found: $BIN_SRC" >&2
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$BIN_DIR" "$RES_DIR"

cp "$BIN_SRC" "$BIN_DIR/$APP_NAME"

# Compile MLX Metal shaders into metallib (swift build doesn't do this).
# This is an optimization — MLX can JIT-compile shaders at runtime if the
# metallib is missing, so failures here are non-fatal.
MLX_METAL="$ROOT_DIR/.build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"
if [ -d "$MLX_METAL" ]; then
  echo "Compiling Metal shaders..."
  AIR_DIR=$(mktemp -d)
  SHADER_FAILED=0
  for f in "$MLX_METAL"/*.metal "$MLX_METAL"/steel/attn/kernels/*.metal; do
    [ -f "$f" ] || continue
    base=$(basename "$f" .metal)
    if ! xcrun -sdk macosx metal -w -c "$f" -I "$MLX_METAL" -o "$AIR_DIR/$base.air" 2>&1; then
      echo "  warning: failed to compile $base.metal"
      SHADER_FAILED=1
    fi
  done
  if [ "$SHADER_FAILED" -eq 0 ] && ls "$AIR_DIR"/*.air >/dev/null 2>&1; then
    xcrun metal-ar r "$AIR_DIR/default.metalar" "$AIR_DIR"/*.air 2>/dev/null \
      && xcrun -sdk macosx metallib "$AIR_DIR/default.metalar" -o "$BIN_DIR/mlx.metallib" 2>&1 \
      && echo "Metal shaders compiled" \
      || echo "warning: Metal shader linking failed — MLX will JIT-compile at runtime"
  else
    echo "warning: Metal shader compilation failed — MLX will JIT-compile at runtime"
  fi
  rm -rf "$AIR_DIR"
fi

cp "$PLIST" "$APP_DIR/Contents/Info.plist"

if [ -f "$ROOT_DIR/Resources/AppIcon.icns" ]; then
  cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# Stage to a temp directory for signing to avoid file-provider extended
# attribute contamination (iCloud Drive, Dropbox, etc. re-add xattrs
# immediately, which breaks codesign).
STAGE_DIR=$(mktemp -d)
STAGE_APP="$STAGE_DIR/${APP_NAME}.app"
trap 'rm -rf "$STAGE_DIR"' EXIT
ditto "$APP_DIR" "$STAGE_APP"
xattr -cr "$STAGE_APP"

if [ -z "${CODESIGN_IDENTITY:-}" ]; then
  echo "Signing: ad-hoc"
  codesign --force --deep --sign - "$STAGE_APP"
else
  echo "Signing: $CODESIGN_IDENTITY"
  if [ -f "$ENTITLEMENTS" ]; then
    codesign --force --deep --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$CODESIGN_IDENTITY" "$STAGE_APP"
  else
    codesign --force --deep --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$STAGE_APP"
  fi
fi

codesign --verify --deep --strict "$STAGE_APP"
echo "Signature verified"

rm -rf "$APP_DIR"
ditto "$STAGE_APP" "$APP_DIR"

echo "Built $APP_DIR"
