// RotateUV Native Unfold V3 - libigl LSCM + SLIM with exact developable unroll,
// chart auto-orientation, texel-density preservation and a measured distortion report.
//
// Per chart:
//   1) exact planar projection       (flat charts)
//   2) exact developable unroll      (cylinder walls, annuli, cones, box nets)
//   3) LSCM / harmonic init + SLIM   (everything else)
//   4) fallback axis projection      (degenerate charts)
// Then: measured distortion, auto-orientation, relative-scale normalization, packing.

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <map>
#include <numeric>
#include <queue>
#include <set>
#include <sstream>
#include <string>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include <Eigen/Core>
#include <igl/boundary_loop.h>
#include <igl/harmonic.h>
#include <igl/lscm.h>
#include <igl/map_vertices_to_circle.h>
#include <igl/slim.h>

#define RUV_UNFOLD_VERSION "3.0.0"

struct Vec2 { double x=0.0, y=0.0; };
struct Vec3 { double x=0.0, y=0.0, z=0.0; };
static Vec3 operator+(const Vec3&a,const Vec3&b){ return {a.x+b.x,a.y+b.y,a.z+b.z}; }
static Vec3 operator-(const Vec3&a,const Vec3&b){ return {a.x-b.x,a.y-b.y,a.z-b.z}; }
static Vec3 operator*(const Vec3&a,double s){ return {a.x*s,a.y*s,a.z*s}; }
static Vec3 operator/(const Vec3&a,double s){ return s!=0.0?a*(1.0/s):Vec3{}; }
static double dot(const Vec3&a,const Vec3&b){ return a.x*b.x+a.y*b.y+a.z*b.z; }
static Vec3 cross(const Vec3&a,const Vec3&b){ return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x}; }
static double len2(const Vec3&a){ return dot(a,a); }
static double len(const Vec3&a){ return std::sqrt(len2(a)); }
static Vec3 norm(const Vec3&a){ const double l=len(a); return l>1e-15?a/l:Vec3{}; }
static double clampd(double v,double lo,double hi){ return std::max(lo,std::min(hi,v)); }

struct EdgeKey {
    int a=0,b=0;
    EdgeKey()=default;
    EdgeKey(int x,int y){ if(x<y){a=x;b=y;} else {a=y;b=x;} }
    bool operator==(const EdgeKey&o)const{return a==o.a&&b==o.b;}
    bool operator<(const EdgeKey&o)const{return a<o.a||(a==o.a&&b<o.b);}
};
struct EdgeHash {
    size_t operator()(const EdgeKey&e)const noexcept {
        return (static_cast<size_t>(static_cast<uint32_t>(e.a))<<32)^static_cast<uint32_t>(e.b);
    }
};

struct Face { std::vector<int> v; };
struct InputMesh {
    std::vector<Vec3> vertices;
    std::vector<Face> faces;
    std::set<EdgeKey> seams;
};

struct Options {
    int slimIters=20;
    bool orient=true;
    bool preserveScale=true;
    bool developable=true;
    int threads=0;
    double padding=0.02;
};

static bool readInput(const std::string&path, InputMesh&m, std::string&err){
    std::ifstream in(path);
    if(!in){ err="Cannot open native unfold input."; return false; }
    std::string line;
    if(!std::getline(in,line) || line!="RUVUNFOLD 1") { err="Invalid RUVUNFOLD header."; return false; }
    int expectedVerts=-1, expectedFaces=-1, expectedSeams=-1;
    while(std::getline(in,line)){
        if(line.empty()) continue;
        std::istringstream ss(line); std::string tag; ss>>tag;
        if(tag=="VERTICES"){
            ss>>expectedVerts; if(expectedVerts<3){err="Invalid vertex count.";return false;}
            m.vertices.reserve(expectedVerts);
            for(int i=0;i<expectedVerts;i++){
                if(!std::getline(in,line)){err="Unexpected EOF in VERTICES.";return false;}
                std::istringstream vs(line); Vec3 p; if(!(vs>>p.x>>p.y>>p.z)){err="Malformed vertex record.";return false;} m.vertices.push_back(p);
            }
        }else if(tag=="FACES"){
            ss>>expectedFaces; if(expectedFaces<1){err="Invalid face count.";return false;}
            m.faces.resize(expectedFaces);
            for(int i=0;i<expectedFaces;i++){
                if(!std::getline(in,line)){err="Unexpected EOF in FACES.";return false;}
                std::istringstream fs(line); std::string ft; int faceIndex=0,n=0; fs>>ft>>faceIndex>>n;
                if(ft!="FACE" || faceIndex!=i+1 || n<3){err="Malformed FACE record.";return false;}
                m.faces[i].v.resize(n);
                for(int k=0;k<n;k++){
                    if(!(fs>>m.faces[i].v[k])){err="FACE record is missing geometry vertex indices.";return false;}
                    if(m.faces[i].v[k]<1 || m.faces[i].v[k]>(int)m.vertices.size()){err="FACE geometry vertex index out of range.";return false;}
                }
            }
        }else if(tag=="SEAMS"){
            ss>>expectedSeams; if(expectedSeams<0){err="Invalid seam count.";return false;}
            for(int i=0;i<expectedSeams;i++){
                if(!std::getline(in,line)){err="Unexpected EOF in SEAMS.";return false;}
                std::istringstream es(line); std::string st; int a=0,b=0; es>>st>>a>>b;
                if(st!="SEAM" || a<1 || b<1 || a>(int)m.vertices.size() || b>(int)m.vertices.size() || a==b){err="Malformed SEAM record.";return false;}
                m.seams.insert(EdgeKey(a,b));
            }
        }else if(tag=="END") break;
    }
    if((int)m.vertices.size()!=expectedVerts || (int)m.faces.size()!=expectedFaces){err="Native unfold input is incomplete.";return false;}
    return true;
}

struct DSU {
    std::vector<int> p,r;
    explicit DSU(int n=0):p(n),r(n,0){std::iota(p.begin(),p.end(),0);}
    int find(int x){return p[x]==x?x:p[x]=find(p[x]);}
    void unite(int a,int b){a=find(a);b=find(b);if(a==b)return;if(r[a]<r[b])std::swap(a,b);p[b]=a;if(r[a]==r[b])r[a]++;}
};

struct HalfEdge { int face=0; int corner=0; int a=0; int b=0; };
struct CutMesh {
    std::vector<int> faceCornerStart;
    std::vector<int> cornerCutVertex;
    std::vector<int> cutGeomVertex;
    std::vector<std::vector<int>> faceAdj;
    int cutVertexCount=0;
};

static CutMesh buildCutMesh(const InputMesh&m){
    CutMesh c; const int nf=(int)m.faces.size(); c.faceCornerStart.resize(nf+1,0);
    for(int f=0;f<nf;f++) c.faceCornerStart[f+1]=c.faceCornerStart[f]+(int)m.faces[f].v.size();
    const int nc=c.faceCornerStart[nf]; DSU dsu(nc);
    std::unordered_map<EdgeKey,std::vector<HalfEdge>,EdgeHash> emap;
    emap.reserve((size_t)nc*2);
    for(int f=0;f<nf;f++){
        const int n=(int)m.faces[f].v.size();
        for(int k=0;k<n;k++){
            const int a=m.faces[f].v[k], b=m.faces[f].v[(k+1)%n];
            emap[EdgeKey(a,b)].push_back({f,k,a,b});
        }
    }
    c.faceAdj.assign(nf,{});
    for(auto&kv:emap){
        const EdgeKey&e=kv.first; auto&hs=kv.second;
        if(hs.size()!=2 || m.seams.count(e)) continue;
        const HalfEdge&h0=hs[0]; const HalfEdge&h1=hs[1];
        const int n0=(int)m.faces[h0.face].v.size(), n1=(int)m.faces[h1.face].v.size();
        const int c0=c.faceCornerStart[h0.face]+h0.corner;
        const int c0n=c.faceCornerStart[h0.face]+((h0.corner+1)%n0);
        const int c1=c.faceCornerStart[h1.face]+h1.corner;
        const int c1n=c.faceCornerStart[h1.face]+((h1.corner+1)%n1);
        if(h0.a==h1.a){ dsu.unite(c0,c1); dsu.unite(c0n,c1n); }
        else { dsu.unite(c0,c1n); dsu.unite(c0n,c1); }
        c.faceAdj[h0.face].push_back(h1.face); c.faceAdj[h1.face].push_back(h0.face);
    }
    c.cornerCutVertex.resize(nc,-1);
    std::unordered_map<int,int> rootToCut; rootToCut.reserve(nc);
    for(int f=0;f<nf;f++){
        const int n=(int)m.faces[f].v.size();
        for(int k=0;k<n;k++){
            const int ci=c.faceCornerStart[f]+k; const int root=dsu.find(ci);
            auto it=rootToCut.find(root); int cv;
            if(it==rootToCut.end()){
                cv=(int)rootToCut.size(); rootToCut[root]=cv; c.cutGeomVertex.push_back(m.faces[f].v[k]);
            }else cv=it->second;
            c.cornerCutVertex[ci]=cv;
        }
    }
    c.cutVertexCount=(int)rootToCut.size(); return c;
}

struct Tri { int a=0,b=0,c=0; };
struct ChartStats {
    double maxStretch=0.0;
    double meanStretch=0.0;
    double maxAreaDist=0.0;
    double maxShear=0.0;
    int flips=0;
    int overlaps=0;
};
struct Chart {
    std::vector<int> faces;
    std::vector<int> cutVerts;
    std::vector<Tri> tris;
    std::vector<Vec2> uv;
    std::unordered_map<int,int> cutToLocal;
    std::string method;
    double energy=0.0;
    double area3D=0.0;
    ChartStats stats;
};

static Vec3 chartPos(const InputMesh&m,const CutMesh&c,const Chart&ch,int local){
    const int cv=ch.cutVerts[local]; const int gv=c.cutGeomVertex[cv]; return m.vertices[gv-1];
}

// ---------------------------------------------------------------------------
// Ear-clipping triangulation in the face's least-squares plane. The previous
// version fanned every face from corner 0, producing degenerate or inverted
// triangles on non-convex n-gons which then corrupted the solve.
// ---------------------------------------------------------------------------
static void triangulatePolygon(const std::vector<Vec3>&pts,const std::vector<int>&local,std::vector<Tri>&out){
    const int n=(int)local.size();
    if(n<3) return;
    if(n==3){ out.push_back({local[0],local[1],local[2]}); return; }

    Vec3 nsum{};
    for(int i=0;i<n;i++){
        const Vec3&p0=pts[i], &p1=pts[(i+1)%n], &p2=pts[(i+2)%n];
        nsum=nsum+cross(p1-p0,p2-p1);
    }
    Vec3 nrm=norm(nsum);
    if(len2(nrm)<1e-20){
        for(int k=1;k+1<n;k++) out.push_back({local[0],local[k],local[k+1]});
        return;
    }
    Vec3 e1=norm(pts[1]-pts[0]);
    if(len2(e1)<1e-20) e1=norm(cross(nrm,Vec3{0,0,1}));
    if(len2(e1)<1e-20) e1=norm(cross(nrm,Vec3{0,1,0}));
    Vec3 e2=norm(cross(nrm,e1));

    std::vector<Vec2> q(n);
    for(int i=0;i<n;i++){ Vec3 d=pts[i]-pts[0]; q[i]={dot(d,e1),dot(d,e2)}; }

    double signedArea=0.0;
    for(int i=0;i<n;i++){ const Vec2&a=q[i],&b=q[(i+1)%n]; signedArea+=a.x*b.y-b.x*a.y; }
    const double orient = signedArea>=0.0 ? 1.0 : -1.0;

    auto crossZ=[](const Vec2&a,const Vec2&b,const Vec2&c){
        return (b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x);
    };
    auto pointInTri=[&](const Vec2&p,const Vec2&a,const Vec2&b,const Vec2&c){
        const double d1=crossZ(a,b,p)*orient, d2=crossZ(b,c,p)*orient, d3=crossZ(c,a,p)*orient;
        return d1>=-1e-12 && d2>=-1e-12 && d3>=-1e-12;
    };

    std::vector<int> idx(n); std::iota(idx.begin(),idx.end(),0);
    int guard=0;
    while((int)idx.size()>3 && guard++ < 4*n){
        bool clipped=false;
        const int cnt=(int)idx.size();
        for(int i=0;i<cnt;i++){
            const int ia=idx[(i+cnt-1)%cnt], ib=idx[i], ic=idx[(i+1)%cnt];
            if(crossZ(q[ia],q[ib],q[ic])*orient <= 1e-14) continue;
            bool contains=false;
            for(int j=0;j<cnt && !contains;j++){
                const int t=idx[j];
                if(t==ia||t==ib||t==ic) continue;
                if(pointInTri(q[t],q[ia],q[ib],q[ic])) contains=true;
            }
            if(contains) continue;
            out.push_back({local[ia],local[ib],local[ic]});
            idx.erase(idx.begin()+i);
            clipped=true;
            break;
        }
        if(!clipped) break;
    }
    if(idx.size()==3){
        out.push_back({local[idx[0]],local[idx[1]],local[idx[2]]});
    }else{
        for(size_t k=1;k+1<idx.size();k++) out.push_back({local[idx[0]],local[idx[k]],local[idx[k+1]]});
    }
}

static std::vector<Chart> buildCharts(const InputMesh&m,const CutMesh&c){
    const int nf=(int)m.faces.size(); std::vector<char>seen(nf,0); std::vector<Chart>charts;
    for(int seed=0;seed<nf;seed++) if(!seen[seed]){
        Chart ch; std::queue<int>q; q.push(seed); seen[seed]=1;
        while(!q.empty()){int f=q.front();q.pop();ch.faces.push_back(f);for(int n:c.faceAdj[f])if(!seen[n]){seen[n]=1;q.push(n);}}
        std::set<int> cvs;
        for(int f:ch.faces){
            const int n=(int)m.faces[f].v.size();
            for(int k=0;k<n;k++) cvs.insert(c.cornerCutVertex[c.faceCornerStart[f]+k]);
        }
        ch.cutVerts.assign(cvs.begin(),cvs.end());
        ch.cutToLocal.reserve(ch.cutVerts.size()*2);
        for(int i=0;i<(int)ch.cutVerts.size();i++) ch.cutToLocal[ch.cutVerts[i]]=i;
        for(int f:ch.faces){
            const int n=(int)m.faces[f].v.size();
            std::vector<int> local(n); std::vector<Vec3> pts(n);
            for(int k=0;k<n;k++){
                local[k]=ch.cutToLocal[c.cornerCutVertex[c.faceCornerStart[f]+k]];
                pts[k]=m.vertices[m.faces[f].v[k]-1];
            }
            std::vector<Tri> ft;
            triangulatePolygon(pts,local,ft);
            for(const auto&t:ft) if(t.a!=t.b&&t.b!=t.c&&t.c!=t.a) ch.tris.push_back(t);
        }
        for(const auto&t:ch.tris){
            const Vec3 a=m.vertices[c.cutGeomVertex[ch.cutVerts[t.a]]-1];
            const Vec3 b=m.vertices[c.cutGeomVertex[ch.cutVerts[t.b]]-1];
            const Vec3 d=m.vertices[c.cutGeomVertex[ch.cutVerts[t.c]]-1];
            ch.area3D+=0.5*len(cross(b-a,d-a));
        }
        charts.push_back(std::move(ch));
    }
    return charts;
}

static int countFlips(const Eigen::MatrixXd&UV,const Eigen::MatrixXi&F){
    int pos=0,neg=0;
    for(int i=0;i<F.rows();++i){
        const auto a=UV.row(F(i,0)); const auto b=UV.row(F(i,1)); const auto d=UV.row(F(i,2));
        const double A=(b(0)-a(0))*(d(1)-a(1))-(b(1)-a(1))*(d(0)-a(0));
        if(A>1e-12)++pos; else if(A<-1e-12)++neg;
    }
    return std::min(pos,neg);
}

// ---------------------------------------------------------------------------
// Measured distortion: per triangle build the 2x2 Jacobian from the isometric
// 3D frame to UV and take its singular values s1 >= s2.
//   stretch = max(s1, 1/s2)   area = max(s1*s2, 1/(s1*s2))   shear = s1/s2
// ---------------------------------------------------------------------------
static void measureChart(const InputMesh&m,const CutMesh&c,Chart&ch){
    ChartStats st;
    st.overlaps=ch.stats.overlaps;
    double wsum=0.0, wstretch=0.0;
    int negative=0, positive=0;

    // Stretch has to be scale invariant, otherwise a chart that is merely small
    // reports huge distortion. Divide out the chart's optimal uniform scale first,
    // so an exact isometry measures 1.0 at any size.
    double area3Dsum=0.0, areaUVsum=0.0;
    for(const auto&t:ch.tris){
        const Vec3 p0=chartPos(m,c,ch,t.a), p1=chartPos(m,c,ch,t.b), p2=chartPos(m,c,ch,t.c);
        area3Dsum+=0.5*len(cross(p1-p0,p2-p0));
        const Vec2&q0=ch.uv[t.a],&q1=ch.uv[t.b],&q2=ch.uv[t.c];
        areaUVsum+=0.5*std::abs((q1.x-q0.x)*(q2.y-q0.y)-(q1.y-q0.y)*(q2.x-q0.x));
    }
    const double sOpt = (area3Dsum>1e-18 && areaUVsum>1e-18) ? std::sqrt(areaUVsum/area3Dsum) : 1.0;
    const double invS = sOpt>1e-18 ? 1.0/sOpt : 1.0;

    for(const auto&t:ch.tris){
        const Vec3 p0=chartPos(m,c,ch,t.a), p1=chartPos(m,c,ch,t.b), p2=chartPos(m,c,ch,t.c);
        const Vec3 d1=p1-p0, d2=p2-p0;
        const Vec3 nrm=cross(d1,d2);
        const double twice=len(nrm);
        if(twice<1e-18) continue;
        const Vec3 e1=norm(d1);
        const Vec3 e2=norm(cross(norm(nrm),e1));
        const double a11=dot(d1,e1), a21=dot(d1,e2);
        const double a12=dot(d2,e1), a22=dot(d2,e2);
        const double det=a11*a22-a12*a21;
        if(std::abs(det)<1e-18) continue;

        const Vec2&u0=ch.uv[t.a],&u1=ch.uv[t.b],&u2=ch.uv[t.c];
        const double b11=u1.x-u0.x, b21=u1.y-u0.y;
        const double b12=u2.x-u0.x, b22=u2.y-u0.y;

        const double i11= a22/det, i12=-a12/det;
        const double i21=-a21/det, i22= a11/det;
        const double j11=(b11*i11+b12*i21)*invS, j12=(b11*i12+b12*i22)*invS;
        const double j21=(b21*i11+b22*i21)*invS, j22=(b21*i12+b22*i22)*invS;

        const double jdet=j11*j22-j12*j21;
        if(jdet>1e-14) ++positive; else if(jdet<-1e-14) ++negative;

        const double m11=j11*j11+j21*j21;
        const double m22=j12*j12+j22*j22;
        const double m12=j11*j12+j21*j22;
        const double tr=m11+m22;
        const double disc=std::sqrt(std::max(0.0,(m11-m22)*(m11-m22)+4.0*m12*m12));
        const double s1=std::sqrt(std::max(0.0,0.5*(tr+disc)));
        const double s2=std::sqrt(std::max(0.0,0.5*(tr-disc)));
        if(s1<1e-14) continue;

        const double area3=0.5*twice;
        if(s2>1e-14){
            const double stretch=std::max(s1,1.0/s2);
            st.maxStretch=std::max(st.maxStretch,stretch);
            st.maxAreaDist=std::max(st.maxAreaDist,std::max(s1*s2,1.0/(s1*s2)));
            st.maxShear=std::max(st.maxShear,s1/s2);
            wstretch+=stretch*area3; wsum+=area3;
        }else{
            st.maxStretch=std::max(st.maxStretch,1e9);
            st.maxAreaDist=std::max(st.maxAreaDist,1e9);
            st.maxShear=std::max(st.maxShear,1e9);
        }
    }
    st.meanStretch = wsum>1e-18 ? wstretch/wsum : 0.0;
    st.flips = std::min(positive,negative);
    ch.stats = st;
}

// ---------------------------------------------------------------------------
// Overlap detection on a uniform grid. Used as the acceptance test for the
// exact developable unroll and as a reported quality metric.
// ---------------------------------------------------------------------------
static int countOverlaps(const Chart&ch,int cap=64){
    const int nt=(int)ch.tris.size();
    if(nt<2 || nt>200000 || (int)ch.uv.size()<3) return 0;
    double minx=1e100,miny=1e100,maxx=-1e100,maxy=-1e100;
    for(const auto&u:ch.uv){minx=std::min(minx,u.x);miny=std::min(miny,u.y);maxx=std::max(maxx,u.x);maxy=std::max(maxy,u.y);}
    const double w=maxx-minx,h=maxy-miny;
    if(!(w>0.0)||!(h>0.0)) return 0;
    const int grid=std::max(1,std::min(256,(int)std::sqrt((double)nt)));
    const double cw=w/grid, chh=h/grid;
    std::vector<std::vector<int>> cells((size_t)grid*grid);
    auto cellOf=[&](double x,double y,int&cx,int&cy){
        cx=(int)clampd(std::floor((x-minx)/std::max(1e-18,cw)),0.0,(double)grid-1.0);
        cy=(int)clampd(std::floor((y-miny)/std::max(1e-18,chh)),0.0,(double)grid-1.0);
    };
    for(int i=0;i<nt;i++){
        const Vec2&a=ch.uv[ch.tris[i].a],&b=ch.uv[ch.tris[i].b],&cc=ch.uv[ch.tris[i].c];
        int x0,y0,x1,y1;
        cellOf(std::min(a.x,std::min(b.x,cc.x)),std::min(a.y,std::min(b.y,cc.y)),x0,y0);
        cellOf(std::max(a.x,std::max(b.x,cc.x)),std::max(a.y,std::max(b.y,cc.y)),x1,y1);
        for(int tx=x0;tx<=x1;tx++) for(int ty=y0;ty<=y1;ty++) cells[(size_t)ty*grid+tx].push_back(i);
    }
    auto crossZ=[](const Vec2&p,const Vec2&q,const Vec2&r){return (q.x-p.x)*(r.y-p.y)-(q.y-p.y)*(r.x-p.x);};
    auto separated=[&](const Vec2*A,const Vec2*B){
        for(int i=0;i<3;i++){
            const Vec2&p=A[i],&q=A[(i+1)%3];
            const double ref=crossZ(p,q,A[(i+2)%3]);
            if(std::abs(ref)<1e-18) continue;
            const double s=ref>0.0?1.0:-1.0;
            bool allOut=true;
            for(int j=0;j<3;j++) if(crossZ(p,q,B[j])*s > 1e-12){ allOut=false; break; }
            if(allOut) return true;
        }
        return false;
    };
    std::set<std::pair<int,int>> found;
    for(const auto&cell:cells){
        if(cell.size()<2) continue;
        for(size_t i=0;i<cell.size();i++) for(size_t j=i+1;j<cell.size();j++){
            const int ti=cell[i],tj=cell[j];
            const Tri&A=ch.tris[ti],&B=ch.tris[tj];
            if(A.a==B.a||A.a==B.b||A.a==B.c||A.b==B.a||A.b==B.b||A.b==B.c||A.c==B.a||A.c==B.b||A.c==B.c) continue;
            const Vec2 pa[3]={ch.uv[A.a],ch.uv[A.b],ch.uv[A.c]};
            const Vec2 pb[3]={ch.uv[B.a],ch.uv[B.b],ch.uv[B.c]};
            if(separated(pa,pb)||separated(pb,pa)) continue;
            found.insert({std::min(ti,tj),std::max(ti,tj)});
            if((int)found.size()>=cap) return (int)found.size();
        }
    }
    return (int)found.size();
}

// ---------------------------------------------------------------------------
// Exact isometric unroll for developable charts (hinge unfolding). Places the
// seed triangle, then walks the dual graph placing each neighbour's third vertex
// by rigid rotation about the shared edge. For a developable chart - cylinder
// wall, annulus, cone, box net, any flat patch - this preserves every edge
// length exactly, with no solver noise. Non-developable charts fail the
// consistency or distortion check and fall through to LSCM + SLIM.
// ---------------------------------------------------------------------------
static bool developableUnroll(const InputMesh&m,const CutMesh&c,Chart&ch,double tol=1.0005){
    const int nt=(int)ch.tris.size();
    const int nv=(int)ch.cutVerts.size();
    if(nt<1||nv<3) return false;

    std::unordered_map<EdgeKey,std::vector<int>,EdgeHash> em; em.reserve(nt*3);
    for(int i=0;i<nt;i++){
        const Tri&t=ch.tris[i];
        em[EdgeKey(t.a,t.b)].push_back(i);
        em[EdgeKey(t.b,t.c)].push_back(i);
        em[EdgeKey(t.c,t.a)].push_back(i);
    }

    std::vector<Vec2> uv(nv,{0.0,0.0});
    std::vector<char> placedV(nv,0), placedT(nt,0);

    auto P=[&](int local){ return chartPos(m,c,ch,local); };
    auto third=[&](const Tri&t,int i,int j){
        if(t.a!=i&&t.a!=j) return t.a;
        if(t.b!=i&&t.b!=j) return t.b;
        return t.c;
    };

    int seed=-1;
    for(int i=0;i<nt;i++){
        const Tri&t=ch.tris[i];
        if(len(cross(P(t.b)-P(t.a),P(t.c)-P(t.a)))>1e-16){ seed=i; break; }
    }
    if(seed<0) return false;
    {
        const Tri&t=ch.tris[seed];
        const Vec3 a=P(t.a),b=P(t.b),cc=P(t.c);
        const double lab=len(b-a);
        if(lab<1e-15) return false;
        const double lac=len(cc-a), lbc=len(cc-b);
        const double x=(lab*lab+lac*lac-lbc*lbc)/(2.0*lab);
        uv[t.a]={0.0,0.0};
        uv[t.b]={lab,0.0};
        uv[t.c]={x,std::sqrt(std::max(0.0,lac*lac-x*x))};
        placedV[t.a]=placedV[t.b]=placedV[t.c]=1;
        placedT[seed]=1;
    }

    std::queue<int> q; q.push(seed);
    int placedCount=1;
    while(!q.empty()){
        const int fi=q.front(); q.pop();
        const Tri t=ch.tris[fi];
        const int pairs[3][2]={{t.a,t.b},{t.b,t.c},{t.c,t.a}};
        for(int k=0;k<3;k++){
            const int i=pairs[k][0], j=pairs[k][1];
            auto it=em.find(EdgeKey(i,j));
            if(it==em.end()) continue;
            for(int nb:it->second){
                if(nb==fi||placedT[nb]) continue;
                if(!placedV[i]||!placedV[j]) continue;
                const Tri&tn=ch.tris[nb];
                const int kv=third(tn,i,j);

                const Vec3 pi=P(i),pj=P(j),pk=P(kv);
                const double lij=len(pj-pi);
                if(lij<1e-15) continue;
                const double lik=len(pk-pi), ljk=len(pk-pj);

                const double x=(lij*lij+lik*lik-ljk*ljk)/(2.0*lij);
                const double y=std::sqrt(std::max(0.0,lik*lik-x*x));
                const Vec2 A=uv[i],B=uv[j];
                const double ex=(B.x-A.x)/lij, ey=(B.y-A.y)/lij;
                // the new vertex lands on the far side of edge ij from this triangle's own apex
                const int own=third(t,i,j);
                const double sideOwn=(B.x-A.x)*(uv[own].y-A.y)-(B.y-A.y)*(uv[own].x-A.x);
                const double s = sideOwn>0.0 ? -1.0 : 1.0;
                const Vec2 cand{ A.x+ex*x + s*(-ey)*y, A.y+ey*x + s*(ex)*y };

                if(placedV[kv]){
                    const double dx=uv[kv].x-cand.x, dy=uv[kv].y-cand.y;
                    if(std::sqrt(dx*dx+dy*dy) > 1e-6*std::max(1.0,lij)) return false;
                }else{
                    uv[kv]=cand; placedV[kv]=1;
                }
                placedT[nb]=1; ++placedCount; q.push(nb);
            }
        }
    }
    if(placedCount!=nt) return false;
    for(int i=0;i<nv;i++) if(!placedV[i]) return false;

    ch.uv=uv;
    ch.stats.overlaps=0;
    measureChart(m,c,ch);
    if(ch.stats.flips>0) return false;
    if(!(ch.stats.maxStretch<=tol)) return false;
    if(countOverlaps(ch,1)>0) return false;   // a >360-degree development folds onto itself
    ch.method="developable-exact";
    ch.energy=0.0;
    return true;
}

static bool planarProject(const InputMesh&m,const CutMesh&c,Chart&ch){
    if(ch.tris.empty()||ch.cutVerts.size()<3)return false;
    Vec3 nsum{}; double areaSum=0.0;
    for(const auto&t:ch.tris){
        Vec3 a=chartPos(m,c,ch,t.a),b=chartPos(m,c,ch,t.b),d=chartPos(m,c,ch,t.c);
        Vec3 cr=cross(b-a,d-a); double twice=len(cr); if(twice<1e-14)continue; nsum=nsum+cr; areaSum+=0.5*twice;
    }
    Vec3 n=norm(nsum); if(len2(n)<1e-12||areaSum<1e-14)return false;
    double worst=0.0;
    for(const auto&t:ch.tris){
        Vec3 a=chartPos(m,c,ch,t.a),b=chartPos(m,c,ch,t.b),d=chartPos(m,c,ch,t.c); Vec3 tn=norm(cross(b-a,d-a)); if(len2(tn)<1e-12)continue;
        const double ang=std::acos(clampd(std::abs(dot(tn,n)),-1.0,1.0))*57.29577951308232; worst=std::max(worst,ang);
    }
    if(worst>1.0)return false;
    Vec3 cen{}; for(int i=0;i<(int)ch.cutVerts.size();i++)cen=cen+chartPos(m,c,ch,i); cen=cen/(double)ch.cutVerts.size();
    Vec3 e1{}; double best=-1.0;
    for(int i=0;i<(int)ch.cutVerts.size();i++){Vec3 v=chartPos(m,c,ch,i)-cen;v=v-n*dot(v,n);double qd=len2(v);if(qd>best){best=qd;e1=v;}}
    e1=norm(e1); if(len2(e1)<1e-12){e1=norm(cross(n,{0,0,1}));if(len2(e1)<1e-12)e1=norm(cross(n,{0,1,0}));}
    Vec3 e2=norm(cross(n,e1)); ch.uv.resize(ch.cutVerts.size());
    for(int i=0;i<(int)ch.cutVerts.size();i++){Vec3 d=chartPos(m,c,ch,i)-cen;ch.uv[i]={dot(d,e1),dot(d,e2)};}
    ch.method="planar-isometric"; ch.energy=0.0;
    ch.stats.overlaps=0;
    measureChart(m,c,ch);
    return true;
}

static bool buildEigenChart(const InputMesh&m,const CutMesh&c,const Chart&ch,Eigen::MatrixXd&V,Eigen::MatrixXi&F){
    if(ch.cutVerts.size()<3 || ch.tris.empty()) return false;
    V.resize((int)ch.cutVerts.size(),3);
    for(int i=0;i<V.rows();++i){Vec3 p=chartPos(m,c,ch,i);V(i,0)=p.x;V(i,1)=p.y;V(i,2)=p.z;}
    F.resize((int)ch.tris.size(),3);
    for(int i=0;i<F.rows();++i){F(i,0)=ch.tris[i].a;F(i,1)=ch.tris[i].b;F(i,2)=ch.tris[i].c;}
    return true;
}

static bool lscmInit(const Eigen::MatrixXd&V,const Eigen::MatrixXi&F,Eigen::MatrixXd&UV){
    Eigen::VectorXi bnd;
    igl::boundary_loop(F,bnd);
    if(bnd.size()>=2){
        int ia=0,ib=1; double best=-1.0;
        for(int i=0;i<bnd.size();++i){
            for(int j=i+1;j<bnd.size();++j){
                const double d=(V.row(bnd(i))-V.row(bnd(j))).squaredNorm();
                if(d>best){best=d;ia=i;ib=j;}
            }
        }
        Eigen::VectorXi b(2); b<<bnd(ia),bnd(ib);
        double pd=std::sqrt(std::max(1e-12,best));
        Eigen::MatrixXd bc(2,2); bc<<0.0,0.0,pd,0.0;
        if(igl::lscm(V,F,b,bc,UV) && UV.rows()==V.rows() && UV.allFinite()) return true;
    }
    if(igl::lscm(V,F,UV) && UV.rows()==V.rows() && UV.allFinite()) return true;
    return false;
}

static bool harmonicInit(const Eigen::MatrixXd&V,const Eigen::MatrixXi&F,Eigen::MatrixXd&UV){
    Eigen::VectorXi bnd;
    igl::boundary_loop(F,bnd);
    if(bnd.size()<3) return false;
    Eigen::MatrixXd bnd_uv;
    igl::map_vertices_to_circle(V,bnd,bnd_uv);
    igl::harmonic(V,F,bnd,bnd_uv,1,UV);
    return UV.rows()==V.rows() && UV.cols()==2 && UV.allFinite();
}

static bool solveLibigl(const InputMesh&m,const CutMesh&c,Chart&ch,int slimIters){
    Eigen::MatrixXd V,UV; Eigen::MatrixXi F;
    if(!buildEigenChart(m,c,ch,V,F)) return false;

    bool ok=lscmInit(V,F,UV);
    int flips=ok?countFlips(UV,F):std::numeric_limits<int>::max();
    if(!ok || flips>0){
        Eigen::MatrixXd hUV;
        if(harmonicInit(V,F,hUV)){
            const int hf=countFlips(hUV,F);
            if(!ok || hf<=flips){ UV=hUV; flips=hf; ok=true; ch.method="harmonic+SLIM"; }
        }
    }
    if(!ok) return false;
    if(ch.method.empty()) ch.method="LSCM+SLIM";

    Eigen::VectorXi b(0); Eigen::MatrixXd bc(0,2);
    igl::SLIMData data;
    try{
        igl::slim_precompute(V,F,UV,data,igl::SYMMETRIC_DIRICHLET,b,bc,0.0);
        // Iterate in small batches so a converged chart exits early instead of
        // always burning the whole budget.
        const int total=std::max(1,slimIters);
        const int batch=5;
        Eigen::MatrixXd bestUV=UV; int bestFlips=flips;
        double prev=std::numeric_limits<double>::infinity();
        for(int done=0;done<total;done+=batch){
            const int step=std::min(batch,total-done);
            Eigen::MatrixXd candidate=igl::slim_solve(data,step);
            if(!(candidate.rows()==UV.rows()&&candidate.cols()==2&&candidate.allFinite())) break;
            const int cf=countFlips(candidate,F);
            // SLIM should be locally injective. Never accept more flips than the initialization had.
            if(cf<=bestFlips){ bestUV=candidate; bestFlips=cf; }
            const double e=data.energy;
            if(std::isfinite(prev) && std::abs(prev-e) <= 1e-7*std::max(1.0,std::abs(prev))) break;
            prev=e;
        }
        UV=bestUV; flips=bestFlips; ch.energy=data.energy;
    }catch(...){
        // Keep the proven LSCM/harmonic initialization if optimization fails.
    }

    int pos=0,neg=0;
    for(int i=0;i<F.rows();++i){
        auto a=UV.row(F(i,0));auto b0=UV.row(F(i,1));auto d=UV.row(F(i,2));
        double A=(b0(0)-a(0))*(d(1)-a(1))-(b0(1)-a(1))*(d(0)-a(0)); if(A>1e-12)++pos;else if(A<-1e-12)++neg;
    }
    if(neg>pos) UV.col(1)=-UV.col(1);
    ch.uv.resize(UV.rows()); for(int i=0;i<UV.rows();++i) ch.uv[i]={UV(i,0),UV(i,1)};
    ch.stats.overlaps=0;
    measureChart(m,c,ch);
    ch.stats.overlaps=countOverlaps(ch);
    return true;
}

static void fallbackProject(const InputMesh&m,const CutMesh&c,Chart&ch){
    Vec3 mn{1e100,1e100,1e100},mx{-1e100,-1e100,-1e100};
    for(int i=0;i<(int)ch.cutVerts.size();i++){Vec3 p=chartPos(m,c,ch,i);mn.x=std::min(mn.x,p.x);mn.y=std::min(mn.y,p.y);mn.z=std::min(mn.z,p.z);mx.x=std::max(mx.x,p.x);mx.y=std::max(mx.y,p.y);mx.z=std::max(mx.z,p.z);}
    std::array<std::pair<double,int>,3> axes={{{mx.x-mn.x,0},{mx.y-mn.y,1},{mx.z-mn.z,2}}};std::sort(axes.begin(),axes.end(),[](auto&a,auto&b){return a.first>b.first;});
    ch.uv.resize(ch.cutVerts.size());
    auto coord=[](const Vec3&p,int a){return a==0?p.x:(a==1?p.y:p.z);};
    for(int i=0;i<(int)ch.cutVerts.size();i++){Vec3 p=chartPos(m,c,ch,i);ch.uv[i]={coord(p,axes[0].second),coord(p,axes[1].second)};}
    ch.method="fallback-projection";
    ch.stats.overlaps=0;
    measureChart(m,c,ch);
}

// ---------------------------------------------------------------------------
// Auto-orientation. LSCM/SLIM return a correct but arbitrarily rotated chart,
// which is why box UVs came out at scrambled angles. Find the dominant boundary
// direction by length-weighted histogram, rotate it onto U, then take the
// quarter turn that leaves the chart landscape.
// ---------------------------------------------------------------------------
static void orientChart(Chart&ch){
    if(ch.uv.size()<3||ch.tris.empty()) return;
    std::unordered_map<EdgeKey,int,EdgeHash> count; count.reserve(ch.tris.size()*3);
    for(const auto&t:ch.tris){
        count[EdgeKey(t.a,t.b)]++; count[EdgeKey(t.b,t.c)]++; count[EdgeKey(t.c,t.a)]++;
    }
    const int BINS=180;
    std::vector<double> hist(BINS,0.0);
    bool any=false;
    for(const auto&kv:count){
        if(kv.second!=1) continue;                   // boundary edges only
        const Vec2&a=ch.uv[kv.first.a],&b=ch.uv[kv.first.b];
        const double dx=b.x-a.x, dy=b.y-a.y;
        const double l=std::sqrt(dx*dx+dy*dy);
        if(l<1e-15) continue;
        double ang=std::atan2(dy,dx)*57.29577951308232;
        while(ang<0.0) ang+=180.0;
        while(ang>=180.0) ang-=180.0;
        hist[(int)clampd(std::floor(ang),0.0,(double)BINS-1.0)]+=l;
        any=true;
    }
    if(!any) return;
    std::vector<double> sm(BINS,0.0);
    for(int i=0;i<BINS;i++){
        for(int d=-2;d<=2;d++){
            const int j=((i+d)%BINS+BINS)%BINS;
            sm[i]+=hist[j]*(d==0?1.0:(std::abs(d)==1?0.6:0.25));
        }
    }
    int peak=0; for(int i=1;i<BINS;i++) if(sm[i]>sm[peak]) peak=i;
    const int pm=((peak-1)%BINS+BINS)%BINS, pp=(peak+1)%BINS;
    const double denom=sm[pm]-2.0*sm[peak]+sm[pp];
    double offset=0.0;
    if(std::abs(denom)>1e-18) offset=clampd(0.5*(sm[pm]-sm[pp])/denom,-0.5,0.5);
    const double theta=-((double)peak+0.5+offset)*3.14159265358979323846/180.0;

    const double cs=std::cos(theta), sn=std::sin(theta);
    for(auto&u:ch.uv){ const double x=u.x,y=u.y; u.x=x*cs-y*sn; u.y=x*sn+y*cs; }

    double minx=1e100,miny=1e100,maxx=-1e100,maxy=-1e100;
    for(const auto&u:ch.uv){minx=std::min(minx,u.x);miny=std::min(miny,u.y);maxx=std::max(maxx,u.x);maxy=std::max(maxy,u.y);}
    if((maxy-miny)>(maxx-minx)){
        for(auto&u:ch.uv){ const double x=u.x,y=u.y; u.x=y; u.y=-x; }
    }
}

// Preserve relative texel density: scale each chart so UV area matches 3D area.
static void normalizeChartScale(Chart&ch){
    if(ch.uv.size()<3||ch.tris.empty()||ch.area3D<=1e-18) return;
    double areaUV=0.0;
    for(const auto&t:ch.tris){
        const Vec2&a=ch.uv[t.a],&b=ch.uv[t.b],&c=ch.uv[t.c];
        areaUV+=0.5*std::abs((b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x));
    }
    if(areaUV<=1e-18) return;
    const double s=std::sqrt(ch.area3D/areaUV);
    if(!(s>0.0)||!std::isfinite(s)) return;
    for(auto&u:ch.uv){ u.x*=s; u.y*=s; }
}

// ---------------------------------------------------------------------------
// Shelf packer: charts sorted tallest-first, each allowed a quarter turn when
// that shelves better. Relative scale between charts is preserved; only one
// global fit is applied at the end.
// ---------------------------------------------------------------------------
static void packCharts(std::vector<Chart>&charts,double padFrac){
    struct Item{ size_t idx; double w,h; bool rot=false; };
    std::vector<Item> items; items.reserve(charts.size());

    double totalArea=0.0, maxDim=0.0;
    for(size_t ci=0;ci<charts.size();ci++){
        double minx=1e100,miny=1e100,maxx=-1e100,maxy=-1e100;
        for(const auto&u:charts[ci].uv){minx=std::min(minx,u.x);miny=std::min(miny,u.y);maxx=std::max(maxx,u.x);maxy=std::max(maxy,u.y);}
        if(charts[ci].uv.empty()){minx=miny=0.0;maxx=maxy=1.0;}
        double w=maxx-minx,h=maxy-miny;
        bool rot=false;
        if(w>h){ std::swap(w,h); rot=true; }   // shelve portrait, remember the turn
        items.push_back({ci,w,h,rot});
        totalArea+=w*h; maxDim=std::max(maxDim,h);
    }
    std::sort(items.begin(),items.end(),[](const Item&a,const Item&b){
        if(a.h!=b.h) return a.h>b.h;
        return a.w>b.w;
    });

    const double targetW=std::max(1e-9,std::sqrt(std::max(1e-18,totalArea))*1.25);
    const double pad=std::max(1e-6,maxDim*0.02);

    double x=0.0,y=0.0,rowH=0.0;
    for(const auto&it:items){
        Chart&ch=charts[it.idx];
        if(it.rot) for(auto&u:ch.uv){ const double ux=u.x,uy=u.y; u.x=uy; u.y=-ux; }
        double minx=1e100,miny=1e100,maxx=-1e100,maxy=-1e100;
        for(const auto&u:ch.uv){minx=std::min(minx,u.x);miny=std::min(miny,u.y);maxx=std::max(maxx,u.x);maxy=std::max(maxy,u.y);}
        if(ch.uv.empty()){minx=miny=0.0;maxx=maxy=1.0;}
        const double w=maxx-minx,h=maxy-miny;
        if(x>0.0 && x+w>targetW){ x=0.0; y+=rowH+pad; rowH=0.0; }
        for(auto&u:ch.uv){ u.x+=x-minx; u.y+=y-miny; }
        x+=w+pad; rowH=std::max(rowH,h);
    }

    double minx=1e100,miny=1e100,maxx=-1e100,maxy=-1e100;
    for(const auto&ch:charts) for(const auto&u:ch.uv){minx=std::min(minx,u.x);miny=std::min(miny,u.y);maxx=std::max(maxx,u.x);maxy=std::max(maxy,u.y);}
    if(!(maxx>minx)||!(maxy>miny)) return;
    const double margin=clampd(padFrac,0.0,0.2);
    const double span=1.0-2.0*margin;
    const double scale=span/std::max(1e-9,std::max(maxx-minx,maxy-miny));
    for(auto&ch:charts) for(auto&u:ch.uv){ u.x=margin+(u.x-minx)*scale; u.y=margin+(u.y-miny)*scale; }
}

static bool writeOutput(const std::string&path,const InputMesh&m,const CutMesh&c,const std::vector<Chart>&charts,std::string&err){
    std::vector<int> cutChart(c.cutVertexCount,-1),cutLocal(c.cutVertexCount,-1);
    int flips=0,overlaps=0;
    double maxStretch=0.0,meanStretch=0.0,maxArea=0.0,maxShear=0.0,wsum=0.0;
    for(int ci=0;ci<(int)charts.size();ci++){
        const Chart&ch=charts[ci];
        flips+=ch.stats.flips; overlaps+=ch.stats.overlaps;
        maxStretch=std::max(maxStretch,ch.stats.maxStretch);
        maxArea=std::max(maxArea,ch.stats.maxAreaDist);
        maxShear=std::max(maxShear,ch.stats.maxShear);
        meanStretch+=ch.stats.meanStretch*ch.area3D; wsum+=ch.area3D;
        for(int li=0;li<(int)ch.cutVerts.size();li++){int cv=ch.cutVerts[li];cutChart[cv]=ci;cutLocal[cv]=li;}
    }
    meanStretch = wsum>1e-18 ? meanStretch/wsum : 0.0;

    std::ofstream out(path);if(!out){err="Cannot create native unfold result.";return false;}
    out<<"RUVUV 2\nSTATUS OK\n";
    out<<"CHARTS "<<charts.size()<<"\nFLIPS "<<flips<<"\n";
    out<<std::fixed<<std::setprecision(6);
    out<<"STRETCH "<<maxStretch<<" "<<meanStretch<<"\n";
    out<<"AREADIST "<<maxArea<<"\n";
    out<<"SHEAR "<<maxShear<<"\n";
    out<<"OVERLAPS "<<overlaps<<"\n";
    out.unsetf(std::ios::floatfield);
    out<<"FACES "<<m.faces.size()<<"\n";
    out<<std::setprecision(17);
    for(int f=0;f<(int)m.faces.size();f++){
        const int n=(int)m.faces[f].v.size();out<<"FACE "<<(f+1)<<" "<<n<<"\n";
        for(int k=0;k<n;k++){
            const int cv=c.cornerCutVertex[c.faceCornerStart[f]+k];const int ci=cutChart[cv],li=cutLocal[cv];
            if(ci<0||li<0){err="Internal chart mapping failure.";return false;}const Vec2&uv=charts[ci].uv[li];
            out<<"UV "<<(k+1)<<" "<<uv.x<<" "<<uv.y<<" "<<cv<<"\n";
        }
        out<<"END_FACE\n";
    }
    out<<"END\n";return true;
}

static void solveOne(const InputMesh&m,const CutMesh&c,Chart&ch,const Options&opt,
                     std::atomic<int>&planarN,std::atomic<int>&devN,std::atomic<int>&slimN,std::atomic<int>&fbN){
    bool ok=planarProject(m,c,ch);
    if(ok) ++planarN;
    if(!ok && opt.developable){ ok=developableUnroll(m,c,ch); if(ok) ++devN; }
    if(!ok){ ok=solveLibigl(m,c,ch,opt.slimIters); if(ok) ++slimN; }
    if(!ok){ fallbackProject(m,c,ch); ++fbN; }
    if(opt.orient) orientChart(ch);
    if(opt.preserveScale) normalizeChartScale(ch);
}

static void printUsage(){
    std::cerr<<"RotateUV Native Unfold V"<<RUV_UNFOLD_VERSION
             <<" - developable unroll + libigl LSCM/SLIM\n"
               "Usage: RotateUV_Unfold.exe input.ruvu output.ruvuv [slimIterations] [options]\n"
               "Options:\n"
               "  --no-orient          keep the raw solver orientation\n"
               "  --no-preserve-scale  normalize each chart independently\n"
               "  --no-developable     skip the exact isometric unroll path\n"
               "  --threads N          worker threads (default: hardware concurrency)\n"
               "  --padding F          atlas margin, 0..0.2 (default 0.02)\n"
               "  --version            print version and exit\n";
}

int main(int argc,char**argv){
    for(int i=1;i<argc;i++) if(std::strcmp(argv[i],"--version")==0){
        std::cout<<"RotateUV_Unfold "<<RUV_UNFOLD_VERSION<<"\n"; return 0;
    }
    if(argc<3){ printUsage(); return 2; }

    Options opt;
    if(argc>=4 && argv[3][0]!='-'){
        try{ opt.slimIters=std::max(1,std::min(100,std::stoi(argv[3]))); }catch(...){ opt.slimIters=20; }
    }
    for(int i=3;i<argc;i++){
        if(std::strcmp(argv[i],"--no-orient")==0) opt.orient=false;
        else if(std::strcmp(argv[i],"--no-preserve-scale")==0) opt.preserveScale=false;
        else if(std::strcmp(argv[i],"--no-developable")==0) opt.developable=false;
        else if(std::strcmp(argv[i],"--threads")==0 && i+1<argc){ try{opt.threads=std::max(0,std::stoi(argv[++i]));}catch(...){} }
        else if(std::strcmp(argv[i],"--padding")==0 && i+1<argc){ try{opt.padding=clampd(std::stod(argv[++i]),0.0,0.2);}catch(...){} }
    }

    InputMesh m;std::string err;
    if(!readInput(argv[1],m,err)){std::cerr<<err<<"\n";return 4;}
    CutMesh c=buildCutMesh(m);
    auto charts=buildCharts(m,c);
    if(charts.empty()){std::cerr<<"No UV charts could be created.\n";return 5;}

    std::atomic<int> planarN{0},devN{0},slimN{0},fbN{0};
    unsigned hw = opt.threads>0 ? (unsigned)opt.threads : std::thread::hardware_concurrency();
    if(hw==0) hw=1;
    const unsigned nthreads=std::min<unsigned>(hw,(unsigned)charts.size());

    if(nthreads<=1){
        for(auto&ch:charts) solveOne(m,c,ch,opt,planarN,devN,slimN,fbN);
    }else{
        std::atomic<size_t> next{0};
        std::vector<std::thread> pool;
        for(unsigned t=0;t<nthreads;t++){
            pool.emplace_back([&]{
                for(;;){
                    const size_t i=next++;
                    if(i>=charts.size()) break;
                    solveOne(m,c,charts[i],opt,planarN,devN,slimN,fbN);
                }
            });
        }
        for(auto&th:pool) th.join();
    }

    packCharts(charts,opt.padding);
    if(!writeOutput(argv[2],m,c,charts,err)){std::cerr<<err<<"\n";return 6;}

    int flips=0,overlaps=0; double maxStretch=0.0;
    for(const auto&ch:charts){ flips+=ch.stats.flips; overlaps+=ch.stats.overlaps; maxStretch=std::max(maxStretch,ch.stats.maxStretch); }
    std::cout<<"RotateUV Native Unfold V"<<RUV_UNFOLD_VERSION
             <<": charts="<<charts.size()
             <<" cutVerts="<<c.cutVertexCount
             <<" seams="<<m.seams.size()
             <<" exact="<<(planarN.load()+devN.load())
             <<" (planar="<<planarN.load()<<" developable="<<devN.load()<<")"
             <<" slim="<<slimN.load()
             <<" fallbacks="<<fbN.load()
             <<" flips="<<flips
             <<" overlaps="<<overlaps
             <<" maxStretch="<<std::fixed<<std::setprecision(4)<<maxStretch
             <<" threads="<<nthreads<<"\n";
    return 0;
}
