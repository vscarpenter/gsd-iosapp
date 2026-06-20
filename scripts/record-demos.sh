#!/usr/bin/env bash
# Records one CONTINUOUS demo reel per device into build/demos/raw/. Each reel is driven by the
# XCUITest choreography (ScreenshotTests/DemoChoreography, scene `reel-<device>`) over seeded data
# with a frozen clock, so footage is identical on every run.
#
#   scripts/record-demos.sh <iphone|ipad|mac|all> [light|dark]
#
# iPhone/iPad capture via `simctl io recordVideo` (simulator). Mac is a native Catalyst app — no
# simulator — so it is captured with macOS `screencapture -v` (a real-machine capture, valid for
# the Mac App Store). The Mac path needs Screen Recording permission for your terminal and a GUI
# session; run it locally on your Mac (see DEMOS.md).
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE="${1:-all}"
APPEARANCE="${2:-light}"
SCHEME="GSDScreenshots"
ONLY="-only-testing:GSDScreenshotTests/DemoChoreography/testDemoScene"
RAW="build/demos/raw"
MAC_SECS="${MAC_SECS:-45}"   # mac screen-recording length; must exceed the choreography (~30s)
mkdir -p "$RAW"

# First available simulator whose name matches one of the candidates (most-preferred first).
resolve_sim() {
  local name udid
  for name in "$@"; do
    udid=$(xcrun simctl list devices available | grep -F "$name (" | grep -oE "[0-9A-F-]{36}" | head -1)
    [ -n "$udid" ] && { echo "$udid"; return 0; }
  done
  return 1
}

# record_sim <label> <scene> <sim-name…>  → build/demos/raw/<label>-<appearance>.mp4
record_sim() {
  local label="$1" scene="$2"; shift 2
  local udid; udid=$(resolve_sim "$@") || {
    echo "No simulator found for $label. Tried: $*"; echo "Available:"; \
      xcrun simctl list devices available | grep -E "iPhone|iPad"; exit 1; }
  echo "=== $label  ($scene, $APPEARANCE)  udid=$udid ==="
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
  xcodebuild build-for-testing -project GSD.xcodeproj -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,id=$udid" >/dev/null
  # App-Store-style status bar (9:41, full signal/battery); cleared on the way out.
  xcrun simctl status_bar "$udid" override --time "9:41" \
    --batteryState charged --batteryLevel 100 \
    --cellularBars 4 --wifiBars 3 --dataNetwork wifi 2>/dev/null || true
  local out="$RAW/$label-$APPEARANCE.mp4"
  xcrun simctl io "$udid" recordVideo --codec h264 --force "$out" &
  local rec=$!
  sleep 1
  TEST_RUNNER_DEMO=1 TEST_RUNNER_DEMO_SCENE="$scene" TEST_RUNNER_DEMO_APPEARANCE="$APPEARANCE" \
    xcodebuild test-without-building -project GSD.xcodeproj -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,id=$udid" $ONLY >/dev/null || true
  sleep 1
  kill -INT "$rec"; wait "$rec" 2>/dev/null || true
  xcrun simctl status_bar "$udid" clear 2>/dev/null || true
  echo "   wrote $out"
}

# Mac Catalyst: full-screen capture while the reel-mac choreography drives the app. encode.sh
# scales the result to a Mac App-Store size; refine the crop there if you want a tighter window.
record_mac() {
  echo "=== mac  (reel-mac, $APPEARANCE) ==="
  xcodebuild build-for-testing -project GSD.xcodeproj -scheme "$SCHEME" \
    -destination 'platform=macOS,variant=Mac Catalyst' >/dev/null
  local out="$RAW/mac.mov"; rm -f "$out"
  # Roll a FIXED-LENGTH recording: `-v` records video, `-V<secs>` (attached form) stops and FINALIZES
  # the .mov when the timer elapses. We deliberately do NOT kill it — interrupting a -v capture can
  # abort it without saving, which is what previously left no mac.mov. The choreography runs inside the
  # window; encode.sh trims the tail. Needs Screen Recording permission for THIS terminal + a GUI
  # session (no headless/CI).
  screencapture -v -V"$MAC_SECS" -x "$out" &
  local rec=$!
  sleep 1
  TEST_RUNNER_DEMO=1 TEST_RUNNER_DEMO_SCENE=reel-mac TEST_RUNNER_DEMO_APPEARANCE="$APPEARANCE" \
    xcodebuild test-without-building -project GSD.xcodeproj -scheme "$SCHEME" \
    -destination 'platform=macOS,variant=Mac Catalyst' $ONLY || true
  wait "$rec" 2>/dev/null || true     # let -V elapse so the .mov is finalized
  if [ -s "$out" ]; then
    echo "   wrote $out (full screen — cropped/scaled in encode.sh)"
  else
    echo "   ERROR: screencapture produced no $out."
    echo "   This almost always means Screen Recording permission is missing. Grant it to THIS"
    echo "   terminal app, fully quit & reopen the terminal, then re-run:"
    echo "     System Settings ▸ Privacy & Security ▸ Screen Recording ▸ enable your terminal."
    return 1
  fi
}

IPHONE_SIMS=("iPhone 16 Pro Max" "iPhone 17 Pro Max" "iPhone 15 Pro Max")   # 6.9" App-Store class
IPAD_SIMS=("iPad Pro 13-inch (M4)" "iPad Pro 13-inch (M5)" "iPad Pro (12.9-inch) (6th generation)")

case "$DEVICE" in
  iphone) record_sim iphone reel-iphone "${IPHONE_SIMS[@]}" ;;
  ipad)   record_sim ipad   reel-ipad   "${IPAD_SIMS[@]}" ;;
  mac)    record_mac ;;
  all)    record_sim iphone reel-iphone "${IPHONE_SIMS[@]}"
          record_sim ipad   reel-ipad   "${IPAD_SIMS[@]}"
          record_mac ;;
  *) echo "usage: $0 <iphone|ipad|mac|all> [light|dark]"; exit 1 ;;
esac

echo "Done. Raw reels in $RAW/  →  encode with: scripts/encode.sh"
