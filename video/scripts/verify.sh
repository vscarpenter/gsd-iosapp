#!/usr/bin/env bash
# Verifies the rendered deliverables in ../out: exact dimensions, 30 fps, 45 s, an AAC audio
# stream, and H.264 yuv420p video. Then extracts a frame every 3 s per file into
# ../out/frames/<name>/ and tiles them into one contact sheet for review.
#
#   bash scripts/verify.sh
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=../out
status=0

check() {
  local file="$1" w="$2" h="$3"
  local v a
  v=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,pix_fmt,width,height,r_frame_rate -of csv=p=0 "$OUT/$file")
  a=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name,sample_rate -of csv=p=0 "$OUT/$file")
  local dur; dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT/$file")
  # ffprobe prints fields in its own order (codec, width, height, pix_fmt, rate), not the requested one.
  local want="h264,${w},${h},yuv420p,30/1"
  local got; got=$(echo "$v" | awk -F, '{print $1","$2","$3","$4","$5}')
  local ok="ok"
  [ "$got" = "$want" ] || ok="MISMATCH (want $want)"
  awk -v d="$dur" 'BEGIN { exit !(d >= 44.95 && d <= 45.1) }' || ok="$ok DURATION $dur"
  [[ "$a" == aac,* ]] || ok="$ok NO-AAC ($a)"
  [ "$ok" = "ok" ] || status=1
  printf "%-16s video=%-32s audio=%-12s duration=%6.2fs  %s\n" "$file" "$got" "$a" "$dur" "$ok"
}

check gsd-16x9.mp4 1920 1080
check gsd-9x16.mp4 1080 1920
check gsd-1x1.mp4 1080 1080

for name in gsd-16x9 gsd-9x16 gsd-1x1; do
  dir="$OUT/frames/$name"; mkdir -p "$dir"
  ffmpeg -y -v error -i "$OUT/$name.mp4" -vf "fps=1/3" "$dir/%02d.png"
  ffmpeg -y -v error -i "$OUT/$name.mp4" -vf "fps=1/3,scale=-1:360,tile=5x3:padding=6:color=#888888" -frames:v 1 "$OUT/frames/$name-sheet.png"
  echo "frames: $dir ($(ls "$dir" | wc -l | tr -d ' ') files), sheet: $OUT/frames/$name-sheet.png"
done
exit $status
