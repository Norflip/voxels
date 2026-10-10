package main

import "core:container/queue"
import "core:mem"
import "core:sync"
import "core:thread"

Worker :: struct($T : typeid) {
    queue :       queue.Queue(T),
    mu :          sync.Mutex,
    sema :        sync.Sema,
    thread :      ^thread.Thread,
    callback :    proc(job : T, scratch : mem.Allocator, user_data : rawptr),
    user_data :   rawptr,
    scratch :     mem.Arena,
    scratch_buf : []byte,
    allocator :   mem.Allocator,
    shutdown :    b32,
}

worker_init :: proc(wt : ^Worker($T), callback : proc(job : T, scratch : mem.Allocator, user_data : rawptr), user_data : rawptr, scratch_size : int, name : Maybe(string) = nil, allocator := context.allocator) -> bool {
    assert(callback != nil)

    worker_loop :: proc(wt : ^Worker(T)) {
        scratch := mem.arena_allocator(&wt.scratch)
        for {
            sync.sema_wait(&wt.sema)
            if sync.atomic_load(&wt.shutdown) do break

            sync.mutex_lock(&wt.mu)
            job, ok := queue.pop_front_safe(&wt.queue)
            sync.mutex_unlock(&wt.mu)
            if !ok do continue

            wt.callback(job, scratch, wt.user_data)
            mem.arena_free_all(&wt.scratch)
        }
    }

    wt.allocator = allocator
    wt.callback = callback
    wt.user_data = user_data
    wt.shutdown = false

    if err := queue.init(&wt.queue, allocator = allocator); err != nil {
        return false
    }

    if scratch_size > 0 {
        buf, err := make([]byte, scratch_size, allocator)
        if err != nil {
            queue.destroy(&wt.queue)
            return false
        }
        wt.scratch_buf = buf
        mem.arena_init(&wt.scratch, wt.scratch_buf)
    }

    wt.thread = thread.create_and_start_with_poly_data(wt, worker_loop, name = name)
    if wt.thread == nil {
        delete(wt.scratch_buf, allocator)
        wt.scratch_buf = nil
        queue.destroy(&wt.queue)
        return false
    }
    return true
}

worker_join :: proc(wt : ^Worker($T)) {
    if wt.thread == nil do return
    sync.atomic_store(&wt.shutdown, true)
    sync.sema_post(&wt.sema)
    thread.join(wt.thread)
    thread.destroy(wt.thread)
    wt.thread = nil
}

worker_destroy :: proc(wt : ^Worker($T)) {
    worker_join(wt)
    queue.destroy(&wt.queue)
    delete(wt.scratch_buf, wt.allocator)
    wt.scratch_buf = nil
}

worker_push :: proc(wt : ^Worker($T), job : T) -> bool {
    sync.mutex_lock(&wt.mu)
    ok, _ := queue.push_back(&wt.queue, job)
    sync.mutex_unlock(&wt.mu)
    if ok {
        sync.sema_post(&wt.sema)
    }
    return ok
}
