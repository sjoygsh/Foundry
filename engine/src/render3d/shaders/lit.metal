// M22 §8: metallic-roughness, glTF Appendix B and analytic ambient DFG.
#include <metal_stdlib>
using namespace metal;
struct PackedLight { float4 position_kind, direction_range, color_intensity, cone_shadow; };
struct Frame {
    float4x4 view_projection; float4 camera_exposure; float4 ambient; uint4 counts;
    float4 camera_forward; float4 shadow_splits; float4 shadow_parameters;
    float4 shadow_tiles[32]; float4 shadow_tile_parameters[32]; float4x4 shadow_matrices[32];
    PackedLight lights[16];
    float4 environment_sh[9]; float4 environment;
};
struct Constants { float4x4 world; float3x3 cofactor; };
struct Material {
    float4 base_color; float alpha_cutoff; float p0,p1,p2;
    float4 surface; float4 emissive_strength;
};
static_assert(sizeof(Frame)==4416, "Frame matches lighting.zig");
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
// Nine pre-convolved coefficients, rgb, already times the intensity: asset.environment.evaluate.
static float3 environmentHarmonics(constant Frame &frame,float3 n) {
    float3 r=frame.environment_sh[0].rgb*0.282095f;
    r+=frame.environment_sh[1].rgb*(0.488603f*n.y);
    r+=frame.environment_sh[2].rgb*(0.488603f*n.z);
    r+=frame.environment_sh[3].rgb*(0.488603f*n.x);
    r+=frame.environment_sh[4].rgb*(1.092548f*n.x*n.y);
    r+=frame.environment_sh[5].rgb*(1.092548f*n.y*n.z);
    r+=frame.environment_sh[6].rgb*(0.315392f*(3*n.z*n.z-1));
    r+=frame.environment_sh[7].rgb*(1.092548f*n.x*n.z);
    r+=frame.environment_sh[8].rgb*(0.546274f*(n.x*n.x-n.y*n.y));
    return r;
}
constant float3 TINTS[4]={float3(1,.25,.25),float3(.25,1,.25),float3(.25,.25,1),float3(1,1,.25)};
// One tile's 3x3 comparison filter (shadows-cascaded.md §5, shadows-local.md §6), each tap
// clamped two texels inside its tile so none reads a neighbour's depth; w is -1 when the point
// leaves the tile. A perspective tile divides by w, and its normal offset grows with `axial`,
// the receiver's depth along the light's axis; a cascade's is in metres, `axial` 1.
// rgb is the light's transmittance (shadows-local.md §9): each tap whose receiver lies beyond
// the translucent depth by more than the tile's relative bias takes the atlas's colour, any
// other white, and only in a frame that drew translucent casters (counts.w).
// A sized light's tile has a penumbra scale, p.z (shadows-local.md §10): sixteen point reads
// on DISC find the blockers within the light's size projected through the receiver, their
// mean depth gives the penumbra's half width, from 1.5 texels to ambient.w, and sixteen
// comparison taps on DISC at that width filter it. With no blocker the point is lit. A zero
// scale is M39's 3x3 filter exactly. lighting.penumbra_disc holds the same points.
constant float2 DISC[16]={
    float2(0.176777,0.000000),float2(-0.225772,0.206826),float2(0.034558,-0.393771),float2(0.284571,0.371173),
    float2(-0.522223,-0.092374),float2(0.494695,-0.314685),float2(-0.165466,0.615525),float2(-0.315561,-0.607594),
    float2(0.684642,0.250030),float2(-0.712256,0.294009),float2(0.343354,-0.733729),float2(0.253730,0.808932),
    float2(-0.764746,-0.443186),float2(0.897134,-0.197232),float2(-0.547507,0.778772),float2(-0.126487,-0.976090)};
static float4 tileShadow(constant Frame &frame,uint t,float3 world,float3 normal,float axial,
    depth2d<float> shadow_image,sampler shadow_sampler,texture2d<float> tint_image,sampler tint_sampler) {
    float4 p=frame.shadow_tile_parameters[t];
    float4 h=frame.shadow_matrices[t]*float4(world+normal*p.x*axial,1);
    if (p.y != 0) { if (h.w <= 0) return float4(1,1,1,-1); h.xyz/=h.w; }
    float3 q=h.xyz;
    float4 tile=frame.shadow_tiles[t];
    if (any(q.xy<tile.xy) || any(q.xy>tile.zw) || q.z<0 || q.z>1) return float4(1,1,1,-1);
    float2 lo=tile.xy+frame.shadow_parameters.zw, hi=tile.zw-frame.shadow_parameters.zw;
    bool tinted=(frame.counts.w & 1u) != 0;
    float visibility=0;
    float3 transmit=0;
    if (p.z != 0) {
        float limit=frame.ambient.w;
        float search=clamp((1-q.z)*p.z,1.5f,limit);
        float sum=0;
        int found=0;
        for (int i=0;i<16;i++) {
            float d=shadow_image.sample(tint_sampler,clamp(q.xy+DISC[i]*search*frame.shadow_parameters.xy,lo,hi));
            if (d > q.z) { sum+=d; found++; }
        }
        if (found == 0 && !tinted) return float4(1);
        float width=found > 0 ? clamp((sum/found-q.z)*p.z,1.5f,limit) : 1.5f;
        for (int i=0;i<16;i++) {
            float2 c=clamp(q.xy+DISC[i]*width*frame.shadow_parameters.xy,lo,hi);
            visibility+=found > 0 ? shadow_image.sample_compare(shadow_sampler,c,q.z) : 1.0f;
            if (tinted) {
                float4 f=tint_image.sample(tint_sampler,c);
                transmit+=q.z < f.a*(1-p.w) ? f.rgb : float3(1);
            }
        }
        return float4(tinted ? transmit/16 : float3(1),visibility/16);
    }
    for (int y=-1;y<=1;y++) for (int x=-1;x<=1;x++) {
        float2 c=clamp(q.xy+float2(x,y)*frame.shadow_parameters.xy,lo,hi);
        visibility+=shadow_image.sample_compare(shadow_sampler,c,q.z);
        if (tinted) {
            float4 f=tint_image.sample(tint_sampler,c);
            transmit+=q.z < f.a*(1-p.w) ? f.rgb : float3(1);
        }
    }
    return float4(tinted ? transmit/9 : float3(1),visibility/9);
}
static float4 shade(VertexOut in,bool front,bool mask,bool normal_map,
    constant Frame &frame,constant Material &material,
    texture2d<float> base_image,sampler base_sampler,
    texture2d<float> mr_image,sampler mr_sampler,
    texture2d<float> normal_image,sampler normal_sampler,
    texture2d<float> ao_image,sampler ao_sampler,
    texture2d<float> emissive_image,sampler emissive_sampler,
    depth2d<float> shadow_image,sampler shadow_sampler,texture2d<float> tint_image,sampler tint_sampler,
    texturecube<float> environment_image,sampler environment_sampler) {
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
        // A light's tiles start at cone_shadow.z - 1, cone_shadow.w of them (shadows-local.md §8).
        uint first=uint(light.cone_shadow.z)-1;
        float3 tint=1;
        if (light.cone_shadow.z != 0 && light.position_kind.w == 0 && cascade < frame.counts.y) {
            float4 shadow=tileShadow(frame,first+cascade,in.world,geometric_normal,1,shadow_image,shadow_sampler,tint_image,tint_sampler);
            if (shadow.w < 0) shadow=float4(1);
            if (next_weight > 0) {
                float4 next=cascade+1 < frame.counts.y ? tileShadow(frame,first+cascade+1,in.world,geometric_normal,1,shadow_image,shadow_sampler,tint_image,tint_sampler) : float4(1);
                if (next.w >= 0) shadow=mix(shadow,next,next_weight);
            }
            falloff*=shadow.w;
            tint=shadow.rgb;
        } else if (light.cone_shadow.z != 0 && light.position_kind.w != 0) {
            // One tile for a spot to pi/3, its offset scaled by depth along its axis; six faces
            // otherwise, the face the offset light-to-receiver vector's largest component names,
            // ties in face order, as lighting.chooseFace (shadows-local.md §7).
            float3 from=in.world-light.position_kind.xyz;
            uint t=first;
            float axial;
            if (light.cone_shadow.w == 1) axial=max(dot(from,light.direction_range.xyz),0.0f);
            else {
                float3 a=abs(from);
                axial=max(a.x,max(a.y,a.z));
                float3 o=from+geometric_normal*frame.shadow_tile_parameters[first].x*axial;
                float3 b=abs(o);
                t+=(b.x>=b.y && b.x>=b.z) ? (o.x>=0 ? 0u : 1u) : (b.y>=b.z) ? (o.y>=0 ? 2u : 3u) : (o.z>=0 ? 4u : 5u);
            }
            float4 shadow=tileShadow(frame,t,in.world,geometric_normal,axial,shadow_image,shadow_sampler,tint_image,tint_sampler);
            if (shadow.w >= 0) { falloff*=shadow.w; tint=shadow.rgb; }
        }
        result+=brdf(base.rgb,metal,rough,n,v,l)*light.color_intensity.rgb*light.color_intensity.w*falloff*tint;
    }
    float ao=1+material.surface.w*(ao_image.sample(ao_sampler,in.uv).r-1);
    float2 ab=ambient_dfg(rough,max(dot(n,v),0.0f));
    float3 f0=mix(float3(.04),base.rgb,metal);
    float3 spec=max(f0*ab.x+ab.y,float3(0));
    float dielectric=.04*ab.x+ab.y;
    result+=frame.ambient.rgb*((1-dielectric)*base.rgb*(1-metal)+spec)*ao;
    // The environment (environment.md §8), when counts.w's second bit binds one: its harmonics at
    // the normal, and its cube along the reflection at roughness times its top level, both turned
    // by its yaw, through the same split sum as the constant ambient (lighting.environmentTerm).
    if ((frame.counts.w & 2u) != 0) {
        float c=frame.environment.z, s=frame.environment.w;
        float3 r=2*dot(n,v)*n-v;
        float3 irradiance=environmentHarmonics(frame,float3(c*n.x-s*n.z,n.y,s*n.x+c*n.z));
        float3 radiance=environment_image.sample(environment_sampler,float3(c*r.x-s*r.z,r.y,s*r.x+c*r.z),level(rough*frame.environment.x)).rgb*frame.environment.y;
        result+=(irradiance*(1-dielectric)*base.rgb*(1-metal)+radiance*spec)*ao;
    }
    result+=material.emissive_strength.rgb*emissive_image.sample(emissive_sampler,in.uv).rgb*material.emissive_strength.w;
    if (frame.counts.z != 0 && cascade < frame.counts.y)
        result*=mix(TINTS[cascade],cascade+1 < frame.counts.y ? TINTS[cascade+1] : float3(1),next_weight);
    return float4(result*frame.camera_exposure.w*base.a,base.a);

}
fragment float4 fragmentLit0(VertexOut in [[stage_in]],bool front [[front_facing]],
    constant Frame &frame [[buffer(9)]],constant Material &material [[buffer(10)]],
    texture2d<float> base_image [[texture(3)]],sampler base_sampler [[sampler(3)]],
    texture2d<float> mr_image [[texture(4)]],sampler mr_sampler [[sampler(4)]],
    texture2d<float> normal_image [[texture(5)]],sampler normal_sampler [[sampler(5)]],
    texture2d<float> ao_image [[texture(6)]],sampler ao_sampler [[sampler(6)]],
    texture2d<float> emissive_image [[texture(7)]],sampler emissive_sampler [[sampler(7)]],
    depth2d<float> shadow_image [[texture(0)]],sampler shadow_sampler [[sampler(0)]],
    texture2d<float> tint_image [[texture(1)]],sampler tint_sampler [[sampler(1)]],
    texturecube<float> environment_image [[texture(2)]],sampler environment_sampler [[sampler(2)]]) {
    return shade(in,front,false,false,frame,material,base_image,base_sampler,mr_image,mr_sampler,normal_image,normal_sampler,ao_image,ao_sampler,emissive_image,emissive_sampler,shadow_image,shadow_sampler,tint_image,tint_sampler,environment_image,environment_sampler);
}
fragment float4 fragmentLit1(VertexOut in [[stage_in]],bool front [[front_facing]],
    constant Frame &frame [[buffer(9)]],constant Material &material [[buffer(10)]],
    texture2d<float> base_image [[texture(3)]],sampler base_sampler [[sampler(3)]],
    texture2d<float> mr_image [[texture(4)]],sampler mr_sampler [[sampler(4)]],
    texture2d<float> normal_image [[texture(5)]],sampler normal_sampler [[sampler(5)]],
    texture2d<float> ao_image [[texture(6)]],sampler ao_sampler [[sampler(6)]],
    texture2d<float> emissive_image [[texture(7)]],sampler emissive_sampler [[sampler(7)]],
    depth2d<float> shadow_image [[texture(0)]],sampler shadow_sampler [[sampler(0)]],
    texture2d<float> tint_image [[texture(1)]],sampler tint_sampler [[sampler(1)]],
    texturecube<float> environment_image [[texture(2)]],sampler environment_sampler [[sampler(2)]]) {
    return shade(in,front,true,false,frame,material,base_image,base_sampler,mr_image,mr_sampler,normal_image,normal_sampler,ao_image,ao_sampler,emissive_image,emissive_sampler,shadow_image,shadow_sampler,tint_image,tint_sampler,environment_image,environment_sampler);
}
fragment float4 fragmentLit2(VertexOut in [[stage_in]],bool front [[front_facing]],
    constant Frame &frame [[buffer(9)]],constant Material &material [[buffer(10)]],
    texture2d<float> base_image [[texture(3)]],sampler base_sampler [[sampler(3)]],
    texture2d<float> mr_image [[texture(4)]],sampler mr_sampler [[sampler(4)]],
    texture2d<float> normal_image [[texture(5)]],sampler normal_sampler [[sampler(5)]],
    texture2d<float> ao_image [[texture(6)]],sampler ao_sampler [[sampler(6)]],
    texture2d<float> emissive_image [[texture(7)]],sampler emissive_sampler [[sampler(7)]],
    depth2d<float> shadow_image [[texture(0)]],sampler shadow_sampler [[sampler(0)]],
    texture2d<float> tint_image [[texture(1)]],sampler tint_sampler [[sampler(1)]],
    texturecube<float> environment_image [[texture(2)]],sampler environment_sampler [[sampler(2)]]) {
    return shade(in,front,false,true,frame,material,base_image,base_sampler,mr_image,mr_sampler,normal_image,normal_sampler,ao_image,ao_sampler,emissive_image,emissive_sampler,shadow_image,shadow_sampler,tint_image,tint_sampler,environment_image,environment_sampler);
}
fragment float4 fragmentLit3(VertexOut in [[stage_in]],bool front [[front_facing]],
    constant Frame &frame [[buffer(9)]],constant Material &material [[buffer(10)]],
    texture2d<float> base_image [[texture(3)]],sampler base_sampler [[sampler(3)]],
    texture2d<float> mr_image [[texture(4)]],sampler mr_sampler [[sampler(4)]],
    texture2d<float> normal_image [[texture(5)]],sampler normal_sampler [[sampler(5)]],
    texture2d<float> ao_image [[texture(6)]],sampler ao_sampler [[sampler(6)]],
    texture2d<float> emissive_image [[texture(7)]],sampler emissive_sampler [[sampler(7)]],
    depth2d<float> shadow_image [[texture(0)]],sampler shadow_sampler [[sampler(0)]],
    texture2d<float> tint_image [[texture(1)]],sampler tint_sampler [[sampler(1)]],
    texturecube<float> environment_image [[texture(2)]],sampler environment_sampler [[sampler(2)]]) {
    return shade(in,front,true,true,frame,material,base_image,base_sampler,mr_image,mr_sampler,normal_image,normal_sampler,ao_image,ao_sampler,emissive_image,emissive_sampler,shadow_image,shadow_sampler,tint_image,tint_sampler,environment_image,environment_sampler);
}
