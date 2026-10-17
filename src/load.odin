package main
import gl "vendor:OpenGL"
import "core:os"
import "core:io"
import "core:fmt"
import "base:runtime"
import "core:strings"
import "core:path/filepath"
import stbi "vendor:stb/image"
import c "core:c/libc"

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

load_cs_program :: proc(label : cstring, path : string) -> (u32, bool) {
    cs_shader := load_shader(path, gl.COMPUTE_SHADER, context.temp_allocator)
    defer gl.DeleteShader(cs_shader)

    if cs_shader == gl.NONE do return gl.NONE, false

    program := gl.CreateProgram()
    gl.AttachShader(program, cs_shader)
    gl.LinkProgram(program)

    params : i32 = -1
    gl.GetProgramiv(program, gl.LINK_STATUS, &params)
    if params != 1 {
        error_log_buf : [PROGRAM_LOG_SIZE]u8
        gl.GetProgramInfoLog(program, PROGRAM_LOG_SIZE, nil, &error_log_buf[0])
        fmt.eprintfln("could not link compute shader program %s [%s] GL index %d", label, path, program)
        fmt.eprintfln("program log: %s", cstring(&error_log_buf[0]))
        return gl.NONE, false
    }

    when ODIN_DEBUG do gl.ObjectLabel(gl.PROGRAM, program, -1, label)
    fmt.printf("loaded compute program: \"%s\" with GL index: %d\n", label, program)
    return program, true
}

@(private = "file")
load_shader :: proc(path : string, type : u32, allocator : runtime.Allocator = context.allocator) -> u32 {
    src, ok := load_asset(path, allocator = allocator)
    defer free_asset(src, allocator = allocator)
    if !ok {
        fmt.eprintfln("failed to read file: \"%s\"", path)
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

// asset loading
ASSET_PATH :: #config(ASSET_PATH, "")

get_asset_path :: proc(path : string, asset_path := ASSET_PATH, allocator := context.allocator) -> (full_path : string, ok : bool) {
    err : runtime.Allocator_Error
    full_path, err = filepath.join([]string{asset_path, path}, allocator)
    if err != .None {
        fmt.eprintfln("get_asset_path: failed to join \"%s\" and \"%s\": %v", asset_path, path, err)
        return "", false
    }
    return full_path, true
}

load_asset_from_path :: proc(path : string, allocator := context.allocator) -> (data : []u8, ok : bool) {
    err : os.Error
    data, err = os.read_entire_file(path, allocator)
    if err != nil {
        fmt.eprintfln("load_asset_fullpath: failed to read \"%s\": %v", path, err)
        return nil, false
    }
    return data, true
}

load_asset :: proc(path : string, asset_path := ASSET_PATH, allocator := context.allocator) -> (data : []u8, ok : bool) {
    full_path := get_asset_path(path, asset_path, context.temp_allocator) or_return
    return load_asset_from_path(full_path, allocator)
}

free_asset :: proc(data : []u8, allocator := context.allocator) {
    delete(data, allocator)
}


load_texture_bytes :: proc(path : string, allocator : runtime.Allocator = context.allocator) -> ([^]byte, i32, i32, bool) {
    content, ok := load_asset(path, allocator = allocator)
    defer free_asset(content, allocator = allocator)

    if !ok {
        fmt.printf("failed to read file: \"%s\"\n", path)
        return nil, 0, 0, false
    }

    w, h, channels : i32
    data := stbi.load_from_memory(raw_data(content), i32(len(content)), &w, &h, &channels, 4)

    if data == nil || w == 0 || h == 0 {
        reason := stbi.failure_reason()
        fmt.eprintfln("could not load image \"%s\": %s", path, reason)
        return nil, 0, 0, false
    }

    return data, w, h, true
}

load_texture :: proc(label : cstring, path : string, allocator : runtime.Allocator = context.temp_allocator) -> (u32, i32, i32, bool) {
    data, w, h, ok := load_texture_bytes(path, allocator)
    defer stbi.image_free(data)
    if !ok {
        return 0, 0, 0, false
    }

    handle : u32
    gl.CreateTextures(gl.TEXTURE_2D, 1, &handle)
    gl.TextureStorage2D(handle, 1, gl.RGBA8, w, h)
    gl.TextureSubImage2D(handle, 0, 0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, data)
    gl.TextureParameteri(handle, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
    gl.TextureParameteri(handle, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
    when ODIN_DEBUG do gl.ObjectLabel(gl.TEXTURE, handle, -1, label)
    return handle, w, h, true
}

load_texture_info :: proc(path : string) -> (i32, i32, bool) {
    full_path, ok := get_asset_path(path, allocator = context.temp_allocator)
    if !ok {
        fmt.eprintfln("failed to combine paths \"%s\" and \"%s\"", path, path)
        return 0, 0, false
    }

    fp := c.fopen(strings.clone_to_cstring(full_path, context.temp_allocator), "rb")
    if fp == nil {
        fmt.eprintfln("failed to open \"%s\"", full_path)
        return 0, 0, false
    }
    defer c.fclose(fp)

    w, h, channels : i32
    if stbi.info_from_file(fp, &w, &h, &channels) == 0 {
        reason := stbi.failure_reason()
        fmt.eprintfln("could not get image info for \"%s\": %s", path, reason)
        return 0, 0, false
    }
    return w, h, true
}
