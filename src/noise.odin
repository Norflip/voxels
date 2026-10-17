package main
import "base:runtime"
import m "core:math/linalg/glsl"
import "core:math/noise"

Noise_Volume :: struct($SIZE_XZ, $SIZE_Y, $JUMP_XZ, $JUMP_Y : i32) where SIZE_XZ % JUMP_XZ == 0 && SIZE_Y % JUMP_Y == 0 {
    data : [(SIZE_XZ / JUMP_XZ + 1) * (SIZE_XZ / JUMP_XZ + 1) * (SIZE_Y / JUMP_Y + 1)]f64,
}

noise_vol_fill :: proc(volume : ^Noise_Volume($SIZE_XZ, $SIZE_Y, $JUMP_XZ, $JUMP_Y), seed : i64, offset : ivec3, sampler : proc(seed : i64, x, y, z : f64, ctx : rawptr) -> f64, ctx : rawptr = nil) {
    STEPS_XZ :: SIZE_XZ / JUMP_XZ + 1
    STEPS_Y :: SIZE_Y / JUMP_Y + 1

    for z : i32 = 0; z < STEPS_XZ; z += 1 {
        for x : i32 = 0; x < STEPS_XZ; x += 1 {
            for y : i32 = STEPS_Y - 1; y >= 0; y -= 1 {
                dx := offset.x + x * JUMP_XZ
                dy := offset.y + y * JUMP_Y
                dz := offset.z + z * JUMP_XZ
                volume.data[vol_index(volume, x, y, z)] = sampler(seed, f64(dx), f64(dy), f64(dz), ctx)
            }
        }
    }
}

noise_vol_sample :: proc(volume : ^Noise_Volume($SIZE_XZ, $SIZE_Y, $JUMP_XZ, $JUMP_Y), x, y, z : i32) -> f64 {
    assert(x >= 0 && y >= 0 && z >= 0 && x <= SIZE_XZ && y <= SIZE_Y && z <= SIZE_XZ)

    x0 := x / JUMP_XZ
    y0 := y / JUMP_Y
    z0 := z / JUMP_XZ

    // early exit if we don't need to interpolate
    if x % JUMP_XZ == 0 && y % JUMP_Y == 0 && z % JUMP_XZ == 0 do return volume.data[vol_index(volume, x0, y0, z0)]

    sx := f64(x % JUMP_XZ) / f64(JUMP_XZ)
    sy := f64(y % JUMP_Y) / f64(JUMP_Y)
    sz := f64(z % JUMP_XZ) / f64(JUMP_XZ)

    n000 := volume.data[vol_index(volume, x0, y0, z0)]
    n100 := volume.data[vol_index(volume, x0 + 1, y0, z0)]
    v00 := m.lerp(n000, n100, sx)

    n010 := volume.data[vol_index(volume, x0, y0 + 1, z0)]
    n110 := volume.data[vol_index(volume, x0 + 1, y0 + 1, z0)]
    v10 := m.lerp(n010, n110, sx)

    n001 := volume.data[vol_index(volume, x0, y0, z0 + 1)]
    n101 := volume.data[vol_index(volume, x0 + 1, y0, z0 + 1)]
    v01 := m.lerp(n001, n101, sx)

    n011 := volume.data[vol_index(volume, x0, y0 + 1, z0 + 1)]
    n111 := volume.data[vol_index(volume, x0 + 1, y0 + 1, z0 + 1)]
    v11 := m.lerp(n011, n111, sx)

    v0 := m.lerp(v00, v10, sy)
    v1 := m.lerp(v01, v11, sy)
    return m.lerp(v0, v1, sz)
}

@(private = "file")
vol_index :: #force_inline proc "contextless" (volume : ^Noise_Volume($SIZE_XZ, $SIZE_Y, $JUMP_XZ, $JUMP_Y), x, y, z : i32) -> i32 {
    STEPS_XZ :: SIZE_XZ / JUMP_XZ + 1
    STEPS_Y :: SIZE_Y / JUMP_Y + 1
    return (x * STEPS_Y * STEPS_XZ) + (y * STEPS_XZ) + z
}


Noise_Area :: struct($SIZE, $JUMP : i32) where SIZE % JUMP == 0 {
    data : [(SIZE / JUMP + 1) * (SIZE / JUMP + 1)]f32,
}

noise_area_fill :: proc(area : ^Noise_Area($SIZE, $JUMP), seed : i64, offset : ivec2, sampler : proc(seed : i64, x, z : f64, ctx : rawptr) -> f64, ctx : rawptr = nil) {
    STEPS :: SIZE / JUMP + 1

    for z : i32 = 0; z < STEPS; z += 1 {
        for x : i32 = 0; x < STEPS; x += 1 {
            wx := f64(offset.x + x * JUMP)
            wz := f64(offset.y + z * JUMP)
            area.data[z * STEPS + x] = f32(sampler(seed, wx, wz, ctx))
        }
    }
}

noise_area_sample :: proc(area : ^Noise_Area($SIZE, $JUMP), x, z : i32) -> f32 {
    STEPS :: SIZE / JUMP + 1
    i, sx, sz := area_cell(area, x, z)
    return bilerp(area.data[i], area.data[i + 1], area.data[i + STEPS], area.data[i + STEPS + 1], sx, sz)
}

@(private = "file")
area_cell :: #force_inline proc(area : ^Noise_Area($SIZE, $JUMP), x, z : i32) -> (i : i32, sx, sz : f32) {
    STEPS :: SIZE / JUMP + 1
    assert(x >= 0 && z >= 0 && x <= SIZE && z <= SIZE)
    x0 := min(x / JUMP, STEPS - 2)
    z0 := min(z / JUMP, STEPS - 2)
    sx = f32(x - x0 * JUMP) / f32(JUMP)
    sz = f32(z - z0 * JUMP) / f32(JUMP)
    i = z0 * STEPS + x0
    return
}

bilerp :: #force_inline proc(a00, a10, a01, a11, sx, sz : f32) -> f32 {
    return m.lerp(m.lerp(a00, a10, sx), m.lerp(a01, a11, sx), sz)
}

/*
    fractal brownian
*/
//TODO: should we multiply the octave index by some constant to decorrelate octaves?

// fbm returns [-1,1]
noise_fbm :: proc {
    noise_fbm_2d,
    noise_fbm_3d,
}

noise_fbm_2d :: proc(seed : i64, x, y : f64, octaves : i32, frequency : f64, persistence : f64 = 0.5, lacunarity : f64 = 2.0) -> f64 {
    total := 0.0
    frequency := frequency
    amplitude := 1.0
    max_value := 0.0

    for i in 0 ..< octaves {
        pos := [2]f64{x * frequency, y * frequency}
        total += f64(noise.noise_2d(seed + i64(i), pos)) * amplitude
        max_value += amplitude
        amplitude *= persistence
        frequency *= lacunarity
    }

    return total / max_value
}

noise_fbm_3d :: proc(seed : i64, x, y, z : f64, octaves : i32, frequency : f64, persistence : f64 = 0.5, lacunarity : f64 = 2.0) -> f64 {
    total := 0.0
    frequency := frequency
    amplitude := 1.0
    max_value := 0.0

    for i in 0 ..< octaves {
        pos := [3]f64{x * frequency, y * frequency, z * frequency}
        total += f64(noise.noise_3d_improve_xz(seed + i64(i), pos)) * amplitude
        max_value += amplitude
        amplitude *= persistence
        frequency *= lacunarity
    }

    return total / max_value
}
