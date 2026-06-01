#!/usr/bin/env bash
set -euo pipefail

# Build Squirrel.app (menu bar app), squirrel-hook (UserPromptSubmit hook target),
# and squirrel-mcp (MCP server). This script just builds and stages binaries —
# for end-to-end setup (symlinks, Claude Code registration, hook install,
# /stash command), run ./install.sh from the repo root.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="${CONFIG:-release}"
APP_NAME="Squirrel"
APP_DIR="build/${APP_NAME}.app"

echo "==> swift build (${CONFIG})"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
# Three distinct product names so the binaries don't collide on case-insensitive
# filesystems (APFS/HFS+). The bundled app binary is renamed to `Squirrel` on copy
# below to match Info.plist's CFBundleExecutable.
APP_BIN="${BIN_DIR}/SquirrelMenuBar"
HOOK_BIN="${BIN_DIR}/squirrel-hook"
MCP_BIN="${BIN_DIR}/squirrel-mcp"

for bin in "$APP_BIN" "$HOOK_BIN" "$MCP_BIN"; do
    if [[ ! -f "$bin" ]]; then
        echo "build failed: $bin not found" >&2
        exit 1
    fi
done

echo "==> assembling ${APP_DIR}"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$APP_BIN" "$APP_DIR/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"

if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc sign so the OS will grant TCC prompts to this bundle. Hardened runtime
# requires the audio-input and apple-events entitlements to be declared, or the
# mic permission flow silently fails and the app never appears in System
# Settings ▸ Privacy & Security ▸ Microphone.
echo "==> ad-hoc signing"
codesign --force --sign - --deep --options runtime \
    --entitlements Resources/Squirrel.entitlements "$APP_DIR"

# Stage hook + MCP binaries alongside the app for easy symlinking.
mkdir -p build/bin
cp "$HOOK_BIN" build/bin/squirrel-hook
cp "$MCP_BIN" build/bin/squirrel-mcp

# Re-sign the standalone copies with a plain ad-hoc signature. SwiftPM emits
# release binaries with a "linker-signed" ad-hoc signature (codesign flag
# 0x20002) that the kernel SIGKILLs at exec once the binary is copied out of
# the build dir — Claude Code then reports "Failed to reconnect: -32000". A
# forced re-sign replaces it with a normal ad-hoc signature that runs.
echo "==> re-signing build/bin binaries"
codesign --force --sign - build/bin/squirrel-hook
codesign --force --sign - build/bin/squirrel-mcp

echo "==> built:"
echo "   ${APP_DIR}"
echo "   build/bin/squirrel-hook  (UserPromptSubmit hook target)"
echo "   build/bin/squirrel-mcp   (MCP server)"
echo ""
echo "For full setup (symlinks + Claude Code registration + hook + /stash), run:"
echo "   ./install.sh"
