#[compute]
#version 450
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 1) uniform sampler2D gi_depth;
layout(set = 0, binding = 2) uniform sampler2D gi_normal_roughness;
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
layout(set = 1, binding = 2, std430) buffer FENGGISurfelResponsePrevious {
	vec4 values[];
} gi_surfel_response_previous;
layout(set = 1, binding = 3, std430) buffer FENGGISurfelResponseNext {
	vec4 values[];
} gi_surfel_response_next;
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
layout(set = 1, binding = 5, std430) buffer FENGGISurfelCounters {
	uint values[];
} gi_surfel_counters;
layout(set = 1, binding = 6, std430) buffer FENGGISurfelUpdateQueue {
	uint indices[];
} gi_surfel_update_queue;
layout(set = 1, binding = 7, std430) buffer FENGGISurfelResponseFiltered {
	vec4 values[];
} gi_surfel_response_filtered;
layout(set = 1, binding = 8, std430) buffer FENGGISurfelStatistics {
	vec4 values[]; // Short-term mean RGB and second moment of luminance.
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

const uint GI_SURFEL_SLOT_EMPTY = 0xffffffffu;
const uint GI_SURFEL_SLOT_TOMBSTONE = 0xfffffffeu;
const uint GI_SURFEL_SLOT_LOCKED = 0xfffffffdu;
const uint GI_SURFEL_MAX_HASH_PROBES = 8u;
const uint GI_SURFEL_TTL_FRAMES = 600u;
const uint GI_SURFEL_UNKNOWN_INSTANCE = 0xffffffffu;
const float GI_SURFEL_LOD_TARGET_PIXELS = 8.0;
const uint GI_SURFEL_TILE_CANDIDATE_COUNT = 4u;
const uint GI_SURFEL_TILE_PHASE_COUNT = 64u;

uint gi_surfel_pop_free_index() {
	uint free_count = atomicAdd(gi_surfel_counters.values[6], 0u);
	for (uint attempt = 0u; attempt < 32u && free_count > 0u; attempt++) {
		uint previous = atomicCompSwap(gi_surfel_counters.values[6], free_count, free_count - 1u);
		if (previous == free_count) return gi_surfel_free_indices.values[free_count - 1u];
		free_count = previous;
	}
	return GI_SURFEL_SLOT_EMPTY;
}

void gi_surfel_push_free_index(uint record_index) {
	uint slot = atomicAdd(gi_surfel_counters.values[6], 1u);
	if (slot < gi_surfel_config.limits.x) {
		gi_surfel_free_indices.values[slot] = record_index;
	} else {
		atomicMin(gi_surfel_counters.values[6], gi_surfel_config.limits.x);
	}
}

uint gi_hash(uint value) {
	value ^= value >> 16u;
	value *= 0x7feb352du;
	value ^= value >> 15u;
	value *= 0x846ca68bu;
	return value ^ (value >> 16u);
}

uint gi_surfel_hash_cell(ivec3 cell, uint level) {
	uvec3 value = uvec3(cell);
	uint hash_value = value.x * 0x9e3779b9u ^ value.y * 0x85ebca6bu
			^ value.z * 0xc2b2ae35u ^ level * 0x27d4eb2fu;
	hash_value ^= hash_value >> 16u;
	hash_value *= 0x7feb352du;
	hash_value ^= hash_value >> 15u;
	hash_value *= 0x846ca68bu;
	return hash_value ^ (hash_value >> 16u);
}

bool gi_surfel_same_record(uint index, ivec3 cell, uint level, vec3 world, vec3 normal) {
	FENGGISurfelRecord record = gi_surfels.records[index];
	if (record.normal_valid.w < 0.5 || record.state.z != 0u
			|| any(notEqual(record.cell_last_seen.xyz, cell))
			|| gi_surfel_tracking.values[index].z != level) return false;
	vec3 old_normal = normalize(record.normal_valid.xyz);
	vec3 delta = world - record.position_radius.xyz;
	float radius = max(record.position_radius.w, 0.001);
	return dot(old_normal, normal) > 0.94
			&& abs(dot(delta, old_normal)) < radius * 0.2
			&& dot(delta, delta) < radius * radius * 0.25;
}

void gi_surfel_write_record(uint index, uint slot, ivec3 cell, vec3 world,
		vec3 normal, float radius, uint level, uint frame_token, bool reset_history) {
	if (reset_history) {
		gi_surfel_response_previous.values[index] = vec4(0.0);
		gi_surfel_response_next.values[index] = vec4(0.0);
		gi_surfel_response_filtered.values[index] = vec4(0.0);
		gi_surfel_statistics.values[index] = vec4(0.0);
		gi_surfels.records[index].position_radius = vec4(world, radius);
		gi_surfels.records[index].normal_valid = vec4(normal, 1.0);
		gi_surfels.records[index].cell_last_seen = ivec4(cell, int(frame_token));
		gi_surfels.records[index].surface = uvec4(0xffffffffu, slot, GI_SURFEL_UNKNOWN_INSTANCE, 0xffffffffu);
		gi_surfels.records[index].state = uvec4(0u, 0u, 0u, 0u);
		gi_surfel_tracking.values[index] = uvec4(0u, 0u, level, 0u);
		uint guide_base = index * 5u;
		for (uint word = 0u; word < 5u; word++) {
			gi_surfel_guide_previous.values[guide_base + word] = 0u;
			gi_surfel_guide_next.values[guide_base + word] = 0u;
		}
		memoryBarrierBuffer();
		return;
	}
	// Keep a matched anchor stable. Moving it toward each GBuffer sample can cross a
	// primitive seam while provenance still names the old triangle, invalidating
	// otherwise static surfels during ray validation.
	gi_surfels.records[index].cell_last_seen.w = int(frame_token);
	gi_surfels.records[index].surface.y = slot;
	memoryBarrierBuffer();
}

void gi_surfel_queue_update(uint index, uint frame_token) {
	uint queue_stamp = frame_token + 1u;
	if (atomicExchange(gi_surfels.records[index].state.x, queue_stamp) == queue_stamp) return;
	uint queue_index = atomicAdd(gi_surfel_counters.values[3], 1u);
	if (queue_index < gi_surfel_config.limits.x) {
		gi_surfel_update_queue.indices[queue_index] = index;
	}
}

bool gi_surfel_insert_new(uint hash_slot, uint old_slot_value, ivec3 cell,
		vec3 world, vec3 normal, float radius, uint level, uint frame_token) {
	uint claimed = atomicCompSwap(gi_surfel_hash.slots[hash_slot], old_slot_value, GI_SURFEL_SLOT_LOCKED);
	if (claimed != old_slot_value) return false;
	uint capacity = gi_surfel_config.limits.x;
	uint record_index = gi_surfel_pop_free_index();
	uint ticket = 0u;
	bool evict_old = false;
	if (record_index == GI_SURFEL_SLOT_EMPTY) {
		ticket = atomicAdd(gi_surfel_counters.values[0], 1u);
		record_index = ticket < capacity ? ticket : ticket % capacity;
		evict_old = ticket >= capacity;
	}
	if (evict_old) {
		uint previous_slot = gi_surfels.records[record_index].surface.y;
		if (previous_slot >= gi_surfel_config.limits.y + 1u
				|| atomicCompSwap(gi_surfel_hash.slots[previous_slot], record_index,
						GI_SURFEL_SLOT_LOCKED) != record_index) {
			atomicExchange(gi_surfel_hash.slots[hash_slot], old_slot_value);
			return false;
		}
		memoryBarrierBuffer();
		atomicExchange(gi_surfel_hash.slots[previous_slot], GI_SURFEL_SLOT_TOMBSTONE);
	}
	gi_surfel_write_record(record_index, hash_slot, cell, world, normal, radius,
			level, frame_token, true);
	atomicMax(gi_surfel_counters.values[1], record_index + 1u);
	memoryBarrierBuffer();
	atomicExchange(gi_surfel_hash.slots[hash_slot], record_index);
	gi_surfel_queue_update(record_index, frame_token);
	return true;
}

void gi_surfel_seed_one(vec3 world, vec3 normal, uint level, uint frame_token) {
	float base_radius = max(gi_surfel_config.owner_size_cell_radius.w, 0.001);
	float radius = base_radius * (level == 0u ? 1.0 : 2.0);
	vec3 owner_local = (gi_surfel_config.world_to_owner * vec4(world, 1.0)).xyz;
	vec3 half_extent = gi_surfel_config.owner_size_cell_radius.xyz * 0.5;
	// TAA inverse projection can round an edge sample a few float ULPs outside.
	vec3 bounds_epsilon = max(half_extent, vec3(1.0)) * 1.9073486328125e-6;
	if (any(greaterThan(abs(owner_local), half_extent + bounds_epsilon))) return;
	vec3 owner_origin = gi_surfel_config.owner_to_world[3].xyz;
	ivec3 cell = ivec3(floor((world - owner_origin) / (2.0 * radius)));
	uint hash_slot = gi_surfel_hash_cell(cell, level) & gi_surfel_config.limits.y;
	for (uint probe = 0u; probe < GI_SURFEL_MAX_HASH_PROBES; probe++) {
		uint entry = gi_surfel_hash.slots[hash_slot];
		if (entry == GI_SURFEL_SLOT_LOCKED) {
			continue;
		}
		if (entry == GI_SURFEL_SLOT_EMPTY || entry == GI_SURFEL_SLOT_TOMBSTONE) {
			if (gi_surfel_insert_new(hash_slot, entry, cell, world, normal, radius,
					level, frame_token)) return;
			hash_slot = (hash_slot + 1u) & gi_surfel_config.limits.y;
			continue;
		}
		if (entry >= gi_surfel_config.limits.x) {
			hash_slot = (hash_slot + 1u) & gi_surfel_config.limits.y;
			continue;
		}
		FENGGISurfelRecord old_record = gi_surfels.records[entry];
		uint age = frame_token - uint(old_record.cell_last_seen.w);
		bool expired = old_record.normal_valid.w < 0.5 || old_record.state.z != 0u
				|| age > GI_SURFEL_TTL_FRAMES;
		bool same = gi_surfel_same_record(entry, cell, level, world, normal);
		if (expired || same) {
			if (atomicCompSwap(gi_surfel_hash.slots[hash_slot], entry,
					GI_SURFEL_SLOT_LOCKED) == entry) {
				old_record = gi_surfels.records[entry];
				expired = old_record.normal_valid.w < 0.5 || old_record.state.z != 0u
						|| frame_token - uint(old_record.cell_last_seen.w) > GI_SURFEL_TTL_FRAMES;
				same = gi_surfel_same_record(entry, cell, level, world, normal);
				if (expired || same) {
					bool needs_first_update = expired || old_record.state.w == 0u;
					gi_surfel_write_record(entry, hash_slot, cell, world, normal, radius,
							level, frame_token, expired);
					atomicExchange(gi_surfel_hash.slots[hash_slot], entry);
					if (needs_first_update) gi_surfel_queue_update(entry, frame_token);
					return;
				}
				atomicExchange(gi_surfel_hash.slots[hash_slot], entry);
			}
		}
		hash_slot = (hash_slot + 1u) & gi_surfel_config.limits.y;
	}
}

bool gi_surfel_decode_seed_candidate(ivec2 pixel, ivec2 depth_size,
		out vec3 world_position, out vec3 normal, out uint level, out ivec3 cell) {
	if (any(lessThan(pixel, ivec2(0))) || any(greaterThanEqual(pixel, depth_size))) return false;
	float depth = texelFetch(gi_depth, pixel, 0).r;
	if (!(depth > 0.0) || isnan(depth) || isinf(depth)) return false;
	vec2 uv = (vec2(pixel) + 0.5) / vec2(depth_size);
	vec4 view_h = gi_frame.data.inverse_projection * vec4(uv * 2.0 - 1.0, depth, 1.0);
	if (!(abs(view_h.w) > 1e-8) || isnan(view_h.w) || isinf(view_h.w)) return false;
	vec3 view_position = view_h.xyz / view_h.w;
	if (any(isnan(view_position)) || any(isinf(view_position))) return false;
	world_position = (gi_frame.data.view_to_world * vec4(view_position, 1.0)).xyz;
	if (any(isnan(world_position)) || any(isinf(world_position))) return false;
	float inverse_projection_y = abs(gi_frame.data.inverse_projection[1][1]);
	float pixel_footprint = 2.0 * inverse_projection_y / float(max(depth_size.y, 1));
	if (abs(gi_frame.data.inverse_projection[3][3]) < 0.5) {
		pixel_footprint *= max(abs(view_position.z), 1e-3);
	}
	float lod_footprint = pixel_footprint * GI_SURFEL_LOD_TARGET_PIXELS;
	level = gi_surfel_config.adaptive.x != 0u
			&& lod_footprint >= gi_surfel_config.owner_size_cell_radius.w ? 1u : 0u;
	ivec2 normal_size = textureSize(gi_normal_roughness, 0);
	if (any(lessThanEqual(normal_size, ivec2(0)))) return false;
	ivec2 normal_pixel = clamp(ivec2(floor(uv * vec2(normal_size))), ivec2(0), normal_size - 1);
	vec3 encoded_normal = texelFetch(gi_normal_roughness, normal_pixel, 0).xyz * 2.0 - 1.0;
	float normal_length = length(encoded_normal);
	if (!(normal_length > 1e-6) || isnan(normal_length) || isinf(normal_length)) return false;
	normal = normalize(mat3(gi_frame.data.view_to_world) * (encoded_normal / normal_length));
	if (any(isnan(normal)) || any(isinf(normal))) return false;
	vec3 owner_local = (gi_surfel_config.world_to_owner * vec4(world_position, 1.0)).xyz;
	vec3 half_extent = gi_surfel_config.owner_size_cell_radius.xyz * 0.5;
	vec3 bounds_epsilon = max(half_extent, vec3(1.0)) * 1.9073486328125e-6;
	if (any(greaterThan(abs(owner_local), half_extent + bounds_epsilon))) return false;
	float base_radius = max(gi_surfel_config.owner_size_cell_radius.w, 0.001);
	float radius = base_radius * (level == 0u ? 1.0 : 2.0);
	vec3 owner_origin = gi_surfel_config.owner_to_world[3].xyz;
	cell = ivec3(floor((world_position - owner_origin) / (2.0 * radius)));
	return true;
}

float gi_surfel_candidate_cell_coverage(ivec3 cell, uint level,
		vec3 world_position, vec3 normal, uint frame_token) {
	float base_radius = max(gi_surfel_config.owner_size_cell_radius.w, 0.001);
	float radius = base_radius * (level == 0u ? 1.0 : 2.0);
	uint hash_slot = gi_surfel_hash_cell(cell, level) & gi_surfel_config.limits.y;
	bool saw_locked_slot = false;
	for (uint probe = 0u; probe < GI_SURFEL_MAX_HASH_PROBES; probe++) {
		uint entry = gi_surfel_hash.slots[hash_slot];
		if (entry == GI_SURFEL_SLOT_EMPTY) break;
		if (entry == GI_SURFEL_SLOT_LOCKED) {
			saw_locked_slot = true;
		} else if (entry != GI_SURFEL_SLOT_TOMBSTONE
				&& entry < gi_surfel_config.limits.x) {
			FENGGISurfelRecord record = gi_surfels.records[entry];
			uint age = frame_token - uint(record.cell_last_seen.w);
			if (age <= GI_SURFEL_TTL_FRAMES
					&& gi_surfel_same_record(entry, cell, level, world_position, normal)) {
				return 1.0;
			}
		}
		hash_slot = (hash_slot + 1u) & gi_surfel_config.limits.y;
	}
	// Do not select a cell while a colliding slot is being published. The next
	// rotating tile visit will score it again after the atomic claim resolves.
	return saw_locked_slot ? 2.0 : 0.0;
}

ivec2 gi_surfel_tile_representative_offset(uint candidate, uint phase) {
	uint local_phase = (phase + candidate * 17u) & (GI_SURFEL_TILE_PHASE_COUNT - 1u);
	ivec2 local_offset = ivec2(int(local_phase & 7u), int(local_phase >> 3u));
	return ivec2(int(candidate & 1u) * 8, int((candidate >> 1u) & 1u) * 8)
			+ local_offset;
}

void main() {
	uint sample_index = gl_GlobalInvocationID.x;
	uint sample_count = uint(gi_surfel_config.control.z);
	if (sample_index >= sample_count) return;
	ivec2 depth_size = textureSize(gi_depth, 0);
	if (any(lessThanEqual(depth_size, ivec2(0)))) return;
	uint pixel_count = uint(depth_size.x) * uint(depth_size.y);
	uint token = gi_surfel_config.limits.w;
	uint seed = gi_hash((sample_index + token) ^ 0x9e3779b9u);
	if (gi_surfel_config.adaptive.x != 0u && gi_surfel_config.adaptive.y != 0u) {
		uint tile_width = uint((depth_size.x + 15) / 16);
		uint absolute_visit = gi_surfel_config.adaptive.z + sample_index;
		uint tile_index = absolute_visit % gi_surfel_config.adaptive.y;
		uint tile_sweep = absolute_visit / gi_surfel_config.adaptive.y;
		ivec2 tile = ivec2(int(tile_index % tile_width), int(tile_index / tile_width));
		// The persistent cursor advances one slot per scheduled tile. This affine
		// permutation visits every 8x8 offset after 64 complete tile sweeps, even
		// when a tile is only revisited every several frames.
		uint phase = (tile_index * 7u + tile_sweep * 13u)
				& (GI_SURFEL_TILE_PHASE_COUNT - 1u);
		uint tie_start = gi_hash(seed ^ 0x27d4eb2fu) & 3u;
		ivec2 seen_pixels[4];
		uint seen_count = 0u;
		bool found = false;
		float best_coverage = 2.0;
		uint best_tie_rank = 4u;
		vec3 best_world = vec3(0.0);
		vec3 best_normal = vec3(0.0, 1.0, 0.0);
		uint best_level = 0u;
		for (uint candidate = 0u; candidate < GI_SURFEL_TILE_CANDIDATE_COUNT; candidate++) {
			ivec2 candidate_pixel = min(tile * 16
					+ gi_surfel_tile_representative_offset(candidate, phase), depth_size - 1);
			bool duplicate = false;
			for (uint previous = 0u; previous < seen_count; previous++) {
				if (all(equal(seen_pixels[previous], candidate_pixel))) duplicate = true;
			}
			if (duplicate) continue;
			seen_pixels[seen_count++] = candidate_pixel;
			vec3 candidate_world;
			vec3 candidate_normal;
			uint candidate_level;
			ivec3 candidate_cell;
			if (!gi_surfel_decode_seed_candidate(candidate_pixel, depth_size,
					candidate_world, candidate_normal, candidate_level, candidate_cell)) continue;
			float coverage = gi_surfel_candidate_cell_coverage(candidate_cell,
					candidate_level, candidate_world, candidate_normal, token);
			if (coverage > 1.0) continue;
			uint tie_rank = (candidate + 4u - tie_start) & 3u;
			if (!found || coverage < best_coverage
					|| (coverage == best_coverage && tie_rank < best_tie_rank)) {
				found = true;
				best_coverage = coverage;
				best_tie_rank = tie_rank;
				best_world = candidate_world;
				best_normal = candidate_normal;
				best_level = candidate_level;
			}
		}
		if (found) gi_surfel_seed_one(best_world, best_normal, best_level, token);
		return;
	}
	uint pixel_index = gi_hash(seed ^ 0x85ebca6bu) % max(pixel_count, 1u);
	ivec2 pixel = ivec2(int(pixel_index % uint(depth_size.x)), int(pixel_index / uint(depth_size.x)));
	vec3 world_position;
	vec3 normal;
	uint level;
	ivec3 cell;
	if (gi_surfel_decode_seed_candidate(pixel, depth_size,
			world_position, normal, level, cell)) {
		gi_surfel_seed_one(world_position, normal, level, token);
	}
}
