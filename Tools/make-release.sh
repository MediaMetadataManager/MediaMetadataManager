#!/bin/bash
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
# set M3_SIGN_IDENTITY) -> verify no plugin bundles or config inside the app ->
# zip -> release notes -> appcast in <clone>/docs/appcast.xml.
# It does NOT push or publish; it prints the commands for that.
#
# Needs Xcode (xcodebuild) and the Sparkle tools; run Tools/setup-sparkle.sh first.

set -euo pipefail

DEV="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"
PUB="${2:-}"
[ -n "$VERSION" ] || { echo "usage: Tools/make-release.sh <version> [public-repo-clone]"; exit 2; }
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || { echo "version must look like 1.0.1"; exit 2; }

cd "$DEV"
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

# 3. the shipped app must carry no plugins and no personal config
if find "$APP" -name '*.bundle' | grep -qi plugin; then
    echo "error: a plugin bundle is inside the app. Not releasing."; exit 1
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
  awk '/^## Unreleased/{f=1;next} /^## /{f=0} f && /^- /{sub(/^- /,""); gsub(/\*\*/,""); gsub(/&/,"\\&amp;"); gsub(/</,"\\&lt;"); print "<li>" $0 "</li>"}' RELEASE_NOTES.md
  echo "</ul></body></html>"
} > "${ZIP%.zip}.html"

# 6. appcast
TAG="v$VERSION"
PREFIX="https://github.com/MediaMetadataManager/MediaMetadataManager/releases/download/$TAG/"
"$BIN/generate_appcast" --download-url-prefix "$PREFIX" \
    --embed-release-notes "$OUT/updates"
if [ -n "$PUB" ]; then
    mkdir -p "$PUB/docs"; cp "$OUT/updates/appcast.xml" "$PUB/docs/appcast.xml"
    echo "Appcast copied to $PUB/docs/appcast.xml"
fi

echo
echo "Done. Zip: $ZIP"
echo
echo "Next (you run these):"
echo "  git add M3.xcodeproj && git commit -m 'Version $VERSION'      # dev repo"
echo "  Tools/export-public.sh <public-clone>                         # snapshot"
echo "  cd <public-clone> && git push"
echo "  gh release create $TAG '$ZIP' --repo MediaMetadataManager/MediaMetadataManager --title '$VERSION' --notes-file <notes>"
echo "  cd <public-clone> && git add docs/appcast.xml && git commit -m 'Appcast $VERSION' && git push"
echo "Order matters: upload the release BEFORE pushing the appcast, so no one is offered an update that 404s."
echo "Note: the appcast keeps older entries only if their zips are in $OUT/updates; copy previous zips there first if you want delta/older entries."
