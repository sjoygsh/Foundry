// The sandbox's textured quad. Foundry's first shader.
//
// Written against the Metal binding convention in `docs/design/rhi.md` §9, which is a
// contract rather than an implementation detail: a shader is compiled against these
// indices, and getting one wrong does not fail — it silently reads the wrong resource.
// Every index below is spelled out with the rule it comes from, because that is the
// documentation a mod author will eventually be reading (CLAUDE.md §5).
//
// Per ADR-0015 this is MSL by choice, not by accident. A second backend brings a second
// variant of this file rather than a redesign of how shaders are referenced.

#include <metal_stdlib>
using namespace metal;

// §9: vertex buffer slots occupy buffer indices 0..7, and an attribute's `location` is the
// index the pipeline's vertex layout declares. Slot 0 is the only one this quad uses.
struct VertexIn {
    float2 position [[attribute(0)]];
    float2 uv       [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// §9: inline constants live at buffer index 8, in **both** stages, because an index is
// allocated per binding rather than per stage. Push-constant-style: part of the command
// stream, scoped to one render pass, replaced whole.
//
// Layout must match `Constants` in main.zig exactly. It is asserted there rather than
// trusted — `float4x4` is column-major in MSL and `core.math.Mat4` stores columns, so the
// two agree byte for byte.
struct Constants {
    float4x4 transform;
    float4   tint;
};

// §9: bind group buffers are allocated from index 9 upward, walking groups in ascending
// order and each group's entries in ascending `binding`. This is group 0's binding 2 — the
// only buffer in the only group — so it lands at 9.
struct Frame {
    float4 modulate;
};

vertex VertexOut vertexMain(
    VertexIn in [[stage_in]],
    constant Constants &k [[buffer(8)]]
) {
    VertexOut out;
    out.position = k.transform * float4(in.position, 0.0, 1.0);
    out.uv = in.uv;
    return out;
}

fragment float4 fragmentMain(
    VertexOut in [[stage_in]],
    constant Constants &k    [[buffer(8)]],
    constant Frame     &f    [[buffer(9)]],
    // The texture and sampler tables are counted separately from the buffer table and each
    // start at 0, so group 0's binding 0 and binding 1 land at texture(0) and sampler(0).
    texture2d<float>    tex  [[texture(0)]],
    sampler             samp [[sampler(0)]]
) {
    // The texture is sRGB and so is the surface, so this multiply happens in linear space
    // and the write encodes back. Getting that wrong is invisible until it is not.
    return tex.sample(samp, in.uv) * k.tint * f.modulate;
}
