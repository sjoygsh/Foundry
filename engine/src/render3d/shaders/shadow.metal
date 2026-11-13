// M22 §9: opaque and alpha-masked directional casters.
#include <metal_stdlib>
using namespace metal;

struct Constants { float4x4 world; float3x3 cofactor; };
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

// The cascade's light matrix arrives folded into `world` (`shadows-cascaded.md` §4), so no
// caster reads the frame uniform.
static VertexOut finishVertex(float3 position, float2 uv, float4 color, constant Constants &constants)
{
    VertexOut out;
    out.position = constants.world * float4(position, 1.0);
    out.uv = uv;
    out.color = color;
    return out;
}

vertex VertexOut vertexMain(PositionIn in [[stage_in]],
                            constant Constants &constants [[buffer(8)]])
{ return finishVertex(in.position, float2(0), float4(1), constants); }

vertex VertexOut vertexColor(PositionColorIn in [[stage_in]],
                             constant Constants &constants [[buffer(8)]])
{ return finishVertex(in.position, float2(0), in.color, constants); }

vertex VertexOut vertexUv(PositionUvIn in [[stage_in]],
                          constant Constants &constants [[buffer(8)]])
{ return finishVertex(in.position, in.uv, float4(1), constants); }

vertex VertexOut vertexUvColor(PositionUvColorIn in [[stage_in]],
                               constant Constants &constants [[buffer(8)]])
{ return finishVertex(in.position, in.uv, in.color, constants); }

fragment void fragmentMain() {}
fragment void fragmentMask(VertexOut in [[stage_in]],
    constant Material &material [[buffer(10)]],
    texture2d<float> image [[texture(1)]], sampler image_sampler [[sampler(1)]]) {
    float alpha=image.sample(image_sampler,in.uv).a*in.color.a*material.base_color.a;
    if (alpha < material.alpha_cutoff) discard_fragment();
}
