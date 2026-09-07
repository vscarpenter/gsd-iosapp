#!/usr/bin/env bash
# Renders the three deliverables into ../out/ (H.264 video, AAC audio, 30 fps, 45 s) and prints an
# ffprobe line per file so the dimensions, frame rate, duration, and audio stream can be checked.
#
#   bash scripts/render.sh            # all three
#   bash scripts/render.sh GSD9x16    # one composition id
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=../out
mkdir -p "$OUT"

render() {
  local id="$1" file="$2"
  npx remotion render "$id" "$OUT/$file" --codec h264 --audio-codec aac --crf 18 --log warn
  ffprobe -v error -show_entries stream=codec_type,codec_name,width,height,r_frame_rate:format=duration \
    -of csv=p=0 "$OUT/$file" | tr '\n' ' '
  echo " <- $OUT/$file"
}

case "${1:-all}" in
  all)     render GSD16x9 gsd-16x9.mp4; render GSD9x16 gsd-9x16.mp4; render GSD1x1 gsd-1x1.mp4 ;;
  GSD16x9) render GSD16x9 gsd-16x9.mp4 ;;
  GSD9x16) render GSD9x16 gsd-9x16.mp4 ;;
  GSD1x1)  render GSD1x1 gsd-1x1.mp4 ;;
  *) echo "usage: $0 [all|GSD16x9|GSD9x16|GSD1x1]"; exit 1 ;;
esac
