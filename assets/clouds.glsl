#version 460 core
layout(local_size_x = 16, local_size_y = 16) in;

#define CLOUD_SIZE 16.0
#define CLOUD_HEIGHT 8.0
#define CLOUD_ALTITUDE 200.0

struct Cmd  { uint count, instance_count, first, base_instance; };
struct CloudInstance { vec3 pos; uint cell; };
layout(binding = 0, std430) buffer CmdBuf { Cmd cmd; };
layout(binding = 1, std430) writeonly buffer CloudInstanceBuffer { CloudInstance instances[]; };

layout(binding = 0) uniform sampler2D u_mask;

layout(location = 0) uniform vec3 u_eye;
layout(location = 1) uniform vec2 u_offset;
layout(location = 2) uniform ivec2 u_grid_min;
layout(location = 3) uniform int u_grid_size;
layout(location = 4) uniform vec4 u_planes[6];

bool aabb_visible(vec3 mn, vec3 mx) {
	for (int i = 0; i < 6; ++i) {
		vec3 p = mix(mn, mx, greaterThan(u_planes[i].xyz, vec3(0.0)));
		if (dot(u_planes[i].xyz, p) + u_planes[i].w < 0.0) return false;
	}
	return true;
}

void main() {
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	if (id.x >= u_grid_size || id.y >= u_grid_size) 
		return;

	int tex_size = textureSize(u_mask, 0).x;

	ivec2 grid_pos = u_grid_min + id; 
	if (texelFetch(u_mask, grid_pos & ivec2(tex_size - 1), 0).a < 0.5) 
		return;

    vec3 bottom_pos = vec3(float(grid_pos.x) * CLOUD_SIZE + u_offset.x, CLOUD_ALTITUDE, float(grid_pos.y) * CLOUD_SIZE + u_offset.y);
	if (!aabb_visible(bottom_pos, bottom_pos + vec3(CLOUD_SIZE, CLOUD_HEIGHT, CLOUD_SIZE))) return;

	uint idx = atomicAdd(cmd.instance_count, 1u);
	instances[idx] = CloudInstance(bottom_pos, 0);
}