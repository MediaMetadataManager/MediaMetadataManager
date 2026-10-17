#
#  build2.py
#
#             Media Metadata Manager
#                       M3
#  Created by: Hans Hoffmeister on 10/16/2026.
#
import sys, copy, subprocess, re, os, collections
from docx import Document
from docx.oxml.ns import qn
from docx.oxml import OxmlElement

name = sys.argv[1]
PASS = int(sys.argv[2])          # 1 = placeholder TOC numbers, 2 = real numbers from pages.txt
NEWDATE = 'October 16, 2026'; OLDDATE = 'October 15, 2026'
W = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'

old = Document(f'{name}.docx')
okids = list(old.element.body)
def is_h1(el):
    s = el.find('.//'+qn('w:pStyle'))
    return el.tag == qn('w:p') and s is not None and s.get(qn('w:val')) == 'Heading1'
start = next(i for i, k in enumerate(okids) if is_h1(k))
cover = copy.deepcopy(okids[0]); pagebreak = copy.deepcopy(okids[1])
assert cover.tag == qn('w:tbl')

# old table widths by header tuple
old_widths = collections.defaultdict(list)
for t in old.tables[1:]:
    hdr = tuple(c.text.strip() for c in t.rows[0].cells)
    grid = [int(g.get(qn('w:w'))) for g in t._tbl.tblGrid.findall(qn('w:gridCol'))]
    if len(set(grid)) > 1: old_widths[hdr].append(grid)   # equal columns are pandoc's default, not a tuned layout

md = open(f'{name}.md', encoding='utf-8').read()
# A manual carries its revision in the front matter ("Revision 1.16 — October 17, 2026"); it replaces
# the revision line on the cover and in the page header, which come from the existing .docx.
_m = re.search(r'\A---\n.*?^version:\s*"(Revision [^"]+)"', md, flags=re.S | re.M)
VERSION = _m.group(1) if _m else None
REVLINE = re.compile(r'Revision [0-9.]+ — [A-Z][a-z]+ \d{1,2}, \d{4}')
def fix_revision(paragraphs):
    if not VERSION: return
    for p in paragraphs:
        ts = list(p.iter(qn('w:t')))
        full = ''.join(t.text or '' for t in ts)
        if ts and REVLINE.search(full):
            ts[0].text = REVLINE.sub(VERSION, full)
            for t in ts[1:]: t.text = ''
md = re.sub(r'\A---\n.*?\n---\n', '', md, flags=re.S)
import glob
from PIL import Image
os.makedirs('_scaled/screens', exist_ok=True)
for f in glob.glob('images/screens/*.png'):
    im = Image.open(f)
    if im.size[0] > 1800:
        im = im.resize((1800, int(im.size[1]*1800/im.size[0])), Image.LANCZOS)
    im.save(os.path.join('_scaled/screens', os.path.basename(f)), optimize=True)
md = md.replace('images/screens/', '_scaled/screens/')
open(f'_{name}.md', 'w', encoding='utf-8').write(md)
subprocess.check_call(['pandoc', f'_{name}.md', '-f', 'markdown', '-o', f'_{name}.docx',
                       f'--reference-doc={name}.docx', '--resource-path=.'])
new = Document(f'_{name}.docx')
body = new.element.body
TOTAL = 9648

def sub(tag, **attrs):
    e = OxmlElement(tag)
    for k, v in attrs.items(): e.set(qn('w:'+k), v)
    return e

# ---- headings: page break before every Heading1 except the first
h1s = [p for p in body.iter(qn('w:p')) if p.find('.//'+qn('w:pStyle')) is not None and p.find('.//'+qn('w:pStyle')).get(qn('w:val')) == 'Heading1']
old_h1 = [k for k in okids if is_h1(k)]
use_pbb = len(old_h1) > 1 and old_h1[1].find('.//'+qn('w:pageBreakBefore')) is not None
for p in (h1s[1:] if use_pbb else []):
    ppr = p.find(qn('w:pPr')); 
    if ppr.find(qn('w:pageBreakBefore')) is None:
        # must come after pStyle
        ps = ppr.find(qn('w:pStyle')); ps.addnext(sub('w:pageBreakBefore'))

# ---- tables
used = collections.Counter()
def cell_text(tc): return ''.join(t.text or '' for t in tc.iter(qn('w:t'))).strip()
for tbl in body.iter(qn('w:tbl')):
    rows = tbl.findall(qn('w:tr'))
    hdr = tuple(cell_text(tc) for tc in rows[0].findall(qn('w:tc')))
    ncol = len(hdr)
    ow = old_widths.get(hdr)
    if ow and used[hdr] < len(ow) and len(ow[used[hdr]]) == ncol:
        widths = ow[used[hdr]]
    elif ow and len(ow[-1]) == ncol:
        widths = ow[-1]
    else:
        widths = None
    used[hdr] += 1
    if widths is None:
        lens = []
        for ci in range(ncol):
            ls = [len(cell_text(r.findall(qn('w:tc'))[ci])) for r in rows[1:]] or [10]
            lens.append(max(8.0, min(90.0, sum(ls)/len(ls))) ** 0.75)
        s = sum(lens); widths = [int(TOTAL*x/s) for x in lens]
        # No column narrower than its longest word, so words and short codes never break mid-word.
        minw = []
        for ci in range(ncol):
            cells = [hdr[ci]] + [cell_text(r.findall(qn('w:tc'))[ci]) for r in rows[1:]]
            minw.append(min(30, max((len(w) for c in cells for w in c.split()), default=4)) * 104 + 300)
        for _ in range(4):
            fixed = [i for i in range(ncol) if widths[i] < minw[i]]
            if not fixed: break
            for i in fixed: widths[i] = minw[i]
            free = [i for i in range(ncol) if i not in fixed]
            room = TOTAL - sum(widths[i] for i in fixed)
            tot = sum(widths[i] for i in free) or 1
            for i in free: widths[i] = int(widths[i] * room / tot)
    sc = TOTAL / sum(widths); widths = [int(w*sc) for w in widths]
    # tblPr
    tblPr = tbl.find(qn('w:tblPr'))
    for ch in list(tblPr): tblPr.remove(ch)
    tblPr.append(sub('w:tblW', type='dxa', w=str(TOTAL)))
    tblPr.append(sub('w:jc', val='center'))
    tblPr.append(sub('w:tblLayout', type='fixed'))
    mar = OxmlElement('w:tblCellMar')
    for side, v in (('top', 60), ('left', 100), ('bottom', 60), ('right', 100)):
        mar.append(sub('w:'+side, w=str(v), type='dxa'))
    tblPr.append(mar)
    tblPr.append(sub('w:tblLook', firstRow='1', lastRow='0', firstColumn='0', lastColumn='0', noHBand='0', noVBand='0', val='0020'))
    grid = tbl.find(qn('w:tblGrid'))
    for ch in list(grid): grid.remove(ch)
    for w in widths: grid.append(sub('w:gridCol', w=str(w)))
    for ri, tr in enumerate(rows):
        trPr = tr.find(qn('w:trPr'))
        if trPr is None:
            trPr = OxmlElement('w:trPr'); tr.insert(0, trPr)
        for ch in list(trPr): trPr.remove(ch)
        if ri == 0: trPr.append(sub('w:tblHeader'))
        trPr.append(sub('w:cantSplit'))
        for ci, tc in enumerate(tr.findall(qn('w:tc'))):
            tcPr = tc.find(qn('w:tcPr'))
            if tcPr is None:
                tcPr = OxmlElement('w:tcPr'); tc.insert(0, tcPr)
            for ch in list(tcPr): tcPr.remove(ch)
            tcPr.append(sub('w:tcW', w=str(widths[ci]), type='dxa'))
            if ri == 0: tcPr.append(sub('w:shd', val='clear', color='auto', fill='1F4E79'))
            b = OxmlElement('w:tcBorders')
            for side in ('top', 'left', 'right'): b.append(sub('w:'+side, val='nil'))
            b.append(sub('w:bottom', val='single', sz='4', color='D5DDE6'))
            tcPr.append(b)
            for p in tc.findall(qn('w:p')):
                ppr = p.find(qn('w:pPr'))
                if ppr is None:
                    ppr = OxmlElement('w:pPr'); p.insert(0, ppr)
                for ch in list(ppr): ppr.remove(ch)
                ppr.append(sub('w:pStyle', val='Compact'))
                ppr.append(sub('w:spacing', after='20', before='20'))
                ppr.append(sub('w:jc', val='left'))
                for r in p.iter(qn('w:r')):
                    rpr = r.find(qn('w:rPr'))
                    if rpr is None:
                        rpr = OxmlElement('w:rPr'); r.insert(0, rpr)
                    if ri == 0:
                        for x in rpr.findall(qn('w:b')): rpr.remove(x)
                        rpr.append(sub('w:b')); rpr.append(sub('w:color', val='FFFFFF'))
                    rpr.append(sub('w:sz', val='17'))


# ---- figures: keep caption with image, cap image height
for p in body.iter(qn('w:p')):
    s_ = p.find('.//'+qn('w:pStyle'))
    if s_ is not None and s_.get(qn('w:val')) == 'CaptionedFigure':
        ppr = p.find(qn('w:pPr'))
        if ppr.find(qn('w:keepNext')) is None: s_.addnext(sub('w:keepNext'))
# keep the paragraph that introduces a figure on the same page as the figure
_ps = list(body.iter(qn('w:p')))
for i, p in enumerate(_ps[:-1]):
    nxt = _ps[i+1].find('.//'+qn('w:pStyle'))
    if nxt is not None and nxt.get(qn('w:val')) == 'CaptionedFigure':
        ppr = p.find(qn('w:pPr'))
        if ppr is None:
            ppr = OxmlElement('w:pPr'); p.insert(0, ppr)
        if ppr.find(qn('w:keepNext')) is None:
            ps_ = ppr.find(qn('w:pStyle'))
            (ps_.addnext if ps_ is not None else (lambda e: ppr.insert(0, e)))(sub('w:keepNext'))
WP='http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing'
A='http://schemas.openxmlformats.org/drawingml/2006/main'
MAXCY=6900000; MAXCX=6126480
for inl in body.iter('{%s}inline' % WP):
    ext = inl.find('{%s}extent' % WP)
    cx, cy = int(ext.get('cx')), int(ext.get('cy'))
    f = min(1.0, MAXCY/cy, MAXCX/cx)
    if f < 1.0:
        ext.set('cx', str(int(cx*f))); ext.set('cy', str(int(cy*f)))
        for a in inl.iter('{%s}ext' % A):
            a.set('cx', str(int(cx*f))); a.set('cy', str(int(cy*f)))

# ---- header text
for sec in new.sections:
    for part in (sec.header, sec.first_page_header):
        for p in part.paragraphs:
            for r in p.runs: r.text = r.text.replace(OLDDATE, NEWDATE)
        fix_revision([q._p for q in part.paragraphs])

# ---- TOC (static, page numbers from pages.txt in pass 2)
heads = []
for p in body.iter(qn('w:p')):
    s = p.find('.//'+qn('w:pStyle'))
    if s is not None and s.get(qn('w:val')) in ('Heading1', 'Heading2'):
        heads.append((1 if s.get(qn('w:val')) == 'Heading1' else 2, ''.join(t.text or '' for t in p.iter(qn('w:t')))))
pages = {}
if PASS == 2:
    for l in open(f'pages_{name}.txt', encoding='utf-8'):
        n, t = l.rstrip('\n').split('\t', 1); pages[t] = n
def toc_par(level, text, num, first=False):
    p = OxmlElement('w:p'); ppr = OxmlElement('w:pPr')
    ppr.append(sub('w:tabs')); ppr[0].append(sub('w:tab', val='right', leader='dot', pos=str(TOTAL)))
    ppr.append(sub('w:spacing', before='80' if level == 1 else '0', after='40' if level == 1 else '20'))
    if level == 2: ppr.append(sub('w:ind', left='360'))
    p.append(ppr)
    def run(txt, bold=False, tab=False):
        r = OxmlElement('w:r'); rpr = OxmlElement('w:rPr')
        if bold: rpr.append(sub('w:b'))
        rpr.append(sub('w:sz', val='21' if level == 1 else '19'))
        r.append(rpr)
        if tab: r.append(OxmlElement('w:tab'))
        else:
            t = OxmlElement('w:t'); t.set('{http://www.w3.org/XML/1998/namespace}space', 'preserve'); t.text = txt; r.append(t)
        return r
    p.append(run(text, bold=(level == 1))); p.append(run('', tab=True)); p.append(run(str(num), bold=(level == 1)))
    return p
title = OxmlElement('w:p'); tp = OxmlElement('w:pPr'); tp.append(sub('w:pStyle', val='TOCHeading')); title.append(tp)
tr_ = OxmlElement('w:r'); tt = OxmlElement('w:t'); tt.text = 'Contents'; tr_.append(tt); title.append(tr_)
front = [cover, pagebreak, title] + [toc_par(l, t, pages.get(t, '00')) for l, t in heads] + [copy.deepcopy(pagebreak)]
first = body[0]
for el in front: first.addprevious(el)
for t in cover.iter(qn('w:t')):
    if t.text and OLDDATE in t.text: t.text = t.text.replace(OLDDATE, NEWDATE)
fix_revision(cover.iter(qn('w:p')))
new.save(f'{name}.new.docx')
open(f'heads_{name}.txt', 'w', encoding='utf-8').write('\n'.join(t for _, t in heads))
print('built', name, 'pass', PASS, 'headings', len(heads))
