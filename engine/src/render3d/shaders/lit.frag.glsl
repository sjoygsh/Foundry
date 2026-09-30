#version 450
#extension GL_ARB_enhanced_layouts : require
layout(location=0) in vec2 uv;
layout(location=1) in vec4 color;
layout(location=2) in vec3 world_position;
layout(location=3) in vec3 world_normal;
layout(location=4) in vec4 world_tangent;
layout(location=0) out vec4 out_color;
struct PackedLight { vec4 position_kind; vec4 direction_range; vec4 color_intensity; vec4 cone_shadow; };
layout(set=0,binding=0,std140) uniform Frame {
    layout(offset=0) mat4 view_projection;
    layout(offset=64) vec4 camera_exposure;
    layout(offset=80) vec4 ambient;
    layout(offset=96) uvec4 counts;
    layout(offset=112) mat4 shadow_matrix;
    layout(offset=176) vec4 shadow_parameters;
    layout(offset=192) PackedLight lights[16];
} frame;
layout(set=0,binding=1) uniform texture2D shadow_image;
layout(set=0,binding=2) uniform samplerShadow shadow_sampler;
layout(set=2,binding=0,std140) uniform Material {
    layout(offset=0) vec4 base_color;
    layout(offset=16) float alpha_cutoff;
layout(offset=32) vec4 surface;
    layout(offset=48) vec4 emissive_strength;
} material;
layout(set=2,binding=1) uniform texture2D base_image;
layout(set=2,binding=2) uniform sampler base_sampler;
layout(set=2,binding=3) uniform texture2D mr_image;
layout(set=2,binding=4) uniform sampler mr_sampler;
layout(set=2,binding=5) uniform texture2D normal_image;
layout(set=2,binding=6) uniform sampler normal_sampler;
layout(set=2,binding=7) uniform texture2D ao_image;
layout(set=2,binding=8) uniform sampler ao_sampler;
layout(set=2,binding=9) uniform texture2D emissive_image;
layout(set=2,binding=10) uniform sampler emissive_sampler;
const float PI = 3.141592653589793;
vec3 safe_normalize(vec3 value, vec3 fallback) {
    float scale = max(abs(value.x), max(abs(value.y), abs(value.z)));
    if (scale == 0) return fallback;
    return normalize(value / scale);
}
// glTF 2.0 Appendix B: dielectric diffuse retains its own .04 Fresnel,
// rather than using the mixed metallic F0 to attenuate diffuse a second time.
vec3 brdf(vec3 base, float metal, float rough, vec3 n, vec3 v, vec3 l) {
    float nv = max(dot(n,v),0), nl = max(dot(n,l),0);
    if (nv <= 0 || nl <= 0) return vec3(0);
    vec3 h = safe_normalize(v+l,n);
    float nh=max(dot(n,h),0), vh=max(dot(v,h),0);
    float a=rough*rough, a2=a*a;
    float d=(nh*nh*(a2-1)+1);
    float distribution=a2/(PI*d*d);
    float visibility=.5/max(nl*sqrt(nv*nv*(1-a2)+a2)+nv*sqrt(nl*nl*(1-a2)+a2),1e-7);
    float f=pow(1-vh,5);
    vec3 f0=mix(vec3(.04),base,metal);
    vec3 fresnel=f0+(1-f0)*f;
    return ((1-(.04+.96*f))*base*(1-metal)/PI + distribution*visibility*fresnel)*nl;
}
// Analytic split-sum DFG fit, Karis (2014), Physically Based Shading on Mobile.
// Permission: THIRD_PARTY_LICENSES/epic-ambient-dfg.md.
vec2 ambient_dfg(float rough, float nv) {
    vec4 r=rough*vec4(-1,-.0275,-.572,.022)+vec4(1,.0425,1.04,-.04);
    float a=min(r.x*r.x,exp2(-9.28*nv))*r.x+r.y;
    return vec2(-1.04,1.04)*a+r.zw;
}
void main() {
    vec4 base=texture(sampler2D(base_image,base_sampler),uv)*material.base_color*color;
#ifdef MASK
    if (base.a < material.alpha_cutoff) discard;
#endif
    vec4 mr=texture(sampler2D(mr_image,mr_sampler),uv);
    float metal=clamp(material.surface.x*mr.b,0,1);
    float rough=clamp(material.surface.y*mr.g,.045,1);
    vec3 n=safe_normalize(world_normal,vec3(0,0,1));
    vec3 geometric_normal=gl_FrontFacing ? n : -n;
#ifdef NORMAL_MAP
    vec3 t=safe_normalize(world_tangent.xyz-n*dot(n,world_tangent.xyz),vec3(1,0,0));
    vec3 b=cross(n,t)*world_tangent.w;
    vec3 sampled=texture(sampler2D(normal_image,normal_sampler),uv).xyz*2-1;
    sampled.xy*=material.surface.z;
    n=safe_normalize(t*sampled.x+b*sampled.y+n*sampled.z,n);
#endif
    if (!gl_FrontFacing) n=-n;
    vec3 v=safe_normalize(frame.camera_exposure.xyz-world_position,n);
    vec3 result=vec3(0);
    for (uint i=0;i<frame.counts.x;i++) {
        PackedLight light=frame.lights[i];
        vec3 l=-light.direction_range.xyz;
        float falloff=1;
        if (light.position_kind.w != 0) {
            vec3 delta=light.position_kind.xyz-world_position;
            float distance=length(delta);
            l=safe_normalize(delta,n);
            float range=light.direction_range.w;
            float ratio=range>0 ? distance/range : 0;
            falloff=max(1-pow(ratio,4),0)/max(distance*distance,1e-6);
            if (light.position_kind.w == 2) {
                float cone=clamp((dot(-l,light.direction_range.xyz)-light.cone_shadow.y)/(light.cone_shadow.x-light.cone_shadow.y),0,1);
                falloff*=cone*cone;
            }
        }
        if (frame.counts.y != 0 && light.cone_shadow.z != 0) {
            vec3 q=(frame.shadow_matrix*vec4(world_position+geometric_normal*frame.shadow_parameters.y,1)).xyz;
            if (all(lessThanEqual(abs(q.xy),vec2(1))) && q.z >= 0 && q.z <= 1) {
                vec2 coord=vec2(q.x*.5+.5,.5-q.y*.5);
                float visibility=0;
                for (int y=-1;y<=1;y++) for (int x=-1;x<=1;x++)
                    visibility+=texture(sampler2DShadow(shadow_image,shadow_sampler),vec3(coord+vec2(x,y)*frame.shadow_parameters.x,q.z));
                falloff*=visibility/9;
            }
        }
        result+=brdf(base.rgb,metal,rough,n,v,l)*light.color_intensity.rgb*light.color_intensity.w*falloff;
    }
    float ao=1+material.surface.w*(texture(sampler2D(ao_image,ao_sampler),uv).r-1);
    vec2 ab=ambient_dfg(rough,max(dot(n,v),0));
    vec3 f0=mix(vec3(.04),base.rgb,metal);
    vec3 spec=max(f0*ab.x+ab.y,vec3(0));
    float dielectric=.04*ab.x+ab.y;
    result+=frame.ambient.rgb*((1-dielectric)*base.rgb*(1-metal)+spec)*ao;
    result+=material.emissive_strength.rgb*texture(sampler2D(emissive_image,emissive_sampler),uv).rgb*material.emissive_strength.w;
    out_color=vec4(result*frame.camera_exposure.w*base.a,base.a);
}
