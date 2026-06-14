#!/usr/bin/env bash
# Composites scene clips onto a 16:9 cream backdrop with caption cards + music -> final mp4.
set -euo pipefail
cd "$(dirname "$0")/.."

CLIPS="build/demo/clips"; DEV="build/demo/device"; SEG="build/demo/seg"
OUT="build/demo/gsd-demo-16x9.mp4"
mkdir -p "$SEG" "$DEV"

SERIF="/System/Library/Fonts/Supplemental/Georgia.ttf"
SANS="/System/Library/Fonts/Supplemental/Arial.ttf"
ICON="${ICON:-App/Assets.xcassets/AppIcon.appiconset/AppIcon.png}"
PAPER="0xF4F1E9"; INK="0x17150F"
MUSIC="${MUSIC:-docs/assets/demo-music.mp3}"   # optional

# Homebrew ffmpeg lacks drawtext; /usr/local ffmpeg 7.x is built with libfreetype. Override
# with FF=… if your drawtext-capable binary lives elsewhere.
FF="${FF:-/usr/local/bin/ffmpeg}"
FFPROBE="${FFPROBE:-ffprobe}"

# seg <clip> <lead> <dur> <label> <sub> <accentHex>  -> $SEG/<name>.mp4
seg() {
  local clip="$1" lead="$2" dur="$3" label="$4" sub="$5" accent="$6"
  local name; name="$(basename "$clip" | sed 's/\.[^.]*$//')"
  local fo; fo=$(echo "$dur - 0.4" | bc)
  "$FF" -y -ss "$lead" -t "$dur" -i "$clip" \
    -f lavfi -t "$dur" -i "color=c=$PAPER:s=1920x1080:r=30" -filter_complex "
      [0:v]scale=-2:1000,setsar=1[ph];
      [1:v]drawbox=x=236:y=44:w=474:h=1004:color=black@0.16:t=fill,boxblur=18:1[bg];
      [bg][ph]overlay=238:40[c0];
      [c0]drawbox=x=780:y=470:w=6:h=150:color=$accent:t=fill[c1];
      [c1]drawtext=fontfile='$SERIF':text='$label':x=820:y=466:fontsize=66:fontcolor=$INK[c2];
      [c2]drawtext=fontfile='$SANS':text='$sub':x=820:y=566:fontsize=34:fontcolor=$INK@0.72,
          fade=t=in:st=0:d=0.4:color=$PAPER,fade=t=out:st=$fo:d=0.4:color=$PAPER[v]
    " -map "[v]" -r 30 -c:v libx264 -pix_fmt yuv420p -an -t "$dur" "$SEG/$name.mp4"
}

# card <out> <dur> <line1> <line2>  -> full-screen cream card with icon
card() {
  local out="$1" dur="$2" l1="$3" l2="$4"; local fo; fo=$(echo "$dur - 0.5" | bc)
  "$FF" -y -f lavfi -t "$dur" -i "color=c=$PAPER:s=1920x1080:r=30" -i "$ICON" -filter_complex "
      [1:v]scale=232:232[ic];
      [0:v][ic]overlay=(W-w)/2:300[b0];
      [b0]drawtext=fontfile='$SERIF':text='$l1':x=(w-text_w)/2:y=600:fontsize=104:fontcolor=$INK[b1];
      [b1]drawtext=fontfile='$SANS':text='$l2':x=(w-text_w)/2:y=748:fontsize=40:fontcolor=$INK@0.78,
          fade=t=in:st=0:d=0.5:color=$PAPER,fade=t=out:st=$fo:d=0.5:color=$PAPER[v]
    " -map "[v]" -r 30 -c:v libx264 -pix_fmt yuv420p -an "$out"
}

# ---- Cards ----
card "$SEG/00-title.mp4" 4 "GSD" "The calm way to get stuff done"
card "$SEG/99-cta.mp4"   6 "Private. Offline-first." "GSD on the App Store"

# ---- In-app segments (lead/dur tuned to each clip's action window) ----
seg "$CLIPS/capture.mp4"   10.5 9 "Capture in plain language" "!! sets priority    #tags organize" "0xB23A2E"
seg "$CLIPS/matrix.mp4"    10.0 9 "Urgency x importance"       "Four quadrants, always in view"     "0x2C6680"
seg "$CLIPS/complete.mp4"  12.5 6 "Done feels good"            "Swipe to complete"                  "0xB23A2E"
seg "$CLIPS/organize.mp4"  12.5 8 "Built for real work"        "Subtasks, recurring, dependencies"  "0x8A6A22"
seg "$CLIPS/dashboard.mp4" 11.5 9 "See where your effort goes" "Insights, on-device"                "0x2C6680"

# ---- Device segments (only if the owner has dropped them in build/demo/device/) ----
# Accept any common screen-recording extension/case (.mov/.mp4/.m4v). `if`-guarded so a
# missing optional clip doesn't trip `set -e`.
dev_clip() { for e in mov MOV mp4 MP4 m4v; do [ -f "$DEV/$1.$e" ] && { printf '%s' "$DEV/$1.$e"; return 0; }; done; return 1; }
# NOTE: caption text is single-quoted in the ffmpeg filtergraph — use a typographic
# apostrophe (’ U+2019), never an ASCII ' which would terminate the string and corrupt the filter.
if w=$(dev_clip widgets); then seg "$w" 1.5 6.5 "Always one glance away" "Today’s Focus on your Home Screen" "0x8A6A22"; fi
if s=$(dev_clip siri);    then seg "$s" 0   7   "Just ask Siri"          "Add tasks with Siri"                "0x6F685F"; fi
if h=$(dev_clip share);   then seg "$h" 0   6   "Add from anywhere"      "Share into GSD from any app"        "0x2C6680"; fi

# ---- Concat in storyboard order (skip any missing optional segment) ----
order=(00-title capture matrix complete organize dashboard widgets share siri 99-cta)
: > "$SEG/list.txt"
for n in "${order[@]}"; do [ -f "$SEG/$n.mp4" ] && echo "file '$n.mp4'" >> "$SEG/list.txt"; done
"$FF" -y -f concat -safe 0 -i "$SEG/list.txt" -r 30 -c:v libx264 -pix_fmt yuv420p "$SEG/_silent.mp4"

# ---- Music bed (optional) ----
if [ -f "$MUSIC" ]; then
  dur=$("$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$SEG/_silent.mp4")
  "$FF" -y -i "$SEG/_silent.mp4" -i "$MUSIC" \
    -filter_complex "[1:a]volume=0.32,afade=t=out:st=$(echo "$dur-2"|bc):d=2[a]" \
    -map 0:v -map "[a]" -shortest -c:v copy -c:a aac "$OUT"
else
  cp "$SEG/_silent.mp4" "$OUT"; echo "NOTE: no $MUSIC — rendered music-free."
fi
echo "Wrote $OUT"
"$FFPROBE" -v error -select_streams v:0 -show_entries stream=width,height,duration -of default=noprint_wrappers=1 "$OUT"
