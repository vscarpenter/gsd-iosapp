#!/usr/bin/env bash
# Records one clip per demo scene into build/demo/clips/. Requires a booted sim UDID.
set -euo pipefail
cd "$(dirname "$0")/.."

SCHEME="GSDScreenshots"
SCENES=(capture matrix complete organize dashboard)
CLIPS="build/demo/clips"
mkdir -p "$CLIPS"

UDID="${UDID:-$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1)}"
[ -n "$UDID" ] || { echo "No booted simulator. Boot one and export UDID=…"; exit 1; }
echo "Recording on $UDID"

xcodegen generate >/dev/null
xcodebuild build-for-testing -project GSD.xcodeproj -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,id=$UDID" >/dev/null

for scene in "${SCENES[@]}"; do
  echo "=== scene: $scene ==="
  xcrun simctl io "$UDID" recordVideo --codec h264 --force "$CLIPS/$scene.mp4" &
  REC=$!
  sleep 1
  TEST_RUNNER_DEMO=1 TEST_RUNNER_DEMO_SCENE="$scene" \
    xcodebuild test-without-building -project GSD.xcodeproj -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,id=$UDID" \
    -only-testing:GSDScreenshotTests/DemoChoreography >/dev/null || true
  sleep 1
  kill -INT "$REC"; wait "$REC" 2>/dev/null || true
  echo "   wrote $CLIPS/$scene.mp4"
done
echo "Done. Clips in $CLIPS/"
