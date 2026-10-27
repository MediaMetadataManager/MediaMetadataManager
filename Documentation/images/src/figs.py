#
#  figs.py
#
#             Media Metadata Manager
#                       M3
#  Created by: Hans Hoffmeister on 10/09/2026.
#
# Draws architecture.png, queue-model.png and timeline.png for the Design and Project Manual.
# Run from the repository root: python3 Documentation/images/src/figs.py
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch
from matplotlib import font_manager as fm
import datetime as dt
for f in fm.findSystemFonts():
    if 'Inter' in f: fm.fontManager.addfont(f)
plt.rcParams['font.family']='Inter'

def box(ax,x,y,w,h,text,fc='white',ec='#2b5d8a',fs=9,bold=False,tc='#1d2b3a'):
    ax.add_patch(FancyBboxPatch((x,y),w,h,boxstyle="round,pad=0,rounding_size=0.012",fc=fc,ec=ec,lw=1.1))
    ax.text(x+w/2,y+h/2,text,ha='center',va='center',fontsize=fs,color=tc,fontweight='bold' if bold else 'normal',linespacing=1.35)

# ---------- architecture layers
fig,ax=plt.subplots(figsize=(10,6.4)); ax.set_xlim(0,1); ax.set_ylim(0,1); ax.axis('off')
layers=[
 ('Interface layer','AppKit windows, sheets, toolbars',0.77,'#e6f0fa','#2b5d8a',
   ['Welcome\nwindow','Queue window\nMovies and\nTV Shows tabs','Single-file\neditor','Settings','Review windows\nnaming, metadata,\nmerge order','Library scan\ntag columns, Edit,\nSend to Queue']),
 ('Workflow layer','M3-specific logic built on the Queue',0.53,'#fff4d6','#c79a1c',
   ['Intake watching\nwatcher + scanner','QueueController\n(one per tab)','QueueRow /\nQueueRelease','Queue actions\nmetadata, name, move,\ncleanup']),
 ('Service layer','reusable building blocks',0.29,'#e9f5ee','#2f7d4f',
   ['Metadata providers\nbuilt-in, custom JSON,\nplugins','ReleaseFilename-\nParser','Naming rules\n(tokens)','FileMerger +\nMergeCompatibility','Sets and\nQueue presets']),
 ('Foundation layer','MP42Foundation (Objective-C / C)',0.05,'#efe6f5','#8061a0',
   ['MP42File, tracks,\nmetadata, undo','Importers\nmp4, mkv, raw, concat','Muxer','mp4v2, FFmpeg,\nOCR libraries']),
]
for title,sub,y,fc,ec,items in layers:
    ax.add_patch(FancyBboxPatch((0.01,y),0.98,0.2,boxstyle="round,pad=0.005,rounding_size=0.015",fc=fc,ec=ec,lw=1.4))
    ax.text(0.03,y+0.172,title,fontsize=11,fontweight='bold',color=ec,va='center')
    ax.text(0.97,y+0.172,sub,fontsize=8.5,color='#4a5b6c',va='center',ha='right')
    n=len(items); gap=0.014; w=(0.94-gap*(n-1))/n
    for i,t in enumerate(items):
        box(ax,0.03+i*(w+gap),y+0.02,w,0.12,t,ec=ec,fs=8.2)
for y in (0.75,0.51,0.27):
    ax.annotate('',xy=(0.5,y-0.012),xytext=(0.5,y+0.015),arrowprops=dict(arrowstyle='-|>',color='#4a5b6c',lw=1.5))
fig.savefig('Documentation/images/architecture.png',dpi=190,bbox_inches='tight',facecolor='white'); plt.close(fig)

# ---------- queue model
# The green box holds four lines; it is wide and tall enough that none of them touches the border.
fig,ax=plt.subplots(figsize=(10,5.2)); ax.set_xlim(0,1); ax.set_ylim(0,1); ax.axis('off')
box(ax,0.30,0.86,0.40,0.12,'Queue: ordered list of QueueRow, saved to disk',fc='#e6f0fa',fs=9,bold=True)
box(ax,0.36,0.66,0.28,0.12,'QueueRow\nwraps exactly one of:',fc='white',fs=9)
box(ax,0.06,0.40,0.30,0.16,'QueueItem\none file, one destination\n(drag-and-drop, Open, AppleScript)',fc='#e6f0fa',fs=8.6)
box(ax,0.64,0.40,0.30,0.16,'QueueRelease\none folder of files, with a stage\n(Intake path)',fc='#fff4d6',ec='#c79a1c',fs=8.6)
box(ax,0.14,0.03,0.72,0.24,'effectiveItem: the QueueItem the work loop processes\nplain row: the item itself\nrelease row: its resolvedItem, once naming, metadata\nand merge are settled (none before that)',fc='#e9f5ee',ec='#2f7d4f',fs=8.6)
for (x1,y1,x2,y2) in [(0.5,0.86,0.5,0.78),(0.43,0.66,0.25,0.56),(0.57,0.66,0.75,0.56),(0.75,0.40,0.66,0.27),(0.25,0.40,0.34,0.27)]:
    ax.annotate('',xy=(x2,y2),xytext=(x1,y1),arrowprops=dict(arrowstyle='-|>',color='#4a5b6c',lw=1.4))
fig.savefig('Documentation/images/queue-model.png',dpi=190,bbox_inches='tight',facecolor='white'); plt.close(fig)

# ---------- timeline
D=dt.date
rows=[
 ('Fork baseline, Custom Sources tab',D(2026,9,10),D(2026,9,11),'#2b5d8a'),
 ('Intake Manager v1, plugins, overwrite/append',D(2026,9,14),D(2026,9,21),'#2b5d8a'),
 ('Lossless merge backend',D(2026,9,21),D(2026,9,23),'#8061a0'),
 ('Workflow phases 1-2, Queue Merge button, reorder sheet',D(2026,9,24),D(2026,9,24),'#c79a1c'),
 ('Phases 3-8, rebrand to M3, plugins to own repos',D(2026,9,26),D(2026,9,28),'#c79a1c'),
 ('Filename rule editor, live merge preview',D(2026,9,27),D(2026,9,29),'#8061a0'),
 ('Phases 9-12, Welcome window, library scan, folder sync',D(2026,9,30),D(2026,10,2),'#c79a1c'),
 ('Upstream ports, modern APIs, undo/redo series',D(2026,10,3),D(2026,10,6),'#2f7d4f'),
 ('Edit+Save move recovery, search-sheet fixes',D(2026,10,6),D(2026,10,7),'#8061a0'),
 ('Live Intake: watching, multi-folder, TV queue, cleanup',D(2026,10,8),D(2026,10,9),'#c79a1c'),
 ('Documentation set',D(2026,10,9),D(2026,10,9),'#2f7d4f'),
 ('Releases 1.0.0 to 1.0.6, Sparkle, Media Locations, unit tests',D(2026,10,10),D(2026,10,11),'#2f7d4f'),
 ('Queue: one window with tabs, sorting, folder rows (1.1.0)',D(2026,10,11),D(2026,10,13),'#c79a1c'),
 ('Time-limited run, TV routing, crash hardening (1.1.1)',D(2026,10,13),D(2026,10,15),'#c79a1c'),
 ('Library scan: tag columns, Edit, Send to Queue, Pause, Clear',D(2026,10,16),D(2026,10,17),'#8061a0'),
 ('GPL notices, test plan, screenshots, guides rebuilt',D(2026,10,15),D(2026,10,17),'#2f7d4f'),
]
fig,ax=plt.subplots(figsize=(10,5.6))
x0=D(2026,9,9)
for i,(lab,s,e,c) in enumerate(rows[::-1]):
    w=(e-s).days+0.7
    ax.barh(i,w,left=matplotlib.dates.date2num(s),color=c,height=0.55,alpha=0.92)
    ax.text(matplotlib.dates.date2num(x0),i,lab,ha='right',va='center',fontsize=8.3,color='#1d2b3a')
ax.set_yticks([]); ax.xaxis_date(); ax.set_xlim(matplotlib.dates.date2num(x0),matplotlib.dates.date2num(D(2026,10,19)))
import matplotlib.dates as md
ax.xaxis.set_major_locator(md.DayLocator(interval=7)); ax.xaxis.set_major_formatter(md.DateFormatter('%b %d'))
for s in ('top','right','left'): ax.spines[s].set_visible(False)
ax.tick_params(axis='x',labelsize=8.5,colors='#4a5b6c'); ax.grid(axis='x',color='#e3e8ee',lw=0.8); ax.set_axisbelow(True)
fig.subplots_adjust(left=0.52)
fig.savefig('Documentation/images/timeline.png',dpi=190,bbox_inches='tight',facecolor='white'); plt.close(fig)
