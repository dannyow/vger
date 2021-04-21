// Copyright © 2021 Audulus LLC. All rights reserved.

#include <metal_stdlib>
using namespace metal;

#include "include/vger_types.h"
#include "sdf.h"

struct VertexOut {
    float4 position  [[ position ]];
    float2 p;
    int primIndex;
};

float sdPrim(const device vgerPrim& prim, float2 p) {
    float d = FLT_MAX;
    switch(prim.type) {
        case vgerBezier:
            // d = sdBezier(p, prim.cvs[0], prim.cvs[1], prim.cvs[2]);
            d = sdBezierApprox(p, prim.cvs[0], prim.cvs[1], prim.cvs[2]);
            break;
        case vgerCircle:
            d = sdCircle(p - prim.cvs[0], prim.radius);
            break;
        case vgerArc:
            d = sdArc(p - prim.cvs[0], prim.cvs[1], prim.cvs[2], prim.radius, 0.002);
            break;
        case vgerRect:
            d = sdBox(p - prim.cvs[0], prim.cvs[1], prim.radius);
            break;
        case vgerSegment:
            d = sdSegment(p, prim.cvs[0], prim.cvs[1]);
            break;
        case vgerCurve:
            for(int i=0;i<prim.count-2;i+=2) {
                d = min(d, sdBezierApprox(p,
                                          prim.cvs[i],
                                          prim.cvs[i+1],
                                          prim.cvs[i+2]));
            }
            break;
    }
    return d;
}

// Oriented bounding box.
struct OBB {
    float2 origin;
    float2 u;
    float2 v;

    OBB inset(float d) const {
        auto un = normalize(u);
        auto vn = normalize(v);
        return {origin+d*(un+vn), u-2*d*un, v-2*d*vn};
    }
};

// Projection of b onto a.
float2 proj(float2 a, float2 b) {
    return normalize(a) * dot(a,b) / length(a);
}

float2 orth(float2 a, float2 b) {
    return b - proj(a, b);
}

float2 rot90(float2 p) {
    return {-p.y, p.x};
}

OBB sdPrimOBB(const device vgerPrim& prim) {
    switch(prim.type) {
        case vgerBezier: {
            auto o = prim.cvs[0];
            auto u = prim.cvs[2]-o;
            auto v = orth(prim.cvs[2]-o, prim.cvs[1]-o);
            return { o, u, v };
        }
        case vgerCircle: {
            auto d = 2*prim.radius;
            return { prim.cvs[0] - prim.radius, {d,0}, {0,d} };
        }
        case vgerRect: {
            auto sz = prim.cvs[1];
            return { prim.cvs[0]-sz, {2*sz.x,0}, {0,2*sz.y} };
        }
        case vgerSegment: {
            auto a = prim.cvs[0];
            auto u = prim.cvs[1] - prim.cvs[0];
            auto v = rot90(u)*.001;
            return { a, u, v };
        }
        case vgerCurve: {
            // XXX: not oriented
            float2 lo = FLT_MAX;
            float2 hi = FLT_MIN;
            for(int i=0;i<prim.count;++i) {
                lo = min(lo, prim.cvs[i]);
                hi = max(hi, prim.cvs[i]);
            }
            auto sz = hi-lo;
            return {lo, {sz.x,0}, {0,sz.y}};
        }
        case vgerArc: {
            auto o = prim.cvs[0];
            auto r = prim.radius;
            return { o-r, {2*r, 0}, {0, 2*r}};
        }
    }
    return {0,0};
}

constant float2 verts[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };

vertex VertexOut vger_vertex(uint vid [[vertex_id]],
                             uint iid [[instance_id]],
                             const device vgerPrim* prims) {
    
    device auto& prim = prims[iid];
    
    VertexOut out;
    out.primIndex = iid;
    
    auto rect = sdPrimOBB(prim).inset(-0.02);

    out.p = verts[vid].x * rect.u + verts[vid].y * rect.v + rect.origin;
    out.position = float4(prim.xform * float3(out.p, 1), 1);
    
    return out;
}

fragment float4 vger_fragment(VertexOut in [[ stage_in ]],
                              const device vgerPrim* prims) {
    
    device auto& prim = prims[in.primIndex];
    
    float d = sdPrim(prim, in.p);

    auto sw = prim.width; // stroke width

    if(d > 2*sw) {
        discard_fragment();
    }

    float fw = length(fwidth(in.p));

    return mix(float4(prim.colors[0].rgb,0.1), prim.colors[0], 1.0-smoothstep(sw,sw+fw,d) );

}
