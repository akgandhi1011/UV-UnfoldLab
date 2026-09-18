#!/usr/bin/env python3
"""Regression against the user's real Desired OBJ.

Checks structural equivalence, not seam phase on symmetric geometry:
- exact chart/island count per object
- generated seam count within 20% of the Desired UV seam count (minimum slack 2)

OBJ UV seams are detected from UV coordinates, not texture-vertex IDs.
"""
from collections import defaultdict
import math, os, subprocess, sys, tempfile

HERE=os.path.dirname(os.path.abspath(__file__))
REF=os.path.join(HERE,'reference','desiredresult.obj')

def parse_obj(path):
    vs=[];vts=[];objs=defaultdict(list);cur='default'
    for line in open(path,encoding='utf-8',errors='ignore'):
        if line.startswith('v '):
            p=line.split();vs.append(tuple(map(float,p[1:4])))
        elif line.startswith('vt '):
            p=line.split();vts.append(tuple(map(float,p[1:3])))
        elif line.startswith('o '): cur=line.split(maxsplit=1)[1].strip()
        elif line.startswith('f '):
            cs=[]
            for tok in line.split()[1:]:
                a=tok.split('/');cs.append((int(a[0]),int(a[1]) if len(a)>1 and a[1] else 0))
            for k in range(1,len(cs)-1): objs[cur].append([cs[0],cs[k],cs[k+1]])
    return vs,vts,objs

def uvkey(vts,ti,eps=1e-6):
    if not ti:return None
    u,v=vts[ti-1];return (round(u/eps),round(v/eps))

def uv_seams(faces,vts):
    inc=defaultdict(list)
    for f in faces:
        for k in range(3):
            a,b=f[k],f[(k+1)%3];e=tuple(sorted((a[0],b[0])))
            pair=(uvkey(vts,a[1]),uvkey(vts,b[1])) if a[0]<b[0] else (uvkey(vts,b[1]),uvkey(vts,a[1]))
            inc[e].append(pair)
    return {e for e,x in inc.items() if len(x)==2 and x[0]!=x[1]}

def write_geom_obj(path,vs,faces):
    used=sorted({vi for f in faces for vi,_ in f});mp={v:i+1 for i,v in enumerate(used)}
    with open(path,'w') as out:
        for v in used:
            x,y,z=vs[v-1];out.write(f'v {x} {y} {z}\n')
        for f in faces: out.write('f '+' '.join(str(mp[vi]) for vi,_ in f)+'\n')
    return {i+1:v for i,v in enumerate(used)}

def read_seams(path,inv):
    out=set()
    for line in open(path):
        p=line.split()
        if p and p[0]=='SEAM':out.add(tuple(sorted((inv[int(p[1])],inv[int(p[2])]))) )
    return out

def chart_count(faces,cuts):
    ef=defaultdict(list)
    for fi,f in enumerate(faces):
        for k in range(3):ef[tuple(sorted((f[k][0],f[(k+1)%3][0])))].append(fi)
    adj=[[] for _ in faces]
    for e,L in ef.items():
        if len(L)==2 and e not in cuts:
            a,b=L;adj[a].append(b);adj[b].append(a)
    seen=set();n=0
    for s in range(len(faces)):
        if s in seen:continue
        n+=1;stack=[s];seen.add(s)
        while stack:
            i=stack.pop()
            for j in adj[i]:
                if j not in seen:seen.add(j);stack.append(j)
    return n

def main():
    if len(sys.argv)<2:
        print('usage: run_reference_regression.py <autoseam-worker>',file=sys.stderr);return 2
    worker=sys.argv[1];vs,vts,objs=parse_obj(REF);fail=0
    for name in sorted(objs,key=lambda x:int(x)):
        faces=objs[name];target=uv_seams(faces,vts);tc=chart_count(faces,target)
        with tempfile.TemporaryDirectory() as td:
            obj=os.path.join(td,'mesh.obj');sp=os.path.join(td,'out.seams');inv=write_geom_obj(obj,vs,faces)
            p=subprocess.run([worker,obj,sp],capture_output=True,text=True)
            if p.returncode!=0:
                print(f'{name}: FAIL worker exit {p.returncode}');fail+=1;continue
            pred=read_seams(sp,inv)
        pc=chart_count(faces,pred);tol=max(2,math.ceil(len(target)*0.20));ok=(pc==tc and abs(len(pred)-len(target))<=tol)
        print(f'{name}: {"PASS" if ok else "FAIL"} charts {pc}/{tc} seams {len(pred)}/{len(target)} tol ±{tol}')
        if not ok:fail+=1
    print(f'\n{len(objs)-fail}/{len(objs)} reference objects passed')
    return 1 if fail else 0
if __name__=='__main__':raise SystemExit(main())
