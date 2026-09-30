// M22's fixed HDR -> surface pass (light.md §7.4), Khronos PBR Neutral.
#include <metal_stdlib>
using namespace metal;
struct ToneOut { float4 position [[position]]; float2 uv; };
vertex ToneOut toneVertex(uint id [[vertex_id]]) {
    float2 xy = float2(float((id << 1) & 2), float(id & 2));
    ToneOut out;
    out.position = float4(xy * 2.0 - 1.0, 0, 1);
    out.uv = float2(xy.x, 1.0 - xy.y);
    return out;
}
static float3 neutral(float3 color) {
    float minimum = min(color.r, min(color.g, color.b));
    color -= minimum < 0.08 ? minimum - 6.25 * minimum * minimum : 0.04;
    float peak = max(color.r, max(color.g, color.b));
    if (peak < 0.76) return color;
    float compressed = 1.0 - 0.24 * 0.24 / (peak - 0.52);
    float blend = 1.0 - 1.0 / (0.15 * (peak - compressed) + 1.0);
    return mix(color * (compressed / peak), float3(compressed), blend);
}
fragment float4 toneFragment(ToneOut in [[stage_in]],
                             texture2d<float> hdr [[texture(0)]],
                             sampler hdr_sampler [[sampler(0)]]) {
    float4 value = hdr.sample(hdr_sampler, in.uv);
    return float4(neutral(value.rgb), value.a);
}
