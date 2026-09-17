#include <algorithm>
#include <array>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <map>
#include <queue>
#include <set>
#include <sstream>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

namespace fs = std::filesystem;

struct Vec3 { double x=0, y=0, z=0; };
static Vec3 operator+(const Vec3&a,const Vec3&b){return {a.x+b.x,a.y+b.y,a.z+b.z};}
static Vec3 operator-(const Vec3&a,const Vec3&b){return {a.x-b.x,a.y-b.y,a.z-b.z};}
static Vec3 operator*(const Vec3&a,double s){return {a.x*s,a.y*s,a.z*s};}
static Vec3 operator/(const Vec3&a,double s){return s!=0?a*(1.0/s):Vec3{};}
static double dot(const Vec3&a,const Vec3&b){return a.x*b.x+a.y*b.y+a.z*b.z;}
static Vec3 cross(const Vec3&a,const Vec3&b){return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x};}
static double len2(const Vec3&a){return dot(a,a);} static double len(const Vec3&a){return std::sqrt(len2(a));}
static Vec3 norm(const Vec3&a){double l=len(a);return l>1e-15?a/l:Vec3{};}
static double clampd(double v,double a,double b){return std::max(a,std::min(b,v));}

struct ObjCorner { int v=0; int vt=0; };
struct ObjFace { std::array<ObjCorner,3> c{}; };
struct ObjMesh { std::vector<Vec3> vertices; std::vector<std::array<double,2>> tex; std::vector<ObjFace> faces; };

struct EdgeKey {
    int a=0,b=0;
    EdgeKey()=default;
    EdgeKey(int x,int y){ if(x<y){a=x;b=y;} else {a=y;b=x;} }
    bool operator==(const EdgeKey&o)const{return a==o.a&&b==o.b;}
    bool operator<(const EdgeKey&o)const{return a<o.a||(a==o.a&&b<o.b);}
};
struct EdgeHash { size_t operator()(const EdgeKey&e)const noexcept {return (static_cast<size_t>(static_cast<unsigned>(e.a))<<32)^static_cast<unsigned>(e.b);} };

static bool parseIndexToken(const std::string& tok,int&v,int&vt){
    v=vt=0; if(tok.empty()) return false; auto p1=tok.find('/');
    try{
        if(p1==std::string::npos){v=std::stoi(tok);return true;}
        v=std::stoi(tok.substr(0,p1)); auto p2=tok.find('/',p1+1);
        std::string t=tok.substr(p1+1,(p2==std::string::npos?tok.size():p2)-(p1+1));
        if(!t.empty()) vt=std::stoi(t); return true;
    }catch(...){return false;}
}

static bool readTriObj(const fs::path&path,ObjMesh&mesh,std::string&err){
    std::ifstream in(path); if(!in){err="Cannot open OBJ: "+path.string();return false;}
    std::string line;
    while(std::getline(in,line)){
        if(line.size()<2) continue; std::istringstream ss(line); std::string tag; ss>>tag;
        if(tag=="v"){
            Vec3 p; if(!(ss>>p.x>>p.y>>p.z)){err="Malformed vertex in OBJ.";return false;} mesh.vertices.push_back(p);
        }else if(tag=="vt"){
            double u=0,v=0; if(!(ss>>u>>v)){err="Malformed vt in OBJ.";return false;} mesh.tex.push_back({u,v});
        }else if(tag=="f"){
            std::vector<ObjCorner> cs; std::string tok;
            while(ss>>tok){int vi=0,vti=0;if(!parseIndexToken(tok,vi,vti)){err="Malformed face token in OBJ.";return false;}
                if(vi<0) vi=(int)mesh.vertices.size()+vi+1; if(vti<0) vti=(int)mesh.tex.size()+vti+1; cs.push_back({vi,vti});}
            if(cs.size()!=3){err="RotateUV Feature-Aware worker requires triangulated OBJ input.";return false;}
            ObjFace f; for(int i=0;i<3;i++) f.c[i]=cs[i]; mesh.faces.push_back(f);
        }
    }
    if(mesh.vertices.empty()||mesh.faces.empty()){err="OBJ has no vertices/faces.";return false;} return true;
}

struct EdgeInfo {
    EdgeKey key;
    std::vector<int> faces;
    double length=0.0;
    double dihedralDeg=0.0;
    bool openBoundary=false;
};
struct MeshTopo {
    std::vector<Vec3> faceNormal;
    std::vector<Vec3> faceCenter;
    std::vector<double> faceArea;
    std::unordered_map<EdgeKey,EdgeInfo,EdgeHash> edges;
    std::vector<std::vector<EdgeKey>> vertexEdges;
    double avgEdge=1.0;
    double totalArea=0.0;
};

static MeshTopo buildTopo(const ObjMesh&m){
    MeshTopo t; int nf=(int)m.faces.size(); t.faceNormal.resize(nf);t.faceCenter.resize(nf);t.faceArea.resize(nf);
    double edgeSum=0; int edgeCount=0;
    for(int fi=0;fi<nf;++fi){
        const auto&f=m.faces[fi]; Vec3 p0=m.vertices[f.c[0].v-1],p1=m.vertices[f.c[1].v-1],p2=m.vertices[f.c[2].v-1];
        Vec3 cr=cross(p1-p0,p2-p0); double a=0.5*len(cr); t.faceArea[fi]=a;t.totalArea+=a;t.faceNormal[fi]=norm(cr);t.faceCenter[fi]=(p0+p1+p2)/3.0;
        for(int k=0;k<3;k++){EdgeKey e(f.c[k].v,f.c[(k+1)%3].v);auto&ei=t.edges[e];ei.key=e;ei.faces.push_back(fi);}
    }
    t.vertexEdges.resize(m.vertices.size()+1);
    for(auto&kv:t.edges){auto&e=kv.second;Vec3 a=m.vertices[e.key.a-1],b=m.vertices[e.key.b-1];e.length=len(b-a);edgeSum+=e.length;edgeCount++;
        e.openBoundary=(e.faces.size()==1); if(e.faces.size()==2){double c=clampd(dot(t.faceNormal[e.faces[0]],t.faceNormal[e.faces[1]]),-1.0,1.0);e.dihedralDeg=std::acos(c)*57.2957795130823208768;} else e.dihedralDeg=180.0;
        t.vertexEdges[e.key.a].push_back(e.key);t.vertexEdges[e.key.b].push_back(e.key);
    }
    if(edgeCount>0) t.avgEdge=edgeSum/edgeCount; return t;
}

struct Profile {
    std::string name="Balanced";
    double featureAngle=38.0;
    double planarAngle=6.0;
    double minFeatureLengthFactor=0.20;
    double minRegionAreaFrac=0.004;
    bool addClosedFallback=true;
};
static Profile profileFromBound(double bound){
    Profile p;
    if(bound>=6.5){p.name="Minimal Seams";p.featureAngle=52.0;p.planarAngle=5.0;p.minRegionAreaFrac=0.008;}
    else if(bound<=4.6){p.name="Low Distortion";p.featureAngle=26.0;p.planarAngle=8.0;p.minRegionAreaFrac=0.002;}
    return p;
}

static std::vector<std::vector<int>> faceComponents(const ObjMesh&m){
    std::unordered_map<EdgeKey,std::vector<int>,EdgeHash> ef;
    for(int fi=0;fi<(int)m.faces.size();++fi){auto&f=m.faces[fi];for(int k=0;k<3;k++)ef[EdgeKey(f.c[k].v,f.c[(k+1)%3].v)].push_back(fi);}
    std::vector<std::vector<int>> adj(m.faces.size());
    for(auto&kv:ef) if(kv.second.size()==2){int a=kv.second[0],b=kv.second[1];adj[a].push_back(b);adj[b].push_back(a);}
    std::vector<char>seen(m.faces.size(),0);std::vector<std::vector<int>>cs;
    for(int s=0;s<(int)m.faces.size();++s)if(!seen[s]){std::queue<int>q;q.push(s);seen[s]=1;std::vector<int>c;while(!q.empty()){int f=q.front();q.pop();c.push_back(f);for(int n:adj[f])if(!seen[n]){seen[n]=1;q.push(n);}}cs.push_back(std::move(c));}
    return cs;
}

static std::set<EdgeKey> featureCycleCore(const ObjMesh&m,const MeshTopo&t,const std::unordered_set<int>&compFaces,const Profile&p){
    std::set<EdgeKey> cand;
    for(auto&kv:t.edges){const auto&e=kv.second;if(e.faces.size()!=2)continue;if(!compFaces.count(e.faces[0])||!compFaces.count(e.faces[1]))continue;
        if(e.length < t.avgEdge*p.minFeatureLengthFactor) continue;
        if(e.dihedralDeg>=p.featureAngle) cand.insert(e.key);
    }
    if(cand.empty()) return {};
    std::unordered_map<int,int> deg; std::unordered_map<int,std::vector<EdgeKey>> inc;
    for(auto&e:cand){deg[e.a]++;deg[e.b]++;inc[e.a].push_back(e);inc[e.b].push_back(e);}
    std::queue<int>q; for(auto&kv:deg) if(kv.second<2) q.push(kv.first); std::set<EdgeKey> alive=cand;
    while(!q.empty()){
        int v=q.front();q.pop(); if(deg[v]>=2) continue;
        auto it=inc.find(v);if(it==inc.end())continue;
        for(auto&e:it->second) if(alive.erase(e)){
            int o=(e.a==v?e.b:e.a);deg[v]--;deg[o]--;if(deg[o]==1)q.push(o);
        }
    }
    return alive;
}

static std::vector<std::vector<int>> planarPatches(const ObjMesh&m,const MeshTopo&t,const std::unordered_set<int>&compFaces,const Profile&p){
    std::vector<std::vector<int>> adj(m.faces.size());
    for(auto&kv:t.edges){auto&e=kv.second;if(e.faces.size()!=2)continue;int a=e.faces[0],b=e.faces[1];if(!compFaces.count(a)||!compFaces.count(b))continue;
        if(e.dihedralDeg<=p.planarAngle){adj[a].push_back(b);adj[b].push_back(a);}
    }
    std::unordered_set<int>seen;std::vector<std::vector<int>>out;
    for(int s:compFaces) if(!seen.count(s)){
        std::queue<int>q;q.push(s);seen.insert(s);std::vector<int>patch;
        while(!q.empty()){int f=q.front();q.pop();patch.push_back(f);for(int n:adj[f])if(!seen.count(n)){seen.insert(n);q.push(n);}}
        out.push_back(std::move(patch));
    }
    return out;
}

static std::vector<std::vector<EdgeKey>> edgeConnectedComponents(const std::set<EdgeKey>&edges){
    std::unordered_map<int,std::vector<EdgeKey>>inc;for(auto&e:edges){inc[e.a].push_back(e);inc[e.b].push_back(e);}std::set<EdgeKey>left=edges;std::vector<std::vector<EdgeKey>>cs;
    while(!left.empty()){
        EdgeKey seed=*left.begin();left.erase(left.begin());std::queue<int>q;q.push(seed.a);q.push(seed.b);std::set<int>seenV{seed.a,seed.b};std::vector<EdgeKey>c{seed};
        while(!q.empty()){int v=q.front();q.pop();for(auto&e:inc[v])if(left.erase(e)){c.push_back(e);int o=(e.a==v?e.b:e.a);if(seenV.insert(o).second)q.push(o);}}
        cs.push_back(std::move(c));
    }return cs;
}

static bool looksLikeClosedLoop(const std::vector<EdgeKey>&es){
    if(es.size()<3)return false;std::unordered_map<int,int>d;for(auto&e:es){d[e.a]++;d[e.b]++;}for(auto&kv:d)if(kv.second!=2)return false;return true;
}


// V2.1 structured standard-geometry assist.
// This is intentionally a high-confidence pre-pass. If it cannot prove that a component
// behaves like an axial/extruded solid, the original V2 feature-aware planner is used unchanged.
struct PlanarLoopCandidate {
    std::vector<EdgeKey> edges;
    Vec3 center{};
    Vec3 normal{};
    double length=0.0;
    double patchArea=0.0;
    double avgBoundaryAngle=0.0;
    double strongFraction=0.0;
};

static Vec3 loopCenter(const ObjMesh&m,const std::vector<EdgeKey>&es){
    std::set<int> vs; for(const auto&e:es){vs.insert(e.a);vs.insert(e.b);} Vec3 c{};
    for(int v:vs)c=c+m.vertices[v-1]; return vs.empty()?c:c/(double)vs.size();
}

static double loopLength(const MeshTopo&t,const std::vector<EdgeKey>&es){
    double L=0.0; for(const auto&e:es){auto it=t.edges.find(e);if(it!=t.edges.end())L+=it->second.length;} return L;
}

static std::vector<PlanarLoopCandidate> collectPlanarLoopCandidates(
    const ObjMesh&m,const MeshTopo&t,const std::unordered_set<int>&compFaces,const Profile&p)
{
    std::vector<PlanarLoopCandidate> out;
    auto patches=planarPatches(m,t,compFaces,p);
    for(auto&patch:patches){
        double area=0.0; Vec3 nsum{}; std::unordered_set<int>pf(patch.begin(),patch.end());
        for(int f:patch){area+=t.faceArea[f];nsum=nsum+t.faceNormal[f]*t.faceArea[f];}
        if(area < t.totalArea*p.minRegionAreaFrac) continue;
        Vec3 pnorm=norm(nsum); if(len2(pnorm)<1e-12) continue;

        std::set<EdgeKey>bd; bool hasOutside=false;
        for(auto&kv:t.edges){const auto&e=kv.second;int inCount=0;for(int f:e.faces)if(pf.count(f))inCount++;
            if(inCount==1){bd.insert(e.key);if(e.faces.size()==2)hasOutside=true;}}
        if(!hasOutside||bd.size()<3) continue;

        auto comps=edgeConnectedComponents(bd);
        for(auto&ec:comps){
            if(!looksLikeClosedLoop(ec))continue;
            double angleSum=0.0;int angleN=0,strongN=0; bool hasOpen=false;
            for(auto&e:ec){auto it=t.edges.find(e);if(it==t.edges.end())continue;const auto&ei=it->second;
                if(ei.openBoundary){hasOpen=true;break;}
                if(ei.faces.size()==2){angleSum+=ei.dihedralDeg;angleN++;if(ei.dihedralDeg>=p.featureAngle)strongN++;}}
            if(hasOpen||angleN==0)continue;
            double avgAng=angleSum/angleN; double strongFrac=(double)strongN/angleN;
            if(avgAng < p.featureAngle*0.70 || strongFrac < 0.65) continue;
            PlanarLoopCandidate c; c.edges=ec;c.center=loopCenter(m,ec);c.normal=pnorm;c.length=loopLength(t,ec);
            c.patchArea=area;c.avgBoundaryAngle=avgAng;c.strongFraction=strongFrac;out.push_back(std::move(c));
        }
    }
    return out;
}

static bool dijkstraAxialSlit(
    const ObjMesh&m,const MeshTopo&t,const std::unordered_set<int>&regionVerts,
    const std::set<EdgeKey>&loopEdges,const std::unordered_set<int>&sources,
    const std::unordered_set<int>&targets,const Vec3&axis,std::vector<EdgeKey>&path)
{
    const double INF=std::numeric_limits<double>::infinity();
    struct AxPrevRec{int v=0;EdgeKey e;bool has=false;}; std::vector<double>d(m.vertices.size()+1,INF);std::vector<AxPrevRec>pr(m.vertices.size()+1);
    using Q=std::pair<double,int>;std::priority_queue<Q,std::vector<Q>,std::greater<Q>>pq;
    for(int s:sources)if(regionVerts.count(s)){d[s]=0.0;pq.push({0.0,s});}
    Vec3 ax=norm(axis); if(len2(ax)<1e-12)return false; int hit=0;
    while(!pq.empty()){
        auto [cd,v]=pq.top();pq.pop();if(cd!=d[v])continue;if(targets.count(v)){hit=v;break;}
        for(auto&e:t.vertexEdges[v]){
            int o=(e.a==v?e.b:e.a);if(!regionVerts.count(o))continue;auto it=t.edges.find(e);if(it==t.edges.end())continue;
            Vec3 ev=norm(m.vertices[o-1]-m.vertices[v-1]);double axial=std::abs(dot(ev,ax));
            // Strongly prefer one continuous generator along the extrusion axis. Radial/shoulder
            // crossings are still possible, but wandering around a cap/feature loop is expensive.
            double dirPenalty=1.0 + 5.0*(1.0-axial)*(1.0-axial);
            double crease=clampd(it->second.dihedralDeg/90.0,0.0,1.0);
            double creaseFactor=1.0-0.45*crease;
            double loopPenalty=loopEdges.count(e)?12.0:1.0;
            double w=std::max(1e-9,it->second.length*dirPenalty*creaseFactor*loopPenalty);
            double nd=cd+w;if(nd<d[o]){d[o]=nd;pr[o]={v,e,true};pq.push({nd,o});}
        }
    }
    if(!hit)return false;path.clear();int cur=hit;
    while(!sources.count(cur)){auto&r=pr[cur];if(!r.has){path.clear();return false;}path.push_back(r.e);cur=r.v;}
    std::reverse(path.begin(),path.end());return !path.empty();
}

static bool tryAxialStandardAssist(
    const ObjMesh&m,const MeshTopo&t,const std::vector<int>&comp,const Profile&p,std::set<EdgeKey>&cuts)
{
    std::unordered_set<int>cf(comp.begin(),comp.end());
    auto loops=collectPlanarLoopCandidates(m,t,cf,p); if(loops.size()<2)return false;

    // Find the strongest family of parallel planar structural loops. Cylinders, boxes,
    // chamfered boxes and stepped/extruded parts all produce this pattern.
    const double cosParallel=std::cos(18.0/57.2957795130823208768);
    int bestSeed=-1;std::vector<int>bestFamily;double bestScore=-1.0;
    for(int i=0;i<(int)loops.size();++i){
        std::vector<int>fam;double score=0.0;
        for(int j=0;j<(int)loops.size();++j){
            if(std::abs(dot(norm(loops[i].normal),norm(loops[j].normal)))>=cosParallel){fam.push_back(j);score+=loops[j].length;}
        }
        if(fam.size()>=2 && (fam.size()>bestFamily.size() || (fam.size()==bestFamily.size()&&score>bestScore))){bestSeed=i;bestFamily=fam;bestScore=score;}
    }
    if(bestSeed<0||bestFamily.size()<2)return false;

    Vec3 axis=norm(loops[bestSeed].normal);Vec3 meanC{};
    for(int idx:bestFamily){if(dot(loops[idx].normal,axis)<0){} meanC=meanC+loops[idx].center;}
    meanC=meanC/(double)bestFamily.size();

    // Reject unrelated parallel loops scattered around an arbitrary model. Their centers must
    // approximately share one extrusion axis and span a meaningful distance.
    double minS=std::numeric_limits<double>::infinity(),maxS=-minS,maxPerp=0.0,meanRadius=0.0;
    int minIdx=-1,maxIdx=-1;
    for(int idx:bestFamily){
        Vec3 dc=loops[idx].center-meanC;double s=dot(dc,axis);Vec3 perp=dc-axis*s;maxPerp=std::max(maxPerp,len(perp));
        if(s<minS){minS=s;minIdx=idx;}if(s>maxS){maxS=s;maxIdx=idx;}
        meanRadius+=loops[idx].length/(2.0*3.14159265358979323846);
    }
    meanRadius/=bestFamily.size();double span=maxS-minS;
    if(span < t.avgEdge*0.60)return false;
    if(maxPerp > std::max(t.avgEdge*1.75,meanRadius*0.30))return false;

    // Avoid grabbing several almost-coincident bevel loops that describe the same station.
    // Keep the strongest/longest loop per small axial band, but preserve distinct concentric
    // loops at the same station (e.g. an annular shoulder) because they are real separators.
    std::vector<int>kept=bestFamily;
    std::sort(kept.begin(),kept.end(),[&](int a,int b){return dot(loops[a].center,axis)<dot(loops[b].center,axis);});

    std::set<EdgeKey>structuredLoops;
    for(int idx:kept)for(auto&e:loops[idx].edges)structuredLoops.insert(e);
    if(structuredLoops.size()<3)return false;

    // Create exactly one global longitudinal slit through all stations instead of one slit per
    // region. This is the key difference from V2 and prevents the multiple unwanted vertical seams.
    std::unordered_set<int>src,dst,rv;
    for(int f:comp){auto&fc=m.faces[f];for(auto&c:fc.c)rv.insert(c.v);}
    for(auto&e:loops[maxIdx].edges){src.insert(e.a);src.insert(e.b);}for(auto&e:loops[minIdx].edges){dst.insert(e.a);dst.insert(e.b);}
    std::vector<EdgeKey>slit;
    if(!dijkstraAxialSlit(m,t,rv,structuredLoops,src,dst,axis,slit))return false;

    cuts=structuredLoops;
    for(auto&e:slit){auto it=t.edges.find(e);if(it!=t.edges.end()&&!it->second.openBoundary)cuts.insert(e);}
    return !cuts.empty();
}

static std::set<EdgeKey> planarBoundaryLoops(const ObjMesh&m,const MeshTopo&t,const std::unordered_set<int>&compFaces,const Profile&p){
    std::set<EdgeKey> seams;auto patches=planarPatches(m,t,compFaces,p);
    for(auto&patch:patches){
        double area=0;std::unordered_set<int>pf(patch.begin(),patch.end());for(int f:patch)area+=t.faceArea[f];
        if(area < t.totalArea*p.minRegionAreaFrac) continue;
        std::set<EdgeKey>bd;bool hasOutside=false;
        for(auto&kv:t.edges){auto&e=kv.second;int inCount=0;for(int f:e.faces)if(pf.count(f))inCount++;if(inCount==1){bd.insert(e.key);if(e.faces.size()==2)hasOutside=true;}}
        if(!hasOutside||bd.size()<3) continue;
        auto comps=edgeConnectedComponents(bd);
        for(auto&ec:comps){if(!looksLikeClosedLoop(ec))continue;
            // Require the loop to border a real normal change; excludes arbitrary patch fragmentation.
            double angleSum=0;int angleN=0, strongN=0;
            for(auto&e:ec){auto it=t.edges.find(e);if(it!=t.edges.end()&&it->second.faces.size()==2){angleSum+=it->second.dihedralDeg;angleN++;if(it->second.dihedralDeg>=p.featureAngle)strongN++;}}
            double avgAng=angleN?angleSum/angleN:0; double strongFrac=angleN?(double)strongN/angleN:0.0;
            // A real cap/structural separator has most of its perimeter on a meaningful normal break.
            // This rejects individual cylinder side quads, whose top/bottom edges are sharp but vertical borders are smooth.
            if(avgAng < p.featureAngle*0.70 || strongFrac < 0.65) continue;
            for(auto&e:ec){auto it=t.edges.find(e);if(it!=t.edges.end()&&!it->second.openBoundary)seams.insert(e);}
        }
    }
    return seams;
}

static std::vector<std::vector<int>> faceRegionsAfterCuts(const ObjMesh&m,const MeshTopo&t,const std::unordered_set<int>&compFaces,const std::set<EdgeKey>&cuts){
    std::vector<std::vector<int>>adj(m.faces.size());
    for(auto&kv:t.edges){auto&e=kv.second;if(e.faces.size()!=2||cuts.count(e.key))continue;int a=e.faces[0],b=e.faces[1];if(compFaces.count(a)&&compFaces.count(b)){adj[a].push_back(b);adj[b].push_back(a);}}
    std::unordered_set<int>seen;std::vector<std::vector<int>>rs;
    for(int s:compFaces)if(!seen.count(s)){std::queue<int>q;q.push(s);seen.insert(s);std::vector<int>r;while(!q.empty()){int f=q.front();q.pop();r.push_back(f);for(int n:adj[f])if(!seen.count(n)){seen.insert(n);q.push(n);}}rs.push_back(std::move(r));}return rs;
}

static std::vector<std::vector<EdgeKey>> regionBoundaryComponents(const MeshTopo&t,const std::unordered_set<int>&rf,const std::set<EdgeKey>&cuts){
    std::set<EdgeKey>bd;
    for(auto&kv:t.edges){auto&e=kv.second;int in=0;for(int f:e.faces)if(rf.count(f))in++;
        if(in==1 && (e.openBoundary || cuts.count(e.key) || e.faces.size()==2)) bd.insert(e.key);
    }
    return edgeConnectedComponents(bd);
}

static Vec3 verticesCentroid(const ObjMesh&m,const std::vector<EdgeKey>&edges){
    std::set<int>vs;for(auto&e:edges){vs.insert(e.a);vs.insert(e.b);}Vec3 c{};for(int v:vs)c=c+m.vertices[v-1];return vs.empty()?c:c/(double)vs.size();
}

struct PrevRec { int v=0; EdgeKey e; bool has=false; };
static bool shortestPathBetweenSets(const ObjMesh&m,const MeshTopo&t,const std::unordered_set<int>&regionVerts,const std::set<EdgeKey>&blocked,const std::unordered_set<int>&sources,const std::unordered_set<int>&targets,const Vec3&axis,std::vector<EdgeKey>&path){
    const double INF=std::numeric_limits<double>::infinity();std::vector<double>d(m.vertices.size()+1,INF);std::vector<PrevRec>pr(m.vertices.size()+1);
    using Q=std::pair<double,int>;std::priority_queue<Q,std::vector<Q>,std::greater<Q>>pq;for(int s:sources)if(regionVerts.count(s)){d[s]=0;pq.push({0,s});}
    int hit=0;Vec3 ax=norm(axis);bool useAxis=len2(ax)>1e-12;
    while(!pq.empty()){auto [cd,v]=pq.top();pq.pop();if(cd!=d[v])continue;if(targets.count(v)){hit=v;break;}
        for(auto&e:t.vertexEdges[v]){if(blocked.count(e))continue;int o=(e.a==v?e.b:e.a);if(!regionVerts.count(o))continue;auto it=t.edges.find(e);if(it==t.edges.end())continue;
            Vec3 ev=norm(m.vertices[o-1]-m.vertices[v-1]);double align=useAxis?std::abs(dot(ev,ax)):0.5;double smoothPenalty=1.0+1.7*(1.0-align);
            // Prefer corners/creases for a seam when they are available, but not enough to override path length.
            double creaseBonus=1.0-0.35*clampd(it->second.dihedralDeg/90.0,0.0,1.0);double w=std::max(1e-9,it->second.length*smoothPenalty*creaseBonus);
            double nd=cd+w;if(nd<d[o]){d[o]=nd;pr[o]={v,e,true};pq.push({nd,o});}
        }
    }
    if(!hit)return false;path.clear();int cur=hit;while(!sources.count(cur)){auto&r=pr[cur];if(!r.has){path.clear();return false;}path.push_back(r.e);cur=r.v;}std::reverse(path.begin(),path.end());return !path.empty();
}

static void addLongitudinalOpenings(const ObjMesh&m,const MeshTopo&t,const std::unordered_set<int>&compFaces,const Profile&p,std::set<EdgeKey>&cuts){
    auto regions=faceRegionsAfterCuts(m,t,compFaces,cuts);
    for(auto&r:regions){
        double area=0;std::unordered_set<int>rf(r.begin(),r.end());std::unordered_set<int>rv;for(int f:r){area+=t.faceArea[f];auto&fc=m.faces[f];for(auto&c:fc.c)rv.insert(c.v);}if(area<t.totalArea*p.minRegionAreaFrac)continue;
        auto bcs=regionBoundaryComponents(t,rf,cuts);std::vector<std::vector<EdgeKey>> loops;for(auto&bc:bcs)if(bc.size()>=2)loops.push_back(bc);
        if(loops.size()>=2){
            // Connect the two boundary components with the largest centroid separation.
            int bi=0,bj=1;double best=-1;for(int i=0;i<(int)loops.size();++i)for(int j=i+1;j<(int)loops.size();++j){Vec3 a=verticesCentroid(m,loops[i]),b=verticesCentroid(m,loops[j]);double q=len2(b-a);if(q>best){best=q;bi=i;bj=j;}}
            std::unordered_set<int>A,B;for(auto&e:loops[bi]){A.insert(e.a);A.insert(e.b);}for(auto&e:loops[bj]){B.insert(e.a);B.insert(e.b);}Vec3 ca=verticesCentroid(m,loops[bi]),cb=verticesCentroid(m,loops[bj]);
            std::vector<EdgeKey>path;if(shortestPathBetweenSets(m,t,rv,cuts,A,B,cb-ca,path)){for(auto&e:path)if(!t.edges.at(e).openBoundary)cuts.insert(e);}        
        }else if(loops.empty() && p.addClosedFallback && r.size()>=12){
            // Closed smooth region fallback: create one long controlled slit rather than random little cuts.
            // Approximate a geodesic diameter with two Dijkstra-like sweeps on the edge graph.
            int seed=*rv.begin();
            auto farthest=[&](int s,std::vector<int>*prevOut)->int{
                std::vector<double>d(m.vertices.size()+1,std::numeric_limits<double>::infinity());std::vector<int>pr(m.vertices.size()+1,0);using Q=std::pair<double,int>;std::priority_queue<Q,std::vector<Q>,std::greater<Q>>pq;d[s]=0;pq.push({0,s});int far=s;
                while(!pq.empty()){auto [cd,v]=pq.top();pq.pop();if(cd!=d[v])continue;if(cd>d[far])far=v;for(auto&e:t.vertexEdges[v]){if(cuts.count(e))continue;int o=(e.a==v?e.b:e.a);if(!rv.count(o))continue;double nd=cd+t.edges.at(e).length;if(nd<d[o]){d[o]=nd;pr[o]=v;pq.push({nd,o});}}}
                if(prevOut)*prevOut=std::move(pr);return far;};
            int a=farthest(seed,nullptr);std::vector<int>pr;int b=farthest(a,&pr);int cur=b;while(cur!=a&&pr[cur]){EdgeKey e(cur,pr[cur]);if(!t.edges.at(e).openBoundary)cuts.insert(e);cur=pr[cur];}
        }
    }
}

static void pruneTinyBranches(const MeshTopo&t,const Profile&p,std::set<EdgeKey>&cuts){
    // Remove very short dangling seam twigs, but preserve loops and long connector paths.
    bool changed=true;double minLen=t.avgEdge*0.60;
    while(changed){changed=false;std::unordered_map<int,int>d;for(auto&e:cuts){d[e.a]++;d[e.b]++;}std::vector<EdgeKey>rm;
        for(auto&e:cuts){if((d[e.a]==1||d[e.b]==1)&&t.edges.at(e).length<minLen)rm.push_back(e);}for(auto&e:rm)if(cuts.erase(e))changed=true;
    }
}

static std::set<EdgeKey> planFeatureAwareLegacy(const ObjMesh&m,const MeshTopo&t,const std::vector<int>&comp,const Profile&p){
    std::unordered_set<int>cf(comp.begin(),comp.end());
    std::set<EdgeKey>cuts=featureCycleCore(m,t,cf,p);
    auto planar=planarBoundaryLoops(m,t,cf,p);cuts.insert(planar.begin(),planar.end());
    addLongitudinalOpenings(m,t,cf,p,cuts);pruneTinyBranches(t,p,cuts);
    // Never output true mesh boundaries: Max already has them for free.
    for(auto it=cuts.begin();it!=cuts.end();){auto ei=t.edges.find(*it);if(ei!=t.edges.end()&&ei->second.openBoundary)it=cuts.erase(it);else ++it;}
    return cuts;
}

static std::set<EdgeKey> planFeatureAware(const ObjMesh&m,const MeshTopo&t,const std::vector<int>&comp,const Profile&p){
    std::set<EdgeKey> structured;
    if(tryAxialStandardAssist(m,t,comp,p,structured)){
        // Same boundary rule as V2: true mesh openings are already free and should not be emitted.
        for(auto it=structured.begin();it!=structured.end();){auto ei=t.edges.find(*it);if(ei!=t.edges.end()&&ei->second.openBoundary)it=structured.erase(it);else ++it;}
        return structured;
    }
    return planFeatureAwareLegacy(m,t,comp,p);
}

static double parseBound(const std::string&s){try{return std::stod(s);}catch(...){return 5.5;}}

int main(int argc,char**argv){
    if(argc<4){
        std::cerr<<"RotateUV Native Auto Seam V2.2 - Feature-Aware + Standard Geometry Assist (V2.1 behavior frozen)\nUsage: RotateUV_AutoSeam.exe input.obj output.seams profileBound [legacyInitialCut]\n";return 2;
    }
    fs::path inputPath=fs::absolute(argv[1]);fs::path outputPath=fs::absolute(argv[2]);double bound=parseBound(argv[3]);Profile prof=profileFromBound(bound);
    ObjMesh mesh;std::string err;if(!readTriObj(inputPath,mesh,err)){std::cerr<<err<<"\n";return 4;}MeshTopo topo=buildTopo(mesh);auto comps=faceComponents(mesh);
    std::set<EdgeKey>allCuts;for(auto&c:comps){auto s=planFeatureAware(mesh,topo,c,prof);allCuts.insert(s.begin(),s.end());}
    std::ofstream out(outputPath);if(!out){std::cerr<<"Cannot create seam output file.\n";return 6;}
    out<<"RUVSEAM 1\n";
    out<<"COMPONENTS "<<comps.size()<<"\n";
    out<<"FAILED_COMPONENTS 0\n";
    out<<"UNMATCHED_TRIANGLES 0\n";
    out<<"DISTORTION_BOUND "<<std::setprecision(8)<<bound<<"\n";
    out<<"SEAMS "<<allCuts.size()<<"\n";
    for(auto&e:allCuts)out<<"SEAM "<<e.a<<" "<<e.b<<"\n";
    out<<"END\n";out.close();
    std::cout<<"RotateUV Feature-Aware Auto Seam V2.2: "<<allCuts.size()<<" seam edges | "<<prof.name<<" | components="<<comps.size()<<"\n";
    return 0;
}
