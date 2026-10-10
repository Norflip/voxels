#version 460 core
layout(location = 0) uniform mat4 u_inv_proj;
layout(location = 1) uniform mat4 u_world_to_camera;

out vec3 v_view_dir;

void main() {
    vec2 pos = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2) * 2.0 - 1.0;
    vec4 clip = vec4(pos, 1.0, 1.0);

    mat3 inv_view_rot = transpose(mat3(u_world_to_camera));
    vec3 view_ray = (u_inv_proj * clip).xyz;
    v_view_dir = inv_view_rot * view_ray;

    gl_Position = clip;
}