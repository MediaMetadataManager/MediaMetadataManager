#
#  pages.py
#
#             Media Metadata Manager
#                       M3
#  Created by: Hans Hoffmeister on 10/16/2026.
#
import sys, subprocess
name=sys.argv[1]
heads=open(f'heads_{name}.txt',encoding='utf-8').read().split('\n')
n=int(subprocess.check_output(['pdfinfo',f'{name}.new.pdf']).decode().split('Pages:')[1].split()[0])
txt=[subprocess.check_output(['pdftotext','-f',str(i),'-l',str(i),'-layout',f'{name}.new.pdf','-']).decode() for i in range(1,n+1)]
cur=1; out=[]
for h in heads:
    found=None
    for pg in range(cur,n+1):
        for l in txt[pg-1].split('\n'):
            l=l.strip()
            if l==h.strip() and '....' not in l: found=pg; break
        if found: break
    if not found: print('NOT FOUND',h); found=cur
    cur=found; out.append(f'{found}\t{h}')
open(f'pages_{name}.txt','w',encoding='utf-8').write('\n'.join(out)+'\n')
print(name,out[:4],'...',out[-1])
