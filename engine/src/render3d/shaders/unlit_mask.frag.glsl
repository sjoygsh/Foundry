#version 450
layout(location = 0) in vec2 in_uv;
layout(location = 1) in vec4 in_color;
layout(location = 0) out vec4 out_color;
layout(set = 2, binding = 0, std140) uniform Material { layout(offset=0) vec4 base_color; layout(offset=16) float alpha_cutoff; } material;
layout(set = 2, binding = 1) uniform texture2D image;
layout(set = 2, binding = 2) uniform sampler image_sampler;
void main() {
    vec4 value = texture(sampler2D(image, image_sampler), in_uv) * in_color * material.base_color;
    if (value.a < material.alpha_cutoff) discard;
    value.rgb *= value.a; out_color = value;
}
