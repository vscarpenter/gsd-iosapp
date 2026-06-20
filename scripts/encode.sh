#!/usr/bin/env bash
# Encodes the raw demo reels (build/demos/raw/) into the final deliverables (build/demos/out/):
#   • Marketing hero:  gsd-demo.mp4 (H.264, muted, +faststart) · gsd-demo.webm (VP9) · poster.png
#   • App-Store previews per device: iphone-6_9.mp4 · ipad-13.mp4 · mac.mp4
#
#   scripts/encode.sh [--hero iphone|ipad] [--appearance light|dark] [--music FILE] [--loop-xfade]
#                     [--hero-start S] [--hero-dur D] [--store-start S] [--store-dur D]
#                     [--no-outro] [--outro-dur S] [--outro-xfade S]
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
#
# The hero AND every per-device video end on a branded card (logo + "GSD Task Manager" +
# gsdtaskmanager.com) — they're all for the landing page. Text can't be drawn in ffmpeg (no
# libfreetype), so the card is a vector SVG rendered to PNG by rsvg-convert (fallback: ImageMagick)
# and composited with core ffmpeg filters; if neither tool is installed the card is skipped with a
# NOTE. Disable with --no-outro (also the right choice for App-Store previews, which discourage end-
# cards). See docs/superpowers/specs/2026-06-20-demo-outro-screen-design.md.
set -euo pipefail
cd "$(dirname "$0")/.."

RAW="build/demos/raw"; OUT="build/demos/out"; mkdir -p "$OUT"
FF="${FF:-ffmpeg}"; FFPROBE="${FFPROBE:-ffprobe}"
HERO="iphone"; APPEARANCE="light"; MUSIC=""; LOOP_XFADE=0
HERO_START=13; HERO_DUR=26          # skip launch+splash → open on the matrix; capture → complete → scroll
STORE_START=12; STORE_DUR=28        # previews start on the matrix; ≤30s for App Store (empty DUR = to end)
OUTRO=1; OUTRO_DUR=3.5; OUTRO_XFADE=0.6   # branded ending card on the hero + per-device videos; see header

while [ $# -gt 0 ]; do case "$1" in
  --hero) HERO="$2"; shift 2 ;;
  --appearance) APPEARANCE="$2"; shift 2 ;;
  --music) MUSIC="$2"; shift 2 ;;
  --loop-xfade) LOOP_XFADE=1; shift ;;
  --hero-start) HERO_START="$2"; shift 2 ;;
  --hero-dur) HERO_DUR="$2"; shift 2 ;;
  --store-start) STORE_START="$2"; shift 2 ;;
  --store-dur) STORE_DUR="$2"; shift 2 ;;
  --outro) OUTRO=1; shift ;;
  --no-outro) OUTRO=0; shift ;;
  --outro-dur) OUTRO_DUR="$2"; shift 2 ;;
  --outro-xfade) OUTRO_XFADE="$2"; shift 2 ;;
  *) echo "usage: $0 [--hero iphone|ipad] [--appearance light|dark] [--music FILE] [--loop-xfade]"
     echo "          [--hero-start S] [--hero-dur D] [--store-start S] [--store-dur D]"
     echo "          [--no-outro] [--outro-dur S] [--outro-xfade S]"; exit 1 ;;
esac; done

# Brand paper + palette for the outro card, per appearance (verbatim from Design/icon/app-icon*.svg).
if [ "$APPEARANCE" = dark ]; then
  OUTRO_BG="0x17150F"; C_RUST="E0705F"; C_TEAL="6FAACB"; C_GOLD="CFB266"; C_GRAY="A9A096"
  C_TITLE="F4F1E9";   C_URL="6FAACB"
else
  OUTRO_BG="0xF4F1E9"; C_RUST="B23A2E"; C_TEAL="2C6680"; C_GOLD="8A6A22"; C_GRAY="6F685F"
  C_TITLE="3A211D";   C_URL="2C6680"
fi

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

# Render the branded outro card SVG (token-substituted for the current palette) to a PNG at <size>px.
# Prefers rsvg-convert, falls back to ImageMagick. Returns non-zero (with a NOTE) if neither exists.
render_outro_card() {
  local size="$1" out="$2"
  local tmpl="scripts/assets/outro-card.svg.tmpl" svg="$OUT/.outro-card.svg"
  [ -f "$tmpl" ] || { echo "  NOTE: missing $tmpl — skipping outro."; return 1; }
  sed -e "s/__RUST__/#$C_RUST/g"  -e "s/__TEAL__/#$C_TEAL/g" \
      -e "s/__GOLD__/#$C_GOLD/g"  -e "s/__GRAY__/#$C_GRAY/g" \
      -e "s/__TITLE__/#$C_TITLE/g" -e "s/__URL__/#$C_URL/g" "$tmpl" > "$svg"
  if   command -v rsvg-convert >/dev/null 2>&1; then rsvg-convert -w "$size" -h "$size" "$svg" -o "$out"
  elif command -v magick >/dev/null 2>&1;       then magick -background none "$svg" -resize "${size}x${size}" "$out"
  elif command -v convert >/dev/null 2>&1;      then convert -background none "$svg" -resize "${size}x${size}" "$out"
  else echo "  NOTE: no rsvg-convert/ImageMagick — skipping outro (install: brew install librsvg)."; rm -f "$svg"; return 1; fi
  rm -f "$svg"
}

# Append the branded ending card to ANY finished clip, at the clip's native resolution. Probes the
# input's dims/fps/duration so the card matches (xfade needs identical dims/sar/fps), renders the
# card scaled to 0.82×min(W,H), and crossfades the clip into the card (which fades up over the brand
# paper). Returns non-zero (leaving <out> unwritten) if the card can't be rendered. Used by the hero
# and every per-device video, so all outputs get an identical ending.
append_outro() {
  local in="$1" out="$2" iw ih fr d
  iw=$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=width  -of csv=p=0 "$in")
  ih=$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$in")
  fr=$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$in")
  d=$( "$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$in")
  local size; size=$(awk "BEGIN{s=int(0.82*($iw<$ih?$iw:$ih)); s-=s%2; print s}")
  local card="$OUT/.outro-card.png"
  render_outro_card "$size" "$card" || return 1
  [ -s "$card" ] || { echo "  NOTE: outro card did not render — skipping outro."; return 1; }
  local off; off=$(calc "$d - $OUTRO_XFADE")           # crossfade starts XFADE before the clip ends
  echo "   + ending card (${iw}x${ih} @ ${OUTRO_DUR}s, xfade ${OUTRO_XFADE}s)"
  local rc=0
  "$FF" -y -i "$in" \
        -loop 1 -t "$OUTRO_DUR" -i "$card" \
        -f lavfi -t "$OUTRO_DUR" -i "color=c=$OUTRO_BG:s=${iw}x${ih}:r=$fr" \
    -filter_complex \
      "[0:v]setsar=1,fps=$fr,format=yuv420p[base];\
       [1:v]format=yuva420p,fade=t=in:st=0:d=0.6:alpha=1[card];\
       [2:v][card]overlay=(W-w)/2:(H-h)/2:format=auto,setsar=1,format=yuv420p[outro];\
       [base][outro]xfade=transition=fade:duration=$OUTRO_XFADE:offset=$off[outv]" \
    -map "[outv]" -an -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$out" || rc=$?
  rm -f "$card"
  return $rc
}

# Marketing hero with the ending card: build the trimmed 1280px reel, then append the card.
# Falls back to a plain hero (handled by the caller) if the card can't be rendered.
encode_hero_outro() {
  local base="$OUT/.hero-base.mp4" rc=0
  encode_hero_plain "$base" || return 1
  append_outro "$base" "$OUT/gsd-demo.mp4"; rc=$?
  rm -f "$base"
  return $rc
}

# ---------------------------------------------------------------------------
# 1) Marketing hero — muted, ~1280px long edge, trimmed to a representative window, loops cleanly.
# ---------------------------------------------------------------------------
hero_in="$(raw_for "$HERO")"
encode_hero_plain() {   # trimmed 1280px reel only, no ending card; writes $1 (default gsd-demo.mp4)
  local out="${1:-$OUT/gsd-demo.mp4}"
  "$FF" -y -ss "$HERO_START" -t "$HERO_DUR" -i "$hero_in" -vf "$LONG1280,setsar=1" \
    -an -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$out"
}
if [ -n "$hero_in" ]; then
  echo "=== marketing hero  ($hero_in  start=$HERO_START dur=$HERO_DUR) ==="
  if [ "$OUTRO" = 1 ]; then
    [ "$LOOP_XFADE" = 1 ] && echo "   (--outro overrides --loop-xfade: an ending card and a seamless loop are mutually exclusive)"
    encode_hero_outro || { echo "   outro unavailable — writing plain hero"; encode_hero_plain; }
  elif [ "$LOOP_XFADE" = 1 ]; then
    # Seamless loop: crossfade the head back over the tail so the last frame melts into the first.
    X=0.6; START=$(calc "$HERO_DUR - $X")
    "$FF" -y -ss "$HERO_START" -t "$HERO_DUR" -i "$hero_in" -filter_complex \
      "[0:v]$LONG1280,setsar=1[v];\
       [v]split[body][pre];\
       [pre]trim=0:$X,setpts=PTS-STARTPTS,format=yuva420p,fade=t=in:st=0:d=$X:alpha=1,setpts=PTS+$START/TB[head];\
       [body][head]overlay[outv]" \
      -map "[outv]" -an -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$OUT/gsd-demo.mp4"
  else
    encode_hero_plain
  fi
  # WebM (VP9) sibling, and a poster from the first frame.
  "$FF" -y -i "$OUT/gsd-demo.mp4" -an -c:v libvpx-vp9 -b:v 0 -crf 33 -row-mt 1 "$OUT/gsd-demo.webm"
  "$FF" -y -i "$OUT/gsd-demo.mp4" -frames:v 1 -update 1 "$OUT/gsd-demo-poster.png"
  echo "   wrote gsd-demo.mp4 · gsd-demo.webm · gsd-demo-poster.png"
else
  echo "NOTE: no hero raw for '$HERO' in $RAW — skipping marketing hero."
fi

# ---------------------------------------------------------------------------
# 2) Per-device videos (iPhone · iPad · Mac) for the landing page. Native sim resolutions already
#    match Apple's App-Store classes, so iPhone/iPad are faithful transcodes; Mac (full-screen
#    capture) is scaled into 1920×1080. Each ends on the branded card (like the hero) unless
#    --no-outro. --music is muxed here only (the web hero stays muted). For App-Store submission
#    instead, use --no-outro (Apple discourages end-cards on previews) and keep length ≤30s.
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
  [ -n "$in" ] || { echo "NOTE: no raw for '$label' — skipping $name (record it first: scripts/record-demos.sh $label)."; return; }
  echo "=== device video: $name  ($in  start=$STORE_START dur=${STORE_DUR:-end}) ==="
  local base="$OUT/.$name.h264.mp4"
  # shellcheck disable=SC2046
  if [ -n "$filt" ]; then
    "$FF" -y $(trim_args) -i "$in" -vf "$filt" -an -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$base"
  else
    "$FF" -y $(trim_args) -i "$in" -an -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$base"
  fi
  local src="$base"
  if [ "$OUTRO" = 1 ]; then
    local withcard="$OUT/.$name.card.mp4"
    if append_outro "$base" "$withcard"; then rm -f "$base"; src="$withcard"; fi
  fi
  mux_music "$src" "$OUT/$name.mp4"; rm -f "$src"
  echo "   wrote $name.mp4"
}

# iPhone 6.9" (1320×2868) and iPad 13" — native capture is already the accepted resolution.
store_device iphone iphone-6_9
store_device ipad   ipad-13
# Mac: scale the full-screen capture into 1920×1080, padding with brand paper if needed.
store_device mac    mac "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:color=$OUTRO_BG,setsar=1"

echo "---"
echo "Outputs in $OUT/ :"
for f in "$OUT"/*.mp4 "$OUT"/*.webm "$OUT"/*.png; do
  [ -f "$f" ] || continue
  printf "  %-26s " "$(basename "$f")"
  "$FFPROBE" -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$f" 2>/dev/null || echo
done
