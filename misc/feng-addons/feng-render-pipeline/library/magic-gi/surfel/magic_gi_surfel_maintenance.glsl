#[compute]
#version 450
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

struct GIFrameData {
	mat4 inverse_projection;
	mat4 view_to_world;
	vec4 size_exposure;
	vec4 light_sky_parameters;
	vec4 world_to_sky_columns[3];
	uvec4 sun_view_generation_sky_array;
	vec4 trace_parameters;
	uvec4 generation_history_flags;
};
layout(set = 0, binding = 20, std140) uniform GIFrame {
	GIFrameData data;
} gi_frame;
layout(set = 0, binding = 21, std140) uniform FENGGISurfelMaintenanceControl {
	uvec4 dispatch; // dispatch count, frame token, reserved.
} gi_surfel_maintenance_control;

struct FENGGISurfaceTrackingRow {
	mat4 local_to_world;
	vec4 normal_to_world_columns[3];
	uvec4 identity;
};
layout(set = 0, binding = 8, std430) readonly buffer FENGGIVertices { uint words[]; } gi_vertices;
layout(set = 0, binding = 9, std430) readonly buffer FENGGIIndices { uint indices[]; } gi_indices;
layout(set = 0, binding = 10, std430) readonly buffer FENGGISurfaces { uint words[]; } gi_surfaces;
layout(set = 0, binding = 40, std430) readonly buffer FENGGISurfaceTracking {
	FENGGISurfaceTrackingRow rows[];
} gi_surface_tracking;

struct FENGGISurfelRecord {
	vec4 position_radius;
	vec4 normal_valid;
	ivec4 cell_last_seen;
	uvec4 surface;
	uvec4 state;
};
layout(set = 1, binding = 0, std430) buffer FENGGISurfelRecords { FENGGISurfelRecord records[]; } gi_surfels;
layout(set = 1, binding = 1, std430) buffer FENGGISurfelHash { uint slots[]; } gi_surfel_hash;
layout(set = 1, binding = 2, std430) buffer FENGGISurfelResponsePrevious { vec4 values[]; } gi_response_previous;
layout(set = 1, binding = 3, std430) buffer FENGGISurfelResponseNext { vec4 values[]; } gi_response_next;
layout(set = 1, binding = 4, std140) uniform FENGGISurfelConfig {
	mat4 world_to_owner;
	mat4 owner_to_world;
	vec4 owner_size_cell_radius;
	uvec4 limits;
	uvec4 light_counts;
	vec4 control;
	uvec4 adaptive;
	vec4 guide;
} gi_surfel_config;
layout(set = 1, binding = 5, std430) buffer FENGGISurfelCounters { uint values[]; } gi_counters;

layout(set = 1, binding = 8, std430) buffer FENGGISurfelProcessedBits { uint values[]; } gi_surfel_processed_bits;
layout(set = 1, binding = 9, std430) buffer FENGGISurfelFiltered { vec4 values[]; } gi_filtered;
layout(set = 1, binding = 10, std430) buffer FENGGISurfelStatistics { vec4 values[]; } gi_statistics;
layout(set = 1, binding = 13, std430) buffer FENGGISurfelTracking { uvec4 values[]; } gi_tracking;
layout(set = 1, binding = 14, std430) buffer FENGGISurfelGuidePrevious { uint values[]; } gi_guide_previous;
layout(set = 1, binding = 15, std430) buffer FENGGISurfelGuideNext { uint values[]; } gi_guide_next;
layout(set = 1, binding = 16, std430) buffer FENGGISurfelFreeIndices { uint values[]; } gi_free_indices;

const uint SLOT_EMPTY = 0xffffffffu;
const uint SLOT_TOMBSTONE = 0xfffffffeu;
const uint SLOT_LOCKED = 0xfffffffdu;
const uint MAX_HASH_PROBES = 8u;
const uint GUIDE_WORDS = 5u;
const float CELL_EPSILON = 1.9073486328125e-6;
const float GI_SURFEL_LOD_TARGET_PIXELS = 8.0;

uint hash_cell(ivec3 cell, uint level) {
	uvec3 value = uvec3(cell);
	uint hash_value = value.x * 0x9e3779b9u ^ value.y * 0x85ebca6bu
			^ value.z * 0xc2b2ae35u ^ level * 0x27d4eb2fu;
	hash_value ^= hash_value >> 16u;
	hash_value *= 0x7feb352du;
	hash_value ^= hash_value >> 15u;
	hash_value *= 0x846ca68bu;
	return hash_value ^ (hash_value >> 16u);
}

float level_radius(uint level) {
	return max(gi_surfel_config.owner_size_cell_radius.w * (level == 0u ? 1.0 : 2.0), 0.001);
}

ivec3 world_cell(vec3 position, uint level) {
	float size = 2.0 * level_radius(level);
	return ivec3(floor((position - gi_surfel_config.owner_to_world[3].xyz) / size));
}

uint source_token(uvec4 identity) {
	// Keep the exact motion revision so lookup can reject records still stored at
	// their previous world transform. Generation separately rejects reused slots.
	return identity.z;
}

void push_free(uint index) {
	uint slot = atomicAdd(gi_counters.values[6], 1u);
	if (slot < gi_surfel_config.limits.x) gi_free_indices.values[slot] = index;
	else atomicMin(gi_counters.values[6], gi_surfel_config.limits.x);
}

void clear_history(uint index) {
	gi_response_previous.values[index] = vec4(0.0);
	gi_response_next.values[index] = vec4(0.0);
	gi_filtered.values[index] = vec4(0.0);
	gi_statistics.values[index] = vec4(0.0);
	uint base = index * GUIDE_WORDS;
	for (uint word = 0u; word < GUIDE_WORDS; word++) {
		gi_guide_previous.values[base + word] = 0u;
		gi_guide_next.values[base + word] = 0u;
	}
	gi_tracking.values[index] = uvec4(0u);
}

void retire_record(uint index, inout FENGGISurfelRecord record) {
	if (record.normal_valid.w < 0.5 || atomicCompSwap(gi_surfels.records[index].state.z, 0u, 1u) != 0u) return;
	uint old_slot = record.surface.y;
	if (old_slot <= gi_surfel_config.limits.y
			&& atomicCompSwap(gi_surfel_hash.slots[old_slot], index, SLOT_LOCKED) == index) {
		memoryBarrierBuffer();
		atomicExchange(gi_surfel_hash.slots[old_slot], SLOT_TOMBSTONE);
	}
	record.state.z = 1u;
	record.normal_valid.w = 0.0;
	record.surface.x = 0u;
	record.surface.z = 0xffffffffu;
	record.surface.w = 0xffffffffu;
	gi_surfels.records[index] = record;
	clear_history(index);
	memoryBarrierBuffer();
	push_free(index);
}

bool insert_existing(uint index, uint level, ivec3 cell, FENGGISurfelRecord current,
		out uint new_hash_slot) {
	uint slot = hash_cell(cell, level) & gi_surfel_config.limits.y;
	float tolerance = level_radius(level) * 0.35;
	float tolerance_squared = tolerance * tolerance;
	for (uint probe = 0u; probe < MAX_HASH_PROBES; probe++) {
		uint old_value = gi_surfel_hash.slots[slot];
		if (old_value == SLOT_LOCKED) {
			slot = (slot + 1u) & gi_surfel_config.limits.y;
			continue;
		}
		if (old_value == SLOT_EMPTY || old_value == SLOT_TOMBSTONE) {
			if (atomicCompSwap(gi_surfel_hash.slots[slot], old_value, SLOT_LOCKED) == old_value) {
				new_hash_slot = slot;
				memoryBarrierBuffer();
				atomicExchange(gi_surfel_hash.slots[slot], index);
				return true;
			}
		} else if (old_value < gi_surfel_config.limits.x && old_value != index) {
			FENGGISurfelRecord other = gi_surfels.records[old_value];
			bool same_anchor = other.normal_valid.w > 0.5 && other.state.z == 0u
					&& gi_tracking.values[old_value].z == level
					&& other.surface.z == current.surface.z
					&& other.surface.w == current.surface.w
					&& dot(other.position_radius.xyz - current.position_radius.xyz,
							other.position_radius.xyz - current.position_radius.xyz) < tolerance_squared;
			// A maintenance lane only retires its own record. Retiring another
			// lane's local copy could race that lane's final whole-record store and
			// resurrect a slot already pushed onto the free stack.
			if (same_anchor && old_value < index) return false;
		} else if (old_value == index) {
			new_hash_slot = slot;
			return true;
		}
		slot = (slot + 1u) & gi_surfel_config.limits.y;
	}
	return false;
}

bool find_same_anchor(uint index, uint target_level, ivec3 target_cell,
		FENGGISurfelRecord current) {
	float tolerance = level_radius(target_level) * 0.35;
	float tolerance_squared = tolerance * tolerance;
	for (int z = -1; z <= 1; z++) {
		for (int y = -1; y <= 1; y++) {
			for (int x = -1; x <= 1; x++) {
				ivec3 cell = target_cell + ivec3(x, y, z);
				uint slot = hash_cell(cell, target_level) & gi_surfel_config.limits.y;
				for (uint probe = 0u; probe < MAX_HASH_PROBES; probe++) {
					uint other_index = gi_surfel_hash.slots[slot];
					if (other_index == SLOT_EMPTY) break;
					if (other_index < gi_surfel_config.limits.x && other_index != index) {
						FENGGISurfelRecord other = gi_surfels.records[other_index];
						if (other.normal_valid.w > 0.5 && other.state.z == 0u
								&& gi_tracking.values[other_index].z == target_level
								&& other.surface.z == current.surface.z
								&& other.surface.w == current.surface.w
								&& dot(other.position_radius.xyz - current.position_radius.xyz,
										other.position_radius.xyz - current.position_radius.xyz) < tolerance_squared) {
							return other_index < index;
						}
					}
					slot = (slot + 1u) & gi_surfel_config.limits.y;
				}
			}
		}
	}
	return false;
}

uint desired_level(uint record_index, vec3 current_world_surface) {
	if (gi_surfel_config.adaptive.x == 0u) return 0u;
	float height = max(gi_frame.data.size_exposure.y, 1.0);
	vec3 camera_position = gi_frame.data.view_to_world[3].xyz;
	vec3 view_position = transpose(mat3(gi_frame.data.view_to_world))
			* (current_world_surface - camera_position);
	float pixel_footprint = 2.0 * abs(gi_frame.data.inverse_projection[1][1]) / height;
	if (abs(gi_frame.data.inverse_projection[3][3]) < 0.5) {
		pixel_footprint *= max(abs(view_position.z), 1e-3);
	}
	float footprint = pixel_footprint * GI_SURFEL_LOD_TARGET_PIXELS;
	float threshold = gi_surfel_config.owner_size_cell_radius.w;
	uint current = gi_tracking.values[record_index].z;
	if (current == 0u) return footprint >= threshold * 1.25 ? 1u : 0u;
	return footprint < threshold * 0.8 ? 0u : 1u;
}

bool surface_anchor(uint slot, uint primitive, uint packed_bary, out vec3 local_position,
		out vec3 local_normal, out FENGGISurfaceTrackingRow tracking) {
	tracking = gi_surface_tracking.rows[slot];
	uvec4 identity = tracking.identity;
	if ((identity.w & 1u) == 0u) return false;
	uint row = slot * 8u;
	uint vertex_base = gi_surfaces.words[row + 0u] / 4u;
	uint index_base = gi_surfaces.words[row + 1u] / 4u;
	uint index_count = gi_surfaces.words[row + 2u];
	uint first_index = primitive * 3u;
	if (first_index + 2u >= index_count) return false;
	uint i0 = gi_indices.indices[index_base + first_index];
	uint i1 = gi_indices.indices[index_base + first_index + 1u];
	uint i2 = gi_indices.indices[index_base + first_index + 2u];
	uint v0 = vertex_base + i0 * 8u;
	uint v1 = vertex_base + i1 * 8u;
	uint v2 = vertex_base + i2 * 8u;
	vec3 p0 = uintBitsToFloat(uvec3(gi_vertices.words[v0], gi_vertices.words[v0 + 1u], gi_vertices.words[v0 + 2u]));
	vec3 p1 = uintBitsToFloat(uvec3(gi_vertices.words[v1], gi_vertices.words[v1 + 1u], gi_vertices.words[v1 + 2u]));
	vec3 p2 = uintBitsToFloat(uvec3(gi_vertices.words[v2], gi_vertices.words[v2 + 1u], gi_vertices.words[v2 + 2u]));
	vec3 n0 = uintBitsToFloat(uvec3(gi_vertices.words[v0 + 3u], gi_vertices.words[v0 + 4u], gi_vertices.words[v0 + 5u]));
	vec3 n1 = uintBitsToFloat(uvec3(gi_vertices.words[v1 + 3u], gi_vertices.words[v1 + 4u], gi_vertices.words[v1 + 5u]));
	vec3 n2 = uintBitsToFloat(uvec3(gi_vertices.words[v2 + 3u], gi_vertices.words[v2 + 4u], gi_vertices.words[v2 + 5u]));
	vec2 bary = unpackUnorm2x16(packed_bary);
	vec3 weights = vec3(max(1.0 - bary.x - bary.y, 0.0), bary.x, bary.y);
	float weight_sum = weights.x + weights.y + weights.z;
	if (!(weight_sum > 1e-6)) return false;
	weights /= weight_sum;
	local_position = p0 * weights.x + p1 * weights.y + p2 * weights.z;
	local_normal = n0 * weights.x + n1 * weights.y + n2 * weights.z;
	return dot(local_normal, local_normal) > 1e-12
			&& all(not(isnan(local_position))) && all(not(isinf(local_position)))
			&& all(not(isnan(local_normal))) && all(not(isinf(local_normal)));
}

void main() {
	uint item = gl_GlobalInvocationID.x;
	uint count = gi_surfel_maintenance_control.dispatch.x;
	if (item >= count) return;
	uint capacity = gi_surfel_config.limits.x;
	uint active_count = min(capacity, gi_counters.values[1]);
	if (active_count == 0u) return;
	// A persistent GPU cursor advances by scheduled lanes, with the processed-bit
	// buffer suppressing duplicate indices when the active high-water mark is small.
	uint ticket = atomicAdd(gi_counters.values[7], 1u);
	uint index = ticket % active_count;
	uint processed_word = index >> 5u;
	uint processed_mask = 1u << (index & 31u);
	if ((atomicOr(gi_surfel_processed_bits.values[processed_word], processed_mask)
			& processed_mask) != 0u) return;
	FENGGISurfelRecord record = gi_surfels.records[index];
	if (record.normal_valid.w < 0.5 || record.state.z != 0u
			|| record.surface.z == 0xffffffffu || record.surface.w == 0xffffffffu) return;
	uint surface_slot = record.surface.z;
	if (surface_slot >= gi_surfel_config.adaptive.w) {
		retire_record(index, record);
		return;
	}
	FENGGISurfaceTrackingRow tracking = gi_surface_tracking.rows[surface_slot];
	if ((tracking.identity.w & 1u) == 0u
			|| tracking.identity.x != gi_tracking.values[index].y) {
		retire_record(index, record);
		return;
	}
	vec3 local_position;
	vec3 local_normal;
	FENGGISurfaceTrackingRow anchor_tracking;
	if (!surface_anchor(surface_slot, record.surface.w, gi_tracking.values[index].x,
			local_position, local_normal, anchor_tracking)) {
		retire_record(index, record);
		return;
	}
	vec3 world_surface = (tracking.local_to_world * vec4(local_position, 1.0)).xyz;
	vec3 world_normal = normalize(mat3(tracking.normal_to_world_columns[0].xyz,
			tracking.normal_to_world_columns[1].xyz, tracking.normal_to_world_columns[2].xyz)
			* normalize(local_normal));
	if (!(dot(world_normal, world_normal) > 0.5) || any(isnan(world_surface))
			|| any(isinf(world_surface)) || any(isnan(world_normal)) || any(isinf(world_normal))) {
		retire_record(index, record);
		return;
	}
	uint old_level = gi_tracking.values[index].z;
	uint packed_bary = gi_tracking.values[index].x;
	uint level = desired_level(index, world_surface);
	float radius = level_radius(level);
	// Keep the stable anchor on the actual triangle. Individual rays add their
	// own small origin bias; radius is never used as a surface offset.
	vec3 world_position = world_surface;
	vec3 owner_local = (gi_surfel_config.world_to_owner * vec4(world_position, 1.0)).xyz;
	vec3 half_extent = gi_surfel_config.owner_size_cell_radius.xyz * 0.5;
	vec3 epsilon = max(half_extent, vec3(1.0)) * CELL_EPSILON;
	if (any(greaterThan(abs(owner_local), half_extent + epsilon))) {
		retire_record(index, record);
		return;
	}
	uint current_token = source_token(tracking.identity);
	bool motion_changed = gi_tracking.values[index].w != current_token;
	vec3 anchor_delta = world_position - record.position_radius.xyz;
	float anchor_motion_squared = dot(anchor_delta, anchor_delta);
	float normal_match = dot(world_normal, normalize(record.normal_valid.xyz));
	bool moved = anchor_motion_squared > max(radius * radius * 1e-6, 1e-10)
			|| normal_match < 0.99999;
	bool discontinuous_motion = anchor_motion_squared > max(4.0 * radius * radius, 0.0625)
			|| normal_match < 0.75;
	if (level == old_level && !motion_changed && !moved) return;
	ivec3 cell = world_cell(world_position, level);
	if (find_same_anchor(index, level, cell, record)) {
		retire_record(index, record);
		return;
	}
	uint old_slot = record.surface.y;
	if (old_slot <= gi_surfel_config.limits.y
			&& atomicCompSwap(gi_surfel_hash.slots[old_slot], index, SLOT_LOCKED) == index) {
		memoryBarrierBuffer();
		atomicExchange(gi_surfel_hash.slots[old_slot], SLOT_TOMBSTONE);
	}
	uint new_slot;
	if (!insert_existing(index, level, cell, record, new_slot)) {
		record.surface.y = old_slot;
		retire_record(index, record);
		return;
	}
	record.position_radius = vec4(world_position, radius);
	record.normal_valid.xyz = world_normal;
	record.cell_last_seen.xyz = cell;
	record.surface.y = new_slot;
	gi_tracking.values[index].y = tracking.identity.x;
	gi_tracking.values[index].z = level;
	gi_tracking.values[index].w = current_token;
	if (discontinuous_motion) {
		clear_history(index);
		record.state.y = 0u;
	}
	gi_tracking.values[index] = uvec4(packed_bary,
		tracking.identity.x, level, current_token);
	// Publish the full record under the invalid-state lock. No concurrent retire
	// can then recycle this slot while this invocation re-anchors it.
	if (atomicCompSwap(gi_surfels.records[index].state.z, 0u, 2u) != 0u) return;
	record.state.z = 2u;
	gi_surfels.records[index] = record;
	memoryBarrierBuffer();
	atomicExchange(gi_surfels.records[index].state.z, 0u);
}
