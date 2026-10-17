package main
import "core:fmt"
import gl "vendor:OpenGL"
import math "core:math/linalg/glsl"


CLOUD_SIZE :: f32(16)
CLOUD_MAX_RENDER_DIST :: f32(FAR_Z)
CLOUD_MAX_GRID_SIDE :: int(CLOUD_MAX_RENDER_DIST * 2 / CLOUD_SIZE) + 2 // 258
CLOUD_MAX_INSTANCES :: CLOUD_MAX_GRID_SIDE * CLOUD_MAX_GRID_SIDE // worst case
CLOUD_ALPHA :: f32(0.8)

CLOUD_GRID_SIDE :: i32(CLOUD_MAX_RENDER_DIST * 2 / CLOUD_SIZE) + 2 // 130


@(private = "file")
Cloud_Instance :: struct {
    pos :  [3]f32,
    _pad : u32,
}

@(private = "file")
_ctx : struct {
    program :     u32,
    cs :          u32,
    mask :        u32,
    instances :   u32,
    cmd_buf :     u32,
    mask_size :   [2]f32,
    offset :      [2]f32,
    initialized : bool,
}

clouds_init :: proc() -> bool {
    program, program_ok := load_program("clouds", "../assets/clouds.vert", "../assets/clouds.frag")
    if !program_ok {
        fmt.eprintln("failed to load cloud shaders")
        clouds_destroy()
        return false
    }
    _ctx.program = program

    cs, cs_ok := load_cs_program("clouds_cs", "../assets/clouds.glsl")
    if !cs_ok {
        fmt.eprintln("failed to load cloud compute shader")
        clouds_destroy()
        return false
    }
    _ctx.cs = cs

    mask, mask_w, mask_h, mask_ok := load_texture("clouds_mask", "../assets/cloud_mask.png")
    if !mask_ok {
        fmt.eprintln("failed to load cloud mask texture")
        clouds_destroy()
        return false
    }

    is_pow2 := mask_w > 0 && (mask_w & (mask_w - 1)) == 0 && (mask_h & (mask_h - 1)) == 0
    if !is_pow2 {
        fmt.eprintln("cloud mask must be power-of-two on both axes, got", mask_w, "x", mask_h)
        _ctx.mask = mask
        clouds_destroy()
        return false
    }

    _ctx.mask = mask
    _ctx.mask_size = {f32(mask_w), f32(mask_h)}

    gl.CreateBuffers(1, &_ctx.instances)
    gl.NamedBufferStorage(_ctx.instances, CLOUD_MAX_INSTANCES * size_of(Cloud_Instance), nil, 0)

    gl.CreateBuffers(1, &_ctx.cmd_buf)
    gl.NamedBufferStorage(_ctx.cmd_buf, size_of(gl.DrawArraysIndirectCommand), nil, gl.DYNAMIC_STORAGE_BIT)

    _ctx.initialized = true
    return true
}


clouds_destroy :: proc() {
    gl.DeleteProgram(_ctx.program)
    gl.DeleteProgram(_ctx.cs)
    gl.DeleteTextures(1, &_ctx.mask)
    gl.DeleteBuffers(1, &_ctx.instances)
    gl.DeleteBuffers(1, &_ctx.cmd_buf)
    _ctx = {}
}

clouds_render :: proc(cam, cull_cam : Camera, orbit_axis, sun_to_local : mat3) {
    if !_ctx.initialized do return

    renderer_group("clouds")

    cmd := gl.DrawArraysIndirectCommand {
        count         = 36,
        instanceCount = 0,
        first         = 0,
        baseInstance  = 0,
    }
    gl.NamedBufferSubData(_ctx.cmd_buf, 0, size_of(cmd), &cmd)

    // COMPUTE PASS
    eye_cs := [2]f32{cam.pos.x - _ctx.offset.x, cam.pos.z - _ctx.offset.y}
    grid_min := ivec2(math.floor((eye_cs - CLOUD_MAX_RENDER_DIST) / CLOUD_SIZE))

    gl.UseProgram(_ctx.cs)
    gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 0, _ctx.cmd_buf)
    gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 1, _ctx.instances)
    gl.Uniform2f(gl.GetUniformLocation(_ctx.cs, "u_offset"), _ctx.offset.x, _ctx.offset.y)
    gl.Uniform2i(gl.GetUniformLocation(_ctx.cs, "u_grid_min"), grid_min.x, grid_min.y)
    gl.Uniform1i(gl.GetUniformLocation(_ctx.cs, "u_grid_size"), CLOUD_GRID_SIDE)
    gl.BindTextureUnit(0, _ctx.mask)

    planes := cull_cam.frustum
    gl.Uniform4fv(gl.GetUniformLocation(_ctx.cs, "u_planes"), 6, &planes[0][0])

    groups := u32((CLOUD_GRID_SIDE + 16 - 1) / 16)
    gl.DispatchCompute(groups, groups, 1)
    gl.MemoryBarrier(gl.COMMAND_BARRIER_BIT | gl.SHADER_STORAGE_BARRIER_BIT)

    // DRAW PASS
    gl.UseProgram(_ctx.program)

    vp := cam.view_proj
    gl.UniformMatrix4fv(gl.GetUniformLocation(_ctx.program, "u_view_proj"), 1, false, &vp[0, 0])
    gl.Uniform3f(gl.GetUniformLocation(_ctx.program, "u_eye"), cam.pos.x, cam.pos.y, cam.pos.z)
    gl.Uniform1f(gl.GetUniformLocation(_ctx.program, "u_render_distance"), CLOUD_MAX_RENDER_DIST)
    gl.Uniform1f(gl.GetUniformLocation(_ctx.program, "u_alpha"), CLOUD_ALPHA)

    orbit_axis := orbit_axis
    sun_to_local := sun_to_local
    gl.UniformMatrix3fv(gl.GetUniformLocation(_ctx.program, "u_sun_orbit"), 1, false, raw_data(&orbit_axis))
    gl.UniformMatrix3fv(gl.GetUniformLocation(_ctx.program, "u_sun_to_local"), 1, false, raw_data(&sun_to_local))

    gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, _ctx.cmd_buf)
    gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 0, _ctx.instances)
    renderer_bind_empty_vao()

    gl.Disable(gl.CULL_FACE)
    gl.Enable(gl.DEPTH_TEST)

    // pass 1: nearest cloud surface into depth only
    gl.Disable(gl.BLEND)
    gl.ColorMask(false, false, false, false)
    gl.DepthMask(true)
    gl.DepthFunc(gl.LESS)
    gl.DrawArraysIndirect(gl.TRIANGLES, nil)

    // pass 2: blend only the surface that won pass 1
    gl.ColorMask(true, true, true, true)
    gl.DepthMask(false)
    gl.DepthFunc(gl.LEQUAL)
    gl.Enable(gl.BLEND)
    gl.BlendFuncSeparate(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA, gl.ONE, gl.ONE_MINUS_SRC_ALPHA)
    gl.DrawArraysIndirect(gl.TRIANGLES, nil)

    // restore
    gl.Disable(gl.BLEND)
    gl.DepthMask(true)
    gl.DepthFunc(gl.LESS)
    gl.Enable(gl.CULL_FACE)
}
