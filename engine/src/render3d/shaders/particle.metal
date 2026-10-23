// M29's engine-owned particle shading model (`docs/design/particles.md` §5, ADR-0064).
//
// The vertex stage is unlit's `vertexUvColor`: position, UV0 and colour, unchanged. Only the
// fragment differs. Its vertex colour is already premultiplied by the expansion, with alpha
// scaled by (1 − additive), so it is not premultiplied again: an alpha of zero keeps its colour
// and adds it. The texel is premultiplied here. Its light is emission plus the frame's ambient
// times the base colour, pre-exposed as lit output is (ADR-0056).
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
static_assert(sizeof(Frame) == 1216, "Frame must match lighting.zig");
struct Material { float4 base_color; float alpha_cutoff; float p0,p1,p2; float4 surface; float4 emissive_strength; };
static_assert(sizeof(Material) == 64, "Material must match renderer.zig");

struct VertexOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
};

static float4 shade(VertexOut in, constant Frame &frame, constant Material &material,
                    texture2d<float> image, sampler image_sampler)
{
    float4 texel = image.sample(image_sampler, in.uv);
    float3 light = material.base_color.rgb * frame.ambient.rgb
                 + material.emissive_strength.rgb * material.emissive_strength.w;
    float opacity = texel.a * material.base_color.a;
    float3 rgb = texel.rgb * opacity * in.color.rgb * light * frame.camera_exposure.w;
    return float4(rgb, opacity * in.color.a);
}

fragment float4 fragmentParticle(VertexOut in [[stage_in]],
                                 constant Frame &frame [[buffer(9)]],
                                 constant Material &material [[buffer(10)]],
                                 texture2d<float> image [[texture(1)]],
                                 sampler image_sampler [[sampler(1)]])
{ return shade(in, frame, material, image, image_sampler); }

fragment float4 fragmentParticleMask(VertexOut in [[stage_in]],
                                     constant Frame &frame [[buffer(9)]],
                                     constant Material &material [[buffer(10)]],
                                     texture2d<float> image [[texture(1)]],
                                     sampler image_sampler [[sampler(1)]])
{
    float4 value = shade(in, frame, material, image, image_sampler);
    if (value.a < material.alpha_cutoff) discard_fragment();
    return value;
}
