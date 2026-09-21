package main

import m "core:math/linalg/glsl"
import "vendor:glfw"

NEAR_Z :: 0.1
FAR_Z :: 1000.0
FOV :: 90.0
MAX_PITCH :: 89.9
MOUSE_SENSITIVITY :: 0.05

WORLD_UP :: m.vec3{0, 1, 0}
LOCAL_FORWARD :: m.vec3{0, 0, -1}
LOCAL_RIGHT :: m.vec3{1, 0, 0}

Player :: struct {
    pos :            m.vec3,
    yaw, pitch :     f32, 
    orientation :    m.quat,
    speed :          f32,
    dirty :          bool,
    view :           m.mat4,
    proj :           m.mat4,
    view_proj :      m.mat4,
    window :         glfw.WindowHandle,
    mouse_captured : bool,
    first_frame :    bool,
    last_x, last_y : f64,
}

player_init :: proc(p : ^Player, pos : m.vec3, window : glfw.WindowHandle) {
    p.pos = pos
    p.yaw = 0
    p.pitch = 0
    p.orientation = m.quatAxisAngle(WORLD_UP, p.yaw) * m.quatAxisAngle(LOCAL_RIGHT, p.pitch)
    p.view = m.identity(m.mat4)
    p.proj = m.identity(m.mat4)
    p.view_proj = m.identity(m.mat4)
    p.window = window
    p.mouse_captured = false
    p.first_frame = true
    p.last_x = 0.0
    p.last_y = 0.0

    p.speed = 5.0
    p.dirty = true
}

player_tick :: proc(p : ^Player, delta_time : f32) {
    update_input(p, delta_time)

    if p.dirty {
        p.view = m.mat4FromQuat(conj(p.orientation)) * m.mat4Translate(-p.pos)
        p.dirty = false
    }

    width, height := glfw.GetWindowSize(p.window)
    if height > 0 {
        aspect := f32(width) / f32(height)
        p.proj = m.mat4Perspective(m.radians(f32(FOV)), aspect, NEAR_Z, FAR_Z)
    }
    p.view_proj = p.proj * p.view
}

player_forward :: proc(p : ^Player) -> m.vec3 {
    return m.quatMulVec3(p.orientation, LOCAL_FORWARD)
}

player_right :: proc(p : ^Player) -> m.vec3 {
    return m.quatMulVec3(p.orientation, LOCAL_RIGHT)
}

@(private = "file")
player_rotate :: proc(p : ^Player, yaw_delta, pitch_delta : f32) {
    max_pitch := m.radians(f32(MAX_PITCH))
    p.yaw = m.mod(p.yaw + yaw_delta, m.TAU)
    p.pitch = clamp(p.pitch + pitch_delta, -max_pitch, max_pitch)
    p.orientation = m.quatAxisAngle(WORLD_UP, p.yaw) * m.quatAxisAngle(LOCAL_RIGHT, p.pitch)
}

@(private = "file")
get_axis_input :: proc(window : glfw.WindowHandle, positive_key, negative_key : i32) -> f32 {
    return f32(glfw.GetKey(window, positive_key) - glfw.GetKey(window, negative_key))
}

@(private = "file")
update_input :: proc(p : ^Player, dt : f32) {
    rot_x, rot_y : f64
    if glfw.GetMouseButton(p.window, glfw.MOUSE_BUTTON_RIGHT) == glfw.PRESS {
        xpos, ypos := glfw.GetCursorPos(p.window)
        if !p.mouse_captured {
            glfw.SetInputMode(p.window, glfw.CURSOR, glfw.CURSOR_DISABLED)
            p.last_x = xpos
            p.last_y = ypos
            p.mouse_captured = true
        } else {
            rot_x = (p.last_x - xpos) * MOUSE_SENSITIVITY
            rot_y = (p.last_y - ypos) * MOUSE_SENSITIVITY
            p.last_x = xpos
            p.last_y = ypos
        }
    } else if p.mouse_captured {
        glfw.SetInputMode(p.window, glfw.CURSOR, glfw.CURSOR_NORMAL)
        p.mouse_captured = false
        p.last_x = 0
        p.last_y = 0
    }

    if p.mouse_captured && (rot_x != 0 || rot_y != 0) {
        player_rotate(p, m.radians(f32(rot_x)), m.radians(f32(rot_y)))
        p.dirty = true
    }

    xt := get_axis_input(p.window, glfw.KEY_D, glfw.KEY_A)
    zt := get_axis_input(p.window, glfw.KEY_W, glfw.KEY_S)
    yt := get_axis_input(p.window, glfw.KEY_SPACE, glfw.KEY_C)

    speed := glfw.GetKey(p.window, glfw.KEY_LEFT_CONTROL) == glfw.PRESS ? p.speed * 5 : p.speed
    if xt != 0 || yt != 0 || zt != 0 {
        dir := m.normalize(m.vec3{xt, yt, zt})
        move_dir := player_right(p) * dir.x + WORLD_UP * dir.y + player_forward(p) * dir.z
        p.pos += move_dir * speed * dt
        p.dirty = true
    }
}