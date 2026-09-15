#!/usr/bin/env bash
# Captures one PNG per screen, light and dark, on iPhone, iPad, and Mac Catalyst, by running the
# RefreshBaseline UI test (ScreenshotTests/RefreshBaseline.swift). Used for the iOS 27 refresh:
# a "baseline" run before any visual change, then one run per phase to compare against it.
#
#   scripts/capture-screens.sh <label> [iphone|ipad|mac ...]     # default: all three
#
# Output: build/screens/<label>/<platform>-<appearance>-NN-name.png (build/ is gitignored).
# The Mac run needs a GUI session and signing for the host (the same as the reel-mac demo).
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL="${1:?usage: capture-screens.sh <label> [iphone|ipad|mac ...]}"; shift
PLATFORMS=("$@")
if [ ${#PLATFORMS[@]} -eq 0 ]; then PLATFORMS=(iphone ipad mac); fi

IPHONE_UDID="${IPHONE_UDID:-CC926802-7D1D-4AF1-9BDA-BCD4B4C4B768}"   # iPhone 18 Pro, iOS 27.0
IPAD_UDID="${IPAD_UDID:-83963D05-D43E-4103-9772-37EA4A81EFA9}"       # iPad Pro 13-inch (M5), iOS 27.0
SCHEME=GSDScreenshots
ONLY=-only-testing:GSDScreenshotTests/RefreshBaseline/testCaptureEveryScreen
DD="${DD:-build/dd}"
OUT="$PWD/build/screens/$LABEL"
mkdir -p "$OUT/logs"

run_test() {
  local platform="$1" appearance="$2" dest="$3"
  local log="$OUT/logs/$platform-$appearance.log"
  echo "=== $platform / $appearance ==="
  TEST_RUNNER_BASELINE=1 \
  TEST_RUNNER_SCREENSHOT_DIR="$OUT" \
  TEST_RUNNER_SCREENSHOT_PREFIX="$platform-$appearance-" \
  TEST_RUNNER_SCREENSHOT_APPEARANCE="$appearance" \
    xcodebuild test-without-building -project GSD.xcodeproj -scheme "$SCHEME" \
      -destination "$dest" -derivedDataPath "$DD" "$ONLY" >"$log" 2>&1 \
    || echo "   $platform/$appearance: xcodebuild reported failures (see $log)"
  echo "   screens: $(ls "$OUT" | grep -c "^$platform-$appearance-" || true)"
}

run_sim() {
  local platform="$1" udid="$2"
  local dest="platform=iOS Simulator,id=$udid"
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
  xcrun simctl status_bar "$udid" override --time 9:41 \
    --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4
  xcodebuild build-for-testing -project GSD.xcodeproj -scheme "$SCHEME" \
    -destination "$dest" -derivedDataPath "$DD" -quiet
  for appearance in light dark; do
    xcrun simctl ui "$udid" appearance "$appearance"
    run_test "$platform" "$appearance" "$dest"
    if [ "$platform" = ipad ]; then
      # The iPad walk runs landscape, but the simulator captures the portrait framebuffer, so
      # the PNG comes out on its side with the UI's top edge on the right. Rotate it upright.
      for png in "$OUT/$platform-$appearance-"*.png; do sips -r 270 "$png" >/dev/null 2>&1; done
    fi
  done
  xcrun simctl status_bar "$udid" clear 2>/dev/null || true
}

run_mac() {
  local dest="platform=macOS,variant=Mac Catalyst"
  # The Catalyst test runner is sandboxed (read-only outside its container), so the walk
  # writes into the runner's temporary directory and the PNGs are copied out afterwards.
  local sandbox="$HOME/Library/Containers/dev.vinny.gsd.screenshot-tests.xctrunner/Data/tmp/gsd-screens"
  xcodebuild build-for-testing -project GSD.xcodeproj -scheme "$SCHEME" \
    -destination "$dest" -derivedDataPath "$DD" -quiet
  for appearance in light dark; do
    mkdir -p "$sandbox"
    find "$sandbox" -name '*.png' -delete
    run_test mac "$appearance" "$dest"
    cp "$sandbox"/mac-"$appearance"-*.png "$OUT/" 2>/dev/null || true
    echo "   copied: $(ls "$OUT" | grep -c "^mac-$appearance-" || true)"
  done
}

for platform in "${PLATFORMS[@]}"; do
  case "$platform" in
    iphone) run_sim iphone "$IPHONE_UDID" ;;
    ipad)   run_sim ipad "$IPAD_UDID" ;;
    mac)    run_mac ;;
    *) echo "unknown platform '$platform' (iphone|ipad|mac)" >&2; exit 1 ;;
  esac
done
echo "Done. Screens in $OUT"
