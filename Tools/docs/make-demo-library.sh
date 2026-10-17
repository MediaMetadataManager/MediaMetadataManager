#!/bin/bash
#
#  make-demo-library.sh
#
#             Media Metadata Manager
#                       M3
#  Created by: Hans Hoffmeister on 10/16/2026.
#
# Builds a small demo library for taking documentation screenshots of M3.
# Every title, studio and year is made up; nothing here is a real work.
# The clips are a few seconds of test pattern, so the whole tree is only a few MB.
#
# Usage:
#   Tools/docs/make-demo-library.sh [folder] [--reset]
#
#   folder    where to build it (default: ~/xCode/M3-DemoLibrary)
#   --reset   delete the folder first (only if it holds the marker file this
#             script writes, so it can never wipe a real library)
#
# What you get:
#   incoming/    use as the Incoming Folder (Media Intake)
#   staging/     use as Ready for Media Library (Media Locations)
#   library/     point Library Scan at this (some files missing tags)
#   dropfolder/  drag items from here into the Queue
#   README.txt   the settings to use and what each item shows
#
# Needs ffmpeg (with libx264 and aac).

set -euo pipefail

ROOT="$HOME/xCode/M3-DemoLibrary"
RESET=0
for arg in "$@"; do
    case "$arg" in
        --reset) RESET=1 ;;
        *) ROOT="$arg" ;;
    esac
done

MARKER=".m3-demo-library"
SHOWN="${M3_DISPLAY_ROOT:-$ROOT}"

command -v ffmpeg >/dev/null || { echo "ffmpeg is required." >&2; exit 1; }

if [ -e "$ROOT" ]; then
    if [ "$RESET" -eq 1 ]; then
        [ -f "$ROOT/$MARKER" ] || { echo "Refusing to delete $ROOT: it is not a demo library made by this script." >&2; exit 1; }
        rm -rf "$ROOT"
    elif [ -n "$(ls -A "$ROOT" 2>/dev/null)" ]; then
        echo "$ROOT already has files. Use --reset to rebuild it." >&2
        exit 1
    fi
fi

mkdir -p "$ROOT"
touch "$ROOT/$MARKER"

# clip <output file> [key=value ...] -- a 4 second test-pattern video with sound and the given tags.
# Every clip is encoded the same way so any of them can be merged losslessly with any other.
clip() {
    local out="$1"; shift
    local meta=()
    for kv in "$@"; do meta+=(-metadata "$kv"); done
    mkdir -p "$(dirname "$out")"
    ffmpeg -hide_banner -loglevel error -y \
        -f lavfi -i "testsrc2=s=480x270:r=24:d=4" \
        -f lavfi -i "sine=frequency=440:d=4" \
        -c:v libx264 -b:v 300k -pix_fmt yuv420p -c:a aac -b:a 64k -shortest \
        "${meta[@]+"${meta[@]}"}" -movflags +faststart "$out"
}

S="$ROOT/staging"
I="$ROOT/incoming"
D="$ROOT/dropfolder"
L="$ROOT/library"

# ---- incoming: Intake releases ----
# A single file with studio and year in the folder name.
clip "$I/Sample Title One [Example Studio] (2020)/Sample Title One.mp4"
# A single file, no studio.
clip "$I/Sample Title Two (2021)/Sample Title Two.mp4"
# Three numbered parts of one movie (a clear merge candidate).
for n in 1 2 3; do
    clip "$I/Sample Title Three [Example Studio] (2019)/Sample Title Three - Part $n.mp4"
done
# A folder that already holds the merge of its parts (shows "Already merged: review").
clip "$I/Sample Title Four [Example Studio] (2022)/Sample Title Four - Part 1.mp4"
clip "$I/Sample Title Four [Example Studio] (2022)/Sample Title Four - Part 2.mp4"
LIST="$(mktemp)"
printf "file '%s'\nfile '%s'\n" \
    "$I/Sample Title Four [Example Studio] (2022)/Sample Title Four - Part 1.mp4" \
    "$I/Sample Title Four [Example Studio] (2022)/Sample Title Four - Part 2.mp4" > "$LIST"
ffmpeg -hide_banner -loglevel error -y -f concat -safe 0 -i "$LIST" -c copy -movflags +faststart \
    "$I/Sample Title Four [Example Studio] (2022)/Sample Title Four.mp4"
rm -f "$LIST"
# A scene-style name.
clip "$I/Sample.Title.Five.2021.1080p.WEB-DL.x264-GRP/sample.title.five.mp4"
# TV episodes dropped loose into the incoming folder (go to the TV Shows tab).
clip "$I/Sample Show S01E01.mp4"
clip "$I/Sample Show S01E02.mp4"
clip "$I/Sample.Show.S01E03.720p.WEB-DL.x264-GRP.mp4"
# A loose movie file.
clip "$I/Loose Sample Movie.mp4"

# ---- dropfolder: drag these into the Queue ----
clip "$D/Dropped Sample Movie.mp4"
clip "$D/Dropped Release/Part 1.mp4"
clip "$D/Dropped Release/Part 2.mp4"

# ---- staging: Ready for Media Library, with two finished items ----
clip "$S/Sample Title Nine [Example Studio] (2018)/Sample Title Nine [Example Studio] (2018).mp4" title="Sample Title Nine" date=2018
clip "$S/Sample Show/Season 01/Sample Show S01E01.mp4" title="Pilot" show="Sample Show" season_number=1 episode_sort=1

# ---- library: for the Library Scan window (different amounts of missing tags) ----
clip "$L/Sample Title Ten (2017).mp4"        title="Sample Title Ten" date=2017
clip "$L/Sample Title Eleven (2016).mp4"     title="Sample Title Eleven"
clip "$L/Sample Title Twelve.mp4"
clip "$L/Sample Title Thirteen (2015).mp4"   date=2015
clip "$L/Sample Title Fourteen.m4v"
clip "$L/Sample Title Fifteen (2014).mp4"    title="Sample Title Fifteen" date=2014
clip "$L/Sample Show/Season 01/Sample Show S01E02.mp4" title="Second Episode" show="Sample Show" season_number=1 episode_sort=2

cat > "$ROOT/README.txt" <<EOF
M3 demo library (made-up names only), built by Tools/docs/make-demo-library.sh

Folder: $SHOWN

Settings to use while taking screenshots (back up your own first: Tools/config-backup.sh backup):
  Preferences > Sources > Media Intake > Incoming Folders:  $SHOWN/incoming
  Preferences > Sources > Media Locations > Staging folder:  $SHOWN/staging
  Library Scan folder:                                       $SHOWN/library
  Drag into the Queue:                                       $SHOWN/dropfolder

What the incoming folder shows:
  Sample Title One / Two      single files waiting for naming
  Sample Title Three          three numbered parts (Merge Review)
  Sample Title Four           parts plus a merged file ("Already merged: review")
  Sample.Title.Five...        scene-style name
  Sample Show S01E01..E03     loose TV episodes (TV Shows tab)
  Loose Sample Movie          a loose file

Restore your own settings afterwards: quit M3, then Tools/config-backup.sh restore
EOF

echo "Demo library built in $ROOT"
du -sh "$ROOT" | cut -f1
