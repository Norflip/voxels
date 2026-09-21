package main
import gl "vendor:OpenGL"
import "core:os"
import "core:io"
import "core:fmt"
import "base:runtime"
import "core:strings"

@(private = "file")
PROGRAM_LOG_SIZE :: 1024

load_program :: proc(label : cstring, vspath, fspath : string) -> (u32, bool) {
    vs_shader := load_shader(vspath, gl.VERTEX_SHADER, context.temp_allocator)
    defer gl.DeleteShader(vs_shader)

    fs_shader := load_shader(fspath, gl.FRAGMENT_SHADER, context.temp_allocator)
    defer gl.DeleteShader(fs_shader)

    if vs_shader == gl.NONE || fs_shader == gl.NONE do return gl.NONE, false

    program := gl.CreateProgram()
    gl.AttachShader(program, vs_shader)
    gl.AttachShader(program, fs_shader)
    gl.LinkProgram(program)

    params : i32 = -1
    gl.GetProgramiv(program, gl.LINK_STATUS, &params)
    if params != 1 {
        error_log_buf : [PROGRAM_LOG_SIZE]u8
        gl.GetProgramInfoLog(program, PROGRAM_LOG_SIZE, nil, &error_log_buf[0])
        fmt.eprintfln("could not link shader program %s [%s, %s] GL index %d", label, vspath, fspath, program)
        fmt.eprintfln("program log: %s", cstring(&error_log_buf[0]))
        return gl.NONE, false
    }

    when ODIN_DEBUG do gl.ObjectLabel(gl.PROGRAM, program, -1, label)
    fmt.printf("loaded shader program: \"%s\" with GL index: %d\n", label, program)
    return program, true
}

@(private = "file")
load_shader :: proc(path : string, type : u32, allocator : runtime.Allocator = context.allocator) -> u32 {
    src, err := os.read_entire_file(path, allocator)
    defer delete(src, allocator)
    if err != io.Error.None {
        fmt.eprintfln("load_shader: failed to read file \"%s\": %v", path, err)
        return gl.NONE
    }

    shader := gl.CreateShader(type)
    ptr := transmute(cstring)raw_data(src)
    length := i32(len(src))
    gl.ShaderSource(shader, 1, &ptr, &length)
    gl.CompileShader(shader)

    params : i32 = -1
    gl.GetShaderiv(shader, gl.COMPILE_STATUS, &params)
    if params != 1 {
        error_log_buf : [PROGRAM_LOG_SIZE]u8
        gl.GetShaderInfoLog(shader, PROGRAM_LOG_SIZE, nil, raw_data(&error_log_buf))
        fmt.eprintfln("load_shader: gl shader %s (%d) failed to compile", path, shader)
        fmt.eprintfln("shader info log:\n%s\n", cstring(raw_data(&error_log_buf)))
        gl.DeleteShader(shader)
        return gl.NONE
    }

    return shader
}
