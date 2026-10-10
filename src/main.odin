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

    //opengl
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
    world_init(&world, 0x123, false)
    // defer world_shutdown(&world)

    player_init(&g_player, world_get_player_spawn(&world), window)

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


        toff :: #force_inline proc(i : int) -> int {return 10 + 20 * i}

        text_area(10, 10, 4, 20)
        textln("voxels")
        textln("%.0f fps | %.2f ms avg | %.2f ms worst", fps, avg_ms, fps_worst_dt * 1000)
        textln("--------------------------------")
        textln("seed: %d", world.seed)
        textln("load radius: %d", world.load_radius)
        textln("frozen: %v", g_is_frozen)
        textln("player pos: [%v %v %v]", int(g_player.pos.x), int(g_player.pos.y), int(g_player.pos.z))
        textln("--------------------------------")
        textln("m total allocated: %d (%d KB, %d MB)\n", g_tracking_allocator.total_memory_allocated, g_tracking_allocator.total_memory_allocated / 1024, g_tracking_allocator.total_memory_allocated / (1024 * 1024))
        textln("m total freed:     %d (%d KB, %d MB)\n", g_tracking_allocator.total_memory_freed, g_tracking_allocator.total_memory_freed / 1024, g_tracking_allocator.total_memory_freed / (1024 * 1024))
        textln("m peak allocated:  %d (%d KB, %d MB)\n", g_tracking_allocator.peak_memory_allocated, g_tracking_allocator.peak_memory_allocated / 1024, g_tracking_allocator.peak_memory_allocated / (1024 * 1024))
        textln("--------------------------------")

        textln(
            "vertex pool utilization: %d/%d [%.2f%%]",
            world.vertex_pool.page_count - world.vertex_pool.free_pages,
            world.vertex_pool.page_count,
            f32(world.vertex_pool.page_count - world.vertex_pool.free_pages) / f32(world.vertex_pool.page_count) * 100,
        )

        if renderer_begin_frame(g_player.camera) {
            face_count := world_render(&world, g_player.camera, g_is_frozen ? g_frozen_cam : g_player.camera, draw_lines = true)
            textln("face count: %d", face_count)
            textln("chunk count: %d", world.chunk_count)

            if g_is_frozen {
                iml_frustum(g_frozen_cam, 0xFF0000FF)
            }


            if g_draw_lines {
                iml_render(g_player.camera.view_proj)
            } else {
                iml_clear()
            }

            renderer_end_frame()
        }

        glfw.SwapBuffers(window)
    }
}

Text_Area :: struct {
    x :    int,
    y :    int,
    pad :  int,
    size : int,
}

@(private = "file")
text_area_inst : Text_Area = Text_Area{0, 0, 0, 16}

@(private = "file")
text_area :: #force_inline proc(x, y, padding : int, size : int = 16) {
    text_area_inst = Text_Area{x, y, padding, size}
}

@(private = "file")
textln :: #force_inline proc(fmt_str : string, args : ..any, color : u32 = WHITE) {
    text(text_area_inst.x, text_area_inst.y, fmt_str, ..args, size = text_area_inst.size, color = color)
    text_area_inst.y += text_area_inst.pad + text_area_inst.size
}

@(private = "file")
block_interaction :: proc(p : Player, w : ^World) {
    xpos, ypos := glfw.GetCursorPos(p.window)
    eye, dir, ok := camera_get_ray(p.camera, xpos, ypos)

    if !ok do return

    hit : World_Hit
    if !world_trace(w, eye, dir, 20.0, &hit) do return

    pos := vec3{f32(hit.pos.x) + 0.5, f32(hit.pos.y) + 0.5, f32(hit.pos.z) + 0.5}

    if glfw.GetKey(p.window, glfw.KEY_LEFT_SHIFT) == glfw.PRESS {
        offp := hit.pos + hit.normal
        iml_box(vec3{f32(offp.x) + 0.5, f32(offp.y) + 0.5, f32(offp.z) + 0.5}, vec3{1.0, 1.0, 1.0}, 0xFF0000FF)
        if mouse_pressed[glfw.MOUSE_BUTTON_LEFT] {
            world_set_block(w, offp, .Stone)
        }
    } else {
        iml_box(pos, vec3{1.0, 1.0, 1.0}, 0xFF0000FF)
        if mouse_pressed[glfw.MOUSE_BUTTON_LEFT] {
            world_set_block(w, hit.pos, .Air)
        }
    }

    iml_box(hit.world_pos, vec3{0.1, 0.1, 0.1}, 0xFF0000FF)
    iml_line(pos, pos + vec3{f32(hit.normal.x), f32(hit.normal.y), f32(hit.normal.z)}, 0xFF00FFFF)
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

    if (key == glfw.KEY_F1 && action == glfw.PRESS) {
        g_is_frozen = !g_is_frozen
        if g_is_frozen {
            g_frozen_cam = camera_snapshot(g_player.camera)
        }
    }

    if key == glfw.KEY_F2 && action == glfw.PRESS {
        g_draw_lines = !g_draw_lines
    }
}
