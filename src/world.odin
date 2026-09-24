package main
import "core:container/queue"
import "core:fmt"
import "core:math/rand"
import "core:mem"
import "core:sync"
import gl "vendor:OpenGL"

COL_HEIGHT :: 16
MAX_FACES :: C_VOLUME * 3 // * 3 for opaque, * 6 if transparent?
RENDER_CAP :: 4096

NEIGHBOUR_DIRS :: [4]ivec2{{-1, 0}, {1, 0}, {0, -1}, {0, 1}}

@(private = "file")
Per_Chunk_Data :: struct {
    x, y, z :  i32,
    _padding : u32,
}

@(private = "file")
Mesh_Result :: struct {
    loc :    ivec3,
    handle : Mesh_Handle,
}

Column_State :: enum u8 {
    Allocated,
    Generated,
    Mesh_Queued,
}

World :: struct {
    chunks :          map[ivec3]^Chunk,
    chunks_mu :       sync.RW_Mutex,
    columns :         map[ivec2]Column_State,
    columns_mu :      sync.Mutex,
    gen_thread :      Worker(ivec2),
    mesh_thread :     Worker(ivec3),
    exiting :         b32,
    mesh_results :    queue.Queue(Mesh_Result),
    mesh_results_mu : sync.Mutex,

    // rendering
    render_count :    u32,
    render_cap :      u32,
    cmds :            [^]gl.DrawArraysIndirectCommand,
    data :            [^]Per_Chunk_Data,
    cmd_buffer :      u32,
    data_buffer :     u32,
    vertex_pool :     Vertex_Pool(Chunk_Face),
    chunk_program :   u32,
    vp_loc :          i32,
}

world_init :: proc(w : ^World) {
    ok : bool
    w.chunk_program, ok = load_program("chunk", "../assets/chunk.vert", "../assets/chunk.frag")
    if !ok {
        fmt.printf("Failed to load chunk program\n")
        return
    }

    w.vp_loc = gl.GetUniformLocation(w.chunk_program, "u_vp")
    w.chunks = make(map[ivec3]^Chunk, context.allocator)
    w.columns = make(map[ivec2]Column_State, context.allocator)
    w.exiting = false
    w.render_cap = RENDER_CAP
    queue.init(&w.mesh_results, allocator = context.allocator)

    storage_flags : u32 = gl.MAP_WRITE_BIT | gl.MAP_PERSISTENT_BIT
    mapping_flags : u32 = gl.MAP_WRITE_BIT | gl.MAP_PERSISTENT_BIT | gl.MAP_FLUSH_EXPLICIT_BIT
    w.cmds = create_mapped_buffer(&w.cmd_buffer, w.render_cap, storage_flags, mapping_flags, "Chunk_Batch_cmd_buf", gl.DrawArraysIndirectCommand)
    w.data = create_mapped_buffer(&w.data_buffer, w.render_cap, storage_flags, mapping_flags, "Chunk_Batch_data_buf", Per_Chunk_Data)
    //vertex_arena_init(&w.vertex_arena, 16 * mem.Megabyte)
    vertex_pool_init(&w.vertex_pool, 16 * mem.Megabyte, 256, context.allocator)

    MESH_SCRATCH_SIZE :: MAX_FACES * size_of(Chunk_Face)
    worker_init(&w.gen_thread, gen_thread_proc, w, 0)
    worker_init(&w.mesh_thread, mesh_thread_proc, w, MESH_SCRATCH_SIZE)

    load_init_chunks(w)
    fmt.printf("world initialized\n")
}

@(private = "file")
load_init_chunks :: proc(w : ^World) {
    sync.rw_mutex_guard(&w.chunks_mu)
    sync.mutex_guard(&w.columns_mu)
    for x := 0; x <= 1; x += 1 {
        for z := 0; z <= 1; z += 1 {
            col := ivec2{i32(x), i32(z)}
            if _, ok := w.columns[col]; ok {
                continue
            }

            for i := COL_HEIGHT - 1; i >= 0; i -= 1 {
                pos := ivec3{col.x, i32(i), col.y}
                chunk := new(Chunk, context.allocator)
                chunk_init(chunk, pos, context.allocator)
                w.chunks[pos] = chunk
            }
            w.columns[col] = .Allocated
            worker_push(&w.gen_thread, col)
        }
    }
}

world_set_block :: proc(w : ^World, pos : ivec3, block : u8) -> bool {
    sync.rw_mutex_shared_guard(&w.chunks_mu)
    chunk_pos, local_pos := loc_world_chunk_local(pos)
    chunk := get_chunk_unsafe(w, chunk_pos)
    if chunk == nil do return false
    return set_block_internal(w, chunk, local_pos.x, local_pos.y, local_pos.z, block)
}

world_get_block :: proc(w : ^World, pos : ivec3) -> u8 {
    sync.rw_mutex_shared_guard(&w.chunks_mu)
    chunk_pos, local_pos := loc_world_chunk_local(pos)
    chunk := get_chunk_unsafe(w, chunk_pos)
    if chunk == nil do return 0
    return chunk_get_block(chunk, local_pos.x, local_pos.y, local_pos.z)
}

world_set_chunk_block :: proc(w : ^World, chunk : ^Chunk, x, y, z : i32, block : u8) -> bool {
    if chunk == nil do return false
    sync.rw_mutex_shared_guard(&w.chunks_mu)
    return set_block_internal(w, chunk, x, y, z, block)
}

@(private = "file")
loc_world_chunk_local :: proc(pos : ivec3) -> (chunk, local : ivec3) {
    chunk = {pos.x >> C_SHIFT, pos.y >> C_SHIFT, pos.z >> C_SHIFT}
    local = pos & (C_SIZE - 1)
    return
}

world_render :: proc(w : ^World, vp : mat4, draw_lines : bool = false) {
    renderer_group("world_render")

    // handle mesh results
    sync.mutex_lock(&w.mesh_results_mu)
    for result in queue.pop_front_safe(&w.mesh_results) {
        chunk := get_chunk_unsafe(w, result.loc)
        if chunk == nil {
            vertex_pool_free(&w.vertex_pool, result.handle)
            continue
        }
        vertex_pool_publish(&w.vertex_pool, result.handle)
        vertex_pool_free(&w.vertex_pool, chunk.handle)
        chunk.handle = result.handle
    }
    sync.mutex_unlock(&w.mesh_results_mu)

    // commit to gpu
    vertex_pool_commit(&w.vertex_pool)

    // collect chunks
    w.render_count = 0
    sync.rw_mutex_shared_lock(&w.chunks_mu)
    for _, chunk in w.chunks {
        push_chunk(w, chunk)

        if draw_lines {
            min_pos := chunk.pos * C_SIZE
            max_pos := min_pos + ivec3{C_SIZE, C_SIZE, C_SIZE}
            color := u32(chunk.blocks != nil ? 0xFFFFFFFF : 0xFFFFFF1E)
            iml_bounds(vec3(min_pos), vec3(max_pos), color)
        }
    }
    sync.rw_mutex_shared_unlock(&w.chunks_mu)

    if w.render_count <= 0 do return

    gl.FlushMappedNamedBufferRange(w.cmd_buffer, 0, int(w.render_count) * size_of(gl.DrawArraysIndirectCommand))
    gl.FlushMappedNamedBufferRange(w.data_buffer, 0, int(w.render_count) * size_of(Per_Chunk_Data))

    gl.Enable(gl.DEPTH_TEST)
    gl.Enable(gl.CULL_FACE)
    gl.CullFace(gl.BACK)
    gl.UseProgram(w.chunk_program)

    vp := vp
    gl.UniformMatrix4fv(0, 1, false, &vp[0, 0])

    renderer_bind_empty_vao()
    gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 0, w.vertex_pool.buffer)
    gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 1, w.data_buffer)
    gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, w.cmd_buffer)
    gl.MultiDrawArraysIndirect(gl.TRIANGLES, nil, i32(w.render_count), 0)
}

@(private = "file")
push_chunk :: proc(w : ^World, chunk : ^Chunk) -> bool {
    handle := chunk.handle
    if handle.count == 0 do return false
    if w.render_count >= w.render_cap do return false

    w.cmds[w.render_count] = gl.DrawArraysIndirectCommand {
        count         = handle.count * 6,
        instanceCount = 1,
        first         = handle.offset * 6,
        baseInstance  = w.render_count,
    }
    w.data[w.render_count] = Per_Chunk_Data{chunk.pos.x * C_SIZE, chunk.pos.y * C_SIZE, chunk.pos.z * C_SIZE, 0}
    w.render_count += 1
    return true
}

@(private = "file")
set_block_internal :: proc(w : ^World, chunk : ^Chunk, x, y, z : i32, block : u8) -> bool {
    if chunk == nil do return false

    did_set := chunk_set_block(chunk, x, y, z, block)
    if !did_set do return false

    mark_chunk_dirty(w, chunk)
    // try_set_height(w, wpos, block)

    if x == 0 || x == C_SIZE - 1 || y == 0 || y == C_SIZE - 1 || z == 0 || z == C_SIZE - 1 {
        if x == 0 {
            if n := get_chunk_unsafe(w, chunk.pos + ivec3{-1, 0, 0}); n != nil {
                if chunk_set_block(n, C_SIZE, y, z, block) do mark_chunk_dirty(w, n)
            }
        } else if x == C_SIZE - 1 {
            if n := get_chunk_unsafe(w, chunk.pos + ivec3{1, 0, 0}); n != nil {
                if chunk_set_block(n, -1, y, z, block) do mark_chunk_dirty(w, n)
            }
        }

        if y == 0 {
            if n := get_chunk_unsafe(w, chunk.pos + ivec3{0, -1, 0}); n != nil {
                if chunk_set_block(n, x, C_SIZE, z, block) do mark_chunk_dirty(w, n)
            }
        } else if y == C_SIZE - 1 {
            if n := get_chunk_unsafe(w, chunk.pos + ivec3{0, 1, 0}); n != nil {
                if chunk_set_block(n, x, -1, z, block) do mark_chunk_dirty(w, n)
            }
        }

        if z == 0 {
            if n := get_chunk_unsafe(w, chunk.pos + ivec3{0, 0, -1}); n != nil {
                if chunk_set_block(n, x, y, C_SIZE, block) do mark_chunk_dirty(w, n)
            }
        } else if z == C_SIZE - 1 {
            if n := get_chunk_unsafe(w, chunk.pos + ivec3{0, 0, 1}); n != nil {
                if chunk_set_block(n, x, y, -1, block) do mark_chunk_dirty(w, n)
            }
        }
    }


    return true
}

@(private = "file")
mark_chunk_dirty :: proc(w : ^World, chunk : ^Chunk) {
    if chunk_mark_mesh_dirty(chunk) do return
    //sync.mutex_guard(&w.dirty_mu)
    //append(&w.dirty_chunks, chunk.pos) // maybe something like this?
}

@(private = "file")
get_chunk :: proc(w : ^World, pos : ivec3) -> ^Chunk {
    sync.rw_mutex_shared_guard(&w.chunks_mu)
    return get_chunk_unsafe(w, pos)
}

@(private = "file")
get_chunk_unsafe :: proc(world : ^World, pos : ivec3) -> ^Chunk {
    if pos.y < 0 || pos.y >= COL_HEIGHT do return nil
    if chunk, ok := world.chunks[pos]; ok {
        return chunk
    }
    return nil
}
@(private = "file")
gen_thread_proc :: proc(loc : ivec2, _ : mem.Allocator, user_data : rawptr) {
    world := cast(^World)user_data
    gen := rand.xoshiro256_random_generator()
    world_height := 50
    max_gen := (world_height / C_SIZE) + 1

    for i := max_gen - 1; i >= 0; i -= 1 {
        pos := ivec3{loc.x, i32(i), loc.y}
        chunk := get_chunk(world, pos)
        if chunk == nil do break

        for y in 0 ..< C_SIZE {
            if y + int(chunk.pos.y * C_SIZE) >= world_height do break

            for x in 0 ..< C_SIZE {
                for z in 0 ..< C_SIZE {
                    block := u8(rand.uint64(gen) % 4)

                    if block == 2 do block = 1
                    if i == 0 && y == 0 do block = 2
                    world_set_chunk_block(world, chunk, i32(x), i32(y), i32(z), block)
                }
            }
        }
    }

    ready : [5]ivec2
    ready_count := 0

    sync.mutex_lock(&world.columns_mu)
    world.columns[loc] = .Generated
    dirs := NEIGHBOUR_DIRS
    candidates : [5]ivec2
    candidates[0] = loc
    for d, i in dirs do candidates[i + 1] = loc + d

    for c in candidates {
        state, exists := world.columns[c]
        if !exists || state != .Generated do continue
        if !column_neighbours_generated_unsafe(world, c) do continue
        world.columns[c] = .Mesh_Queued
        ready[ready_count] = c
        ready_count += 1
    }
    sync.mutex_unlock(&world.columns_mu)

    for c in ready[:ready_count] {
        for i in 0 ..< COL_HEIGHT {
            pos := ivec3{c.x, i32(i), c.y}
            chunk := get_chunk(world, pos)
            if chunk != nil && chunk.num_filled > 0 do worker_push(&world.mesh_thread, pos)
        }
    }
}

@(private = "file")
column_neighbours_generated_unsafe :: proc(w : ^World, loc : ivec2) -> bool {
    dirs := NEIGHBOUR_DIRS
    for d in dirs {
        state, exists := w.columns[loc + d]
        // missing column is treated as world edge, must become "not ready" once columns stream or something
        if exists && state == .Allocated do return false
    }
    return true
}

@(private = "file")
mesh_thread_proc :: proc(loc : ivec3, scratch : mem.Allocator, user_data : rawptr) {
    world := (^World)(user_data)

    sync.rw_mutex_shared_guard(&world.chunks_mu)
    chunk := get_chunk_unsafe(world, loc)
    if chunk == nil do return

    bytes, err := mem.alloc_bytes_non_zeroed(MAX_FACES * size_of(Chunk_Face), align_of(Chunk_Face), scratch)
    assert(err == nil, "mesh scratch arena too small")
    face_buffer := mem.slice_data_cast([]Chunk_Face, bytes)
    face_count := u32(chunk_generate_faces(chunk, face_buffer))

    handle, ok := vertex_pool_alloc(&world.vertex_pool, face_buffer[:face_count])
    if !ok {
        fmt.eprintfln("vertex pool allocation failed for chunk %v", loc)
        return
    }

//    fmt.eprintfln("vertex pool page count: %v / %v", world.vertex_pool.page_count - world.vertex_pool.free_pages, world.vertex_pool.page_count)

    sync.mutex_lock(&world.mesh_results_mu)
    queue.push_back(&world.mesh_results, Mesh_Result{loc, handle})
    sync.mutex_unlock(&world.mesh_results_mu)
}
