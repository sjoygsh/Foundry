#version 450

layout(location = 0) in vec2 in_position;
layout(location = 1) in vec2 in_uv;
layout(location = 0) out vec2 out_uv;

layout(push_constant, std430) uniform Constants {
    layout(offset = 0, column_major) mat4 transform;
    layout(offset = 64) vec4 tint;
} constants;

void main() {
    gl_Position = constants.transform * vec4(in_position, 0.0, 1.0);
    out_uv = in_uv;
}
