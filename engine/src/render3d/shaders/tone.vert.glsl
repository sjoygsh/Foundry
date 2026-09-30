#version 450
layout(location = 0) out vec2 out_uv;
void main() {
    vec2 xy = vec2(float((gl_VertexIndex << 1) & 2), float(gl_VertexIndex & 2));
    gl_Position = vec4(xy * 2.0 - 1.0, 0.0, 1.0);
    out_uv = vec2(xy.x, 1.0 - xy.y);
}
