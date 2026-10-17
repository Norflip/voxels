package main
import "core:math"
import "core:sync"

Column_Heights :: [C_SIZE][C_SIZE]i32
Chunk_Noise :: Noise_Volume(C_SIZE, C_SIZE, 4, 8)

SEA_HEIGHT :: 64
SURFACE_HEIGHT :: 20.0 // baseline surface above sea level
FLATGRASS_HEIGHT :: 20

MOUNTAIN_BLEND :: 0.15
BIOME_BLEND :: 0.05

// continental
CONT_OCTAVE :: 4
CONT_FREQ :: 1.0 / 700.0

// 3D density carve
DENSE_OCTAVE :: 4
DENSE_FREQ :: 1.0 / 110.0

// climate
TEMP_OCTAVE :: 3
TEMP_FREQ :: 1.0 / 1500.0
RAIN_OCTAVE :: 3
RAIN_FREQ :: 1.0 / 1100.0

// selector
SELECT_OCTAVE :: 4
SELECT_FREQ :: 1.0 / 60.0
SELECT_SHARPNESS :: 6.0

Biome :: enum u8 {
    Plains,
    Forest,
    Desert,
    Mountains,
    Flat,
}

// temp, rain, continentalness
@(private = "file")
Climate :: [3]f64

@(private = "file")
Biome_Shape :: struct {
    target :    Climate, 
    lift :      f64,     // added to SEA_HEIGHT + SURFACE_HEIGHT
    cont_amp :  f64,     
    carve_amp : f64,     
    squash :    f64,     
}

@(private = "file")
Biome_Surface :: struct {
    top :   Block,
    sub :   Block,
    depth : i32,
}

@(private = "file", rodata)
BIOME_SHAPE := [Biome]Biome_Shape {
    .Plains    = {target = {-0.15, -0.1, -0.05}, lift = 0, cont_amp = 28, carve_amp = 10, squash = 0.6},
    .Forest    = {target = {0.0, 0.2, -0.05}, lift = 4, cont_amp = 28, carve_amp = 12, squash = 0.4},
    .Desert    = {target = {0.2, -0.15, -0.05}, lift = -4, cont_amp = 20, carve_amp = 6, squash = 0.7},
    .Mountains = {target = {0.0, 0.0, 0.35}, lift = 45, cont_amp = 28, carve_amp = 22, squash = 0.2},
    .Flat      = {},
}

@(private = "file", rodata)
BIOME_SURFACE := [Biome]Biome_Surface {
    .Plains    = {top = .Dirt, sub = .Dirt, depth = 3},
    .Forest    = {top = .Grass, sub = .Dirt, depth = 3},
    .Desert    = {top = .Sand, sub = .Sand, depth = 4},
    .Mountains = {top = .Stone, sub = .Stone, depth = 0},
    .Flat      = {top = .Grass, sub = .Dirt, depth = 3},
}

gen_column :: proc(w : ^World, loc : ivec2, heights : ^Column_Heights) {
    column : [H_SIZE]^Chunk

    key, _ := hunk_column_index(loc)
    hunk : ^Hunk
    {
        sync.rw_mutex_shared_guard(&w.hunks_mu)
        hunk = w.hunks[key]
    }

    if .Gen_Flat in w.flags {
        max_col_y := (FLATGRASS_HEIGHT / C_SIZE) + 1
        for i in 0 ..< max_col_y {
            column[i] = get_chunk(w, ivec3{loc.x, i32(i), loc.y})
            gen_flat_shape(w, column[i], heights)
        }
    } else {
        for i in 0 ..< H_SIZE {
            column[i] = get_chunk(w, ivec3{loc.x, i32(i), loc.y})
            gen_shape(w, hunk, column[i], heights)
        }
    }

    gen_surface(w, hunk, &column, heights)
    if column[0] != nil do gen_mantle(w, column[0])
}

hunk_gen_climate :: proc(w : ^World, hunk : ^Hunk) {
    if .Gen_Flat in w.flags {
        for &b in hunk.biomes do b = .Flat
        return
    }

    origin := hunk.pos * H_WSIZE
    noise_area_fill(&hunk.cont, w.seed, origin, proc(seed : i64, x, z : f64, ctx : rawptr) -> f64 {
            scale := (^World)(ctx).biome_scale
            return noise_fbm(seed + 0x44, x, z, CONT_OCTAVE, CONT_FREQ / scale)
        }, w)
    noise_area_fill(&hunk.temperature, w.seed, origin, proc(seed : i64, x, z : f64, ctx : rawptr) -> f64 {
            scale := (^World)(ctx).biome_scale
            return noise_fbm(seed + 0x55, x, z, TEMP_OCTAVE, TEMP_FREQ / scale)
        }, w)
    noise_area_fill(&hunk.rain, w.seed, origin, proc(seed : i64, x, z : f64, ctx : rawptr) -> f64 {
            scale := (^World)(ctx).biome_scale
            return noise_fbm(seed + 0x66, x, z, RAIN_OCTAVE, RAIN_FREQ / scale)
        }, w)

    for i in 0 ..< len(hunk.biomes) {
        hunk.biomes[i] = classify_biome(hunk.temperature.data[i], hunk.rain.data[i], hunk.cont.data[i])
    }
}

@(private = "file")
gen_shape :: proc(w : ^World, hunk : ^Hunk, chunk : ^Chunk, heights : ^Column_Heights) {
    vol : Chunk_Noise
    noise_vol_fill(&vol, w.seed, chunk.pos * C_SIZE, proc(seed : i64, wx, wy, wz : f64, ctx : rawptr) -> f64 {
            h := (^Hunk)(ctx)
            origin := h.pos * H_WSIZE
            lx := i32(wx) - origin.x
            lz := i32(wz) - origin.y

            cont := f64(noise_area_sample(&h.cont, lx, lz))
            temp := f64(noise_area_sample(&h.temperature, lx, lz))
            rain := f64(noise_area_sample(&h.rain, lx, lz))

            surface, carve_amp, squash := shape_at(cont, temp, rain)
            carve := carve_at(seed, wx, wy, wz) * carve_amp
            return carve + (surface - wy) * squash
        }, hunk)

    base_y := chunk.pos.y * C_SIZE
    for x in 0 ..< i32(C_SIZE) {
        for z in 0 ..< i32(C_SIZE) {
            for y : i32 = C_SIZE - 1; y >= 0; y -= 1 {
                d := noise_vol_sample(&vol, x, y, z)
                if d > 0 {
                    gen_set_block(w, chunk, x, y, z, .Stone)
                    if heights[x][z] < base_y + y do heights[x][z] = base_y + y
                }
            }
        }
    }
}

@(private = "file")
gen_flat_shape :: proc(w : ^World, chunk : ^Chunk, heights : ^Column_Heights) {
    base_y := chunk.pos.y * C_SIZE
    for x in 0 ..< i32(C_SIZE) {
        for z in 0 ..< i32(C_SIZE) {
            for y : i32 = C_SIZE - 1; y >= 0; y -= 1 {
                world_y := base_y + y
                if world_y > FLATGRASS_HEIGHT do continue
                gen_set_block(w, chunk, x, y, z, .Stone)
            }
        }
    }

    for x in 0 ..< C_SIZE {
        for z in 0 ..< C_SIZE {
            heights[x][z] = FLATGRASS_HEIGHT
        }
    }
}

@(private = "file")
gen_surface :: proc(w : ^World, hunk : ^Hunk, column : ^[H_SIZE]^Chunk, heights : ^Column_Heights) {
    base_x := (column[0].pos.x & (H_SIZE - 1)) * C_SIZE
    base_z := (column[0].pos.z & (H_SIZE - 1)) * C_SIZE

    for x in 0 ..< i32(C_SIZE) {
        for z in 0 ..< i32(C_SIZE) {
            top := heights[x][z]
            if top < 0 do continue

            chunk := column[top >> C_SHIFT]
            if chunk == nil do continue

            surf := BIOME_SURFACE[hunk_biome_at(w, hunk, base_x + x, base_z + z)]
            gen_set_block(w, chunk, x, top & (C_SIZE - 1), z, surf.top)

            for y := top - 1; y > top - 1 - surf.depth && y > 0; y -= 1 {
                sub_chunk := column[y >> C_SHIFT]
                if sub_chunk == nil do break
                if chunk_get_block(sub_chunk, x, y & (C_SIZE - 1), z) != .Stone do break
                gen_set_block(w, sub_chunk, x, y & (C_SIZE - 1), z, surf.sub)
            }
        }
    }
}

@(private = "file")
gen_mantle :: proc(w : ^World, bottom : ^Chunk) {
    assert(bottom.pos.y == 0)
    for x in 0 ..< i32(C_SIZE) {
        for z in 0 ..< i32(C_SIZE) {
            gen_set_block(w, bottom, x, 0, z, .Mantle)
        }
    }
}

@(private = "file")
hunk_biome_at :: proc(w : ^World, hunk : ^Hunk, lx, lz : i32) -> Biome {
    if .Gen_Flat in w.flags do return .Flat
    temp := noise_area_sample(&hunk.temperature, lx, lz)
    rain := noise_area_sample(&hunk.rain, lx, lz)
    cont := noise_area_sample(&hunk.cont, lx, lz)
    return classify_biome(temp, rain, cont)
}

@(private = "file")
biome_dist_sq :: #force_inline proc(c : Climate) -> (d : [Biome]f64) {
    for b in Biome {
        if b == .Flat do continue
        diff := BIOME_SHAPE[b].target - c
        d[b] = diff.x * diff.x + diff.y * diff.y + diff.z * diff.z
    }
    return
}

// 0 below edge - width, 1 above edge + width
soft_step :: #force_inline proc(edge, width, x : f64) -> f64 {
    t := clamp((x - (edge - width)) / (2 * width), 0, 1)
    return t * t * (3 - 2 * t)
}

@(private = "file")
classify_biome :: proc(temp, rain, cont : f32) -> Biome {
    d := biome_dist_sq({f64(temp), f64(rain), f64(cont)})
    best := Biome.Plains
    for b in Biome {
        if b == .Flat do continue
        if d[b] < d[best] do best = b
    }
    return best
}

@(private = "file")
biome_weights :: #force_inline proc(c : Climate) -> (w : [Biome]f64) {
    d := biome_dist_sq(c)
    d_min := max(f64)
    for b in Biome {
        if b == .Flat do continue
        d_min = min(d_min, d[b])
    }

    total := 0.0
    for b in Biome {
        if b == .Flat do continue
        w[b] = math.exp((d_min - d[b]) / BIOME_BLEND)
        total += w[b]
    }
    for b in Biome do w[b] /= total
    return
}

@(private = "file")
carve_at :: #force_inline proc(seed : i64, x, y, z : f64) -> f64 {
    sel := clamp(noise_fbm(seed + 0x13, x, y, z, SELECT_OCTAVE, SELECT_FREQ) * SELECT_SHARPNESS + 0.5, 0, 1)
    if sel <= 0 do return noise_fbm(seed + 0x11, x, y, z, DENSE_OCTAVE, DENSE_FREQ)
    if sel >= 1 do return noise_fbm(seed + 0x12, x, y, z, DENSE_OCTAVE, DENSE_FREQ)
    lo := noise_fbm(seed + 0x11, x, y, z, DENSE_OCTAVE, DENSE_FREQ)
    hi := noise_fbm(seed + 0x12, x, y, z, DENSE_OCTAVE, DENSE_FREQ)
    return lo + (hi - lo) * sel
}

@(private = "file")
shape_at :: #force_inline proc(cont, temp, rain : f64) -> (surface, carve_amp, squash : f64) {
    weights := biome_weights({temp, rain, cont})
    surface = f64(SEA_HEIGHT) + SURFACE_HEIGHT
    for b in Biome {
        s := BIOME_SHAPE[b]
        surface += weights[b] * (s.lift + cont * s.cont_amp)
        carve_amp += weights[b] * s.carve_amp
        squash += weights[b] * s.squash
    }
    return
}
