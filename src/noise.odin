package main
import "base:runtime"
import m "core:math/linalg/glsl"
import "core:math/noise"

JUMPS_XZ :: 8
JUMPS_Y :: 16
STEPS_XZ :: (C_SIZE / JUMPS_XZ) + 1
STEPS_Y :: (C_SIZE / JUMPS_Y) + 1

// sanity check
#assert(C_SIZE % JUMPS_XZ == 0)
#assert(C_SIZE % JUMPS_Y == 0)

Noise_Volume :: [STEPS_XZ * STEPS_XZ * STEPS_Y]f64

noise_vol_fill :: proc(volume : ^Noise_Volume, seed : i64, offset : ivec3, sampler : proc(seed : i64, x, y, z : f64, ctx : rawptr) -> f64, ctx : rawptr = nil) {
    for z : i32 = 0; z < STEPS_XZ; z += 1 {
        for x : i32 = 0; x < STEPS_XZ; x += 1 {
            for y : i32 = STEPS_Y - 1; y >= 0; y -= 1 {
                dx := offset.x + x * JUMPS_XZ
                dy := offset.y + y * JUMPS_Y
                dz := offset.z + z * JUMPS_XZ
                volume[vol_index(x, y, z)] = sampler(seed, f64(dx), f64(dy), f64(dz), ctx)
            }
        }
    }
}

noise_vol_sample :: proc(volume : ^Noise_Volume, x, y, z : i32) -> f64 {
    assert(x >= 0 && y >= 0 && z >= 0 && x < C_SIZE + 1 && y < C_SIZE + 1 && z < C_SIZE + 1)

    x0 := x / JUMPS_XZ
    y0 := y / JUMPS_Y
    z0 := z / JUMPS_XZ

    // early exit if we don't need to interpolate
    if x % JUMPS_XZ == 0 && y % JUMPS_Y == 0 && z % JUMPS_XZ == 0 do return volume[vol_index(x0, y0, z0)]

    sx := f64(x % JUMPS_XZ) / f64(JUMPS_XZ)
    sy := f64(y % JUMPS_Y) / f64(JUMPS_Y)
    sz := f64(z % JUMPS_XZ) / f64(JUMPS_XZ)

    n000 := volume[vol_index(x0, y0, z0)]
    n100 := volume[vol_index(x0 + 1, y0, z0)]
    v00 := m.lerp(n000, n100, sx)

    n010 := volume[vol_index(x0, y0 + 1, z0)]
    n110 := volume[vol_index(x0 + 1, y0 + 1, z0)]
    v10 := m.lerp(n010, n110, sx)

    n001 := volume[vol_index(x0, y0, z0 + 1)]
    n101 := volume[vol_index(x0 + 1, y0, z0 + 1)]
    v01 := m.lerp(n001, n101, sx)

    n011 := volume[vol_index(x0, y0 + 1, z0 + 1)]
    n111 := volume[vol_index(x0 + 1, y0 + 1, z0 + 1)]
    v11 := m.lerp(n011, n111, sx)

    v0 := m.lerp(v00, v10, sy)
    v1 := m.lerp(v01, v11, sy)
    return m.lerp(v0, v1, sz)
}

@(private = "file")
vol_index :: #force_inline proc "contextless" (x, y, z : i32) -> i32 {
    return (x * STEPS_Y * STEPS_XZ) + (y * STEPS_XZ) + z
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
        pos := [3]f64{x * frequency, z * frequency, y * frequency}
        total += f64(noise.noise_3d_improve_xz(seed + i64(i), pos)) * amplitude
        max_value += amplitude
        amplitude *= persistence
        frequency *= lacunarity
    }

    return total / max_value
}
