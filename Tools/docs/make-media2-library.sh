#!/bin/bash
#
# make-media2-library.sh -- builds a small scratch library of short CLIPS cut from
# real titles on the media volume, for the documentation screenshots that need
# real names (review dialogs, metadata search). Nothing on the volume is changed:
# it is only read, and the clips are stream copies (no re-encoding) of the first
# seconds, with their tags removed so the Library scan sees files that need metadata.
#
#   Tools/docs/make-media2-library.sh [source-root] [target-folder]
#
# Defaults: source-root  "/Volumes/Media 2/Media 2"
#           target-folder ~/xCode/M3-Media2-Library
# Needs ffmpeg and ffprobe.
#
# Layout it creates:
#   incoming/  a release with a scene-style name (naming review),
#              a folder holding three parts of one movie (merge review, open folder)
#   library/   movies and episodes with proper names and no tags
#   staging/   empty "Ready for Media Library" folder
#
set -euo pipefail

SRC="${1:-/Volumes/Media 2/Media 2}"
OUT="${2:-$HOME/xCode/M3-Media2-Library}"
CLIP=40     # seconds per clip
PART=18     # seconds per part of the multi-part release

command -v ffmpeg >/dev/null || { echo "ffmpeg not found (brew install ffmpeg)"; exit 1; }
[ -d "$SRC" ] || { echo "Source not found: $SRC"; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/incoming" "$OUT/library" "$OUT/staging"

# clip <source file> <target file> [start seconds] [length seconds]
clip() {
  local in="$1" out="$2" start="${3:-30}" len="${4:-$CLIP}"
  mkdir -p "$(dirname "$out")"
  ffmpeg -v error -y -ss "$start" -i "$in" -t "$len" -map 0:v:0 -map 0:a:0 \
         -c copy -map_metadata -1 -map_chapters -1 -movflags +faststart "$out"
}

M="$SRC/Movies"
T="$SRC/TV Shows/Shaun the Sheep/Season 3"

# Naming review: a release folder named the way downloads are.
clip "$M/Stick Man/Stick Man (HD).mp4" \
     "$OUT/incoming/Stick.Man.2015.1080p.WEB-DL.x264-GRP/Stick.Man.2015.1080p.WEB-DL.x264-GRP.mp4"

# Merge review and the open folder: three parts of one movie.
for n in 1 2 3; do
  clip "$M/Thicker then Water/Thicker then Water.mp4" \
       "$OUT/incoming/Thicker then Water/Thicker then Water - Part $n.mp4" $((60 + (n-1)*PART)) "$PART"
done

# Metadata review: a single file in a folder that is already named.
clip "$M/Along Came Auntie/Along Came Auntie.mp4" \
     "$OUT/incoming/Along Came Auntie (1926)/Along Came Auntie (1926).mp4"

# Library: proper names, no tags.
clip "$M/Stick Man/Stick Man (HD).mp4"               "$OUT/library/Stick Man (2015).mp4"
clip "$M/Along Came Auntie/Along Came Auntie.mp4"    "$OUT/library/Along Came Auntie (1926).mp4"
for f in "Laurel & Hardy_ They Go Boom/Laurel & Hardy_ They Go Boom.mp4"; do
  clip "$M/$f" "$OUT/library/Laurel & Hardy - They Go Boom (1929).mp4"
done
n=0
for t in "01 The Stand Off" "02 The Coconut" "03 The Shepherd" "04 You Missed A Bit"; do
  n=$((n+1))
  clip "$T/$t.mp4" "$OUT/library/Shaun the Sheep/Season 3/Shaun the Sheep - S03E0$n - ${t#* }.mp4" 20 25
done

echo "Scratch library ready: $OUT"
du -sh "$OUT"
find "$OUT" -type f | sed "s|$OUT/||" | sort
