#!/bin/bash
#
#  check-headers.sh
#
#             Media Metadata Manager
#                       M3
#  Created by: Hans Hoffmeister on 10/16/2026.
#
# Checks the source-file header rule:
#   * a file that exists only in M3 starts with a "Created by: Hans Hoffmeister"
#     header (the same layout Xcode writes);
#   * a file that came from Subler (or MP42Foundation) and was changed in M3
#     carries a "Modified for M3 (Media Metadata Manager)" notice, because the
#     GPL asks modified files to say that they were changed, and when;
#   * a file that is identical to an upstream version needs nothing.
# Whether a file is "ours", "changed" or "identical" is decided by comparing it
# with every version in the upstream histories, fetched read-only.
#
# Usage: bash Tools/check-headers.sh        (from the repository root)
# Exit status 0 = everything is marked, 1 = something needs a header or notice.

set -u
cd "$(git rev-parse --show-toplevel)" || exit 2

APP_URL="https://github.com/SublerApp/Subler.git"
LIB_URL="https://github.com/SublerApp/MP42Foundation.git"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Files that differ from upstream only by blank space (nothing worth a notice).
EXEMPT="Classes/SaveOptions.swift MP42Foundation/MP42/MP42Mp4Importer.m"

echo "Fetching upstream histories (read-only)..."
git fetch --quiet "$APP_URL" main:refs/remotes/headercheck/app 2>/dev/null || { echo "Could not fetch $APP_URL"; exit 2; }
git fetch --quiet "$LIB_URL" main:refs/remotes/headercheck/lib 2>/dev/null || { echo "Could not fetch $LIB_URL"; exit 2; }

for which in app lib; do
    git rev-list --objects "refs/remotes/headercheck/$which" | awk 'NF>1' > "$TMP/$which.objs"
    cut -d' ' -f1  "$TMP/$which.objs" | sort -u > "$TMP/$which.hashes"
    cut -d' ' -f2- "$TMP/$which.objs" | sort -u > "$TMP/$which.paths"
    sed 's|.*/||' "$TMP/$which.paths" | sort -u > "$TMP/$which.names"
done

missing=0
check() {   # check <file> <hashes> <paths> <names> <path-relative-to-upstream>
    local f="$1" rel="$5" h
    case " $EXEMPT " in *" $f "*) return;; esac
    h=$(git hash-object "$f")
    if grep -qx "$h" "$2"; then return; fi
    if grep -qxF "$rel" "$3" || grep -qxF "$(basename "$f")" "$4"; then
        head -40 "$f" | grep -q "Modified for M3 (Media Metadata Manager)" || { echo "needs a 'Modified for M3' notice: $f"; missing=1; }
    else
        head -40 "$f" | grep -qE "Created by:? Hans Hoffmeister" || { echo "needs a 'Created by' header: $f"; missing=1; }
    fi
}

while IFS= read -r f; do
    [ -f "$f" ] || continue
    case "$f" in
        */contrib/*|*/Pods/*|build-release/*) continue;;
        MP42Foundation/*) check "$f" "$TMP/lib.hashes" "$TMP/lib.paths" "$TMP/lib.names" "${f#MP42Foundation/}";;
        *)                check "$f" "$TMP/app.hashes" "$TMP/app.paths" "$TMP/app.names" "$f";;
    esac
done < <(git ls-files '*.swift' '*.m' '*.mm' '*.h' '*.sh' '*.py'; git ls-files --others --exclude-standard '*.swift' '*.m' '*.mm' '*.h' '*.sh' '*.py')

if [ "$missing" = 0 ]; then echo "All source files are marked correctly."; fi
exit $missing
