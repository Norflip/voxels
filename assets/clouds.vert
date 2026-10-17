#version 460 core

#define CLOUD_SIZE 16.0
#define CLOUD_HEIGHT 8.0
#define CLOUD_ALTITUDE 128.0

const vec3 CUBE_VERTS[36] = vec3[36](
    // +Y
    vec3(-0.5, 0.5,-0.5), vec3(-0.5, 0.5, 0.5), vec3( 0.5, 0.5, 0.5),
    vec3(-0.5, 0.5,-0.5), vec3( 0.5, 0.5, 0.5), vec3( 0.5, 0.5,-0.5),
    // -Y
    vec3(-0.5,-0.5, 0.5), vec3(-0.5,-0.5,-0.5), vec3( 0.5,-0.5,-0.5),
    vec3(-0.5,-0.5, 0.5), vec3( 0.5,-0.5,-0.5), vec3( 0.5,-0.5, 0.5),
    // +Z
    vec3(-0.5,-0.5, 0.5), vec3( 0.5,-0.5, 0.5), vec3( 0.5, 0.5, 0.5),
    vec3(-0.5,-0.5, 0.5), vec3( 0.5, 0.5, 0.5), vec3(-0.5, 0.5, 0.5),
    // -Z
    vec3( 0.5,-0.5,-0.5), vec3(-0.5,-0.5,-0.5), vec3(-0.5, 0.5,-0.5),
    vec3( 0.5,-0.5,-0.5), vec3(-0.5, 0.5,-0.5), vec3( 0.5, 0.5,-0.5),
    // +X
    vec3( 0.5,-0.5, 0.5), vec3( 0.5,-0.5,-0.5), vec3( 0.5, 0.5,-0.5),
    vec3( 0.5,-0.5, 0.5), vec3( 0.5, 0.5,-0.5), vec3( 0.5, 0.5, 0.5),
    // -X
    vec3(-0.5,-0.5,-0.5), vec3(-0.5,-0.5, 0.5), vec3(-0.5, 0.5, 0.5),
    vec3(-0.5,-0.5,-0.5), vec3(-0.5, 0.5, 0.5), vec3(-0.5, 0.5,-0.5)
);

struct CloudInstance {
    vec3 pos;
    uint _pad;
};

layout(std430, binding = 0) readonly buffer CloudInstanceBuffer {
    CloudInstance instances[];
};

layout(location = 0) uniform mat4 u_view_proj;

/*
out flat int v_face;
out float v_height_01;
out vec3 v_world_pos;
*/

out flat int v_face;
out vec3 v_local;
out vec3 v_world_pos;


//invariant gl_Position;

void main() {
    const int face = gl_VertexID / 6;
    vec3 local_pos = CUBE_VERTS[gl_VertexID] + 0.5;
    vec3 world = instances[gl_InstanceID].pos + local_pos * vec3(CLOUD_SIZE, CLOUD_HEIGHT, CLOUD_SIZE);
    v_local = local_pos;
    v_face = face;
    v_world_pos = world;
    gl_Position = u_view_proj * vec4(world, 1.0);
}