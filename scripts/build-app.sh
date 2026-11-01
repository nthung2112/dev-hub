#!/usr/bin/env bash
# Builds DevHub.app into ./build. Pass --install to copy it to ~/Applications.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/DevHub.app"

cd "$ROOT"
xcrun swift build -c release --product DevHub
BIN="$(xcrun swift build -c release --product DevHub --show-bin-path)/DevHub"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DevHub"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Deliberately not re-signed with `codesign`: an explicit ad-hoc bundle signature was blocked on
# managed Macs, while apps that keep only the linker's signature on the binary run.
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST="$HOME/Applications/DevHub.app"
  mkdir -p "$HOME/Applications"
  pkill -x DevHub 2>/dev/null || true
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  echo "Installed $DEST (open it with: open \"$DEST\")"
fi
