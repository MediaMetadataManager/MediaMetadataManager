#!/usr/bin/env python3
#
#  flow.py
#
#             Media Metadata Manager
#                       M3
#  Created by: Hans Hoffmeister on 10/10/2026.
#
"""
Single source for M3's flow charts.

  python3 Documentation/images/src/flow.py Documentation

writes (paths relative to the Documentation folder given):
  images/app-flow.png, images/src/app-flow.dot   the complete flow chart of the app
  images/pipeline.png, images/src/pipeline.dot   the same chart cut down to Intake -> Queue -> delivery
  diagrams/M3-app-flow.drawio                    editable draw.io version of the complete chart

Edit the NODES / EDGES below and run again; both pictures and the draw.io file
are produced from them, so they cannot drift apart. Needs graphviz (dot).
"""
import json, subprocess, sys, os
from xml.sax.saxutils import escape

# kind -> (fill, stroke, font colour, dot shape)
KINDS = {
    'start': ('#2b5d8a', '#2b5d8a', 'white',   'box'),
    'auto':  ('#e6f0fa', '#2b5d8a', '#1b2733', 'box'),
    'human': ('#fff4d6', '#c79a1c', '#1b2733', 'box'),
    'dec':   ('#f4f4f4', '#777777', '#1b2733', 'diamond'),
    'bad':   ('#f9dede', '#b04a4a', '#1b2733', 'box'),
    'opt':   ('#efe6f5', '#8061a0', '#1b2733', 'box'),
    'end':   ('#2f7d4f', '#2f7d4f', 'white',   'box'),
}

# lanes (dot clusters), in display order: id -> title
LANES = {
    'ways':   'Ways in',
    'editor': 'Editor (one file at a time)',
    'scan':   'Library scan',
    'hand':   'Queue: items you add by hand',
    'intake': 'Media Intake: watched folders',
    'run':    'Queue run',
    'deliver':'Delivery (Preferences > Sources > Media Locations)',
    'after':  'Afterwards',
}

# id, kind, lane, in-pipeline-chart?, title, detail
NODES = [
 ('W',   'start', 'ways',   False, 'Welcome window', 'Tag One File\nMerge and Tag Files\nScan Library for Missing Metadata'),
 ('DRP', 'start', 'ways',   False, 'Add Item, drag and drop,\nFile > Open', 'files or folders you add yourself'),
 ('IF',  'start', 'intake', True,  'Incoming Folders', 'one or more, set on the Media Intake tab'),

 ('ED',  'human', 'editor', False, 'Editor', 'edit tags, artwork, tracks, chapters\nSearch Metadata asks your enabled providers'),
 ('SV',  'auto',  'editor', False, 'Save / Save & Close', 'tags written into the file itself\n(in place: no original kept, nothing to the Trash)'),
 ('REN', 'auto',  'editor', False, 'Name and folder', 'renamed by the Filename rules, Movie or\nShow/Season folders applied (not if no Title is tagged)'),
 ('STQ', 'auto',  'editor', False, 'Send to Queue', 'the open file becomes a Queue item instead'),

 ('LS',  'human', 'scan',   False, 'Library scan', 'pick a folder; lists .mp4 / .m4v / .mov files\nmissing Title or Release Date.\nRight-click a tag to type a value into\nthe file, or send files to the Queue'),

 ('TVH', 'dec',   'hand',   False, 'Name looks like a\nTV episode?', ''),
 ('PI',  'auto',  'hand',   False, 'Plain Queue item', 'one row per file; Queue Options decide which\nactions run. Edit re-reads the file from disk;\nif it was moved: Find...'),
 ('MB',  'human', 'hand',   False, 'Merge button', 'select 2 or more items, Merge Review sheet,\nchoose where to save, lossless merge'),

 ('DISC','auto',  'intake', True,  'Discovery', 'Automatically watch (folder watcher + 20 s check)\nor the Scan Now button'),
 ('SET', 'auto',  'intake', True,  'Filter and settle', 'skips hidden files, delivery folders and unfinished\ndownloads; waits until sizes stop changing'),
 ('TV',  'dec',   'intake', True,  'TV episode?', ''),
 ('TVQ', 'auto',  'intake', True,  'TV Shows tab', 'its own list in the Queue window; same steps'),
 ('ROW', 'auto',  'intake', True,  'Release row in Movies Queue', 'one folder of files\n(a loose file gets a folder of its own)'),
 ('AA',  'dec',   'intake', True,  'Auto-approve on and\nconfident title match?', ''),
 ('NR',  'human', 'intake', True,  'Naming Review', 'approve, edit the name, or reject\nSearch All Providers'),
 ('REJ', 'bad',   'intake', True,  'Rejected', 'row stays parked in the Queue'),
 ('REN2','auto',  'intake', True,  'Folder renamed', 'Title Vol N [Studio] (Year)'),
 ('NF',  'dec',   'intake', True,  'One file or several?', 'a subtitle file beside the video\ndoes not count as a part'),
 ('MT',  'dec',   'intake', True,  'Online match for the\nname, confident?', ''),
 ('MR',  'human', 'intake', True,  'Metadata Review', 'search again with other words, pick a result,\nchoose Portrait or Landscape art,\nor Continue Without Metadata.\nSearch with menu: pick another source'),
 ('AMG', 'dec',   'intake', True,  'Folder already holds\na merged file?', ''),
 ('AMR', 'human', 'intake', True,  'Already merged: review', 'use the merged file, or merge the parts anyway\n(the old merged file is kept as " - OLD")'),
 ('SEV', 'dec',   'intake', True,  'Auto-merge on, parts\nnumbered and compatible?', ''),
 ('AM',  'auto',  'intake', True,  'Auto-merge', 'starts after about 1 s\n(opening the row cancels it)'),
 ('MRV', 'human', 'intake', True,  'Merge Review', 'pick files (untick a file to leave it out),\ndrag into order, compatibility check'),
 ('MG',  'auto',  'intake', True,  'Lossless merge', 'no re-encode, a chapter at each join;\nwritten under a hidden name, renamed when complete;\nprogress shown on the row, parts marked Merged afterwards'),
 ('MF',  'bad',   'intake', True,  'Merge failed', 'reason shown on the row;\nreopen and retry'),
 ('RDY', 'auto',  'intake', True,  'Item ready in the Queue', 'metadata search and delivery actions attached'),

 ('ST',  'auto',  'run',    True,  'Start', 'Auto-Start, or the Start button.\nMovies and TV Shows tabs take turns, one file\nat a time (or both at once, if you set that)'),
 ('ACT', 'auto',  'run',    True,  'Actions, then write the file', 'clear old tags, search metadata and artwork (a release\nsearches by its approved name), set filename,\nsubtitles (a file beside the video is embedded),\ntrack tidy-ups, optimize'),

 ('DEL', 'dec',   'deliver',True,  'Deliver automatically?', ''),
 ('STG', 'auto',  'deliver',True,  'Staging folder', 'Ready for Media Library: your check before the library.\nRules are ignored. No staging folder set: file stays put'),
 ('RUL', 'dec',   'deliver',True,  'First enabled rule\nthat matches?', ''),
 ('RF',  'auto',  'deliver',True,  'The rule\'s folder', 'Movies and TV Shows have separate rule lists\n(genre, rating, year, ...)'),
 ('DF',  'auto',  'deliver',True,  'Default destination', 'Apple TV Automatically Add folder;\nblank first row follows the Apple TV app\'s setting'),
 ('AAF', 'dec',   'deliver',True,  'Automatically Add\nfolder?', ''),
 ('FILE','auto',  'deliver',True,  'Finished file goes in alone', 'the Apple TV app files it from there'),
 ('FOLD','auto',  'deliver',True,  'Folder moved in', 'release folder, or movie / Show/Season folder;\n"name 2", "name 3" if the name is taken'),

 ('CL',  'dec',   'after',  True,  'Clean up processed\nfiles on?', ''),
 ('TR',  'opt',   'after',  True,  'Originals to the Trash', 'merged parts / unconverted source, logged'),
 ('EF',  'opt',   'after',  True,  'Remove empty folders', 'if on: Incoming and staging folders, to the Trash, logged'),
 ('AR',  'dec',   'after',  True,  'Remove finished items\nautomatically on?', ''),
 ('RM',  'end',   'after',  True,  'Row leaves the Queue', 'the file is where delivery put it'),
 ('KEEP','end',   'after',  True,  'Row stays with a checkmark', 'until Remove completed items or the next launch'),
]

# from, to, label, style('' or 'dashed'), in-pipeline-chart?
EDGES = [
 ('W','ED','Tag One File','',False), ('W','LS','Scan Library','',False), ('W','MB','Merge and Tag Files','',False),
 ('LS','ED','double-click a file','',False), ('LS','PI','Send to Queue\n(edited where it sits)','',False),
 ('DRP','TVH','','',False), ('TVH','PI','no: Movies tab','',False), ('TVH','TVQ','yes: TV Shows tab\n(on either tab; a folder with\nboth kinds is split)','',False), ('DRP','ED','Open a single file','',False),
 ('ED','SV','','',False), ('ED','STQ','','',False), ('STQ','PI','','',False),
 ('SV','REN','','',False), ('REN','DEL','folder sync on','',False),
 ('PI','ST','','',False), ('MB','PI','merged file becomes\na plain item','dashed',False),

 ('IF','DISC','','',True), ('DISC','SET','','',True), ('SET','TV','','',True),
 ('TV','TVQ','yes','',True), ('TV','ROW','no','',True),
 ('ROW','AA','','',True), ('AA','NR','no','',True), ('AA','REN2','yes','dashed',True),
 ('NR','REN2','approve','',True), ('NR','REJ','reject','',True), ('REJ','NR','reopen','dashed',True),
 ('REN2','NF','','',True),
 ('NF','MT','one','',True), ('NF','AMG','several','',True), ('AMG','SEV','no','',True), ('AMG','AMR','yes (about as big as\nthe other files together)','',True), ('AMR','MT','use the merged file','',True), ('AMR','MG','merge the parts anyway','',True),
 ('MT','RDY','yes','',True), ('MT','MR','no, or nothing found','',True), ('MR','RDY','','',True),
 ('SEV','AM','yes','',True), ('SEV','MRV','no','',True), ('AM','MG','','',True), ('MRV','MG','','',True),
 ('MG','MF','cannot merge','',True), ('MF','MRV','retry','dashed',True),
 ('MG','MT','merged file: same check\nas a single file','',True),
 ('RDY','ST','','',True), ('ST','ACT','','',True), ('ACT','DEL','','',True),

 ('DEL','RUL','yes','',True), ('DEL','STG','no','',True),
 ('RUL','RF','yes','',True), ('RUL','DF','no','',True),
 ('RF','AAF','','',True), ('DF','AAF','','',True),
 ('AAF','FILE','yes','',True), ('AAF','FOLD','no','',True),
 ('STG','FOLD','','',True),
 ('FILE','CL','','',True), ('FOLD','CL','','',True), ('FOLD','EF','after the run','dashed',True),
 ('CL','TR','yes','',True), ('CL','AR','no','',True), ('TR','AR','','',True),
 ('AR','RM','yes','',True), ('AR','KEEP','no','',True),
]

def esc_dot(s): return s.replace('"','\\"')

def html_label(title, detail, fg):
    t = '<BR/>'.join(escape(x) for x in title.split('\n'))
    out = '<<FONT COLOR="%s" POINT-SIZE="12"><B>%s</B></FONT>' % (fg, t)
    if detail:
        d = '<BR/>'.join(escape(x) for x in detail.split('\n'))
        out += '<BR/><FONT COLOR="%s" POINT-SIZE="10">%s</FONT>' % (fg, d)
    return out + '>'

def build_dot(pipeline):
    nodes = [n for n in NODES if (n[3] or not pipeline)]
    ids = {n[0] for n in nodes}
    edges = [e for e in EDGES if e[0] in ids and e[1] in ids and (e[4] or not pipeline)]
    lines = ['digraph G {',
      '  graph [rankdir=TB, fontname="Inter", bgcolor="white", nodesep=0.35, ranksep=0.42, pad=0.3, dpi=130, newrank=true, compound=true];',
      '  node  [fontname="Inter", style="rounded,filled", penwidth=1.3, margin="0.16,0.09"];',
      '  edge  [fontname="Inter", fontsize=10, color="#4a5b6c", fontcolor="#33414f", arrowsize=0.8];']
    for lane, title in LANES.items():
        members = [n for n in nodes if n[2] == lane]
        if not members: continue
        lines.append('  subgraph cluster_%s {' % lane)
        lines.append('    label="%s"; fontname="Inter"; fontsize=13; fontcolor="#33414f"; style="rounded"; color="#c4ccd4"; labeljust=l; margin=14;' % esc_dot(title))
        for i, k, _, _, t, d in members:
            fill, stroke, fg, shape = KINDS[k]
            sty = 'filled' if shape == 'diamond' else 'rounded,filled'
            lines.append('    %s [label=%s, shape=%s, style="%s", fillcolor="%s", color="%s"%s];' %
                         (i, html_label(t, d, fg), shape, sty, fill, stroke, ', margin="0.05,0.05"' if shape=='diamond' else ''))
        lines.append('  }')
    for a, b, lab, sty, _ in edges:
        attrs = []
        if lab: attrs.append('label="%s"' % esc_dot(lab).replace('\n', '\\n'))
        if sty: attrs.append('style=%s' % sty)
        lines.append('  %s -> %s%s;' % (a, b, ' [%s]' % ', '.join(attrs) if attrs else ''))
    lines.append('}')
    return '\n'.join(lines), nodes, edges

def drawio(dotsrc, nodes, edges, title):
    js = json.loads(subprocess.run(['dot', '-Tjson'], input=dotsrc, capture_output=True, text=True, check=True).stdout)
    bb = [float(x) for x in js['bb'].split(',')]
    H = bb[3]
    byname = {o['name']: o for o in js['objects'] if 'pos' in o}
    cells = ['<mxCell id="0"/>', '<mxCell id="1" parent="0"/>']
    nid = {}
    counter = [2]
    def nxt():
        counter[0] += 1; return str(counter[0])
    # lanes first so they sit behind
    for o in js['objects']:
        if o['name'].startswith('cluster_'):
            lane = o['name'][len('cluster_'):]
            x1, y1, x2, y2 = [float(v) for v in o['bb'].split(',')]
            cid = nxt()
            cells.append('<mxCell id="%s" value="%s" style="rounded=1;whiteSpace=wrap;html=1;fillColor=none;strokeColor=#c4ccd4;dashed=1;verticalAlign=top;align=left;spacingLeft=10;fontSize=13;fontColor=#33414f;arcSize=3;" vertex="1" parent="1"><mxGeometry x="%.0f" y="%.0f" width="%.0f" height="%.0f" as="geometry"/></mxCell>'
                         % (cid, escape(LANES[lane]), x1, H - y2, x2 - x1, y2 - y1))
    for i, k, lane, _, t, d in nodes:
        o = byname[i]
        cx, cy = [float(v) for v in o['pos'].split(',')]
        w, h = float(o['width']) * 72, float(o['height']) * 72
        fill, stroke, fg, shape = KINDS[k]
        style = ('rhombus;' if shape == 'diamond' else 'rounded=1;') + 'whiteSpace=wrap;html=1;fillColor=%s;strokeColor=%s;fontColor=%s;fontSize=12;' % (fill, stroke, fg)
        val = '<b>%s</b>' % '<br>'.join(escape(x) for x in t.split('\n'))
        if d: val += '<br><font style="font-size:10px">%s</font>' % '<br>'.join(escape(x) for x in d.split('\n'))
        cid = nxt(); nid[i] = cid
        cells.append('<mxCell id="%s" value="%s" style="%s" vertex="1" parent="1"><mxGeometry x="%.0f" y="%.0f" width="%.0f" height="%.0f" as="geometry"/></mxCell>'
                     % (cid, escape(val, {'"': '&quot;'}), style, cx - w / 2, H - cy - h / 2, w, h))
    for a, b, lab, sty, _ in edges:
        cid = nxt()
        st = 'edgeStyle=orthogonalEdgeStyle;rounded=1;html=1;endArrow=block;endFill=1;strokeColor=#4a5b6c;fontSize=10;' + ('dashed=1;' if sty else '')
        cells.append('<mxCell id="%s" value="%s" style="%s" edge="1" parent="1" source="%s" target="%s"><mxGeometry relative="1" as="geometry"/></mxCell>'
                     % (cid, escape(lab.replace('\n', ' ')), st, nid[a], nid[b]))
    return ('<mxfile host="app.diagrams.net"><diagram id="flow" name="%s"><mxGraphModel dx="1400" dy="900" grid="1" gridSize="10" guides="1" tooltips="1" connect="1" arrows="1" fold="1" page="0" math="0" shadow="0"><root>%s</root></mxGraphModel></diagram></mxfile>'
            % (escape(title), ''.join(cells)))

def main(doc):
    for sub in ('images', 'images/src', 'diagrams'):
        os.makedirs(os.path.join(doc, sub), exist_ok=True)
    for name, pipeline in (('app-flow', False), ('pipeline', True)):
        src, nodes, edges = build_dot(pipeline)
        dot = os.path.join(doc, 'images/src', name + '.dot')
        open(dot, 'w').write(src)
        subprocess.run(['dot', '-Tpng', dot, '-o', os.path.join(doc, 'images', name + '.png')], check=True)
        if not pipeline:
            open(os.path.join(doc, 'diagrams/M3-app-flow.drawio'), 'w').write(drawio(src, nodes, edges, 'M3 complete flow'))

if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else 'Documentation')
