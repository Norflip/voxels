package main
import "core:container/queue"
import "core:mem"
import "core:slice"
import "core:sync"
import gl "vendor:OpenGL"


Mesh_Handle :: struct {
    offset : u32,
    count :  u32,
}

@(private = "file")
Fence_Batch :: struct {
    fence : gl.sync_t,
    count : u32,
}

@(private = "file")
Page_Span :: struct {
    first, count : u32,
}

Vertex_Pool :: struct($T : typeid) {
    elems :        [^]T,
    buffer :       u32,
    page_size :    u32,
    page_count :   u32,
    mu :           sync.Mutex,
    used_mask :    []u64,
    free_pages :   u32,
    dirty :        [dynamic]Page_Span,
    pending_free : queue.Queue(Mesh_Handle),
    fences :       queue.Queue(Fence_Batch),
    unfenced :     u32,
    allocator :    mem.Allocator,
}

vertex_pool_init :: proc(pool : ^Vertex_Pool($T), size_bytes : int, page_size : u32, allocator := context.allocator) -> bool {
    if page_size == 0 do return false
    page_count := u32(size_bytes / size_of(T) / int(page_size))
    if page_count == 0 do return false

    storage_flags : u32 = gl.MAP_WRITE_BIT | gl.MAP_PERSISTENT_BIT
    mapping_flags : u32 = gl.MAP_WRITE_BIT | gl.MAP_PERSISTENT_BIT | gl.MAP_FLUSH_EXPLICIT_BIT
    pool.elems = create_mapped_buffer(&pool.buffer, page_count * page_size, storage_flags, mapping_flags, "Vertex_Pool_buf", T)
    if pool.elems == nil do return false

    word_count := int(page_count + 63) / 64
    mask, err := make([]u64, word_count, allocator)
    if err != nil {
        gl.DeleteBuffers(1, &pool.buffer)
        return false
    }

    if tail := page_count % 64; tail != 0 {
        mask[word_count - 1] = ~u64(0) << tail
    }

    pool.used_mask = mask
    pool.page_size = page_size
    pool.page_count = page_count
    pool.free_pages = page_count
    pool.unfenced = 0
    pool.allocator = allocator
    pool.dirty = make([dynamic]Page_Span, allocator)
    queue.init(&pool.pending_free, allocator = allocator)
    queue.init(&pool.fences, allocator = allocator)
    return true
}

vertex_pool_alloc :: proc(pool : ^Vertex_Pool($T), src : []T) -> (handle : Mesh_Handle, ok : bool) {
    count := u32(len(src))
    if count == 0 do return {}, true
    pages := (count + pool.page_size - 1) / pool.page_size

    first : u32
    {
        sync.mutex_guard(&pool.mu)
        if pages > pool.free_pages do return {}, false
        found : bool
        first, found = find_free_run(pool.used_mask, pages)
        if !found do return {}, false
        set_page_range(pool.used_mask, first, pages, true)
        pool.free_pages -= pages
    }

    offset := first * pool.page_size
    copy(pool.elems[offset:][:count], src)
    return Mesh_Handle{offset, count}, true
}

vertex_pool_free :: proc(pool : ^Vertex_Pool($T), handle : Mesh_Handle) {
    if handle.count == 0 do return
    queue.push_back(&pool.pending_free, handle)
    pool.unfenced += 1
}

vertex_pool_publish :: proc(pool : ^Vertex_Pool($T), handle : Mesh_Handle) {
    if handle.count == 0 do return
    append(&pool.dirty, Page_Span{handle.offset / pool.page_size, pages_for(pool, handle.count)})
}

vertex_pool_commit :: proc(pool : ^Vertex_Pool($T)) {
    flush_dirty_spans(pool)
    reclaim_signaled_pages(pool)

    fence_freed_handles(pool)
}

@(private = "file")
pages_for :: #force_inline proc(pool : ^Vertex_Pool($T), count : u32) -> u32 {
    return (count + pool.page_size - 1) / pool.page_size
}

@(private = "file")
flush_dirty_spans :: proc(pool : ^Vertex_Pool($T)) {
    if len(pool.dirty) == 0 do return
    slice.sort_by(pool.dirty[:], proc(a, b : Page_Span) -> bool {return a.first < b.first})

    page_bytes := int(pool.page_size) * size_of(T)
    cur := pool.dirty[0]
    for span in pool.dirty[1:] {
        if span.first <= cur.first + cur.count {
            cur.count = max(cur.count, span.first + span.count - cur.first)
            continue
        }
        gl.FlushMappedNamedBufferRange(pool.buffer, int(cur.first) * page_bytes, int(cur.count) * page_bytes)
        cur = span
    }
    gl.FlushMappedNamedBufferRange(pool.buffer, int(cur.first) * page_bytes, int(cur.count) * page_bytes)
    clear(&pool.dirty)
}

@(private = "file")
fence_freed_handles :: proc(pool : ^Vertex_Pool($T)) {
    if pool.unfenced == 0 do return
    fence := gl.FenceSync(gl.SYNC_GPU_COMMANDS_COMPLETE, 0)
    queue.push_back(&pool.fences, Fence_Batch{fence, pool.unfenced})
    pool.unfenced = 0
}

@(private = "file")
reclaim_signaled_pages :: proc(pool : ^Vertex_Pool($T)) -> (freed : u32) {
    for queue.len(pool.fences) > 0 {
        batch := queue.front(&pool.fences)
        status : i32
        gl.GetSynciv(batch.fence, gl.SYNC_STATUS, 1, nil, &status)
        if status != gl.SIGNALED do break

        queue.pop_front(&pool.fences)
        gl.DeleteSync(batch.fence)

        sync.mutex_guard(&pool.mu)
        for _ in 0 ..< batch.count {
            h := queue.pop_front(&pool.pending_free)
            pages := pages_for(pool, h.count)
            set_page_range(pool.used_mask, h.offset / pool.page_size, pages, false)
            pool.free_pages += pages
            freed += pages
        }
    }
    return
}

@(private = "file")
find_free_run :: proc(mask : []u64, pages : u32) -> (first : u32, ok : bool) {
    run_start, run_len : u32
    for word, wi in mask {
        base := u32(wi) * 64
        if word == ~u64(0) {
            run_len = 0
            continue
        }
        if word == 0 {
            if run_len == 0 do run_start = base
            run_len += 64
            if run_len >= pages do return run_start, true
            continue
        }
        for bit in u32(0) ..< 64 {
            if word & (u64(1) << bit) != 0 {
                run_len = 0
                continue
            }
            if run_len == 0 do run_start = base + bit
            run_len += 1
            if run_len >= pages do return run_start, true
        }
    }
    return 0, false
}

@(private = "file")
set_page_range :: proc(mask : []u64, first, count : u32, used : bool) {
    for page in first ..< first + count {
        bit := u64(1) << (page % 64)
        if used {
            assert(mask[page / 64] & bit == 0, "vertex pool page double alloc")
            mask[page / 64] |= bit
        } else {
            assert(mask[page / 64] & bit != 0, "vertex pool page double free")
            mask[page / 64] &~= bit
        }
    }
}
