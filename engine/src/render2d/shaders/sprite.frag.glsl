#version 450

layout(location = 0) in vec2 in_uv;
layout(location = 1) in vec4 in_color;
layout(location = 0) out vec4 out_color;

// Descriptor set equals bind-group index and the binding numbers are unchanged.
// Images and samplers remain separate descriptors and combine only at sampling.
layout(set = 0, binding = 0) uniform texture2D image;
layout(set = 0, binding = 1) uniform sampler image_sampler;

void main() {
    vec4 texel = texture(sampler2D(image, image_sampler), in_uv);
    texel.rgb *= texel.a;
    out_color = texel * in_color;
}
