#[compute]
#version 450
layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

struct FENGGISurfelRecord {
	vec4 position_radius;
	vec4 normal_valid;
	ivec4 cell_last_seen;
	uvec4 surface;
	uvec4 state;
};

layout(set = 0, binding = 4, std140) uniform FENGGISurfelConfig {
	mat4 world_to_owner;
	mat4 owner_to_world;
	vec4 owner_size_cell_radius;
	uvec4 limits;
} gi_surfel_config;
layout(set = 1, binding = 0, std430) readonly buffer FENGGISurfelRecords {
	FENGGISurfelRecord records[];
} gi_surfels;
layout(set = 1, binding = 5, std430) readonly buffer FENGGISurfelCounters {
	uint values[];
} gi_surfel_counters;
layout(set = 1, binding = 13, std430) readonly buffer FENGGISurfelTracking {
	uvec4 values[];
} gi_surfel_tracking;
layout(set = 1, binding = 17, std430) buffer FENGGISurfelLODPresence {
	uint levels;
} gi_surfel_lod_presence;

shared uint group_levels;
shared uint group_high_water;

void main() {
	uint lane = gl_LocalInvocationIndex;
	if (lane == 0u) {
		group_levels = 0u;
		group_high_water = min(gi_surfel_config.limits.x, gi_surfel_counters.values[1]);
	}
	barrier();

	uint index = gl_GlobalInvocationID.x;
	if (index < group_high_water) {
		FENGGISurfelRecord record = gi_surfels.records[index];
		uvec4 tracking = gi_surfel_tracking.values[index];
		uint level = tracking.z;
		if (record.normal_valid.w >= 0.5 && record.state.z == 0u && level < 2u) {
			atomicOr(group_levels, 1u << level);
		}
	}
	barrier();
	if (lane == 0u && group_levels != 0u) {
		atomicOr(gi_surfel_lod_presence.levels, group_levels);
	}
}
