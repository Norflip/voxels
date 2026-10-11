#version 460 core

#define QUANTISED_AO 1
#define TEXEL_SIZE 8.0

const vec3 NORMAL_LOOKUP[6] = {
    vec3( 1,  0,  0),
    vec3(-1,  0,  0),
    vec3( 0,  1,  0),
    vec3( 0, -1,  0),
    vec3( 0,  0,  1),
    vec3( 0,  0, -1)
};

const float dir_shadow_strength = 0.3;
uniform sampler2DArray u_atlas_sampler;

in vec2 v_uv;
in flat uint v_face;
in flat uint v_tex;
#if QUANTISED_AO == 1
in flat vec4 ao_corner_v2f;
#else
in float ao_v2f;
#endif

out vec4 frag_color;

float sample_ao() {
#if QUANTISED_AO == 1
    vec2 cell = min(floor(v_uv * TEXEL_SIZE), vec2(TEXEL_SIZE - 1.0));
    vec2 uv_q = (cell + 0.5) / TEXEL_SIZE;
    float ao_v0 = mix(ao_corner_v2f[0], ao_corner_v2f[1], uv_q.x);
    float ao_v1 = mix(ao_corner_v2f[3], ao_corner_v2f[2], uv_q.x);
    return mix(ao_v1, ao_v0, uv_q.y);
#else
    return ao_v2f;
#endif
}

void main() {
    const vec3 sun_dir = normalize(vec3(0.4, 1.0, 0.25));
    const vec3 normal = NORMAL_LOOKUP[v_face];

    vec3 uv = vec3(v_uv, v_tex);
    vec4 albedo = texture(u_atlas_sampler, uv);
    if(albedo.a < 0.1) discard;

    float ndots = (dot(normal, sun_dir) + 1.0) * 0.5;
    albedo.rgb *= (1.0 - dir_shadow_strength) + (dir_shadow_strength * ndots); // probably wrong? 

    float ao = sample_ao();
    frag_color = vec4(albedo.rgb * ao, 1.0);
}
