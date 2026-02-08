#!/usr/bin/env bash
set -euo pipefail

echo "LagunaWave — Development Environment Setup"
echo "============================================"
echo ""

ALL_GOOD=true

# --- Xcode Command Line Tools ---
if xcode-select -p &>/dev/null; then
  echo "[ok] Xcode Command Line Tools"
else
  ALL_GOOD=false
  echo "[missing] Xcode Command Line Tools"
  read -p "  Install now? [y/N] " response
  if [[ "$response" =~ ^[Yy]$ ]]; then
    xcode-select --install
    echo "  Xcode CLT installer launched — re-run this script when it finishes."
    exit 0
  else
    echo "  Skipped. Install manually with: xcode-select --install"
  fi
fi

# --- Metal Toolchain (required by MLX at runtime) ---
if xcrun -sdk macosx metal --version &>/dev/null; then
  echo "[ok] Metal Toolchain"
else
  ALL_GOOD=false
  echo "[missing] Metal Toolchain (required by MLX for on-device inference)"
  read -p "  Install now? [y/N] " response
  if [[ "$response" =~ ^[Yy]$ ]]; then
    echo "  Downloading Metal Toolchain (this may take a minute)..."
    xcodebuild -downloadComponent MetalToolchain
    if xcrun -sdk macosx metal --version &>/dev/null; then
      echo "  [ok] Metal Toolchain installed"
    else
      echo "  [error] Installation may have failed — check and retry manually:"
      echo "    xcodebuild -downloadComponent MetalToolchain"
    fi
  else
    echo "  Skipped. Install manually with: xcodebuild -downloadComponent MetalToolchain"
  fi
fi

# --- Swift compiler ---
if command -v swift &>/dev/null; then
  SWIFT_VERSION=$(swift --version 2>&1 | head -1)
  echo "[ok] Swift ($SWIFT_VERSION)"
else
  ALL_GOOD=false
  echo "[missing] Swift compiler — install Xcode or Xcode Command Line Tools"
fi

echo ""
if [ "$ALL_GOOD" = true ]; then
  echo "All prerequisites met. You're ready to build:"
  echo "  ./scripts/build.sh    # Build release .app bundle"
  echo "  ./scripts/run.sh      # Build + launch (for development)"
else
  echo "Some prerequisites are missing — see above for install instructions."
fi
