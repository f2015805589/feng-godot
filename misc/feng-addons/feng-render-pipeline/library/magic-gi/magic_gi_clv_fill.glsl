#[compute]
#version 450
#define MAGIC_GI_WIDE_CANDIDATE_POOL_LIMIT 16
#define MAGIC_GI_WIDE_VISIBLE_PROBE_LIMIT 8
layout(local_size_x = 64) in;
layout(set = 0, binding = 0) uniform sampler2D geometry_atlas;
layout(set = 0, binding = 1) uniform isampler2D index_map;
layout(set = 0, binding = 2, std430) readonly buffer VisibilityNodes { vec4 nodes[]; } visibility_bvh;
layout(set = 0, binding = 3, std430) readonly buffer VisibilityTriangles { vec4 triangles[]; } visibility_geometry;
layout(set = 0, binding = 4, std430) readonly buffer Lighting { vec4 values[]; } directional_lighting;
layout(set = 0, binding = 5, std430) readonly buffer Jobs { ivec4 cells[]; } jobs;
layout(rgba32f, set = 0, binding = 6) uniform writeonly image3D cache_image;
layout(rgba32i, set = 0, binding = 7) uniform writeonly iimage3D cache_tags;
layout(set = 0, binding = 8, std140) uniform GIParams {
	mat4 inverse_projection; mat4 world_to_grid; mat4 view_to_world;
	vec4 grid; vec4 control; vec4 lighting_sh[7]; vec4 sky_lighting_sh[7];
} params;
layout(push_constant, std430) uniform FillParameters {
	int jobs; int resolution; int epoch; float base_spacing;
} config;
#include "magic_gi_visibility.glslinc"
#define MAGIC_INDEX_BINDING 9
#include "magic_gi_index.glslinc"
#define LOOKUP_CELL_RADIUS 2
#define probe_lighting directional_lighting
vec2 sample_visibility_moments(int probe, vec3 direction) { return vec2(0.0); }
float chebyshev_visibility(vec2 moments, float distance, float variance) { return 0.0; }
#include "magic_gi_sh.glslinc"
#include "magic_gi_gather.glslinc"

void main() {
	uint index = gl_GlobalInvocationID.x;
	if (index >= uint(config.jobs)) { return; }
	ivec4 job = jobs.cells[index];
	float step_size = config.base_spacing * float(1 << job.w);
	vec3 world = (vec3(job.xyz) + 0.5) * step_size;
	ivec3 slot = ((job.xyz % config.resolution) + config.resolution) % config.resolution;
	slot.z += job.w * config.resolution;
	vec4 coefficients[18];
	for (int k = 0; k < 18; k++) { coefficients[k] = vec4(0.0); }
	vec3 grid_position = (params.world_to_grid * vec4(world, 1.0)).xyz;
	ivec3 dims = ivec3(params.grid.xyz);
	ivec3 center = ivec3(floor(grid_position));
	float nearest_distance = params.control.y * 3.0;
	int nearest_triangle = -1;
	vec3 surface = world;
	// Identify the closest axis intersection for a conservative interpolation
	// domain. Different connected patches are never interpolated together.
	for (int ray = 0; ray < 6; ray++) {
		vec3 direction = vec3(0.0); direction[ray / 2] = (ray % 2) == 0 ? 1.0 : -1.0;
		int triangle;
		float half_distance = params.control.y * 1.5;
		vec3 found = nearest_surface(world + direction * half_distance, direction, half_distance, -1, triangle);
		float distance = length(found - world);
		if (triangle == -2) { nearest_triangle = -2; break; }
		if (triangle >= 0 && distance < nearest_distance) {
			nearest_distance = distance; nearest_triangle = triangle; surface = found;
		}
	}
	vec3 normal = vec3(0.0);
	int surface_patch = 0;
	bool valid = nearest_triangle != -2;
	if (nearest_triangle >= 0) {
		vec3 edge1 = visibility_geometry.triangles[nearest_triangle * 3 + 1].xyz;
		vec3 edge2 = visibility_geometry.triangles[nearest_triangle * 3 + 2].xyz;
		normal = normalize(cross(edge2, edge1));
		surface_patch = int(visibility_geometry.triangles[nearest_triangle * 3 + 2].w);
		valid = dot(world - surface, normal) >= -0.00001;
	}
	float candidate_weight = 0.0;
	float visible_support_weight = 0.0;
	if (valid && nearest_triangle >= 0 && all(greaterThanEqual(center, ivec3(0))) && all(lessThan(center, dims))) {
		gather_probe_field(surface, normal, nearest_triangle, true, true, coefficients,
				candidate_weight, visible_support_weight);
	}
	for (int k = 0; k < 18; k++) {
		imageStore(cache_image, slot + ivec3(k * config.resolution, 0, 0), coefficients[k]);
	}
	// W = -1 means no visibility-supported reconstruction; 0 denotes free space,
	// and a positive value identifies a surface patch. Zero-radiance supported
	// surfaces remain valid CLV interpolation cells.
	imageStore(cache_image, slot + ivec3(18 * config.resolution, 0, 0),
			vec4(normal, visible_support_weight > 1e-10 ? float(surface_patch) : -1.0));
	imageStore(cache_tags, slot, ivec4(job.xyz, config.epoch));
}
