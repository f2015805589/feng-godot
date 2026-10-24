#[compute]
#version 450
// Re-evaluate one current incident-radiance SH9 per immutable free-space cell.
// A separate post-relight projection pass writes the configurable octahedral
// response atlas. Keeping these passes separate makes the raw SH dependency
// explicit and avoids recomputing TransferMatrix products per angular texel.
layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) readonly buffer Transfer {
	float values[];
} transport;
layout(set = 0, binding = 1, std430) readonly buffer Sky {
	float values[];
} sky;
layout(set = 0, binding = 2, std430) readonly buffer Emission {
	float values[];
} emission;
layout(set = 0, binding = 3, std430) readonly buffer Sources {
	float values[];
} sources;
layout(set = 0, binding = 4, std140) uniform GIParams {
	mat4 inverse_projection;
	mat4 world_to_grid;
	mat4 view_to_world;
	vec4 grid;
	vec4 control;
	vec4 lighting_sh[7];
	vec4 sky_lighting_sh[7];
} params;
layout(set = 0, binding = 5, std430) readonly buffer Validity {
	uint values[];
} validity;
layout(set = 0, binding = 6, std430) writeonly buffer RawSH {
	float values[];
} raw_sh;
layout(set = 0, binding = 7, std430) readonly buffer ClipSourceIndices {
	int values[];
} clip_source_indices;

layout(push_constant, std430) uniform Configuration {
	int clip_cell_count;
	int source_probe_count;
	int emitter_count;
	int reserved;
} config;

const int RAW_SH_STRIDE = 28;

vec3 sh_coefficient(vec4 blocks[7], int coefficient) {
	int scalar = coefficient * 3;
	return vec3(blocks[scalar / 4][scalar % 4],
		blocks[(scalar + 1) / 4][(scalar + 1) % 4],
		blocks[(scalar + 2) / 4][(scalar + 2) % 4]);
}

bool finite_vec3(vec3 value) {
	return !any(isnan(value)) && !any(isinf(value));
}

void clear_raw_sh(int probe) {
	int base = probe * RAW_SH_STRIDE;
	for (int scalar = 0; scalar < 27; scalar++) {
		raw_sh.values[base + scalar] = 0.0;
	}
	raw_sh.values[base + 27] = 0.0;
}

void relight_cell(int clip_cell) {
	int source_probe = clip_source_indices.values[clip_cell];
	if (source_probe < 0 || source_probe >= config.source_probe_count ||
			validity.values[source_probe] == 0u) {
		clear_raw_sh(clip_cell);
		return;
	}
	vec3 combined_sh[9];
	for (int outgoing = 0; outgoing < 9; outgoing++) {
		vec3 value = vec3(0.0);
		for (int incoming = 0; incoming < 9; incoming++) {
			vec3 live_secondary = sh_coefficient(params.lighting_sh, incoming);
			vec3 live_sky = sh_coefficient(params.sky_lighting_sh, incoming);
			int transfer_base = source_probe * 243 + outgoing * 27 + incoming * 3;
			value += vec3(transport.values[transfer_base],
				transport.values[transfer_base + 1],
				transport.values[transfer_base + 2]) * live_secondary;
			value += sky.values[source_probe * 81 + outgoing * 9 + incoming] * live_sky;
		}
		for (int emitter_index = 0; emitter_index < config.emitter_count;
				emitter_index++) {
			int emission_base = (emitter_index * config.source_probe_count + source_probe) * 54
					+ outgoing * 6;
			int source_base = emitter_index * 6;
			for (int channel = 0; channel < 3; channel++) {
				value[channel] += emission.values[emission_base + channel]
						* sources.values[source_base + channel]
					+ emission.values[emission_base + 3 + channel]
						* sources.values[source_base + 3 + channel];
			}
		}
		if (!finite_vec3(value)) {
			clear_raw_sh(clip_cell);
			return;
		}
		combined_sh[outgoing] = value;
	}
	int base = clip_cell * RAW_SH_STRIDE;
	for (int coefficient = 0; coefficient < 9; coefficient++) {
		raw_sh.values[base + coefficient * 3] = combined_sh[coefficient].x;
		raw_sh.values[base + coefficient * 3 + 1] = combined_sh[coefficient].y;
		raw_sh.values[base + coefficient * 3 + 2] = combined_sh[coefficient].z;
	}
	// This is a data-validity token, not radiance alpha; valid black remains 1.
	raw_sh.values[base + 27] = 1.0;
}

void main() {
	uint index = gl_GlobalInvocationID.x;
	if (config.clip_cell_count <= 0 || config.source_probe_count <= 0 ||
			index >= uint(config.clip_cell_count)) {
		return;
	}
	relight_cell(int(index));
}
