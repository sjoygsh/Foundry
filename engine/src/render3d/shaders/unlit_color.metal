// Foundry's first 3D shader: position plus linear vertex colour, with no material.
// The fixed indices are ADR-0054's mesh semantics and rhi.md §9's binding map.

#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float3 position [[attribute(0)]];
    float4 color    [[attribute(5)]];
};

struct VertexOut {
    float4 position [[position]];
    float4 color;
};

struct Frame {
    float4x4 view_projection;
};

struct Constants {
    float4x4 world;
};

vertex VertexOut vertexMain(VertexIn in [[stage_in]],
                            constant Frame &frame [[buffer(9)]],
                            constant Constants &constants [[buffer(8)]])
{
    VertexOut out;
    out.position = frame.view_projection * constants.world * float4(in.position, 1.0);
    out.color = in.color;
    return out;
}

fragment float4 fragmentMain(VertexOut in [[stage_in]])
{
    // The render target is sRGB, so this linear value is encoded by the attachment.
    return in.color;
}
