#!/usr/bin/env bash
# Builds the macOS app in release mode and installs it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"
REPO="$(cd .. && pwd)"

if [ ! -d "$REPO/engine/node_modules" ]; then
  echo "engine sem dependências — rode: cd $REPO/engine && npm ci" >&2
  exit 1
fi

flutter build macos --release
APP="build/macos/Build/Products/Release/claude_flow.app"

if pgrep -f "/Applications/claude_flow.app/Contents/MacOS/claude_flow" >/dev/null; then
  osascript -e 'tell application "claude_flow" to quit' || true
  for _ in $(seq 1 20); do
    pgrep -f "/Applications/claude_flow.app/Contents/MacOS/claude_flow" >/dev/null || break
    sleep 0.25
  done
fi

rm -rf /Applications/claude_flow.app
cp -R "$APP" /Applications/
open /Applications/claude_flow.app
echo "instalado: /Applications/claude_flow.app"
