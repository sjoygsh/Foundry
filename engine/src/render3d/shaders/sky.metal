// M41's sky pass (environment.md §9): the frame's environment drawn behind everything opaque.
#include <metal_stdlib>
using namespace metal;
struct PackedLight { float4 position_kind, direction_range, color_intensity, cone_shadow; };
struct Frame {
    float4x4 view_projection; float4 camera_exposure; float4 ambient; uint4 counts;
    float4 camera_forward; float4 shadow_splits; float4 shadow_parameters;
    float4 shadow_tiles[32]; float4 shadow_tile_parameters[32]; float4x4 shadow_matrices[32];
    PackedLight lights[16];
    float4 environment_sh[9]; float4 environment;
};
// The inverse view-projection, renderer.zig's SkyConstants.
struct Constants { float4x4 inverse_view_projection; };
static_assert(sizeof(Frame)==4416, "Frame matches lighting.zig");
static_assert(sizeof(Constants)==64, "Constants matches renderer.zig");
// Two points on each corner's view ray, unprojected and not yet divided: a ray is linear in
// the screen, so they interpolate exactly. Two depths rather than the camera's position keep an
// orthographic camera's parallel rays right.
struct SkyOut { float4 position [[position]]; float4 near_point; float4 mid_point; };
vertex SkyOut skyVertex(uint id [[vertex_id]], constant Constants &constants [[buffer(8)]]) {
    float2 xy = float2(float((id << 1) & 2), float(id & 2)) * 2.0 - 1.0;
    SkyOut out;
    // Reversed-Z's far plane: the depth test colours only what nothing opaque covered.
    out.position = float4(xy, 0, 1);
    out.near_point = constants.inverse_view_projection * float4(xy, 1, 1);
    out.mid_point = constants.inverse_view_projection * float4(xy, 0.5, 1);
    return out;
}
fragment float4 skyFragment(SkyOut in [[stage_in]], constant Frame &frame [[buffer(9)]],
    texturecube<float> environment_image [[texture(2)]], sampler environment_sampler [[sampler(2)]]) {
    float3 d = normalize(in.mid_point.xyz / in.mid_point.w - in.near_point.xyz / in.near_point.w);
    // Turned back by the yaw, as lit.metal turns a reflection (lighting.environmentDirection).
    float c = frame.environment.z, s = frame.environment.w;
    float3 r = float3(c * d.x - s * d.z, d.y, s * d.x + c * d.z);
    float3 radiance = environment_image.sample(environment_sampler, r, level(0)).rgb * frame.environment.y;
    return float4(radiance * frame.camera_exposure.w, 1);
}
