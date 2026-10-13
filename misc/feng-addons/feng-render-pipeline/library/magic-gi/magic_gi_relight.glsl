#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D transfer_atlas;
layout(set = 0, binding = 1) uniform sampler2D primary_sky_atlas;
layout(set = 0, binding = 2) uniform sampler2D emission_atlas;
// Same block as the surface gather; lighting is evaluated in physical scene units.
// Exposure, receiver material, AO and pass strength are applied by the gather.
layout(set = 0, binding = 3, std140) uniform GIParams {
	mat4 inverse_projection;
	mat4 world_to_grid;
	mat4 view_to_world;
	vec4 grid;
	vec4 control;
	vec4 lighting_sh[7];
	vec4 sky_lighting_sh[7];
} params;
layout(set = 0, binding = 4, std430) writeonly buffer ProbeLighting {
	vec4 values[]; // secondary + emission RGB, primary sky RGB, per probe.
} probe_lighting;

vec3 unpack_sh(vec4 blocks[7], int coefficient) {
	int first = coefficient * 3;
	return vec3(blocks[first / 4][first % 4],
			blocks[(first + 1) / 4][(first + 1) % 4],
			blocks[(first + 2) / 4][(first + 2) % 4]);
}

void main() {
	int probe = int(gl_GlobalInvocationID.x);
	if (probe >= int(params.grid.w)) {
		return;
	}
	ivec2 position = ivec2(probe % 32, probe / 32);
	vec4 transfer[7];
	vec4 primary[3];
	for (int i = 0; i < 7; i++) {
		transfer[i] = texelFetch(transfer_atlas, ivec2(position.x * 7 + i, position.y), 0);
	}
	for (int i = 0; i < 3; i++) {
		primary[i] = texelFetch(primary_sky_atlas, ivec2(position.x * 3 + i, position.y), 0);
	}
	vec3 secondary = vec3(0.0);
	vec3 sky = vec3(0.0);
	for (int i = 0; i < 9; i++) {
		secondary += unpack_sh(transfer, i) * unpack_sh(params.lighting_sh, i);
		sky += primary[i / 4][i % 4] * 0.3183098861837907 * unpack_sh(params.sky_lighting_sh, i);
	}
	vec3 emission = texelFetch(emission_atlas, position, 0).rgb;
	probe_lighting.values[probe * 2] = vec4(max(secondary, vec3(0.0)) + max(emission, vec3(0.0)), 0.0);
	probe_lighting.values[probe * 2 + 1] = vec4(max(sky, vec3(0.0)), 0.0);
}
