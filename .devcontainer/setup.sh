#!/usr/bin/env bash
set -Eeuo pipefail

mkdir -p "$HOME/.ubuntu24-github/logs" "$HOME/.ubuntu24-github/runtime" "$HOME/.ubuntu24-github/vnc" "$HOME/.ubuntu24-github/nginx"
chmod 700 "$HOME/.ubuntu24-github/runtime" "$HOME/.ubuntu24-github/vnc"
chmod +x start.sh .devcontainer/launch.sh .devcontainer/start.sh
