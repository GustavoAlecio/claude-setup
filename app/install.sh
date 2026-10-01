#!/usr/bin/env bash
# Builds the macOS app in release mode and installs it to /Applications.
# Quitting the app stops its engine and every session on it, so it refuses while a session is running or waiting
# for permission; `--force` installs anyway. Sourcing the file only defines the functions.
set -euo pipefail

APP_PROCESS="/Applications/claude_flow.app/Contents/MacOS/claude_flow"

# Prints "id<TAB>status<TAB>project<TAB>command" for sessions in running or waiting_permission. Fails when the engine
# cannot be reached: no engine.pid, no listening port for that pid, or no answer from /api/sessions.
active_sessions() {
  local pidfile="${WORKFLOW_ROOT:-$HOME/.claude/workflow}/.dashboard/engine-sessions/engine.pid"
  [ -f "$pidfile" ] || return 1
  local pid port
  pid=$(tr -d '[:space:]' <"$pidfile")
  [ -n "$pid" ] || return 1
  port=$(lsof -nP -a -p "$pid" -iTCP -sTCP:LISTEN -Fn 2>/dev/null | sed -n 's/^n.*:\([0-9][0-9]*\)$/\1/p' | head -n 1 || true)
  [ -n "$port" ] || return 1
  curl -fsS --max-time 3 "http://127.0.0.1:$port/api/sessions" | python3 -c '
import json, sys
for s in json.load(sys.stdin):
    if s.get("status") in ("running", "waiting_permission"):
        print("\t".join(str(s.get(k) or "") for k in ("id", "status", "project", "command")))
'
}

# Exit status 1 with the list when a session would be killed; an unreachable engine only warns.
guard_sessions() {
  [ "${1:-}" = "--force" ] && return 0
  local list
  if ! list=$(active_sessions); then
    echo "aviso: engine inacessível; seguindo sem checar sessões ativas" >&2
    return 0
  fi
  [ -z "$list" ] && return 0
  echo "sessões ativas no engine (fechar o app interrompe todas; use --force para instalar mesmo assim):" >&2
  printf '%s\n' "$list" >&2
  return 1
}

main() {
  local force=""
  for arg in "$@"; do
    case "$arg" in
      --force) force="--force" ;;
      *) echo "uso: install.sh [--force]" >&2; exit 2 ;;
    esac
  done
  cd "$(dirname "${BASH_SOURCE[0]}")"
  local repo
  repo="$(cd .. && pwd)"

  if [ ! -d "$repo/engine/node_modules" ]; then
    echo "engine sem dependências — rode: cd $repo/engine && npm ci" >&2
    exit 1
  fi

  # Before the build so a refusal costs nothing; a session started during the build is not caught.
  guard_sessions ${force:+"$force"} || exit 1

  flutter build macos --release
  local app="build/macos/Build/Products/Release/claude_flow.app"

  if pgrep -f "$APP_PROCESS" >/dev/null; then
    osascript -e 'tell application "claude_flow" to quit' || true
    for _ in $(seq 1 20); do
      pgrep -f "$APP_PROCESS" >/dev/null || break
      sleep 0.25
    done
  fi

  rm -rf /Applications/claude_flow.app
  cp -R "$app" /Applications/
  open /Applications/claude_flow.app
  echo "instalado: /Applications/claude_flow.app"
}

# `return` only succeeds when the file is sourced.
(return 0 2>/dev/null) || main "$@"
