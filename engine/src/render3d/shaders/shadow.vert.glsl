#version 450
layout(location = 0) in vec3 in_position;
#ifdef UV
layout(location = 3) in vec2 in_uv;
#endif
#ifdef COLOR
layout(location = 5) in vec4 in_color;
#endif
layout(location = 0) out vec2 out_uv;
layout(location = 1) out vec4 out_color;
layout(push_constant, std430) uniform Constants {
    layout(offset=0, column_major) mat4 world;
    layout(offset=64, column_major) mat3 cofactor;
} constants;
void main() {
    // The cascade's light matrix arrives folded into `world` (`shadows-cascaded.md` §4).
    gl_Position = constants.world * vec4(in_position, 1.0);
    out_uv = vec2(0); out_color = vec4(1);
#ifdef UV
    out_uv = in_uv;
#endif
#ifdef COLOR
    out_color = in_color;
#endif
}
