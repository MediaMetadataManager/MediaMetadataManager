#!/bin/bash
#
# Keep your own settings safe while you test releases and updates.
# Everything the app remembers lives OUTSIDE the .app:
#   ~/Library/Preferences/com.quattromeister.M3.plist   (preferences, API keys, folders)
#   ~/Library/Application Support/M3/                   (plugins, history, caches)
# Updating or replacing the app never touches them.
#
#   Tools/config-backup.sh backup            save a timestamped copy
#   Tools/config-backup.sh list              show saved copies
#   Tools/config-backup.sh restore [name]    put a copy back (latest if no name)
#   Tools/config-backup.sh fresh-start       move your settings aside to test a
#                                            brand-new install; 'restore' brings them back
#
# Quit the app before restore / fresh-start.

set -euo pipefail

DOMAIN="com.quattromeister.M3"
PREF="$HOME/Library/Preferences/$DOMAIN.plist"
SUPPORT="$HOME/Library/Application Support/M3"
STORE="$HOME/Documents/M3-config-backups"
mkdir -p "$STORE"

quit_check() {
    if pgrep -x M3 >/dev/null; then echo "Please quit M3 first."; exit 1; fi
}
save_to() {
    local d="$1"; mkdir -p "$d"
    defaults export "$DOMAIN" "$d/$DOMAIN.plist" 2>/dev/null || true
    [ -d "$SUPPORT" ] && ditto "$SUPPORT" "$d/Application Support M3"
    echo "Saved to $d"
}

case "${1:-}" in
  backup)
    save_to "$STORE/$(date +%Y%m%d-%H%M%S)" ;;
  list)
    ls -1 "$STORE" ;;
  restore)
    quit_check
    NAME="${2:-$(ls -1 "$STORE" | tail -1)}"
    D="$STORE/$NAME"; [ -d "$D" ] || { echo "No such backup: $NAME"; exit 1; }
    [ -f "$D/$DOMAIN.plist" ] && defaults import "$DOMAIN" "$D/$DOMAIN.plist"
    if [ -d "$D/Application Support M3" ]; then
        mkdir -p "$SUPPORT"; ditto "$D/Application Support M3" "$SUPPORT"
    fi
    killall cfprefsd 2>/dev/null || true
    echo "Restored $NAME" ;;
  fresh-start)
    quit_check
    save_to "$STORE/before-fresh-$(date +%Y%m%d-%H%M%S)"
    defaults delete "$DOMAIN" 2>/dev/null || true
    [ -d "$SUPPORT" ] && mv "$SUPPORT" "$SUPPORT.parked-$(date +%s)"
    killall cfprefsd 2>/dev/null || true
    echo "Settings cleared. Launch M3 to see a first-run experience."
    echo "Run: Tools/config-backup.sh restore    to get your settings back (parked Application Support copy is also kept)." ;;
  *)
    sed -n '2,19p' "$0" ;;
esac
