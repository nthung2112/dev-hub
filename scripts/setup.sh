#!/usr/bin/env bash
# One-time setup for Dev Hub: check the toolchain, build, and run the tests.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! xcrun --find swift >/dev/null 2>&1; then
  echo "Xcode or the Xcode Command Line Tools are required. Install with: xcode-select --install" >&2
  exit 1
fi

echo "Building Dev Hub..."
xcrun swift build -c release --product DevHub

echo "Running tests..."
xcrun swift test

echo "Done. Install the app with: ./scripts/build-app.sh --install"
