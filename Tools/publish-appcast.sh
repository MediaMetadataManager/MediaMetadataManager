#!/bin/bash
#
# Publish the Sparkle appcast built by Tools/make-release.sh.
#
#   Tools/publish-appcast.sh <version> <public-repo-clone>
#
# Run it AFTER the GitHub Release for that version is published. It refuses to
# continue unless the release zip actually downloads (HTTP 200), so nobody is
# ever offered an update that 404s. Then it copies build-release/updates/
# appcast.xml to <clone>/docs/appcast.xml, commits and pushes.

set -euo pipefail

DEV="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"; PUB="${2:-}"
[ -n "$VERSION" ] && [ -n "$PUB" ] || { echo "usage: Tools/publish-appcast.sh <version> <public-repo-clone>"; exit 2; }
PUB="$(cd "$PUB" && pwd)"
[ -d "$PUB/.git" ] || { echo "error: $PUB is not a git clone"; exit 2; }

APPCAST="$DEV/build-release/updates/appcast.xml"
[ -f "$APPCAST" ] || { echo "error: $APPCAST not found. Run Tools/make-release.sh first."; exit 1; }
grep -q "<sparkle:version>$VERSION</sparkle:version>" "$APPCAST" \
    || { echo "error: the built appcast has no $VERSION entry (is it from another build?)"; exit 1; }

URL="https://github.com/MediaMetadataManager/MediaMetadataManager/releases/download/v$VERSION/MediaMetadataManager-$VERSION.zip"
CODE="$(curl -sIL -o /dev/null -w '%{http_code}' "$URL" || true)"
if [ "$CODE" != "200" ]; then
    echo "error: $URL returned HTTP $CODE."
    echo "Publish the GitHub Release (not a draft) with the zip attached first."
    exit 1
fi
echo "Release zip downloads (HTTP 200)."

mkdir -p "$PUB/docs"
cp "$APPCAST" "$PUB/docs/appcast.xml"
cd "$PUB"
git add docs/appcast.xml
if git diff --cached --quiet; then echo "Appcast already up to date."; exit 0; fi
git commit -q -m "Appcast $VERSION"
git push
echo "Appcast $VERSION published. GitHub Pages updates in a minute or two."
