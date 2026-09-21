#version 460 core

const vec3 NORMAL_LOOKUP[6] = {
    vec3( 1,  0,  0),
    vec3(-1,  0,  0),
    vec3( 0,  1,  0),
    vec3( 0, -1,  0),
    vec3( 0,  0,  1),
    vec3( 0,  0, -1)
};

layout(location = 2) uniform mat3 u_sun_orbit;

in vec2 v_uv;
in flat uint v_face;
in flat uint v_tex;

out vec4 frag_color;

const float dir_shadow_strength = 0.8;

void main() {
    const vec3 sun_dir = normalize(vec3(1.0, 1.0, 1.0));
    const vec3 normal = NORMAL_LOOKUP[v_face];

    //vec3 uv = vec3(v_uv, v_tex);
    vec4 color = vec4(v_uv, 0, 1);
    if(color.a < 0.1) discard;

    float ndots = (dot(normal, sun_dir) + 1.0) * 0.5;
    color.rgb *= (1.0 - dir_shadow_strength) + (dir_shadow_strength * ndots);
    frag_color = color;
}
