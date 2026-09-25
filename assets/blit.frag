#version 460 core

layout(binding = 0) uniform sampler2D u_scene;
out vec4 out_color;

//https://www.shadertoy.com/view/lsKSWR
vec3 apply_vignette(vec3 color, vec2 uv) {
    const float intensity = 15.0;
    const float vpow = 0.15;

    vec2 inv_uv = uv * (1.0 - uv.yx);
    float vig = inv_uv.x * inv_uv.y * intensity;
    vig = pow(vig, vpow);
    color *= vig;
    return color;
}

vec3 linear_to_srgb(vec3 c) {
    return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c));
}

void main() {
    vec3 scene = texelFetch(u_scene, ivec2(gl_FragCoord.xy), 0).rgb;
    vec3 ldr = clamp(scene, 0.0, 1.0);

    // we could pass the uv from the vert shader instead
    //ldr = apply_vignette(ldr, gl_FragCoord.xy / vec2(textureSize(u_scene, 0)));
    out_color = vec4(linear_to_srgb(ldr), 1.0);
}
