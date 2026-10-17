#!/bin/bash
#
#  make-test-library.sh
#
#             Media Metadata Manager
#                       M3
#  Created by: Hans Hoffmeister on 10/11/2026.
#
# Builds a small, throwaway library for testing M3 by hand or with a test agent.
# Every title, studio and year here is made up. Each video is a one second
# clip of a few kilobytes, so the whole tree is tiny and can be rebuilt at will.
#
# Usage:
#   Tools/make-test-library.sh [folder] [--reset]
#
#   folder    where to build it (default: ~/xCode/M3-TestLibrary)
#   --reset   delete the folder first (only if it contains the marker file
#             this script writes, so it can never wipe a real library)
#
# What you get:
#   staging/     stands in for "Ready for Media Library" (a library root)
#   incoming/    stands in for an Intake incoming folder
#   dropfolder/  a folder to drag from Finder into the Queue
#   README.txt   the M3 settings to use and the checks to make
#
# Needs ffmpeg (with libx264 and aac).

set -euo pipefail

ROOT="$HOME/xCode/M3-TestLibrary"
RESET=0
for arg in "$@"; do
    case "$arg" in
        --reset) RESET=1 ;;
        *) ROOT="$arg" ;;
    esac
done

MARKER=".m3-test-library"
# The path to print in the README (set when building through a mount whose path differs from the real one).
SHOWN="${M3_DISPLAY_ROOT:-$ROOT}"

command -v ffmpeg >/dev/null || { echo "ffmpeg is required." >&2; exit 1; }

if [ -e "$ROOT" ]; then
    if [ "$RESET" -eq 1 ]; then
        [ -f "$ROOT/$MARKER" ] || { echo "Refusing to delete $ROOT: it is not a test library made by this script." >&2; exit 1; }
        rm -rf "$ROOT"
    elif [ -n "$(ls -A "$ROOT" 2>/dev/null)" ]; then
        echo "$ROOT already has files. Use --reset to rebuild it." >&2
        exit 1
    fi
fi

mkdir -p "$ROOT"
touch "$ROOT/$MARKER"

# clip <output file> [key=value ...]  -- a one second video+audio clip with the given tags
clip() {
    local out="$1"; shift
    local meta=()
    for kv in "$@"; do meta+=(-metadata "$kv"); done
    mkdir -p "$(dirname "$out")"
    ffmpeg -hide_banner -loglevel error -y \
        -f lavfi -i "color=c=0x305070:s=160x90:r=10:d=1" \
        -f lavfi -i "sine=frequency=440:d=1" \
        -c:v libx264 -pix_fmt yuv420p -c:a aac -b:a 32k -shortest \
        "${meta[@]+"${meta[@]}"}" -movflags +faststart "$out"
}

S="$ROOT/staging"
I="$ROOT/incoming"
D="$ROOT/dropfolder"

# ---- staging: finished files with different amounts of missing metadata ----
clip "$S/Sample Title One (2020)/Sample Title One (2020).mp4"   title="Sample Title One"   date=2020
clip "$S/Sample Title Two (2021)/Sample Title Two (2021).mp4"   title="Sample Title Two"
clip "$S/Sample Title Three/Sample Title Three.mp4"
clip "$S/Sample Title Four (2019)/Sample Title Four (2019).m4v" title="Sample Title Four"  date=2019
clip "$S/random_video_0007/random_video_0007.mp4"
clip "$S/Sample Show/Season 01/Sample Show S01E01.mp4"          title="Pilot" show="Sample Show" season_number=1 episode_sort=1
# A file sitting loose in the staging root (no folder of its own).
clip "$S/Loose Staged File.mp4"                                 title="Loose Staged File"

# ---- incoming: Intake releases ----
# Single file in a release folder, studio in brackets, year missing.
clip "$I/Sample Title Five [Example Studio] ()/scene.mp4"
# Two parts of one release (merge candidates).
clip "$I/Sample Title Six [Example Studio] (2023)/Sample Title Six - Part 1.mp4"
clip "$I/Sample Title Six [Example Studio] (2023)/Sample Title Six - Part 2.mp4"
# A download still in progress: the .part file must be ignored.
clip "$I/Sample Title Seven (2022)/Sample Title Seven.mp4"
echo "partial" > "$I/Sample Title Seven (2022)/Sample Title Seven.mp4.part"
# Scene-style name.
clip "$I/Sample.Title.Eight.2021.1080p.WEB-DL.x264-GRP/sample.title.eight.mp4"
# Nested folders.
clip "$I/Nested Release/Disc 1/a.mp4"
clip "$I/Nested Release/Disc 2/b.mp4"
# A loose file straight in the incoming folder.
clip "$I/Loose Incoming File.mp4"

# ---- dropfolder: drag this folder into the Queue ----
clip "$D/Dropped Release/First.mp4"
clip "$D/Dropped Release/Second.mp4"
clip "$D/Dropped Release/Third.mp4"
clip "$D/Single Dropped File.mp4"

cat > "$ROOT/README.txt" <<EOF
M3 test library (made by Tools/make-test-library.sh). Everything in here is
made up and safe to change. Rebuild with: Tools/make-test-library.sh "$SHOWN" --reset

Point M3 at it first (Preferences > Sources):
  Media Locations > Staging folder        $SHOWN/staging
  Media Locations > Deliver automatically OFF (then try ON)
  Media Intake    > Incoming Folders      $SHOWN/incoming
Use a throwaway default destination too, never your real library.

Before a test, save the state:   Tools/test-library-state.sh "$SHOWN" > before.txt
After it:                        Tools/test-library-state.sh "$SHOWN" > after.txt ; diff before.txt after.txt

Checks:
 1. Intake > Scan Now finds the release folders and the loose file (not the .part file); Reset Scan then scan again
    adds nothing twice.
 2. Drag dropfolder/Dropped Release into the Queue: one folder row with 3 files under it.
    Drag Single Dropped File.mp4: one row.
 3. Add everything in staging to a Queue (Search Metadata, Set output filename on): no new
    files or folders appear; files are edited and renamed where they sit; random_video_0007
    keeps its name (no title tag); nothing moves out of staging.
 4. Run step 3 a second time: before/after listings are identical.
 5. Library scan on staging: lists every file missing Title, Release Date, Rating or Studio.
EOF

echo "Built $ROOT ($(find "$ROOT" -type f -name '*.mp4' -o -type f -name '*.m4v' | wc -l | tr -d ' ') videos)."
