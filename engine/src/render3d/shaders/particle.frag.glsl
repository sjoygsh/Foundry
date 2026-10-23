#version 450
// M29's particle shading model (`docs/design/particles.md` §5): `particle.metal`'s fragment.
// Vertex colour arrives premultiplied with alpha scaled by (1 − additive), so it is not
// premultiplied again; the texel is. Light is emission plus ambient × base colour, pre-exposed.
#extension GL_ARB_enhanced_layouts : require
layout(location = 0) in vec2 in_uv;
layout(location = 1) in vec4 in_color;
layout(location = 0) out vec4 out_color;
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
layout(set=2,binding=0,std140) uniform Material {
    layout(offset=0) vec4 base_color;
    layout(offset=16) float alpha_cutoff;
    layout(offset=32) vec4 surface;
    layout(offset=48) vec4 emissive_strength;
} material;
layout(set=2,binding=1) uniform texture2D image;
layout(set=2,binding=2) uniform sampler image_sampler;
void main() {
    vec4 texel = texture(sampler2D(image, image_sampler), in_uv);
    vec3 light = material.base_color.rgb * frame.ambient.rgb
               + material.emissive_strength.rgb * material.emissive_strength.w;
    float opacity = texel.a * material.base_color.a;
    vec3 rgb = texel.rgb * opacity * in_color.rgb * light * frame.camera_exposure.w;
    out_color = vec4(rgb, opacity * in_color.a);
#ifdef MASK
    if (out_color.a < material.alpha_cutoff) discard;
#endif
}
