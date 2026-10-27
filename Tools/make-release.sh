#!/bin/bash
#
#  make-release.sh
#
#             Media Metadata Manager
#                       M3
#  Created by: Hans Hoffmeister on 10/10/2026.
#
#
# Build a release zip and (re)generate the Sparkle appcast.
#
#   Tools/make-release.sh <version> [public-repo-clone]
#   e.g. Tools/make-release.sh 1.0.1 ~/xCode/MediaMetadataManager-public
#
# <version> becomes MARKETING_VERSION (shown to users) and the build number
# (CURRENT_PROJECT_VERSION, which Sparkle compares) is set to the same value,
# so versions must always go UP: 1.0.0 -> 1.0.1 -> 1.1.0.
#
# Steps: set version -> Release build (ad hoc signed, or Developer ID if you
# set M3_SIGN_IDENTITY) -> add the shipped plugins (Plex, Jellyfin), verify nothing else or personal config is inside the app ->
# zip -> release notes -> appcast in <clone>/docs/appcast.xml.
# It does NOT push or publish; it prints the commands for that.
#
# Needs Xcode (xcodebuild) and the Sparkle tools; run Tools/setup-sparkle.sh first.

set -euo pipefail

DEV="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"
PUB="${2:-}"
TAG="v$VERSION"
[ -n "$VERSION" ] || { echo "usage: Tools/make-release.sh <version> [public-repo-clone]"; exit 2; }
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || { echo "version must look like 1.0.1"; exit 2; }

cd "$DEV"
# Every released zip is kept in release-archive/ (not in git, not public) so the
# appcast can keep older entries. A version that is already archived has been
# released and must never be rebuilt: users hold the old bytes and signature.
ARCHIVE="$DEV/release-archive"
if [ -e "$ARCHIVE/MediaMetadataManager-$VERSION.zip" ] && [ "${M3_REBUILD:-0}" != "1" ]; then
    echo "error: $VERSION is already in release-archive/ (already released). Use a new version number."
    echo "       (Only if it was never published: M3_REBUILD=1 Tools/make-release.sh $VERSION ...)"
    exit 1
fi
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "error: uncommitted changes. Commit first so the release matches the repo."
    exit 1
fi
grep -q SUPublicEDKey Info.plist || { echo "error: run Tools/setup-sparkle.sh first (no SUPublicEDKey in Info.plist)."; exit 1; }
command -v xcodebuild >/dev/null || { echo "error: xcodebuild not found (run this on the Mac with Xcode)."; exit 1; }

BIN="$(find ~/Library/Developer/Xcode/DerivedData -type d -path '*artifacts/sparkle/Sparkle/bin' 2>/dev/null | head -1)"
[ -x "$BIN/generate_appcast" ] || { echo "error: Sparkle tools not found; build once in Xcode."; exit 1; }

OUT="$DEV/build-release"
rm -rf "$OUT"; mkdir -p "$OUT/derived" "$OUT/updates"

# 1. version
sed -i '' -E "s/(MARKETING_VERSION = )[0-9.]+;/\1$VERSION;/; s/(CURRENT_PROJECT_VERSION = )[0-9.]+;/\1$VERSION;/" M3.xcodeproj/project.pbxproj

# 2. build
IDENT="${M3_SIGN_IDENTITY:--}"
echo "Building $VERSION (signing identity: ${IDENT/#-/ad hoc})..."
xcodebuild -project M3.xcodeproj -scheme M3 -configuration Release \
    -derivedDataPath "$OUT/derived" \
    CODE_SIGN_IDENTITY="$IDENT" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
    build | tail -5
APP="$OUT/derived/Build/Products/Release/M3.app"
[ -d "$APP" ] || { echo "error: build did not produce M3.app"; exit 1; }

# 2b. the paid library-server plugins ship inside the app (Contents/PlugIns),
# locked until a licence key is entered. ONLY the names listed here may ship;
# anything else (a private plugin) must never end up in a release. The plugin
# projects live next to this one (override with M3_PLUGIN_PROJECTS).
SHIPPED_PLUGINS="JellyfinPlugin PlexPlugin"
PLUGIN_PROJECTS="${M3_PLUGIN_PROJECTS:-$(dirname "$DEV")}"
mkdir -p "$APP/Contents/PlugIns"
for P in $SHIPPED_PLUGINS; do
    PROJ="$PLUGIN_PROJECTS/$P/$P.xcodeproj"
    [ -d "$PROJ" ] || { echo "error: $PROJ not found (set M3_PLUGIN_PROJECTS to the folder that holds the plugin projects)."; exit 1; }
    echo "Building $P..."
    PLOG="$OUT/build-$P.log"
    if ! xcodebuild -project "$PROJ" -scheme "$P" -configuration Release \
        -derivedDataPath "$OUT/derived-$P" \
        CODE_SIGN_IDENTITY="$IDENT" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
        build > "$PLOG" 2>&1; then
        echo "error: $P failed to build. The compiler said:"
        grep -E "error:|fatal error|BUILD FAILED" "$PLOG" | awk '!seen[$0]++' | head -30
        echo "Full log: $PLOG"
        exit 1
    fi
    tail -3 "$PLOG"
    BUNDLE="$OUT/derived-$P/Build/Products/Release/$P.bundle"
    [ -d "$BUNDLE" ] || { echo "error: $P did not produce $P.bundle"; exit 1; }
    ditto "$BUNDLE" "$APP/Contents/PlugIns/$P.bundle"
    codesign --force --sign "$IDENT" "$APP/Contents/PlugIns/$P.bundle"
done
# The app's seal changed, so sign it again (inner code first, then the app).
codesign --force --sign "$IDENT" --preserve-metadata=identifier,entitlements,flags,runtime "$APP"

# 3. the shipped app carries exactly the plugins listed above and no personal config
FOUND_PLUGINS="$(ls "$APP/Contents/PlugIns" | sort | tr '\n' ' ')"
EXPECTED_PLUGINS="$(for P in $SHIPPED_PLUGINS; do echo "$P.bundle"; done | sort | tr '\n' ' ')"
if [ "$FOUND_PLUGINS" != "$EXPECTED_PLUGINS" ]; then
    echo "error: Contents/PlugIns holds [$FOUND_PLUGINS], expected [$EXPECTED_PLUGINS]. Not releasing."; exit 1
fi
if find "$APP" -name '*.bundle' -not -path "$APP/Contents/PlugIns/*" | grep -qi plugin; then
    echo "error: a plugin bundle is inside the app outside Contents/PlugIns. Not releasing."; exit 1
fi
# (pattern built from pieces so this script does not trip the export scan itself)
PAT='hot''mov''ies|po''rn|hans''hoff''meister|private''relay'
if grep -rIl -i -E "$PAT" "$APP" >/dev/null 2>&1; then
    echo "error: personal or plugin-specific text found inside the app. Not releasing."
    grep -rIl -i -E "$PAT" "$APP" | head
    exit 1
fi
codesign --verify --deep --strict "$APP" && echo "Signature verifies."

# 4. zip
ZIP="$OUT/updates/MediaMetadataManager-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# 5. release notes next to the zip (Sparkle shows <zipname>.html)
{
  echo "<html><body style=\"font-family:-apple-system;font-size:13px\">"
  echo "<h3>Media Metadata Manager $VERSION</h3><ul>"
  awk '
    function flush() { if (cur != "") { gsub(/\*\*/,"",cur); gsub(/&/,"\\&amp;",cur); gsub(/</,"\\&lt;",cur); print "<li>" cur "</li>"; cur="" } }
    /^## Unreleased/ { f=1; next }
    /^## /           { flush(); f=0 }
    f && /^- /       { flush(); cur=substr($0,3); next }
    f && /^[ \t]+[^ \t]/ && cur != "" { t=$0; sub(/^[ \t]+/,"",t); cur=cur " " t; next }
    f                { flush() }
    END              { flush() }
  ' RELEASE_NOTES.md
  echo "</ul></body></html>"
} > "${ZIP%.zip}.html"

# 6. appcast (also restores earlier releases from release-archive/)
mkdir -p "$ARCHIVE"
bash "$DEV/Tools/make-appcast.sh" "$VERSION"
# (The appcast is NOT copied into the public clone here: export-public.sh would
# commit it with the next snapshot and it could go live before the release zip.
# Tools/publish-appcast.sh does it after checking the zip downloads.)

# 7. archive this release (only now that everything above succeeded)
cp "$ZIP" "${ZIP%.zip}.html" "$ARCHIVE"/

echo
echo "Done. Zip: $ZIP"
echo
PUBARG="${PUB:-<public-clone>}"
echo "Next (you run these, in this order):"
echo "  git add M3.xcodeproj && git commit -m 'Version $VERSION'       # dev repo"
echo "  Tools/export-public.sh $PUBARG                                  # snapshot"
echo "  git -C $PUBARG push                                             # source only"
echo "  gh release create $TAG '$ZIP' --repo MediaMetadataManager/MediaMetadataManager --title '$VERSION' --notes '...'"
echo "      (or on github.com: Releases > Draft a new release, tag $TAG, attach the zip, Publish)"
echo "  Tools/publish-appcast.sh $VERSION $PUBARG                       # checks the zip downloads, then publishes the feed"
echo "Release first, appcast last, so no one is offered an update that 404s."
echo "Older releases in release-archive/ were included, so the appcast lists them too."
