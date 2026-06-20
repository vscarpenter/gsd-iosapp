#!/usr/bin/env bash
# Encodes the raw demo reels (build/demos/raw/) into the final deliverables (build/demos/out/):
#   • Marketing hero:  gsd-demo.mp4 (H.264, muted, +faststart) · gsd-demo.webm (VP9) · poster.png
#   • App-Store previews per device: iphone-6_9.mp4 · ipad-13.mp4 · mac.mp4
#
#   scripts/encode.sh [--hero iphone|ipad] [--appearance light|dark] [--music FILE] [--loop-xfade]
#                     [--hero-start S] [--hero-dur D] [--store-start S] [--store-dur D]
#
# The raw reels include the simulator launch/seed lead-in (~10s) plus the full paced flow, so they
# run ~50–60s. TRIM to the window you want with --hero-start/--hero-dur (and --store-start/-dur);
# view build/demos/raw/*.mp4 first and tune — launch timing varies by machine. Defaults skip the
# lead-in and take a representative ~26s window for the hero.
#
# Plain ffmpeg only (no drawtext), so stock Homebrew ffmpeg works. The web hero is ALWAYS muted
# (autoplay requires it); only the App-Store previews carry --music. Apple's accepted preview
# resolutions are picky and change with new device classes — verify against the current spec at
# https://developer.apple.com/help/app-store-connect/reference/app-preview-specifications/
set -euo pipefail
cd "$(dirname "$0")/.."

RAW="build/demos/raw"; OUT="build/demos/out"; mkdir -p "$OUT"
FF="${FF:-ffmpeg}"; FFPROBE="${FFPROBE:-ffprobe}"
HERO="iphone"; APPEARANCE="light"; MUSIC=""; LOOP_XFADE=0
HERO_START=13; HERO_DUR=26          # skip launch+splash → open on the matrix; capture → complete → scroll
STORE_START=12; STORE_DUR=28        # previews start on the matrix; ≤30s for App Store (empty DUR = to end)
PAPER="0xF4F1E9"                     # brand cream, used to pad any letterboxing

while [ $# -gt 0 ]; do case "$1" in
  --hero) HERO="$2"; shift 2 ;;
  --appearance) APPEARANCE="$2"; shift 2 ;;
  --music) MUSIC="$2"; shift 2 ;;
  --loop-xfade) LOOP_XFADE=1; shift ;;
  --hero-start) HERO_START="$2"; shift 2 ;;
  --hero-dur) HERO_DUR="$2"; shift 2 ;;
  --store-start) STORE_START="$2"; shift 2 ;;
  --store-dur) STORE_DUR="$2"; shift 2 ;;
  *) echo "usage: $0 [--hero iphone|ipad] [--appearance light|dark] [--music FILE] [--loop-xfade]"
     echo "          [--hero-start S] [--hero-dur D] [--store-start S] [--store-dur D]"; exit 1 ;;
esac; done

calc() { awk "BEGIN{printf \"%.3f\", $1}"; }
# Long edge → 1280, preserving aspect & even dims (works for portrait and landscape sources).
LONG1280="scale='if(gt(iw,ih),1280,-2)':'if(gt(iw,ih),-2,1280)'"

# raw path for a device label, honoring the appearance suffix then a bare fallback.
raw_for() {
  local label="$1"
  if   [ -f "$RAW/$label-$APPEARANCE.mp4" ]; then echo "$RAW/$label-$APPEARANCE.mp4"
  elif [ -f "$RAW/$label.mp4" ];            then echo "$RAW/$label.mp4"
  elif [ -f "$RAW/$label.mov" ];            then echo "$RAW/$label.mov"
  else echo ""; fi
}

# ---------------------------------------------------------------------------
# 1) Marketing hero — muted, ~1280px long edge, trimmed to a representative window, loops cleanly.
# ---------------------------------------------------------------------------
hero_in="$(raw_for "$HERO")"
if [ -n "$hero_in" ]; then
  echo "=== marketing hero  ($hero_in  start=$HERO_START dur=$HERO_DUR) ==="
  if [ "$LOOP_XFADE" = 1 ]; then
    # Seamless loop: crossfade the head back over the tail so the last frame melts into the first.
    X=0.6; START=$(calc "$HERO_DUR - $X")
    "$FF" -y -ss "$HERO_START" -t "$HERO_DUR" -i "$hero_in" -filter_complex \
      "[0:v]$LONG1280,setsar=1[v];\
       [v]split[body][pre];\
       [pre]trim=0:$X,setpts=PTS-STARTPTS,format=yuva420p,fade=t=in:st=0:d=$X:alpha=1,setpts=PTS+$START/TB[head];\
       [body][head]overlay[outv]" \
      -map "[outv]" -an -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$OUT/gsd-demo.mp4"
  else
    "$FF" -y -ss "$HERO_START" -t "$HERO_DUR" -i "$hero_in" -vf "$LONG1280,setsar=1" \
      -an -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$OUT/gsd-demo.mp4"
  fi
  # WebM (VP9) sibling, and a poster from the first frame.
  "$FF" -y -i "$OUT/gsd-demo.mp4" -an -c:v libvpx-vp9 -b:v 0 -crf 33 -row-mt 1 "$OUT/gsd-demo.webm"
  "$FF" -y -i "$OUT/gsd-demo.mp4" -frames:v 1 -update 1 "$OUT/gsd-demo-poster.png"
  echo "   wrote gsd-demo.mp4 · gsd-demo.webm · gsd-demo-poster.png"
else
  echo "NOTE: no hero raw for '$HERO' in $RAW — skipping marketing hero."
fi

# ---------------------------------------------------------------------------
# 2) App-Store previews (per device). Native sim resolutions already match Apple's classes, so
#    iPhone/iPad are faithful transcodes; Mac (full-screen capture) is scaled into 1920×1080.
#    --music is muxed here only (the web hero stays muted).
# ---------------------------------------------------------------------------
trim_args() { printf -- "-ss %s" "$STORE_START"; [ -n "$STORE_DUR" ] && printf -- " -t %s" "$STORE_DUR"; }

mux_music() {   # <in.mp4> <out.mp4>  — copy video, add ducked music faded out; else strip audio.
  local in="$1" out="$2"
  if [ -n "$MUSIC" ] && [ -f "$MUSIC" ]; then
    local d; d=$("$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$in"); local fo; fo=$(calc "$d - 1.5")
    "$FF" -y -i "$in" -i "$MUSIC" \
      -filter_complex "[1:a]volume=0.30,afade=t=out:st=$fo:d=1.5[a]" \
      -map 0:v -map "[a]" -shortest -c:v copy -c:a aac -b:a 192k "$out"
  else
    "$FF" -y -i "$in" -an -c:v copy "$out"
  fi
}

store_device() {   # <label> <out-name> [scale-filter]
  local label="$1" name="$2" filt="${3:-}"
  local in; in="$(raw_for "$label")"
  [ -n "$in" ] || { echo "NOTE: no raw for '$label' — skipping $name preview."; return; }
  echo "=== App-Store preview: $name  ($in  start=$STORE_START dur=${STORE_DUR:-end}) ==="
  local base="$OUT/.$name.h264.mp4"
  # shellcheck disable=SC2046
  if [ -n "$filt" ]; then
    "$FF" -y $(trim_args) -i "$in" -vf "$filt" -an -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$base"
  else
    "$FF" -y $(trim_args) -i "$in" -an -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$base"
  fi
  mux_music "$base" "$OUT/$name.mp4"; rm -f "$base"
  echo "   wrote $name.mp4"
}

# iPhone 6.9" (1320×2868) and iPad 13" — native capture is already the accepted resolution.
store_device iphone iphone-6_9
store_device ipad   ipad-13
# Mac: scale the full-screen capture into 1920×1080, padding with brand cream if needed.
store_device mac    mac "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:color=$PAPER,setsar=1"

echo "---"
echo "Outputs in $OUT/ :"
for f in "$OUT"/*.mp4 "$OUT"/*.webm "$OUT"/*.png; do
  [ -f "$f" ] || continue
  printf "  %-26s " "$(basename "$f")"
  "$FFPROBE" -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$f" 2>/dev/null || echo
done
