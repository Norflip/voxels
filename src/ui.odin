package main
import "core:fmt"
import gl "vendor:OpenGL"
import math "core:math/linalg/glsl"

FONT_WIDTH :: 5
FONT_HEIGHT :: 8

FONT_TEX_COLS :: 8
FONT_TEX_ROWS :: 96 / FONT_TEX_COLS
FONT_TEX_WIDTH :: FONT_TEX_COLS * FONT_WIDTH
FONT_TEX_HEIGHT :: FONT_TEX_ROWS * FONT_HEIGHT
ATLAS_W :: FONT_TEX_WIDTH
ATLAS_H :: FONT_TEX_HEIGHT + 1

UI_MAX_QUADS :: 8 * 1024
UI_MAX_CMDS :: 256

UI_WHITE_U : f32 : 0.5 / f32(ATLAS_W)
UI_WHITE_V : f32 : (f32(FONT_TEX_HEIGHT) + 0.5) / f32(ATLAS_H)

TEXT_AREA_DEFAULT_SIZE :: 16

@(private = "file")
Quad :: struct #packed {
    pos_rect : vec4,
    uv_rect :  vec4,
    color :    u32,
    layer :    u32,
    _pad :     [2]u32,
}

@(private = "file")
Cmd :: struct {
    texture :    u32,
    program :    u32,
    first_quad : i32,
    quad_count : i32,
}

@(private = "file")
Text_Area :: struct {
    x :    int,
    y :    int,
    pad :  int,
    size : int,
}

@(private = "file")
TEXT_AREA_DEFAULT :: Text_Area{0, 0, 0, TEXT_AREA_DEFAULT_SIZE}

@(private = "file")
_ctx : struct {
    program :        u32,
    texarr_program : u32,
    quads :          u32,
    quads_cpu :      [UI_MAX_QUADS]Quad,
    count :          i32,
    font_tex :       u32,
    proj :           mat4,
    window_w :       i32,
    window_h :       i32,
    initialized :    bool,
    cmds :           [UI_MAX_CMDS]Cmd,
    cmd_count :      i32,
    proj_u_loc :     i32,
    active_area : Text_Area,
}

ui_init :: proc(window_width, window_height : i32) {

    gl.CreateBuffers(1, &_ctx.quads)
    gl.NamedBufferStorage(_ctx.quads, UI_MAX_QUADS * size_of(Quad), nil, gl.DYNAMIC_STORAGE_BIT)
    when ODIN_DEBUG do gl.ObjectLabel(gl.BUFFER, _ctx.quads, -1, "ui_quad_buffer")

    ok : bool
    _ctx.program, ok = load_program("ui_prog", "../assets/ui.vert", "../assets/ui.frag")
    if !ok {
        fmt.println("Failed to load UI shaders:")
        return
    }

    definitions := [][2]string{{"SAMPLE_TEXARR", "1"}}
    _ctx.texarr_program, ok = load_program("ui_texarr_prog", "../assets/ui.vert", "../assets/ui.frag", definitions)
    if !ok {
        fmt.println("Failed to load UI texture array shaders:")
        return
    }

    _ctx.proj_u_loc = gl.GetUniformLocation(_ctx.program, "u_proj")

    pixels : [ATLAS_W * ATLAS_H * 4]u8
    for i in 0 ..< 96 {
        tx := (i % FONT_TEX_COLS) * FONT_WIDTH
        ty := (i / FONT_TEX_COLS) * FONT_HEIGHT

        char_data := FONT_DATA[i]
        for x in 0 ..< FONT_WIDTH {
            column := char_data[x]
            for y in 0 ..< 8 {
                idx := ((ty + y) * ATLAS_W + (tx + x)) * 4
                v : u8 = ((column >> u32(y)) & 1) == 1 ? 0xFF : 0x00
                pixels[idx + 0] = v
                pixels[idx + 1] = v
                pixels[idx + 2] = v
                pixels[idx + 3] = v
            }
        }
    }

    // white texel row (y == FONT_TEX_HEIGHT) for solid fills
    for x in 0 ..< ATLAS_W {
        idx := (FONT_TEX_HEIGHT * ATLAS_W + x) * 4
        pixels[idx + 0] = 0xFF
        pixels[idx + 1] = 0xFF
        pixels[idx + 2] = 0xFF
        pixels[idx + 3] = 0xFF
    }

    tex : u32
    gl.CreateTextures(gl.TEXTURE_2D, 1, &tex)
    gl.TextureParameteri(tex, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
    gl.TextureParameteri(tex, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
    gl.TextureParameteri(tex, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
    gl.TextureParameteri(tex, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
    gl.TextureStorage2D(tex, 1, gl.RGBA8, ATLAS_W, ATLAS_H)
    gl.TextureSubImage2D(tex, 0, 0, 0, ATLAS_W, ATLAS_H, gl.RGBA, gl.UNSIGNED_BYTE, &pixels)
    _ctx.font_tex = tex
    when ODIN_DEBUG do gl.ObjectLabel(gl.TEXTURE, _ctx.font_tex, -1, "ui_font_texture")

    ui_resize(window_width, window_height)
    _ctx.count = 0
    _ctx.active_area = TEXT_AREA_DEFAULT
    _ctx.initialized = true
}

ui_resize :: proc(window_width, window_height : i32) {
    _ctx.window_w = window_width
    _ctx.window_h = window_height
    _ctx.proj = math.mat4Ortho3d(0.0, f32(window_width), f32(window_height), 0.0, -1.0, 1.0)
    gl.ProgramUniformMatrix4fv(_ctx.program, _ctx.proj_u_loc, 1, gl.FALSE, raw_data(&_ctx.proj))
    gl.ProgramUniformMatrix4fv(_ctx.texarr_program, _ctx.proj_u_loc, 1, gl.FALSE, raw_data(&_ctx.proj))
}

ui_cleanup :: proc() {
    if !_ctx.initialized do return
    gl.DeleteBuffers(1, &_ctx.quads)
    gl.DeleteProgram(_ctx.program)
    gl.DeleteProgram(_ctx.texarr_program)
    gl.DeleteTextures(1, &_ctx.font_tex)
    _ctx.initialized = false
}

ui_reset :: proc() {
    if !_ctx.initialized do return
    _ctx.count = 0
    _ctx.cmd_count = 0
    _ctx.active_area = TEXT_AREA_DEFAULT
}

ui_render :: proc() {
    _ctx.active_area = TEXT_AREA_DEFAULT

    if !_ctx.initialized do return
    if _ctx.count == 0 do return

    renderer_group("ui")

    gl.Disable(gl.DEPTH_TEST)
    gl.Disable(gl.CULL_FACE)
    gl.Enable(gl.BLEND)
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)

    renderer_bind_empty_vao()
    gl.NamedBufferSubData(_ctx.quads, 0, int(_ctx.count) * size_of(Quad), &_ctx.quads_cpu[0])
    gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 0, _ctx.quads)

    cur_program : u32 = 0
    for i in 0 ..< _ctx.cmd_count {
        cmd := _ctx.cmds[i]
        if cmd.quad_count == 0 do continue
        if cmd.program != cur_program {
            gl.UseProgram(cmd.program)
            cur_program = cmd.program
        }
        gl.BindTextureUnit(0, cmd.texture)
        gl.DrawArrays(gl.TRIANGLES, cmd.first_quad * 6, cmd.quad_count * 6)
    }

    _ctx.count = 0
    _ctx.cmd_count = 0
}

ui_rect :: proc(x, y, w, h : f32, color : u32 = 0xFFFFFFFF) {
    if !_ctx.initialized do return
    push_quad(Quad{pos_rect = vec4{x, y, x + w, y + h}, uv_rect = vec4{UI_WHITE_U, UI_WHITE_V, UI_WHITE_U, UI_WHITE_V}, color = color, layer = 0}, _ctx.font_tex, _ctx.program)
}

ui_rect_tex :: proc(x, y, w, h : f32, texture : u32, uv : vec4 = vec4{0, 0, 1, 1}, color : u32 = 0xFFFFFFFF) {
    if !_ctx.initialized do return
    push_quad(Quad{pos_rect = vec4{x, y, x + w, y + h}, uv_rect = uv, color = color, layer = 0}, texture, _ctx.program)
}

ui_rect_atlas :: proc(x, y, w, h : f32, atlas : Atlas, layer : u32, uv : vec4 = vec4{0, 0, 1, 1}, color : u32 = 0xFFFFFFFF) {
    if !_ctx.initialized do return
    if layer >= u32(atlas.layers) do return
    push_quad(Quad{pos_rect = vec4{x, y, x + w, y + h}, uv_rect = uv, color = color, layer = layer}, atlas.handle, _ctx.texarr_program)
}

ui_area :: proc(x, y, padding : int, size : int = TEXT_AREA_DEFAULT_SIZE) {
    _ctx.active_area = Text_Area{x, y, padding, size}
}

ui_textln :: proc(fmt_str : string, args : ..any, color : u32 = WHITE) {
    lines := ui_text(_ctx.active_area.x, _ctx.active_area.y, _ctx.active_area.size, fmt_str, ..args, color = color)
    _ctx.active_area.y += max(lines, 1) * _ctx.active_area.size + _ctx.active_area.pad
}

// returns the number of lines drawn, 0 if nothing was drawn
ui_text :: proc(x, y : int, size : int, fmt_str : string, args : ..any, color : u32 = 0xFFFFFFFF) -> int {
    if !_ctx.initialized do return 0
    str := fmt.tprintf(fmt_str, ..args)
    if len(str) == 0 do return 0

    char_h := f32(size)
    char_w := char_h * (f32(FONT_WIDTH) / f32(FONT_HEIGHT))
    spacing := char_w + 2

    x_offset := 0
    y_offset := 0

    for ch in str {
        switch ch {
        case ' ':
            x_offset += 1
            continue
        case '\t':
            x_offset += 4 // TAB_SPACES
            continue
        case '\n':
            x_offset = 0
            y_offset += 1
            continue
        }

        x_pos := f32(x) + f32(x_offset) * spacing
        y_pos := f32(y) + f32(y_offset) * char_h

        rect := rune_rect(ch)
        push_quad(Quad{pos_rect = vec4{x_pos, y_pos, x_pos + char_w, y_pos + char_h}, uv_rect = rect, color = color, layer = 0}, _ctx.font_tex, _ctx.program)

        x_offset += 1
    }
    return y_offset + 1
}

@(private = "file")
push_quad :: proc(quad : Quad, texture : u32, program : u32) {
    if _ctx.count >= UI_MAX_QUADS do return

    need_new := _ctx.cmd_count == 0
    if !need_new {
        last := &_ctx.cmds[_ctx.cmd_count - 1]
        need_new = last.texture != texture || last.program != program
    }

    if need_new {
        if _ctx.cmd_count >= UI_MAX_CMDS do return
        _ctx.cmds[_ctx.cmd_count] = Cmd {
            texture    = texture,
            program    = program,
            first_quad = _ctx.count,
            quad_count = 0,
        }
        _ctx.cmd_count += 1
    }

    _ctx.cmds[_ctx.cmd_count - 1].quad_count += 1
    _ctx.quads_cpu[_ctx.count] = quad
    _ctx.count += 1
}


@(private = "file")
rune_rect :: proc(c : rune) -> vec4 {
    ci := int(c) - 0x20
    if ci < 0 || ci >= 96 do ci = 0

    tx := ci % FONT_TEX_COLS * FONT_WIDTH
    ty := ci / FONT_TEX_COLS * FONT_HEIGHT

    TEXEL_X :: 1.0 / f32(ATLAS_W)
    TEXEL_Y :: 1.0 / f32(ATLAS_H)
    HALF_X :: TEXEL_X * 0.5

    u0 := f32(tx) * TEXEL_X + HALF_X
    u1 := f32(tx + FONT_WIDTH) * TEXEL_X - HALF_X
    v1 := f32(ty) * TEXEL_Y
    v0 := f32(ty + FONT_HEIGHT) * TEXEL_Y
    return vec4{u0, v0, u1, v1}
}

@(rodata)
//@(private = "file")
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
