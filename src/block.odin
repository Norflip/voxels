package main

Block :: enum u8 {
    Air = 0,
    Stone,
    Mantle,
    Dirt,
}

block_is_solid :: #force_inline proc "contextless" (b : Block) -> bool {
    return b != Block.Air
}

block_create_face :: #force_inline proc "contextless" (b : Block, neighbour : Block) -> bool {
    return block_is_solid(b) && !block_is_solid(neighbour)
}
