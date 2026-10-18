#[compute]
#version 450
layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 12, std140) uniform FENGGISurfelProbeConfig {
	ivec4 starts[3];
	vec4 spacing;
	uvec4 budget;
} gi_surfel_probe_config;
layout(set = 1, binding = 5, std430) buffer FENGGISurfelCounters {
	uint values[];
} gi_surfel_counters;

const uint GI_SURFEL_PROBE_COUNT = 1536u;

void main() {
	uint updates = gi_surfel_probe_config.budget.x;
	uint effective_updates = min(gi_surfel_probe_config.budget.y, updates);
	uint reserve_max = updates - effective_updates;
	uint surface_rays = max(gi_surfel_probe_config.budget.w, 1u);
	uint active_count = min(updates, gi_surfel_counters.values[1]);
	uint reserve_actual = min(reserve_max, active_count / 8u);
	if ((surface_rays & 1u) != 0u) reserve_actual &= ~1u;
	uint actual_rays = min(gi_surfel_probe_config.budget.z, reserve_actual * surface_rays);
	uint scheduled_probe_slots = actual_rays / 2u;
	if (scheduled_probe_slots == 0u) return;
	uint cursor = gi_surfel_counters.values[5] % GI_SURFEL_PROBE_COUNT;
	gi_surfel_counters.values[5] = (cursor + scheduled_probe_slots) % GI_SURFEL_PROBE_COUNT;
}
