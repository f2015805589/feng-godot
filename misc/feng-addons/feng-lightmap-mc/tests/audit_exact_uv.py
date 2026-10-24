"""Independent exact-rational UV overlap audit for audit_actual_uv.gd snapshots.
Float32 values are restored exactly; no epsilon/sliver tolerance is used.
"""
import json
import struct
import sys
from fractions import Fraction
from pathlib import Path


def v2(v):
    return tuple(Fraction(struct.unpack("f", struct.pack("f",c))[0]) for c in v)


def cross(a,b):
    return a[0]*b[1]-a[1]*b[0]


def sub(a,b):
    return a[0]-b[0], a[1]-b[1]


def area(poly):
    if len(poly)<3:
        return Fraction(0)
    # Translation-invariant fan, exact arithmetic regardless of location.
    return sum((cross(sub(poly[i],poly[0]),sub(poly[i+1],poly[0])) for i in range(1,len(poly)-1)),Fraction(0))/2


def intersect(subject,clip):
    orient=1 if area(clip)>0 else -1
    out=subject
    for a,b in zip(clip,clip[1:]+clip[:1]):
        if not out:
            break
        edge=sub(b,a)
        side=lambda p: orient*cross(edge,sub(p,a))
        result=[]
        previous=out[-1]
        ps=side(previous)
        for current in out:
            cs=side(current)
            if (ps>=0)!=(cs>=0):
                t=ps/(ps-cs)
                result.append((previous[0]+(current[0]-previous[0])*t,previous[1]+(current[1]-previous[1])*t))
            if cs>=0:
                result.append(current)
            previous,ps=current,cs
        out=result
    return out


def main():
    path=Path(sys.argv[1])
    meshes=json.loads(path.read_text(encoding="utf-8"))
    report=[]
    for mesh in meshes:
        triangles=[([v2(v) for v in t["uv"]],t["global_id"]) for t in mesh["triangles"]]
        bounds=[(min(p[0] for p in v),max(p[0] for p in v),min(p[1] for p in v),max(p[1] for p in v)) for v,_ in triangles]
        active=[]
        overlaps=[]
        tests=0
        for i in sorted(range(len(triangles)), key=lambda j:bounds[j][0]):
            ib=bounds[i]
            active=[j for j in active if bounds[j][1]>ib[0]]
            for j in active:
                jb=bounds[j]
                if min(ib[1],jb[1])<=max(ib[0],jb[0]) or min(ib[3],jb[3])<=max(ib[2],jb[2]):
                    continue
                tests+=1
                overlap=abs(area(intersect(triangles[i][0],triangles[j][0])))
                if overlap>0:
                    overlaps.append({"global_ids":[triangles[i][1],triangles[j][1]],"exact_area":str(overlap),"area":float(overlap)})
            active.append(i)
        row={"path":mesh["path"],"triangle_count":len(triangles),"exact_pair_tests":tests,"positive_overlap_count":len(overlaps),"overlaps":overlaps}
        report.append(row)
        print(json.dumps({k:v for k,v in row.items() if k!="overlaps"},ensure_ascii=False))
    output=path.with_name("actual_uv_exact_audit.json")
    output.write_text(json.dumps({"method":"exact rational float32 triangle intersection, zero epsilon", "meshes":report},ensure_ascii=False,indent=2),encoding="utf-8")
    print(output)
    return 1 if any(r["positive_overlap_count"] for r in report) else 0

if __name__=="__main__":
    raise SystemExit(main())
