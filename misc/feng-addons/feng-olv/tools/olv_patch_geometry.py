"""Observed physical patch footprints, independent of indoor/outdoor labels.

One distance table per center and coplanar patch replaces the normally weak
dominant-normal AABB component. Ray count, token width and model weights do not
grow. The caller supplies the same edge-connected patch components used by the
legacy extent extractor. No semantic shells, probe labels or model are used.
"""
import collections
import math
import numpy as np


def _outer_segments(triangles, candidates, normal):
    """Split edges at crossings/T-junctions and discard union-internal edges."""
    triangles=np.asarray(triangles,dtype='f8');axis=int(np.abs(normal).argmax())
    axes=[i for i in range(3) if i!=axis];origin=triangles[0,0]
    flat=(triangles-origin)[...,axes];a=flat[:,0];e1=flat[:,1]-a;e2=flat[:,2]-a
    all_start=flat[:,[0,1,2]].reshape(-1,2);all_end=flat[:,[1,2,0]].reshape(-1,2)
    other=all_end-all_start;scale=max(1.,float(np.ptp(flat,axis=(0,1)).max()))
    cross=lambda x,y:x[...,0]*y[...,1]-x[...,1]*y[...,0]
    den=cross(e1,e2)
    def covered(points):
        delta=points[:,None,:]-a
        u=cross(delta,e2)/den;v=cross(e1,delta)/den
        return ((u>=0)&(v>=0)&(u+v<=1)).any(1)
    output=[]
    for start,end in candidates:
        first=(start-origin)[axes];d=(end-start)[axes];length2=float(d@d)
        if length2<1e-28:continue
        delta=all_start-first;div=cross(d,other);parallel=np.abs(div)<=1e-14*scale*scale
        safe=np.where(parallel,1.,div);t=cross(delta,other)/safe;u=cross(delta,d)/safe
        values=[0.,1.];mask=(~parallel)&(t>0)&(t<1)&(u>=-1e-10)&(u<=1+1e-10)
        values.extend(t[mask]);collinear=parallel&(np.abs(cross(delta,d))<=1e-12*scale*scale)
        for endpoints in (all_start,all_end):
            location=((endpoints-first)*d).sum(1)/length2
            values.extend(location[collinear&(location>0)&(location<1)])
        values=sorted(values);splits=[values[0]]
        for value in values[1:]:
            if value-splits[-1]>1e-11:splits.append(float(value))
        starts=np.asarray(splits[:-1]);ends=np.asarray(splits[1:]);middle=(starts+ends)/2
        side=np.array([-d[1],d[0]])/math.sqrt(length2)
        epsilon=np.minimum((ends-starts)*math.sqrt(length2)*1e-5,max(scale*1e-9,1e-8))
        center=first+middle[:,None]*d
        boundary=covered(center+epsilon[:,None]*side)!=covered(center-epsilon[:,None]*side)
        for t0,t1 in zip(starts[boundary],ends[boundary]):output.append((start+(end-start)*t0,start+(end-start)*t1))
    if not output:raise ValueError('observed coplanar patch has no finite external boundary')
    return output


class PatchFootprints:
    def __init__(self, triangles, triangle_normals, roots):
        self.triangles=np.asarray(triangles,dtype='f8').reshape(-1,3,3)
        _,first,self.triangle_patch_ids=np.unique(roots,return_index=True,return_inverse=True)
        self.patch_count=len(first)
        self.normals=np.asarray(triangle_normals,dtype='f8')[first]
        self.dominant_axes=np.abs(self.normals).round(12).argmax(1)
        self.a=self.triangles[:,0]
        self.e1=self.triangles[:,1]-self.a;self.e2=self.triangles[:,2]-self.a
        self.d00=(self.e1*self.e1).sum(1);self.d01=(self.e1*self.e2).sum(1);self.d11=(self.e2*self.e2).sum(1)
        self.den=self.d00*self.d11-self.d01*self.d01
        if np.any(self.den<=0):raise ValueError('degenerate observed patch triangle')
        groups=collections.defaultdict(dict)
        for index,face in enumerate(self.triangles):
            patch=int(self.triangle_patch_ids[index]);points=[v.astype('<f4').tobytes() for v in face]
            triangle_key=tuple(sorted(points))
            for i,j in ((0,1),(1,2),(2,0)):
                key=tuple(sorted((points[i],points[j])))
                entry=groups[patch].setdefault(key,[face[i],face[j],set()])
                entry[2].add(triangle_key)
        starts=[];ends=[];patch_ids=[]
        for patch,edges in sorted(groups.items()):
            # Duplicate faces do not erase a physical boundary. A rare
            # nonmanifold patch with no single-use edges keeps all edges.
            boundary=[edge for edge in edges.values() if len(edge[2])==1]
            candidates=[(edge[0],edge[1]) for edge in boundary or list(edges.values())]
            physical=_outer_segments(self.triangles[self.triangle_patch_ids==patch],candidates,self.normals[patch])
            for start,end in physical:
                starts.append(start);ends.append(end);patch_ids.append(patch)
        self.starts=np.asarray(starts,dtype='f8');self.edge_vectors=np.asarray(ends,dtype='f8')-self.starts
        self.edge_lengths=(self.edge_vectors*self.edge_vectors).sum(1)
        self.edge_patch_ids=np.asarray(patch_ids,dtype='i8')
        self.edge_normals=self.normals[self.edge_patch_ids]
        self.edge_keys=set().union(*(set(edges) for edges in groups.values()))
        self._refresh_bounds()
        self._device_cache={}

    def _refresh_bounds(self):
        self.bounds_low=np.full((self.patch_count,3),float('inf'))
        self.bounds_high=np.full((self.patch_count,3),-float('inf'))
        np.minimum.at(self.bounds_low,self.triangle_patch_ids,self.triangles.min(1))
        np.maximum.at(self.bounds_high,self.triangle_patch_ids,self.triangles.max(1))

    @classmethod
    def concatenated(cls, parts):
        """Reuse disjoint exact-edge components; shared-edge meshes need a rebuild."""
        seen=set()
        for part in parts:
            if seen&part.edge_keys:return None
            seen.update(part.edge_keys)
        result=cls.__new__(cls)
        names=('triangles','normals','a','e1','e2','d00','d01','d11','den','starts',
               'edge_vectors','edge_lengths','edge_normals','dominant_axes','bounds_low','bounds_high')
        for name in names:setattr(result,name,np.concatenate([getattr(p,name) for p in parts]))
        offset=0;triangles=[];edges=[]
        for part in parts:
            triangles.append(part.triangle_patch_ids+offset);edges.append(part.edge_patch_ids+offset)
            offset+=part.patch_count
        result.patch_count=offset;result.triangle_patch_ids=np.concatenate(triangles)
        result.edge_patch_ids=np.concatenate(edges);result.edge_keys=seen;result._device_cache={}
        return result

    def rotated(self, matrix):
        """Exact coordinate permutations used by physically traced quarter views."""
        matrix=np.asarray(matrix,dtype='f8')
        if matrix.shape!=(3,3) or not np.isin(matrix,[-1.,0.,1.]).all() or not np.array_equal(matrix@matrix.T,np.eye(3)):
            raise ValueError('cache rotation requires an exact signed coordinate permutation')
        result=type(self).__new__(type(self));result.triangles=self.triangles@matrix.T
        result.triangles[result.triangles==0]=0.
        result.triangle_patch_ids=self.triangle_patch_ids.copy();result.patch_count=self.patch_count
        result.a=result.triangles[:,0];result.e1=result.triangles[:,1]-result.a;result.e2=result.triangles[:,2]-result.a
        result.d00=(result.e1*result.e1).sum(1);result.d01=(result.e1*result.e2).sum(1);result.d11=(result.e2*result.e2).sum(1)
        result.den=result.d00*result.d11-result.d01*result.d01
        normal=np.cross(result.e1,result.e2);normal/=np.linalg.norm(normal,axis=1)[:,None]
        _,first=np.unique(result.triangle_patch_ids,return_index=True);result.normals=normal[first]
        result.dominant_axes=np.abs(result.normals).round(12).argmax(1)
        result.starts=self.starts@matrix.T;result.edge_vectors=self.edge_vectors@matrix.T
        result.edge_lengths=(result.edge_vectors*result.edge_vectors).sum(1)
        result.edge_patch_ids=self.edge_patch_ids.copy();result.edge_normals=result.normals[result.edge_patch_ids]
        result._refresh_bounds();result._device_cache={};result.edge_keys=set()
        for face in result.triangles:
            points=[v.astype('<f4').tobytes() for v in face]
            for i,j in ((0,1),(1,2),(2,0)):result.edge_keys.add(tuple(sorted((points[i],points[j]))))
        return result

    def numpy_signed_distances(self, centers):
        centers=np.asarray(centers,dtype='f8').reshape(-1,3)
        delta=centers[:,None,:]-self.a
        d20=(delta*self.e1).sum(-1);d21=(delta*self.e2).sum(-1)
        u=(self.d11*d20-self.d01*d21)/self.den;v=(self.d00*d21-self.d01*d20)/self.den
        covered=(u>=-1e-10)&(v>=-1e-10)&(u+v<=1+1e-10)
        delta=centers[:,None,:]-self.starts
        t=np.clip((delta*self.edge_vectors).sum(-1)/self.edge_lengths,0,1)
        residual=delta-t[:,:,None]*self.edge_vectors
        residual-=self.edge_normals*(residual*self.edge_normals).sum(-1,keepdims=True)
        distance2=(residual*residual).sum(-1)
        output=np.empty((len(centers),self.patch_count),dtype='f8')
        for patch in range(self.patch_count):
            inside=covered[:,self.triangle_patch_ids==patch].any(1)
            distance=np.sqrt(distance2[:,self.edge_patch_ids==patch].min(1))
            output[:,patch]=np.where(inside,-distance,distance)
        return output

    def torch_signed_distances(self, torch, centers):
        key=str(centers.device)
        if key not in self._device_cache:
            self._device_cache[key]={name:torch.as_tensor(getattr(self,name),device=centers.device)
                for name in ('a','e1','e2','d00','d01','d11','den','starts','edge_vectors','edge_lengths',
                             'edge_normals','triangle_patch_ids','edge_patch_ids','dominant_axes')}
        g=self._device_cache[key];centers=centers.to(dtype=torch.float64)
        delta=centers[:,None,:]-g['a']
        d20=(delta*g['e1']).sum(-1);d21=(delta*g['e2']).sum(-1)
        u=(g['d11']*d20-g['d01']*d21)/g['den'];v=(g['d00']*d21-g['d01']*d20)/g['den']
        covered=(u>=-1e-10)&(v>=-1e-10)&(u+v<=1+1e-10)
        inside=torch.zeros((len(centers),self.patch_count),dtype=torch.int32,device=centers.device)
        inside.scatter_reduce_(1,g['triangle_patch_ids'][None].expand(len(centers),-1),covered.to(torch.int32),reduce='amax')
        delta=centers[:,None,:]-g['starts']
        t=((delta*g['edge_vectors']).sum(-1)/g['edge_lengths']).clamp(0,1)
        residual=delta-t[:,:,None]*g['edge_vectors']
        residual=residual-g['edge_normals']*(residual*g['edge_normals']).sum(-1,keepdim=True)
        distance2=torch.full((len(centers),self.patch_count),float('inf'),dtype=torch.float64,device=centers.device)
        distance2.scatter_reduce_(1,g['edge_patch_ids'][None].expand(len(centers),-1),residual.square().sum(-1),reduce='amin')
        return torch.where(inside.bool(),-1.,1.)*distance2.clamp_min(0).sqrt()


def self_test(torch, device):
    # A concave L footprint with a missing corner. The bounding rectangle
    # contains (1.5,1.5), while the actual physical patch does not.
    triangles=np.array([[[0,0,0],[2,0,0],[2,0,1]],[[0,0,0],[2,0,1],[0,0,1]],
                        [[0,0,1],[1,0,1],[1,0,2]],[[0,0,1],[1,0,2],[0,0,2]]],dtype='f8')
    normal=np.tile([0.,1.,0.],(4,1));root=np.zeros(4,dtype=int)
    p=PatchFootprints(triangles,normal,root)
    points=np.array([[.5,3.,.5],[1.5,-2.,1.5],[1.5,0.,.999],[1.5,0.,1.001],[.5,0.,1.01]])
    expected=np.array([-.5,.5,-.001,.001,-.5])
    cpu=p.numpy_signed_distances(points)[:,0]
    gpu=p.torch_signed_distances(torch,torch.tensor(points,device=device))[:,0].cpu().numpy()
    if not np.allclose(cpu,expected,atol=1e-12) or not np.allclose(cpu,gpu,atol=1e-12):raise ValueError('concave patch footprint test failed')
    # Coplanar patches separated in space remain separate; vertex winding
    # and duplicate coincident faces do not change the physical footprint.
    doubled=PatchFootprints(np.concatenate([triangles,triangles[:,::-1]]),np.tile([0.,1.,0.],(8,1)),np.zeros(8,dtype=int))
    if not np.allclose(doubled.numpy_signed_distances(points)[:,0],expected,atol=1e-12):raise ValueError('duplicate/winding footprint test failed')
    return dict(status='passed',max_cpu_cuda_delta=float(np.abs(cpu-gpu).max()),
        checks=['concavity','true_boundary_sides','normal_projection_invariance','duplicate_faces','winding_invariance','internal_T_junction_removal'])
