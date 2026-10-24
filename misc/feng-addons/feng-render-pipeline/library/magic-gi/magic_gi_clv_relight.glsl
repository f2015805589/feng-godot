#[compute]
#version 450
// Relight the complete resident layout-9 CLV from geometry-interpolated transfer
// matrices. This dispatch never queries probes or reruns the geometry stencil.
layout(local_size_x = 64) in;
layout(rgba32f, set = 0, binding = 0) uniform image3D cache_image;
layout(rgba32i, set = 0, binding = 1) uniform readonly iimage3D cache_tags;
layout(rgba32f, set = 0, binding = 2) uniform readonly image3D transfer_matrix_image;
layout(set = 0, binding = 3, std140) uniform GIParams {
	mat4 inverse_projection;
	mat4 world_to_grid;
	mat4 view_to_world;
	vec4 grid;
	vec4 control;
	vec4 lighting_sh[7];
	vec4 sky_lighting_sh[7];
} params;
layout(set = 0, binding = 4, std430) readonly buffer Stencils { uint words[]; } clv_stencils;
layout(set = 0, binding = 5, std430) readonly buffer EmissionSources { float values[]; } clv_emission_sources;
layout(push_constant, std430) uniform RelightParameters {
	int jobs;
	int resolution;
	int epoch;
	int emitters;
	int reserved0;
	int reserved1;
	int reserved2;
	int reserved3;
} config;
#include "magic_gi_clv_layout.glslinc"
#include "magic_gi_sh.glslinc"

const int CLV_LEVELS = 3;
const int CLV_STENCIL_CAPACITY = 16;
const int CLV_STENCIL_WORDS = 4 + CLV_STENCIL_CAPACITY * 3;
const int CLV_TRANSFER_MATRIX_COLUMNS = 81;
const int CLV_EMISSION_MATRIX_COLUMNS_PER_SOURCE = 14;
const uint CLV_STENCIL_TRANSFER_VALID_BIT = 0x80000000u;
shared vec3 relit_coefficients[54];
shared uint relit_valid[54];

ivec3 clv_transfer_matrix_position(ivec3 slot, int axis, int column) {
	int level = slot.z / config.resolution;
	int local_z = slot.z - level * config.resolution;
	return ivec3(column * config.resolution + slot.x, slot.y,
			(level * CLV_FACE_SLOT_COUNT + axis) * config.resolution + local_z);
}

float clv_transfer_matrix_scalar(ivec3 slot, int axis, int scalar_index) {
	vec4 packed_value = imageLoad(transfer_matrix_image,
			clv_transfer_matrix_position(slot, axis, scalar_index / 4));
	return packed_value[scalar_index & 3];
}

vec3 clv_live_sh_coefficient(vec4 blocks[7], int index) {
	int scalar_index = index * 3;
	return vec3(blocks[scalar_index / 4][scalar_index & 3],
			blocks[(scalar_index + 1) / 4][(scalar_index + 1) & 3],
			blocks[(scalar_index + 2) / 4][(scalar_index + 2) & 3]);
}

bool clv_relight_column(ivec3 slot, int axis, int column, out vec3 coefficient) {
	int outgoing = column < 9 ? column : column - 9;
	coefficient = vec3(0.0);
	if (column < 9) {
		for (int incoming = 0; incoming < 9; incoming++) {
			vec3 live = clv_live_sh_coefficient(params.lighting_sh, incoming);
			for (int channel = 0; channel < 3; channel++) {
				int transfer_index = outgoing * 27 + incoming * 3 + channel;
				coefficient[channel] += clv_transfer_matrix_scalar(slot, axis,
						transfer_index) * live[channel];
			}
		}
		for (int emitter = 0; emitter < config.emitters; emitter++) {
			int emission_base = CLV_TRANSFER_MATRIX_COLUMNS * 4
					+ emitter * CLV_EMISSION_MATRIX_COLUMNS_PER_SOURCE * 4 + outgoing * 6;
			for (int channel = 0; channel < 3; channel++) {
				float first = clv_transfer_matrix_scalar(slot, axis, emission_base + channel);
				float second = clv_transfer_matrix_scalar(slot, axis, emission_base + 3 + channel);
				coefficient[channel] += first * clv_emission_sources.values[emitter * 6 + channel]
						+ second * clv_emission_sources.values[emitter * 6 + 3 + channel];
			}
		}
	} else {
		for (int incoming = 0; incoming < 9; incoming++) {
			vec3 live = clv_live_sh_coefficient(params.sky_lighting_sh, incoming);
			float transfer = clv_transfer_matrix_scalar(slot, axis,
					243 + outgoing * 9 + incoming);
			coefficient += live * transfer;
		}
	}
	return all(not(isnan(coefficient))) && all(not(isinf(coefficient)));
}

void main() {
	uint index = gl_WorkGroupID.x;
	if (index >= uint(config.jobs)) { return; }
	int lane = int(gl_LocalInvocationIndex);
	int cells_per_level = config.resolution * config.resolution * config.resolution;
	int level = int(index) / cells_per_level;
	if (level >= CLV_LEVELS) { return; }
	int local_index = int(index) - level * cells_per_level;
	ivec3 local = ivec3(local_index % config.resolution,
		(local_index / config.resolution) % config.resolution,
		local_index / (config.resolution * config.resolution));
	ivec3 slot = local + ivec3(0, 0, level * config.resolution);
	ivec4 tag = imageLoad(cache_tags, slot);
	if (tag.w != config.epoch) { return; }
	if (lane < CLV_FACE_SLOT_COUNT * CLV_FACE_RADIANCE_COLUMNS) {
		int axis = lane / CLV_FACE_RADIANCE_COLUMNS;
		int column = lane % CLV_FACE_RADIANCE_COLUMNS;
		uint stencil_base = uint(((slot.z * config.resolution + slot.y)
				* config.resolution + slot.x) * CLV_FACE_SLOT_COUNT + axis) * uint(CLV_STENCIL_WORDS);
		uint stencil_count = clv_stencils.words[stencil_base];
		bool transfer_valid = (clv_stencils.words[stencil_base + 1u]
				& CLV_STENCIL_TRANSFER_VALID_BIT) != 0u;
		// The support image stores geometric certification for the strict native
		// sampler. It is not transfer validity: the hardware-interpolated
		// approximate sampler still needs relit values at uncertified corners,
		// then applies its own normal/plane/patch safety checks.
		bool axis_supported = transfer_valid
				&& stencil_count > 0u
				&& clv_emission_sources.values.length() >= config.emitters * 6;
		vec3 relit = vec3(0.0);
		if (axis_supported) {
			axis_supported = clv_relight_column(slot, axis, column, relit);
		}
		uint shared_index = uint(axis * CLV_FACE_RADIANCE_COLUMNS + column);
		relit_valid[shared_index] = axis_supported ? 1u : 0u;
		relit_coefficients[shared_index] = axis_supported ? relit : vec3(0.0);
	}
	barrier();
	if (lane >= CLV_FACE_SLOT_COUNT * CLV_FACE_RADIANCE_COLUMNS) { return; }
	int axis = lane / CLV_FACE_RADIANCE_COLUMNS;
	int column = lane % CLV_FACE_RADIANCE_COLUMNS;
	uint shared_index = uint(axis * CLV_FACE_RADIANCE_COLUMNS + column);
	uint stencil_base = uint(((slot.z * config.resolution + slot.y)
			* config.resolution + slot.x) * CLV_FACE_SLOT_COUNT + axis) * uint(CLV_STENCIL_WORDS);
	bool axis_supported = true;
	for (int coefficient = 0; coefficient < CLV_FACE_RADIANCE_COLUMNS; coefficient++) {
		axis_supported = axis_supported
				&& relit_valid[uint(axis * CLV_FACE_RADIANCE_COLUMNS + coefficient)] != 0u;
	}
	vec4 stored = vec4(axis_supported ? relit_coefficients[shared_index] : vec3(0.0), 0.0);
	if (column == 0 && axis_supported) {
		stored.w = float(clv_stencils.words[stencil_base + 1u]
				& ~CLV_STENCIL_TRANSFER_VALID_BIT);
	}
	imageStore(cache_image, slot + ivec3(clv_face_column(axis, column)
			* config.resolution, 0, 0), stored);
	if (column == 0) {
		vec4 metadata = imageLoad(cache_image, slot + ivec3(clv_face_column(axis,
				CLV_FACE_METADATA_COLUMN) * config.resolution, 0, 0));
		vec3 normal = metadata.xyz;
		bool diffuse_valid = axis_supported && metadata.w > 0.0
				&& !any(isnan(normal)) && !any(isinf(normal));
		vec3 secondary = vec3(0.0);
		vec3 primary = vec3(0.0);
		if (diffuse_valid) {
			float basis[9];
			diffuse_basis(normal, basis);
			for (int coefficient = 0; coefficient < 9; coefficient++) {
				secondary += relit_coefficients[uint(axis * 18 + coefficient)] * basis[coefficient];
				primary += relit_coefficients[uint(axis * 18 + coefficient + 9)] * basis[coefficient];
			}
		}
		float diffuse_alpha = diffuse_valid ? 1.0 : 0.0;
		imageStore(cache_image, slot + ivec3(clv_face_column(axis,
				CLV_FACE_DIFFUSE_COLUMN) * config.resolution, 0, 0),
				vec4(secondary, diffuse_alpha));
		imageStore(cache_image, slot + ivec3(clv_face_column(axis,
				CLV_FACE_DIFFUSE_COLUMN + 1) * config.resolution, 0, 0),
				vec4(primary, diffuse_alpha));
	}
}
