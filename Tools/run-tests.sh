#!/bin/bash
#
#  run-tests.sh
#
#             Media Metadata Manager
#                       M3
#  Created by: Hans Hoffmeister on 10/17/2026.
#
#
# The gate every release has to pass: the source-header check, then the whole unit
# test suite (the hosted M3Tests target). Exit status 0 = everything passed.
#
#   Tools/run-tests.sh
#
# Tools/release.sh runs this before it builds anything and stops if it fails.
# Quit M3 first: the tests are hosted by the app and need it not to be running.

set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

if pgrep -x M3 >/dev/null 2>&1; then
    echo "error: M3 is running. Quit it (Cmd-Q) and run the tests again."; exit 1
fi

echo "==> Source-file headers"
bash Tools/check-headers.sh || { echo "error: the header check failed (see above)."; exit 1; }

LOG="${TMPDIR:-/tmp}/m3-tests.log"
DERIVED="${TMPDIR:-/tmp}/m3-tests-derived"
echo
echo "==> Unit tests (log: $LOG)"
xcodebuild test -project M3.xcodeproj -scheme M3 -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" > "$LOG" 2>&1
STATUS=$?

if [ "$STATUS" -ne 0 ] || ! grep -q '\*\* TEST SUCCEEDED \*\*' "$LOG"; then
    echo "error: the tests did not pass. What failed:"
    grep -E "error:|Test Case .* failed|\*\* TEST FAILED|\*\* BUILD FAILED" "$LOG" | sort -u | head -40
    echo "Full log: $LOG"
    exit 1
fi
COUNT="$(grep -Eo "Executed [0-9]+ tests?" "$LOG" | tail -1)"
echo "All tests passed (${COUNT:-count not reported})."
