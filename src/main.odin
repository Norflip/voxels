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
    winheight := i32(f32(mode.height) * WINDOW_MONITOR_FACTOR)
    winwidth := i32(f32(winheight) * WINDOW_ASPECT)

    window := glfw.CreateWindow(winwidth, winheight, " ", nil, nil)
    defer glfw.Terminate()

    if window == nil {
        fmt.println("Failed to create GLFW window")
        return
    }

    glfw.MakeContextCurrent(window)
    glfw.SwapInterval(0)

    //opengl
    gl.load_up_to(GL_VERSION_MAJOR, GL_VERSION_MINOR, glfw.gl_set_proc_address)
    gl.ClipControl(gl.LOWER_LEFT, gl.ZERO_TO_ONE)

    gl.Enable(gl.DEBUG_OUTPUT)
    gl.Enable(gl.DEBUG_OUTPUT_SYNCHRONOUS)
    gl.DebugMessageCallback(gl_err_callback, nil)
    gl.DebugMessageControl(gl.DONT_CARE, gl.DONT_CARE, gl.DEBUG_SEVERITY_NOTIFICATION, 0, nil, gl.FALSE)

    iml_init()
    world : World
    world_init(&world)

    player : Player
    player_init(&player, vec3{0, 0, 3}, window)

    fps_frames := 0
    fps_elapsed := 0.0
    fps_worst_dt := 0.0
    t1 := glfw.GetTime()

    for glfw.WindowShouldClose(window) == false {
        free_all(context.temp_allocator)
        glfw.PollEvents()

        t2 := glfw.GetTime()
        dt := t2 - t1
        t1 = t2

        fps_frames += 1
        fps_elapsed += dt
        fps_worst_dt = max(fps_worst_dt, dt)
        if fps_elapsed >= 0.5 {
            fps := f64(fps_frames) / fps_elapsed
            avg_ms := fps_elapsed * 1000 / f64(fps_frames)
            title := fmt.ctprintf("%.0f fps | %.2f ms avg | %.2f ms worst", fps, avg_ms, fps_worst_dt * 1000)
            glfw.SetWindowTitle(window, title)

            fps_frames = 0
            fps_elapsed = 0
            fps_worst_dt = 0
        }

        player_tick(&player, f32(dt))

        gl.Viewport(0, 0, winwidth, winheight)
        gl.ClearColor(0.1, 0.1, 0.2, 1.0)
        gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)

        world_render(&world, player.view_proj)

        iml_render(player.view_proj)
        glfw.SwapBuffers(window)
    }
}

glfw_err_callback :: proc "c" (error : i32, description : cstring) {
    context = runtime.default_context()

    desc := string(description)
    //if error == glfw.INVALID_VALUE && strings.contains(desc, "gamepad mapping") do return

    fmt.eprintfln("[GLFW] [%d]: %s", error, desc)
}

gl_err_callback :: proc "c" (source : u32, type : u32, id : u32, severity : u32, length : i32, message : cstring, userParam : rawptr) {
    context = runtime.default_context()
    fmt.eprintf("[GL] %s\n", message)
    os.exit(-1)
}
