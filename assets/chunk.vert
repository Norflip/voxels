#version 460 core

#define QUANTISED_AO 1

const ivec3 VOXEL_CORNERS[8] = ivec3[8](
    ivec3(0, 0, 0), ivec3(1, 0, 0), ivec3(1, 0, 1), ivec3(0, 0, 1), 
    ivec3(0, 1, 0), ivec3(1, 1, 0), ivec3(1, 1, 1), ivec3(0, 1, 1)
);

const uint CUBE_FACE_LOOKUP[24] = uint[24](
    1u, 2u, 6u, 5u, // r 
    3u, 0u, 4u, 7u, // l 
    4u, 5u, 6u, 7u, // u
    0u, 3u, 2u, 1u, // d 
    2u, 3u, 7u, 6u, // f
    0u, 1u, 5u, 4u  // b
);

const int TRIS_ORDER [6] = {3, 2, 1, 3, 1, 0}; 
const int FLIPPED_TRIS_ORDER [6] = {2, 1, 0, 2, 0, 3};
const vec2 CORNER_UV [4] = vec2[4] (vec2(0,1), vec2(1,1), vec2(1,0), vec2(0,0));

//const float AO_VALUES[4] = float[](0.30, 0.60, 0.80, 1.0); 
const float AO_VALUES[4] = float[](0.55, 0.70, 0.85, 1.0); 

struct FaceQuad {
    uint loc;
    uint tex;
    uint ao;
    uint _pad;
};

struct ChunkData {
    int x, y, z;
    uint lod;
};

layout(std430, binding = 0) buffer FaceQuadBuffer {
    FaceQuad quads[];
};

layout(std430, binding = 1) buffer ChunkDataBuffer {
    ChunkData per_chunk[];
};

layout(location = 0) uniform mat4 u_vp;

out vec2 v_uv;
out flat uint v_face;
out flat uint v_tex;
out flat uint v_atlas_layer;
#if QUANTISED_AO == 1
out flat vec4 ao_corner_v2f;
#else
out float ao_v2f;
#endif

ivec3 get_quad_pos (FaceQuad q, out uint face) {
    uint x = (q.loc & 0x1Fu);
    uint y = ((q.loc >> 5) & 0x1Fu);
    uint z = ((q.loc >> 10) & 0x1Fu);
    face = (q.loc >> 15) & 0x7u;
    return ivec3(x, y, z);
}

ivec3 get_voxel_pos(uint face, uint corner_index) {
    uint c_index = CUBE_FACE_LOOKUP[(face * 4) + corner_index];
    return VOXEL_CORNERS[c_index];
}

void main () {
    FaceQuad q = quads[gl_VertexID / 6];
    ChunkData chunk_data = per_chunk[gl_BaseInstance];
    ivec3 chunk_pos = ivec3(chunk_data.x, chunk_data.y, chunk_data.z);

    uint face;
    const ivec3 quad_pos = get_quad_pos(q, face);
    const int corner_index = (q.ao & (1u << 8)) != 0 ? FLIPPED_TRIS_ORDER[gl_VertexID % 6] : TRIS_ORDER[gl_VertexID % 6];
    const ivec3 voxel_pos = get_voxel_pos(face, corner_index);

    const ivec3 wpos = voxel_pos + quad_pos + chunk_pos;
    gl_Position = u_vp * vec4(vec3(wpos), 1.0);

    v_face = face;
    v_uv = CORNER_UV[corner_index];
    v_tex = q.tex;

#if QUANTISED_AO == 1
    for (int i = 0; i < 4; i++) {
        ao_corner_v2f[i] = AO_VALUES[(q.ao >> (i * 2)) & 0x3];
    }
#else
    ao_v2f = AO_VALUES[(q.ao >> (corner_index * 2)) & 0x3];
#endif
}