package main

import "core:fmt"
import gl "vendor:OpenGL"

MAX_LINES :: 16 * 1024
MAX_LINE_VERTICES :: MAX_LINES * 2

@(rodata)
@(private = "file")
BOX_CORNERS := [8]vec3 {
    {-0.5, -0.5, -0.5}, {0.5, -0.5, -0.5}, {0.5, -0.5, 0.5}, {-0.5, -0.5, 0.5},
    {-0.5,  0.5, -0.5}, {0.5,  0.5, -0.5}, {0.5,  0.5, 0.5}, {-0.5,  0.5, 0.5},
}

@(private = "file")
Line_Vertex :: struct {
    x, y, z : f32,
    color :   u32,
}
#assert(size_of(Line_Vertex) == 16)

@(private = "file")
_ctx : struct {
    program :     u32,
    vao :         u32, 
    vbo :         u32,
    vp_loc :      i32,
    count :       i32, 
    initialized : bool,
}

@(private = "file")
_vertices : [MAX_LINE_VERTICES]Line_Vertex

iml_init :: proc() -> bool {
    program, ok := load_program("line_prog", "../assets/line.vert", "../assets/line.frag")
    if !ok {
        fmt.eprintln("iml: failed to load debug line shaders")
        return false
    }

    gl.CreateVertexArrays(1, &_ctx.vao)
    gl.CreateBuffers(1, &_ctx.vbo)
    gl.NamedBufferStorage(_ctx.vbo, size_of(_vertices), nil, gl.DYNAMIC_STORAGE_BIT)

    when ODIN_DEBUG {
        gl.ObjectLabel(gl.VERTEX_ARRAY, _ctx.vao, -1, "debug_line_vao")
        gl.ObjectLabel(gl.BUFFER, _ctx.vbo, -1, "debug_line_buffer")
    }

    _ctx.program = program
    _ctx.vp_loc = gl.GetUniformLocation(program, "u_vp")
    _ctx.count = 0
    _ctx.initialized = true
    return true
}

iml_cleanup :: proc() {
    if !_ctx.initialized do return
    gl.DeleteBuffers(1, &_ctx.vbo)
    gl.DeleteVertexArrays(1, &_ctx.vao)
    gl.DeleteProgram(_ctx.program)
    _ctx = {}
}

iml_render :: proc(vp : mat4) {
    if !_ctx.initialized || _ctx.count == 0 do return

    vertex_count := _ctx.count * 2
    gl.NamedBufferSubData(_ctx.vbo, 0, int(vertex_count) * size_of(Line_Vertex), &_vertices[0])

    gl.UseProgram(_ctx.program)
    vp := vp
    gl.UniformMatrix4fv(_ctx.vp_loc, 1, gl.FALSE, raw_data(&vp))
    gl.BindVertexArray(_ctx.vao)
    gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 0, _ctx.vbo)

    gl.Enable(gl.DEPTH_TEST)
    gl.DepthFunc(gl.LEQUAL)
    gl.Enable(gl.BLEND)
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)

    gl.DrawArrays(gl.LINES, 0, vertex_count)

    gl.Disable(gl.BLEND)
    _ctx.count = 0
}

iml_line :: proc(start, end : vec3, color : u32) {
    if !_ctx.initialized || _ctx.count >= MAX_LINES do return
    i := _ctx.count * 2
    _vertices[i + 0] = {start.x, start.y, start.z, color}
    _vertices[i + 1] = {end.x, end.y, end.z, color}
    _ctx.count += 1
}

iml_box :: proc(centre, size : vec3, color : u32) {
    if !_ctx.initialized || _ctx.count + 12 > MAX_LINES do return

    corners : [8]vec3
    for i in 0 ..< 8 {
        corners[i] = centre + BOX_CORNERS[i] * size
    }

    j := 3
    for i in 0 ..< 4 {
        iml_line(corners[i], corners[j], color)
        iml_line(corners[i + 4], corners[j + 4], color)
        iml_line(corners[i], corners[i + 4], color)
        j = i
    }
}

iml_bounds :: proc(lo, hi : vec3, color : u32) {
    iml_box((lo + hi) * 0.5, hi - lo, color)
}
