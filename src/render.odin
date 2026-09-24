package main
import gl "vendor:OpenGL"
import "core:fmt"

RENDERER_GPU_DEBUG :: #config(RENDERER_GPU_DEBUG, ODIN_DEBUG)
RENDER_TARGET_COLOR_FORMAT :: gl.RGBA16F
RENDER_TARGET_DEPTH_FORMAT :: gl.DEPTH_COMPONENT32F

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
}

renderer_init :: proc(backbuffer_width, backbuffer_height : i32) -> bool {
    assert(!_ctx.initialized, "renderer_init called twice")

    gl.GetIntegerv(gl.MAX_DEBUG_GROUP_STACK_DEPTH, &_ctx.max_group_depth)
    gl.GetIntegerv(gl.MAX_DEBUG_MESSAGE_LENGTH, &_ctx.max_message_length)

    gl.CreateVertexArrays(1, &_ctx.empty_vao)
    when ODIN_DEBUG do gl.ObjectLabel(gl.VERTEX_ARRAY, _ctx.empty_vao, -1, "renderer_empty_vao")

    program, program_ok := load_program("blit", "../assets/blit.vert", "../assets/blit.frag")
    if !program_ok {
        gl.DeleteVertexArrays(1, &_ctx.empty_vao)
        _ctx.empty_vao = 0
        return false
    }
    _ctx.blit_program = program
    when ODIN_DEBUG do gl.ObjectLabel(gl.PROGRAM, _ctx.blit_program, -1, "renderer_blit_program")

    _ctx.initialized = true
    renderer_resize(backbuffer_width, backbuffer_height)
    return true
}

renderer_shutdown :: proc() {
    if !_ctx.initialized do return
    assert(!_ctx.in_frame, "renderer_shutdown called inside a frame")

    render_target_destroy(&_ctx.target)
    gl.DeleteProgram(_ctx.blit_program)
    gl.DeleteVertexArrays(1, &_ctx.empty_vao)
    _ctx = {}
}

renderer_resize :: proc(backbuffer_width, backbuffer_height : i32) {
    assert(_ctx.initialized, "renderer_resize called before renderer_init")
    assert(!_ctx.in_frame, "renderer_resize called inside a frame")

    _ctx.backbuffer_width = backbuffer_width
    _ctx.backbuffer_height = backbuffer_height

    if backbuffer_width <= 0 || backbuffer_height <= 0 do return
    if _ctx.target.width == backbuffer_width && _ctx.target.height == backbuffer_height do return

    render_target_destroy(&_ctx.target)
    _ctx.target = render_target_create(backbuffer_width, backbuffer_height)
}

renderer_begin_frame :: proc(clear_color := [4]f32{0.1, 0.1, 0.2, 1.0}) -> bool {
    assert(_ctx.initialized, "renderer_begin_frame called before renderer_init")
    assert(!_ctx.in_frame, "renderer_begin_frame called twice without renderer_end_frame")

    if _ctx.backbuffer_width <= 0 || _ctx.backbuffer_height <= 0 do return false

    gl.BindFramebuffer(gl.FRAMEBUFFER, _ctx.target.framebuffer)
    gl.Viewport(0, 0, _ctx.target.width, _ctx.target.height)

    gl.ColorMask(true, true, true, true)
    gl.DepthMask(true)
    gl.Enable(gl.DEPTH_TEST)
    gl.DepthFunc(gl.LESS)
    gl.Enable(gl.CULL_FACE)
    gl.CullFace(gl.BACK)
    gl.Disable(gl.BLEND)

    color := clear_color
    clear_depth : f32 = 1
    gl.ClearNamedFramebufferfv(_ctx.target.framebuffer, gl.COLOR, 0, &color[0])
    gl.ClearNamedFramebufferfv(_ctx.target.framebuffer, gl.DEPTH, 0, &clear_depth)

    _ctx.in_frame = true
    return true
}

renderer_end_frame :: proc() {
    renderer_assert_can_render()
    assert(_ctx.group_depth == 0, "renderer_end_frame called with unclosed render groups")

    {
        renderer_group("blit")

        gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
        gl.Viewport(0, 0, _ctx.backbuffer_width, _ctx.backbuffer_height)
        gl.Disable(gl.DEPTH_TEST)
        gl.Disable(gl.CULL_FACE)
        gl.Disable(gl.BLEND)

        gl.UseProgram(_ctx.blit_program)
        gl.BindTextureUnit(0, _ctx.target.color_texture)
        gl.BindVertexArray(_ctx.empty_vao)
        gl.DrawArrays(gl.TRIANGLES, 0, 3)
    }

    _ctx.in_frame = false
}


renderer_can_render :: proc() -> bool {
    return _ctx.in_frame
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
render_target_create :: proc(width, height : i32) -> (target : Render_Target) {
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
render_target_destroy :: proc(target : ^Render_Target) {
    gl.DeleteFramebuffers(1, &target.framebuffer)
    gl.DeleteTextures(1, &target.color_texture)
    gl.DeleteTextures(1, &target.depth_texture)
    target^ = {}
}
