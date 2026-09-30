#version 450
#extension GL_ARB_enhanced_layouts : require
layout(location=0) in vec3 position;
layout(location=1) in vec3 normal;
#ifdef COLOR
layout(location=5) in vec4 color;
#endif
#ifdef UV
layout(location=3) in vec2 uv;
#endif
#ifdef TANGENT
layout(location=2) in vec4 tangent;
#endif
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
layout(push_constant,std430) uniform Constants {
    layout(offset=0) mat4 world;
    layout(offset=64) mat3 cofactor;
} constants;
layout(location=0) out vec2 out_uv;
layout(location=1) out vec4 out_color;
layout(location=2) out vec3 out_world;
layout(location=3) out vec3 out_normal;
layout(location=4) out vec4 out_tangent;
void main() {
    vec4 p = constants.world * vec4(position,1);
    gl_Position = frame.view_projection * p;
    out_world = p.xyz;
    float handedness = determinant(mat3(constants.world)) < 0 ? -1 : 1;
    out_normal = constants.cofactor * normal * handedness;
    out_uv = vec2(0);
    out_color = vec4(1);
    out_tangent = vec4(1,0,0,1);
#ifdef UV
    out_uv = uv;
#endif
#ifdef COLOR
    out_color = color;
#endif
#ifdef TANGENT
    out_tangent = vec4(mat3(constants.world) * tangent.xyz, tangent.w * handedness);
#endif
}
