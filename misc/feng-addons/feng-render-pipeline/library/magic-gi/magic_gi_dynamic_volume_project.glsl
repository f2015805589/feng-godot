#[compute]
#version 450

// Project the currently relit incident-radiance SH9 tensor into a small
// octahedral direction-response tile for each free-space volume source cell.
// This remains dynamic: the input SH buffer is rewritten by the live relight
// stage when lighting/sky/emission changes. No material, exposure, sky-owner,
// or visibility weighting is applied here.
layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) readonly buffer RawSH {
	float values[]; // per cell: 9 RGB SH coefficients (27 floats), validity token.
} source_sh;
layout(set = 0, binding = 1, std430) readonly buffer ReceiverMoments {
	float values[]; // per cell: 64 oct texels, each [mean distance, square distance].
} source_moments;
layout(set = 0, binding = 2, std430) readonly buffer ClipSourceIndices {
	int values[];
} clip_source_indices;

layout(rgba32f, set = 1, binding = 0) uniform writeonly image3D response_atlas;
layout(rg32f, set = 1, binding = 1) uniform writeonly image3D moment_atlas;

layout(push_constant, std430) uniform ProjectionConfig {
	int clip_cell_count;
	int source_probe_count;
	int dim_x;
	int dim_y;
	int dim_z;
	int angular_resolution; // interior N; supported values are 8, 12, and 16.
	int tile_size; // N + 2, including one folded texel on each XY edge.
} config;

#include "magic_gi_sh9_tensor.glslinc"

shared vec4 shared_tensor[7];
shared uint shared_cell_valid;

bool magic_gi_dynamic_volume_projection_config_valid() {
	if (config.clip_cell_count <= 0 || config.source_probe_count <= 0
			|| config.dim_x <= 0 || config.dim_y <= 0 || config.dim_z <= 0) {
		return false;
	}
	if (config.clip_cell_count > source_sh.values.length() / 28
			|| config.clip_cell_count > clip_source_indices.values.length()) {
		return false;
	}
	if (config.angular_resolution != 8 && config.angular_resolution != 12
			&& config.angular_resolution != 16) {
		return false;
	}
	if (config.tile_size != config.angular_resolution + 2) {
		return false;
	}
	// Division-based checks avoid overflowing a malformed dimension product.
	if (config.dim_x > config.clip_cell_count
			|| config.dim_y > config.clip_cell_count / config.dim_x) {
		return false;
	}
	int xy_count = config.dim_x * config.dim_y;
	if (config.dim_z > config.clip_cell_count / xy_count
			|| xy_count * config.dim_z != config.clip_cell_count) {
		return false;
	}
	ivec3 actual_size = imageSize(response_atlas);
	ivec3 actual_moment_size = imageSize(moment_atlas);
	return actual_size.x > 0 && actual_size.y > 0 && actual_size.z == config.dim_z
			&& actual_size.x % config.tile_size == 0
			&& actual_size.y % config.tile_size == 0
			&& actual_size.x / config.tile_size == config.dim_x
			&& actual_size.y / config.tile_size == config.dim_y
			&& actual_moment_size == ivec3(config.dim_x * 10,
					config.dim_y * 10, config.dim_z)
			&& source_moments.values.length() >= config.source_probe_count * 128;
}

float magic_gi_dynamic_volume_sign_not_zero(float value) {
	return value < 0.0 ? -1.0 : 1.0;
}

vec3 magic_gi_dynamic_volume_octa_decode(vec2 uv) {
	vec2 p = uv * 2.0 - 1.0;
	vec3 n = vec3(p, 1.0 - abs(p.x) - abs(p.y));
	if (n.z < 0.0) {
		vec2 old_xy = n.xy;
		n.x = (1.0 - abs(old_xy.y))
				* magic_gi_dynamic_volume_sign_not_zero(old_xy.x);
		n.y = (1.0 - abs(old_xy.x))
				* magic_gi_dynamic_volume_sign_not_zero(old_xy.y);
	}
	float length_squared = dot(n, n);
	if (!(length_squared > 1e-12) || isnan(length_squared) || isinf(length_squared)) {
		return vec3(0.0, 0.0, 1.0);
	}
	return n * inversesqrt(length_squared);
}

// Match frp_magic_gi_dynamic_volume_fold_moment_texel(): fold X first, then Y.
ivec2 magic_gi_dynamic_volume_fold_octa_texel(ivec2 texel, int size) {
	for (int iteration = 0; iteration < 4; iteration++) {
		if (texel.x < 0) {
			texel = ivec2(-texel.x - 1, size - 1 - texel.y);
		} else if (texel.x >= size) {
			texel = ivec2(size * 2 - 1 - texel.x, size - 1 - texel.y);
		}
		if (texel.y < 0) {
			texel = ivec2(size - 1 - texel.x, -texel.y - 1);
		} else if (texel.y >= size) {
			texel = ivec2(size - 1 - texel.x, size * 2 - 1 - texel.y);
		}
		if (all(greaterThanEqual(texel, ivec2(0)))
				&& all(lessThan(texel, ivec2(size)))) {
			return texel;
		}
	}
	return clamp(texel, ivec2(0), ivec2(size - 1));
}

// The SH tensor has already received the single cosine-convolution / PI
// conversion in magic_gi_sh9_tensor_pack_e_over_pi(). `normal` is a unit
// octahedral sample direction. Return the signed response without clamping.
vec3 magic_gi_dynamic_volume_eval_tensor_unit(vec3 normal) {
	float x = normal.x;
	float y = normal.y;
	float z = normal.z;
	return shared_tensor[0].xyz * (x * x)
			+ shared_tensor[1].xyz * x
			+ shared_tensor[2].xyz * (y * y)
			+ vec3(shared_tensor[0].a, shared_tensor[1].a, shared_tensor[2].a) * (x * y)
			+ shared_tensor[3].xyz * y
			+ shared_tensor[4].xyz * (z * z)
			+ vec3(shared_tensor[3].a, shared_tensor[4].a, shared_tensor[5].a) * (y * z)
			+ shared_tensor[5].xyz * z
			+ shared_tensor[6].xyz * (x * z);
}

void main() {
	// Dispatch exactly (dim_x, dim_y, dim_z), one workgroup per source cell.
	// Every predicate below is workgroup-uniform, so no invocation can return
	// before the shared-memory barrier while another invocation waits at it.
	if (!magic_gi_dynamic_volume_projection_config_valid()) {
		return;
	}
	ivec3 cell = ivec3(gl_WorkGroupID.xyz);
	if (cell.x >= config.dim_x || cell.y >= config.dim_y || cell.z >= config.dim_z) {
		return;
	}
	int cell_index = (cell.z * config.dim_y + cell.y) * config.dim_x + cell.x;
	int source_index = clip_source_indices.values[cell_index];
	uint lane = gl_LocalInvocationID.x;

	if (lane == 0u) {
		uint source_base = uint(cell_index) * 28u;
		vec3 raw_radiance_sh[9];
		for (int coefficient = 0; coefficient < 9; coefficient++) {
			uint coefficient_base = source_base + uint(coefficient * 3);
			raw_radiance_sh[coefficient] = vec3(
					source_sh.values[coefficient_base],
					source_sh.values[coefficient_base + 1u],
					source_sh.values[coefficient_base + 2u]);
		}
		float validity_token = source_sh.values[source_base + 27u];
		bool source_index_valid = source_index >= 0
				&& source_index < config.source_probe_count;
		bool token_valid = source_index_valid && !isnan(validity_token) && !isinf(validity_token)
				&& validity_token > 0.5;
		vec4 packed[7];
		magic_gi_sh9_tensor_pack_e_over_pi(raw_radiance_sh,
				token_valid ? 1.0 : 0.0, packed);
		bool packed_valid = token_valid && packed[6].a > 0.5;
		for (int field = 0; field < 7; field++) {
			packed_valid = packed_valid && magic_gi_sh9_tensor_finite_vec4(packed[field]);
		}
		for (int field = 0; field < 7; field++) {
			shared_tensor[field] = packed_valid ? packed[field] : vec4(0.0);
		}
		shared_cell_valid = packed_valid ? 1u : 0u;
	}
	barrier();

	int response_tile_pixels = config.tile_size * config.tile_size;
	int moment_tile_pixels = 100;
	int tile_pixels = max(response_tile_pixels, moment_tile_pixels);
	for (int linear_texel = int(lane); linear_texel < tile_pixels; linear_texel += 256) {
		if (linear_texel < response_tile_pixels) {
			int local_x = linear_texel % config.tile_size;
			int local_y = linear_texel / config.tile_size;
			ivec2 folded = magic_gi_dynamic_volume_fold_octa_texel(
					ivec2(local_x - 1, local_y - 1), config.angular_resolution);
			vec2 octa_uv = (vec2(folded) + vec2(0.5)) / float(config.angular_resolution);
			vec3 direction = magic_gi_dynamic_volume_octa_decode(octa_uv);
			vec3 response = shared_cell_valid != 0u
					? magic_gi_dynamic_volume_eval_tensor_unit(direction) : vec3(0.0);
			bool response_finite = magic_gi_sh9_tensor_finite_vec3(response);
			// A valid black cell remains alpha=1. If pathological finite coefficients
			// overflow only this F32 direction evaluation, mark that texel invalid.
			vec4 projected = shared_cell_valid != 0u && response_finite
					? vec4(response, 1.0) : vec4(0.0);
			ivec3 destination = ivec3(cell.x * config.tile_size + local_x,
					cell.y * config.tile_size + local_y, cell.z);
			imageStore(response_atlas, destination, projected);
		}
		if (linear_texel < moment_tile_pixels) {
			int moment_x = linear_texel % 10;
			int moment_y = linear_texel / 10;
			ivec2 folded = magic_gi_dynamic_volume_fold_octa_texel(
					ivec2(moment_x - 1, moment_y - 1), 8);
			uint texel = uint(folded.y * 8 + folded.x);
			vec2 moment_value = vec2(0.0);
			if (source_index >= 0 && source_index < config.source_probe_count) {
				uint moment_offset = uint(source_index) * 128u + texel * 2u;
				moment_value = vec2(source_moments.values[moment_offset],
						source_moments.values[moment_offset + 1u]);
			}
			if (any(isnan(moment_value)) || any(isinf(moment_value)) ||
					any(lessThan(moment_value, vec2(0.0)))) {
				moment_value = vec2(0.0);
			}
			ivec3 destination = ivec3(cell.x * 10 + moment_x,
					cell.y * 10 + moment_y, cell.z);
			imageStore(moment_atlas, destination, vec4(moment_value, 0.0, 0.0));
		}
	}
}
