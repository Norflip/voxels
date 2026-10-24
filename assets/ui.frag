#version 460 core

in vec2 v_uv;
in vec4 v_color;

#ifdef SAMPLE_TEXARR
in flat int v_layer;
layout(binding = 0) uniform sampler2DArray u_tex;
#else
layout(binding = 0) uniform sampler2D u_tex;
#endif

out vec4 frag_color;

vec3 linear_to_srgb(vec3 c) {
    return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c));
}

void main() {
    vec4 texel;
#ifdef SAMPLE_TEXARR
    texel = texture(u_tex, vec3(v_uv, v_layer));
#else
    texel = texture(u_tex, v_uv);
#endif
   // float alpha = max(texel.a, v_color.a);
   // vec3 color = mix(texel.rgb, v_color.rgb, v_color.a);
    frag_color = vec4(linear_to_srgb(texel.rgb) * v_color.rgb, texel.a * v_color.a);
}