#!/usr/bin/env bash
set -Eeuo pipefail

STATE_DIR="$HOME/.ubuntu24-github"
PID_FILE="$STATE_DIR/server.pid"
LOG_FILE="$STATE_DIR/logs/server.log"

mkdir -p "$STATE_DIR/logs"

if [[ -f "$PID_FILE" ]]; then
  PID="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
    exit 0
  fi
fi

nohup bash .devcontainer/start.sh >"$LOG_FILE" 2>&1 &
echo "$!" > "$PID_FILE"
