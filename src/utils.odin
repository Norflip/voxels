package main
import gl "vendor:OpenGL"

ivec2 :: [2]i32
ivec3 :: [3]i32

vec3 :: [3]f32
vec4 :: [4]f32
mat4 :: matrix[4, 4]f32
mat3 :: matrix[3, 3]f32

RED :: u32(0xFF0000FF)
GREEN :: u32(0x00FF00FF)
BLUE :: u32(0x0000FFFF)
WHITE :: u32(0xFFFFFFFF)

create_mapped_buffer :: proc(buffer : ^u32, size : u32, storage_flags : u32, mapping_flags : u32, label : cstring, $T : typeid) -> [^]T {
    gl.CreateBuffers(1, buffer)
    gl.NamedBufferStorage(buffer^, int(size_of(T) * size), nil, storage_flags)
    mapped := gl.MapNamedBufferRange(buffer^, 0, int(size_of(T) * size), mapping_flags)
    when ODIN_DEBUG do gl.ObjectLabel(gl.BUFFER, buffer^, -1, label)
    return ([^]T)(mapped)
}
