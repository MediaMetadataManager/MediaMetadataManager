#!/usr/bin/env python3
#
#  check_stale.py
#
#             Media Metadata Manager
#                       M3
#  Created by: Hans Hoffmeister on 10/16/2026.
#
"""Report which documentation screenshots may be out of date.

Usage:
  check_stale.py <repo root> [--docs Documentation] [--fail] [--markdown out.md]
  check_stale.py <repo root> --mark-ok queue-movies-tab.png [more.png ...]

For each screenshot in images/screens/manifest.json:
  MISSING  the PNG is not there yet
  STALE    a source file listed for it changed after the screenshot was taken
  OK       nothing relevant changed since
  UNKNOWN  the manifest lists no 'sources' for it
The screenshot's time is its last Git commit (or its file time when it is new or modified),
or the time you last confirmed it with --mark-ok (kept in images/screens/reviewed.json),
whichever is later. A source file's time is its last Git commit (or its file time when it
has uncommitted changes). 'sources' are repo-relative paths or globs ('**' allowed).
Patterns that match no file are reported, so a wrong guess shows up instead of hiding.
--fail exits with status 1 when anything is MISSING or STALE (for a release gate).
"""
import json, os, subprocess, sys, glob, time, datetime

args = sys.argv[1:]
repo = os.path.abspath(args[0])
docs = args[args.index('--docs') + 1] if '--docs' in args else 'Documentation'
shots = os.path.join(repo, docs, 'images', 'screens')
manifest = json.load(open(os.path.join(shots, 'manifest.json'), encoding='utf-8'))
reviewed_path = os.path.join(shots, 'reviewed.json')
reviewed = json.load(open(reviewed_path)) if os.path.exists(reviewed_path) else {}

def git(*a):
    return subprocess.run(['git', '-C', repo] + list(a), capture_output=True, text=True).stdout

if '--mark-ok' in args:
    now = int(time.time())
    for f in args[args.index('--mark-ok') + 1:]:
        if f.startswith('--'): break
        reviewed[os.path.basename(f)] = now
    json.dump(reviewed, open(reviewed_path, 'w'), indent=2, sort_keys=True)
    print('marked as confirmed:', ', '.join(sorted(os.path.basename(f) for f in args[args.index('--mark-ok') + 1:] if not f.startswith('--'))))
    sys.exit(0)

dirty = set()
for line in git('status', '--porcelain').splitlines():
    p = line[3:].strip().strip('"')
    if ' -> ' in p: p = p.split(' -> ')[1]
    dirty.add(p)

def file_time(rel):
    """Last change time of a repo-relative path: file time if uncommitted, else last commit."""
    if rel in dirty or any(d.startswith(rel.rstrip('/') + '/') for d in dirty):
        return int(os.path.getmtime(os.path.join(repo, rel))) if os.path.exists(os.path.join(repo, rel)) else int(time.time())
    out = git('log', '-1', '--format=%ct', '--', rel).strip()
    return int(out) if out else int(os.path.getmtime(os.path.join(repo, rel)))

def expand(pattern):
    hits = glob.glob(os.path.join(repo, pattern), recursive=True)
    return sorted(os.path.relpath(h, repo) for h in hits if os.path.isfile(h))

def fmt(t): return datetime.datetime.fromtimestamp(t).strftime('%Y-%m-%d %H:%M')

rows = []; problems = []
for s in manifest['screens']:
    f = s['file']; rel = os.path.join(docs, 'images', 'screens', f)
    if not os.path.exists(os.path.join(repo, rel)):
        rows.append(('MISSING', f, 'no file yet', [])); continue
    srcs = s.get('sources') or []
    if not srcs:
        rows.append(('UNKNOWN', f, 'no sources listed in the manifest', [])); continue
    shot_time = max(file_time(rel), reviewed.get(f, 0))
    changed = []; matched_any = False
    for pat in srcs:
        for sf in expand(pat):
            matched_any = True
            t = file_time(sf)
            if t > shot_time:
                changed.append((t, sf))
    if not matched_any:
        problems.append(f'{f}: none of its source patterns match a file ({", ".join(srcs)}); fix "sources" in manifest.json')
    if changed:
        changed.sort(reverse=True)
        names = [c[1] for c in changed[:4]]
        more = f' (+{len(changed)-4} more)' if len(changed) > 4 else ''
        subj = git('log', '-1', '--format=%s', '--', changed[0][1]).strip() or 'uncommitted change'
        rows.append(('STALE', f, f'screenshot {fmt(shot_time)}; changed {fmt(changed[0][0])}: ' + ', '.join(names) + more + f'  [{subj[:70]}]', changed))
    else:
        rows.append(('OK', f, f'screenshot {fmt(shot_time)}', []))

order = {'STALE': 0, 'MISSING': 1, 'UNKNOWN': 2, 'OK': 3}
rows.sort(key=lambda r: (order[r[0]], r[1]))
counts = {k: sum(1 for r in rows if r[0] == k) for k in order}
lines = [f"Screenshots: {counts['STALE']} stale, {counts['MISSING']} missing, {counts['UNKNOWN']} unknown, {counts['OK']} ok"]
for st, f, why, _ in rows: lines.append(f'  {st:8} {f}  {why}')
if problems:
    lines.append('Problems with the manifest:')
    lines += [f'  {p}' for p in problems]
print('\n'.join(lines))
if '--markdown' in args:
    out = args[args.index('--markdown') + 1]
    md = ['# Screenshots to retake', '', f'Checked {fmt(int(time.time()))}.', '']
    todo = [r for r in rows if r[0] in ('STALE', 'MISSING')]
    if not todo: md.append('Nothing to retake.')
    for st, f, why, _ in todo:
        sh = next(s for s in manifest['screens'] if s['file'] == f)
        md += [f'- [ ] `{f}` ({st.lower()}): {sh["show"]}', f'  - Set up: {sh["setup"]}', f'  - {why}']
    open(out, 'w').write('\n'.join(md) + '\n')
sys.exit(1 if ('--fail' in args and (counts['STALE'] or counts['MISSING'])) else 0)
