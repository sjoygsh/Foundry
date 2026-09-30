#version 450
layout(location = 0) in vec3 in_position;
layout(location = 3) in vec2 in_uv;
layout(location = 0) out vec2 out_uv;
layout(location = 1) out vec4 out_color;
struct PackedLight { vec4 position_kind; vec4 direction_range; vec4 color_intensity; vec4 cone_shadow; };
layout(set = 0, binding = 0, std140) uniform Frame {
    layout(offset=0, column_major) mat4 view_projection;
    layout(offset=64) vec4 camera_exposure;
    layout(offset=80) vec4 ambient;
    layout(offset=96) uvec4 counts;
    layout(offset=112, column_major) mat4 shadow_matrix;
    layout(offset=176) vec4 shadow_parameters;
    layout(offset=192) PackedLight lights[16];
} frame;
layout(push_constant, std430) uniform Constants {
    layout(offset=0, column_major) mat4 world;
    layout(offset=64, column_major) mat3 cofactor;
} constants;
void main() {
    gl_Position = frame.view_projection * constants.world * vec4(in_position, 1.0);
    out_uv = in_uv; out_color = vec4(1.0);
}
