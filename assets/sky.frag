#version 460 core

in vec3 v_view_dir;
out vec4 frag_color;

const vec3 HORIZON_COLOR = vec3(0.6, 0.75, 0.9);
const vec3 ZENITH_COLOR  = vec3(0.1, 0.3, 0.8);
   
vec3 sample_sky_color(vec3 dir) {
    float t = clamp(dir.y * 0.5 + 0.5, 0.0, 1.0);
    return mix(HORIZON_COLOR, ZENITH_COLOR, t);
}

void main() {
    vec3 dir = normalize(v_view_dir);
    vec3 col = sample_sky_color(dir);
    frag_color = vec4(col, 1.0);
}