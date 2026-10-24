package main
import "core:container/queue"
import "core:fmt"
import "core:mem"
import "core:sync"
import "base:intrinsics"
import math "core:math/linalg/glsl"
import gl "vendor:OpenGL"

MAX_FACES :: C_VOLUME * 3 // * 3 for opaque, * 6 if transparent?
RENDER_CAP :: 4096
CMD_CAP :: RENDER_CAP * 6
FRAMES_IN_FLIGHT :: 3

NEIGHBOUR_DIRS :: [4]ivec2{{-1, 0}, {1, 0}, {0, -1}, {0, 1}}
NEIGHBOUR_DIRS_8 :: [8]ivec2{{-1, -1}, {0, -1}, {1, -1}, {-1, 0}, {1, 0}, {-1, 1}, {0, 1}, {1, 1}}

H_SIZE :: 16
H_SHIFT :: 4
H_AREA :: H_SIZE * H_SIZE
H_VOL :: H_SIZE * H_SIZE * H_SIZE
H_WSIZE :: H_SIZE * C_SIZE
H_WSHIFT :: H_SHIFT + C_SHIFT
H_WAREA :: H_WSIZE * H_WSIZE

CLIMATE_JUMP :: 16
CLIMATE_STEPS :: H_WSIZE / CLIMATE_JUMP + 1
Climate_Noise :: Noise_Area(H_WSIZE, CLIMATE_JUMP)

MAX_STAMPS_PER_COLUMN :: (C_SIZE / TREE_CELL) * (C_SIZE / TREE_CELL)

Stamp_Placement :: struct {
    //pos :  ivec3,
    x, z : u8,
    y :    u16,
    kind : Stamp_Kind,
}

Column_Stamps :: struct {
    count : u8,
    items : [MAX_STAMPS_PER_COLUMN]Stamp_Placement,
}

Hunk :: struct {
    pos :         ivec2,
    mu :          sync.RW_Mutex,
    columns :     [H_AREA]Column_State,
    chunks :      [H_AREA][H_SIZE]^Chunk,
    cols_count :  u32,
    heightmap :   [H_WAREA]i16,
    stamps :      [H_AREA]Column_Stamps,

    // readonly stuff
    cont :        Climate_Noise,
    temperature : Climate_Noise,
    rain :        Climate_Noise,
    biomes :      [CLIMATE_STEPS * CLIMATE_STEPS]Biome,
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
    Generated, // terrain and stamp plan done
    Decorating, // writing stamps, may touch all 8 neighbours
    Decorated,
    Mesh_Queued,
}

World_Flag :: enum u8 {
    Default = 0,
    Gen_Flat,
    No_Ring,
}
World_Flags :: bit_set[World_Flag;u8]

World :: struct {
    hunks :               map[ivec2]^Hunk,
    hunks_mu :            sync.RW_Mutex,
    gen_thread :          Worker(ivec2),
    mesh_thread :         Worker(ivec3),
    exiting :             b32,
    mesh_results :        queue.Queue(Mesh_Result),
    mesh_results_mu :     sync.Mutex,

    // world gen parameters
    load_radius :         i32,
    load_center :         [2]i32,
    seed :                i64,
    flags :               World_Flags,
    biome_scale :         f64,

    // rendering
    visible_chunk_count : u32,
    cmd_count :           u32,
    cmds :                [^]gl.DrawArraysIndirectCommand, // FRAMES_IN_FLIGHT slots of CMD_CAP
    data :                [^]Per_Chunk_Data, // FRAMES_IN_FLIGHT slots of data_stride
    cmd_buffer :          u32,
    data_buffer :         u32,
    data_stride :         u32, // elements per data slot, SSBO offset aligned
    frame :               u32, // slot being written this frame
    fences :              [FRAMES_IN_FLIGHT]gl.sync_t,
    vertex_pool :         Vertex_Pool(Chunk_Face),
    chunk_program :       u32,
    vp_loc :              i32,
}

world_init :: proc(w : ^World, seed : i64, load_radius : i32, flags : World_Flags = {}) {
    ok : bool
    w.chunk_program, ok = load_program("chunk", "../assets/chunk.vert", "../assets/chunk.frag")
    if !ok {
        fmt.printf("Failed to load chunk program\n")
        return
    }

    w.vp_loc = gl.GetUniformLocation(w.chunk_program, "u_vp")
    w.hunks = make(map[ivec2]^Hunk, context.allocator)
    w.exiting = false
    w.load_radius = load_radius
    w.load_center = [2]i32{0, 0}
    w.seed = seed
    w.flags = flags
    w.biome_scale = 0.8
    queue.init(&w.mesh_results, allocator = context.allocator)

    ssbo_align : i32
    gl.GetIntegerv(gl.SHADER_STORAGE_BUFFER_OFFSET_ALIGNMENT, &ssbo_align)
    data_bytes := mem.align_forward_int(RENDER_CAP * size_of(Per_Chunk_Data), max(int(ssbo_align), size_of(Per_Chunk_Data)))
    w.data_stride = u32(data_bytes / size_of(Per_Chunk_Data))

    storage_flags : u32 = gl.MAP_WRITE_BIT | gl.MAP_PERSISTENT_BIT
    mapping_flags : u32 = gl.MAP_WRITE_BIT | gl.MAP_PERSISTENT_BIT | gl.MAP_FLUSH_EXPLICIT_BIT
    w.cmds = create_mapped_buffer(&w.cmd_buffer, CMD_CAP * FRAMES_IN_FLIGHT, storage_flags, mapping_flags, "Chunk_Batch_cmd_buf", gl.DrawArraysIndirectCommand)
    w.data = create_mapped_buffer(&w.data_buffer, w.data_stride * FRAMES_IN_FLIGHT, storage_flags, mapping_flags, "Chunk_Batch_data_buf", Per_Chunk_Data)
    vertex_pool_init(&w.vertex_pool, 16 * mem.Megabyte, 256, context.allocator)

    MESH_SCRATCH_SIZE :: MAX_FACES * size_of(Chunk_Face)
    worker_init(&w.gen_thread, gen_thread_proc, w, 0, "gen_thread")
    worker_init(&w.mesh_thread, mesh_thread_proc, w, MESH_SCRATCH_SIZE, "mesh_thread")

    stamps_init()
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
    for &h in hunk.heightmap do h = -1 // no data
    hunk_gen_climate(w, hunk)
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

world_get_block :: proc(w : ^World, pos : ivec3) -> Block {
    sync.rw_mutex_shared_guard(&w.hunks_mu)
    chunk_pos, local_pos := modiv_world_chunk_local(pos)
    chunk := get_chunk_unsafe(w, chunk_pos)
    if chunk == nil do return .Air
    return chunk_get_block(chunk, local_pos.x, local_pos.y, local_pos.z)
}


world_set_block :: proc(w : ^World, pos : ivec3, block : Block) -> bool {
    sync.rw_mutex_shared_guard(&w.hunks_mu)
    chunk_pos, local_pos := modiv_world_chunk_local(pos)
    chunk := get_chunk_unsafe(w, chunk_pos)
    if chunk == nil do return false
    if !set_block_internal(w, chunk, local_pos.x, local_pos.y, local_pos.z, block) do return false
    update_height_unsafe(w, pos, block)
    return true
}

world_set_chunk_block :: proc(w : ^World, chunk : ^Chunk, x, y, z : i32, block : Block) -> bool {
    if chunk == nil do return false
    sync.rw_mutex_shared_guard(&w.hunks_mu)
    if !set_block_internal(w, chunk, x, y, z, block) do return false
    update_height_unsafe(w, chunk.pos * C_SIZE + ivec3{x, y, z}, block)
    return true
}

world_get_height :: proc(w : ^World, x, z : i32) -> (height : i32, ok : bool) {
    sync.rw_mutex_shared_guard(&w.hunks_mu)
    key, local := modiv_world_hunk_local(ivec3{x, 0, z})
    hunk := w.hunks[key]
    if hunk == nil do return -1, false
    height = i32(intrinsics.atomic_load_explicit(&hunk.heightmap[local.z * H_WSIZE + local.x], .Relaxed))
    return height, height >= 0
}

// biome of the nearest climate sample
world_get_biome :: proc(w : ^World, x, z : i32) -> (biome : Biome, ok : bool) {
    sync.rw_mutex_shared_guard(&w.hunks_mu)
    key, local := modiv_world_hunk_local(ivec3{x, 0, z})
    hunk := w.hunks[key]
    if hunk == nil do return .Plains, false
    ix := (local.x + CLIMATE_JUMP / 2) / CLIMATE_JUMP
    iz := (local.z + CLIMATE_JUMP / 2) / CLIMATE_JUMP
    return hunk.biomes[iz * CLIMATE_STEPS + ix], true
}

//TODO: come up with a better name for these kinds of procs
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
    /*
    if draw_lines {
        for key, hunk in w.hunks {
            min_pos := ivec3{key.x << H_WSHIFT, 0, key.y << H_WSHIFT}
            max_pos := min_pos + ivec3{H_WSIZE, H_SIZE * C_SIZE, H_WSIZE}
            iml_bounds(vec3(min_pos), vec3(max_pos), 0xFF0000FF)
        }
    }
    */

    renderer_group("world_render")
    wait_frame_fence(w)

    w.cmd_count = 0
    w.visible_chunk_count = 0
    face_count : u32 = 0

    sync.rw_mutex_shared_lock(&w.hunks_mu)
    {
        handle_mesh_results(w)
        vertex_pool_commit(&w.vertex_pool)

        for _, hunk in w.hunks {
            sync.rw_mutex_shared_lock(&hunk.mu)
            for col in 0 ..< H_AREA {
                if hunk.columns[col] == .Unloaded do continue
                for chunk in hunk.chunks[col] {
                    fc := push_chunk_for_render(w, chunk, cull_cam)
                    face_count += fc

                    if fc > 0 && draw_lines && chunk.blocks != nil {
                        min_pos := chunk.pos * C_SIZE
                        max_pos := min_pos + ivec3{C_SIZE, C_SIZE, C_SIZE}
                        iml_bounds(vec3(min_pos), vec3(max_pos), 0xFFFFFF1E)
                    }
                }
            }
            sync.rw_mutex_shared_unlock(&hunk.mu)
        }
    }
    sync.rw_mutex_shared_unlock(&w.hunks_mu)

    if w.cmd_count > 0 {
        cmd_offset := int(w.frame * CMD_CAP) * size_of(gl.DrawArraysIndirectCommand)
        data_offset := int(w.frame * w.data_stride) * size_of(Per_Chunk_Data)
        data_size := int(w.visible_chunk_count) * size_of(Per_Chunk_Data)

        gl.FlushMappedNamedBufferRange(w.cmd_buffer, cmd_offset, int(w.cmd_count) * size_of(gl.DrawArraysIndirectCommand))
        gl.FlushMappedNamedBufferRange(w.data_buffer, data_offset, data_size)

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

        // range starts at the slot, so baseInstance stays slot-local
        gl.BindBufferRange(gl.SHADER_STORAGE_BUFFER, 1, w.data_buffer, data_offset, data_size)
        gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, w.cmd_buffer)
        indirect_offset := ([^]gl.DrawArraysIndirectCommand)(rawptr(uintptr(cmd_offset)))
        gl.MultiDrawArraysIndirect(gl.TRIANGLES, indirect_offset, i32(w.cmd_count), 0)
    }

    signal_frame_fence(w)
    return face_count
}

@(private = "file")
handle_mesh_results :: proc(w : ^World) {
    sync.mutex_guard(&w.mesh_results_mu)

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
}

@(private = "file")
wait_frame_fence :: proc(w : ^World) {
    fence := w.fences[w.frame]
    if fence == nil do return

    wait: for {
        switch gl.ClientWaitSync(fence, gl.SYNC_FLUSH_COMMANDS_BIT, 1_000_000_000) {
        case gl.ALREADY_SIGNALED, gl.CONDITION_SATISFIED:
            break wait
        case gl.TIMEOUT_EXPIRED:
            fmt.eprintfln("frame fence %v: still waiting after 1s", w.frame)
        case gl.WAIT_FAILED:
            fmt.eprintfln("frame fence %v: ClientWaitSync failed", w.frame)
            break wait
        }
    }
    gl.DeleteSync(fence)
    w.fences[w.frame] = nil
}

@(private = "file")
signal_frame_fence :: proc(w : ^World) {
    assert(w.fences[w.frame] == nil)
    w.fences[w.frame] = gl.FenceSync(gl.SYNC_GPU_COMMANDS_COMPLETE, 0)
    w.frame = (w.frame + 1) % FRAMES_IN_FLIGHT
}

@(private = "file")
push_chunk_for_render :: proc(w : ^World, chunk : ^Chunk, cam : Camera) -> (faces_pushed : u32) {
    handle := chunk.handle
    if handle.count == 0 do return 0
    if w.visible_chunk_count >= RENDER_CAP || w.cmd_count + 6 > CMD_CAP do return 0

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

    cmd_base := w.frame * CMD_CAP
    data_base := w.frame * w.data_stride
    data_index := w.visible_chunk_count
    offset := handle.offset
    for face in 0 ..< 6 {
        count := chunk.face_counts[face]
        start := offset
        offset += count
        if count == 0 || !visible[face] do continue

        w.cmds[cmd_base + w.cmd_count] = gl.DrawArraysIndirectCommand {
            count         = count * 6,
            instanceCount = 1,
            first         = start * 6,
            baseInstance  = data_index,
        }
        w.cmd_count += 1
        faces_pushed += count
    }

    if faces_pushed == 0 do return 0

    w.data[data_base + data_index] = Per_Chunk_Data{chunk.pos.x * C_SIZE, chunk.pos.y * C_SIZE, chunk.pos.z * C_SIZE, 0}
    w.visible_chunk_count += 1
    return
}

@(private = "file")
set_block_internal :: proc(w : ^World, chunk : ^Chunk, x, y, z : i32, block : Block) -> bool {
    if chunk == nil do return false
    if !chunk_set_block(chunk, x, y, z, block) do return false
    mark_chunk_dirty(w, chunk)

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
update_height_unsafe :: proc(w : ^World, wpos : ivec3, block : Block) {
    key, local := modiv_world_hunk_local(wpos)
    hunk := w.hunks[key]
    if hunk == nil do return
    h := &hunk.heightmap[local.z * H_WSIZE + local.x]
    top := i32(intrinsics.atomic_load_explicit(h, .Relaxed))

    if block_is_solid(block) {
        if wpos.y > top do intrinsics.atomic_store_explicit(h, i16(wpos.y), .Relaxed)
        return
    }
    if wpos.y != top do return

    lx := wpos.x & (C_SIZE - 1)
    lz := wpos.z & (C_SIZE - 1)
    new_top : i32 = -1
    y := wpos.y - 1
    scan: for y >= 0 {
        chunk_base := (y >> C_SHIFT) << C_SHIFT
        chunk := get_chunk_unsafe(w, ivec3{wpos.x >> C_SHIFT, y >> C_SHIFT, wpos.z >> C_SHIFT})
        if chunk != nil && chunk.num_filled > 0 {
            for ly := y - chunk_base; ly >= 0; ly -= 1 {
                if block_is_solid(chunk_get_block(chunk, lx, ly, lz)) {
                    new_top = chunk_base + ly
                    break scan
                }
            }
        }
        y = chunk_base - 1
    }
    intrinsics.atomic_store_explicit(h, i16(new_top), .Relaxed)
}

@(private = "file")
store_column_heights :: proc(w : ^World, loc : ivec2, heights : ^Column_Heights) {
    sync.rw_mutex_shared_guard(&w.hunks_mu)
    key, _ := hunk_column_index(loc)
    hunk := w.hunks[key]
    if hunk == nil do return

    base_x := (loc.x & (H_SIZE - 1)) * C_SIZE
    base_z := (loc.y & (H_SIZE - 1)) * C_SIZE
    for z in 0 ..< i32(C_SIZE) {
        row := (base_z + z) * H_WSIZE + base_x
        for x in 0 ..< i32(C_SIZE) {
            intrinsics.atomic_store_explicit(&hunk.heightmap[row + x], i16(heights[x][z]), .Relaxed)
        }
    }
}

@(private = "file")
mark_chunk_dirty :: proc(w : ^World, chunk : ^Chunk) {
    if !chunk_mark_mesh_dirty(chunk) do return

    // either push directly or add to a dirty queue?
    worker_push(&w.mesh_thread, chunk.pos)
}

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

    heights : Column_Heights
    shape : Column_Shape
    gen_column(world, loc, &heights, &shape)
    store_column_heights(world, loc, &heights)
    plan_column_stamps(world, loc, &heights, &shape)

    // only columns within 1 of loc can become decoratable now
    decorate : [9]ivec2
    decorate_count := 0

    sync.rw_mutex_lock(&world.hunks_mu)
    column_state_unsafe(world, loc)^ = .Generated
    for dz in i32(-1) ..= 1 {
        for dx in i32(-1) ..= 1 {
            c := loc + ivec2{dx, dz}
            state := column_state_unsafe(world, c)
            if state == nil || state^ != .Generated do continue
            if !column_neighbours_at_least_unsafe(world, c, .Generated) do continue
            state^ = .Decorating
            decorate[decorate_count] = c
            decorate_count += 1
        }
    }
    sync.rw_mutex_unlock(&world.hunks_mu)

    if decorate_count == 0 do return
    for c in decorate[:decorate_count] do apply_column_stamps(world, c)

    // only columns within 2 of loc can become mesh-ready now
    ready : [25]ivec2
    ready_count := 0

    sync.rw_mutex_lock(&world.hunks_mu)
    for c in decorate[:decorate_count] do column_state_unsafe(world, c)^ = .Decorated
    for dz in i32(-2) ..= 2 {
        for dx in i32(-2) ..= 2 {
            c := loc + ivec2{dx, dz}
            state := column_state_unsafe(world, c)
            if state == nil || state^ != .Decorated do continue
            if !column_neighbours_at_least_unsafe(world, c, .Decorated) do continue
            state^ = .Mesh_Queued
            ready[ready_count] = c
            ready_count += 1
        }
    }
    sync.rw_mutex_unlock(&world.hunks_mu)

    // All chunks, including empty ones, so the mesher clears their initial dirty flag.
    for c in ready[:ready_count] {
        for i in 0 ..< H_SIZE {
            pos := ivec3{c.x, i32(i), c.y}
            if get_chunk(world, pos) != nil do worker_push(&world.mesh_thread, pos)
        }
    }
}

gen_stamp_block :: proc(w : ^World, wpos : ivec3, block : Block) -> bool {
    sync.rw_mutex_shared_guard(&w.hunks_mu)
    chunk_pos, local := modiv_world_chunk_local(wpos)
    chunk := get_chunk_unsafe(w, chunk_pos)
    if chunk == nil do return false
    if chunk_get_block(chunk, local.x, local.y, local.z) != .Air do return false
    if !set_block_internal(w, chunk, local.x, local.y, local.z, block) do return false
    if block_is_solid(block) do raise_height_unsafe(w, wpos)
    return true
}

gen_set_block :: proc(w : ^World, chunk : ^Chunk, x, y, z : i32, block : Block) -> bool {
    if chunk == nil do return false
    sync.rw_mutex_shared_guard(&w.hunks_mu)
    return set_block_internal(w, chunk, x, y, z, block)
}

world_column_seed :: #force_inline proc(seed : i64, col : ivec2, salt : u64 = 0x5747_4D50) -> u64 {
    return u64(seed) ~ salt ~ (u64(u32(col.x)) << 32 | u64(u32(col.y)))
}

@(private = "file")
raise_height_unsafe :: proc(w : ^World, wpos : ivec3) {
    key, local := modiv_world_hunk_local(wpos)
    hunk := w.hunks[key]
    if hunk == nil do return
    h := &hunk.heightmap[local.z * H_WSIZE + local.x]
    new_top := i16(wpos.y)
    cur := intrinsics.atomic_load_explicit(h, .Relaxed)
    for cur < new_top {
        prev, ok := intrinsics.atomic_compare_exchange_weak_explicit(h, cur, new_top, .Relaxed, .Relaxed)
        if ok do break
        cur = prev
    }
}

@(private = "file")
column_at_least_unsafe :: proc(w : ^World, col : ivec2, min_state : Column_State) -> bool {
    state := column_state_unsafe(w, col)
    if state == nil || state^ == .Unloaded do return .No_Ring in w.flags
    return state^ >= min_state
}

@(private = "file")
column_neighbours_at_least_unsafe :: proc(w : ^World, col : ivec2, min_state : Column_State) -> bool {
    dirs := NEIGHBOUR_DIRS_8
    for d in dirs {
        if !column_at_least_unsafe(w, col + d, min_state) do return false
    }
    return true
}

@(private = "file")
column_state_unsafe :: proc(w : ^World, col : ivec2) -> ^Column_State {
    key, idx := hunk_column_index(col)
    hunk := w.hunks[key]
    if hunk == nil do return nil
    return &hunk.columns[idx]
}

@(private = "file")
should_mesh :: proc(load_radius : i32, center : [2]i32, chunk : ^Chunk) -> bool {
    d := ivec2{chunk.pos.x, chunk.pos.z} - center
    return math.abs_i32(d.x) <= load_radius && math.abs_i32(d.y) <= load_radius
}

@(private = "file")
mesh_thread_proc :: proc(loc : ivec3, scratch : mem.Allocator, user_data : rawptr) {
    w := (^World)(user_data)
    sync.rw_mutex_shared_guard(&w.hunks_mu)
    chunk := get_chunk_unsafe(w, loc)
    if chunk == nil do return

    if !should_mesh(w.load_radius, w.load_center, chunk) do return

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
