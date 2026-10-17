package main

import "vendor:glfw"
import m "core:math/linalg/glsl"

NEAR_Z :: 0.1
FAR_Z :: 1000.0
FOV :: 90.0
MAX_PITCH :: 89.9
MOUSE_SENSITIVITY :: 0.05

WORLD_RIGHT :: vec3{1, 0, 0}
WORLD_UP :: vec3{0, 1, 0}
WORLD_FORWARD :: vec3{0, 0, -1}

// Plain value type, no owned memory. Safe to copy freely.
Camera :: struct {
    pos :           vec3,
    orientation :   m.quat,
    view :          m.mat4,
    proj :          m.mat4,
    inv_proj :      m.mat4,
    view_proj :     m.mat4,
    frustum :       [6]vec4,
    width, height : int, // window coords, matches glfw.GetCursorPos
    dirty :         bool,
}

camera_init :: proc(c : ^Camera, pos : vec3, width, height : int) {
    c^ = {}
    c.pos = pos
    c.orientation = 1
    c.view = m.identity(m.mat4)
    c.proj = m.identity(m.mat4)
    c.view_proj = m.identity(m.mat4)
    c.dirty = true
    camera_resize(c, width, height)
    camera_tick(c)
}

camera_tick :: proc(c : ^Camera) {
    if !c.dirty do return
    c.view = m.mat4FromQuat(conj(c.orientation)) * m.mat4Translate(-c.pos)
    c.view_proj = c.proj * c.view

    // frustum plane extraction
    // https://www.gamedevs.org/uploads/fast-extraction-viewing-frustum-planes-from-world-view-projection-matrix.pdf
    mat := c.view_proj
    c.frustum[0] = {mat[3, 0] + mat[0, 0], mat[3, 1] + mat[0, 1], mat[3, 2] + mat[0, 2], mat[3, 3] + mat[0, 3]} // -x
    c.frustum[1] = {mat[3, 0] - mat[0, 0], mat[3, 1] - mat[0, 1], mat[3, 2] - mat[0, 2], mat[3, 3] - mat[0, 3]} // +x
    c.frustum[2] = {mat[3, 0] + mat[1, 0], mat[3, 1] + mat[1, 1], mat[3, 2] + mat[1, 2], mat[3, 3] + mat[1, 3]} // -y
    c.frustum[3] = {mat[3, 0] - mat[1, 0], mat[3, 1] - mat[1, 1], mat[3, 2] - mat[1, 2], mat[3, 3] - mat[1, 3]} // +y
    c.frustum[4] = {mat[3, 0] + mat[2, 0], mat[3, 1] + mat[2, 1], mat[3, 2] + mat[2, 2], mat[3, 3] + mat[2, 3]} // near
    c.frustum[5] = {mat[3, 0] - mat[2, 0], mat[3, 1] - mat[2, 1], mat[3, 2] - mat[2, 2], mat[3, 3] - mat[2, 3]} // far
    for &plane in c.frustum do plane /= m.length(plane.xyz)

    c.dirty = false
}

camera_resize :: proc(c : ^Camera, width, height : int) {
    if width <= 0 || height <= 0 do return
    if width == c.width && height == c.height do return
    c.width = width
    c.height = height
    aspect := f32(width) / f32(height)
    c.proj = m.mat4Perspective(m.radians(f32(FOV)), aspect, NEAR_Z, FAR_Z)
    c.inv_proj = m.inverse(c.proj)
    c.dirty = true
}

camera_forward :: #force_inline proc(c : Camera) -> vec3 {
    return m.quatMulVec3(c.orientation, WORLD_FORWARD)
}

camera_right :: #force_inline proc(c : Camera) -> vec3 {
    return m.quatMulVec3(c.orientation, WORLD_RIGHT)
}

camera_get_ray :: proc(c : Camera, x, y : f64) -> (origin, dir : vec3, ok : bool) {
    if c.width <= 0 || c.height <= 0 do return origin, dir, false

    ndc_x := 2.0 * f32(x) / f32(c.width) - 1.0
    ndc_y := 1.0 - 2.0 * f32(y) / f32(c.height)

    near_view := m.inverse(c.proj) * vec4{ndc_x, ndc_y, -1.0, 1.0}
    near_view /= near_view.w

    dir = m.normalize(m.quatMulVec3(c.orientation, near_view.xyz))
    origin = c.pos
    return origin, dir, true
}

camera_aabb_in_view :: proc(c : Camera, min, max : vec3) -> bool {
    corners : [8]vec3
    corners[0] = vec3{min.x, min.y, min.z}
    corners[4] = vec3{min.x, min.y, max.z}
    corners[2] = vec3{min.x, max.y, min.z}
    corners[6] = vec3{min.x, max.y, max.z}
    corners[1] = vec3{max.x, min.y, min.z}
    corners[5] = vec3{max.x, min.y, max.z}
    corners[3] = vec3{max.x, max.y, min.z}
    corners[7] = vec3{max.x, max.y, max.z}

    for i in 0 ..< 6 {
        plane : vec4 = c.frustum[i]
        out := 0
        for j in 0 ..< 8 {
            point := corners[j]
            dst := plane.x * point.x + plane.y * point.y + plane.z * point.z + plane.w
            if dst < 0.0 do out += 1
        }
        if out == 8 do return false
    }
    return true
}

Player :: struct {
    pos :            vec3,
    yaw, pitch :     f32,
    speed :          f32,
    camera :         Camera,
    window :         glfw.WindowHandle,
    mouse_captured : bool,
    last_x, last_y : f64,
}

player_init :: proc(p : ^Player, pos : vec3, window : glfw.WindowHandle) {
    p^ = {}
    p.pos = pos
    p.speed = 5.0
    p.window = window
    width, height := glfw.GetWindowSize(window)
    camera_init(&p.camera, pos, int(width), int(height))
}

player_tick :: proc(p : ^Player, world : ^World, delta_time : f32) {
    width, height := glfw.GetWindowSize(p.window)
    camera_resize(&p.camera, int(width), int(height))

    if update_input(p, delta_time) {
        p.camera.pos = p.pos
        p.camera.orientation = player_orientation(p^)
        p.camera.dirty = true
    }
    camera_tick(&p.camera)
}

player_orientation :: proc(p : Player) -> m.quat {
    return m.quatAxisAngle(WORLD_UP, p.yaw) * m.quatAxisAngle(WORLD_RIGHT, p.pitch)
}

player_world_coord :: #force_inline proc(p : Player) -> ivec3 {
    return ivec3{i32(p.pos.x), i32(p.pos.y), i32(p.pos.z)}
}

@(private = "file")
player_rotate :: proc(p : ^Player, yaw_delta, pitch_delta : f32) {
    max_pitch := m.radians(f32(MAX_PITCH))
    p.yaw = m.mod(p.yaw + yaw_delta, m.TAU)
    p.pitch = clamp(p.pitch + pitch_delta, -max_pitch, max_pitch)
}

@(private = "file")
get_axis_input :: proc(window : glfw.WindowHandle, positive_key, negative_key : i32) -> f32 {
    return f32(glfw.GetKey(window, positive_key) - glfw.GetKey(window, negative_key))
}

@(private = "file")
update_input :: proc(p : ^Player, dt : f32) -> (changed : bool) {
    rot_x, rot_y : f64
    if glfw.GetMouseButton(p.window, glfw.MOUSE_BUTTON_RIGHT) == glfw.PRESS {
        if !p.mouse_captured {
            glfw.SetInputMode(p.window, glfw.CURSOR, glfw.CURSOR_DISABLED)
            p.last_x, p.last_y = glfw.GetCursorPos(p.window)
            p.mouse_captured = true
        } else {
            xpos, ypos := glfw.GetCursorPos(p.window)
            rot_x = (p.last_x - xpos) * MOUSE_SENSITIVITY
            rot_y = (p.last_y - ypos) * MOUSE_SENSITIVITY
            p.last_x = xpos
            p.last_y = ypos
        }
    } else if p.mouse_captured {
        glfw.SetInputMode(p.window, glfw.CURSOR, glfw.CURSOR_NORMAL)
        p.mouse_captured = false
    }

    if rot_x != 0 || rot_y != 0 {
        player_rotate(p, m.radians(f32(rot_x)), m.radians(f32(rot_y)))
        changed = true
    }

    xt := get_axis_input(p.window, glfw.KEY_D, glfw.KEY_A)
    zt := get_axis_input(p.window, glfw.KEY_W, glfw.KEY_S)
    yt := get_axis_input(p.window, glfw.KEY_SPACE, glfw.KEY_C)

    speed := glfw.GetKey(p.window, glfw.KEY_LEFT_CONTROL) == glfw.PRESS ? p.speed * 5 : p.speed
    if xt != 0 || yt != 0 || zt != 0 {
        orientation := player_orientation(p^)
        forward := m.quatMulVec3(orientation, WORLD_FORWARD)
        right := m.quatMulVec3(orientation, WORLD_RIGHT)
        dir := m.normalize(vec3{xt, yt, zt})
        p.pos += (right * dir.x + WORLD_UP * dir.y + forward * dir.z) * speed * dt
        changed = true
    }
    return
}
