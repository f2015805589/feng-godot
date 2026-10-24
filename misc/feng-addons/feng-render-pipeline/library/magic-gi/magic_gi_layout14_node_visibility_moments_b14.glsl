#[compute]
#version 450

// B-side geometry producer. This is a new field-node -> receiver visibility
// sidecar; it is not the existing probe-origin visibility_moments atlas.
// One 64-lane workgroup owns one node. Each lane writes one 8x8 oct texel.
// The node tag is published only after all 64 complete BVH rays succeed.
layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) readonly buffer VisibilityNodes {
	vec4 nodes[];
} b14_bvh;

layout(set = 0, binding = 1, std430) readonly buffer VisibilityTriangles {
	vec4 triangles[];
} b14_geometry;

struct B14NodeJob {
	ivec4 logical_level; // absolute logical node xyz, clipmap level in w
};
layout(set = 0, binding = 2, std430) readonly buffer NodeJobs {
	B14NodeJob jobs[];
} b14_jobs;

// One RG32F 8x8 oct tile per physical node. XY packs physical node XY and
// angular texel XY; Z packs level and physical node Z.
layout(rg32f, set = 0, binding = 3) uniform writeonly image3D b14_moment_image;

// Per physical node: (logical_x, logical_y, logical_z, positive geometry epoch).
// w==0 is invalid. A current logical coordinate and epoch are both required.
layout(set = 0, binding = 4, std430) buffer NodeMomentTags {
	ivec4 records[];
} b14_tags;

layout(push_constant, std430) uniform B14ProducerParameters {
	ivec4 dispatch; // job_count, resolution, level_count, geometry_epoch
	vec4 level_step; // L0/L1/L2 spacing, ray-range scale (must be >= 3.1)
} b14_config;

shared uint b14_lane_complete[64];

bool b14_finite1(float v) { return !isnan(v) && !isinf(v); }
bool b14_finite3(vec3 v) { return !any(isnan(v)) && !any(isinf(v)); }

int b14_wrap(int value, int resolution) {
	int m = value % resolution;
	return (m + resolution) % resolution;
}

ivec3 b14_physical(ivec3 logical, int resolution) {
	return ivec3(b14_wrap(logical.x, resolution),
		b14_wrap(logical.y, resolution), b14_wrap(logical.z, resolution));
}

int b14_physical_index(ivec3 physical, int level, int resolution) {
	return ((level * resolution + physical.z) * resolution + physical.y)
		* resolution + physical.x;
}

float b14_sign_not_zero(float v) { return v < 0.0 ? -1.0 : 1.0; }

vec3 b14_oct_decode(vec2 uv) {
	vec2 p = uv * 2.0 - 1.0;
	vec3 v = vec3(p, 1.0 - abs(p.x) - abs(p.y));
	if (v.z < 0.0) {
		vec2 old_xy = v.xy;
		v.x = (1.0 - abs(old_xy.y)) * b14_sign_not_zero(old_xy.x);
		v.y = (1.0 - abs(old_xy.x)) * b14_sign_not_zero(old_xy.y);
	}
	float length_squared = dot(v, v);
	if (!(length_squared > 1e-20) || !b14_finite1(length_squared)) {
		return vec3(0.0, 0.0, 1.0);
	}
	return v * inversesqrt(length_squared);
}

bool b14_ray_bounds(vec3 origin, vec3 direction, float limit,
		vec3 lower, vec3 upper, out bool valid) {
	valid = b14_finite3(lower) && b14_finite3(upper)
		&& all(lessThanEqual(lower, upper));
	if (!valid) { return false; }
	float t_min = 1e-5;
	float t_max = limit - 1e-5;
	for (int axis = 0; axis < 3; axis++) {
		if (abs(direction[axis]) < 1e-8) {
			if (origin[axis] < lower[axis] || origin[axis] > upper[axis]) {
				return false;
			}
		} else {
			float a = (lower[axis] - origin[axis]) / direction[axis];
			float b = (upper[axis] - origin[axis]) / direction[axis];
			t_min = max(t_min, min(a, b));
			t_max = min(t_max, max(a, b));
		}
	}
	return t_min <= t_max;
}

bool b14_intersect_triangle(vec3 origin, vec3 direction, float limit,
		int triangle_index, inout float nearest) {
	int base = triangle_index * 3;
	vec4 a_record = b14_geometry.triangles[base];
	vec4 e1_record = b14_geometry.triangles[base + 1];
	vec4 e2_record = b14_geometry.triangles[base + 2];
	if (!b14_finite3(a_record.xyz) || !b14_finite3(e1_record.xyz)
			|| !b14_finite3(e2_record.xyz) || !b14_finite1(a_record.w)
			|| !b14_finite1(e1_record.w) || !b14_finite1(e2_record.w)
			|| e1_record.w < 0.0) {
		return false;
	}
	vec3 p = cross(direction, e2_record.xyz);
	float determinant = dot(e1_record.xyz, p);
	if (!b14_finite1(determinant)) { return false; }
	if (abs(determinant) < e1_record.w) { return true; }
	vec3 from_a = origin - a_record.xyz;
	float u = dot(from_a, p) / determinant;
	vec3 q = cross(from_a, e1_record.xyz);
	float v = dot(direction, q) / determinant;
	float distance = dot(e2_record.xyz, q) / determinant;
	if (!b14_finite1(u) || !b14_finite1(v) || !b14_finite1(distance)) {
		return false;
	}
	if (u >= -1e-6 && v >= -1e-6 && u + v <= 1.000001
			&& distance > 1e-5 && distance < min(nearest, limit)) {
		nearest = distance;
	}
	return true;
}

// Traverses the existing preorder/escape-link BVH to completion. There is no
// 256-node cap: malformed links, non-finite data, or a non-completing walk
// invalidate the entire tile instead of publishing partial moments.
bool b14_trace_first_hit(vec3 origin, vec3 direction, float limit,
		out float distance_out) {
	if (!b14_finite3(origin) || !b14_finite3(direction) || !b14_finite1(limit)
			|| !(limit > 2e-5)) { return false; }
	int node_value_count = b14_bvh.nodes.length();
	int triangle_value_count = b14_geometry.triangles.length();
	if (node_value_count <= 0 || (node_value_count % 2) != 0
			|| triangle_value_count <= 0 || (triangle_value_count % 3) != 0) {
		return false;
	}
	int node_count = node_value_count / 2;
	int triangle_count = triangle_value_count / 3;
	int node = 0;
	float nearest = limit;
	for (int visit = 0; visit < node_count; visit++) {
		if (node == node_count) { break; }
		if (node < 0 || node > node_count - 1) { return false; }
		vec4 lower = b14_bvh.nodes[node * 2];
		vec4 upper = b14_bvh.nodes[node * 2 + 1];
		if (!b14_finite3(lower.xyz) || !b14_finite3(upper.xyz)
				|| any(greaterThan(lower.xyz, upper.xyz))
				|| !b14_finite1(lower.w) || !b14_finite1(upper.w)
				|| lower.w != floor(lower.w) || upper.w != floor(upper.w)
				|| lower.w <= float(node) || lower.w > float(node_count)
				|| upper.w < 0.0
				|| upper.w > float(triangle_count + 1) * 8.0 + 7.0) {
			return false;
		}
		int escape_node = int(lower.w);
		int leaf_range = int(upper.w);
		if (leaf_range > 0) {
			int first = leaf_range / 8 - 1;
			int count = leaf_range % 8;
			if (first < 0 || count <= 0 || first + count > triangle_count) {
				return false;
			}
		}
		bool bounds_valid = false;
		bool hit_bounds = b14_ray_bounds(origin, direction, nearest,
				lower.xyz, upper.xyz, bounds_valid);
		if (!bounds_valid) { return false; }
		if (!hit_bounds) {
			node = escape_node;
			continue;
		}
		if (leaf_range > 0) {
			int first = leaf_range / 8 - 1;
			int count = leaf_range % 8;
			for (int leaf = 0; leaf < count; leaf++) {
				if (!b14_intersect_triangle(origin, direction, limit,
						first + leaf, nearest)) {
					return false;
				}
			}
		}
		node++;
	}
	if (node != node_count || !b14_finite1(nearest)
			|| !(nearest >= 0.0) || nearest > limit) {
		return false;
	}
	distance_out = nearest;
	return true;
}

void main() {
	uint job_index = gl_WorkGroupID.x;
	if (b14_config.dispatch.x <= 0 || job_index >= uint(b14_config.dispatch.x)) { return; }
	int resolution = b14_config.dispatch.y;
	int level_count = b14_config.dispatch.z;
	int geometry_epoch = b14_config.dispatch.w;
	if (resolution <= 0 || resolution > 256 || level_count <= 0 || level_count > 3
			|| geometry_epoch <= 0 || int(job_index) >= b14_jobs.jobs.length()) { return; }
	ivec4 job = b14_jobs.jobs[int(job_index)].logical_level;
	int level = job.w;
	if (level < 0 || level >= level_count || level >= 3) { return; }
	float step_size = b14_config.level_step[level];
	float range_scale = b14_config.level_step.w;
	if (!(step_size > 0.0) || !b14_finite1(step_size)
			|| !(range_scale >= 3.1) || !b14_finite1(range_scale)) { return; }
	float max_distance = step_size * range_scale;
	if (!b14_finite1(max_distance) || !(max_distance > 0.0)) { return; }
	ivec3 physical = b14_physical(job.xyz, resolution);
	int physical_index = b14_physical_index(physical, level, resolution);
	ivec3 output_size = imageSize(b14_moment_image);
	if (any(lessThan(output_size, ivec3(resolution * 8, resolution * 8,
			level_count * resolution))) || physical_index < 0
			|| physical_index >= b14_tags.records.length()) { return; }
	uint lane = gl_LocalInvocationID.x;
	if (lane == 0u) {
		// Clear publication before this job writes any data. Consumers run only
		// after the dispatch boundary and must match both logical xyz and epoch.
		b14_tags.records[physical_index] = ivec4(0);
	}
	barrier();
	int texel_x = int(lane & 7u);
	int texel_y = int(lane >> 3u);
	vec3 direction = b14_oct_decode((vec2(texel_x, texel_y) + vec2(0.5)) / 8.0);
	float distance = 0.0;
	bool complete = b14_trace_first_hit((vec3(job.xyz) + vec3(0.5)) * step_size,
		direction, max_distance, distance);
	vec2 moments = complete ? vec2(distance, distance * distance) : vec2(0.0);
	complete = complete && b14_finite1(moments.x) && b14_finite1(moments.y)
		&& moments.x >= 0.0 && moments.y >= 0.0;
	ivec3 image_coord = ivec3(physical.xy * 8 + ivec2(texel_x, texel_y),
		level * resolution + physical.z);
	imageStore(b14_moment_image, image_coord, vec4(moments, 0.0, 0.0));
	b14_lane_complete[lane] = complete ? 1u : 0u;
	memoryBarrierImage();
	barrier();
	if (lane == 0u) {
		bool tile_complete = true;
		for (int ray = 0; ray < 64; ray++) {
			tile_complete = tile_complete && b14_lane_complete[ray] != 0u;
		}
		if (tile_complete) {
			b14_tags.records[physical_index] = ivec4(job.xyz, geometry_epoch);
		}
		memoryBarrierBuffer();
	}
}
