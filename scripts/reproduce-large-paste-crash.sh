#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASTE_FILE="${1:-$ROOT_DIR/Tests/MarkwasniceTests/Resources/large_paste.md}"
LOG_DIR="${TMPDIR:-/tmp}/markwasnice-large-paste"
APP_LOG="$LOG_DIR/app.log"
APP_PID=""

if [[ ! -f "$PASTE_FILE" ]]; then
  echo "Paste fixture not found: $PASTE_FILE" >&2
  exit 1
fi

mkdir -p "$LOG_DIR"
: > "$APP_LOG"

cleanup() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

pbcopy < "$PASTE_FILE"

(
  cd "$ROOT_DIR"
  swift run Markwasnice
) > "$APP_LOG" 2>&1 &
APP_PID=$!

osascript <<'APPLESCRIPT'
tell application "System Events"
  repeat 80 times
    if exists process "Markwasnice" then exit repeat
    delay 0.1
  end repeat
end tell

tell application "System Events"
  tell process "Markwasnice"
    set frontmost to true
    repeat 80 times
      if exists window 1 then exit repeat
      delay 0.1
    end repeat
  end tell
  keystroke "a" using command down
  delay 0.2
  keystroke "v" using command down
end tell
APPLESCRIPT

sleep 8

if ! kill -0 "$APP_PID" 2>/dev/null; then
  echo "Markwasnice exited or crashed during large paste. App log: $APP_LOG" >&2
  recent_crash=$(ls -t "$HOME"/Library/Logs/DiagnosticReports/Markwasnice*.crash 2>/dev/null | head -n 1 || true)
  if [[ -n "$recent_crash" ]]; then
    echo "Recent crash report: $recent_crash" >&2
  fi
  exit 1
fi

echo "Large paste completed without process exit. App log: $APP_LOG"
