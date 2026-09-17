#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
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
struct Chart {
    std::vector<int> faces;
    std::vector<int> cutVerts;
    std::vector<Tri> tris;
    std::vector<Vec2> uv;
    std::unordered_map<int,int> cutToLocal;
    int flips=0;
    std::string method;
    double energy=0.0;
};

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
            const int c0=ch.cutToLocal[c.cornerCutVertex[c.faceCornerStart[f]]];
            for(int k=1;k+1<n;k++){
                const int c1=ch.cutToLocal[c.cornerCutVertex[c.faceCornerStart[f]+k]];
                const int c2=ch.cutToLocal[c.cornerCutVertex[c.faceCornerStart[f]+k+1]];
                if(c0!=c1&&c1!=c2&&c2!=c0) ch.tris.push_back({c0,c1,c2});
            }
        }
        charts.push_back(std::move(ch));
    }
    return charts;
}

static Vec3 chartPos(const InputMesh&m,const CutMesh&c,const Chart&ch,int local){
    const int cv=ch.cutVerts[local]; const int gv=c.cutGeomVertex[cv]; return m.vertices[gv-1];
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
    for(int i=0;i<(int)ch.cutVerts.size();i++){Vec3 v=chartPos(m,c,ch,i)-cen;v=v-n*dot(v,n);double q=len2(v);if(q>best){best=q;e1=v;}}
    e1=norm(e1); if(len2(e1)<1e-12){e1=norm(cross(n,{0,0,1}));if(len2(e1)<1e-12)e1=norm(cross(n,{0,1,0}));}
    Vec3 e2=norm(cross(n,e1)); ch.uv.resize(ch.cutVerts.size());
    for(int i=0;i<(int)ch.cutVerts.size();i++){Vec3 d=chartPos(m,c,ch,i)-cen;ch.uv[i]={dot(d,e1),dot(d,e2)};}
    ch.flips=0; ch.method="planar-isometric"; ch.energy=0.0; return true;
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
        Eigen::MatrixXd candidate=igl::slim_solve(data,std::max(1,slimIters));
        if(candidate.rows()==UV.rows() && candidate.cols()==2 && candidate.allFinite()){
            const int cf=countFlips(candidate,F);
            // SLIM should be locally injective. Never accept a result with more flips than initialization.
            if(cf<=flips){UV=candidate;flips=cf;ch.energy=data.energy;}
        }
    }catch(...){
        // Keep proven LSCM/harmonic initialization if optimization fails unexpectedly.
    }

    // Normalize global orientation only; this does not hide local inversions.
    int pos=0,neg=0;
    for(int i=0;i<F.rows();++i){
        auto a=UV.row(F(i,0));auto b0=UV.row(F(i,1));auto d=UV.row(F(i,2));
        double A=(b0(0)-a(0))*(d(1)-a(1))-(b0(1)-a(1))*(d(0)-a(0)); if(A>1e-12)++pos;else if(A<-1e-12)++neg;
    }
    if(neg>pos) UV.col(1)=-UV.col(1);
    ch.flips=std::min(pos,neg);
    ch.uv.resize(UV.rows()); for(int i=0;i<UV.rows();++i) ch.uv[i]={UV(i,0),UV(i,1)};
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
}

static void packCharts(std::vector<Chart>&charts){
    double totalArea=0.0,maxH=0.0;
    struct B{double minx,maxx,miny,maxy;};std::vector<B>bb(charts.size());
    for(size_t ci=0;ci<charts.size();ci++){
        auto&ch=charts[ci];double minx=1e100,miny=1e100,maxx=-1e100,maxy=-1e100;
        for(auto&u:ch.uv){minx=std::min(minx,u.x);miny=std::min(miny,u.y);maxx=std::max(maxx,u.x);maxy=std::max(maxy,u.y);}if(ch.uv.empty()){minx=miny=0;maxx=maxy=1;}
        bb[ci]={minx,maxx,miny,maxy};totalArea+=(maxx-minx)*(maxy-miny);maxH=std::max(maxH,maxy-miny);
    }
    double targetW=std::max(1.0,std::sqrt(std::max(1e-12,totalArea))*1.7);double pad=std::max(1e-5,maxH*0.04);double x=0.0,y=0.0,rowH=0.0;
    for(size_t ci=0;ci<charts.size();ci++){
        double w=bb[ci].maxx-bb[ci].minx,h=bb[ci].maxy-bb[ci].miny;if(x>0&&x+w>targetW){x=0;y+=rowH+pad;rowH=0;}
        for(auto&u:charts[ci].uv){u.x+=x-bb[ci].minx;u.y+=y-bb[ci].miny;}x+=w+pad;rowH=std::max(rowH,h);
    }
    double minx=1e100,miny=1e100,maxx=-1e100,maxy=-1e100;for(auto&ch:charts)for(auto&u:ch.uv){minx=std::min(minx,u.x);miny=std::min(miny,u.y);maxx=std::max(maxx,u.x);maxy=std::max(maxy,u.y);}
    double w=maxx-minx,h=maxy-miny,scale=0.96/std::max(1e-9,std::max(w,h));for(auto&ch:charts)for(auto&u:ch.uv){u.x=0.02+(u.x-minx)*scale;u.y=0.02+(u.y-miny)*scale;}
}

static bool writeOutput(const std::string&path,const InputMesh&m,const CutMesh&c,const std::vector<Chart>&charts,std::string&err){
    std::vector<int> cutChart(c.cutVertexCount,-1),cutLocal(c.cutVertexCount,-1);int flips=0;
    for(int ci=0;ci<(int)charts.size();ci++){flips+=charts[ci].flips;for(int li=0;li<(int)charts[ci].cutVerts.size();li++){int cv=charts[ci].cutVerts[li];cutChart[cv]=ci;cutLocal[cv]=li;}}
    std::ofstream out(path);if(!out){err="Cannot create native unfold result.";return false;}
    out<<"RUVUV 1\nSTATUS OK\nCHARTS "<<charts.size()<<"\nFLIPS "<<flips<<"\nFACES "<<m.faces.size()<<"\n";
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

int main(int argc,char**argv){
    if(argc<3){
        std::cerr<<"RotateUV Native Unfold V2 - libigl LSCM + SLIM\nUsage: RotateUV_Unfold.exe input.ruvu output.ruvuv [slimIterations]\n";return 2;
    }
    int slimIters=20; if(argc>=4){try{slimIters=std::max(1,std::min(100,std::stoi(argv[3])));}catch(...){slimIters=20;}}
    InputMesh m;std::string err;if(!readInput(argv[1],m,err)){std::cerr<<err<<"\n";return 4;}
    CutMesh c=buildCutMesh(m);auto charts=buildCharts(m,c);if(charts.empty()){std::cerr<<"No UV charts could be created.\n";return 5;}
    int fallbackCount=0,totalFlips=0,slimCharts=0,planarCharts=0;
    for(auto&ch:charts){
        bool ok=planarProject(m,c,ch); if(ok)++planarCharts;
        if(!ok){ok=solveLibigl(m,c,ch,slimIters); if(ok)++slimCharts;}
        if(!ok){fallbackProject(m,c,ch);fallbackCount++;}
        totalFlips+=ch.flips;
    }
    packCharts(charts);if(!writeOutput(argv[2],m,c,charts,err)){std::cerr<<err<<"\n";return 6;}
    std::cout<<"RotateUV Native Unfold V2: charts="<<charts.size()<<" cutVerts="<<c.cutVertexCount<<" seams="<<m.seams.size()
             <<" slim="<<slimCharts<<" planar="<<planarCharts<<" fallbacks="<<fallbackCount<<" flips="<<totalFlips<<" iters="<<slimIters<<"\n";
    return 0;
}
