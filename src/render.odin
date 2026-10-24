package main
import gl "vendor:OpenGL"
import "core:fmt"
import math "core:math/linalg/glsl"

RENDERER_GPU_DEBUG :: #config(RENDERER_GPU_DEBUG, ODIN_DEBUG)
RENDER_TARGET_COLOR_FORMAT :: gl.RGBA16F
RENDER_TARGET_DEPTH_FORMAT :: gl.DEPTH_COMPONENT32F


SUN_ROTATION_SPEED :: 0.02

Glyph_Quad :: struct #packed {
    pos_rect : vec4,
    uv_rect :  vec4,
    color :    u32,
    _pad :     [3]u32,
}

@(private = "file")
Render_Target :: struct {
    framebuffer :   u32,
    color_texture : u32,
    depth_texture : u32,
    width :         i32,
    height :        i32,
}

@(private = "file")
_ctx : struct {
    target :             Render_Target,
    blit_program :       u32,
    empty_vao :          u32,
    backbuffer_width :   i32,
    backbuffer_height :  i32,
    max_group_depth :    i32,
    max_message_length : i32,
    group_depth :        i32,
    in_frame :           bool,
    initialized :        bool,

    //
    skybox_program :     u32,
    sun_local_roll :     f32,
    sun_local_yaw :      f32,
    sun_orbit_axis :     math.quat,
}

@(private = "file")
g_active_camera : Camera

@(private = "file")
g_cull_camera : Camera

renderer_init :: proc(backbuffer_width, backbuffer_height : i32) -> bool {
    assert(!_ctx.initialized, "renderer_init called twice")

    gl.GetIntegerv(gl.MAX_DEBUG_GROUP_STACK_DEPTH, &_ctx.max_group_depth)
    gl.GetIntegerv(gl.MAX_DEBUG_MESSAGE_LENGTH, &_ctx.max_message_length)

    gl.CreateVertexArrays(1, &_ctx.empty_vao)
    when ODIN_DEBUG do gl.ObjectLabel(gl.VERTEX_ARRAY, _ctx.empty_vao, -1, "renderer_empty_vao")

    ok : bool

    _ctx.blit_program, ok = load_program("blit", "../assets/blit.vert", "../assets/blit.frag")
    if !ok {
        gl.DeleteVertexArrays(1, &_ctx.empty_vao)
        _ctx.empty_vao = 0
        return false
    }

    _ctx.skybox_program, ok = load_program("skybox", "../assets/sky.vert", "../assets/sky.frag")
    if !ok {
        fmt.eprintln("failed to load skybox shader")
        gl.DeleteVertexArrays(1, &_ctx.empty_vao)
        _ctx.empty_vao = 0
        return false
    }

    _ctx.sun_orbit_axis = math.quatAxisAngle({1, 0, 0}, f32(math.PI * 0.25)) * math.quatAxisAngle({0, 1, 0}, f32(math.PI * 0.75))
    _ctx.initialized = true
    _ctx.backbuffer_width = backbuffer_width
    _ctx.backbuffer_height = backbuffer_height
    _ctx.target = rt_create(backbuffer_width, backbuffer_height)

    ui_init(backbuffer_width, backbuffer_height)
    clouds_init()
    return true
}

renderer_shutdown :: proc() {
    if !_ctx.initialized do return
    assert(!_ctx.in_frame, "renderer_shutdown called inside a frame")

    rt_destroy(&_ctx.target)
    gl.DeleteProgram(_ctx.blit_program)
    gl.DeleteProgram(_ctx.skybox_program)
    gl.DeleteVertexArrays(1, &_ctx.empty_vao)
    ui_cleanup()
    _ctx = {}
}

renderer_resize :: proc(backbuffer_width, backbuffer_height : i32) {
    assert(_ctx.initialized, "renderer_resize called before renderer_init")
    assert(!_ctx.in_frame, "renderer_resize called inside a frame")

    _ctx.backbuffer_width = backbuffer_width
    _ctx.backbuffer_height = backbuffer_height

    if backbuffer_width <= 0 || backbuffer_height <= 0 do return
    if _ctx.target.width == backbuffer_width && _ctx.target.height == backbuffer_height do return

    rt_destroy(&_ctx.target)
    _ctx.target = rt_create(backbuffer_width, backbuffer_height)
    ui_resize(backbuffer_width, backbuffer_height)
}

renderer_begin_frame :: proc(cam, cull_cam : Camera, dt : f32) -> bool {
    assert(_ctx.initialized, "renderer_begin_frame called before renderer_init")
    assert(!_ctx.in_frame, "renderer_begin_frame called twice without renderer_end_frame")

    if _ctx.backbuffer_width <= 0 || _ctx.backbuffer_height <= 0 do return false
    g_active_camera = cam
    g_cull_camera = cull_cam

    gl.BindFramebuffer(gl.FRAMEBUFFER, _ctx.target.framebuffer)
    gl.Viewport(0, 0, _ctx.target.width, _ctx.target.height)

    gl.ColorMask(true, true, true, true)
    gl.DepthMask(true)
    gl.Enable(gl.DEPTH_TEST)
    gl.DepthFunc(gl.LESS)
    gl.Enable(gl.CULL_FACE)
    gl.CullFace(gl.BACK)
    gl.Disable(gl.BLEND)

    clear_depth : f32 = 1
    gl.ClearNamedFramebufferfv(_ctx.target.framebuffer, gl.DEPTH, 0, &clear_depth)
    // no need if we are rendering a skybox on top
    //gl.ClearNamedFramebufferfv(_ctx.target.framebuffer, gl.COLOR, 0, &color[0])

    _ctx.sun_local_roll += dt * SUN_ROTATION_SPEED
    _ctx.sun_local_roll = math.mod(_ctx.sun_local_roll, math.TAU)
    _ctx.sun_local_yaw += dt * SUN_ROTATION_SPEED * 0.5
    _ctx.sun_local_yaw = math.mod(_ctx.sun_local_yaw, math.TAU)

    _ctx.in_frame = true
    return true
}

renderer_end_frame :: proc(draw_text : bool = true) {
    renderer_assert_can_render()
    assert(_ctx.group_depth == 0, "renderer_end_frame called with unclosed render groups")

    renderer_bind_empty_vao()


    orbit_axis := cast(mat3)math.mat4FromQuat(math.normalize(_ctx.sun_orbit_axis))
    spin := math.quatAxisAngle({0, 1, 0}, _ctx.sun_local_yaw) * math.quatAxisAngle({1, 0, 1}, _ctx.sun_local_roll)
    sun_to_local := math.transpose(orbit_axis * cast(mat3)math.mat4FromQuat(math.normalize(spin)))
    {
        renderer_group("skybox")
        gl.DepthFunc(gl.LEQUAL)
        gl.DepthMask(false)
        gl.Disable(gl.CULL_FACE)
        gl.UseProgram(_ctx.skybox_program)

        inv_proj := g_active_camera.inv_proj
        view := g_active_camera.view
        gl.UniformMatrix4fv(0, 1, gl.FALSE, raw_data(&inv_proj))
        gl.UniformMatrix4fv(1, 1, gl.FALSE, raw_data(&view))

        gl.UniformMatrix3fv(2, 1, false, raw_data(&orbit_axis))
        gl.UniformMatrix3fv(3, 1, false, raw_data(&sun_to_local))

        gl.DrawArrays(gl.TRIANGLES, 0, 3)
        gl.DepthMask(true)
        gl.DepthFunc(gl.LESS)
        gl.Enable(gl.CULL_FACE)
    }

    clouds_render(g_active_camera, g_cull_camera, orbit_axis, sun_to_local)

    {
        renderer_group("blit")

        gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
        gl.Viewport(0, 0, _ctx.backbuffer_width, _ctx.backbuffer_height)
        gl.Disable(gl.DEPTH_TEST)
        gl.Disable(gl.CULL_FACE)
        gl.Disable(gl.BLEND)

        gl.UseProgram(_ctx.blit_program)
        gl.BindTextureUnit(0, _ctx.target.color_texture)
        gl.DrawArrays(gl.TRIANGLES, 0, 3)
    }

    if draw_text {
        ui_render()
    } else {

    }

    _ctx.in_frame = false
}


renderer_can_render :: proc() -> bool {
    return _ctx.in_frame
}

renderer_sun_mat :: proc() -> mat3 {
    return cast(mat3)math.mat4FromQuat(_ctx.sun_orbit_axis)
}

renderer_assert_can_render :: proc(loc := #caller_location) {
    assert(_ctx.in_frame, "render call made outside renderer_begin_frame/renderer_end_frame", loc)
}

@(deferred_out = renderer_end_group)
renderer_group :: proc(name : string, loc := #caller_location) -> (pushed : bool) {
    return renderer_begin_group(name)
}

renderer_begin_group :: proc(name : string, loc := #caller_location) -> (pushed : bool) {
    renderer_assert_can_render(loc)

    when RENDERER_GPU_DEBUG {
        assert(_ctx.group_depth < _ctx.max_group_depth, "render group stack overflow", loc)
        assert(i32(len(name)) < _ctx.max_message_length, "render group name too long", loc)

        gl.PushDebugGroup(gl.DEBUG_SOURCE_APPLICATION, 0, i32(len(name)), cstring(raw_data(name)))
        _ctx.group_depth += 1
        pushed = true
    }
    return
}

renderer_end_group :: proc(pushed : bool) {
    if !pushed do return
    gl.PopDebugGroup()
    _ctx.group_depth -= 1
}

renderer_bind_empty_vao :: proc() {
    gl.BindVertexArray(_ctx.empty_vao)
}

@(private = "file")
rt_create :: proc(width, height : i32) -> (target : Render_Target) {
    target.width = width
    target.height = height

    gl.CreateTextures(gl.TEXTURE_2D, 1, &target.color_texture)
    gl.TextureStorage2D(target.color_texture, 1, RENDER_TARGET_COLOR_FORMAT, width, height)
    when ODIN_DEBUG do gl.ObjectLabel(gl.TEXTURE, target.color_texture, -1, "render_target_color")

    gl.CreateTextures(gl.TEXTURE_2D, 1, &target.depth_texture)
    gl.TextureStorage2D(target.depth_texture, 1, RENDER_TARGET_DEPTH_FORMAT, width, height)
    when ODIN_DEBUG do gl.ObjectLabel(gl.TEXTURE, target.depth_texture, -1, "render_target_depth")

    gl.CreateFramebuffers(1, &target.framebuffer)
    gl.NamedFramebufferTexture(target.framebuffer, gl.COLOR_ATTACHMENT0, target.color_texture, 0)
    gl.NamedFramebufferTexture(target.framebuffer, gl.DEPTH_ATTACHMENT, target.depth_texture, 0)
    when ODIN_DEBUG do gl.ObjectLabel(gl.FRAMEBUFFER, target.framebuffer, -1, "render_target")

    status := gl.CheckNamedFramebufferStatus(target.framebuffer, gl.FRAMEBUFFER)
    if status != gl.FRAMEBUFFER_COMPLETE {
        panic("render target framebuffer incomplete")
    }
    return
}

@(private = "file")
rt_destroy :: proc(target : ^Render_Target) {
    gl.DeleteFramebuffers(1, &target.framebuffer)
    gl.DeleteTextures(1, &target.color_texture)
    gl.DeleteTextures(1, &target.depth_texture)
    target^ = {}
}

/*
@(private = "file")
init_text :: proc() {
    ok : bool
    _ctx.program, ok = load_program("text", "../assets/text.vert", "../assets/text.frag")
    if !ok do return

    gl.CreateBuffers(1, &_ctx.quads)
    gl.NamedBufferStorage(_ctx.quads, UI_MAX_QUADS * size_of(Glyph_Quad), nil, gl.DYNAMIC_STORAGE_BIT)
    when ODIN_DEBUG do gl.ObjectLabel(gl.BUFFER, _ctx.quads, -1, "text_quad_buffer")
    _ctx.proj_u_loc = gl.GetUniformLocation(_ctx.program, "u_proj")

    pixels : [FONT_TEX_WIDTH * FONT_TEX_HEIGHT * 4]u8
    for i in 0 ..< 96 {
        tx := (i % FONT_TEX_COLS) * FONT_WIDTH
        ty := (i / FONT_TEX_COLS) * FONT_HEIGHT

        char_data := FONT_DATA[i]
        for x in 0 ..< FONT_WIDTH {
            column := char_data[x]
            for y in 0 ..< 8 {
                idx := ((ty + y) * FONT_TEX_WIDTH + (tx + x)) * 4
                v : u8 = ((column >> u32(y)) & 1) == 1 ? 0xFF : 0x00
                pixels[idx + 0] = v
                pixels[idx + 1] = v
                pixels[idx + 2] = v
                pixels[idx + 3] = v
            }
        }
    }

    tex : u32
    gl.CreateTextures(gl.TEXTURE_2D, 1, &tex)
    gl.TextureParameteri(tex, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
    gl.TextureParameteri(tex, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
    gl.TextureParameteri(tex, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
    gl.TextureParameteri(tex, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
    gl.TextureStorage2D(tex, 1, gl.RGBA8, FONT_TEX_WIDTH, FONT_TEX_HEIGHT)
    gl.TextureSubImage2D(tex, 0, 0, 0, FONT_TEX_WIDTH, FONT_TEX_HEIGHT, gl.RGBA, gl.UNSIGNED_BYTE, &pixels)
    _ctx.font_tex = tex
    when ODIN_DEBUG do gl.ObjectLabel(gl.TEXTURE, _ctx.font_tex, -1, "font_tex")

    _ctx.proj = math.mat4Ortho3d(0.0, f32(_ctx.backbuffer_width), f32(_ctx.backbuffer_height), 0.0, -1.0, 1.0)
    _ctx.quad_count = 0
    _ctx.initialized = true
}
*/
