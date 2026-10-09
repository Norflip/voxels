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

MOUSE_BUTTON_COUNT :: glfw.MOUSE_BUTTON_LAST + 1
mouse_pressed : [MOUSE_BUTTON_COUNT]bool

main :: proc() {
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
    world_init(&world)
    //defer world_shutdown(&world)

    player : Player
    player_init(&player, vec3{C_SIZE / 2, BASE_HEIGHT + HEIGHT_AMPLITUDE, C_SIZE / 2}, window)

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

        player_tick(&player, &world, f32(dt))
        block_interaction(player, &world)

        text(10, 10, "voxels")
        //text(10, 30, "fps: %.2f", fps_elapsed > 0 ? f64(fps_frames) / fps_elapsed : 0)
        text(10, 30, "%.0f fps | %.2f ms avg | %.2f ms worst", fps, avg_ms, fps_worst_dt * 1000)
        text(
            10,
            50,
            "vertex pool utilization: %d / %d %.2f%%",
            world.vertex_pool.page_count - world.vertex_pool.free_pages,
            world.vertex_pool.page_count,
            f32(world.vertex_pool.page_count - world.vertex_pool.free_pages) / f32(world.vertex_pool.page_count) * 100,
        )

        if renderer_begin_frame() {
            face_count := world_render(&world, player.view_proj, draw_lines = true)
            text(10, 70, "face count: %d", face_count)

            iml_render(player.view_proj)
            renderer_end_frame()
        }

        glfw.SwapBuffers(window)
    }
}

@(private = "file")
block_interaction :: proc(p : Player, w : ^World) {
    xpos, ypos := glfw.GetCursorPos(p.window)
    eye, dir, ok := player_get_ray(p, xpos, ypos)

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
}
