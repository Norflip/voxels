package main
import "base:runtime"
import "core:math/rand"

C_SIZE :: 32
C_SHIFT :: 5

C_VOLUME :: (C_SIZE * C_SIZE * C_SIZE)
C_SIZE_PAD :: C_SIZE + 2
C_VOL_PAD :: C_SIZE_PAD * C_SIZE_PAD * C_SIZE_PAD

@(rodata)
CARDINAL := [6]ivec3 {
    ivec3{1, 0, 0}, // Right
    ivec3{-1, 0, 0}, // Left
    ivec3{0, 1, 0}, // Top
    ivec3{0, -1, 0}, // Bottom
    ivec3{0, 0, 1}, // Back
    ivec3{0, 0, -1}, // Front
}

Chunk_Face :: struct {
    loc :   u32,
    tex :   u32,
    _pad0 : u32,
    _pad1 : u32,
}

Chunk :: struct {
    pos :             [3]i32,
    blocks :          [^]u8,
    block_allocator : runtime.Allocator,
    num_filled :      u32,
    dirty :           b32,
    handle :          Mesh_Handle,
}

chunk_init :: proc(c : ^Chunk, pos : [3]i32, allocator : runtime.Allocator = context.allocator) {
    c.pos = pos
    c.blocks = nil
    c.block_allocator = allocator
    c.num_filled = 0
    c.dirty = true
    c.handle = Mesh_Handle{offset = 0, count = 0}
}

chunk_destroy :: proc(c : ^Chunk) {
    if c.blocks != nil {
        free(rawptr(c.blocks), c.block_allocator)
        c.blocks = nil
    }
    c.num_filled = 0
}

chunk_set_block :: proc(chunk : ^Chunk, x, y, z : i32, block : u8) -> bool {
    if !in_padded_bounds(x, y, z) do return false

    if chunk.blocks == nil {
        if block == 0 do return false
        chunk.blocks = make([^]u8, C_VOL_PAD, chunk.block_allocator)
        if chunk.blocks == nil {
            panic("failed to allocate memory for chunk blocks")
        }
        chunk.num_filled = 0
    }

    index := index_pos(x, y, z)
    old_block := chunk.blocks[index]
    if old_block == block do return false

    if in_inner_bounds(x, y, z) {
        if old_block != 0 && block == 0 {
            chunk.num_filled -= 1
        } else if old_block == 0 && block != 0 {
            chunk.num_filled += 1
        }
    }

    chunk.blocks[index] = block
    return true
}

chunk_get_block :: proc(chunk : ^Chunk, x, y, z : i32) -> u8 {
    if chunk.blocks == nil do return 0
    if !in_padded_bounds(x, y, z) do return 0
    index := index_pos(x, y, z)
    return chunk.blocks[index]
}

chunk_generate_faces :: proc(chunk : ^Chunk, faces_out : []Chunk_Face) -> u32 {
    if chunk.num_filled == 0 || !chunk.dirty do return 0
    count : u32 = 0

    for z in 0 ..< i32(C_SIZE) {
        for y in 0 ..< i32(C_SIZE) {
            for x in 0 ..< i32(C_SIZE) {
                pos := ivec3{x, y, z}
                block := chunk_get_block(chunk, pos.x, pos.y, pos.z)
                if block == 0 do continue
                for face in 0 ..< 6 {
                    npos := pos + CARDINAL[face]
                    if !block_is_solid(chunk, npos.x, npos.y, npos.z) {
                        faces_out[count] = make_face(pos, face, 0)
                        count += 1
                    }
                }
            }
        }
    }

    chunk.dirty = false
    return count
}

@(private = "file")
index_pos :: #force_inline proc(x, y, z : i32) -> i32 {
    return (y + 1) + ((z + 1) * C_SIZE_PAD) + ((x + 1) * C_SIZE_PAD * C_SIZE_PAD)
}

@(private = "file")
in_padded_bounds :: #force_inline proc(x, y, z : i32) -> bool {
    return x >= -1 && x < C_SIZE + 1 && y >= -1 && y < C_SIZE + 1 && z >= -1 && z < C_SIZE + 1
}

@(private = "file")
in_inner_bounds :: #force_inline proc(x, y, z : i32) -> bool {
    return x >= 0 && x < C_SIZE && y >= 0 && y < C_SIZE && z >= 0 && z < C_SIZE
}

@(private = "file")
block_is_solid :: proc(chunk : ^Chunk, x, y, z : i32) -> bool {
    return chunk_get_block(chunk, x, y, z) != 0
}

@(private = "file")
make_face :: proc(pos : ivec3, #any_int face : u32, tex : u32) -> Chunk_Face {
    x, y, z : u32 = u32(pos.x) & 0x1F, u32(pos.y) & 0x1F, u32(pos.z) & 0x1F
    loc := (x & 0x1F) | ((y & 0x1F) << 5) | ((z & 0x1F) << 10) | ((face & 0x7) << 15)
    return Chunk_Face{loc = loc, tex = tex, _pad0 = 0, _pad1 = 0}
}
