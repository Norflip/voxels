#version 460 core

in vec2 v_uv;
in vec4 v_color;

uniform sampler2D u_tex;

out vec4 frag_color;

void main() {
    vec4 texel = texture(u_tex, v_uv);
    // float alpha = max(texel.a, v_color.a);
    // vec3 color = mix(texel.rgb, v_color.rgb, v_color.a);
    frag_color = texel * v_color;
}