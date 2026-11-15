#version 450

// M41's layered-texture readback tests (`environment.md` §3): a full-target quad, as the
// Metal backend's `layered_msl` draws, so a fragment knows its pixel by position alone.
void main() {
    const vec2 corners[6] = vec2[6](vec2(-1, -1), vec2(1, -1), vec2(-1, 1), vec2(-1, 1), vec2(1, -1), vec2(1, 1));
    gl_Position = vec4(corners[gl_VertexIndex], 0.0, 1.0);
}
