# Voxels

A from-scratch voxel engine written in [Odin](https://odin-lang.org/) on OpenGL 4.6. Terrain is generated and meshed on background threads while the main thread streams finished meshes into a single persistently mapped GPU buffer and draws the whole world with one multi-draw-indirect call. The project is a rewrite of an earlier voxel engine, rebuilt around a GPU-driven renderer and a lock-aware streaming pipeline.

> **Work in progress:** this project is under active development, so features, structure and performance may change as I keep building on it.

## About

The renderer keeps every chunk mesh in one large vertex pool and submits the visible world as a single indirect draw. Faces are packed into sixteen bytes and reconstructed in the vertex shader from the vertex index, so there are no vertex attribute arrays. Chunks are culled against the frustum, then per face direction, and each remaining direction becomes its own command, so back faces never reach the GPU. Freed mesh pages are only reused once a fence confirms the GPU is done reading them.

Generation runs on a dedicated thread, one column of chunks at a time, and a separate thread meshes finished chunks. A per-column state machine makes sure a column is only decorated once all its neighbours have terrain, and only meshed once all its neighbours are decorated, so structures can cross chunk borders without racing generation.

Terrain is built from continentalness, temperature and rainfall noise. Those classify the world into biomes, and a softmax blend over climate distance mixes each biome's shape parameters so borders have no seams. A 3D density function carves overhangs, a surface pass lays down biome-specific blocks, and deterministic stamps place small structures from the world seed.

Clouds are placed by a compute shader that culls a grid against a mask texture and the frustum, then drawn with a depth prepass so overlapping translucent boxes never double-blend. A sun orbits the sky and lights the terrain, the sky and the clouds from a single shared rotation. A debug overlay with a freezable culling camera shows exactly what the renderer skipped.