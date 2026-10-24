package main
import "core:math"
import "core:sync"
import "core:math/rand"

Column_Heights :: [C_SIZE][C_SIZE]i32
Chunk_Noise :: Noise_Volume(C_SIZE, C_SIZE, 4, 8)

SEA_HEIGHT :: 64
SURFACE_HEIGHT :: 20.0 // baseline surface above sea level
FLATGRASS_HEIGHT :: 20

MOUNTAIN_BLEND :: 0.15
BIOME_BLEND :: 0.05

// much sharper than terrain, tree density only fades near biome borders
TREE_BLEND :: 0.01 

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

CARVE_BOUND :: 1.0 // must be >= max |carve_at|, i.e. the bound of noise_fbm

COLUMN_SHAPE_SIZE :: C_SIZE + 1
COLUMN_SHAPE_AREA :: COLUMN_SHAPE_SIZE * COLUMN_SHAPE_SIZE

SLOPE_RADIUS :: 1

// tree placement chance per candidate, blended across biome borders
// TODO: register per biome
@(private = "file", rodata)
BIOME_TREES := [Biome]f64 {
    .Plains    = 0.04,
    .Forest    = 0.4,
    .Desert    = 0.0,
    .Mountains = 0.0,
    .Flat      = 0.0,
}

Column_Shape :: struct {
    surface :     [COLUMN_SHAPE_AREA]f64,
    carve_amp :   [COLUMN_SHAPE_AREA]f64,
    squash :      [COLUMN_SHAPE_AREA]f64,
    trees :       [COLUMN_SHAPE_AREA]f32,
    origin :      ivec2, 
    air_above :   i32,   
    solid_below : i32,   
}

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

gen_column :: proc(w : ^World, loc : ivec2, heights : ^Column_Heights, shape : ^Column_Shape) {
     column : [H_SIZE]^Chunk

    key, _ := hunk_column_index(loc)
    hunk : ^Hunk
    {
        sync.rw_mutex_shared_guard(&w.hunks_mu)
        hunk = w.hunks[key]
    }

    for i in 0 ..< H_SIZE do column[i] = get_chunk(w, ivec3{loc.x, i32(i), loc.y})

    if .Gen_Flat in w.flags {
        shape^ = {}
        max_col_y := (FLATGRASS_HEIGHT / C_SIZE) + 1
        for i in 0 ..< max_col_y do gen_flat_shape(w, column[i], heights)
    } else {
        column_shape_fill(hunk, loc, shape)
        for i in 0 ..< H_SIZE do gen_shape(w, shape, column[i], heights)
    }

    gen_surface(w, hunk, &column, heights)
    if column[0] != nil do gen_mantle(w, column[0])
}


@(private = "file")
column_shape_fill :: proc(hunk : ^Hunk, col : ivec2, s : ^Column_Shape) {
    s.origin = col * C_SIZE
    hunk_origin := hunk.pos * H_WSIZE
    lx0 := s.origin.x - hunk_origin.x
    lz0 := s.origin.y - hunk_origin.y

    air_hi := min(f64)
    solid_lo := max(f64)
    for z in 0 ..< i32(COLUMN_SHAPE_SIZE) {
        for x in 0 ..< i32(COLUMN_SHAPE_SIZE) {
            cont := f64(noise_area_sample(&hunk.cont, lx0 + x, lz0 + z))
            temp := f64(noise_area_sample(&hunk.temperature, lx0 + x, lz0 + z))
            rain := f64(noise_area_sample(&hunk.rain, lx0 + x, lz0 + z))
            climate := Climate{temp, rain, cont}
            weights := biome_weights(climate, BIOME_BLEND)
            surface, carve_amp, squash := shape_from_weights(weights, cont)

            tree_weights := biome_weights(climate, TREE_BLEND)
            trees := 0.0
            for b in Biome do trees += tree_weights[b] * BIOME_TREES[b]

            i := z * COLUMN_SHAPE_SIZE + x
            s.surface[i] = surface
            s.carve_amp[i] = carve_amp
            s.squash[i] = squash
            s.trees[i] = f32(trees)

            band := squash > 0 ? carve_amp * CARVE_BOUND / squash : f64(H_SIZE * C_SIZE)
            air_hi = max(air_hi, surface + band)
            solid_lo = min(solid_lo, surface - band)
        }
    }
    // 1 block margin on each side for rounding
    s.air_above = i32(math.ceil(air_hi)) + 1
    s.solid_below = i32(math.floor(solid_lo)) - 1
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
gen_shape :: proc(w : ^World, shape : ^Column_Shape, chunk : ^Chunk, heights : ^Column_Heights) {
    base_y := chunk.pos.y * C_SIZE
    if base_y >= shape.air_above do return

    // top noise sample sits at base_y + C_SIZE, so the whole chunk is solid
    if base_y + C_SIZE < shape.solid_below {
        for x in 0 ..< i32(C_SIZE) {
            for z in 0 ..< i32(C_SIZE) {
                for y in 0 ..< i32(C_SIZE) do gen_set_block(w, chunk, x, y, z, .Stone)
                heights[x][z] = max(heights[x][z], base_y + C_SIZE - 1)
            }
        }
        return
    }

    vol : Chunk_Noise
    noise_vol_fill(&vol, w.seed, chunk.pos * C_SIZE, proc(seed : i64, wx, wy, wz : f64, ctx : rawptr) -> f64 {
            s := (^Column_Shape)(ctx)
            i := (i32(wz) - s.origin.y) * COLUMN_SHAPE_SIZE + (i32(wx) - s.origin.x)
            carve := carve_at(seed, wx, wy, wz)
            when ODIN_DEBUG do assert(abs(carve) <= CARVE_BOUND, "CARVE_BOUND too small for noise_fbm")
            return carve * s.carve_amp[i] + (s.surface[i] - wy) * s.squash[i]
        }, shape)

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
biome_weights :: #force_inline proc(c : Climate, blend : f64) -> (w : [Biome]f64) {
    d := biome_dist_sq(c)
    d_min := max(f64)
    for b in Biome {
        if b == .Flat do continue
        d_min = min(d_min, d[b])
    }

    total := 0.0
    for b in Biome {
        if b == .Flat do continue
        w[b] = math.exp((d_min - d[b]) / blend)
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


// replaces shape_at
@(private = "file")
shape_from_weights :: #force_inline proc(weights : [Biome]f64, cont : f64) -> (surface, carve_amp, squash : f64) {
    surface = f64(SEA_HEIGHT) + SURFACE_HEIGHT
    for b in Biome {
        s := BIOME_SHAPE[b]
        surface += weights[b] * (s.lift + cont * s.cont_amp)
        carve_amp += weights[b] * s.carve_amp
        squash += weights[b] * s.squash
    }
    return
}

@(private = "file")
height_gradient :: proc(h : ^Column_Heights, x, z : i32) -> (gx, gz : f32) {
    at :: proc(h : ^Column_Heights, x, z : i32) -> f32 {
        if x < 0 || x >= C_SIZE || z < 0 || z >= C_SIZE do return 0
        return f32(h[x][z])
    }
    gx = ((at(h, x + 1, z - 1) + 2 * at(h, x + 1, z) + at(h, x + 1, z + 1)) - (at(h, x - 1, z - 1) + 2 * at(h, x - 1, z) + at(h, x - 1, z + 1))) / 8
    gz = ((at(h, x - 1, z + 1) + 2 * at(h, x, z + 1) + at(h, x + 1, z + 1)) - (at(h, x - 1, z - 1) + 2 * at(h, x, z - 1) + at(h, x + 1, z - 1))) / 8
    return
}

// every non-air bottom cell must rest on terrain at exactly ground_y
// TODO: make this optional per stamp type
@(private = "file")
footprint_is_flat :: proc(s : Stamp, heights : ^Column_Heights, x, z, ground_y : i32) -> bool {
    for sz in 0 ..< s.size.z {
        for sx in 0 ..< s.size.x {
            if s.blocks[sz * s.size.x + sx] == .Air do continue
            gx := x + sx - s.anchor.x
            gz := z + sz - s.anchor.z
            if heights[gx][gz] != ground_y do return false
        }
    }
    return true
}

// dot(normalize(-gx, 1, -gz), up) >= min_up
@(private = "file")
slope_ok :: #force_inline proc(gx, gz, min_up : f32) -> bool {
    if min_up <= 0 do return true
    return gx * gx + gz * gz <= 1 / (min_up * min_up) - 1
}

plan_column_stamps :: proc(w : ^World, col : ivec2, heights : ^Column_Heights, shape : ^Column_Shape) {
    key, idx := hunk_column_index(col)
    hunk : ^Hunk
    {
        sync.rw_mutex_shared_guard(&w.hunks_mu)
        hunk = w.hunks[key]
    }
    if hunk == nil do return

    plan := &hunk.stamps[idx]
    plan^ = {}

    stamp := stamp_get(.Tree)
    lo, hi := stamp.foot_lo, stamp.foot_hi
    span := [2]i32{min(TREE_JITTER, TREE_CELL - (hi.x - lo.x)), min(TREE_JITTER, TREE_CELL - (hi.y - lo.y))}
    assert(span.x > 0 && span.y > 0, "stamp footprint wider than TREE_CELL")

    state : rand.Xoshiro256_Random_State
    gen := rand.xoshiro256_random_generator(&state)
    rand.reset(world_column_seed(w.seed, col), gen) 

    for cz in 0 ..< i32(C_SIZE / TREE_CELL) {
        for cx in 0 ..< i32(C_SIZE / TREE_CELL) {
            jx := rand.int31_max(span.x, gen)
            jz := rand.int31_max(span.y, gen)
            roll := rand.float32(gen)

            x := cx * TREE_CELL - lo.x + jx
            z := cz * TREE_CELL - lo.y + jz

            //if roll >= column_shape_trees(shape, x, z) do continue
            if roll >= shape.trees[z * COLUMN_SHAPE_SIZE + x] do continue

            top := heights[x][z]
            if top < 0 || top + 1 >= H_SIZE * C_SIZE do continue

            gx, gz := height_gradient(heights, x, z)
            if !slope_ok(gx, gz, stamp.min_up) do continue
            if !footprint_is_flat(stamp, heights, x, z, top) do continue

            ground := world_get_block(w, {col.x * C_SIZE + x, top, col.y * C_SIZE + z})
            if !stamp.ground(ground) do continue

            plan.items[plan.count] = {x = u8(x), z = u8(z), y = u16(top + 1), kind = .Tree}
            plan.count += 1
        }
    }
}

// caller guarantees col is .Decorating, so all 8 neighbours have terrain?
apply_column_stamps :: proc(w : ^World, col : ivec2) {
    key, idx := hunk_column_index(col)
    hunk : ^Hunk
    {
        sync.rw_mutex_shared_guard(&w.hunks_mu)
        hunk = w.hunks[key]
    }
    if hunk == nil do return

    plan := hunk.stamps[idx]
    for p in plan.items[:plan.count] {
        stamp := stamp_get(p.kind)
        pos := ivec3{col.x * C_SIZE + i32(p.x), i32(p.y), col.y * C_SIZE + i32(p.z)}
        origin := pos - stamp.anchor
        i := 0
        for y in 0 ..< stamp.size.y {
            for z in 0 ..< stamp.size.z {
                for x in 0 ..< stamp.size.x {
                    block := stamp.blocks[i]
                    i += 1
                    if block == .Air do continue

                    cell := origin + ivec3{x, y, z}
                    assert(abs((cell.x >> C_SHIFT) - col.x) <= 1 && abs((cell.z >> C_SHIFT) - col.y) <= 1, "stamp reaches past the 8-neighbour ring")
                    gen_stamp_block(w, cell, block)
                }
            }
        }
    }
}

/*
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
*/