// M22 §8: metallic-roughness, glTF Appendix B and analytic ambient DFG.
#include <metal_stdlib>
using namespace metal;
struct PackedLight { float4 position_kind, direction_range, color_intensity, cone_shadow; };
struct Frame {
    float4x4 view_projection; float4 camera_exposure; float4 ambient; uint4 counts;
    float4 camera_forward; float4 shadow_splits; float4 shadow_offsets; float4 shadow_parameters;
    float4 shadow_tiles[4]; float4x4 shadow_matrices[4]; PackedLight lights[16];
};
struct Constants { float4x4 world; float3x3 cofactor; };
struct Material {
    float4 base_color; float alpha_cutoff; float p0,p1,p2;
    float4 surface; float4 emissive_strength;
};
static_assert(sizeof(Frame)==1520, "Frame matches lighting.zig");
static_assert(sizeof(Constants)==112, "Constants matches renderer.zig");
static_assert(sizeof(Material)==64, "Material matches renderer.zig");
struct VertexOut {
    float4 position [[position]]; float2 uv; float4 color; float3 world;
    float3 normal; float4 tangent;
};
static VertexOut finishVertex(float3 p,float3 n,float2 uv,float4 color,float4 t,
                              constant Frame &frame,constant Constants &constants) {
    VertexOut out;
    float4 world=constants.world*float4(p,1);
    out.position=frame.view_projection*world;
    out.world=world.xyz;
    float3x3 basis=float3x3(constants.world[0].xyz,constants.world[1].xyz,constants.world[2].xyz);
    float sign=determinant(basis)<0 ? -1 : 1;
    out.normal=constants.cofactor*n*sign;
    out.tangent=float4(basis*t.xyz,t.w*sign);
    out.uv=uv; out.color=color;
    return out;
}
struct VertexIn0 { float3 position [[attribute(0)]]; float3 normal [[attribute(1)]];    };
vertex VertexOut vertexLit0(VertexIn0 in [[stage_in]],constant Frame &frame [[buffer(9)]],constant Constants &constants [[buffer(8)]]) {
    return finishVertex(in.position,in.normal,float2(0),float4(1),float4(1,0,0.0f,1.0f),frame,constants);
}
struct VertexIn1 { float3 position [[attribute(0)]]; float3 normal [[attribute(1)]]; float4 color [[attribute(5)]];   };
vertex VertexOut vertexLit1(VertexIn1 in [[stage_in]],constant Frame &frame [[buffer(9)]],constant Constants &constants [[buffer(8)]]) {
    return finishVertex(in.position,in.normal,float2(0),in.color,float4(1,0,0.0f,1.0f),frame,constants);
}
struct VertexIn2 { float3 position [[attribute(0)]]; float3 normal [[attribute(1)]];  float2 uv [[attribute(3)]];  };
vertex VertexOut vertexLit2(VertexIn2 in [[stage_in]],constant Frame &frame [[buffer(9)]],constant Constants &constants [[buffer(8)]]) {
    return finishVertex(in.position,in.normal,in.uv,float4(1),float4(1,0,0.0f,1.0f),frame,constants);
}
struct VertexIn3 { float3 position [[attribute(0)]]; float3 normal [[attribute(1)]]; float4 color [[attribute(5)]]; float2 uv [[attribute(3)]];  };
vertex VertexOut vertexLit3(VertexIn3 in [[stage_in]],constant Frame &frame [[buffer(9)]],constant Constants &constants [[buffer(8)]]) {
    return finishVertex(in.position,in.normal,in.uv,in.color,float4(1,0,0.0f,1.0f),frame,constants);
}
struct VertexIn4 { float3 position [[attribute(0)]]; float3 normal [[attribute(1)]];   float4 tangent [[attribute(2)]]; };
vertex VertexOut vertexLit4(VertexIn4 in [[stage_in]],constant Frame &frame [[buffer(9)]],constant Constants &constants [[buffer(8)]]) {
    return finishVertex(in.position,in.normal,float2(0),float4(1),in.tangent,frame,constants);
}
struct VertexIn5 { float3 position [[attribute(0)]]; float3 normal [[attribute(1)]]; float4 color [[attribute(5)]];  float4 tangent [[attribute(2)]]; };
vertex VertexOut vertexLit5(VertexIn5 in [[stage_in]],constant Frame &frame [[buffer(9)]],constant Constants &constants [[buffer(8)]]) {
    return finishVertex(in.position,in.normal,float2(0),in.color,in.tangent,frame,constants);
}
struct VertexIn6 { float3 position [[attribute(0)]]; float3 normal [[attribute(1)]];  float2 uv [[attribute(3)]]; float4 tangent [[attribute(2)]]; };
vertex VertexOut vertexLit6(VertexIn6 in [[stage_in]],constant Frame &frame [[buffer(9)]],constant Constants &constants [[buffer(8)]]) {
    return finishVertex(in.position,in.normal,in.uv,float4(1),in.tangent,frame,constants);
}
struct VertexIn7 { float3 position [[attribute(0)]]; float3 normal [[attribute(1)]]; float4 color [[attribute(5)]]; float2 uv [[attribute(3)]]; float4 tangent [[attribute(2)]]; };
vertex VertexOut vertexLit7(VertexIn7 in [[stage_in]],constant Frame &frame [[buffer(9)]],constant Constants &constants [[buffer(8)]]) {
    return finishVertex(in.position,in.normal,in.uv,in.color,in.tangent,frame,constants);
}
constant float PI = 3.141592653589793;
float3 safe_normalize(float3 value, float3 fallback) {
    float scale = max(abs(value.x), max(abs(value.y), abs(value.z)));
    if (scale == 0) return fallback;
    return normalize(value / scale);
}
// glTF 2.0 Appendix B: dielectric diffuse retains its own .04 Fresnel,
// rather than using the mixed metallic F0 to attenuate diffuse a second time.
float3 brdf(float3 base, float metal, float rough, float3 n, float3 v, float3 l) {
    float nv = max(dot(n,v),0.0f), nl = max(dot(n,l),0.0f);
    if (nv <= 0 || nl <= 0) return float3(0);
    float3 h = safe_normalize(v+l,n);
    float nh=max(dot(n,h),0.0f), vh=max(dot(v,h),0.0f);
    float a=rough*rough, a2=a*a;
    float d=(nh*nh*(a2-1)+1);
    float distribution=a2/(PI*d*d);
    float visibility=.5/max(nl*sqrt(nv*nv*(1-a2)+a2)+nv*sqrt(nl*nl*(1-a2)+a2),1e-7);
    float f=pow(1-vh,5.0f);
    float3 f0=mix(float3(.04),base,metal);
    float3 fresnel=f0+(1-f0)*f;
    return ((1-(.04+.96*f))*base*(1-metal)/PI + distribution*visibility*fresnel)*nl;
}
// Analytic split-sum DFG fit, Karis (2014), Physically Based Shading on Mobile.
// Permission: THIRD_PARTY_LICENSES/epic-ambient-dfg.md.
float2 ambient_dfg(float rough, float nv) {
    float4 r=rough*float4(-1,-.0275,-.572,.022)+float4(1,.0425,1.04,-.04);
    float a=min(r.x*r.x,exp2(-9.28*nv))*r.x+r.y;
    return float2(-1.04,1.04)*a+r.zw;
}
constant float3 TINTS[4]={float3(1,.25,.25),float3(.25,1,.25),float3(.25,.25,1),float3(1,1,.25)};
// shadows-cascaded.md §5: one cascade's 3x3 comparison filter, each tap clamped two texels
// inside its tile so none reads a neighbour's depth; -1 when the point leaves the tile.
static float cascadeVisibility(constant Frame &frame,uint c,float3 world,float3 normal,
    depth2d<float> shadow_image,sampler shadow_sampler) {
    float3 q=(frame.shadow_matrices[c]*float4(world+normal*frame.shadow_offsets[c],1)).xyz;
    float4 tile=frame.shadow_tiles[c];
    if (any(q.xy<tile.xy) || any(q.xy>tile.zw) || q.z<0 || q.z>1) return -1;
    float2 lo=tile.xy+frame.shadow_parameters.zw, hi=tile.zw-frame.shadow_parameters.zw;
    float visibility=0;
    for (int y=-1;y<=1;y++) for (int x=-1;x<=1;x++)
        visibility+=shadow_image.sample_compare(shadow_sampler,clamp(q.xy+float2(x,y)*frame.shadow_parameters.xy,lo,hi),q.z);
    return visibility/9;
}
static float4 shade(VertexOut in,bool front,bool mask,bool normal_map,
    constant Frame &frame,constant Material &material,
    texture2d<float> base_image,sampler base_sampler,
    texture2d<float> mr_image,sampler mr_sampler,
    texture2d<float> normal_image,sampler normal_sampler,
    texture2d<float> ao_image,sampler ao_sampler,
    texture2d<float> emissive_image,sampler emissive_sampler,
    depth2d<float> shadow_image,sampler shadow_sampler) {
    float4 base=base_image.sample(base_sampler,in.uv)*material.base_color*in.color;
    if (mask && base.a < material.alpha_cutoff) discard_fragment();
    float4 mr=mr_image.sample(mr_sampler,in.uv);
    float metal=clamp(material.surface.x*mr.b,0.0f,1.0f);
    float rough=clamp(material.surface.y*mr.g,.045f,1.0f);
    float3 n=safe_normalize(in.normal,float3(0,0.0f,1.0f));
    float3 geometric_normal=front ? n : -n;
    if (normal_map) {
    float3 t=safe_normalize(in.tangent.xyz-n*dot(n,in.tangent.xyz),float3(1,0,0.0f));
    float3 b=cross(n,t)*in.tangent.w;
    float3 sampled=normal_image.sample(normal_sampler,in.uv).xyz*2-1;
    sampled.xy*=material.surface.z;
    n=safe_normalize(t*sampled.x+b*sampled.y+n*sampled.z,n);
    }
    if (!front) n=-n;
    float3 v=safe_normalize(frame.camera_exposure.xyz-in.world,n);
    float3 result=float3(0);
    // The cascade by view depth, and the weight of the next across the band at its end
    // (lighting.chooseCascade); counts.y past the last split, unshadowed.
    uint cascade=frame.counts.y;
    float next_weight=0;
    float view_depth=dot(in.world-frame.camera_exposure.xyz,frame.camera_forward.xyz);
    float start=0;
    for (uint c=0;c<frame.counts.y;c++) {
        float end=frame.shadow_splits[c];
        if (view_depth <= end) {
            float band=frame.camera_forward.w*(end-start);
            cascade=c;
            next_weight=band > 0 ? clamp((view_depth-(end-band))/band,0.0f,1.0f) : 0;
            break;
        }
        start=end;
    }
    for (uint i=0;i<frame.counts.x;i++) {
        PackedLight light=frame.lights[i];
        float3 l=-light.direction_range.xyz;
        float falloff=1;
        if (light.position_kind.w != 0) {
            float3 delta=light.position_kind.xyz-in.world;
            float distance=length(delta);
            l=safe_normalize(delta,n);
            float range=light.direction_range.w;
            float ratio=range>0 ? distance/range : 0;
            falloff=max(1-pow(ratio,4.0f),0.0f)/max(distance*distance,1e-6);
            if (light.position_kind.w == 2) {
                float cone=clamp((dot(-l,light.direction_range.xyz)-light.cone_shadow.y)/(light.cone_shadow.x-light.cone_shadow.y),0.0f,1.0f);
                falloff*=cone*cone;
            }
        }
        if (cascade < frame.counts.y && light.cone_shadow.z != 0) {
            float visibility=cascadeVisibility(frame,cascade,in.world,geometric_normal,shadow_image,shadow_sampler);
            if (visibility < 0) visibility=1;
            if (next_weight > 0) {
                float next=cascade+1 < frame.counts.y ? cascadeVisibility(frame,cascade+1,in.world,geometric_normal,shadow_image,shadow_sampler) : 1;
                if (next >= 0) visibility=mix(visibility,next,next_weight);
            }
            falloff*=visibility;
        }
        result+=brdf(base.rgb,metal,rough,n,v,l)*light.color_intensity.rgb*light.color_intensity.w*falloff;
    }
    float ao=1+material.surface.w*(ao_image.sample(ao_sampler,in.uv).r-1);
    float2 ab=ambient_dfg(rough,max(dot(n,v),0.0f));
    float3 f0=mix(float3(.04),base.rgb,metal);
    float3 spec=max(f0*ab.x+ab.y,float3(0));
    float dielectric=.04*ab.x+ab.y;
    result+=frame.ambient.rgb*((1-dielectric)*base.rgb*(1-metal)+spec)*ao;
    result+=material.emissive_strength.rgb*emissive_image.sample(emissive_sampler,in.uv).rgb*material.emissive_strength.w;
    if (frame.counts.z != 0 && cascade < frame.counts.y)
        result*=mix(TINTS[cascade],cascade+1 < frame.counts.y ? TINTS[cascade+1] : float3(1),next_weight);
    return float4(result*frame.camera_exposure.w*base.a,base.a);

}
fragment float4 fragmentLit0(VertexOut in [[stage_in]],bool front [[front_facing]],
    constant Frame &frame [[buffer(9)]],constant Material &material [[buffer(10)]],
    texture2d<float> base_image [[texture(1)]],sampler base_sampler [[sampler(1)]],
    texture2d<float> mr_image [[texture(2)]],sampler mr_sampler [[sampler(2)]],
    texture2d<float> normal_image [[texture(3)]],sampler normal_sampler [[sampler(3)]],
    texture2d<float> ao_image [[texture(4)]],sampler ao_sampler [[sampler(4)]],
    texture2d<float> emissive_image [[texture(5)]],sampler emissive_sampler [[sampler(5)]],
    depth2d<float> shadow_image [[texture(0)]],sampler shadow_sampler [[sampler(0)]]) {
    return shade(in,front,false,false,frame,material,base_image,base_sampler,mr_image,mr_sampler,normal_image,normal_sampler,ao_image,ao_sampler,emissive_image,emissive_sampler,shadow_image,shadow_sampler);
}
fragment float4 fragmentLit1(VertexOut in [[stage_in]],bool front [[front_facing]],
    constant Frame &frame [[buffer(9)]],constant Material &material [[buffer(10)]],
    texture2d<float> base_image [[texture(1)]],sampler base_sampler [[sampler(1)]],
    texture2d<float> mr_image [[texture(2)]],sampler mr_sampler [[sampler(2)]],
    texture2d<float> normal_image [[texture(3)]],sampler normal_sampler [[sampler(3)]],
    texture2d<float> ao_image [[texture(4)]],sampler ao_sampler [[sampler(4)]],
    texture2d<float> emissive_image [[texture(5)]],sampler emissive_sampler [[sampler(5)]],
    depth2d<float> shadow_image [[texture(0)]],sampler shadow_sampler [[sampler(0)]]) {
    return shade(in,front,true,false,frame,material,base_image,base_sampler,mr_image,mr_sampler,normal_image,normal_sampler,ao_image,ao_sampler,emissive_image,emissive_sampler,shadow_image,shadow_sampler);
}
fragment float4 fragmentLit2(VertexOut in [[stage_in]],bool front [[front_facing]],
    constant Frame &frame [[buffer(9)]],constant Material &material [[buffer(10)]],
    texture2d<float> base_image [[texture(1)]],sampler base_sampler [[sampler(1)]],
    texture2d<float> mr_image [[texture(2)]],sampler mr_sampler [[sampler(2)]],
    texture2d<float> normal_image [[texture(3)]],sampler normal_sampler [[sampler(3)]],
    texture2d<float> ao_image [[texture(4)]],sampler ao_sampler [[sampler(4)]],
    texture2d<float> emissive_image [[texture(5)]],sampler emissive_sampler [[sampler(5)]],
    depth2d<float> shadow_image [[texture(0)]],sampler shadow_sampler [[sampler(0)]]) {
    return shade(in,front,false,true,frame,material,base_image,base_sampler,mr_image,mr_sampler,normal_image,normal_sampler,ao_image,ao_sampler,emissive_image,emissive_sampler,shadow_image,shadow_sampler);
}
fragment float4 fragmentLit3(VertexOut in [[stage_in]],bool front [[front_facing]],
    constant Frame &frame [[buffer(9)]],constant Material &material [[buffer(10)]],
    texture2d<float> base_image [[texture(1)]],sampler base_sampler [[sampler(1)]],
    texture2d<float> mr_image [[texture(2)]],sampler mr_sampler [[sampler(2)]],
    texture2d<float> normal_image [[texture(3)]],sampler normal_sampler [[sampler(3)]],
    texture2d<float> ao_image [[texture(4)]],sampler ao_sampler [[sampler(4)]],
    texture2d<float> emissive_image [[texture(5)]],sampler emissive_sampler [[sampler(5)]],
    depth2d<float> shadow_image [[texture(0)]],sampler shadow_sampler [[sampler(0)]]) {
    return shade(in,front,true,true,frame,material,base_image,base_sampler,mr_image,mr_sampler,normal_image,normal_sampler,ao_image,ao_sampler,emissive_image,emissive_sampler,shadow_image,shadow_sampler);
}
