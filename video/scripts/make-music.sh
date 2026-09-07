#!/usr/bin/env bash
# Builds public/music.m4a from the repo's music track: the AAC stream is extracted as-is
# (44.1 kHz stereo), then the first 45 s are kept with a 2 s fade out. Prints both durations.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=../docs/assets/music.mp4
TMP=$(mktemp -t gsd-music).m4a
ffmpeg -y -v error -i "$SRC" -vn -c:a copy "$TMP"
echo "source audio: $(ffprobe -v error -show_entries format=duration -of csv=p=0 "$TMP") s"
ffmpeg -y -v error -i "$TMP" -t 45 -af "afade=t=out:st=43:d=2" -c:a aac -b:a 192k -ar 44100 public/music.m4a
rm -f "$TMP"
ffprobe -v error -show_entries stream=codec_name,sample_rate,channels:format=duration -of default=noprint_wrappers=1 public/music.m4a
