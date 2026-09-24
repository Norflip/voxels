#version 460 core

layout(binding = 0) uniform sampler2D u_scene;
out vec4 out_color;

vec3 linear_to_srgb(vec3 c) {
    return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c));
}

void main() {
    vec3 scene = texelFetch(u_scene, ivec2(gl_FragCoord.xy), 0).rgb;
    vec3 ldr = clamp(scene, 0.0, 1.0);
    out_color = vec4(linear_to_srgb(ldr), 1.0);
}
