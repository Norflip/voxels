package main
import "core:container/queue"
import "core:fmt"
import "core:mem"
import "core:sync"
import "base:intrinsics"
import math "core:math/linalg/glsl"
import gl "vendor:OpenGL"

//TODO:
// implement biome specific params
// seperate rendering
// seperate world generation
// implement column height tracking

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

H_SIZE :: 16
H_SHIFT :: 4
H_AREA :: H_SIZE * H_SIZE
H_VOL :: H_SIZE * H_SIZE * H_SIZE
H_WSIZE :: H_SIZE * C_SIZE
H_WSHIFT :: H_SHIFT + C_SHIFT
H_WAREA :: H_WSIZE * H_WSIZE

@(private = "file")
Hunk :: struct {
    pos :     ivec2,
    mu :      sync.RW_Mutex,
    columns : [H_AREA]Column_State,
    chunks :  [H_AREA][H_SIZE]^Chunk,
    cols_count :   u32,
}

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

@(private = "file")
Column_State :: enum u8 {
    Unloaded = 0,
    Allocated,
    Generated,
    Mesh_Queued,
}

World_Flag :: enum u8 {
    Default = 0,
    Gen_Flat,
    No_Ring,
}
World_Flags :: bit_set[World_Flag;u8]

World :: struct {
    hunks :           map[ivec2]^Hunk,
    hunks_mu :        sync.RW_Mutex,
    gen_thread :      Worker(ivec2),
    mesh_thread :     Worker(ivec3),
    exiting :         b32,
    mesh_results :    queue.Queue(Mesh_Result),
    mesh_results_mu : sync.Mutex,

    //
    load_radius :     i32,
    load_center :     [2]i32,
    seed :            i64,
    flags :           World_Flags,

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

world_init :: proc(w : ^World, seed : i64, flags : World_Flags = {}) {
    ok : bool
    w.chunk_program, ok = load_program("chunk", "../assets/chunk.vert", "../assets/chunk.frag")
    if !ok {
        fmt.printf("Failed to load chunk program\n")
        return
    }

    w.vp_loc = gl.GetUniformLocation(w.chunk_program, "u_vp")
    //w.chunks = make(map[ivec3]^Chunk, context.allocator)
    //w.columns = make(map[ivec2]Column_State, context.allocator)
    w.hunks = make(map[ivec2]^Hunk, context.allocator)
    w.exiting = false
    w.load_radius = 3
    w.load_center = [2]i32{2, 2}
    w.seed = seed
    w.flags = flags
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
    sync.rw_mutex_guard(&w.hunks_mu)

    radius := w.load_radius
    if .No_Ring not_in w.flags do radius += 1

    size := 1 + int(radius) * 2
    center := w.load_center
    min_hunk, _ := modiv_chunk_hunk_local(ivec3{center.x - radius, 0, center.y - radius})
    max_hunk, _ := modiv_chunk_hunk_local(ivec3{center.x + radius, 0, center.y + radius})

    for hunk_x := min_hunk.x; hunk_x <= max_hunk.x; hunk_x += 1 {
        for hunk_z := min_hunk.z; hunk_z <= max_hunk.z; hunk_z += 1 {
            try_create_hunk(w, hunk_x, hunk_z)
        }
    }

    x, z, dx, dz : int
    dz = -1
    for _ in 0 ..< (size * size) {
        if (-size / 2 <= x) && (x <= size / 2) && (-size / 2 <= z) && (z <= size / 2) {
            load_column(w, center + ivec2{i32(x), i32(z)})
        }

        if (x == z) || ((x < 0) && (x == -z)) || ((x > 0) && (x == 1 - z)) {
            dx, dz = -dz, dx
        }
        x += dx
        z += dz
    }
}

@(private = "file")
try_create_hunk :: proc(w : ^World, hunk_x, hunk_z : i32) -> bool {

    key := ivec2{hunk_x, hunk_z}
    if _, exists := w.hunks[key]; exists do return false

    hunk := new(Hunk, context.allocator)
    hunk.pos = key
    w.hunks[key] = hunk

    fmt.printf("initializing hunk at (%v, %v)\n", hunk_x, hunk_z)
    return true
}

@(private = "file")
load_column :: proc(w : ^World, col : ivec2) {
    key, idx := hunk_column_index(col)
    hunk := w.hunks[key]
    assert(hunk != nil, "load_column: hunk not created")

    sync.rw_mutex_guard(&hunk.mu)
    if hunk.columns[idx] != .Unloaded do return
    for i := H_SIZE - 1; i >= 0; i -= 1 {
        chunk := new(Chunk, context.allocator)
        chunk_init(chunk, ivec3{col.x, i32(i), col.y}, context.allocator)
        hunk.chunks[idx][i] = chunk
    }
    
    hunk.columns[idx] = .Allocated
    intrinsics.atomic_add(&hunk.cols_count, 1)
    worker_push(&w.gen_thread, col)
}

world_set_block :: proc(w : ^World, pos : ivec3, block : Block) -> bool {
    sync.rw_mutex_shared_guard(&w.hunks_mu)
    chunk_pos, local_pos := modiv_world_chunk_local(pos)
    chunk := get_chunk_unsafe(w, chunk_pos)
    if chunk == nil do return false
    return set_block_internal(w, chunk, local_pos.x, local_pos.y, local_pos.z, block)
}

world_get_block :: proc(w : ^World, pos : ivec3) -> Block {
    sync.rw_mutex_shared_guard(&w.hunks_mu)
    chunk_pos, local_pos := modiv_world_chunk_local(pos)
    chunk := get_chunk_unsafe(w, chunk_pos)
    if chunk == nil do return .Air
    return chunk_get_block(chunk, local_pos.x, local_pos.y, local_pos.z)
}

world_set_chunk_block :: proc(w : ^World, chunk : ^Chunk, x, y, z : i32, block : Block) -> bool {
    if chunk == nil do return false
    sync.rw_mutex_shared_guard(&w.hunks_mu)
    return set_block_internal(w, chunk, x, y, z, block)
}

modiv_world_chunk_local :: #force_inline proc(pos : ivec3) -> (chunk, local : ivec3) {
    chunk = {pos.x >> C_SHIFT, pos.y >> C_SHIFT, pos.z >> C_SHIFT}
    local = pos & (C_SIZE - 1)
    return
}

modiv_chunk_hunk_local :: #force_inline proc(pos : ivec3) -> (hunk, local : ivec3) {
    hunk = {pos.x >> H_SHIFT, pos.y >> H_SHIFT, pos.z >> H_SHIFT}
    local = pos & (H_SIZE - 1)
    return
}

modiv_world_hunk_local :: #force_inline proc(pos : ivec3) -> (hunk : ivec2, local : ivec3) {
    hunk = {pos.x >> H_WSHIFT, pos.z >> H_WSHIFT}
    local = pos & (H_WSIZE - 1)
    return
}

hunk_column_index :: #force_inline proc(col : ivec2) -> (hunk : ivec2, idx : i32) {
    hunk = {col.x >> H_SHIFT, col.y >> H_SHIFT}
    idx = (col.y & (H_SIZE - 1)) << H_SHIFT | (col.x & (H_SIZE - 1))
    return
}

world_get_player_spawn :: proc(w : ^World) -> vec3 {
    if .Gen_Flat in w.flags do return vec3{C_SIZE / 2, FLATGRASS_HEIGHT + 4, C_SIZE / 2}
    return vec3{C_SIZE / 2, SEA_HEIGHT + SURFACE_HEIGHT + 4, C_SIZE / 2}
}

// cull_cam : Maybe(Camera) = nil ?
world_render :: proc(w : ^World, cam : Camera, cull_cam : Camera, draw_lines : bool = false) -> u32 {

    // hunk bounds
    if draw_lines {
        for key, hunk in w.hunks {
            min_pos := ivec3{key.x << H_WSHIFT, 0, key.y << H_WSHIFT}
            max_pos := min_pos + ivec3{H_WSIZE, H_SIZE * C_SIZE, H_WSIZE}
            iml_bounds(vec3(min_pos), vec3(max_pos), 0xFF0000FF)
        }
    }

    renderer_group("world_render")

    sync.rw_mutex_shared_lock(&w.hunks_mu)

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

    for _, hunk in w.hunks {
        sync.rw_mutex_shared_lock(&hunk.mu)
        for col in 0 ..< H_AREA {
            if hunk.columns[col] == .Unloaded do continue
            for chunk in hunk.chunks[col] {
                face_count += push_chunk_for_render(w, chunk, cull_cam)

                if draw_lines && chunk.blocks != nil {
                    min_pos := chunk.pos * C_SIZE
                    max_pos := min_pos + ivec3{C_SIZE, C_SIZE, C_SIZE}
                    iml_bounds(vec3(min_pos), vec3(max_pos), 0xFFFFFF1E)
                }
            }
        }
        sync.rw_mutex_shared_unlock(&hunk.mu)
    }
    sync.rw_mutex_shared_unlock(&w.hunks_mu)

    if w.cmd_count == 0 do return 0

    gl.FlushMappedNamedBufferRange(w.cmd_buffer, 0, int(w.cmd_count) * size_of(gl.DrawArraysIndirectCommand))
    gl.FlushMappedNamedBufferRange(w.data_buffer, 0, int(w.chunk_count) * size_of(Per_Chunk_Data))

    gl.Enable(gl.DEPTH_TEST)
    gl.Enable(gl.CULL_FACE)
    gl.CullFace(gl.BACK)
    gl.UseProgram(w.chunk_program)

    vp := cam.view_proj
    gl.UniformMatrix4fv(0, 1, false, &vp[0, 0])

    sun_orbit := renderer_sun_mat()
    gl.UniformMatrix3fv(gl.GetUniformLocation(w.chunk_program, "u_sun_orbit"), 1, gl.FALSE, raw_data(&sun_orbit))

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
    sync.rw_mutex_shared_guard(&w.hunks_mu)
    return get_chunk_unsafe(w, pos)
}

@(private = "file")
get_chunk_unsafe :: proc(w : ^World, pos : ivec3) -> ^Chunk {
    if pos.y < 0 || pos.y >= H_SIZE do return nil
    key, idx := hunk_column_index(ivec2{pos.x, pos.z})
    hunk := w.hunks[key]
    if hunk == nil do return nil
    sync.rw_mutex_shared_guard(&hunk.mu)
    return hunk.chunks[idx][pos.y]
}

@(private = "file")
gen_thread_proc :: proc(loc : ivec2, _ : mem.Allocator, user_data : rawptr) {
    world := cast(^World)user_data
    column : [H_SIZE]^Chunk
    heights : Column_Heights

    if .Gen_Flat in world.flags {
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
        for i in 0 ..< H_SIZE {
            column[i] = get_chunk(world, ivec3{loc.x, i32(i), loc.y})
            gen_shape(world, column[i], &heights)
        }
    }

    gen_surface(world, &column, &heights)
    if column[0] != nil do gen_mantle(world, column[0])

    ready : [5]ivec2
    ready_count := 0

    // readiness spans up to 4 hunks
    // exclusive map lock instead of ordered hunk locks runs once per column
    sync.rw_mutex_lock(&world.hunks_mu)
    column_state_unsafe(world, loc)^ = .Generated
    dirs := NEIGHBOUR_DIRS
    candidates : [5]ivec2
    candidates[0] = loc
    for d, i in dirs do candidates[i + 1] = loc + d

    for c in candidates {
        state := column_state_unsafe(world, c)
        if state == nil || state^ != .Generated do continue
        if !column_neighbours_generated_unsafe(world, c) do continue
        state^ = .Mesh_Queued
        ready[ready_count] = c
        ready_count += 1
    }
    sync.rw_mutex_unlock(&world.hunks_mu)

    // All chunks, including empty ones, so the mesher clears their initial dirty flag.
    // TODO: maybe not
    for c in ready[:ready_count] {
        for i in 0 ..< H_SIZE {
            pos := ivec3{c.x, i32(i), c.y}
            if get_chunk(world, pos) != nil do worker_push(&world.mesh_thread, pos)
        }
    }
}

@(private = "file")
column_state_unsafe :: proc(w : ^World, col : ivec2) -> ^Column_State {
    key, idx := hunk_column_index(col)
    hunk := w.hunks[key]
    if hunk == nil do return nil
    return &hunk.columns[idx]
}

@(private = "file")
column_neighbours_generated_unsafe :: proc(w : ^World, loc : ivec2) -> bool {
    dirs := NEIGHBOUR_DIRS
    for d in dirs {
        state := column_state_unsafe(w, loc + d)
        // unloaded column is treated as world edge, must become "not ready" once columns stream or something
        if state != nil && state^ == .Allocated do return false
    }
    return true
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
gen_surface :: proc(w : ^World, column : ^[H_SIZE]^Chunk, heights : ^Column_Heights) {
    for x in 0 ..< i32(C_SIZE) {
        for z in 0 ..< i32(C_SIZE) {
            top := heights[x][z]
            if top < 0 do continue

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
should_mesh :: proc(w : ^World, chunk : ^Chunk) -> bool {
    d := ivec2{chunk.pos.x, chunk.pos.z} - w.load_center
    return math.abs_i32(d.x) <= w.load_radius && math.abs_i32(d.y) <= w.load_radius
}

@(private = "file")
mesh_thread_proc :: proc(loc : ivec3, scratch : mem.Allocator, user_data : rawptr) {
    w := (^World)(user_data)
    sync.rw_mutex_shared_guard(&w.hunks_mu)
    chunk := get_chunk_unsafe(w, loc)
    if chunk == nil do return

    if !should_mesh(w, chunk) do return

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
            handle, ok = vertex_pool_alloc(&w.vertex_pool, face_buffer[:face_count])
            if !ok {
                fmt.eprintfln("vertex pool allocation failed for chunk %v", loc)
                return
            }
        }
    }

    sync.mutex_lock(&w.mesh_results_mu)
    queue.push_back(&w.mesh_results, Mesh_Result{loc, handle, face_counts})
    sync.mutex_unlock(&w.mesh_results_mu)
}
