#version 460 core

const vec3 FACE_NORMAL[6] = vec3[6](
    vec3(0.0, 1.0, 0.0), vec3(0.0, -1.0, 0.0),
    vec3(0.0, 0.0, 1.0), vec3(0.0, 0.0, -1.0),
    vec3(1.0, 0.0, 0.0), vec3(-1.0, 0.0, 0.0)
);

layout(location = 1) uniform vec3 u_eye;
layout(location = 2) uniform float u_render_distance;
layout(location = 3) uniform float u_alpha;

layout(location = 4) uniform mat3 u_sun_orbit; // orbit
layout(location = 5) uniform mat3 u_sun_to_local; // transpose(orbit * spin)

const vec3 SUN_COLOR = vec3(1.0, 0.92, 0.66);
const vec3 SUN_RADIUS = vec3(9.0);
const float SUN_STRENGTH = 0.4;
const vec3 AMBIENT = vec3(0.6, 0.63, 0.7);

in flat int v_face;
in vec3 v_local;
in vec3 v_world_pos;

out vec4 frag_color;

float distance_fade(float dist_01) {
    const float FADE_START = 0.5;
    const float FADE_END = 1.0;
    return 1.0 - smoothstep(FADE_START, FADE_END, dist_01);
}

vec2 intersect_box(vec3 ro, vec3 rd, vec3 half_extent) {
    vec3 inv  = 1.0 / rd;
    vec3 t1   = (-half_extent - ro) * inv;
    vec3 t2   = ( half_extent - ro) * inv;
    vec3 tmin = min(t1, t2);
    vec3 tmax = max(t1, t2);
    float tn  = max(max(tmin.x, tmin.y), tmin.z);
    float tf  = min(min(tmax.x, tmax.y), tmax.z);
    return vec2(tn, tf);
}

float sun_cube_coverage(vec3 sun_dir, vec3 view_dir) {
    vec3 ro_local = u_sun_to_local * (-sun_dir * 100.0);
    vec3 rd_local = u_sun_to_local * view_dir;
    vec2 t = intersect_box(ro_local, rd_local, SUN_RADIUS);
    return float(t.x <= t.y && t.y > 0.0);
}

vec3 cloud_lighting(vec3 sun_dir) {
    float wrap = dot(FACE_NORMAL[v_face], sun_dir) * 0.5 + 0.5;
    vec3 lit = AMBIENT + SUN_COLOR * wrap * SUN_STRENGTH;

    float height_shade = mix(0.7, 1.0, v_local.y);
    vec3 height_tint = mix(vec3(0.8, 0.85, 1.0), vec3(1.0), v_local.y);
    return lit * height_shade * height_tint;
}

void main() {
    float dist_01 = length(u_eye - v_world_pos) / u_render_distance;
    float alpha = u_alpha * distance_fade(dist_01);
    if (alpha < 0.001) discard;

    vec3 sun_dir = normalize(u_sun_orbit[2]); // orbit * (0, 0, 1)
    vec3 view_dir = normalize(v_world_pos - u_eye);

    vec3 color = cloud_lighting(sun_dir);

    float cos_sun = max(dot(view_dir, sun_dir), 0.0);
    float halo = pow(cos_sun, 8.0);
    float lining = pow(cos_sun, 24.0);
    color += SUN_COLOR * (0.25 * halo + 0.6 * lining);

    // The sun cube punches a window in its own shape
    float sun_window = sun_cube_coverage(sun_dir, view_dir);
    alpha *= 1.0 - (0.25 * lining + 0.5 * sun_window);

    frag_color = vec4(color, alpha);
}