#version 460 core

layout(location = 0) uniform mat4 u_vp;

layout(location = 0) in vec3 a_pos;
layout(location = 1) in vec3 a_color;

out vec3 v_color;

void main() {
	v_color = a_color;
	gl_Position = u_vp * vec4(a_pos, 1.0);
}