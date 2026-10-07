#!/bin/bash
# run_game.sh — windowed run with watchdog cleanup.
# - Kills stale toohuman instances first.
# - Launches the game (opens its own SDL window on the desktop).
# - Watchdog: kills the game if the newest log freezes for 60s (hung
#   thread) or if an access-violation spam loop is detected (crash loop).
# Usage: ./run_game.sh [timeout_seconds]   (default 600)

BUILD="/home/nick/Desktop/Coding/Roms/Too Human/port/out/build/linux-amd64-release"
LOGDIR="$BUILD/logs"
TIMEOUT="${1:-600}"

# 1. Clean stale instances
pkill -9 -x toohuman 2>/dev/null && echo "[watchdog] killed stale toohuman"

# 2. Launch windowed
cd "$BUILD"
LD_LIBRARY_PATH=/tmp/rexglue-sdk/out/install/linux-amd64/lib ./toohuman \
  --game_data_root "/home/nick/Desktop/Coding/Roms/Too Human/extracted" \
  --user_data_root "/home/nick/Desktop/Coding/Roms/Too Human/port/userdata" \
  --gpu_plugin xenos \
  --vulkan_async_skip_incomplete_frames=false \
  --async_shader_compilation=false &
GPID=$!
echo "[watchdog] launched toohuman pid=$GPID (windowed), timeout=${TIMEOUT}s"

# 3. Watchdog loop
START=$(date +%s)
LAST_SIZE=0
LAST_CHANGE=$START
VIOL_BASE=0
while kill -0 $GPID 2>/dev/null; do
  sleep 5
  NOW=$(date +%s)
  if [ $((NOW - START)) -gt "$TIMEOUT" ]; then
    echo "[watchdog] timeout ${TIMEOUT}s reached — stopping"
    kill -9 $GPID 2>/dev/null
    break
  fi
  NEW=$(ls -t "$LOGDIR"/toohuman_*.log 2>/dev/null | grep -v "\." | head -1)
  [ -z "$NEW" ] && continue
  SZ=$(stat -c %s "$LOGDIR/$NEW" 2>/dev/null || echo 0)
  if [ "$SZ" != "$LAST_SIZE" ]; then LAST_SIZE=$SZ; LAST_CHANGE=$NOW; fi
  # freeze: newest log untouched for 60s (main pipeline hung)
  if [ $((NOW - LAST_CHANGE)) -gt 60 ]; then
    echo "[watchdog] log $NEW stale for 60s — freeze detected, killing"
    kill -9 $GPID 2>/dev/null
    break
  fi
  # crash loop: unhandled-violation spam
  V=$(grep -c "Unhandled" "$LOGDIR/$NEW" 2>/dev/null || echo 0)
  if [ $((V - VIOL_BASE)) -gt 5000 ]; then
    echo "[watchdog] violation spam (${V} lines) — crash loop, killing"
    kill -9 $GPID 2>/dev/null
    break
  fi
  if [ "$V" -lt "$VIOL_BASE" ]; then VIOL_BASE=$V; fi
done

wait $GPID 2>/dev/null
echo "[watchdog] game exited rc=$?"
# 4. Final cleanup
pkill -9 -x toohuman 2>/dev/null
echo "[watchdog] cleanup done"
