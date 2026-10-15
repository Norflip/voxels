#version 460 core

layout(location = 2) uniform mat3 u_sun_orbit; // orbit
layout(location = 3) uniform mat3 u_sun_to_local; // transpose(orbit * spin)

in vec3 v_view_dir;
out vec4 frag_color;

const vec3 HORIZON_COLOR = vec3(0.6, 0.75, 0.9);
const vec3 ZENITH_COLOR  = vec3(0.1, 0.3, 0.8);
const vec3 SUN_COLOR = vec3(1.0, 0.92, 0.66);
const vec3 SUN_RADIUS = vec3(9.0);

vec3 sample_sky_color(vec3 dir) {
    float t = clamp(dir.y * 0.5 + 0.5, 0.0, 1.0);
    return mix(HORIZON_COLOR, ZENITH_COLOR, t);
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

void main() {
    vec3 dir = normalize(v_view_dir);
    vec3 col = sample_sky_color(dir);


    vec3 sun_dir = normalize(u_sun_orbit * vec3(0.0, 0.0, 1.0));
    vec3 ro_local = u_sun_to_local * (-sun_dir * 100.0);
    vec3 rd_local = u_sun_to_local * dir;

    vec2 t = intersect_box(ro_local, rd_local, vec3(SUN_RADIUS));
    col = mix(col, SUN_COLOR, float(t.x <= t.y && t.y > 0.0));

    frag_color = vec4(col, 1.0);
}