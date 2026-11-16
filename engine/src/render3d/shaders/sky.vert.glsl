#version 450
// M41's sky pass (environment.md §9), as sky.metal draws it.
layout(push_constant,std430) uniform Constants {
    layout(offset=0) mat4 inverse_view_projection;
} constants;
layout(location=0) out vec4 near_point;
layout(location=1) out vec4 mid_point;
void main() {
    vec2 xy = vec2(float((gl_VertexIndex << 1) & 2), float(gl_VertexIndex & 2)) * 2.0 - 1.0;
    gl_Position = vec4(xy, 0.0, 1.0);
    near_point = constants.inverse_view_projection * vec4(xy, 1.0, 1.0);
    mid_point = constants.inverse_view_projection * vec4(xy, 0.5, 1.0);
}
