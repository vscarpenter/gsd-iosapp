#!/usr/bin/env bash
# Records the product-video clips (one per beat) from the iOS simulator, driven by the `video-*`
# scenes in ScreenshotTests/DemoChoreography.swift, then normalizes them for the Remotion project
# in video/. Design: docs/superpowers/specs/2026-09-07-product-video-design.md.
#
#   scripts/capture-video-clips.sh build                    # build the GSDScreenshots bundle once
#   scripts/capture-video-clips.sh record iphone [scene...] # default: matrix capture complete dashboard widget
#   scripts/capture-video-clips.sh record ipad   [scene...] # default: matrix capture complete dashboard drag
#   scripts/capture-video-clips.sh normalize                # captures/*.mov -> captures/normalized/*.mp4
#   scripts/capture-video-clips.sh probe                    # ffprobe report for the normalized clips
#
# Handshake: the scene touches $READY once the seeded UI has settled (the recorder starts) and
# $DONE after its closing hold (the recorder stops), so every clip opens and closes on a hold.
set -euo pipefail
cd "$(dirname "$0")/.."

IPHONE_UDID="${IPHONE_UDID:-F1F0563B-B96A-4EA3-BD4C-8B5D5A46841D}"   # iPhone 17 Pro, iOS 26.5
IPAD_UDID="${IPAD_UDID:-1AB77A4E-8576-4B71-BAE7-0BC00A58D352}"       # iPad Pro 13-inch (M5), iOS 26.5
SCHEME=GSDScreenshots
ONLY=-only-testing:GSDScreenshotTests/DemoChoreography/testDemoScene
DD="${DD:-build/dd}"
CAPTURES=captures
# simctl can pin the status-bar time but not its date (the ISO form is accepted and ignored on iPad),
# so the app's frozen clock is noon local on the recording day: the iPad's date readout and the
# app's "today" then agree. Within a day the footage is deterministic.
VIDEO_EPOCH=$(/bin/date -j -f "%Y-%m-%d %H:%M:%S" "$(/bin/date +%Y-%m-%d) 12:00:00" +%s)
# iPad scenes run landscape, but simctl records the portrait framebuffer, so the clip comes out on
# its side with the UI's top edge on the right. Rotate 90 degrees counter-clockwise. ROTATE_IPAD= skips.
ROTATE_IPAD="${ROTATE_IPAD-transpose=2}"

udid_for() {
  case "$1" in
    iphone) echo "$IPHONE_UDID" ;;
    ipad)   echo "$IPAD_UDID" ;;
    *) echo "unknown device '$1' (iphone|ipad)" >&2; exit 1 ;;
  esac
}

prepare_sim() {
  local udid="$1"
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
  xcrun simctl ui "$udid" appearance light
  xcrun simctl status_bar "$udid" override --time 9:41 \
    --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4
}

cmd_build() {
  xcodebuild build-for-testing -project GSD.xcodeproj -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,id=$IPHONE_UDID" -derivedDataPath "$DD" -quiet
}

record_scene() {
  local device="$1" udid="$2" scene="$3"
  local out="$CAPTURES/$device-$scene.mov" log="$CAPTURES/logs/$device-$scene.log"
  local READY="/tmp/gsd-video-ready-$device" DONE="/tmp/gsd-video-done-$device"   # per device, so both can record at once
  rm -f "$READY" "$DONE" "$out"
  TEST_RUNNER_DEMO=1 TEST_RUNNER_DEMO_SCENE="video-$scene" TEST_RUNNER_VIDEO_EPOCH="$VIDEO_EPOCH" \
  TEST_RUNNER_VIDEO_READY="$READY" TEST_RUNNER_VIDEO_DONE="$DONE" \
    xcodebuild test-without-building -project GSD.xcodeproj -scheme "$SCHEME" \
      -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$DD" $ONLY >"$log" 2>&1 &
  local test=$!
  while [ ! -f "$READY" ]; do
    if ! kill -0 "$test" 2>/dev/null; then
      echo "   $device-$scene: the test ended before the ready signal (see $log)"; return 1
    fi
    sleep 0.1
  done
  xcrun simctl io "$udid" recordVideo --codec h264 --mask ignored --force "$out" &
  local rec=$!
  while [ ! -f "$DONE" ]; do
    kill -0 "$test" 2>/dev/null || break
    sleep 0.1
  done
  sleep 0.3
  kill -INT "$rec" 2>/dev/null || true
  wait "$rec" 2>/dev/null || true
  wait "$test" 2>/dev/null || true
  [ -s "$out" ] || { echo "   $device-$scene: no recording written (see $log)"; return 1; }
  echo "   wrote $out ($(ffprobe -v error -show_entries format=duration -of csv=p=0 "$out") s)"
}

cmd_record() {
  local device="$1"; shift
  local udid; udid=$(udid_for "$device")
  local scenes=("$@")
  if [ ${#scenes[@]} -eq 0 ]; then
    case "$device" in
      iphone) scenes=(matrix capture complete dashboard widget) ;;
      ipad)   scenes=(matrix capture complete dashboard drag) ;;
    esac
  fi
  mkdir -p "$CAPTURES/logs"
  prepare_sim "$udid"
  local failed=0
  for scene in "${scenes[@]}"; do
    echo "=== $device / video-$scene ==="
    record_scene "$device" "$udid" "$scene" || failed=1
  done
  xcrun simctl status_bar "$udid" clear 2>/dev/null || true
  return $failed
}

# Trim window per raw clip as "start duration" in seconds, chosen from one-frame-per-second contact
# sheets of the 2026-09-07 takes: each window opens on a hold, carries the beat, and closes on a
# hold at least 0.4 s before the recorder stopped. Durations must match video/src/beats.ts.
trim_for() {
  case "$1" in
    iphone-matrix)    echo "0.3 8" ;;
    iphone-capture)   echo "2.5 9.6" ;;
    iphone-complete)  echo "3.0 8.7" ;;
    iphone-dashboard) echo "1.0 8" ;;
    iphone-widget)    echo "0.3 7.6" ;;
    ipad-matrix)      echo "0.3 7" ;;
    ipad-capture)     echo "3.4 9.6" ;;
    ipad-complete)    echo "2.8 8.7" ;;
    ipad-dashboard)   echo "1.8 8" ;;
    ipad-drag)        echo "3.6 7.6" ;;
    *) echo "0 10" ;;
  esac
}

cmd_normalize() {
  mkdir -p "$CAPTURES/normalized"
  for mov in "$CAPTURES"/*.mov; do
    local name vf start dur; name=$(basename "$mov" .mov); vf="fps=30"
    case "$name" in ipad-*) [ -n "$ROTATE_IPAD" ] && vf="$ROTATE_IPAD,$vf" ;; esac
    read -r start dur <<< "$(trim_for "$name")"
    ffmpeg -y -v error -ss "$start" -t "$dur" -i "$mov" -vf "$vf" -fps_mode cfr \
      -c:v libx264 -preset slow -crf 17 -pix_fmt yuv420p -movflags +faststart -an \
      "$CAPTURES/normalized/$name.mp4"
    echo "   $CAPTURES/normalized/$name.mp4 (from ${start}s, ${dur}s)"
  done
}

cmd_probe() {
  printf "%-22s %6s %7s %8s %8s\n" clip width height fps seconds
  for f in "$CAPTURES"/normalized/*.mp4; do
    ffprobe -v error -select_streams v:0 \
      -show_entries stream=width,height,r_frame_rate:format=duration -of csv=p=0 "$f" \
      | tr '\n' ',' | awk -F, -v n="$(basename "$f")" '{ split($3, r, "/"); printf "%-22s %6s %7s %8.2f %8.2f\n", n, $1, $2, r[1]/r[2], $4 }'
  done
}

case "${1:-}" in
  build)     cmd_build ;;
  record)    shift; cmd_record "$@" ;;
  normalize) cmd_normalize ;;
  probe)     cmd_probe ;;
  *) sed -n '2,12p' "$0"; exit 1 ;;
esac
