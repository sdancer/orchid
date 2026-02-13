#!/bin/bash
export WINEPREFIX=/home/agent/.wine
export WINEARCH=win32
export DISPLAY=${DISPLAY:-:99}

# Start Xvfb if not running
if ! pgrep -x Xvfb > /dev/null; then
  Xvfb $DISPLAY -screen 0 800x600x16 &
  sleep 1
fi

# Find and run the game exe
GAME_DIR="${1:-/workspace/game}"
GAME_EXE=$(find "$GAME_DIR" -maxdepth 2 -iname "*.exe" -not -iname "unins*" -not -iname "setup*" | head -1)
if [ -n "$GAME_EXE" ]; then
  echo "Running: $GAME_EXE"
  cd "$(dirname "$GAME_EXE")"
  timeout 30 wine "$GAME_EXE" "${@:2}" 2>&1 || echo "Game exited with code $?"
else
  echo "No game executable found in $GAME_DIR"
  find "$GAME_DIR" -type f | head -20
fi
