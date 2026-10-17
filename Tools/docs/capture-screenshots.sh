#!/bin/bash
#
#  capture-screenshots.sh
#
#             Media Metadata Manager
#                       M3
#  Created by: Hans Hoffmeister on 10/17/2026.
#
# Takes the documentation screenshots by running the app itself (a Debug build with the
# screenshot mode in Classes/DocsScreenshots.swift) against a made-up demo library.
#
# Usage (Terminal, from the repository folder):
#   Tools/docs/capture-screenshots.sh                    all shots
#   Tools/docs/capture-screenshots.sh --only prefs-general,message-log
#   Tools/docs/capture-screenshots.sh --out ~/Desktop/shots
#
# What it does, in order:
#   1. builds the demo library in /Users/Shared/M3-Demo (made-up titles, neutral path) and
#      copies the clips of real titles (~/xCode/M3-Media2-Library, made by
#      Tools/docs/make-media2-library.sh from the media volume) to /Users/Shared/M3-Media2
#   2. builds the Debug app (no plugins, nothing from your own settings)
#   3. saves your settings, starts M3 with clean ones, takes the pictures, quits
#   4. puts your settings back, even if something fails
#
# The pictures go to ~/xCode/M3-Screenshots/new (or --out). They are NOT copied into
# the guides: look at them first (and the privacy check in the m3-docs-screenshots skill).
#
# First run: macOS asks to let Terminal record the screen. Allow it, then run again.
# Quit M3 first. Needs Xcode and ffmpeg.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
DEMO="/Users/Shared/M3-Demo"
MEDIA="/Users/Shared/M3-Media2"                 # working copy of the clips: the run edits them in place
MEDIA_READY="$HOME/xCode/M3-Media2-Library"     # the clips as made by make-media2-library.sh
OUT="$HOME/xCode/M3-Screenshots/new"
ONLY=""
DERIVED="$HOME/Library/Caches/M3-screenshots-build"
DOMAIN="com.quattromeister.M3"
SUPPORT="$HOME/Library/Application Support/M3"
STORE="$HOME/Documents/M3-config-backups"

while [ $# -gt 0 ]; do
    case "$1" in
        --only) ONLY="$2"; shift 2 ;;
        --out)  OUT="$2"; shift 2 ;;
        *) sed -n '2,25p' "$0"; exit 2 ;;
    esac
done

pgrep -x M3 >/dev/null && { echo "Please quit M3 first."; exit 1; }
command -v xcodebuild >/dev/null || { echo "xcodebuild not found (run this on the Mac with Xcode)."; exit 1; }
READY="$HOME/xCode/M3-DemoLibrary"   # an already built demo library, used when ffmpeg is not installed
if ! command -v ffmpeg >/dev/null && [ ! -f "$READY/.m3-demo-library" ]; then
    echo "ffmpeg not found (brew install ffmpeg), and there is no ready demo library at $READY."; exit 1
fi

echo "== 1/4 Demo library"
mkdir -p "$DEMO"
[ -f "$DEMO/.m3-demo-library" ] || { [ -z "$(ls -A "$DEMO")" ] || { echo "$DEMO exists and is not a demo library."; exit 1; }; }
if command -v ffmpeg >/dev/null; then
    "$REPO/Tools/docs/make-demo-library.sh" "$DEMO" --reset >/dev/null || { echo "Could not build the demo library."; exit 1; }
else
    echo "(ffmpeg not installed: copying the ready demo library from $READY)"
    [ -f "$DEMO/.m3-demo-library" ] && rm -rf "$DEMO"
    mkdir -p "$DEMO" && ditto "$READY" "$DEMO" || { echo "Could not copy the demo library."; exit 1; }
fi

if [ -d "$MEDIA_READY/library" ]; then
    mkdir -p "$MEDIA"
    rsync -a --delete --exclude '.phase2*' "$MEDIA_READY/" "$MEDIA/" || { echo "Could not copy the clips to $MEDIA."; exit 1; }
else
    echo "(no clips at $MEDIA_READY: run Tools/docs/make-media2-library.sh; the shots with real titles will be left out)"
fi

echo "== 2/4 Building the Debug app"
cd "$REPO"
xcodebuild -project M3.xcodeproj -scheme M3 -configuration Debug \
    -derivedDataPath "$DERIVED" \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
    build > "$DERIVED.log" 2>&1 || { grep -E "error:" "$DERIVED.log" | sort -u | head -20; echo "Build failed (full log: $DERIVED.log)."; exit 1; }
APP="$DERIVED/Build/Products/Debug/M3.app"
[ -x "$APP/Contents/MacOS/M3" ] || { echo "Build produced no app."; exit 1; }
find "$APP" -name '*.bundle' | grep -qi plugin && { echo "Plugins found inside the app; stopping."; exit 1; }

echo "== 3/4 Settings saved, starting clean"
"$REPO/Tools/config-backup.sh" fresh-start >/dev/null || { echo "Could not save your settings; nothing was changed."; exit 1; }
BACKUP="$(ls -1 "$STORE" | grep '^before-fresh' | tail -1)"
[ -n "$BACKUP" ] && [ -f "$STORE/$BACKUP/$DOMAIN.plist" -o -d "$STORE/$BACKUP" ] || { echo "No settings backup found; stopping."; exit 1; }

restore() {
    pkill -x M3 2>/dev/null || true
    sleep 1
    defaults delete "$DOMAIN" 2>/dev/null || true
    rm -rf "$SUPPORT"
    "$REPO/Tools/config-backup.sh" restore "$BACKUP" >/dev/null && echo "== 4/4 Your settings are back ($BACKUP)"
}
trap restore EXIT

mkdir -p "$OUT"
[ -z "$ONLY" ] && rm -f "$OUT"/*.png   # a full run starts from an empty folder, so no old picture is mistaken for a new one
LOG="$OUT/run.log"
: > "$LOG"
"$APP/Contents/MacOS/M3" -M3DocsScreenshots YES -M3ScreenshotDir "$OUT" -M3DemoRoot "$DEMO" -M3MediaRoot "$MEDIA" \
    ${ONLY:+-M3ScreenshotOnly "$ONLY"} > "$LOG" 2>&1 &
PID=$!
tail -f "$LOG" 2>/dev/null | grep --line-buffered '^\[screenshots\]' &
TAILPID=$!
for _ in $(seq 1 300); do   # up to 10 minutes: the Library scan run edits files for real
    kill -0 "$PID" 2>/dev/null || break
    sleep 2
done
if kill -0 "$PID" 2>/dev/null; then
    echo "Took too long; stopping M3. Last lines of the app's output:"
    tail -15 "$LOG"
    kill "$PID"
fi
kill "$TAILPID" 2>/dev/null || true

echo
echo "Pictures: $OUT"
ls -1 "$OUT" | sed 's/^/  /'
