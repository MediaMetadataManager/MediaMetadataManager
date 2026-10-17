#!/usr/bin/env bash
#
#  rebuild-manual.sh
#
#             Media Metadata Manager
#                       M3
#  Created by: Hans Hoffmeister on 10/17/2026.
#
# Rebuild the Word and PDF copies of the Design and Project Manual from its Markdown.
# Usage: rebuild-manual.sh <workdir>
# <workdir> must hold Design-and-Project-Manual.md, the existing Design-and-Project-Manual.docx
# (used for styles, cover, header, footer) and images/ (the figures). The revision line on the
# cover and in the page header is taken from the `version:` line of the Markdown.
# Needs: pandoc, soffice (LibreOffice), pdftotext, python3 with python-docx and Pillow.
# Writes Design-and-Project-Manual.new.docx and .new.pdf; copy them over the originals when satisfied.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$1"
n=Design-and-Project-Manual
# The manual lives one folder below images/; the build runs with images/ beside the Markdown.
sed -i.bak 's#(\.\./images/#(images/#g' $n.md
python3 "$HERE/build2.py" $n 1
soffice --headless --convert-to pdf $n.new.docx >/dev/null 2>&1
python3 "$HERE/pages.py" $n
python3 "$HERE/build2.py" $n 2
soffice --headless --convert-to pdf $n.new.docx >/dev/null 2>&1
cp pages_$n.txt prev_$n.txt
python3 "$HERE/pages.py" $n
diff -q prev_$n.txt pages_$n.txt >/dev/null || { echo "$n: page numbers moved between passes; run again"; }
ls -la $n.new.docx $n.new.pdf
