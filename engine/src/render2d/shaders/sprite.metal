// Foundry's sprite shader — the engine's own, embedded rather than loaded (ADR-0019).
//
// This is an *engine-owned* shader: the renderer cannot draw without it, which makes it
// machinery in the same category as the index buffer rather than content. It is
// deliberately not overridable — it is the other half of a contract with the batcher's
// vertex layout (docs/design/render2d.md §6), and a mod that replaced it could not honour
// that contract without also replacing the batcher. A mod that wants sprites to look
// different supplies a material, once the material system exists.
//
// Every binding index below is fixed by docs/design/rhi.md §9 and is a contract, not a
// preference:
//
// The entry points must be named vertexMain and fragmentMain: the backend looks them up
// by name, and a shader that calls them anything else fails pipeline creation rather than
// rendering wrongly. See docs/design/rhi.md §10.
//
//   attribute 0,1,2  -> the three fields of render2d.sprite.Vertex, in declaration order
//   buffer(8)        -> inline constants, both stages
//   texture(0)       -> bind group 0, binding 0
//   sampler(0)       -> bind group 0, binding 1

#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float2 position [[attribute(0)]];
    float2 uv       [[attribute(1)]];
    // uchar4_normalized in the vertex layout, so this arrives as 0..1 floats.
    float4 color    [[attribute(2)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
};

// 64 bytes, well inside the 128 the RHI guarantees. The camera changes every frame and
// nothing else does, so it is inline constants rather than a uniform buffer: command
// stream data needs none of the ring buffering a per-frame resource would.
struct Constants {
    float4x4 view_projection;
};

vertex VertexOut vertexMain(VertexIn in [[stage_in]],
                              constant Constants &constants [[buffer(8)]])
{
    VertexOut out;
    // z = 0: draw order is the sort key, not depth. There is no depth buffer here.
    out.position = constants.view_projection * float4(in.position, 0.0, 1.0);
    out.uv = in.uv;
    out.color = in.color;
    return out;
}

fragment float4 fragmentMain(VertexOut in [[stage_in]],
                               texture2d<float> image [[texture(0)]],
                               sampler image_sampler [[sampler(0)]])
{
    // The texture is an _srgb format, so this sample is already linear light.
    float4 texel = image.sample(image_sampler, in.uv);

    // PNG stores straight alpha; the pipeline blends premultiplied (BlendState
    // .premultiplied_alpha). Premultiplying here, after the sample, is the last point at
    // which it can be done without losing precision in the stored image.
    texel.rgb *= texel.a;

    // in.color is already premultiplied, by Color.toPremultipliedRgba8 on the CPU.
    return texel * in.color;
}
