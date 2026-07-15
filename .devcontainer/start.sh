#!/usr/bin/env bash
set -Eeuo pipefail

PUBLIC_PORT="${PORT:-3000}"
DISPLAY_NUM="${DISPLAY_NUM:-7}"
DISPLAY=":${DISPLAY_NUM}"
VNC_PORT="$((5900 + DISPLAY_NUM))"
NOVNC_PORT="${NOVNC_PORT:-6080}"
TTYD_PORT="${TTYD_PORT:-7681}"
SCREEN_SIZE="${SCREEN_SIZE:-1368x768x24}"
TERMINAL_USER="${TERMINAL_USER:-user}"
TERMINAL_PASSWORD="${TERMINAL_PASSWORD:-1234}"
DESKTOP_PASSWORD="${DESKTOP_PASSWORD:-1234}"
STATE_DIR="$HOME/.ubuntu24-github"
LOG_DIR="$STATE_DIR/logs"
RUNTIME_DIR="$STATE_DIR/runtime"
VNC_DIR="$STATE_DIR/vnc"
NGINX_DIR="$STATE_DIR/nginx"
NGINX_CONFIG="$NGINX_DIR/nginx.conf"
VNC_PASSWORD_FILE="$VNC_DIR/passwd"
WORKSPACE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export DISPLAY
export XDG_RUNTIME_DIR="$RUNTIME_DIR"

mkdir -p "$LOG_DIR" "$RUNTIME_DIR" "$VNC_DIR" "$NGINX_DIR/client_body_temp" "$NGINX_DIR/proxy_temp" "$NGINX_DIR/fastcgi_temp" "$NGINX_DIR/uwsgi_temp" "$NGINX_DIR/scgi_temp"
chmod 700 "$RUNTIME_DIR" "$VNC_DIR"

for command_name in Xvfb xdpyinfo fluxbox xterm x11vnc websockify ttyd nginx; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'Missing dependency: %s\n' "$command_name" >&2
    printf 'Rebuild the Codespace container from the Command Palette.\n' >&2
    exit 1
  }
done

PIDS=()

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  for pid in "${PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  exit "$status"
}

trap cleanup EXIT INT TERM

pkill -f "Xvfb :${DISPLAY_NUM}" 2>/dev/null || true
pkill -f "x11vnc.*${VNC_PORT}" 2>/dev/null || true
pkill -f "websockify.*${NOVNC_PORT}" 2>/dev/null || true
pkill -f "ttyd.*${TTYD_PORT}" 2>/dev/null || true
pkill -f "nginx.*${NGINX_CONFIG}" 2>/dev/null || true
pkill -f fluxbox 2>/dev/null || true
pkill -f xterm 2>/dev/null || true
rm -f "/tmp/.X${DISPLAY_NUM}-lock" "/tmp/.X11-unix/X${DISPLAY_NUM}" "$STATE_DIR/nginx.pid" 2>/dev/null || true

x11vnc -storepasswd "$DESKTOP_PASSWORD" "$VNC_PASSWORD_FILE" >/dev/null
chmod 600 "$VNC_PASSWORD_FILE"

cat > "$NGINX_CONFIG" <<EOF2
pid $STATE_DIR/nginx.pid;
error_log $LOG_DIR/nginx-error.log;

events {
  worker_connections 512;
}

http {
  access_log $LOG_DIR/nginx-access.log;
  include /etc/nginx/mime.types;
  default_type application/octet-stream;
  client_body_temp_path $NGINX_DIR/client_body_temp;
  proxy_temp_path $NGINX_DIR/proxy_temp;
  fastcgi_temp_path $NGINX_DIR/fastcgi_temp;
  uwsgi_temp_path $NGINX_DIR/uwsgi_temp;
  scgi_temp_path $NGINX_DIR/scgi_temp;

  map \$http_upgrade \$connection_upgrade {
    default upgrade;
    '' close;
  }

  server {
    listen 0.0.0.0:$PUBLIC_PORT;
    server_name _;
    root $WORKSPACE_DIR/web;
    index index.html;

    location = /health {
      default_type text/plain;
      return 200 'ok';
    }

    location = / {
      try_files /index.html =404;
    }

    location /desktop/ {
      alias /usr/share/novnc/;
      try_files \$uri \$uri/ /desktop/vnc.html;
    }

    location /websockify {
      proxy_pass http://127.0.0.1:$NOVNC_PORT;
      proxy_http_version 1.1;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection \$connection_upgrade;
      proxy_set_header Host \$host;
      proxy_read_timeout 86400;
    }

    location /terminal/ {
      proxy_pass http://127.0.0.1:$TTYD_PORT;
      proxy_http_version 1.1;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection \$connection_upgrade;
      proxy_set_header Host \$host;
      proxy_read_timeout 86400;
    }
  }
}
EOF2

Xvfb "$DISPLAY" -screen 0 "$SCREEN_SIZE" -ac -nolisten tcp >"$LOG_DIR/xvfb.log" 2>&1 &
PIDS+=("$!")

for _ in $(seq 1 100); do
  xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 && break
  sleep 0.1
done

xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 || {
  printf 'Xvfb failed to start. Check %s\n' "$LOG_DIR/xvfb.log" >&2
  exit 1
}

fluxbox >"$LOG_DIR/fluxbox.log" 2>&1 &
PIDS+=("$!")

xterm -geometry 110x32+40+40 -title "Ubuntu 24.04" -e bash >"$LOG_DIR/xterm.log" 2>&1 &
PIDS+=("$!")

x11vnc -display "$DISPLAY" -rfbport "$VNC_PORT" -rfbauth "$VNC_PASSWORD_FILE" -forever -shared -localhost -noxdamage >"$LOG_DIR/x11vnc.log" 2>&1 &
PIDS+=("$!")

websockify --web=/usr/share/novnc/ "$NOVNC_PORT" "127.0.0.1:$VNC_PORT" >"$LOG_DIR/websockify.log" 2>&1 &
PIDS+=("$!")

ttyd --port "$TTYD_PORT" --interface 127.0.0.1 --base-path /terminal --credential "$TERMINAL_USER:$TERMINAL_PASSWORD" --writable bash -l >"$LOG_DIR/ttyd.log" 2>&1 &
PIDS+=("$!")

nginx -c "$NGINX_CONFIG" -p "$NGINX_DIR" -g 'daemon off;' >"$LOG_DIR/nginx.log" 2>&1 &
PIDS+=("$!")

printf 'Ubuntu 24.04 workspace started on port %s\n' "$PUBLIC_PORT"
printf 'Open the forwarded port and choose Desktop or Terminal.\n'

wait -n "${PIDS[@]}"
