package main
import "core:container/queue"
import "core:fmt"
import "core:math/rand"
import "core:mem"
import "core:sync"
import gl "vendor:OpenGL"

COL_HEIGHT :: 16
MAX_FACES :: C_VOLUME * 3 // * 3 for opaque, * 6 if transparent? 
MESH_SCRATCH_SIZE :: MAX_FACES * size_of(Chunk_Face)
MESH_BUFFER_FACES :: 16 * mem.Megabyte / size_of(Chunk_Face)
RENDER_CAP :: 4096

@(private = "file")
Per_Chunk_Data :: struct {
    x, y, z :  i32,
    _padding : u32,
}

Mesh_Handle :: struct {
    offset : u32,
    count :  u32,
}

@(private = "file")
Mesh_Result :: struct {
    loc :    ivec3,
    handle : Mesh_Handle,
}

World :: struct {
    chunks :          map[ivec3]^Chunk,
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
    mesh_faces :      [^]Chunk_Face,
    mesh_buffer :     u32,
    mesh_used :       u32, // in faces, atomic
    chunk_program :   u32,
    vp_loc :          i32,
    empty_vao :       u32,
}

// GL
create_mapped_buffer :: proc(buffer : ^u32, size : u32, storage_flags : u32, mapping_flags : u32, label : cstring, $T : typeid) -> [^]T {
    gl.CreateBuffers(1, buffer)
    gl.NamedBufferStorage(buffer^, int(size_of(T) * size), nil, storage_flags)
    mapped := gl.MapNamedBufferRange(buffer^, 0, int(size_of(T) * size), mapping_flags)
    when ODIN_DEBUG do gl.ObjectLabel(gl.BUFFER, buffer^, -1, label)
    return ([^]T)(mapped)
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
    w.exiting = false
    w.render_cap = RENDER_CAP
    queue.init(&w.mesh_results, allocator = context.allocator)

    storage_flags : u32 = gl.MAP_WRITE_BIT | gl.MAP_PERSISTENT_BIT
    mapping_flags : u32 = gl.MAP_WRITE_BIT | gl.MAP_PERSISTENT_BIT | gl.MAP_FLUSH_EXPLICIT_BIT
    w.cmds = create_mapped_buffer(&w.cmd_buffer, w.render_cap, storage_flags, mapping_flags, "Chunk_Batch_cmd_buf", gl.DrawArraysIndirectCommand)
    w.data = create_mapped_buffer(&w.data_buffer, w.render_cap, storage_flags, mapping_flags, "Chunk_Batch_data_buf", Per_Chunk_Data)
    w.mesh_faces = create_mapped_buffer(&w.mesh_buffer, MESH_BUFFER_FACES, storage_flags, mapping_flags, "Chunk_Mesh_buf", Chunk_Face)
    gl.CreateVertexArrays(1, &w.empty_vao)

    worker_init(&w.gen_thread, gen_thread_proc, w, 0)
    worker_init(&w.mesh_thread, mesh_thread_proc, w, MESH_SCRATCH_SIZE)

    for i := COL_HEIGHT - 1; i >= 0; i -= 1 {
        pos := ivec3{0, i32(i), 0}
        chunk := new(Chunk)

        chunk_init(chunk, pos, context.allocator)
        w.chunks[pos] = chunk
    }

    worker_push(&w.gen_thread, ivec2{0, 0})
    fmt.printf("world initialized\n")
}

world_render :: proc(w : ^World, vp : matrix[4, 4]f32) {
    sync.mutex_lock(&w.mesh_results_mu)
    for result in queue.pop_front_safe(&w.mesh_results) {
        chunk := get_chunk_unsafe(w, result.loc)
        if chunk == nil do continue
        gl.FlushMappedNamedBufferRange(w.mesh_buffer, int(result.handle.offset) * size_of(Chunk_Face), int(result.handle.count) * size_of(Chunk_Face))
        chunk.handle = result.handle
    }
    sync.mutex_unlock(&w.mesh_results_mu)

    w.render_count = 0
    for _, chunk in w.chunks {
        push_chunk(w, chunk)
    }

    if w.render_count > 0 {
        gl.FlushMappedNamedBufferRange(w.cmd_buffer, 0, int(w.render_count) * size_of(gl.DrawArraysIndirectCommand))
        gl.FlushMappedNamedBufferRange(w.data_buffer, 0, int(w.render_count) * size_of(Per_Chunk_Data))

        gl.Enable(gl.DEPTH_TEST)
        gl.Enable(gl.CULL_FACE)
        gl.CullFace(gl.BACK)
        gl.UseProgram(w.chunk_program)

        vp := vp
        gl.UniformMatrix4fv(0, 1, false, &vp[0, 0])

        gl.BindVertexArray(w.empty_vao)
        gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 0, w.mesh_buffer)
        gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 1, w.data_buffer)
        gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, w.cmd_buffer)
        gl.MultiDrawArraysIndirect(gl.TRIANGLES, nil, i32(w.render_count), 0)
    }

    for _, chunk in w.chunks {
        min_pos := chunk.pos * C_SIZE
        max_pos := min_pos + ivec3{C_SIZE, C_SIZE, C_SIZE}
        iml_bounds(vec3(min_pos), vec3(max_pos), 0xFFFFFF50)
    }
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
get_chunk_unsafe :: proc(world : ^World, pos : ivec3) -> ^Chunk {
    if pos.y < 0 || pos.y >= COL_HEIGHT do return nil
    if chunk, ok := world.chunks[pos]; ok {
        return chunk
    }
    return nil
}

@(private = "file")
gen_thread_proc :: proc(loc : ivec2, scratch : mem.Allocator, user_data : rawptr) {
    world := cast(^World)user_data

    for i := COL_HEIGHT - 1; i >= 0; i -= 1 {
        pos := ivec3{loc.x, i32(i), loc.y}
        chunk := get_chunk_unsafe(world, pos)
        fmt.printf("generating chunk %v\n", pos)

        if chunk == nil do break
        gen := rand.pcg_random_generator()

        for x in 0 ..< C_SIZE {
            for z in 0 ..< C_SIZE {
                for y in 0 ..< C_SIZE {
                    block := u8(rand.uint64(gen) >> 63)
                    chunk_set_block(chunk, i32(x), i32(y), i32(z), block)
                }
            }
        }

        // intrinsics.atomic_store(&chunk.spawn_state, Chunk_Spawn_State.Ready)
        if chunk.num_filled > 0 {
            worker_push(&world.mesh_thread, pos)
        }
    }
}

@(private = "file")
mesh_thread_proc :: proc(loc : ivec3, scratch : mem.Allocator, user_data : rawptr) {
    world := (^World)(user_data)

    chunk := get_chunk_unsafe(world, loc)
    if chunk == nil do return

    bytes, err := mem.alloc_bytes_non_zeroed(MAX_FACES * size_of(Chunk_Face), align_of(Chunk_Face), scratch)
    assert(err == nil, "mesh scratch arena too small")
    face_buffer := mem.slice_data_cast([]Chunk_Face, bytes)

    face_count := u32(chunk_generate_faces(chunk, face_buffer))
    fmt.printf("generated %v faces for chunk %v (block count: %v)\n", face_count, loc, chunk.num_filled)
    if face_count == 0 do return

    offset := sync.atomic_add(&world.mesh_used, face_count)
    if offset + face_count > MESH_BUFFER_FACES {
        fmt.printf("mesh buffer full, chunk %v not uploaded\n", loc)
        return
    }
    copy(world.mesh_faces[offset:][:face_count], face_buffer[:face_count])

    sync.mutex_lock(&world.mesh_results_mu)
    queue.push_back(&world.mesh_results, Mesh_Result{loc, {offset, face_count}})
    sync.mutex_unlock(&world.mesh_results_mu)
}
