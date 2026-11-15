#version 450

// One pixel per layer.
layout(location = 0) out vec4 out_color;
layout(set = 0, binding = 0) uniform texture2DArray image;
layout(set = 0, binding = 1) uniform sampler image_sampler;

void main() {
    out_color = texture(sampler2DArray(image, image_sampler), vec3(0.5, 0.5, float(uint(gl_FragCoord.x))));
}
