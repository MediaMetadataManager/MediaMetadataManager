#!/bin/bash
#
# One-time Sparkle setup (run at home, on the Mac you build on).
#
#   Tools/setup-sparkle.sh <feed-url>
#   e.g. Tools/setup-sparkle.sh https://mediametadatamanager.github.io/MediaMetadataManager/appcast.xml
#
# 1. Finds Sparkle's generate_keys tool (it ships with the Sparkle Swift
#    package that Xcode already downloaded for this project).
# 2. Creates the EdDSA signing key pair. The PRIVATE key goes into your login
#    Keychain; the PUBLIC key is printed.
# 3. Writes SUPublicEDKey, SUFeedURL and the check-automatically keys into
#    Info.plist.
#
# Safe to run again: if a key already exists generate_keys just prints the
# existing public key; Info.plist keys are overwritten with the same values.

set -euo pipefail

DEV="$(cd "$(dirname "$0")/.." && pwd)"
FEED="${1:-}"
[ -n "$FEED" ] || { echo "usage: Tools/setup-sparkle.sh <appcast-feed-url>"; exit 2; }
PLIST="$DEV/Info.plist"

BIN="$(find ~/Library/Developer/Xcode/DerivedData -type d -path '*artifacts/sparkle/Sparkle/bin' 2>/dev/null | head -1)"
if [ -z "$BIN" ] || [ ! -x "$BIN/generate_keys" ]; then
    echo "Could not find Sparkle's tools. Open the project in Xcode and build once"
    echo "(so the Sparkle package is downloaded), then run this again."
    exit 1
fi
echo "Using Sparkle tools in: $BIN"

echo
echo "Creating (or reading) the signing key. macOS may ask to allow Keychain access."
OUT="$("$BIN/generate_keys" 2>&1)" || true
echo "$OUT"
PUB="$(echo "$OUT" | grep -Eo '[A-Za-z0-9+/]{43}=' | head -1)"
if [ -z "$PUB" ]; then
    PUB="$("$BIN/generate_keys" -p 2>/dev/null | tail -1)"
fi
[ -n "$PUB" ] || { echo "Could not read the public key."; exit 1; }

set_key() { # key type value
    /usr/libexec/PlistBuddy -c "Delete :$1" "$PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :$1 $2 $3" "$PLIST"
}
set_key SUPublicEDKey string "$PUB"
set_key SUFeedURL string "$FEED"
set_key SUEnableAutomaticChecks bool true
set_key SUScheduledCheckInterval integer 86400

echo
echo "Info.plist updated:"
echo "  SUPublicEDKey = $PUB"
echo "  SUFeedURL     = $FEED"
echo
echo "IMPORTANT: back up the private key now, or you can never ship an update"
echo "that existing installs will accept:"
echo "  $BIN/generate_keys -x ~/Desktop/M3-sparkle-private-key"
echo "Store that file in your password manager / offline, NEVER in the repo."
