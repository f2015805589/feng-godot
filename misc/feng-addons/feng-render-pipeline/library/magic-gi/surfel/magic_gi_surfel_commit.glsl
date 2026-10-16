#[compute]
#version 450
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 4, std140) uniform FENGGISurfelConfig {
	mat4 world_to_owner;
	mat4 owner_to_world;
	vec4 owner_size_cell_radius;
	uvec4 limits;
	uvec4 light_counts;
	vec4 control;
} gi_surfel_config;

struct FENGGISurfelRecord {
	vec4 position_radius;
	vec4 normal_valid;
	ivec4 cell_last_seen;
	uvec4 surface;
	uvec4 state;
};
layout(set = 1, binding = 0, std430) buffer FENGGISurfelRecords {
	FENGGISurfelRecord records[];
} gi_surfels;
layout(set = 1, binding = 6, std430) readonly buffer FENGGISurfelUpdateQueue {
	uint indices[];
} gi_surfel_update_queue;
layout(set = 1, binding = 7, std430) readonly buffer FENGGISurfelPendingResults {
	uvec4 values[];
} gi_surfel_pending_results;

const uint GI_SURFEL_UNKNOWN_INSTANCE = 0xffffffffu;

void main() {
	uint item = gl_GlobalInvocationID.x;
	uint update_count = min(gi_surfel_config.limits.z, gi_surfel_config.limits.x);
	if (item >= update_count) return;
	uint index = gi_surfel_update_queue.indices[gi_surfel_config.limits.x + item];
	if (index >= gi_surfel_config.limits.x) return;
	uvec4 result = gi_surfel_pending_results.values[item];
	if (result.w == 1u) {
		gi_surfels.records[index].surface.x = result.z;
		gi_surfels.records[index].surface.z = result.x;
		gi_surfels.records[index].surface.w = result.y;
		gi_surfels.records[index].state.z = 0u;
		gi_surfels.records[index].state.y = gi_surfel_config.limits.w;
	} else if (result.w == 2u) {
		gi_surfels.records[index].surface.x = 0u;
		gi_surfels.records[index].surface.z = GI_SURFEL_UNKNOWN_INSTANCE;
		gi_surfels.records[index].surface.w = GI_SURFEL_UNKNOWN_INSTANCE;
		gi_surfels.records[index].state.z = 1u;
		gi_surfels.records[index].state.y = gi_surfel_config.limits.w;
	}
}
