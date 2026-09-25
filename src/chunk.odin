package main
import "base:runtime"
import "core:math/rand"
import "base:intrinsics"

Block :: enum u8 {
    Air = 0,
    Stone,
    Mantle,
    Dirt,
}

block_is_solid :: #force_inline proc(b : Block) -> bool {
    return b != Block.Air
}

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
    loc :  u32,
    tex :  u32,
    ao :   u32,
    _pad : u32,
}

Chunk :: struct {
    pos :             [3]i32,
    blocks :          [^]Block,
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
    c.handle = Mesh_Handle {
        offset = 0,
        count  = 0,
    }
}

chunk_destroy :: proc(c : ^Chunk) {
    if c.blocks != nil {
        free(rawptr(c.blocks), c.block_allocator)
        c.blocks = nil
    }
    c.num_filled = 0
}

chunk_set_block :: proc(chunk : ^Chunk, x, y, z : i32, block : Block) -> bool {
    if !in_padded_bounds(x, y, z) do return false

    if chunk.blocks == nil {
        if block == .Air do return false
        chunk.blocks = make([^]Block, C_VOL_PAD, chunk.block_allocator)
        if chunk.blocks == nil do panic("failed to allocate memory for chunk blocks")
        chunk.num_filled = 0
    }

    index := index_pos(x, y, z)
    old_block := chunk.blocks[index]
    if old_block == block do return false

    if in_inner_bounds(x, y, z) {
        if old_block != .Air && block == .Air {
            chunk.num_filled -= 1
        } else if old_block == .Air && block != .Air {
            chunk.num_filled += 1
        }
    }

    chunk.blocks[index] = block
    return true
}

chunk_get_block :: proc(chunk : ^Chunk, x, y, z : i32) -> Block {
    if chunk.blocks == nil do return .Air
    if !in_padded_bounds(x, y, z) do return .Air
    index := index_pos(x, y, z)
    return chunk.blocks[index]
}

@(require_results)
chunk_mark_mesh_dirty :: proc "contextless" (chunk : ^Chunk) -> bool {
    return !bool(intrinsics.atomic_exchange(&chunk.dirty, true))
}

chunk_clear_mesh_dirty :: proc "contextless" (chunk : ^Chunk) {
    intrinsics.atomic_store(&chunk.dirty, false)
}

chunk_generate_faces :: proc(chunk : ^Chunk, faces_out : []Chunk_Face) -> u32 {
    if chunk.num_filled == 0 do return 0
    count : u32 = 0

    for z in 0 ..< i32(C_SIZE) {
        for y in 0 ..< i32(C_SIZE) {
            for x in 0 ..< i32(C_SIZE) {
                pos := ivec3{x, y, z}
                block := chunk_get_block(chunk, pos.x, pos.y, pos.z)
                if block == .Air do continue
                for face in 0 ..< 6 {
                    npos := pos + CARDINAL[face]
                    if !is_solid(chunk, npos) {
                        ao := get_face_ao_packed(chunk, pos.x, pos.y, pos.z, face)
                        faces_out[count] = make_face(pos, face, u32(block) - 1, ao)
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
get_face_ao_packed :: proc(chunk : ^Chunk, x, y, z : i32, face : int) -> u32 {
    @(rodata)
    @(static)
    g_face_uv := [6][2]ivec3 {
        {{0, 0, 1}, {0, 1, 0}}, // +X
        {{0, 0, -1}, {0, 1, 0}}, // -X
        {{1, 0, 0}, {0, 0, 1}}, // +Y
        {{0, 0, 1}, {1, 0, 0}}, // -Y
        {{-1, 0, 0}, {0, 1, 0}}, // +Z
        {{1, 0, 0}, {0, 1, 0}}, // -Z
    }

    ao_value :: proc(side1, side2, corner : bool) -> u32 {
        if side1 && side2 do return 0
        return 3 - u32(u8(side1) + u8(side2) + u8(corner))
    }

    s := ivec3{x, y, z} + CARDINAL[face]
    u := g_face_uv[face][0]
    v := g_face_uv[face][1]

    u_neg := is_solid(chunk, s - u)
    u_pos := is_solid(chunk, s + u)
    v_neg := is_solid(chunk, s - v)
    v_pos := is_solid(chunk, s + v)

    ao := [4]u32{ao_value(u_neg, v_neg, is_solid(chunk, s - u - v)), ao_value(u_pos, v_neg, is_solid(chunk, s + u - v)), ao_value(u_pos, v_pos, is_solid(chunk, s + u + v)), ao_value(u_neg, v_pos, is_solid(chunk, s - u + v))}

    packed_ao := ao[0] | ao[1] << 2 | ao[2] << 4 | ao[3] << 6
    if ao[1] + ao[3] < ao[0] + ao[2] do packed_ao |= 1 << 8
    return packed_ao
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
is_solid :: #force_inline proc(chunk : ^Chunk, pos : ivec3) -> bool {
    return block_is_solid(chunk_get_block(chunk, pos.x, pos.y, pos.z))
}

@(private = "file")
make_face :: proc(pos : ivec3, #any_int face : u32, tex : u32, ao : u32) -> Chunk_Face {
    x, y, z : u32 = u32(pos.x) & 0x1F, u32(pos.y) & 0x1F, u32(pos.z) & 0x1F
    loc := (x & 0x1F) | ((y & 0x1F) << 5) | ((z & 0x1F) << 10) | ((face & 0x7) << 15)
    return Chunk_Face{loc = loc, tex = tex, ao = ao, _pad = 0}
}
