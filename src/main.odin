package main
import "core:fmt"
import "core:mem"
import "core:os"
import "base:runtime"
import "core:strings"

import glfw "vendor:glfw"
import gl "vendor:OpenGL"

GL_VERSION_MAJOR :: 4
GL_VERSION_MINOR :: 6

WINDOW_ASPECT :: f32(6.0 / 5.0)
WINDOW_MONITOR_FACTOR :: f32(0.75)

g_player : Player
g_is_frozen : bool
g_frozen_cam : Camera

MOUSE_BUTTON_COUNT :: glfw.MOUSE_BUTTON_LAST + 1
mouse_pressed : [MOUSE_BUTTON_COUNT]bool

g_tracking_allocator : mem.Tracking_Allocator
g_draw_lines : bool = true
g_draw_text : bool = true
g_selected_block : i32 = 0

@(private = "file")
@(rodata)
g_available_blocks : []Block = {.Stone, .Mantle, .Dirt, .Grass, .Sand, .Log, .Leaves}

main :: proc() {
    when ODIN_DEBUG {
        backing := context.allocator
        mem.tracking_allocator_init(&g_tracking_allocator, backing)
        context.allocator = mem.tracking_allocator(&g_tracking_allocator)
        defer {
            mem.tracking_allocator_destroy(&g_tracking_allocator)
        }
    }

    glfw.SetErrorCallback(glfw_err_callback)
    if !glfw.Init() {
        fmt.println("Failed to initialize GLFW")
        return
    }

    glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, GL_VERSION_MAJOR)
    glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, GL_VERSION_MINOR)
    glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)

    monitor := glfw.GetPrimaryMonitor()
    mode := glfw.GetVideoMode(monitor)
    window_height := i32(f32(mode.height) * WINDOW_MONITOR_FACTOR)
    window_width := i32(f32(window_height) * WINDOW_ASPECT)

    window := glfw.CreateWindow(window_width, window_height, " ", nil, nil)
    defer glfw.Terminate()

    if window == nil {
        fmt.println("Failed to create GLFW window")
        return
    }

    glfw.MakeContextCurrent(window)
    glfw.SwapInterval(0)
    glfw.SetMouseButtonCallback(window, input_mouse_button_callback)
    glfw.SetKeyCallback(window, input_key_callback)
    glfw.SetFramebufferSizeCallback(window, glfw_framebuffer_size_callback)

    //opengl stuff
    gl.load_up_to(GL_VERSION_MAJOR, GL_VERSION_MINOR, glfw.gl_set_proc_address)
    gl.ClipControl(gl.LOWER_LEFT, gl.ZERO_TO_ONE)

    gl.Enable(gl.DEBUG_OUTPUT)
    gl.Enable(gl.DEBUG_OUTPUT_SYNCHRONOUS)
    gl.DebugMessageCallback(gl_err_callback, nil)
    gl.DebugMessageControl(gl.DONT_CARE, gl.DONT_CARE, gl.DEBUG_SEVERITY_NOTIFICATION, 0, nil, gl.FALSE)

    renderer_init(window_width, window_height)
    defer renderer_shutdown()

    iml_init()
    defer iml_cleanup()

    world : World
    world_init(&world, 0x123, 8, {})
    // defer world_shutdown(&world)

    player_init(&g_player, world_get_player_spawn(&world), window)
    block_init()

    fps_frames := 0
    fps_elapsed := 0.0
    fps_worst_dt := 0.0
    t1 := glfw.GetTime()

    fps : f64 = 0.0
    avg_ms : f64 = 0.0

    for glfw.WindowShouldClose(window) == false {
        free_all(context.temp_allocator)

        mouse_pressed = {}
        glfw.PollEvents()

        t2 := glfw.GetTime()
        dt := t2 - t1
        t1 = t2

        fps_frames += 1
        fps_elapsed += dt
        fps_worst_dt = max(fps_worst_dt, dt)
        if fps_elapsed >= 0.5 {
            fps = f64(fps_frames) / fps_elapsed
            avg_ms = fps_elapsed * 1000 / f64(fps_frames)
            fps_frames = 0
            fps_elapsed = 0
            fps_worst_dt = 0
        }

        player_tick(&g_player, &world, f32(dt))
        block_interaction(g_player, &world)

        ui_area(10, 10, 4, 16)
        ui_textln("voxels")
        ui_textln("%.0f fps | %.2f ms avg | %.2f ms worst", fps, avg_ms, fps_worst_dt * 1000)
        ui_textln("--------------------------------")
        ui_textln("seed: %d", world.seed)
        ui_textln("load radius: %d", world.load_radius)
        ui_textln("frozen: %v", g_is_frozen)

        pc := player_world_coord(g_player)
        ui_textln("player pos: %v", pc)

        chunk_l, chunk_local_l := modiv_world_chunk_local(pc)
        ui_textln("chunk: %v | local: %v", chunk_l, chunk_local_l)

        hunk_l, chunk_hunk_l := modiv_world_hunk_local(pc)
        ui_textln("hunk: %v | local: %v", hunk_l, chunk_hunk_l)

        ui_textln("== active hunks ==")
        for hunk_pos, hunk_ptr in world.hunks {
            ui_textln("\thunk pos: %v | cols count: %d", hunk_pos, hunk_ptr.cols_count)
        }

        biome, bok := world_get_biome(&world, pc.x, pc.z)
        ui_textln("biome: %v | ok: %v", biome, bok)

        ui_textln("--------------------------------")
        ui_textln("m total allocated: %d (%d KB, %d MB)", g_tracking_allocator.total_memory_allocated, g_tracking_allocator.total_memory_allocated / 1024, g_tracking_allocator.total_memory_allocated / (1024 * 1024))
        ui_textln("m total freed:     %d (%d KB, %d MB)", g_tracking_allocator.total_memory_freed, g_tracking_allocator.total_memory_freed / 1024, g_tracking_allocator.total_memory_freed / (1024 * 1024))
        ui_textln("m peak allocated:  %d (%d KB, %d MB)", g_tracking_allocator.peak_memory_allocated, g_tracking_allocator.peak_memory_allocated / 1024, g_tracking_allocator.peak_memory_allocated / (1024 * 1024))
        ui_textln("--------------------------------")

        ui_textln(
            "vertex pool utilization: %d/%d [%.2f%%]",
            world.vertex_pool.page_count - world.vertex_pool.free_pages,
            world.vertex_pool.page_count,
            f32(world.vertex_pool.page_count - world.vertex_pool.free_pages) / f32(world.vertex_pool.page_count) * 100,
        )

        selection_toolbar(g_player.camera.width, g_player.camera.height, g_selected_block, g_block_atlas)

        /*
        // heightmap test
        HEIGHTMAP_RADIUS :: 12
        for hz := -HEIGHTMAP_RADIUS; hz <= HEIGHTMAP_RADIUS; hz += 1 {
            for hx := -HEIGHTMAP_RADIUS; hx <= HEIGHTMAP_RADIUS; hx += 1 {
                hx_world := pc.x + i32(hx)
                hz_world := pc.z + i32(hz)
                height, hok := world_get_height(&world, hx_world, hz_world)
                if hok {
                    pos := vec3{f32(hx_world), f32(height) + 0.5 + 0.2, f32(hz_world)} + 0.5
                    iml_box(pos, vec3{0.15, 0.15, 0.15}, RED)
                }
            }
        }
        */

        cull_cam := g_is_frozen ? g_frozen_cam : g_player.camera
        if renderer_begin_frame(g_player.camera, cull_cam, f32(dt)) {
            face_count := world_render(&world, g_player.camera, cull_cam, draw_lines = true)
            ui_textln("face count: %d", face_count)
            ui_textln("chunk count: %d", world.visible_chunk_count)

            if g_is_frozen do iml_frustum(g_frozen_cam, 0xFF0000FF)
            if g_draw_lines {
                iml_render(g_player.camera.view_proj)
            } else {
                iml_clear()
            }

            renderer_end_frame(g_draw_text)
        }

        glfw.SwapBuffers(window)
    }
}

selection_toolbar :: proc(width, height : i32, selected : i32, atlas : Atlas) {

    SLOT :: 72
    PAD :: 6
    SELECTED_OFFSET :: 16
    SELECTED_SCALE :: 1.1

    n := i32(len(g_available_blocks))
    bar_w := n * SLOT + (n + 1) * PAD
    bar_h := i32(SLOT + 2 * PAD)
    bar_x := (width - bar_w) / 2

    bot_padding := i32(32)
    bar_y := height - bar_h - bot_padding

    for block, i in g_available_blocks {
        sx := f32(bar_x + PAD + i32(i) * (SLOT + PAD))
        sy := f32(bar_y + PAD)
        size := f32(SLOT)

        if i32(i) == selected do sy -= SELECTED_OFFSET
        index := block_get_preview_atlas_index(block)
        if index < 0 do continue
        ui_rect_atlas(f32(sx), f32(sy), size, size, atlas, u32(index))
    }
}

@(private = "file")
block_interaction :: proc(p : Player, w : ^World) {
    xpos, ypos := glfw.GetCursorPos(p.window)
    eye, dir, ok := camera_get_ray(p.camera, xpos, ypos)

    if !ok do return

    hit : World_Hit
    if !world_trace(w, eye, dir, 20.0, &hit) do return

    if mouse_pressed[glfw.MOUSE_BUTTON_MIDDLE] {
        // why does this not run?
        fmt.printf("hit.block: %v\n", hit.block)
        for b, i in g_available_blocks {
            if b == hit.block {
                g_selected_block = i32(i)
                break
            }
        }
    } else if glfw.GetKey(p.window, glfw.KEY_LEFT_SHIFT) == glfw.PRESS {
        pos := vec3{f32(hit.pos.x) + 0.5, f32(hit.pos.y) + 0.5, f32(hit.pos.z) + 0.5}
        iml_box(pos, vec3{1.0, 1.0, 1.0}, 0xFF0000FF)
        iml_line(pos, pos + vec3{f32(hit.normal.x), f32(hit.normal.y), f32(hit.normal.z)}, 0xFF00FFFF)

        if mouse_pressed[glfw.MOUSE_BUTTON_LEFT] {
            world_set_block(w, hit.pos, .Air)
        }
    } else {
        offp := hit.pos + hit.normal
        iml_box(vec3{f32(offp.x) + 0.5, f32(offp.y) + 0.5, f32(offp.z) + 0.5}, vec3{1.0, 1.0, 1.0}, 0xFF0000FF)
        if g_selected_block >= 0 && g_selected_block < i32(len(g_available_blocks)) && mouse_pressed[glfw.MOUSE_BUTTON_LEFT] {
            world_set_block(w, offp, g_available_blocks[g_selected_block])
        }
    }

    iml_box(hit.world_pos, vec3{0.1, 0.1, 0.1}, 0xFF0000FF)
}


@(private = "file")
glfw_err_callback :: proc "c" (error : i32, description : cstring) {
    context = runtime.default_context()
    desc := string(description)
    //if error == glfw.INVALID_VALUE && strings.contains(desc, "gamepad mapping") do return

    fmt.eprintfln("[GLFW] [%d]: %s", error, desc)
}

@(private = "file")
gl_err_callback :: proc "c" (source : u32, type : u32, id : u32, severity : u32, length : i32, message : cstring, userParam : rawptr) {
    context = runtime.default_context()
    fmt.eprintf("[GL] %s\n", message)
    os.exit(-1)
}

@(private = "file")
glfw_framebuffer_size_callback :: proc "c" (window : glfw.WindowHandle, width, height : i32) {
    context = runtime.default_context()
    renderer_resize(width, height)
    player_resize_view(&g_player, width, height)
}

@(private = "file")
input_mouse_button_callback :: proc "c" (window : glfw.WindowHandle, button, action, mods : i32) {
    if button < 0 || int(button) >= MOUSE_BUTTON_COUNT do return
    if glfw.PRESS == action {
        mouse_pressed[button] = true
    }
}

@(private = "file")
input_key_callback :: proc "c" (window : glfw.WindowHandle, key, scancode, action, mods : i32) {
    if key == glfw.KEY_ESCAPE && action == glfw.PRESS {
        glfw.SetWindowShouldClose(window, true)
    }

    // check 1-9 numbers
    if action == glfw.PRESS {
        if key >= glfw.KEY_1 && key <= glfw.KEY_9 {
            g_selected_block = key - glfw.KEY_1
        }
    }

    if (key == glfw.KEY_F1 && action == glfw.PRESS) {
        g_is_frozen = !g_is_frozen
        if g_is_frozen {
            g_frozen_cam = g_player.camera
        }
    }

    if key == glfw.KEY_F2 && action == glfw.PRESS {
        g_draw_lines = !g_draw_lines
    }

    if key == glfw.KEY_F3 && action == glfw.PRESS {
        g_draw_text = !g_draw_text
    }
}
