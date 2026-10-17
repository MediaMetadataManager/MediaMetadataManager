#!/usr/bin/env python3
#
#  build-helpbook.py
#
#             Media Metadata Manager
#                       M3
#  Created by: Hans Hoffmeister on 10/17/2026.
#
# Builds the help pages shown by the app's own Help window (Classes/HelpWindowController.swift)
# from the Markdown guides, so the guides stay the single source of the help text.
#
#   Usage (from the repository root):   python3 Tools/docs/build-helpbook.py [--force]   (--force rescales every image)
#   Needs: pandoc and python3 with Pillow.
#   Output: Documentation/HelpBook/M3.help   (a folder reference in the Xcode project, copied into the app)
#
# Run it after any change to User-Guide.md, Getting-Started.md or RELEASE_NOTES.md, then rebuild the app.
# (The folder is still called M3.help from the days when the system's Help Viewer was tried; that viewer
# did not find a book for this app reliably, so the app shows the pages itself and searches them with
# help-index.json. Nothing needs indexing with hiutil.)
#
# What it makes:
#   - one page per chapter and per sub-chapter (## heading) of both guides, so a search hit
#     lands on a short page, not on a 40-page document;
#   - an anchor (<a name="...">) at every heading; the anchors the app opens from its "?" buttons
#     are listed in Classes/HelpAnchor.swift and checked by M3Tests/HelpAnchorTests.swift;
#   - a "What's new" page from the released sections of RELEASE_NOTES.md;
#   - shrd/help-index.json: title, outline level, plain text and anchors of every page, which the
#     Help window's search and the Help menu's search box read;
#   - scaled copies of the screenshots (the originals stay full size in Documentation/images).
import html, json, os, re, subprocess, sys
from PIL import Image

ROOT = os.getcwd()
DOC = os.path.join(ROOT, 'Documentation')
BOOK = os.path.join(DOC, 'HelpBook', 'M3.help')
RES = os.path.join(BOOK, 'Contents', 'Resources')
LPROJ = os.path.join(RES, 'en.lproj')
SHRD = os.path.join(RES, 'shrd')
TITLE = 'Media Metadata Manager Help'      # must equal CFBundleHelpBookName in the app's Info.plist
GUIDES = [
    ('start', 'Getting Started', 'Getting-Started.md'),
    ('guide', 'User Guide', 'User-Guide.md'),
]
MAX_IMG_WIDTH = 1000

def slug(text):
    t = re.sub(r'^\s*\d+(\.\d+)*\.?\s+', '', text)          # drop "3.2 " numbering
    t = re.sub(r'[^A-Za-z0-9]+', '-', t.lower()).strip('-')
    return t or 'section'

def plain(md):
    t = re.sub(r'!\[[^\]]*\]\([^)]*\)', '', md)
    t = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', t)
    t = re.sub(r'[*_`]+', '', t)
    return re.sub(r'\s+', ' ', t).strip()

def summary(md):
    for para in re.split(r'\n\s*\n', md):
        p = para.strip()
        if not p or p.startswith(('#', '|', '!', '<!--', '```', '-', '1.')):
            continue
        s = plain(p)
        if len(s) > 20:
            return s[:157] + '...' if len(s) > 160 else s
    return ''

def split_guide(path):
    """Return [(h1_title, intro_md, [(h2_title, body_md), ...]), ...] for a guide's Markdown."""
    text = open(path, encoding='utf-8').read()
    text = re.sub(r'\A---\n.*?\n---\n', '', text, flags=re.S)
    chapters, cur, in_fence = [], None, False
    for line in text.split('\n'):
        if line.startswith('```'):
            in_fence = not in_fence
        m = None if in_fence else re.match(r'^(#{1,2}) (.+?)\s*$', line)
        if m and len(m.group(1)) == 1:
            cur = {'title': m.group(2), 'intro': [], 'subs': []}
            chapters.append(cur)
        elif m:
            if cur is None:
                continue
            cur['subs'].append({'title': m.group(2), 'body': []})
        elif cur is not None:
            (cur['subs'][-1]['body'] if cur['subs'] else cur['intro']).append(line)
    return [(c['title'], '\n'.join(c['intro']).strip(),
             [(s['title'], '\n'.join(s['body']).strip()) for s in c['subs']]) for c in chapters]

used_anchors, used_files, pages, referenced = {}, {}, [], set()

def unique(table, name):
    n, base = name, name
    i = 2
    while n in table:
        n = f'{base}-{i}'
        i += 1
    table[n] = True
    return n

def pandoc_html(md):
    out = subprocess.run(['pandoc', '-f', 'markdown', '-t', 'html5', '--no-highlight', '--wrap=none',
                          '--shift-heading-level-by=-1'], input=md, capture_output=True, text=True, check=True).stdout
    return out

def fix_html(h, prefix):
    """Images to the scaled copies in shrd/, an anchor at every sub-heading, no raw .md links."""
    def img(m):
        src = m.group(1)
        rel = re.sub(r'^(\.\./)*images/', '', src)
        referenced.add(rel)
        return f'src="../shrd/images/{rel}"'
    h = re.sub(r'src="([^"]+)"', img, h)
    def head(m):
        level, idattr, inner = m.group(1), m.group(2), m.group(3)
        base = slug(re.sub('<[^>]+>', '', inner))
        a = unique(used_anchors, f'{prefix}{base}')
        return f'<h{level}>{inner}</h{level}>'.replace('<h' + level + '>', f'<a name="{a}"></a><h{level}>', 1)
    h = re.sub(r'<h([2-6])( id="[^"]*")?>(.*?)</h\1>', head, h)
    return h

CSS = """
:root { color-scheme: light dark; --fg:#1d2b3a; --bg:#ffffff; --muted:#5b6b7b; --line:#d9e0e8; --accent:#1d5fa8; --soft:#f2f6fa; }
@media (prefers-color-scheme: dark) { :root { --fg:#e6edf3; --bg:#1c2128; --muted:#9aa7b4; --line:#39424d; --accent:#6cb0ff; --soft:#262d36; } }
html { font: 15px/1.55 -apple-system, "Helvetica Neue", Helvetica, sans-serif; color: var(--fg); background: var(--bg); }
body { max-width: 780px; margin: 0 auto; padding: 18px 26px 48px; }
h1 { font-size: 1.9em; margin: .3em 0 .4em; } h2 { font-size: 1.35em; margin-top: 1.6em; border-bottom: 1px solid var(--line); padding-bottom: .2em; }
h3 { font-size: 1.1em; margin-top: 1.3em; } a { color: var(--accent); text-decoration: none; } a:hover { text-decoration: underline; }
.crumbs { color: var(--muted); font-size: .85em; margin-bottom: .4em; } .crumbs a { color: var(--muted); }
img { max-width: 100%; height: auto; border: 1px solid var(--line); border-radius: 6px; }
figure { margin: 1.2em 0; } figcaption { color: var(--muted); font-size: .88em; margin-top: .4em; }
table { border-collapse: collapse; width: 100%; margin: 1em 0; font-size: .94em; } th, td { text-align: left; vertical-align: top; padding: 6px 9px; border-bottom: 1px solid var(--line); }
th { background: var(--soft); } code { font: .92em ui-monospace, Menlo, monospace; background: var(--soft); padding: 1px 4px; border-radius: 4px; }
pre { background: var(--soft); padding: 10px 12px; border-radius: 6px; overflow-x: auto; } pre code { background: none; padding: 0; }
mark { background: #ffe38a; color: #1d2b3a; border-radius: 2px; }
.toc { list-style: none; padding-left: 0; } .toc li { margin: .35em 0; } .toc ul { list-style: none; padding-left: 1.2em; }
.footer { margin-top: 2.4em; padding-top: .8em; border-top: 1px solid var(--line); color: var(--muted); font-size: .85em; }
"""

index_meta = []

def page(file, title, body, crumbs, desc, meta_title=False, level=0):
    head = ['<!DOCTYPE html>', '<html lang="en"><head><meta charset="utf-8">',
            '<meta http-equiv="Content-Type" content="text/html; charset=utf-8">']
    if meta_title:
        head.append(f'<meta name="AppleTitle" content="{TITLE}">')
    head += [f'<title>{html.escape(re.sub("<[^>]+>", "", title))}</title>',
             '<meta name="robots" content="anchors">',
             f'<meta name="description" content="{html.escape(desc, quote=True)}">',
             '<link rel="stylesheet" href="../shrd/style.css"></head><body>']
    nav = ' &rsaquo; '.join(f'<a href="{h}">{html.escape(t)}</a>' if h else html.escape(t) for t, h in crumbs)
    out = '\n'.join(head) + f'\n<div class="crumbs">{nav}</div>\n{body}\n'
    out += '<div class="footer"><a href="index.html">Contents</a> &middot; Media Metadata Manager Help</div>\n</body></html>\n'
    open(os.path.join(LPROJ, file), 'w', encoding='utf-8').write(out)
    pages.append(file)
    text = html.unescape(re.sub(r'<[^>]+>', ' ', body))
    index_meta.append({'file': file, 'title': re.sub('<[^>]+>', '', html.unescape(title)),
                       'crumbs': [t for t, _ in crumbs], 'level': level,
                       'text': re.sub(r'\s+', ' ', text).strip(),
                       'anchors': re.findall(r'<a name="([^"]+)"', body)})

def build():
    for d in (LPROJ, os.path.join(SHRD, 'images')):
        os.makedirs(d, exist_ok=True)
    open(os.path.join(SHRD, 'style.css'), 'w').write(CSS.strip() + '\n')

    toc = {}   # guide key -> list of (title, file, [(subtitle, file)])
    for key, name, md_file in GUIDES:
        prefix = 'start-' if key == 'start' else ''
        toc[key] = []
        for h1, intro, subs in split_guide(os.path.join(DOC, md_file)):
            a1 = unique(used_anchors, prefix + slug(h1))
            f1 = unique(used_files, f'{key}-{slug(h1)}')
            if prefix == '' and slug(h1) == 'preferences':
                sub_prefix = 'preferences-'
            else:
                sub_prefix = prefix
            entry = (h1, f1 + '.html', [])
            sub_pages = []
            for h2, body in subs:
                base = slug(h2)
                a2 = unique(used_anchors, sub_prefix + base)
                f2 = unique(used_files, f'{key}-{base}')
                sub_pages.append((h2, body, a2, f2))
                entry[2].append((h2, f2 + '.html'))
            toc[key].append(entry)
            # chapter page: intro, then the list of its sub-chapters
            body = f'<a name="{a1}"></a><h1>{html.escape(h1)}</h1>\n' + fix_html(pandoc_html(intro), prefix) if intro else \
                   f'<a name="{a1}"></a><h1>{html.escape(h1)}</h1>\n'
            if subs:
                body += '<h2>In this chapter</h2>\n<ul class="toc">' + ''.join(
                    f'<li><a href="{f}.html#{a}">{html.escape(t)}</a></li>' for t, _, a, f in
                    [(s[0], s[1], s[2], s[3]) for s in sub_pages]) + '</ul>\n'
            page(f1 + '.html', h1, body, [(TITLE, 'index.html'), (name, None)], summary(intro) or h1)
            for h2, body_md, a2, f2 in sub_pages:
                b = f'<a name="{a2}"></a><h1>{html.escape(h2)}</h1>\n' + fix_html(pandoc_html(body_md), sub_prefix)
                page(f2 + '.html', h2, b, [(TITLE, 'index.html'), (name, None), (h1, f1 + '.html')], summary(body_md) or h2, level=1)

    # What's new, from the released sections of RELEASE_NOTES.md
    notes = open(os.path.join(ROOT, 'RELEASE_NOTES.md'), encoding='utf-8').read()
    parts = re.split(r'(?m)^## ', notes)[1:]
    released = [p for p in parts if not p.lower().startswith('unreleased')]
    md = '\n\n'.join('## ' + p.strip() for p in released)
    a = unique(used_anchors, 'whats-new')
    f = unique(used_files, 'whats-new')
    body = f'<a name="{a}"></a><h1>What\'s new</h1>\n<p>Changes in each released version, newest first.</p>\n' + fix_html(pandoc_html(md), 'whatsnew-').replace('<h2', '<h2')
    # pandoc shifted ## to #; restore them as sub-headings
    body = body.replace('<h1', '<h2').replace('</h1>', '</h2>').replace('<a name="whats-new"></a><h2>What\'s new</h2>', '<a name="whats-new"></a><h1>What\'s new</h1>')
    page('whats-new.html', "What's new", body, [(TITLE, 'index.html')], 'Changes in each released version of Media Metadata Manager.')

    # The front page
    def toc_html(rows):
        out = '<ul class="toc">'
        for t, f, subs in rows:
            out += f'<li><a href="{f}">{html.escape(t)}</a>'
            if subs:
                out += '<ul>' + ''.join(f'<li><a href="{sf}">{html.escape(st)}</a></li>' for st, sf in subs) + '</ul>'
            out += '</li>'
        return out + '</ul>'
    front = (f'<a name="home"></a><h1>{TITLE}</h1>\n'
             '<p>Media Metadata Manager (M3) tags and merges movie and TV files. Type a word in the search box on the left, '
             'or pick a topic below. In the app, the <b>Help</b> menu\'s search box also finds menu commands and points at them.</p>\n'
             '<h2>New here?</h2>\n' + toc_html([(t, f, []) for t, f, _ in toc['start']]) +
             '\n<h2>Reference: the User Guide</h2>\n' + toc_html(toc['guide']) +
             '\n<h2>Other</h2>\n<ul class="toc"><li><a href="whats-new.html">What\'s new</a></li>'
             '<li><a href="https://github.com/MediaMetadataManager/MediaMetadataManager">Project page on GitHub</a></li></ul>\n')
    page('index.html', TITLE, front, [(TITLE, None)], 'Help for Media Metadata Manager: getting started, the User Guide, and what is new.', meta_title=True)

    # Scaled screenshots and figures (originals stay full size in Documentation/images)
    src = os.path.join(DOC, 'images')
    n = 0
    for rel in sorted(referenced):
        srcf = os.path.join(src, rel)
        if not os.path.exists(srcf):
            print('Missing image:', rel)
            continue
        dst = os.path.join(SHRD, 'images', rel)
        if '--force' not in sys.argv and os.path.exists(dst) and os.path.getmtime(dst) >= os.path.getmtime(srcf):
            continue
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        im = Image.open(srcf)
        if im.width > MAX_IMG_WIDTH:
            im = im.resize((MAX_IMG_WIDTH, round(im.height * MAX_IMG_WIDTH / im.width)), Image.LANCZOS)
        # 256 colours: UI screenshots shrink to about a sixth of their size with no visible change
        im.convert('RGBA').quantize(256, method=Image.FASTOCTREE).save(dst, optimize=True)
        n += 1

    # The search index the Help window and the Help menu's search box read: index first, then the
    # pages in reading order, What's new last.
    ordered = [m for m in index_meta if m['file'] == 'index.html'] + \
              [m for m in index_meta if m['file'] not in ('index.html', 'whats-new.html')] + \
              [m for m in index_meta if m['file'] == 'whats-new.html']
    with open(os.path.join(SHRD, 'help-index.json'), 'w', encoding='utf-8') as fh:
        json.dump({'pages': ordered}, fh, ensure_ascii=False, separators=(',', ':'))

    # anchors.json: every anchor, for looking things up
    with open(os.path.join(DOC, 'HelpBook', 'anchors.json'), 'w') as fh:
        json.dump(sorted({a for m in ordered for a in m['anchors']}), fh, indent=1)

    # Pages left over from an earlier build (this script cannot delete files in a connected folder)
    stale = [f for f in os.listdir(LPROJ) if f.endswith('.html') and f not in pages]
    print(f'{len(pages)} pages, {len(used_anchors)} anchors, {n} images scaled, index {os.path.getsize(os.path.join(SHRD, "help-index.json")) // 1024} KB')
    if stale:
        print('Stale pages from an earlier build; delete them:', ', '.join(sorted(stale)))

if __name__ == '__main__':
    build()
