#version 460 core

layout(location = 0) uniform mat4 u_vp;

struct vertex {
    vec3 pos;
    uint col;
};

layout(std430, binding = 0) buffer VertexBuffer {
    vertex vertices[];
};

out vec4 v_color;

vec4 unpack_u32(uint color) {
    float r = float((color >> 24) & 0xFFu) / 255.0;
    float g = float((color >> 16) & 0xFFu) / 255.0;
    float b = float((color >> 8) & 0xFFu) / 255.0;
    float a = float(color & 0xFFu) / 255.0;
    return vec4(r, g, b, a);
}

void main() {
    uint index = uint(gl_VertexID);
    vec3 position = vertices[index].pos;
    uint color_packed = vertices[index].col;
    v_color = unpack_u32(color_packed);
    gl_Position = u_vp * vec4(position.xyz, 1.0);
}