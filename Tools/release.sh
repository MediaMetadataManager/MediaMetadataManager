#!/bin/bash
#
# One command for a whole release.
#
#   Tools/release.sh <version> [public-clone] [--yes] [--from <step>]
#   e.g. Tools/release.sh 1.0.2
#
# Steps, in order (each is skipped with --from <step> to resume after a failure):
#   preflight  checks nothing is half-done and the signing key matches Info.plist
#   backup     saves your own settings (Tools/config-backup.sh)
#   build      Tools/make-release.sh: version bump, Release build, zip, appcast
#   commit     moves "## Unreleased" in RELEASE_NOTES.md under this version,
#              commits "Version <version>" and pushes the dev repo
#   export     Tools/export-public.sh snapshot, pushes the public clone (source only)
#   release    creates the GitHub Release with the zip (uses `gh` if it is
#              installed and signed in; otherwise opens the page and waits)
#   appcast    Tools/publish-appcast.sh: refuses unless the zip downloads, then
#              publishes the update feed
#
# Release first, appcast last: the order is built in. Nothing is pushed until
# you answer the confirmation after the build (use --yes to skip the questions).

set -euo pipefail

DEV="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DEV"

VERSION=""; PUB=""; YES=0; FROM="preflight"
while [ $# -gt 0 ]; do
    case "$1" in
        --yes) YES=1 ;;
        --from) FROM="${2:-}"; shift ;;
        -*) echo "unknown option $1"; exit 2 ;;
        *) if [ -z "$VERSION" ]; then VERSION="$1"; else PUB="$1"; fi ;;
    esac
    shift
done
[ -n "$VERSION" ] || { sed -n '3,25p' "$0"; exit 2; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must look like 1.0.2"; exit 2; }
PUB="${PUB:-$HOME/xCode/MediaMetadataManager-public}"
[ -d "$PUB/.git" ] || { echo "error: $PUB is not a git clone of the public repo"; exit 2; }
PUB="$(cd "$PUB" && pwd)"

REPO="MediaMetadataManager/MediaMetadataManager"
TAG="v$VERSION"
ZIP="$DEV/release-archive/MediaMetadataManager-$VERSION.zip"
DATE="$(date +%Y-%m-%d)"

STEPS="preflight backup build commit export release appcast"
index_of() { local i=0 s; for s in $STEPS; do [ "$s" = "$1" ] && { echo $i; return; }; i=$((i+1)); done; echo -1; }
FROM_I="$(index_of "$FROM")"
[ "$FROM_I" -ge 0 ] || { echo "unknown step '$FROM' (steps: $STEPS)"; exit 2; }
want() { [ "$(index_of "$1")" -ge "$FROM_I" ]; }

say() { echo; echo "==> $*"; }
ask() {  # ask <question>
    [ "$YES" = 1 ] && return 0
    local a; read -r -p "$1 [y/N] " a; [ "$a" = "y" ] || [ "$a" = "Y" ]
}
version_gt() { awk -v a="$1" -v b="$2" 'BEGIN{split(a,x,".");split(b,y,".");for(i=1;i<=3;i++){if(x[i]+0>y[i]+0){exit 0}if(x[i]+0<y[i]+0){exit 1}}exit 1}'; }

# ---------------------------------------------------------------- preflight
if want preflight; then
    say "Checking everything is ready for $VERSION"
    [ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || { echo "error: dev repo is not on main"; exit 1; }
    if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
        echo "error: uncommitted changes in the dev repo. Commit them first:"; git status --short --untracked-files=no; exit 1
    fi
    if [ -n "$(git -C "$PUB" status --porcelain)" ]; then
        echo "error: the public clone has uncommitted changes:"; git -C "$PUB" status --short; exit 1
    fi
    command -v xcodebuild >/dev/null || { echo "error: xcodebuild not found (run this on the Mac with Xcode)"; exit 1; }

    LAST="$(ls release-archive/MediaMetadataManager-*.zip 2>/dev/null | sed -E 's#.*/MediaMetadataManager-(.*)\.zip#\1#' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
    if [ -n "$LAST" ]; then
        version_gt "$VERSION" "$LAST" || { echo "error: $VERSION is not newer than the last release ($LAST)"; exit 1; }
    fi
    echo "Last release: ${LAST:-none}; this one: $VERSION"

    # notes: there must be something under "## Unreleased"
    NOTES="$(awk '/^## Unreleased/{f=1;next} /^## /{f=0} f && /^- /' RELEASE_NOTES.md)"
    [ -n "$NOTES" ] || { echo "error: RELEASE_NOTES.md has no entries under '## Unreleased'. Add what changed first."; exit 1; }
    echo "Release notes ($(echo "$NOTES" | grep -c '^- ') entries):"; echo "$NOTES" | cut -c1-110

    # signing key in the Keychain must be the one the app trusts
    BIN="$(find ~/Library/Developer/Xcode/DerivedData -type d -path '*artifacts/sparkle/Sparkle/bin' 2>/dev/null | head -1)"
    [ -x "$BIN/generate_keys" ] || { echo "error: Sparkle tools not found; build once in Xcode"; exit 1; }
    KEY_PLIST="$(awk '/SUPublicEDKey/{getline; gsub(/<[^>]*>|[ \t]/,""); print; exit}' Info.plist)"
    KEY_CHAIN="$("$BIN/generate_keys" -p 2>/dev/null | tail -1 | tr -d '[:space:]')"
    [ "$KEY_PLIST" = "$KEY_CHAIN" ] || { echo "error: the Keychain signing key does not match Info.plist. Not releasing."; exit 1; }
    echo "Signing key matches Info.plist."
    echo "Remember: quit M3 before the build."
    ask "Build and release $VERSION?" || { echo "Stopped."; exit 1; }
fi

# ------------------------------------------------------------------- backup
if want backup; then
    say "Backing up your settings"
    bash "$DEV/Tools/config-backup.sh" backup
fi

# -------------------------------------------------------------------- build
if want build; then
    say "Building $VERSION"
    bash "$DEV/Tools/make-release.sh" "$VERSION" "$PUB"
fi
[ -f "$ZIP" ] || { echo "error: $ZIP not found. Run again from the build step."; exit 1; }

if want commit; then
    say "Built. Next: commit the version and publish the source."
    echo "Zip: $ZIP ($(du -h "$ZIP" | cut -f1))"
    ask "Commit 'Version $VERSION', push the dev repo and the public source, and publish the release?" || { echo "Stopped. Resume with:  Tools/release.sh $VERSION --from commit"; exit 1; }
fi

# ------------------------------------------------------------------- commit
if want commit; then
    say "Committing Version $VERSION"
    if ! grep -q "^## $VERSION (" RELEASE_NOTES.md; then
        perl -0pi -e "s/^## Unreleased\n/## Unreleased\n\n## $VERSION ($DATE)\n/m" RELEASE_NOTES.md
    fi
    git add M3.xcodeproj RELEASE_NOTES.md
    git commit -m "Version $VERSION" || echo "(nothing new to commit)"
    git push
fi

# ------------------------------------------------------------------- export
if want export; then
    say "Exporting the public source snapshot"
    bash "$DEV/Tools/export-public.sh" "$PUB"
    git -C "$PUB" push
fi

# ------------------------------------------------------------------ release
if want release; then
    say "Creating the GitHub Release $TAG"
    NOTES_FILE="$(mktemp)"
    awk -v h="## $VERSION (" 'index($0,h)==1{f=1;next} /^## /{f=0} f' RELEASE_NOTES.md | sed 's/\*\*//g' > "$NOTES_FILE"
    if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
        if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
            echo "Release $TAG already exists; making sure the zip is attached."
            gh release upload "$TAG" "$ZIP" --repo "$REPO" --clobber
        else
            gh release create "$TAG" "$ZIP" --repo "$REPO" --target main --title "$VERSION" --notes-file "$NOTES_FILE"
        fi
    else
        echo "gh is not installed or not signed in, so do this part in the browser:"
        echo "  1. tag $TAG (Create new tag on publish, target main), title $VERSION"
        echo "  2. drag the zip from the Finder window that just opened onto the page"
        echo "  3. release notes are on your clipboard: paste them in"
        echo "  4. click Publish release (not a draft)"
        pbcopy < "$NOTES_FILE" 2>/dev/null || true
        open -R "$ZIP"
        open "https://github.com/$REPO/releases/new?tag=$TAG&title=$VERSION"
        read -r -p "Press Return once the release is published... " _
    fi
    rm -f "$NOTES_FILE"
fi

# ------------------------------------------------------------------ appcast
if want appcast; then
    say "Publishing the update feed"
    bash "$DEV/Tools/publish-appcast.sh" "$VERSION" "$PUB"
fi

say "Released $VERSION."
echo "GitHub Pages takes a minute or two to serve the new feed. Then, in an older installed copy,"
echo "quit M3 (Cmd-Q), relaunch and choose Check for Updates... : it should offer $VERSION."
