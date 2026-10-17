package main
import "core:fmt"
import "base:runtime"
import gl "vendor:OpenGL"
import stbi "vendor:stb/image"

Atlas :: struct {
    handle : u32,
    w, h :   i32,
    layers : i32,
}

Atlas_Builder :: struct {
    paths :     [dynamic]string,
    index_map : map[string]i32,
    tile_w :    i32,
    tile_h :    i32,
    allocator : runtime.Allocator,
    init : bool,
}

atlas_builder_init :: proc(builder : ^Atlas_Builder, tile_width, tile_height : i32, allocator : runtime.Allocator = context.allocator) {
    if tile_width <= 0 || tile_height <= 0 {
        fmt.eprintfln("atlas_builder_init: invalid tile dimensions %d, %d", tile_width, tile_height)
        return
    }

    builder^ = {
        paths     = make([dynamic]string, allocator),
        index_map = make(map[string]i32, allocator),
        tile_w    = tile_width,
        tile_h    = tile_height,
        allocator = allocator,
        init = true,
    }
}

atlas_builder_destroy :: proc(builder : ^Atlas_Builder) {
    if builder.init {
        delete(builder.index_map)
        delete(builder.paths)
        builder.tile_w = 0
        builder.tile_h = 0
        builder.init = false
    }
}

atlas_builder_valid :: proc(builder : Atlas_Builder) -> bool {
    return builder.tile_w > 0 && builder.tile_h > 0 && builder.init
}

atlas_builder_add :: proc(builder : ^Atlas_Builder, path : string) -> (index : i32, ok : bool) {
    if !builder.init {
        fmt.eprintfln("atlas_builder_add: builder is not initialized")
        return -1, false
    }

    idx, exists := builder.index_map[path]
    if exists do return idx, true

    width, height, ok1 := load_texture_info(path)
    if !ok1 do return -1, false

    //TODO: if we want to add more tiles per image we need to change this
    if width != builder.tile_w || height != builder.tile_h {
        fmt.printf("atlas_builder_add: %s has the wrong dimensions %d, %d should be %d, %d\n", path, width, height, builder.tile_w, builder.tile_h)
        return -1, false
    }

    new_idx := i32(len(builder.paths))
    append(&builder.paths, path)
    builder.index_map[path] = new_idx
    return new_idx, true
}

atlas_builder_build :: proc(label : cstring, builder : ^Atlas_Builder) -> Atlas {
    if len(builder.paths) == 0 {
        fmt.eprintfln("no paths provided for \"%s\"", label)
        return Atlas{}
    }

    m := max(builder.tile_w, builder.tile_h)
    levels : i32 = 1
    for m > 1 {
        m >>= 1
        levels += 1
    }

    layer_count := i32(len(builder.paths))
    handle : u32
    gl.CreateTextures(gl.TEXTURE_2D_ARRAY, 1, &handle)
    gl.TextureStorage3D(handle, levels, gl.SRGB8_ALPHA8, builder.tile_w, builder.tile_h, layer_count)
    when ODIN_DEBUG do gl.ObjectLabel(gl.TEXTURE, handle, -1, label)
    layer_offset : i32 = 0

    for path, _ in builder.paths {
        data, iw, ih, ok := load_texture_bytes(path, allocator = context.temp_allocator)
        defer stbi.image_free(data)
        if !ok {
            gl.DeleteTextures(1, &handle)
            return Atlas{}
        }

        gl.PixelStorei(gl.UNPACK_ROW_LENGTH, iw)
        cols := iw / builder.tile_w
        rows := ih / builder.tile_h

        for row in 0 ..< rows {
            for col in 0 ..< cols {
                tile_index := row * cols + col
                layer := layer_offset + tile_index
                x_px := col * builder.tile_w
                y_px := row * builder.tile_h
                offset := uintptr((y_px * iw + x_px) * 4)

                gl.TextureSubImage3D(handle, 0, 0, 0, layer, builder.tile_w, builder.tile_h, 1, gl.RGBA, gl.UNSIGNED_BYTE, rawptr(uintptr(data) + offset))

                key : string
                if rows == 1 && cols == 1 {
                    key = path
                } else {
                    key = fmt.tprintf("%s:%d", path, tile_index)
                }
            }
        }

        gl.PixelStorei(gl.UNPACK_ROW_LENGTH, 0)
        layer_offset += cols * rows
    }

    gl.TextureParameteri(handle, gl.TEXTURE_MIN_FILTER, gl.NEAREST_MIPMAP_LINEAR)
    gl.TextureParameteri(handle, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
    gl.TextureParameteri(handle, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
    gl.TextureParameteri(handle, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
    gl.GenerateTextureMipmap(handle)

    fmt.printfln("loaded atlas \"%s\": %d layers, %dx%d tiles, %d mip levels", label, layer_count, builder.tile_w, builder.tile_h, levels)

    builder.tile_w = 0
    builder.tile_h = 0
    return Atlas{handle = handle, w = builder.tile_w, h = builder.tile_h, layers = layer_count}
}
