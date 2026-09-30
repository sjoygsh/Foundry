// M20's engine-owned unlit shading model (`docs/design/meshes.md` §7.2).
#include <metal_stdlib>
using namespace metal;

struct PackedLight { float4 position_kind, direction_range, color_intensity, cone_shadow; };
struct Frame {
    float4x4 view_projection;
    float4 camera_exposure;
    float4 ambient;
    uint4 counts;
    float4x4 shadow_matrix;
    float4 shadow_parameters;
    PackedLight lights[16];
};
struct Constants { float4x4 world; float3x3 cofactor; };
static_assert(sizeof(PackedLight) == 64, "PackedLight must match lighting.zig");
static_assert(sizeof(Frame) == 1216, "Frame must match lighting.zig");
static_assert(sizeof(Constants) == 112, "Constants must match renderer.zig");
struct Material { float4 base_color; float alpha_cutoff; float p0,p1,p2; float4 surface; float4 emissive_strength; };
static_assert(sizeof(Material) == 64, "Material must match renderer.zig");

struct VertexOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
};

struct PositionIn { float3 position [[attribute(0)]]; };
struct PositionColorIn { float3 position [[attribute(0)]]; float4 color [[attribute(5)]]; };
struct PositionUvIn { float3 position [[attribute(0)]]; float2 uv [[attribute(3)]]; };
struct PositionUvColorIn {
    float3 position [[attribute(0)]];
    float2 uv [[attribute(3)]];
    float4 color [[attribute(5)]];
};

static VertexOut finishVertex(float3 position, float2 uv, float4 color,
                              constant Frame &frame, constant Constants &constants)
{
    VertexOut out;
    out.position = frame.view_projection * constants.world * float4(position, 1.0);
    out.uv = uv;
    out.color = color;
    return out;
}

vertex VertexOut vertexMain(PositionIn in [[stage_in]],
                            constant Frame &frame [[buffer(9)]],
                            constant Constants &constants [[buffer(8)]])
{ return finishVertex(in.position, float2(0), float4(1), frame, constants); }

vertex VertexOut vertexColor(PositionColorIn in [[stage_in]],
                             constant Frame &frame [[buffer(9)]],
                             constant Constants &constants [[buffer(8)]])
{ return finishVertex(in.position, float2(0), in.color, frame, constants); }

vertex VertexOut vertexUv(PositionUvIn in [[stage_in]],
                          constant Frame &frame [[buffer(9)]],
                          constant Constants &constants [[buffer(8)]])
{ return finishVertex(in.position, in.uv, float4(1), frame, constants); }

vertex VertexOut vertexUvColor(PositionUvColorIn in [[stage_in]],
                               constant Frame &frame [[buffer(9)]],
                               constant Constants &constants [[buffer(8)]])
{ return finishVertex(in.position, in.uv, in.color, frame, constants); }

static float4 shade(VertexOut in, constant Material &material,
                    texture2d<float> image, sampler image_sampler)
{
    float4 value = image.sample(image_sampler, in.uv) * in.color * material.base_color;
    value.rgb *= value.a;
    return value;
}

fragment float4 fragmentMain(VertexOut in [[stage_in]],
                             constant Material &material [[buffer(10)]],
                             texture2d<float> image [[texture(1)]],
                             sampler image_sampler [[sampler(1)]])
{ return shade(in, material, image, image_sampler); }

fragment float4 fragmentMask(VertexOut in [[stage_in]],
                             constant Material &material [[buffer(10)]],
                             texture2d<float> image [[texture(1)]],
                             sampler image_sampler [[sampler(1)]])
{
    float4 value = shade(in, material, image, image_sampler);
    if (value.a < material.alpha_cutoff) discard_fragment();
    return value;
}
