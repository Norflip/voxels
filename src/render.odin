package main
import gl "vendor:OpenGL"
import "core:fmt"
import math "core:math/linalg/glsl"

RENDERER_GPU_DEBUG :: #config(RENDERER_GPU_DEBUG, ODIN_DEBUG)
RENDER_TARGET_COLOR_FORMAT :: gl.RGBA16F
RENDER_TARGET_DEPTH_FORMAT :: gl.DEPTH_COMPONENT32F

FONT_WIDTH :: 5
FONT_HEIGHT :: 8

FONT_TEX_COLS :: 8
FONT_TEX_ROWS :: 96 / FONT_TEX_COLS
FONT_TEX_WIDTH :: FONT_TEX_COLS * FONT_WIDTH
FONT_TEX_HEIGHT :: FONT_TEX_ROWS * FONT_HEIGHT

UI_MAX_QUADS :: 8 * 1024

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


    // quad rendering
    program :            u32,
    quads :              u32,
    quads_cpu :          [UI_MAX_QUADS]Glyph_Quad,
    quad_count :         i32,
    font_tex :           u32,
    proj :               mat4,
    proj_u_loc :         i32,
}

@(private = "file")
g_active_camera : Camera

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

    _ctx.initialized = true
    renderer_resize(backbuffer_width, backbuffer_height)

    init_text()
    return true
}

renderer_shutdown :: proc() {
    if !_ctx.initialized do return
    assert(!_ctx.in_frame, "renderer_shutdown called inside a frame")

    rt_destroy(&_ctx.target)
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

    rt_destroy(&_ctx.target)
    _ctx.target = rt_create(backbuffer_width, backbuffer_height)
}

renderer_begin_frame :: proc(cam : Camera) -> bool {
    assert(_ctx.initialized, "renderer_begin_frame called before renderer_init")
    assert(!_ctx.in_frame, "renderer_begin_frame called twice without renderer_end_frame")

    if _ctx.backbuffer_width <= 0 || _ctx.backbuffer_height <= 0 do return false
    g_active_camera = cam

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

    _ctx.in_frame = true
    return true
}

renderer_end_frame :: proc() {
    renderer_assert_can_render()
    assert(_ctx.group_depth == 0, "renderer_end_frame called with unclosed render groups")

    renderer_bind_empty_vao()

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

        gl.DrawArrays(gl.TRIANGLES, 0, 3)
        gl.DepthMask(true)
        gl.DepthFunc(gl.LESS)
        gl.Enable(gl.CULL_FACE)
    }

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

    render_text()

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

text :: proc(x, y : int, fmt_str : string, args : ..any, size : int = 16, color : u32 = WHITE) {
    if !_ctx.initialized do return
    str := fmt.tprintf(fmt_str, ..args)
    if len(str) == 0 do return

    char_h := f32(size)
    char_w := char_h * (f32(FONT_WIDTH) / f32(FONT_HEIGHT))
    spacing := char_w + 2

    x_offset := 0
    y_offset := 0

    for ch in str {
        if _ctx.quad_count >= UI_MAX_QUADS {
            fmt.eprintf("UI_MAX_QUADS exceeded\n")
            return
        }

        switch ch {
        case ' ':
            x_offset += 1
            continue
        case '\t':
            x_offset += 4 // TAB_SPACES
            continue
        case '\r':
            continue
        case '\n':
            x_offset = 0
            y_offset += 1
            continue
        }

        x_pos := f32(x) + f32(x_offset) * spacing
        y_pos := f32(y) + f32(y_offset) * char_h

        _ctx.quads_cpu[_ctx.quad_count] = Glyph_Quad {
            pos_rect = vec4{x_pos, y_pos, x_pos + char_w, y_pos + char_h},
            uv_rect  = rune_rect(ch),
            color    = color,
        }
        _ctx.quad_count += 1
        x_offset += 1
    }
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

@(private = "file")
render_text :: proc() {
    if _ctx.quad_count == 0 do return
    if !_ctx.initialized do return

    when ODIN_DEBUG do gl.PushDebugGroup(gl.DEBUG_SOURCE_APPLICATION, 0, -1, "Render Text")

    gl.Disable(gl.DEPTH_TEST)
    gl.Disable(gl.CULL_FACE)
    gl.Enable(gl.BLEND)
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)

    gl.NamedBufferSubData(_ctx.quads, 0, int(_ctx.quad_count) * size_of(Glyph_Quad), &_ctx.quads_cpu[0])
    gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 0, _ctx.quads)

    proj := _ctx.proj

    gl.UseProgram(_ctx.program)
    gl.UniformMatrix4fv(_ctx.proj_u_loc, 1, gl.FALSE, raw_data(&proj))
    gl.BindTextureUnit(0, _ctx.font_tex)
    gl.DrawArrays(gl.TRIANGLES, 0, _ctx.quad_count * 6)

    gl.Enable(gl.DEPTH_TEST)
    gl.Enable(gl.CULL_FACE)
    gl.Disable(gl.BLEND)
    _ctx.quad_count = 0
    when ODIN_DEBUG do gl.PopDebugGroup()
}

@(private = "file")
rune_rect :: proc(c : rune) -> vec4 {
    ci := int(c) - 0x20
    if ci < 0 || ci >= 96 do ci = 0

    tx := ci % FONT_TEX_COLS * FONT_WIDTH
    ty := ci / FONT_TEX_COLS * FONT_HEIGHT

    FONT_TEXEL_X :: 1.0 / f32(FONT_TEX_WIDTH)
    FONT_TEXEL_Y :: 1.0 / f32(FONT_TEX_HEIGHT)

    HALF_X :: FONT_TEXEL_X * 0.5
    u0 := f32(tx) * FONT_TEXEL_X + HALF_X
    u1 := f32(tx + FONT_WIDTH) * FONT_TEXEL_X - HALF_X
    v1 := f32(ty) * FONT_TEXEL_Y
    v0 := f32(ty + FONT_HEIGHT) * FONT_TEXEL_Y
    return vec4{u0, v0, u1, v1}
}

@(rodata)
@(private = "file")
FONT_DATA := [96][FONT_WIDTH]u8 {
    {0x00, 0x00, 0x00, 0x00, 0x00}, // 0x20 ' '
    {0x00, 0x00, 0xFA, 0x00, 0x00}, // 0x21 '!'
    {0x00, 0xE0, 0x00, 0xE0, 0x00}, // 0x22 '"'
    {0x28, 0xFE, 0x28, 0xFE, 0x28}, // 0x23 '#'
    {0x24, 0x54, 0xFE, 0x54, 0x48}, // 0x24 '$'
    {0xC4, 0xC8, 0x10, 0x26, 0x46}, // 0x25 '%'
    {0x6C, 0x92, 0xAA, 0x44, 0x0A}, // 0x26 '&'
    {0x00, 0xA0, 0xC0, 0x00, 0x00}, // 0x27 '''
    {0x00, 0x38, 0x44, 0x82, 0x00}, // 0x28 '('
    {0x00, 0x82, 0x44, 0x38, 0x00}, // 0x29 ')'
    {0x10, 0x54, 0x38, 0x54, 0x10}, // 0x2A '*'
    {0x10, 0x10, 0x7C, 0x10, 0x10}, // 0x2B '+'
    {0x00, 0x0A, 0x0C, 0x00, 0x00}, // 0x2C ','
    {0x10, 0x10, 0x10, 0x10, 0x10}, // 0x2D '-'
    {0x00, 0x06, 0x06, 0x00, 0x00}, // 0x2E '.'
    {0x04, 0x08, 0x10, 0x20, 0x40}, // 0x2F '/'
    {0x7C, 0x8A, 0x92, 0xA2, 0x7C}, // 0x30 '0'
    {0x00, 0x42, 0xFE, 0x02, 0x00}, // 0x31 '1'
    {0x42, 0x86, 0x8A, 0x92, 0x62}, // 0x32 '2'
    {0x84, 0x82, 0xA2, 0xD2, 0x8C}, // 0x33 '3'
    {0x18, 0x28, 0x48, 0xFE, 0x08}, // 0x34 '4'
    {0xE4, 0xA2, 0xA2, 0xA2, 0x9C}, // 0x35 '5'
    {0x3C, 0x52, 0x92, 0x92, 0x0C}, // 0x36 '6'
    {0x80, 0x8E, 0x90, 0xA0, 0xC0}, // 0x37 '7'
    {0x6C, 0x92, 0x92, 0x92, 0x6C}, // 0x38 '8'
    {0x60, 0x92, 0x92, 0x94, 0x78}, // 0x39 '9'
    {0x00, 0x6C, 0x6C, 0x00, 0x00}, // 0x3A ':'
    {0x00, 0x6A, 0x6C, 0x00, 0x00}, // 0x3B ';'
    {0x00, 0x10, 0x28, 0x44, 0x82}, // 0x3C '<'
    {0x28, 0x28, 0x28, 0x28, 0x28}, // 0x3D '='
    {0x82, 0x44, 0x28, 0x10, 0x00}, // 0x3E '>'
    {0x40, 0x80, 0x8A, 0x90, 0x60}, // 0x3F '?'
    {0x4C, 0x92, 0x9E, 0x82, 0x7C}, // 0x40 '@'
    {0x7E, 0x88, 0x88, 0x88, 0x7E}, // 0x41 'A'
    {0xFE, 0x92, 0x92, 0x92, 0x6C}, // 0x42 'B'
    {0x7C, 0x82, 0x82, 0x82, 0x44}, // 0x43 'C'
    {0xFE, 0x82, 0x82, 0x44, 0x38}, // 0x44 'D'
    {0xFE, 0x92, 0x92, 0x92, 0x82}, // 0x45 'E'
    {0xFE, 0x90, 0x90, 0x80, 0x80}, // 0x46 'F'
    {0x7C, 0x82, 0x82, 0x8A, 0x4C}, // 0x47 'G'
    {0xFE, 0x10, 0x10, 0x10, 0xFE}, // 0x48 'H'
    {0x00, 0x82, 0xFE, 0x82, 0x00}, // 0x49 'I'
    {0x04, 0x02, 0x82, 0xFC, 0x80}, // 0x4A 'J'
    {0xFE, 0x10, 0x28, 0x44, 0x82}, // 0x4B 'K'
    {0xFE, 0x02, 0x02, 0x02, 0x02}, // 0x4C 'L'
    {0xFE, 0x40, 0x20, 0x40, 0xFE}, // 0x4D 'M'
    {0xFE, 0x20, 0x10, 0x08, 0xFE}, // 0x4E 'N'
    {0x7C, 0x82, 0x82, 0x82, 0x7C}, // 0x4F 'O'
    {0xFE, 0x90, 0x90, 0x90, 0x60}, // 0x50 'P'
    {0x7C, 0x82, 0x8A, 0x84, 0x7A}, // 0x51 'Q'
    {0xFE, 0x90, 0x98, 0x94, 0x62}, // 0x52 'R'
    {0x62, 0x92, 0x92, 0x92, 0x8C}, // 0x53 'S'
    {0x80, 0x80, 0xFE, 0x80, 0x80}, // 0x54 'T'
    {0xFC, 0x02, 0x02, 0x02, 0xFC}, // 0x55 'U'
    {0xF8, 0x04, 0x02, 0x04, 0xF8}, // 0x56 'V'
    {0xFE, 0x04, 0x18, 0x04, 0xFE}, // 0x57 'W'
    {0xC6, 0x28, 0x10, 0x28, 0xC6}, // 0x58 'X'
    {0xC0, 0x20, 0x1E, 0x20, 0xC0}, // 0x59 'Y'
    {0x86, 0x8A, 0x92, 0xA2, 0xC2}, // 0x5A 'Z'
    {0x00, 0x00, 0xFE, 0x82, 0x82}, // 0x5B '['
    {0x40, 0x20, 0x10, 0x08, 0x04}, // 0x5C '\'
    {0x82, 0x82, 0xFE, 0x00, 0x00}, // 0x5D ']'
    {0x20, 0x40, 0x80, 0x40, 0x20}, // 0x5E '^'
    {0x02, 0x02, 0x02, 0x02, 0x02}, // 0x5F '_'
    {0x00, 0x80, 0x40, 0x20, 0x00}, // 0x60 '`'
    {0x04, 0x2A, 0x2A, 0x2A, 0x1E}, // 0x61 'a'
    {0xFE, 0x12, 0x22, 0x22, 0x1C}, // 0x62 'b'
    {0x1C, 0x22, 0x22, 0x22, 0x04}, // 0x63 'c'
    {0x1C, 0x22, 0x22, 0x12, 0xFE}, // 0x64 'd'
    {0x1C, 0x2A, 0x2A, 0x2A, 0x18}, // 0x65 'e'
    {0x10, 0x7E, 0x90, 0x80, 0x40}, // 0x66 'f'
    {0x10, 0x28, 0x2A, 0x2A, 0x3C}, // 0x67 'g'
    {0xFE, 0x10, 0x20, 0x20, 0x1E}, // 0x68 'h'
    {0x00, 0x22, 0xBE, 0x02, 0x00}, // 0x69 'i'
    {0x04, 0x02, 0x22, 0xBC, 0x00}, // 0x6A 'j'
    {0x00, 0xFE, 0x08, 0x14, 0x22}, // 0x6B 'k'
    {0x00, 0x82, 0xFE, 0x02, 0x00}, // 0x6C 'l'
    {0x3E, 0x20, 0x18, 0x20, 0x1E}, // 0x6D 'm'
    {0x3E, 0x10, 0x20, 0x20, 0x1E}, // 0x6E 'n'
    {0x1C, 0x22, 0x22, 0x22, 0x1C}, // 0x6F 'o'
    {0x3E, 0x28, 0x28, 0x28, 0x10}, // 0x70 'p'
    {0x10, 0x28, 0x28, 0x18, 0x3E}, // 0x71 'q'
    {0x3E, 0x10, 0x20, 0x20, 0x10}, // 0x72 'r'
    {0x12, 0x2A, 0x2A, 0x2A, 0x04}, // 0x73 's'
    {0x20, 0xFC, 0x22, 0x02, 0x04}, // 0x74 't'
    {0x3C, 0x02, 0x02, 0x04, 0x3E}, // 0x75 'u'
    {0x38, 0x04, 0x02, 0x04, 0x38}, // 0x76 'v'
    {0x3C, 0x02, 0x0C, 0x02, 0x3C}, // 0x77 'w'
    {0x22, 0x14, 0x08, 0x14, 0x22}, // 0x78 'x'
    {0x30, 0x0A, 0x0A, 0x0A, 0x3C}, // 0x79 'y'
    {0x22, 0x26, 0x2A, 0x32, 0x22}, // 0x7A 'z'
    {0x00, 0x10, 0x6C, 0x82, 0x00}, // 0x7B '{'
    {0x00, 0x00, 0xFE, 0x00, 0x00}, // 0x7C '|'
    {0x00, 0x82, 0x6C, 0x10, 0x00}, // 0x7D '}'
    {0x10, 0x10, 0x54, 0x38, 0x10}, // 0x7E '~'
    {0x10, 0x38, 0x54, 0x10, 0x10}, // 0x7F '⌂'
}
