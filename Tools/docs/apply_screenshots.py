#!/usr/bin/env python3
#
#  apply_screenshots.py
#
#             Media Metadata Manager
#                       M3
#  Created by: Hans Hoffmeister on 10/16/2026.
#
"""Insert the screenshots named in manifest.json into the guides.

Usage: apply_screenshots.py <Documentation dir> [--ocr patterns.txt]

- PNGs live in <Documentation>/images/screens/ and are named exactly as in manifest.json.
- For every placement whose PNG exists, an image line (preceded by a marker comment) is
  put in the guide right after the block that contains the 'after' text. Running it again
  only refreshes the caption/path (idempotent). If the PNG is missing, nothing is inserted
  (and a stale image line is removed), so the Markdown never points at a missing file.
- Prints a report: inserted, refreshed, missing, unknown files, odd sizes.
- --ocr <file>: also OCR each PNG (needs tesseract) and flag any line of <file> (one
  case-insensitive pattern per line) that shows up in the image text.
"""
import json, os, re, subprocess, sys, glob
from PIL import Image

doc_dir = sys.argv[1]
ocr_file = sys.argv[sys.argv.index('--ocr') + 1] if '--ocr' in sys.argv else None
shots_dir = os.path.join(doc_dir, 'images', 'screens')
manifest = json.load(open(os.path.join(shots_dir, 'manifest.json'), encoding='utf-8'))

texts = {}
def load(doc):
    if doc not in texts:
        texts[doc] = open(os.path.join(doc_dir, doc + '.md'), encoding='utf-8').read().split('\n')
    return texts[doc]

def marker(file, doc): return f'<!-- screen:{file}:{doc} -->'

def remove_existing(lines, mk):
    for i, l in enumerate(lines):
        if l.strip() == mk:
            j = i + 1
            if j < len(lines) and lines[j].startswith('!['): j += 1
            # drop one surrounding blank line
            if i > 0 and lines[i-1] == '' and (j >= len(lines) or lines[j] == ''): j += 1
            del lines[i:j]
            return True
    return False

report = {'inserted': [], 'refreshed': [], 'missing': [], 'errors': [], 'warnings': []}
known = set()
for s in manifest['screens']:
    f = s['file']; known.add(f)
    path = os.path.join(shots_dir, f)
    exists = os.path.exists(path)
    if exists:
        w, h = Image.open(path).size
        if w < 700: report['warnings'].append(f'{f}: only {w}px wide, may look soft in print')
        if w > 3200: report['warnings'].append(f'{f}: {w}px wide, large (it is scaled down in the Word/PDF copies)')
    for p in s['placements']:
        lines = load(p['doc']); mk = marker(f, p['doc'])
        if not exists:
            remove_existing(lines, mk)
            n_hits = sum(1 for l in lines if p['after'] in l and not l.startswith('![') and not l.startswith('<!--'))
            if n_hits != 1:
                report['errors'].append(f"{f} ({p['doc']}): anchor {p['after']!r} matched {n_hits} lines")
            report['missing'].append(f"{f} ({p['doc']})")
            continue
        img = f"![{p['caption']}](images/screens/{f})"
        existed = remove_existing(lines, mk)
        hits = [i for i, l in enumerate(lines) if p['after'] in l and not l.startswith('![') and not l.startswith('<!--')]
        if len(hits) != 1:
            report['errors'].append(f"{f} ({p['doc']}): anchor {p['after']!r} matched {len(hits)} lines")
            continue
        i = hits[0]
        while i + 1 < len(lines) and lines[i + 1].strip() != '': i += 1
        # keep manifest order when several screenshots share one anchor block
        while i + 3 < len(lines) and lines[i+1] == '' and lines[i+2].startswith('<!-- screen:') and lines[i+3].startswith('!['):
            i += 3
        lines[i+1:i+1] = ['', mk, img] + ([''] if i + 1 < len(lines) and lines[i+1] != '' else [])
        report['refreshed' if existed else 'inserted'].append(f"{f} ({p['doc']})")

for doc, lines in texts.items():
    out = '\n'.join(lines)
    out = re.sub(r'\n{3,}', '\n\n', out)
    open(os.path.join(doc_dir, doc + '.md'), 'w', encoding='utf-8').write(out)

for f in sorted(os.path.basename(x) for x in glob.glob(os.path.join(shots_dir, '*.png'))):
    if f not in known: report['warnings'].append(f'{f}: not in manifest.json (ignored)')

if ocr_file:
    pats = [l.strip() for l in open(ocr_file, encoding='utf-8') if l.strip() and not l.startswith('#')]
    for f in sorted(known):
        path = os.path.join(shots_dir, f)
        if not os.path.exists(path): continue
        try:
            txt = subprocess.check_output(['tesseract', path, '-', '--psm', '11'], stderr=subprocess.DEVNULL).decode('utf-8', 'ignore').lower()
        except Exception as e:
            report['warnings'].append(f'OCR unavailable: {e}'); break
        for pat in pats:
            if re.search(pat.lower(), txt): report['errors'].append(f'{f}: OCR found a forbidden term (pattern {pat!r})')

for k in ('inserted', 'refreshed', 'missing', 'warnings', 'errors'):
    print(f'{k}: {len(report[k])}')
    for x in report[k]: print('   ', x)
sys.exit(1 if report['errors'] else 0)
