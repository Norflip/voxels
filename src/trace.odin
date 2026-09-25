package main
import math "core:math/linalg/glsl"

World_Hit :: struct {
    pos :       ivec3,
    world_pos : vec3,
    normal :    ivec3,
    block :     Block,
    valid :     bool,
    distance :  f32,
}

// eye and dir in world space
world_trace :: proc(world : ^World, eye, dir : vec3, max_distance : f32, hit : ^World_Hit) -> bool {
    f := math.floor(eye)
    s := math.sign(dir)

    pos := ivec3{i32(f.x), i32(f.y), i32(f.z)}
    step := ivec3{i32(s.x), i32(s.y), i32(s.z)}

    fr := eye - math.floor(eye)
    t_p := vec3(step) / dir
    tmax_x := t_p.x * ((dir.x > 0.0) ? (1.0 - fr.x) : fr.x)
    tmax_y := t_p.y * ((dir.y > 0.0) ? (1.0 - fr.y) : fr.y)
    tmax_z := t_p.z * ((dir.z > 0.0) ? (1.0 - fr.z) : fr.z)

    max_steps := i32(max_distance * math.SQRT_THREE) + 2
    normal := ivec3{0, 0, 0}
    t_entry : f32 = 0.0

    for _ in 0 ..< max_steps {
        if t_entry > max_distance do break

        block := world_get_block(world, pos)
        if block_is_solid(block) {
            hit.pos = pos
            hit.block = block
            hit.normal = normal
            hit.world_pos = eye + dir * t_entry
            hit.distance = t_entry
            hit.valid = true
            return true
        }

        if tmax_x < tmax_y {
            if tmax_z < tmax_x {
                t_entry = tmax_z
                tmax_z += t_p.z
                pos.z += step.z
                normal = ivec3{0, 0, -step.z}
            } else {
                t_entry = tmax_x
                tmax_x += t_p.x
                pos.x += step.x
                normal = ivec3{-step.x, 0, 0}
            }
        } else {
            if tmax_z < tmax_y {
                t_entry = tmax_z
                tmax_z += t_p.z
                pos.z += step.z
                normal = ivec3{0, 0, -step.z}
            } else {
                t_entry = tmax_y
                tmax_y += t_p.y
                pos.y += step.y
                normal = ivec3{0, -step.y, 0}
            }
        }
    }

    return false
}
