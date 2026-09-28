#version 450
layout(location = 0) in vec3 in_position;
layout(location = 3) in vec2 in_uv;
layout(location = 5) in vec4 in_color;
layout(location = 0) out vec2 out_uv;
layout(location = 1) out vec4 out_color;
layout(set = 0, binding = 0, std140) uniform Frame { layout(offset=0, column_major) mat4 view_projection; } frame;
layout(push_constant, std430) uniform Constants { layout(offset=0, column_major) mat4 world; } constants;
void main() {
    gl_Position = frame.view_projection * constants.world * vec4(in_position, 1.0);
    out_uv = in_uv; out_color = in_color;
}
