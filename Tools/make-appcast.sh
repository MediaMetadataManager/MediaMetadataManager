#!/bin/bash
#
# (Re)generate the Sparkle appcast from the zips in build-release/updates plus
# every earlier release kept in release-archive/. Called by make-release.sh; can
# also be run on its own to rebuild the appcast without rebuilding the app:
#
#   Tools/make-appcast.sh <newest-version>
#
# Result: build-release/updates/appcast.xml (publish it with publish-appcast.sh).
#
# Deltas are switched off (--maximum-deltas 0): they would be extra files to
# upload to every release, and the zips are small. Each entry's download URL is
# pointed at the GitHub Release that actually holds its zip (v<its own version>).

set -euo pipefail

DEV="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "usage: Tools/make-appcast.sh <newest-version>"; exit 2; }

BIN="$(find ~/Library/Developer/Xcode/DerivedData -type d -path '*artifacts/sparkle/Sparkle/bin' 2>/dev/null | head -1)"
[ -x "$BIN/generate_appcast" ] || { echo "error: Sparkle tools not found; build once in Xcode."; exit 1; }

OUT="$DEV/build-release/updates"
ARCHIVE="$DEV/release-archive"
mkdir -p "$OUT" "$ARCHIVE"

# earlier releases (never overwrites what is already in OUT)
for f in "$ARCHIVE"/MediaMetadataManager-*.zip "$ARCHIVE"/MediaMetadataManager-*.html; do
    [ -e "$f" ] || continue
    [ -e "$OUT/$(basename "$f")" ] || cp "$f" "$OUT/"
done
[ -f "$OUT/MediaMetadataManager-$VERSION.zip" ] || { echo "error: no MediaMetadataManager-$VERSION.zip in $OUT"; exit 1; }
rm -f "$OUT"/*.delta "$OUT/appcast.xml"   # generate_appcast would otherwise carry old entries (and deltas) forward

BASE="https://github.com/MediaMetadataManager/MediaMetadataManager/releases/download"
"$BIN/generate_appcast" --maximum-deltas 0 --download-url-prefix "$BASE/v$VERSION/" \
    --embed-release-notes "$OUT"

# point each older entry at its own release
for z in "$OUT"/MediaMetadataManager-*.zip; do
    v="$(basename "$z" .zip)"; v="${v#MediaMetadataManager-}"
    [ "$v" = "$VERSION" ] && continue
    perl -pi -e "s#\\Q$BASE/v$VERSION/MediaMetadataManager-$v.zip\\E#$BASE/v$v/MediaMetadataManager-$v.zip#g" "$OUT/appcast.xml"
done

echo "Appcast entries:"
grep -E "<sparkle:version>|enclosure url" "$OUT/appcast.xml" | sed -E 's/length=.*//' | sed 's/^ *//'
