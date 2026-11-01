#!/usr/bin/env bash
# Renders the showcase images from the app itself, offscreen. No window, no clicking.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/showcase"
mkdir -p "$OUT"

cd "$ROOT"
xcrun swift build -c release --product DevHub
BIN="$(xcrun swift build -c release --product DevHub --show-bin-path)/DevHub"

"$BIN" --render "$OUT/panel.png" utilities
"$BIN" --render "$OUT/panel-dark.png" utilities --dark
"$BIN" --render "$OUT/settings-mac.png" utilities --settings
"$BIN" --render "$OUT/settings-general.png" --settings

echo "Rendered showcase images into $OUT"
