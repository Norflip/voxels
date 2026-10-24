package main

TREE_CELL :: 4
TREE_JITTER :: 2 // min spacing between anchors is TREE_CELL - TREE_JITTER + 1
#assert(C_SIZE % TREE_CELL == 0)
#assert(TREE_JITTER <= TREE_CELL)

Stamp_Kind :: enum u8 {
    Tree,
}

Stamp :: struct {
    size :    ivec3,
    anchor :  ivec3,
    blocks :  []Block,
    min_up :  f32, // min dot(terrain normal, up) at the anchor
    ground :  proc(b : Block) -> bool,
    foot_lo : [2]i32,
    foot_hi : [2]i32,
}

@(private = "file")
A :: Block.Air
@(private = "file")
S :: Block.Log
@(private = "file")
L :: Block.Leaves

//odinfmt: disable
@(private = "file", rodata)
TREE_BLOCKS := [5 * 7 * 5]Block {
    // y = 0
    A, A, A, A, A,
    A, A, A, A, A,
    A, A, S, A, A,
    A, A, A, A, A,
    A, A, A, A, A,
    // y = 1
    A, A, A, A, A,
    A, A, A, A, A,
    A, A, S, A, A,
    A, A, A, A, A,
    A, A, A, A, A,
    // y = 2
    A, A, A, A, A,
    A, A, A, A, A,
    A, A, S, A, A,
    A, A, A, A, A,
    A, A, A, A, A,
    // y = 3
    A, L, L, L, A,
    L, L, L, L, L,
    L, L, S, L, L,
    L, L, L, L, L,
    A, L, L, L, A,
    // y = 4
    A, L, L, L, A,
    L, L, L, L, L,
    L, L, S, L, L,
    L, L, L, L, L,
    A, L, L, L, A,
    // y = 5
    A, A, A, A, A,
    A, L, L, L, A,
    A, L, S, L, A,
    A, L, L, L, A,
    A, A, A, A, A,
    // y = 6
    A, A, A, A, A,
    A, A, L, A, A,
    A, L, L, L, A,
    A, A, L, A, A,
    A, A, A, A, A,
}
//odinfmt: enable

@(private = "file")
g_stamps : [Stamp_Kind]Stamp

stamps_init :: proc() {
    g_stamps[.Tree] = {
        size = {5, 7, 5},
        anchor = {2, 0, 2},
        blocks = TREE_BLOCKS[:],
        min_up = 0.7,
        ground = proc(b : Block) -> bool {
            return b == .Grass || b == .Dirt
        },
    }

    for &s, kind in g_stamps {
        assert(s.blocks != nil, "stamp kind missing from stamps_init")
        s.foot_lo, s.foot_hi = stamp_footprint(s)
    }
}

stamp_get :: #force_inline proc(kind : Stamp_Kind) -> Stamp {
    return g_stamps[kind]
}

stamp_index :: #force_inline proc(s : Stamp, x, y, z : i32) -> i32 {
    return (y * s.size.z + z) * s.size.x + x
}

// bounds of the bottom layer's non-air cells relative to the anchor
// planted stamps are anchored on a solid bottom cell
@(private = "file")
stamp_footprint :: proc(s : Stamp) -> (lo, hi : [2]i32) {
    assert(len(s.blocks) == int(s.size.x * s.size.y * s.size.z), "stamp blocks length does not match size")
    assert(s.anchor.y == 0, "planted stamp must be anchored on its bottom layer")
    assert(s.blocks[stamp_index(s, s.anchor.x, 0, s.anchor.z)] != .Air, "planted stamp anchor must be a solid bottom cell")

    lo = {max(i32), max(i32)}
    hi = {min(i32), min(i32)}
    for z in 0 ..< s.size.z {
        for x in 0 ..< s.size.x {
            if s.blocks[stamp_index(s, x, 0, z)] == .Air do continue
            d := [2]i32{x, z} - s.anchor.xz
            lo = {min(lo.x, d.x), min(lo.y, d.y)}
            hi = {max(hi.x, d.x), max(hi.y, d.y)}
        }
    }
    return
}
