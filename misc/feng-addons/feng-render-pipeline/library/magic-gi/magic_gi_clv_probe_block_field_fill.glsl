#[compute]
#version 450
// Layout14 V0: one normal-independent block-center field per clipmap cell.
// The complete radius is derived from this CLV step in source-grid cells;
// there is no probe or candidate truncation.
layout(local_size_x = 64) in;
layout(set = 0, binding = 0) uniform sampler2D geometry_atlas;
layout(set = 0, binding = 1) uniform isampler2D index_map;
layout(set = 0, binding = 2, std430) readonly buffer VisibilityNodes { vec4 nodes[]; } visibility_bvh;
layout(set = 0, binding = 3, std430) readonly buffer VisibilityTriangles { vec4 triangles[]; } visibility_geometry;
layout(set = 0, binding = 4, std430) readonly buffer RawDirectional { vec4 values[]; } raw_directional;
struct FieldJob {
	vec4 center_spacing; // world block center xyz, active CLV step in w
	ivec4 logical_level; // logical cache cell xyz, clipmap level
};
layout(set = 0, binding = 5, std430) readonly buffer FieldJobs { FieldJob values[]; } jobs;
layout(rgba32f, set = 0, binding = 6) uniform image3D field_image;
layout(rgba32i, set = 0, binding = 7) uniform iimage3D field_tags;
layout(set = 0, binding = 8, std140) uniform GIParams {
	mat4 inverse_projection; mat4 world_to_grid; mat4 view_to_world;
	vec4 grid; vec4 control; vec4 lighting_sh[7]; vec4 sky_lighting_sh[7];
} params;
layout(set = 0, binding = 11, r32ui) uniform uimage3D field_support;
layout(set = 0, binding = 13) uniform sampler2D visibility_moment_atlas;
layout(push_constant, std430) uniform FillParameters {
	int job_count; int resolution; int geometry_epoch; float base_spacing;
} config;

#include "magic_gi_visibility.glslinc"
#define MAGIC_INDEX_BINDING 9
#include "magic_gi_index.glslinc"
#define MAGIC_CLUSTER_BINDING 10
#include "magic_gi_probe_clusters.glslinc"
#include "magic_gi_clv_probe_visibility.glslinc"
#include "magic_gi_clv_field_layout.glslinc"
#include "magic_gi_sh.glslinc"

const int FIELD_COLUMN_COUNT = 18;
const int FIELD_LEVEL_COUNT = 3;
const int FIELD_GUARD = 1;
const float FIELD_WEIGHT_EPSILON_SCALE = 0.16;
shared vec4 reduce_coefficients[FIELD_COLUMN_COUNT][64];
shared vec2 reduce_weights[64];
shared uvec2 reduce_invalid_stream[64];

bool field_finite_vec4(vec4 v) {
	return !any(isnan(v)) && !any(isinf(v));
}

ivec3 field_wrap(ivec3 logical, int resolution) {
	return ((logical % resolution) + resolution) % resolution;
}

float field_cell_window(ivec3 cell, ivec3 center, vec3 fraction, int radius) {
	float window = 1.0;
	for (int axis = 0; axis < 3; axis++) {
		int offset = cell[axis] - center[axis];
		if (abs(offset) == radius) {
			window *= offset < 0 ? 1.0 - smoothstep(0.0, 1.0, fraction[axis])
					: smoothstep(0.0, 1.0, fraction[axis]);
		}
	}
	return window;
}

void field_store_column(ivec3 wrapped_slot, int level, int column, vec4 value) {
	int resolution = config.resolution;
	int stride = resolution + FIELD_GUARD;
	ivec3 base = ivec3(column * stride + wrapped_slot.x,
		wrapped_slot.y, level * stride + wrapped_slot.z);
	for (int mask = 0; mask < 8; mask++) {
		if ((mask & 1) != 0 && wrapped_slot.x != 0) { continue; }
		if ((mask & 2) != 0 && wrapped_slot.y != 0) { continue; }
		if ((mask & 4) != 0 && wrapped_slot.z != 0) { continue; }
		ivec3 dst = base + ivec3((mask & 1) != 0 ? resolution : 0,
				(mask & 2) != 0 ? resolution : 0,
				(mask & 4) != 0 ? resolution : 0);
		imageStore(field_image, dst, value);
	}
}

void main() {
	uint lane = gl_LocalInvocationIndex;
	uint job_index = gl_WorkGroupID.x;
	if (config.job_count <= 0 || job_index >= uint(config.job_count)) { return; }
	FieldJob job = jobs.values[job_index];
	int cluster_word_count = probe_cluster_data.values.length();
	vec3 block_center = job.center_spacing.xyz;
	float step_size = job.center_spacing.w;
	int level = job.logical_level.w;
	ivec3 logical_cell = job.logical_level.xyz;
	if (config.resolution <= 1 || level < 0 || level >= FIELD_LEVEL_COUNT) { return; }
	vec4 lane_coefficients[FIELD_COLUMN_COUNT];
	for (int k = 0; k < FIELD_COLUMN_COUNT; k++) { lane_coefficients[k] = vec4(0.0); }
	float lane_secondary_weight = 0.0;
	float lane_primary_weight = 0.0;
	uint lane_bad_secondary = 0u;
	uint lane_bad_primary = 0u;
	bool job_valid = level >= 0 && level < FIELD_LEVEL_COUNT
			&& config.resolution > 1 && step_size > 0.0
			&& cluster_word_count >= 4
			&& !any(isnan(block_center)) && !any(isinf(block_center))
			&& !isnan(step_size) && !isinf(step_size);
	vec3 grid_position = vec3(0.0);
	ivec3 grid_dimensions = ivec3(params.grid.xyz);
	ivec3 center_cell = ivec3(0);
	vec3 grid_fraction = vec3(0.0);
	int radius = 2;
	float source_spacing = max(params.control.y, 0.001);
	if (job_valid && all(greaterThan(grid_dimensions, ivec3(0)))) {
		grid_position = (params.world_to_grid * vec4(block_center, 1.0)).xyz;
		job_valid = !any(isnan(grid_position)) && !any(isinf(grid_position))
				&& all(greaterThanEqual(grid_position, vec3(0.0)))
				&& all(lessThan(grid_position, vec3(grid_dimensions)));
		if (job_valid) {
			center_cell = ivec3(floor(grid_position));
			grid_fraction = grid_position - vec3(center_cell);
			// Keep the same world support radius as two CLV cells while enumerating
			// the finer source grid completely at coarser clipmap levels.
			radius = max(2, int(ceil(2.0 * step_size / source_spacing)));
		}
	}
	if (job_valid && params.grid.w > 0.0) {
		int side = radius * 2 + 1;
		int neighbor_count = side * side * side;
		float kernel_epsilon = max(step_size * step_size * FIELD_WEIGHT_EPSILON_SCALE, 0.0001);
		bool compact_index_map = textureSize(index_map, 0).x == grid_dimensions.x;
		for (int neighbor_ordinal = int(lane); neighbor_ordinal < neighbor_count;
				neighbor_ordinal += 64) {
			int dx = neighbor_ordinal % side - radius;
			int dy = (neighbor_ordinal / side) % side - radius;
			int dz = neighbor_ordinal / (side * side) - radius;
			ivec3 cell = center_cell + ivec3(dx, dy, dz);
			if (any(lessThan(cell, ivec3(0))) || any(greaterThanEqual(cell, grid_dimensions))) { continue; }
			float cell_window = field_cell_window(cell, center_cell, grid_fraction, radius);
			if (!(cell_window > 0.0)) { continue; }
			ivec2 map_range = cell_probe_map_range(cell, grid_dimensions, compact_index_map);
			int cell_count = map_range.y;
			if (cell_count <= 0) { continue; }
			for (int probe_slot = 0; probe_slot < cell_count; probe_slot++) {
				int probe = cell_probe(cell, probe_slot, grid_dimensions, compact_index_map, map_range.x);
				if (probe < 0) { break; } // Build slots are dense.
				if (float(probe) >= params.grid.w) { continue; }
				ivec2 geometry_xy = ivec2((probe % 32) * 3, probe / 32);
				vec3 sample_position = texelFetch(geometry_atlas, geometry_xy + ivec2(1, 0), 0).xyz;
				vec4 normal_record = texelFetch(geometry_atlas, geometry_xy + ivec2(2, 0), 0);
				float local_spacing = max(normal_record.w, 0.001);
				float distance_squared = dot(block_center - sample_position, block_center - sample_position);
				float distance = sqrt(max(distance_squared, 0.0));
				float density_window = 1.0;
				// Match gather_probe_neighborhood(): density feathering is relative
				// to the source-grid spacing, not this coarser CLV block step.
				if (local_spacing < source_spacing * 0.999) {
					float local_support = local_spacing * 2.5;
					if (distance >= local_support) { continue; }
					density_window = 1.0 - smoothstep(local_spacing * 1.5,
						local_support, distance);
				}
				float spatial_weight = cell_window * density_window
						* local_spacing * local_spacing
						* inversesqrt(kernel_epsilon + distance_squared);
				if (!(spatial_weight > 0.0) || isnan(spatial_weight) || isinf(spatial_weight)) { continue; }
				// This is the same probe-to-receiver geometry query used by ordinary
				// source gathering, evaluated once at this block center. Moment visibility
				// further weights an unblocked segment as in the existing CLV path.
				if (segment_blocked(sample_position, block_center, -1, 0)) { continue; }
				float visibility = clv_probe_visibility(probe, block_center);
				if (!(visibility > 0.0001) || isnan(visibility) || isinf(visibility)) { continue; }
				float secondary_weight = spatial_weight * visibility;
				float primary_weight = secondary_weight * kernel_epsilon
						/ max(kernel_epsilon + distance_squared, 1e-7);
				bool secondary_finite = true;
				bool primary_finite = true;
				for (int k = 0; k < 9; k++) {
					vec4 secondary = raw_directional.values[probe * 18 + k];
					vec4 primary = raw_directional.values[probe * 18 + 9 + k];
					secondary_finite = secondary_finite && field_finite_vec4(secondary);
					primary_finite = primary_finite && field_finite_vec4(primary);
				}
				if (secondary_finite) {
					lane_secondary_weight += secondary_weight;
					for (int k = 0; k < 9; k++) {
						lane_coefficients[k] += raw_directional.values[probe * 18 + k] * secondary_weight;
					}
				} else {
					lane_bad_secondary = 1u;
				}
				if (primary_finite) {
					lane_primary_weight += primary_weight;
					for (int k = 0; k < 9; k++) {
						lane_coefficients[9 + k] += raw_directional.values[probe * 18 + 9 + k] * primary_weight;
					}
				} else {
					lane_bad_primary = 1u;
				}
			}
		}
	}
	for (int k = 0; k < FIELD_COLUMN_COUNT; k++) { reduce_coefficients[k][lane] = lane_coefficients[k]; }
	reduce_weights[lane] = vec2(lane_secondary_weight, lane_primary_weight);
	reduce_invalid_stream[lane] = uvec2(lane_bad_secondary, lane_bad_primary);
	barrier();
	for (uint stride = 32u; stride > 0u; stride >>= 1u) {
		if (lane < stride) {
			for (int k = 0; k < FIELD_COLUMN_COUNT; k++) {
				reduce_coefficients[k][lane] += reduce_coefficients[k][lane + stride];
			}
			reduce_weights[lane] += reduce_weights[lane + stride];
			reduce_invalid_stream[lane] |= reduce_invalid_stream[lane + stride];
		}
		barrier();
	}
	if (lane != 0u) { return; }
	ivec3 slot = field_wrap(logical_cell, config.resolution);
	ivec3 tag_slot = slot + ivec3(0, 0, level * config.resolution);
	uint support = 0u;
	bool secondary_valid = reduce_weights[0].x > 1e-7
			&& !isnan(reduce_weights[0].x) && !isinf(reduce_weights[0].x)
			&& reduce_invalid_stream[0].x == 0u;
	bool primary_valid = reduce_weights[0].y > 1e-7
			&& !isnan(reduce_weights[0].y) && !isinf(reduce_weights[0].y)
			&& reduce_invalid_stream[0].y == 0u;
	for (int k = 0; k < FIELD_COLUMN_COUNT; k++) {
		vec4 value = reduce_coefficients[k][0];
		bool stream_valid = k < 9 ? secondary_valid : primary_valid;
		float denominator = k < 9 ? reduce_weights[0].x : reduce_weights[0].y;
		value = stream_valid ? value / denominator : vec4(0.0);
		if (!field_finite_vec4(value)) {
			if (k < 9) { secondary_valid = false; }
			else { primary_valid = false; }
		}
		lane_coefficients[k] = value;
	}
	if (!secondary_valid) {
		for (int k = 0; k < 9; k++) { lane_coefficients[k] = vec4(0.0); }
	} else {
		support |= CLV_FIELD_SUPPORT_SECONDARY;
	}
	if (!primary_valid) {
		for (int k = 9; k < 18; k++) { lane_coefficients[k] = vec4(0.0); }
	} else {
		support |= CLV_FIELD_SUPPORT_PRIMARY;
	}
	for (int k = 0; k < FIELD_COLUMN_COUNT; k++) { field_store_column(slot, level, k, lane_coefficients[k]); }
	imageStore(field_tags, tag_slot, ivec4(logical_cell, config.geometry_epoch));
	imageStore(field_support, tag_slot, uvec4(support, 0u, 0u, 0u));
}
