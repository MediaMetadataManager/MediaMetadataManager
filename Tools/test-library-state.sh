#!/bin/bash
#
#  test-library-state.sh
#
#             Media Metadata Manager
#                       M3
#  Created by: Hans Hoffmeister on 10/11/2026.
#
# Prints a sorted listing of a folder: relative path, size and a short hash for
# every file (hidden files included). Save it before and after a test and diff
# the two to see exactly what changed.
#
# Usage: Tools/test-library-state.sh <folder> > before.txt

set -euo pipefail
ROOT="${1:?usage: test-library-state.sh <folder>}"
cd "$ROOT"
find . -mindepth 1 \( -type f -o -type d \) | LC_ALL=C sort | while IFS= read -r path; do
    if [ -d "$path" ]; then
        echo "D  $path"
    else
        size=$(stat -f%z "$path" 2>/dev/null || stat -c%s "$path")
        hash=$(shasum -a 1 "$path" 2>/dev/null | cut -c1-10 || sha1sum "$path" | cut -c1-10)
        echo "F  $size  $hash  $path"
    fi
done
