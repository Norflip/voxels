package main

import "core:sync"

MAX_STAMPS_PER_COLUMN :: 8
BOULDER_ATTEMPTS :: 4
BOULDER_CHANCE_PERCENT :: 80

Stamp_Kind :: enum u8 {
    Boulder,
}

Stamp :: struct {
    size :   ivec3,
    anchor : ivec3,
    blocks : []Block,
}

Stamp_Placement :: struct {
    pos :  ivec3,
    kind : Stamp_Kind,
}

Column_Stamps :: struct {
    count : u8,
    items : [MAX_STAMPS_PER_COLUMN]Stamp_Placement,
}

@(private = "file", rodata)
BOULDER_BLOCKS := [3 * 2 * 3]Block {
    .Stone, .Stone, .Stone,
    .Stone, .Stone, .Stone,
    .Stone, .Stone, .Stone,

    .Air,   .Stone, .Air,
    .Stone, .Stone, .Stone,
    .Air,   .Stone, .Air,
}

stamp_get :: proc(kind : Stamp_Kind) -> Stamp {
    switch kind {
    case .Boulder:
        return {size = {3, 2, 3}, anchor = {1, 0, 1}, blocks = BOULDER_BLOCKS[:]}
    }
    panic("stamp_get: unknown stamp kind")
}

@(private = "file")
splitmix64 :: #force_inline proc(state : ^u64) -> u64 {
    state^ += 0x9E3779B97F4A7C15
    z := state^
    z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
    z = (z ~ (z >> 27)) * 0x94D049BB133111EB
    return z ~ (z >> 31)
}

// replace with an odinlang builtin proc
@(private = "file")
column_rng :: proc(seed : i64, col : ivec2) -> u64 {
    state := u64(seed) ~ 0x5747_4D50 ~ (u64(u32(col.x)) << 32 | u64(u32(col.y)))
    splitmix64(&state)
    return state
}

plan_column_stamps :: proc(w : ^World, col : ivec2, heights : ^Column_Heights) {
    key, idx := hunk_column_index(col)
    hunk : ^Hunk
    {
        sync.rw_mutex_shared_guard(&w.hunks_mu)
        hunk = w.hunks[key]
    }
    if hunk == nil do return

    plan := &hunk.stamps[idx]
    plan^ = {}

    rng := column_rng(w.seed, col)
    for _ in 0 ..< BOULDER_ATTEMPTS {
        r := splitmix64(&rng)
        if r % 100 >= BOULDER_CHANCE_PERCENT do continue
        if plan.count == MAX_STAMPS_PER_COLUMN do break

        x := i32((r >> 8) & (C_SIZE - 1))
        z := i32((r >> 16) & (C_SIZE - 1))
        top := heights[x][z]
        if top < 0 || top + 1 >= H_SIZE * C_SIZE do continue

        plan.items[plan.count] = {
            pos  = {col.x * C_SIZE + x, top + 1, col.y * C_SIZE + z},
            kind = .Boulder,
        }
        plan.count += 1
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
        origin := p.pos - stamp.anchor
        i := 0
        for y in 0 ..< stamp.size.y {
            for z in 0 ..< stamp.size.z {
                for x in 0 ..< stamp.size.x {
                    block := stamp.blocks[i]
                    i += 1
                    if block == .Air do continue

                    cell := origin + ivec3{x, y, z}
                    assert(abs((cell.x >> C_SHIFT) - col.x) <= 1 && abs((cell.z >> C_SHIFT) - col.y) <= 1,
                        "stamp reaches past the 8-neighbour ring")
                    gen_stamp_block(w, cell, block)
                }
            }
        }
    }
}