#[compute]
#version 450
// One-shot diagnostic readback for the active layout-9 cache. This is only
// dispatched when an explicit validation request is armed. Each lane records
// one wrapped cell corner for the receiver's dominant normal axis.
layout(local_size_x = 8) in;

layout(rgba32f, set = 0, binding = 0) uniform readonly image3D transfer_matrix_image;
layout(rgba32f, set = 0, binding = 1) uniform readonly image3D cache_image;
layout(rgba32i, set = 0, binding = 2) uniform readonly iimage3D cache_tags;
layout(r32ui, set = 0, binding = 3) uniform readonly uimage3D cache_support;
layout(set = 0, binding = 4, std430) readonly buffer Stencils { uint words[]; } clv_stencils;
layout(set = 0, binding = 5, std430) readonly buffer ReceiverSamples { vec4 values[]; } receivers;
layout(set = 0, binding = 6, std430) writeonly buffer Snapshot { uint words[]; } snapshot;
layout(set = 0, binding = 7, std140) uniform ClipmapParameters {
	ivec4 origins[3];
	vec4 spacing;
	ivec4 control;
} params;

layout(push_constant, std430) uniform SnapshotConfig {
	int sample_count;
	int resolution;
	int emitter_count;
	int record_words;
} config;

const int CLV_LEVELS = 3;
const int CLV_FACE_COUNT = 3;
const int CLV_FACE_SLOT_COLUMNS = 24;
const int CLV_FACE_RADIANCE_COLUMNS = 18;
const int CLV_FACE_METADATA_COLUMN = 18;
const int CLV_FACE_ANCHOR_COLUMN = 19;
const int CLV_FACE_DIFFUSE_COLUMN = 20;
const int CLV_FACE_APPROX_GEOMETRY_COLUMN = 22;
const int CLV_FACE_APPROX_MOMENTS_COLUMN = 23;
const int CLV_TRANSFER_MATRIX_COLUMNS = 81;
const int CLV_EMISSION_COLUMNS_PER_SOURCE = 14;
const int CLV_STENCIL_CAPACITY = 16;
const int CLV_STENCIL_WORDS = 4 + CLV_STENCIL_CAPACITY * 3;
const uint CLV_TRANSFER_VALID_BIT = 0x80000000u;
const uint CLV_SUPPORT_NEIGHBOR_READY_BIT = 128u;
const uint SNAPSHOT_RECORD_WORDS = 194u;

int clv_dominant_axis(vec3 normal) {
	vec3 magnitude = abs(normal);
	if (magnitude.x >= magnitude.y && magnitude.x >= magnitude.z) { return 0; }
	if (magnitude.y >= magnitude.z) { return 1; }
	return 2;
}

ivec3 clv_wrap(ivec3 logical, int resolution) {
	return ((logical % resolution) + resolution) % resolution;
}

ivec3 clv_transfer_position(ivec3 slot, int axis, int column) {
	int level = slot.z / config.resolution;
	int local_z = slot.z - level * config.resolution;
	return ivec3(column * config.resolution + slot.x, slot.y,
			(level * CLV_FACE_COUNT + axis) * config.resolution + local_z);
}

float clv_transfer_scalar(ivec3 slot, int axis, int scalar_index) {
	vec4 packed_value = imageLoad(transfer_matrix_image,
			clv_transfer_position(slot, axis, scalar_index / 4));
	return packed_value[scalar_index & 3];
}

vec4 clv_transfer_statistics(ivec3 slot, int axis, int domain, int emitter_count) {
	int scalar_count = domain == 0 ? 243 : (domain == 1 ? 81 : emitter_count * 54);
	int nonzero_count = 0;
	int invalid_count = 0;
	float max_absolute = 0.0;
	float signed_sum = 0.0;
	for (int scalar = 0; scalar < scalar_count; scalar++) {
		float value = 0.0;
		if (domain == 0) {
			value = clv_transfer_scalar(slot, axis, scalar);
		} else if (domain == 1) {
			value = clv_transfer_scalar(slot, axis, 243 + scalar);
		} else {
			int emitter = scalar / 54;
			int emitter_scalar = scalar - emitter * 54;
			int column = CLV_TRANSFER_MATRIX_COLUMNS
					+ emitter * CLV_EMISSION_COLUMNS_PER_SOURCE + emitter_scalar / 4;
			vec4 packed_value = imageLoad(transfer_matrix_image,
					clv_transfer_position(slot, axis, column));
			value = packed_value[emitter_scalar & 3];
		}
		if (isnan(value) || isinf(value)) {
			invalid_count++;
			continue;
		}
		if (value != 0.0) { nonzero_count++; }
		max_absolute = max(max_absolute, abs(value));
		signed_sum += value;
	}
	return vec4(float(nonzero_count), max_absolute, signed_sum, float(invalid_count));
}

float clv_emission_peek(ivec3 slot, int axis, int scalar_index) {
	if (config.emitter_count <= 0 || scalar_index < 0 || scalar_index >= 54) { return 0.0; }
	int column = CLV_TRANSFER_MATRIX_COLUMNS + scalar_index / 4;
	vec4 packed_value = imageLoad(transfer_matrix_image,
			clv_transfer_position(slot, axis, column));
	return packed_value[scalar_index & 3];
}

uint clv_stencil_base(ivec3 slot, int axis) {
	return uint(((slot.z * config.resolution + slot.y) * config.resolution + slot.x)
			* CLV_FACE_COUNT + axis) * uint(CLV_STENCIL_WORDS);
}

uint clv_record_base(uint sample_index, uint level, uint corner) {
	return ((sample_index * uint(CLV_LEVELS) + level) * 8u + corner)
			* SNAPSHOT_RECORD_WORDS;
}

void clv_store_vec4(uint base, vec4 value) {
	snapshot.words[base] = floatBitsToUint(value.x);
	snapshot.words[base + 1u] = floatBitsToUint(value.y);
	snapshot.words[base + 2u] = floatBitsToUint(value.z);
	snapshot.words[base + 3u] = floatBitsToUint(value.w);
}

void clv_write_empty_record(uint output_base, uint sample_index, uint level,
		uint corner, int axis, ivec3 base, ivec3 logical_corner, uint flags,
		vec4 fraction) {
	for (uint word = 0u; word < SNAPSHOT_RECORD_WORDS; word++) {
		snapshot.words[output_base + word] = 0u;
	}
	snapshot.words[output_base] = sample_index;
	snapshot.words[output_base + 1u] = level;
	snapshot.words[output_base + 2u] = corner;
	snapshot.words[output_base + 3u] = uint(axis);
	snapshot.words[output_base + 4u] = flags;
	snapshot.words[output_base + 5u] = uint(base.x);
	snapshot.words[output_base + 6u] = uint(base.y);
	snapshot.words[output_base + 7u] = uint(base.z);
	snapshot.words[output_base + 8u] = 0u;
	snapshot.words[output_base + 9u] = uint(logical_corner.x);
	snapshot.words[output_base + 10u] = uint(logical_corner.y);
	snapshot.words[output_base + 11u] = uint(logical_corner.z);
	snapshot.words[output_base + 12u] = 0u;
	clv_store_vec4(output_base + 142u, fraction);
}

void main() {
	uint sample_index = gl_WorkGroupID.x / uint(CLV_LEVELS);
	uint level = gl_WorkGroupID.x % uint(CLV_LEVELS);
	uint corner = gl_LocalInvocationIndex;
	if (sample_index >= uint(config.sample_count) || corner >= 8u
			|| config.record_words != int(SNAPSHOT_RECORD_WORDS)) { return; }
	int resolution = config.resolution;
	int axis = 0;
	ivec3 base = ivec3(0);
	vec3 fraction = vec3(0.0);
	bool valid_sample = true;
	vec4 world_value = receivers.values[sample_index * 2u];
	vec4 normal_value = receivers.values[sample_index * 2u + 1u];
	vec3 normal = normal_value.xyz;
	float normal_length_squared = dot(normal, normal);
	if (!(normal_length_squared > 1e-12) || isnan(normal_length_squared)
			|| isinf(normal_length_squared) || isnan(params.spacing.x)
			|| isinf(params.spacing.x) || !(params.spacing.x > 0.0)) {
		valid_sample = false;
	} else {
		normal *= inversesqrt(normal_length_squared);
		axis = clv_dominant_axis(normal);
		float step_size = params.spacing.x * float(1 << int(level));
		vec3 position = (world_value.xyz + normal * step_size * 0.75) / step_size - 0.5;
		if (any(isnan(position)) || any(isinf(position))) {
			valid_sample = false;
		} else {
			base = ivec3(floor(position));
			fraction = fract(position);
		}
	}
	ivec3 corner_offset = ivec3(int(corner & 1u), int((corner >> 1u) & 1u), int((corner >> 2u) & 1u));
	ivec3 logical_corner = base + corner_offset;
	uint output_base = clv_record_base(sample_index, level, corner);
	ivec3 relative = base - params.origins[level].xyz;
	bool inside_window = valid_sample
			&& all(greaterThanEqual(relative, ivec3(0)))
			&& all(lessThan(relative, ivec3(resolution - 1)));
	uint flags = valid_sample ? 1u : 0u;
	if (inside_window) { flags |= 1u << 1u; }
	if (!inside_window) {
		clv_write_empty_record(output_base, sample_index, level, corner, axis,
				base, logical_corner, flags, vec4(fraction, 0.0));
		return;
	}
	ivec3 physical = clv_wrap(logical_corner, resolution);
	ivec3 slot = physical + ivec3(0, 0, int(level) * resolution);
	ivec4 tag = imageLoad(cache_tags, slot);
	uint support = imageLoad(cache_support, slot).r;
	bool tag_matches = all(equal(tag.xyz, logical_corner)) && tag.w == params.control.z;
	bool axis_supported = (support & (1u << uint(axis))) != 0u;
	uint stencil_base = clv_stencil_base(slot, axis);
	uint stencil_count = clv_stencils.words[stencil_base];
	uint stencil_marker = clv_stencils.words[stencil_base + 1u];
	bool transfer_valid = (stencil_marker & CLV_TRANSFER_VALID_BIT) != 0u;
	// Dynamic transfer aggregates preserve every accepted probe even when the
	// compact diagnostic stencil only retained its first CLV_STENCIL_CAPACITY IDs.
	bool stencil_count_valid = stencil_count > 0u
			&& (stencil_count <= uint(CLV_STENCIL_CAPACITY) || transfer_valid);
	if (tag_matches) { flags |= 1u << 2u; }
	if (axis_supported) { flags |= 1u << 3u; }
	if (stencil_count_valid) { flags |= 1u << 4u; }
	if (transfer_valid) { flags |= 1u << 5u; }
	if ((support & CLV_SUPPORT_NEIGHBOR_READY_BIT) != 0u) { flags |= 1u << 6u; }
	snapshot.words[output_base] = sample_index;
	snapshot.words[output_base + 1u] = level;
	snapshot.words[output_base + 2u] = corner;
	snapshot.words[output_base + 3u] = uint(axis);
	snapshot.words[output_base + 4u] = flags;
	snapshot.words[output_base + 5u] = uint(base.x);
	snapshot.words[output_base + 6u] = uint(base.y);
	snapshot.words[output_base + 7u] = uint(base.z);
	snapshot.words[output_base + 8u] = 0u;
	snapshot.words[output_base + 9u] = uint(logical_corner.x);
	snapshot.words[output_base + 10u] = uint(logical_corner.y);
	snapshot.words[output_base + 11u] = uint(logical_corner.z);
	snapshot.words[output_base + 12u] = 0u;
	for (int component = 0; component < 4; component++) {
		snapshot.words[output_base + 13u + uint(component)] = uint(tag[component]);
	}
	snapshot.words[output_base + 17u] = support;
	snapshot.words[output_base + 18u] = stencil_count;
	snapshot.words[output_base + 19u] = stencil_marker;
	snapshot.words[output_base + 20u] = clv_stencils.words[stencil_base + 2u];
	snapshot.words[output_base + 21u] = clv_stencils.words[stencil_base + 3u];
	clv_store_vec4(output_base + 22u, clv_transfer_statistics(slot, axis, 0, 0));
	clv_store_vec4(output_base + 26u, clv_transfer_statistics(slot, axis, 1, 0));
	clv_store_vec4(output_base + 30u,
			clv_transfer_statistics(slot, axis, 2, config.emitter_count));
	clv_store_vec4(output_base + 34u, vec4(
			clv_transfer_scalar(slot, axis, 0), clv_transfer_scalar(slot, axis, 1),
			clv_transfer_scalar(slot, axis, 2), clv_transfer_scalar(slot, axis, 3)));
	clv_store_vec4(output_base + 38u, vec4(
			clv_transfer_scalar(slot, axis, 243), clv_transfer_scalar(slot, axis, 244),
			clv_transfer_scalar(slot, axis, 245), clv_transfer_scalar(slot, axis, 246)));
	clv_store_vec4(output_base + 42u, vec4(
			clv_emission_peek(slot, axis, 0), clv_emission_peek(slot, axis, 1),
			clv_emission_peek(slot, axis, 2), clv_emission_peek(slot, axis, 3)));
	for (int column = 0; column < CLV_FACE_RADIANCE_COLUMNS; column++) {
		vec4 value = imageLoad(cache_image, slot + ivec3(
				(axis * CLV_FACE_SLOT_COLUMNS + column) * resolution, 0, 0));
		clv_store_vec4(output_base + 46u + uint(column * 4), value);
	}
	clv_store_vec4(output_base + 118u, imageLoad(cache_image, slot + ivec3(
			(axis * CLV_FACE_SLOT_COLUMNS + CLV_FACE_DIFFUSE_COLUMN) * resolution, 0, 0)));
	clv_store_vec4(output_base + 122u, imageLoad(cache_image, slot + ivec3(
			(axis * CLV_FACE_SLOT_COLUMNS + CLV_FACE_DIFFUSE_COLUMN + 1) * resolution, 0, 0)));
	clv_store_vec4(output_base + 126u, imageLoad(cache_image, slot + ivec3(
			(axis * CLV_FACE_SLOT_COLUMNS + CLV_FACE_METADATA_COLUMN) * resolution, 0, 0)));
	clv_store_vec4(output_base + 130u, imageLoad(cache_image, slot + ivec3(
			(axis * CLV_FACE_SLOT_COLUMNS + CLV_FACE_ANCHOR_COLUMN) * resolution, 0, 0)));
	clv_store_vec4(output_base + 134u, imageLoad(cache_image, slot + ivec3(
			(axis * CLV_FACE_SLOT_COLUMNS + CLV_FACE_APPROX_GEOMETRY_COLUMN) * resolution, 0, 0)));
	clv_store_vec4(output_base + 138u, imageLoad(cache_image, slot + ivec3(
			(axis * CLV_FACE_SLOT_COLUMNS + CLV_FACE_APPROX_MOMENTS_COLUMN) * resolution, 0, 0)));
	clv_store_vec4(output_base + 142u, vec4(fraction, 0.0));
	uint stored_entries = min(stencil_count, uint(CLV_STENCIL_CAPACITY));
	for (uint entry = 0u; entry < uint(CLV_STENCIL_CAPACITY); entry++) {
		uint output_entry = output_base + 146u + entry * 3u;
		if (entry < stored_entries) {
			uint source_entry = stencil_base + 4u + entry * 3u;
			snapshot.words[output_entry] = clv_stencils.words[source_entry];
			snapshot.words[output_entry + 1u] = clv_stencils.words[source_entry + 1u];
			snapshot.words[output_entry + 2u] = clv_stencils.words[source_entry + 2u];
		}
	}
}
