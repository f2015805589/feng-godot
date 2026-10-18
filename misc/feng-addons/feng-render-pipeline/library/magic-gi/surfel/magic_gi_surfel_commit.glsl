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
	uvec4 adaptive;
	vec4 guide;
} gi_surfel_config;
layout(set = 0, binding = 12, std140) uniform FENGGISurfelProbeConfig {
	ivec4 starts[3];
	vec4 spacing;
	uvec4 budget;
} gi_surfel_probe_config;

struct FENGGISurfelRecord {
	vec4 position_radius;
	vec4 normal_valid;
	ivec4 cell_last_seen;
	uvec4 surface;
	uvec4 state; // Queue token, mean cosine first-hit distance bits, invalid flag, successful update sequence.
};
layout(set = 1, binding = 0, std430) buffer FENGGISurfelRecords {
	FENGGISurfelRecord records[];
} gi_surfels;
layout(set = 1, binding = 1, std430) buffer FENGGISurfelHash {
	uint slots[];
} gi_surfel_hash;
layout(set = 1, binding = 5, std430) buffer FENGGISurfelCounters {
	uint values[];
} gi_surfel_counters;
layout(set = 1, binding = 6, std430) readonly buffer FENGGISurfelUpdateQueue {
	uint indices[];
} gi_surfel_update_queue;
layout(set = 1, binding = 7, std430) readonly buffer FENGGISurfelPendingResults {
	uvec4 values[];
} gi_surfel_pending_results;
layout(set = 1, binding = 9, std430) buffer FENGGISurfelResponseFiltered {
	vec4 values[];
} gi_surfel_response_filtered;
layout(set = 1, binding = 10, std430) buffer FENGGISurfelStatistics {
	vec4 values[];
} gi_surfel_statistics;
layout(set = 1, binding = 13, std430) buffer FENGGISurfelTracking {
	uvec4 values[];
} gi_surfel_tracking;
layout(set = 1, binding = 14, std430) buffer FENGGISurfelGuidePrevious {
	uint values[];
} gi_surfel_guide_previous;
layout(set = 1, binding = 15, std430) buffer FENGGISurfelGuideNext {
	uint values[];
} gi_surfel_guide_next;
layout(set = 1, binding = 16, std430) buffer FENGGISurfelFreeIndices {
	uint values[];
} gi_surfel_free_indices;

const uint GI_SURFEL_UNKNOWN_INSTANCE = 0xffffffffu;
const uint GI_SURFEL_SLOT_TOMBSTONE = 0xfffffffeu;
const uint GI_SURFEL_SLOT_LOCKED = 0xfffffffdu;

void gi_surfel_commit_retire(uint index, uint capacity) {
	uint hash_slot = gi_surfels.records[index].surface.y;
	uint hash_mask = gi_surfel_config.limits.y;
	if (hash_slot <= hash_mask
			&& atomicCompSwap(gi_surfel_hash.slots[hash_slot], index, GI_SURFEL_SLOT_LOCKED) == index) {
		memoryBarrierBuffer();
		atomicExchange(gi_surfel_hash.slots[hash_slot], GI_SURFEL_SLOT_TOMBSTONE);
	}
	gi_surfels.records[index].normal_valid.w = 0.0;
	gi_surfels.records[index].state.z = 1u;
	gi_surfels.records[index].state.w = 0u;
	memoryBarrierBuffer();
	uint free_slot = atomicAdd(gi_surfel_counters.values[6], 1u);
	if (free_slot < capacity) {
		gi_surfel_free_indices.values[free_slot] = index;
	} else {
		atomicMin(gi_surfel_counters.values[6], capacity);
	}
}

void main() {
	uint item = gl_GlobalInvocationID.x;
	uint capacity = gi_surfel_config.limits.x;
	uint active_count = min(capacity, gi_surfel_counters.values[1]);
	uint updates = min(gi_surfel_probe_config.budget.x, capacity);
	uint active_budget = min(updates, active_count);
	uint effective_updates = min(gi_surfel_probe_config.budget.y, updates);
	uint reserve_max = updates - effective_updates;
	uint surface_rays = max(gi_surfel_probe_config.budget.w, 1u);
	uint reserve_actual = min(reserve_max, active_budget / 8u);
	if ((surface_rays & 1u) != 0u) reserve_actual &= ~1u;
	uint budget = active_budget - reserve_actual;
	if (item == 0u && active_count > 0u && budget > 0u) {
		bool direct_ring = active_count <= budget;
		uint urgent_limit = direct_ring ? 0u : budget - budget / 4u;
		uint queued_count = direct_ring ? 0u : min(gi_surfel_counters.values[3], urgent_limit);
		uint ring_count = budget - queued_count;
		uint cursor = gi_surfel_counters.values[4] % active_count;
		// Advance by scheduled ring slots, even if a slot is invalid or deduplicated.
		gi_surfel_counters.values[4] = (cursor + ring_count) % active_count;
	}
	uint dispatch_count = updates;
	if (item >= dispatch_count) return;
	uint index = gi_surfel_update_queue.indices[gi_surfel_config.limits.x + item];
	if (index >= capacity) return;
	uvec4 result = gi_surfel_pending_results.values[item];
	uint status = result.w;
	if (status == 1u) {
		gi_surfels.records[index].surface.x = result.z;
		gi_surfels.records[index].surface.z = result.x;
		gi_surfels.records[index].surface.w = result.y;
		gi_surfels.records[index].state.z = 0u;
		gi_surfels.records[index].state.w += 1u;
		uint guide_base = index * 5u;
		for (uint word = 0u; word < 5u; word++) {
			gi_surfel_guide_previous.values[guide_base + word]
					= gi_surfel_guide_next.values[guide_base + word];
		}
	} else if (status == 2u) {
		gi_surfels.records[index].surface.x = 0u;
		gi_surfels.records[index].surface.z = GI_SURFEL_UNKNOWN_INSTANCE;
		gi_surfels.records[index].surface.w = GI_SURFEL_UNKNOWN_INSTANCE;
		gi_surfels.records[index].state.y = 0u;
		gi_surfels.records[index].state.z = 1u;
		gi_surfels.records[index].state.w = 0u;
		gi_surfel_response_filtered.values[index] = vec4(0.0);
		gi_surfel_statistics.values[index] = vec4(0.0);
		gi_surfel_tracking.values[index] = uvec4(0u);
		uint guide_base = index * 5u;
		for (uint word = 0u; word < 5u; word++) {
			gi_surfel_guide_previous.values[guide_base + word] = 0u;
			gi_surfel_guide_next.values[guide_base + word] = 0u;
		}
		gi_surfel_commit_retire(index, capacity);
	}
}
