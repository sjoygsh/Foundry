#version 450

// Vulkan's spelling of the shader-visible RHI contract in docs/design/rhi.md §9.
// Locations are the fields of render2d.sprite.Vertex; the push block is the
// camera's column-major Mat4 at offset zero.
layout(location = 0) in vec2 in_position;
layout(location = 1) in vec2 in_uv;
layout(location = 2) in vec4 in_color;

layout(location = 0) out vec2 out_uv;
layout(location = 1) out vec4 out_color;

layout(push_constant, std430) uniform Constants {
    layout(offset = 0, column_major) mat4 view_projection;
} constants;

void main() {
    gl_Position = constants.view_projection * vec4(in_position, 0.0, 1.0);
    out_uv = in_uv;
    out_color = in_color;
}
