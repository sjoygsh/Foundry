#version 450

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_color;

layout(push_constant, std430) uniform Constants {
    layout(offset = 0, column_major) mat4 transform;
    layout(offset = 64) vec4 tint;
} constants;

layout(set = 0, binding = 0) uniform texture2D image;
layout(set = 0, binding = 1) uniform sampler image_sampler;
layout(set = 0, binding = 2, std140) uniform Frame {
    layout(offset = 0) vec4 modulate;
} frame;

void main() {
    out_color = texture(sampler2D(image, image_sampler), in_uv) * constants.tint * frame.modulate;
}
