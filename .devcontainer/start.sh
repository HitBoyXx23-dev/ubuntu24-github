#!/usr/bin/env bash
set -Eeuo pipefail

PUBLIC_PORT="${PORT:-3000}"
DISPLAY_NUM="${DISPLAY_NUM:-7}"
DISPLAY=":${DISPLAY_NUM}"
VNC_PORT="$((5900 + DISPLAY_NUM))"
NOVNC_PORT="${NOVNC_PORT:-6080}"
TERMINAL_PORT="${TERMINAL_PORT:-7681}"
SCREEN_SIZE="${SCREEN_SIZE:-1368x768x24}"
TERMINAL_USER="${TERMINAL_USER:-user}"
TERMINAL_PASSWORD="${TERMINAL_PASSWORD:-1234}"
DESKTOP_PASSWORD="${DESKTOP_PASSWORD:-1234}"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$HOME/.ubuntu24-github"
RUN_DIR="$STATE_DIR/run"
LOG_DIR="$STATE_DIR/logs"
VNC_DIR="$STATE_DIR/vnc"
NGINX_DIR="$STATE_DIR/nginx"
NGINX_CONF="$NGINX_DIR/nginx.conf"
NGINX_PID="$RUN_DIR/nginx.pid"

export DISPLAY
export XDG_RUNTIME_DIR="$RUN_DIR"

mkdir -p "$RUN_DIR" "$LOG_DIR" "$VNC_DIR" "$NGINX_DIR"
chmod 700 "$RUN_DIR" "$VNC_DIR"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  }
}

for command_name in Xvfb fluxbox x11vnc websockify ttyd nginx xterm xdpyinfo; do
  need "$command_name"
done

NOVNC_DIR=""
for candidate in /usr/share/novnc /usr/share/noVNC /opt/novnc; do
  if [[ -f "$candidate/vnc.html" ]]; then
    NOVNC_DIR="$candidate"
    break
  fi
done

if [[ -z "$NOVNC_DIR" ]]; then
  printf 'noVNC files were not found. Rebuild the Codespace container.\n' >&2
  exit 1
fi

stop_pid_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    local pid
    pid="$(cat "$file" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      sleep 1
    fi
    rm -f "$file"
  fi
}

for pid_file in "$RUN_DIR"/*.pid; do
  [[ -e "$pid_file" ]] || continue
  stop_pid_file "$pid_file"
done

rm -f "/tmp/.X${DISPLAY_NUM}-lock" "/tmp/.X11-unix/X${DISPLAY_NUM}" 2>/dev/null || true

x11vnc -storepasswd "$DESKTOP_PASSWORD" "$VNC_DIR/passwd" >/dev/null
chmod 600 "$VNC_DIR/passwd"

Xvfb "$DISPLAY" -screen 0 "$SCREEN_SIZE" -ac -nolisten tcp >"$LOG_DIR/xvfb.log" 2>&1 &
echo "$!" >"$RUN_DIR/xvfb.pid"

for _ in $(seq 1 100); do
  xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 && break
  sleep 0.1
done

if ! xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
  printf 'Xvfb failed to start.\n' >&2
  exit 1
fi

fluxbox >"$LOG_DIR/fluxbox.log" 2>&1 &
echo "$!" >"$RUN_DIR/fluxbox.pid"

xterm -geometry 110x30+60+60 -title "Ubuntu 24.04" >"$LOG_DIR/xterm.log" 2>&1 &
echo "$!" >"$RUN_DIR/xterm.pid"

x11vnc -display "$DISPLAY" -rfbport "$VNC_PORT" -rfbauth "$VNC_DIR/passwd" -forever -shared -repeat -noxdamage -xkb >"$LOG_DIR/x11vnc.log" 2>&1 &
echo "$!" >"$RUN_DIR/x11vnc.pid"

websockify --web "$NOVNC_DIR" "$NOVNC_PORT" "127.0.0.1:$VNC_PORT" >"$LOG_DIR/websockify.log" 2>&1 &
echo "$!" >"$RUN_DIR/websockify.pid"

ttyd --port "$TERMINAL_PORT" --interface 127.0.0.1 --base-path /terminal --credential "$TERMINAL_USER:$TERMINAL_PASSWORD" --writable bash >"$LOG_DIR/ttyd.log" 2>&1 &
echo "$!" >"$RUN_DIR/ttyd.pid"

cat >"$NGINX_CONF" <<EOF
pid $NGINX_PID;
error_log $LOG_DIR/nginx-error.log notice;

events {
  worker_connections 256;
}

http {
  access_log $LOG_DIR/nginx-access.log;
  include /etc/nginx/mime.types;
  default_type application/octet-stream;
  sendfile on;

  map \$http_upgrade \$connection_upgrade {
    default upgrade;
    '' close;
  }

  server {
    listen 0.0.0.0:$PUBLIC_PORT;
    server_name _;

    root $PROJECT_DIR/web;
    index index.html;

    location = / {
      try_files /index.html =404;
    }

    location = /desktop {
      return 302 /desktop/;
    }

    location /desktop/websockify {
      proxy_pass http://127.0.0.1:$NOVNC_PORT;
      proxy_http_version 1.1;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection \$connection_upgrade;
      proxy_set_header Host \$host;
      proxy_read_timeout 86400;
      proxy_send_timeout 86400;
    }

    location /desktop/ {
      alias $NOVNC_DIR/;
    }

    location = /terminal {
      return 302 /terminal/;
    }

    location /terminal/ {
      proxy_pass http://127.0.0.1:$TERMINAL_PORT;
      proxy_http_version 1.1;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection \$connection_upgrade;
      proxy_set_header Host \$host;
      proxy_set_header X-Real-IP \$remote_addr;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto \$scheme;
      proxy_read_timeout 86400;
      proxy_send_timeout 86400;
    }

    location = /health {
      access_log off;
      default_type text/plain;
      return 200 'ok';
    }
  }
}
EOF

nginx -t -p "$STATE_DIR/" -c "$NGINX_CONF"
nginx -p "$STATE_DIR/" -c "$NGINX_CONF"

printf 'Ubuntu 24.04 workspace is running on port %s\n' "$PUBLIC_PORT"
printf 'Desktop: /desktop/vnc.html?autoconnect=true&resize=scale&path=websockify\n'
printf 'Terminal: /terminal/\n'

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  for pid_file in "$RUN_DIR"/*.pid; do
    [[ -e "$pid_file" ]] || continue
    stop_pid_file "$pid_file"
  done
  exit "$status"
}

trap cleanup EXIT INT TERM

while true; do
  sleep 3600
done
