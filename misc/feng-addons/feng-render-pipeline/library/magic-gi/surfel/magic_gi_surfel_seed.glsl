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
	uvec4 state; // queue token, processed token, invalid flag, pending layer mask.
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
} gi_surfel_config;
layout(set = 1, binding = 5, std430) buffer FENGGISurfelCounters {
	uint values[];
} gi_surfel_counters;
layout(set = 1, binding = 6, std430) buffer FENGGISurfelUpdateQueue {
	uint indices[];
} gi_surfel_update_queue;

const uint GI_SURFEL_SLOT_EMPTY = 0xffffffffu;
const uint GI_SURFEL_SLOT_TOMBSTONE = 0xfffffffeu;
const uint GI_SURFEL_SLOT_LOCKED = 0xfffffffdu;
const uint GI_SURFEL_MAX_HASH_PROBES = 8u;
const uint GI_SURFEL_TTL_FRAMES = 600u;
const uint GI_SURFEL_UNKNOWN_INSTANCE = 0xffffffffu;

uint gi_hash(uint value) {
	value ^= value >> 16u;
	value *= 0x7feb352du;
	value ^= value >> 15u;
	value *= 0x846ca68bu;
	return value ^ (value >> 16u);
}

uint gi_surfel_hash_cell(ivec3 cell) {
	uvec3 value = uvec3(cell);
	uint hash_value = value.x * 0x9e3779b9u ^ value.y * 0x85ebca6bu ^ value.z * 0xc2b2ae35u;
	hash_value ^= hash_value >> 16u;
	hash_value *= 0x7feb352du;
	hash_value ^= hash_value >> 15u;
	hash_value *= 0x846ca68bu;
	return hash_value ^ (hash_value >> 16u);
}

bool gi_surfel_same_record(uint index, ivec3 cell, vec3 world, vec3 normal) {
	FENGGISurfelRecord record = gi_surfels.records[index];
	if (record.normal_valid.w < 0.5 || record.state.z != 0u
			|| any(notEqual(record.cell_last_seen.xyz, cell))) return false;
	vec3 old_normal = normalize(record.normal_valid.xyz);
	vec3 delta = world - record.position_radius.xyz;
	float radius = max(record.position_radius.w, 0.001);
	return dot(old_normal, normal) > 0.94
			&& abs(dot(delta, old_normal)) < radius * 0.2
			&& dot(delta, delta) < radius * radius * 0.25;
}

void gi_surfel_write_record(uint index, uint slot, ivec3 cell, vec3 world,
		vec3 normal, float radius, uint frame_token, bool reset_history) {
	if (reset_history) {
		gi_surfel_response_previous.values[index] = vec4(0.0);
		gi_surfel_response_next.values[index] = vec4(0.0);
		gi_surfels.records[index].position_radius = vec4(world, radius);
		gi_surfels.records[index].normal_valid = vec4(normal, 1.0);
		gi_surfels.records[index].cell_last_seen = ivec4(cell, int(frame_token));
		gi_surfels.records[index].surface = uvec4(0xffffffffu, slot, GI_SURFEL_UNKNOWN_INSTANCE, 0xffffffffu);
		gi_surfels.records[index].state = uvec4(0u, 0u, 0u, 0xffffffffu);
		memoryBarrierBuffer();
		return;
	}
	FENGGISurfelRecord old_record = gi_surfels.records[index];
	vec3 updated_position = mix(old_record.position_radius.xyz, world, 0.2);
	vec3 updated_normal = normalize(mix(old_record.normal_valid.xyz, normal, 0.2));
	gi_surfels.records[index].position_radius = vec4(updated_position, radius);
	gi_surfels.records[index].normal_valid = vec4(updated_normal, 1.0);
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
		vec3 world, vec3 normal, float radius, uint frame_token) {
	uint claimed = atomicCompSwap(gi_surfel_hash.slots[hash_slot], old_slot_value, GI_SURFEL_SLOT_LOCKED);
	if (claimed != old_slot_value) return false;
	uint ticket = atomicAdd(gi_surfel_counters.values[0], 1u);
	uint capacity = gi_surfel_config.limits.x;
	uint record_index = ticket < capacity ? ticket : ticket % capacity;
	if (ticket >= capacity) {
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
	gi_surfel_write_record(record_index, hash_slot, cell, world, normal, radius, frame_token, true);
	atomicMax(gi_surfel_counters.values[1], record_index + 1u);
	memoryBarrierBuffer();
	atomicExchange(gi_surfel_hash.slots[hash_slot], record_index);
	gi_surfel_queue_update(record_index, frame_token);
	return true;
}

void gi_surfel_seed_one(vec3 world, vec3 normal, uint frame_token) {
	float radius = max(gi_surfel_config.owner_size_cell_radius.w, 0.001);
	vec3 owner_local = (gi_surfel_config.world_to_owner * vec4(world, 1.0)).xyz;
	vec3 half_extent = gi_surfel_config.owner_size_cell_radius.xyz * 0.5;
	// TAA inverse projection can round an edge sample a few float ULPs outside.
	vec3 bounds_epsilon = max(half_extent, vec3(1.0)) * 1.9073486328125e-6;
	if (any(greaterThan(abs(owner_local), half_extent + bounds_epsilon))) return;
	vec3 owner_origin = gi_surfel_config.owner_to_world[3].xyz;
	ivec3 cell = ivec3(floor((world - owner_origin) / (2.0 * radius)));
	uint hash_slot = gi_surfel_hash_cell(cell) & gi_surfel_config.limits.y;
	for (uint probe = 0u; probe < GI_SURFEL_MAX_HASH_PROBES; probe++) {
		uint entry = gi_surfel_hash.slots[hash_slot];
		if (entry == GI_SURFEL_SLOT_LOCKED) {
			continue;
		}
		if (entry == GI_SURFEL_SLOT_EMPTY || entry == GI_SURFEL_SLOT_TOMBSTONE) {
			if (gi_surfel_insert_new(hash_slot, entry, cell, world, normal, radius, frame_token)) return;
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
		bool same = gi_surfel_same_record(entry, cell, world, normal);
		if (expired || same) {
			if (atomicCompSwap(gi_surfel_hash.slots[hash_slot], entry,
					GI_SURFEL_SLOT_LOCKED) == entry) {
				old_record = gi_surfels.records[entry];
				expired = old_record.normal_valid.w < 0.5 || old_record.state.z != 0u
						|| frame_token - uint(old_record.cell_last_seen.w) > GI_SURFEL_TTL_FRAMES;
				same = gi_surfel_same_record(entry, cell, world, normal);
				if (expired || same) {
					gi_surfel_write_record(entry, hash_slot, cell, world, normal, radius,
							frame_token, expired);
					atomicExchange(gi_surfel_hash.slots[hash_slot], entry);
					gi_surfel_queue_update(entry, frame_token);
					return;
				}
				atomicExchange(gi_surfel_hash.slots[hash_slot], entry);
			}
		}
		hash_slot = (hash_slot + 1u) & gi_surfel_config.limits.y;
	}
}

void main() {
	uint sample_index = gl_GlobalInvocationID.x;
	uint sample_count = uint(gi_surfel_config.control.z);
	if (sample_index >= sample_count) return;
	ivec2 depth_size = textureSize(gi_depth, 0);
	if (any(lessThanEqual(depth_size, ivec2(0)))) return;
	uint pixel_count = uint(depth_size.x) * uint(depth_size.y);
	uint token = gi_surfel_config.limits.w;
	uint seed = gi_hash(sample_index ^ token * 0x9e3779b9u);
	uint pixel_index = gi_hash(seed ^ 0x85ebca6bu) % max(pixel_count, 1u);
	ivec2 pixel = ivec2(int(pixel_index % uint(depth_size.x)), int(pixel_index / uint(depth_size.x)));
	float depth = texelFetch(gi_depth, pixel, 0).r;
	if (!(depth > 0.0) || isnan(depth) || isinf(depth)) return;
	vec2 uv = (vec2(pixel) + 0.5) / vec2(depth_size);
	vec4 view_h = gi_frame.data.inverse_projection * vec4(uv * 2.0 - 1.0, depth, 1.0);
	if (!(abs(view_h.w) > 1e-8) || isnan(view_h.w) || isinf(view_h.w)) return;
	vec3 view_position = view_h.xyz / view_h.w;
	vec3 world_position = (gi_frame.data.view_to_world * vec4(view_position, 1.0)).xyz;
	ivec2 normal_size = textureSize(gi_normal_roughness, 0);
	ivec2 normal_pixel = clamp(ivec2(floor(uv * vec2(normal_size))), ivec2(0), normal_size - 1);
	vec3 encoded_normal = texelFetch(gi_normal_roughness, normal_pixel, 0).xyz * 2.0 - 1.0;
	float normal_length = length(encoded_normal);
	if (!(normal_length > 1e-6) || isnan(normal_length) || isinf(normal_length)) return;
	vec3 normal = normalize(mat3(gi_frame.data.view_to_world) * (encoded_normal / normal_length));
	gi_surfel_seed_one(world_position, normal, token);
}
