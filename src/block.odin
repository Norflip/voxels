package main

Block :: enum u8 {
    Air = 0,
    Stone,
    Mantle,
    Dirt,
    Grass,
    Sand,
    Log,
    Leaves,
}

BLOCK_COUNT :: len(Block)

g_block_atlas : Atlas

block_init :: proc() {
    atlas_builder : Atlas_Builder
    atlas_builder_init(&atlas_builder, 8, 8, context.temp_allocator)
    defer atlas_builder_destroy(&atlas_builder)

    atlas_builder_add(&atlas_builder, "../assets/blocks/stone.png") // 0
    atlas_builder_add(&atlas_builder, "../assets/blocks/mantle.png") // 1
    atlas_builder_add(&atlas_builder, "../assets/blocks/dirt.png") // 2
    atlas_builder_add(&atlas_builder, "../assets/blocks/grass_top.png") // 3
    atlas_builder_add(&atlas_builder, "../assets/blocks/grass_side.png") // 4
    atlas_builder_add(&atlas_builder, "../assets/blocks/sand.png") // 5
    atlas_builder_add(&atlas_builder, "../assets/blocks/log_side.png") // 6
    atlas_builder_add(&atlas_builder, "../assets/blocks/log_top.png") // 7
    atlas_builder_add(&atlas_builder, "../assets/blocks/leaves.png") // 8

    g_block_atlas = atlas_builder_build("block_atlas", &atlas_builder)
}

block_is_solid :: #force_inline proc(b : Block) -> bool {
    assert(u8(b) < u8(BLOCK_COUNT))
    return b != Block.Air
}

block_create_face :: #force_inline proc(b : Block, neighbour : Block) -> bool {
    return block_is_solid(b) && !block_is_solid(neighbour)
}

block_get_preview_atlas_index :: proc(block : Block) -> i32 {
    assert(u8(block) < u8(BLOCK_COUNT))
    switch block {
    case Block.Stone:
        return 0
    case Block.Mantle:
        return 1
    case Block.Dirt:
        return 2
    case Block.Grass:
        return 4
    case Block.Sand:
        return 5
    case Block.Log:
        return 7
    case Block.Leaves:
        return 8
    case Block.Air:
        return -1
    }
    return -1
}

block_get_atlas_index :: proc(b : Block, face : int) -> (index : u32, ok : bool) {
    assert(u8(b) < u8(BLOCK_COUNT))
    assert(face >= 0 && face < 6)

    switch b {
    case Block.Stone:
        return 0, true
    case Block.Mantle:
        return 1, true
    case Block.Dirt:
        return 2, true
    case Block.Grass:
        if face == 2 do return 3, true
        if face == 3 do return 2, true
        return 4, true
    case Block.Sand:
        return 5, true
    case Block.Log:
        if face == 2 || face == 3 do return 7, true
        return 6, true
    case Block.Leaves:
        return 8, true
    case Block.Air:
        return 0, false
    }
    return 0, false
}
