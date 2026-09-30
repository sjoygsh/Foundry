#version 450
#ifdef MASK
layout(location=0) in vec2 in_uv;
layout(location=1) in vec4 in_color;
layout(set=2,binding=0,std140) uniform Material { layout(offset=0) vec4 base_color; layout(offset=16) float alpha_cutoff; } material;
layout(set=2,binding=1) uniform texture2D image;
layout(set=2,binding=2) uniform sampler image_sampler;
#endif
void main() {
#ifdef MASK
    float alpha=texture(sampler2D(image,image_sampler),in_uv).a*in_color.a*material.base_color.a;
    if (alpha < material.alpha_cutoff) discard;
#endif
}
