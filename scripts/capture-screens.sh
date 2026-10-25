#!/usr/bin/env bash
# Captures one PNG per screen, light and dark, on iPhone, iPad, iPhone Duo, and Mac Catalyst, by
# running the RefreshBaseline UI test (ScreenshotTests/RefreshBaseline.swift). Used for the iOS 27
# refresh: a "baseline" run before any visual change, then one run per phase to compare against it.
#
#   scripts/capture-screens.sh <label> [iphone|ipad|mac|widths|duo|duo-open ...]   # default: iphone ipad mac
#
# `widths` (Mac only) pins the window to three widths and crosses the compact/regular boundary
# with the editor open (RefreshBaseline.testCaptureWidths).
#
# `duo` walks the iPhone Duo's outer display: the script reboots the simulator, which is the one
# headless way to the closed pose (a pose set in Device Hub survives a detach). `duo-open` walks
# the inner display: no CLI unfolds the phone, so the script waits (DUO_WAIT seconds, default
# 600) for you to open it in Device Hub, in portrait. The walk captures whichever display is
# live at its native size, 1398x2034 outer and 2007x2853 inner, which are the App Store Connect
# screenshot sizes for the Duo; both Duo runs check every PNG for that size and for no alpha.
#
# Output: build/screens/<label>/<platform>-<appearance>-NN-name.png (build/ is gitignored).
# The Mac run needs a GUI session and signing for the host (the same as the reel-mac demo).
# The Duo runs need `timeout` (coreutils) and `magick` (ImageMagick) from Homebrew.
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL="${1:?usage: capture-screens.sh <label> [iphone|ipad|mac|widths|duo|duo-open ...]}"; shift
PLATFORMS=("$@")
if [ ${#PLATFORMS[@]} -eq 0 ]; then PLATFORMS=(iphone ipad mac); fi

IPHONE_UDID="${IPHONE_UDID:-CC926802-7D1D-4AF1-9BDA-BCD4B4C4B768}"   # iPhone 18 Pro, iOS 27.0
IPAD_UDID="${IPAD_UDID:-2481EF71-D468-40E6-B9AF-F36E9CEFA2B7}"       # iPad Air 13-inch (M4), iOS 27.0
DUO_UDID="${DUO_UDID:-22BC0A9F-090C-47EB-81EA-290802AA3E22}"         # iPhone Duo, iOS 27.1
DUO_WAIT="${DUO_WAIT:-600}"
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

run_widths() {
  local dest="platform=macOS,variant=Mac Catalyst"
  local sandbox="$HOME/Library/Containers/dev.vinny.gsd.screenshot-tests.xctrunner/Data/tmp/gsd-screens"
  xcodebuild build-for-testing -project GSD.xcodeproj -scheme "$SCHEME" \
    -destination "$dest" -derivedDataPath "$DD" -quiet
  mkdir -p "$sandbox"
  find "$sandbox" -name '*.png' -delete
  local log="$OUT/logs/mac-widths.log"
  echo "=== mac / widths ==="
  TEST_RUNNER_BASELINE=1 TEST_RUNNER_WIDTHS=1 TEST_RUNNER_SCREENSHOT_PREFIX="mac-widths-" \
    xcodebuild test-without-building -project GSD.xcodeproj -scheme "$SCHEME" \
      -destination "$dest" -derivedDataPath "$DD" \
      -only-testing:GSDScreenshotTests/RefreshBaseline/testCaptureWidths >"$log" 2>&1 \
    || echo "   mac/widths: xcodebuild reported failures (see $log)"
  cp "$sandbox"/mac-widths-*.png "$OUT/" 2>/dev/null || true
  echo "   copied: $(ls "$OUT" | grep -c "^mac-widths-" || true)"
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

# MARK: iPhone Duo

require_duo_tools() {
  local tool
  for tool in timeout magick; do
    command -v "$tool" >/dev/null 2>&1 \
      || { echo "the Duo runs need '$tool' (brew install coreutils imagemagick)" >&2; return 1; }
  done
}

# The port UUID of one of the Duo's framebuffers, found by its width. The UUIDs change on
# every boot, so they are never hard-coded.
duo_display() {   # outer|inner
  local width
  case "$1" in outer) width=1398 ;; inner) width=2007 ;; esac
  xcrun simctl io "$DUO_UDID" enumerate \
    | awk -v w="$width" '/UUID:/ { uuid = $2 } /Default width:/ && $3 == w { print uuid; exit }'
}

# True when the display is drawing something. A dark framebuffer is a flat image (standard
# deviation 0; its mean is not 0, so brightness is no test), and a screenshot of a powered-off
# display can hang, hence the timeout.
duo_display_is_live() {   # outer|inner
  local uuid png spread
  uuid="$(duo_display "$1")"
  [ -n "$uuid" ] || return 1
  png="$(mktemp -t gsd-duo).png"
  timeout 20 xcrun simctl io "$DUO_UDID" screenshot --display="$uuid" --mask=ignored "$png" \
    >/dev/null 2>&1 || { rm -f "$png"; return 1; }
  spread="$(magick "$png" -colorspace Gray -format '%[fx:standard_deviation]' info:)"
  rm -f "$png"
  awk -v s="$spread" 'BEGIN { exit !(s > 0.01) }'
}

# App Store Connect accepts these files as they are only at the exact size with no alpha.
verify_pngs() {   # <prefix> <width> <height>
  local png dims bad=0
  for png in "$OUT/$1-"*.png; do
    [ -f "$png" ] || continue
    dims="$(sips -g pixelWidth -g pixelHeight -g hasAlpha "$png" \
      | awk '/pixelWidth/ { w = $2 } /pixelHeight/ { h = $2 } /hasAlpha/ { a = $2 } END { print w "x" h " alpha=" a }')"
    if [ "$dims" != "$2x$3 alpha=no" ]; then
      echo "   $(basename "$png"): $dims (want $2x$3 alpha=no)"; bad=1
    fi
  done
  if [ "$bad" -eq 0 ]; then echo "   $1: every PNG is $2x$3 with no alpha"; else return 1; fi
}

run_duo() {
  require_duo_tools
  echo "=== duo: rebooting into the closed pose ==="
  xcrun simctl shutdown "$DUO_UDID" 2>/dev/null || true
  xcrun simctl boot "$DUO_UDID"
  xcrun simctl bootstatus "$DUO_UDID" -b >/dev/null 2>&1 || true
  duo_display_is_live outer || { echo "duo: the outer display is dark after the reboot" >&2; return 1; }
  run_sim duo-outer "$DUO_UDID"
  verify_pngs duo-outer 1398 2034
}

run_duo_open() {
  require_duo_tools
  xcrun simctl boot "$DUO_UDID" 2>/dev/null || true
  xcrun simctl bootstatus "$DUO_UDID" -b >/dev/null 2>&1 || true
  local waited=0
  until duo_display_is_live inner; do
    if [ "$waited" -eq 0 ]; then
      echo "duo-open: open the iPhone Duo in Device Hub (portrait) and leave it open; waiting up to ${DUO_WAIT}s"
    fi
    if [ "$waited" -ge "$DUO_WAIT" ]; then echo "duo-open: the inner display never came on" >&2; return 1; fi
    sleep 5; waited=$((waited + 5))
  done
  run_sim duo-inner "$DUO_UDID"
  verify_pngs duo-inner 2007 2853
}

for platform in "${PLATFORMS[@]}"; do
  case "$platform" in
    iphone)   run_sim iphone "$IPHONE_UDID" ;;
    ipad)     run_sim ipad "$IPAD_UDID" ;;
    mac)      run_mac ;;
    widths)   run_widths ;;
    duo)      run_duo ;;
    duo-open) run_duo_open ;;
    *) echo "unknown platform '$platform' (iphone|ipad|mac|widths|duo|duo-open)" >&2; exit 1 ;;
  esac
done
echo "Done. Screens in $OUT"
