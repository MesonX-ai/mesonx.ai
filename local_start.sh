#!/usr/bin/env bash
#
# local_start.sh — launch the mesonx.ai site locally.
#
# Serves this folder (index.html + liquid-glass.js + assets/fonts) over HTTP
# so the page renders exactly like production. Must use HTTP (not file://)
# because the WebGL background texture is drawn from an offscreen canvas and
# ES module / font CORS rules block file:// rendering.
#
# Usage:
#   ./local_start.sh              # serve on port 8000
#   ./local_start.sh -p 8080      # custom port
#
set -euo pipefail

PORT=8000
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--port) PORT="${2:?Port number required}"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1 (see ./local_start.sh --help)" >&2; exit 1 ;;
  esac
done

cd "$(dirname "$0")"

[[ -f index.html ]] || { echo "❌ index.html not found in $(pwd)"; exit 1; }

# Stop anything currently listening on the target port (previous preview).
if command -v lsof >/dev/null 2>&1; then
  PIDS="$(lsof -tnP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)"
  if [[ -n "$PIDS" ]]; then
    echo "🛑 Port $PORT in use (PID(s): $(echo "$PIDS" | tr '\n' ' ')) — stopping ..."
    kill $PIDS 2>/dev/null || true
    sleep 1
    PIDS="$(lsof -tnP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)"
    [[ -n "$PIDS" ]] && kill -9 $PIDS 2>/dev/null || true
    sleep 1
    echo "✅ Port $PORT is now free."
  else
    echo "👍 Port $PORT is already free."
  fi
fi

echo "🚀 Serving mesonx.ai at http://localhost:$PORT ..."
echo "   (Ctrl+C to stop)"
if command -v python3 >/dev/null 2>&1; then
  exec python3 -m http.server "$PORT"
else
  exec npx --yes serve -l "$PORT" .
fi
