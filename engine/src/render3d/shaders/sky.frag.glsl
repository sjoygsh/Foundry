#version 450
#extension GL_ARB_enhanced_layouts : require
// M41's sky pass (environment.md §9), as sky.metal draws it.
layout(location=0) in vec4 near_point;
layout(location=1) in vec4 mid_point;
layout(location=0) out vec4 out_color;
struct PackedLight { vec4 position_kind; vec4 direction_range; vec4 color_intensity; vec4 cone_shadow; };
layout(set=0,binding=0,std140) uniform Frame {
    layout(offset=0) mat4 view_projection;
    layout(offset=64) vec4 camera_exposure;
    layout(offset=80) vec4 ambient;
    layout(offset=96) uvec4 counts;
    layout(offset=112) vec4 camera_forward;
    layout(offset=128) vec4 shadow_splits;
    layout(offset=144) vec4 shadow_parameters;
    layout(offset=160) vec4 shadow_tiles[32];
    layout(offset=672) vec4 shadow_tile_parameters[32];
    layout(offset=1184) mat4 shadow_matrices[32];
    layout(offset=3232) PackedLight lights[16];
    layout(offset=4256) vec4 environment_sh[9];
    layout(offset=4400) vec4 environment;
} frame;
layout(set=0,binding=5) uniform textureCube environment_image;
layout(set=0,binding=6) uniform sampler environment_sampler;
void main() {
    vec3 d = normalize(mid_point.xyz / mid_point.w - near_point.xyz / near_point.w);
    float c = frame.environment.z, s = frame.environment.w;
    vec3 r = vec3(c * d.x - s * d.z, d.y, s * d.x + c * d.z);
    vec3 radiance = textureLod(samplerCube(environment_image, environment_sampler), r, 0.0).rgb * frame.environment.y;
    out_color = vec4(radiance * frame.camera_exposure.w, 1.0);
}
