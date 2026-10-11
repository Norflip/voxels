package main
import "core:container/queue"
import "core:fmt"
import "core:math/rand"
import "core:mem"
import "core:sync"
import gl "vendor:OpenGL"
import "core:math/noise"

//TODO: 
// implement biome specific params
// seperate rendering
// seperate world generation
// implement column height tracking

COL_HEIGHT :: 16
MAX_FACES :: C_VOLUME * 3 // * 3 for opaque, * 6 if transparent?
RENDER_CAP :: 4096
CMD_CAP :: RENDER_CAP * 6

NEIGHBOUR_DIRS :: [4]ivec2{{-1, 0}, {1, 0}, {0, -1}, {0, 1}}
Column_Heights :: [C_SIZE][C_SIZE]i32

SEA_HEIGHT :: 64
SURFACE_HEIGHT :: 20.0 // baseline surface above sea level
FLATGRASS_HEIGHT :: 20
SQUASH :: 0.8

// continental
CONT_OCTAVE :: 4
CONT_FREQ :: 1.0 / 700.0 // broad surface shape
CONT_AMP :: 28.0 // how much the surface rolls

// 3D density carve
DENSE_OCTAVE :: 4
DENSE_FREQ :: 1.0 / 110.0
DENSE_AMP :: 10.0



@(private = "file")
Per_Chunk_Data :: struct {
    x, y, z :  i32,
    _padding : u32,
}

@(private = "file")
Mesh_Result :: struct {
    loc :         ivec3,
    handle :      Mesh_Handle,
    face_counts : [6]u32,
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

    //
    load_radius :     i32,
    seed :            i64,
    flatgen :         bool,

    // rendering
    chunk_count :     u32,
    cmd_count :       u32,
    cmds :            [^]gl.DrawArraysIndirectCommand,
    data :            [^]Per_Chunk_Data,
    cmd_buffer :      u32,
    data_buffer :     u32,
    vertex_pool :     Vertex_Pool(Chunk_Face),
    chunk_program :   u32,
    vp_loc :          i32,
}

world_init :: proc(w : ^World, seed : i64, flatgrass : bool = false) {
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
    w.load_radius = 3
    w.seed = seed
    w.flatgen = flatgrass
    queue.init(&w.mesh_results, allocator = context.allocator)

    storage_flags : u32 = gl.MAP_WRITE_BIT | gl.MAP_PERSISTENT_BIT
    mapping_flags : u32 = gl.MAP_WRITE_BIT | gl.MAP_PERSISTENT_BIT | gl.MAP_FLUSH_EXPLICIT_BIT
    w.cmds = create_mapped_buffer(&w.cmd_buffer, CMD_CAP, storage_flags, mapping_flags, "Chunk_Batch_cmd_buf", gl.DrawArraysIndirectCommand)
    w.data = create_mapped_buffer(&w.data_buffer, RENDER_CAP, storage_flags, mapping_flags, "Chunk_Batch_data_buf", Per_Chunk_Data)
    //vertex_arena_init(&w.vertex_arena, 16 * mem.Megabyte)
    vertex_pool_init(&w.vertex_pool, 16 * mem.Megabyte, 256, context.allocator)

    MESH_SCRATCH_SIZE :: MAX_FACES * size_of(Chunk_Face)
    worker_init(&w.gen_thread, gen_thread_proc, w, 0, "gen_thread")
    worker_init(&w.mesh_thread, mesh_thread_proc, w, MESH_SCRATCH_SIZE, "mesh_thread")

    load_init_chunks(w)
    fmt.printf("world initialized\n")
}

@(private = "file")
load_init_chunks :: proc(w : ^World) {
    sync.rw_mutex_guard(&w.chunks_mu)
    sync.mutex_guard(&w.columns_mu)

    size := 1 + int(w.load_radius) * 2
    t := size
    x, z, dx, dz : int
    dz = -1
    i := 0

    for _ in 0 ..< (size * size) {
        if (-size / 2 <= x) && (x <= size / 2) && (-size / 2 <= z) && (z <= size / 2) {
            col := ivec2{i32(x), i32(z)}
            if _, ok := w.columns[col]; ok do continue
            for i := COL_HEIGHT - 1; i >= 0; i -= 1 {
                pos := ivec3{col.x, i32(i), col.y}
                chunk := new(Chunk, context.allocator)
                chunk_init(chunk, pos, context.allocator)
                w.chunks[pos] = chunk
            }
            w.columns[col] = .Allocated
            worker_push(&w.gen_thread, col)
            i += 1
        }

        if (x == z) || ((x < 0) && (x == -z)) || ((x > 0) && (x == 1 - z)) {
            t = dx
            dx = -dz
            dz = t
        }
        x += dx
        z += dz
    }
}


world_set_block :: proc(w : ^World, pos : ivec3, block : Block) -> bool {
    sync.rw_mutex_shared_guard(&w.chunks_mu)
    chunk_pos, local_pos := loc_world_chunk_local(pos)
    chunk := get_chunk_unsafe(w, chunk_pos)
    if chunk == nil do return false
    return set_block_internal(w, chunk, local_pos.x, local_pos.y, local_pos.z, block)
}

world_get_block :: proc(w : ^World, pos : ivec3) -> Block {
    sync.rw_mutex_shared_guard(&w.chunks_mu)
    chunk_pos, local_pos := loc_world_chunk_local(pos)
    chunk := get_chunk_unsafe(w, chunk_pos)
    if chunk == nil do return .Air
    return chunk_get_block(chunk, local_pos.x, local_pos.y, local_pos.z)
}

world_set_chunk_block :: proc(w : ^World, chunk : ^Chunk, x, y, z : i32, block : Block) -> bool {
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

world_get_player_spawn :: proc(w : ^World) -> vec3 {
    if w.flatgen do return vec3{C_SIZE / 2, FLATGRASS_HEIGHT + 4, C_SIZE / 2}
    return vec3{C_SIZE / 2, SEA_HEIGHT + SURFACE_HEIGHT + 4, C_SIZE / 2}
}

// cull_cam : Maybe(Camera) = nil ?
world_render :: proc(w : ^World, cam : Camera, cull_cam : Camera, draw_lines : bool = false) -> u32 {
    renderer_group("world_render")

    // handle mesh results
    sync.mutex_lock(&w.mesh_results_mu)
    for result in queue.pop_front_safe(&w.mesh_results) {
        chunk := get_chunk_unsafe(w, result.loc)
        if chunk == nil {
            vertex_pool_free(&w.vertex_pool, result.handle)
            continue
        }
        if result.handle.count > 0 do vertex_pool_publish(&w.vertex_pool, result.handle)
        vertex_pool_free(&w.vertex_pool, chunk.handle)
        chunk.handle = result.handle
        chunk.face_counts = result.face_counts
    }
    sync.mutex_unlock(&w.mesh_results_mu)

    // commit to gpu
    vertex_pool_commit(&w.vertex_pool)

    // collect chunks
    w.cmd_count = 0
    w.chunk_count = 0
    face_count : u32 = 0

    sync.rw_mutex_shared_lock(&w.chunks_mu)
    for _, chunk in w.chunks {
        face_count += push_chunk_for_render(w, chunk, cull_cam)

        if draw_lines && chunk.blocks != nil {
            min_pos := chunk.pos * C_SIZE
            max_pos := min_pos + ivec3{C_SIZE, C_SIZE, C_SIZE}
            // color := u32(chunk.blocks != nil ? 0xFFFFFFFF : 0xFFFFFF1E)
            iml_bounds(vec3(min_pos), vec3(max_pos), 0xFFFFFF1E)
        }
    }
    sync.rw_mutex_shared_unlock(&w.chunks_mu)

    if w.cmd_count == 0 do return 0

    gl.FlushMappedNamedBufferRange(w.cmd_buffer, 0, int(w.cmd_count) * size_of(gl.DrawArraysIndirectCommand))
    gl.FlushMappedNamedBufferRange(w.data_buffer, 0, int(w.chunk_count) * size_of(Per_Chunk_Data))

    gl.Enable(gl.DEPTH_TEST)
    gl.Enable(gl.CULL_FACE)
    gl.CullFace(gl.BACK)
    gl.UseProgram(w.chunk_program)

    vp := cam.view_proj
    gl.UniformMatrix4fv(0, 1, false, &vp[0, 0])

    renderer_bind_empty_vao()
    gl.BindTextureUnit(0, g_block_atlas.handle)
    gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 0, w.vertex_pool.buffer)
    gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 1, w.data_buffer)
    gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, w.cmd_buffer)
    gl.MultiDrawArraysIndirect(gl.TRIANGLES, nil, i32(w.cmd_count), 0)

    return face_count
}

/*
@(private = "file")
push_chunk_for_render :: proc(w : ^World, chunk : ^Chunk) -> bool {
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
*/

@(private = "file")
push_chunk_for_render :: proc(w : ^World, chunk : ^Chunk, cam : Camera) -> (faces_pushed : u32) {
    handle := chunk.handle
    if handle.count == 0 do return 0
    if w.chunk_count >= RENDER_CAP || w.cmd_count + 6 > CMD_CAP do return 0

    min_pos := vec3(chunk.pos * C_SIZE)
    max_pos := min_pos + C_SIZE

    if camera_aabb_in_view(cam, min_pos, max_pos) == false do return 0

    //a face with normal +X sits on a plane in (min.x, max.x] so it can only be front-facing when the camera is past min.x
    visible := [6]bool {
        cam.pos.x > min_pos.x, // +X
        cam.pos.x < max_pos.x, // -X
        cam.pos.y > min_pos.y, // +Y
        cam.pos.y < max_pos.y, // -Y
        cam.pos.z > min_pos.z, // +Z
        cam.pos.z < max_pos.z, // -Z
    }

    data_index := w.chunk_count
    offset := handle.offset
    for face in 0 ..< 6 {
        count := chunk.face_counts[face]
        start := offset
        offset += count
        if count == 0 || !visible[face] do continue

        w.cmds[w.cmd_count] = gl.DrawArraysIndirectCommand {
            count         = count * 6,
            instanceCount = 1,
            first         = start * 6,
            baseInstance  = data_index,
        }
        w.cmd_count += 1
        faces_pushed += count
    }

    if faces_pushed == 0 do return 0

    w.data[data_index] = Per_Chunk_Data{chunk.pos.x * C_SIZE, chunk.pos.y * C_SIZE, chunk.pos.z * C_SIZE, 0}
    w.chunk_count += 1
    return
}


@(private = "file")
set_block_internal :: proc(w : ^World, chunk : ^Chunk, x, y, z : i32, block : Block) -> bool {
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
    if !chunk_mark_mesh_dirty(chunk) do return

    // either push directly or add to a dirty queue?
    worker_push(&w.mesh_thread, chunk.pos)
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
    column : [COL_HEIGHT]^Chunk 
    heights : Column_Heights

    if world.flatgen {
        max_col_y := (FLATGRASS_HEIGHT / C_SIZE) + 1
        for i in 0 ..< max_col_y {
            column[i] = get_chunk(world, ivec3{loc.x, i32(i), loc.y})
            gen_flat_shape(world, column[i])
        }
        for x in 0 ..< C_SIZE {
            for z in 0 ..< C_SIZE {
                heights[x][z] = FLATGRASS_HEIGHT
            }
        }
    } else {
        for i in 0 ..< COL_HEIGHT {
            column[i] = get_chunk(world, ivec3{loc.x, i32(i), loc.y})
            gen_shape(world, column[i], &heights)
        }
    }

    gen_surface(world, &column, &heights)

    if column[0] != nil do gen_mantle(world, column[0])

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

    // All chunks, including empty ones, so the mesher clears their initial dirty flag.
    // TODO: maybe not
    for c in ready[:ready_count] {
        for i in 0 ..< COL_HEIGHT {
            pos := ivec3{c.x, i32(i), c.y}
            if get_chunk(world, pos) != nil do worker_push(&world.mesh_thread, pos)
        }
    }
}


@(private = "file")
gen_shape :: proc(w : ^World, chunk : ^Chunk, heights : ^Column_Heights) {

    vol : Noise_Volume
    noise_vol_fill(
        &vol,
        w.seed,
        chunk.pos * C_SIZE,
        proc(seed : i64, wx, wy, wz : f64, ctx : rawptr) -> f64 {
            cont := noise_fbm(seed + 0x44, wx, wz, CONT_OCTAVE, CONT_FREQ) // fbm returns [-1,1]
            cont *= CONT_AMP

            carve := noise_fbm(seed + 0x11, wx, wy, wz, DENSE_OCTAVE, DENSE_FREQ)
            carve *= DENSE_AMP

            surface := f64(SEA_HEIGHT) + SURFACE_HEIGHT + cont
            return carve + (surface - wy) * SQUASH
        },
    )

    base_y := chunk.pos.y * C_SIZE
    for x in 0 ..< i32(C_SIZE) {
        for z in 0 ..< i32(C_SIZE) {
            for y : i32 = C_SIZE - 1; y >= 0; y -= 1 {
                d := noise_vol_sample(&vol, x, y, z)
                if d > 0 {
                    world_set_chunk_block(w, chunk, x, y, z, .Stone)
                    if heights[x][z] < base_y + y do heights[x][z] = base_y + y
                }
            }
        }
    }
}

@(private = "file")
gen_flat_shape :: proc(w : ^World, chunk : ^Chunk) {
    base_y := chunk.pos.y * C_SIZE
    for x in 0 ..< i32(C_SIZE) {
        for z in 0 ..< i32(C_SIZE) {
            for y : i32 = C_SIZE - 1; y >= 0; y -= 1 {
                world_y := base_y + y
                if world_y > FLATGRASS_HEIGHT do continue
                world_set_chunk_block(w, chunk, x, y, z, .Stone)
            }
        }
    }
}

@(private = "file")
gen_surface :: proc(w : ^World, column : ^[COL_HEIGHT]^Chunk, heights : ^Column_Heights) {
    for x in 0 ..< i32(C_SIZE) {
        for z in 0 ..< i32(C_SIZE) {
            top := heights[x][z]
            if top < 0 do break

            chunk := column[top >> C_SHIFT]
            if chunk == nil do continue
            world_set_chunk_block(w, chunk, x, top & (C_SIZE - 1), z, .Grass)
        }
    }
}

@(private = "file")
gen_mantle :: proc(w : ^World, bottom : ^Chunk) {
    assert(bottom.pos.y == 0)
    for x in 0 ..< i32(C_SIZE) {
        for z in 0 ..< i32(C_SIZE) {
            world_set_chunk_block(w, bottom, x, 0, z, .Mantle)
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

    // Must precede all block reads: any edit after this point re-queues the chunk.
    chunk_clear_mesh_dirty(chunk)

    handle : Mesh_Handle
    face_counts : [6]u32
    if chunk.num_filled > 0 {
        bytes, err := mem.alloc_bytes_non_zeroed(MAX_FACES * size_of(Chunk_Face), align_of(Chunk_Face), scratch)
        assert(err == nil, "mesh scratch arena too small")
        face_buffer := mem.slice_data_cast([]Chunk_Face, bytes)
        face_count : u32
        face_count, face_counts = chunk_generate_faces(chunk, face_buffer)

        if face_count > 0 {
            ok : bool
            handle, ok = vertex_pool_alloc(&world.vertex_pool, face_buffer[:face_count])
            if !ok {
                fmt.eprintfln("vertex pool allocation failed for chunk %v", loc)
                return
            }
        }
    }

    sync.mutex_lock(&world.mesh_results_mu)
    queue.push_back(&world.mesh_results, Mesh_Result{loc, handle, face_counts})
    sync.mutex_unlock(&world.mesh_results_mu)
}
