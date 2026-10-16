#!/usr/bin/env bash
# Rebuild the Word and PDF copies of both guides from the Markdown.
# Usage: rebuild.sh <workdir>
# <workdir> must hold User-Guide.md, Getting-Started.md, the existing User-Guide.docx and
# Getting-Started.docx (used for styles, cover, header, footer) and images/ (with images/screens/).
# Needs: pandoc, soffice (LibreOffice), pdftotext, python3 with python-docx and Pillow.
# Writes <Name>.new.docx and <Name>.new.pdf; copy them over the originals when satisfied.
set -euo pipefail
cd "$1"
HERE="$(cd "$(dirname "$0")" && pwd)"
python3 "$HERE/apply_screenshots.py" . || { echo "apply_screenshots reported errors, stopping"; exit 1; }
for n in User-Guide Getting-Started; do
  python3 "$HERE/build2.py" $n 1
  soffice --headless --convert-to pdf $n.new.docx >/dev/null 2>&1
  python3 "$HERE/pages.py" $n
  python3 "$HERE/build2.py" $n 2
  soffice --headless --convert-to pdf $n.new.docx >/dev/null 2>&1
  cp pages_$n.txt prev_$n.txt
  python3 "$HERE/pages.py" $n
  diff -q prev_$n.txt pages_$n.txt >/dev/null || { echo "$n: page numbers moved between passes; run again"; }
done
ls -la *.new.docx *.new.pdf
