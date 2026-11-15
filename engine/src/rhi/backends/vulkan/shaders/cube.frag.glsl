#version 450

// One pixel per direction: the six faces in the RHI's order, then the edge between +X and +Z.
layout(location = 0) out vec4 out_color;
layout(set = 0, binding = 0) uniform textureCube image;
layout(set = 0, binding = 1) uniform sampler image_sampler;

void main() {
    const vec3 directions[7] = vec3[7](vec3(1, 0, 0), vec3(-1, 0, 0), vec3(0, 1, 0), vec3(0, -1, 0),
                                       vec3(0, 0, 1), vec3(0, 0, -1), vec3(1, 0, 1));
    out_color = texture(samplerCube(image, image_sampler), directions[uint(gl_FragCoord.x)]);
}
