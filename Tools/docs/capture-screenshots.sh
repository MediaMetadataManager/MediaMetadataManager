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
#      (then a second launch with the stand-in library server, Tools/SampleLibraryServer, installed, for
#      the shots that show a library server; it is removed again afterwards)
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

# The shots that show a library server (Tools/SampleLibraryServer). They need that plugin loaded, and
# the plain Providers tab must be photographed without it, so they run in a second launch.
SERVER_SHOTS="library-scan-server,prefs-providers-library-servers,prefs-custom-sources-library-servers"
SAMPLE="/Users/Shared/M3-Sample-Library"        # copy of the made-up demo movies for the stand-in to list
SERVER_PROJ="$REPO/Tools/SampleLibraryServer/SampleLibraryServer.xcodeproj"

FIRST_ONLY=""; SECOND_ONLY=""; RUN_FIRST=1; RUN_SECOND=1
if [ -n "$ONLY" ]; then
    RUN_FIRST=0; RUN_SECOND=0
    for s in $(echo "$ONLY" | tr ',' ' '); do
        case ",$SERVER_SHOTS," in
            *",$s,"*) SECOND_ONLY="${SECOND_ONLY:+$SECOND_ONLY,}$s"; RUN_SECOND=1 ;;
            *)        FIRST_ONLY="${FIRST_ONLY:+$FIRST_ONLY,}$s"; RUN_FIRST=1 ;;
        esac
    done
fi

# run_app <shots> [extra arguments]: starts M3 in screenshot mode and waits for it to finish.
run_app() {
    local only="$1"; shift
    "$APP/Contents/MacOS/M3" -M3DocsScreenshots YES -M3ScreenshotDir "$OUT" -M3DemoRoot "$DEMO" -M3MediaRoot "$MEDIA" \
        ${only:+-M3ScreenshotOnly "$only"} "$@" >> "$LOG" 2>&1 &
    local pid=$!
    tail -n 0 -f "$LOG" 2>/dev/null | grep --line-buffered '^\[screenshots\]' &
    local tailpid=$!
    for _ in $(seq 1 300); do   # up to 10 minutes: the Library scan run edits files for real
        kill -0 "$pid" 2>/dev/null || break
        sleep 2
    done
    if kill -0 "$pid" 2>/dev/null; then
        echo "Took too long; stopping M3. Last lines of the app's output:"
        tail -15 "$LOG"
        kill "$pid"
    fi
    kill "$tailpid" 2>/dev/null || true
}

[ "$RUN_FIRST" = 1 ] && run_app "$FIRST_ONLY"

if [ "$RUN_SECOND" = 1 ]; then
    echo "== Library server shots (second launch, stand-in library server installed)"
    if [ ! -d "$SERVER_PROJ" ]; then
        echo "(no stand-in plugin at $SERVER_PROJ: the library server shots are left out)"
    elif [ ! -d "$DEMO/library" ]; then
        echo "(no demo library at $DEMO: the library server shots are left out)"
    else
        # The made-up demo movies (no TV folder); a copy, so the run before this one cannot have changed them.
        rm -rf "$SAMPLE"; mkdir -p "$SAMPLE"
        rsync -a --exclude 'Sample Show' "$DEMO/library/" "$SAMPLE/"
        # The plugin's own build step copies the bundle to the Plugins folder (clean at this point).
        if xcodebuild -project "$SERVER_PROJ" -scheme SampleLibraryServer -configuration Release \
               -derivedDataPath "$DERIVED-sample" \
               CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
               build > "$DERIVED-sample.log" 2>&1 && [ -d "$SUPPORT/Plugins/SampleLibraryServer.bundle" ]; then
            run_app "${SECOND_ONLY:-$SERVER_SHOTS}" -SampleLibraryFolder "$SAMPLE"
        else
            grep -E "error:" "$DERIVED-sample.log" | sort -u | head -10
            echo "Could not build or install the stand-in plugin (log: $DERIVED-sample.log); its shots are left out."
        fi
        rm -rf "$SUPPORT/Plugins/SampleLibraryServer.bundle"
    fi
fi

echo
echo "Pictures: $OUT"
ls -1 "$OUT" | sed 's/^/  /'
