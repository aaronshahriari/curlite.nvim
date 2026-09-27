#!/usr/bin/env bash
# Run the curlite test suite. Pass a substring to filter tests.
#
# A local echo server (tests/server.py) is started for the integration tests
# and stopped again on exit. Without python3 those tests skip.
set -u
cd "$(dirname "$0")/.." || exit 1

PORT="${CURLITE_TEST_PORT:-18923}"
SERVER_PID=""

if command -v python3 >/dev/null 2>&1; then
  python3 tests/server.py "$PORT" >/dev/null 2>&1 &
  SERVER_PID=$!
  # Wait for the port to answer rather than sleeping a fixed amount.
  for _ in $(seq 1 50); do
    curl -s -o /dev/null -m 1 "http://127.0.0.1:$PORT/json" && break
    sleep 0.1
  done
fi

cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
}
trap cleanup EXIT

CURLITE_TEST_PORT="$PORT" nvim --headless --noplugin -u NONE -l tests/harness.lua "$@"
