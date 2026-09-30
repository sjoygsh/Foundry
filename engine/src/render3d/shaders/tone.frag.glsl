#version 450
layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_color;
layout(set = 0, binding = 0) uniform texture2D hdr;
layout(set = 0, binding = 1) uniform sampler hdr_sampler;
vec3 neutral(vec3 color) {
    float minimum = min(color.r, min(color.g, color.b));
    color -= minimum < 0.08 ? minimum - 6.25 * minimum * minimum : 0.04;
    float peak = max(color.r, max(color.g, color.b));
    if (peak < 0.76) return color;
    float compressed = 1.0 - 0.24 * 0.24 / (peak - 0.52);
    float blend = 1.0 - 1.0 / (0.15 * (peak - compressed) + 1.0);
    return mix(color * (compressed / peak), vec3(compressed), blend);
}
void main() {
    vec4 value = texture(sampler2D(hdr, hdr_sampler), in_uv);
    out_color = vec4(neutral(value.rgb), value.a);
}
