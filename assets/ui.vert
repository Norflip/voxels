#version 460 core

struct Quad {
    vec4 pos_rect; // x0, y0, x1, y1
    vec4 uv_rect;  // u0, v0, u1, v1
    uint color;
    uint layer; 
    uint _pad0[2];
};

layout(std430, binding = 0) readonly buffer QuadBuffer {
    Quad quads[];
};

uniform mat4 u_proj;

out vec2 v_uv;
out vec4 v_color;
#ifdef SAMPLE_TEXARR
out flat int v_layer;
#endif

vec4 unpack_u32(uint color) {
    float r = float((color >> 24) & 0xFFu) / 255.0;
    float g = float((color >> 16) & 0xFFu) / 255.0;
    float b = float((color >> 8) & 0xFFu) / 255.0;
    float a = float(color & 0xFFu) / 255.0;
    return vec4(r, g, b, a);
}

void main() {
    int quad_id = gl_VertexID / 6;
    int vert_id = gl_VertexID % 6;

    Quad q = quads[quad_id];

    const int x_sel = (0x26 >> vert_id) & 1;
    const int y_sel = (0x2C >> vert_id) & 1;
    float x = (x_sel == 0) ? q.pos_rect.x : q.pos_rect.z;
    float y = (y_sel == 0) ? q.pos_rect.y : q.pos_rect.w;
    float u = (x_sel == 0) ? q.uv_rect.x  : q.uv_rect.z;
    float v = (y_sel == 0) ? q.uv_rect.y  : q.uv_rect.w;

    gl_Position = u_proj * vec4(x, y, 0.0, 1.0);
    v_uv = vec2(u, v);

    v_color = unpack_u32(q.color);

#ifdef SAMPLE_TEXARR
    v_layer = int(q.layer); 
#endif
}