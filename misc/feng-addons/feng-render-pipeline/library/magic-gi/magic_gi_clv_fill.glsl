#[compute]
#version 450
// CLV ABI 8: cache diffuse projection and geometry-only interpolation stencils.
#define MAGIC_GI_WIDE_CANDIDATE_POOL_LIMIT 16
#define MAGIC_GI_WIDE_VISIBLE_PROBE_LIMIT 8
layout(local_size_x = 64) in;
layout(set = 0, binding = 0) uniform sampler2D geometry_atlas;
layout(set = 0, binding = 1) uniform isampler2D index_map;
layout(set = 0, binding = 2, std430) readonly buffer VisibilityNodes { vec4 nodes[]; } visibility_bvh;
layout(set = 0, binding = 3, std430) readonly buffer VisibilityTriangles { vec4 triangles[]; } visibility_geometry;
layout(set = 0, binding = 4, std430) readonly buffer Lighting { vec4 values[]; } directional_lighting;
layout(set = 0, binding = 5, std430) readonly buffer Jobs { ivec4 cells[]; } jobs;
layout(rgba32f, set = 0, binding = 6) uniform image3D cache_image;
layout(rgba32i, set = 0, binding = 7) uniform iimage3D cache_tags;
layout(r32ui, set = 0, binding = 11) uniform writeonly uimage3D support_image;
layout(set = 0, binding = 8, std140) uniform GIParams {
	mat4 inverse_projection; mat4 world_to_grid; mat4 view_to_world;
	vec4 grid; vec4 control; vec4 lighting_sh[7]; vec4 sky_lighting_sh[7];
} params;
layout(push_constant, std430) uniform FillParameters {
	int jobs; int resolution; int epoch; float base_spacing;
} config;
#include "magic_gi_visibility.glslinc"
#include "magic_gi_clv_layout.glslinc"
#define MAGIC_INDEX_BINDING 9
#define MAGIC_CLUSTER_BINDING 10
#include "magic_gi_index.glslinc"
#include "magic_gi_probe_clusters.glslinc"
#define LOOKUP_CELL_RADIUS 2
#define probe_lighting directional_lighting
vec2 sample_visibility_moments(int probe, vec3 direction) { return vec2(0.0); }
float chebyshev_visibility(vec2 moments, float distance, float variance) { return 0.0; }
#include "magic_gi_sh.glslinc"
#include "magic_gi_clv_stencil.glslinc"
#include "magic_gi_gather.glslinc"

// Find the nearest front-facing receiver triangle, not merely the nearest
// two-sided hit. A closer backface must not hide a farther usable face slot.
vec3 clv_nearest_front_surface(vec3 ray_end, vec3 direction, float radius,
		out int receiver_triangle) {
	vec3 origin = ray_end - direction * radius;
	vec3 inverse_direction = 1.0 / mix(direction, vec3(1.0),
			lessThan(abs(direction), vec3(1e-8)));
	float nearest = radius * 2.0;
	vec3 resolved = ray_end;
	receiver_triangle = -1;
	int node_value_count = visibility_bvh.nodes.length();
	int triangle_value_count = visibility_geometry.triangles.length();
	if (node_value_count <= 0 || (node_value_count % 2) != 0
			|| triangle_value_count <= 0 || (triangle_value_count % 3) != 0) {
		receiver_triangle = -2;
		return ray_end;
	}
	int node_count = node_value_count / 2;
	int triangle_count = triangle_value_count / 3;
	int node = 0;
	for (int visit = 0; visit < 256 && node < node_count; visit++) {
		vec4 lower = visibility_bvh.nodes[node * 2];
		vec4 upper = visibility_bvh.nodes[node * 2 + 1];
		if (!visibility_finite_vec3(lower.xyz) || !visibility_finite_vec3(upper.xyz)
				|| any(greaterThan(lower.xyz, upper.xyz)) || isnan(lower.w) || isinf(lower.w)
				|| isnan(upper.w) || isinf(upper.w) || lower.w <= float(node)
				|| lower.w > float(node_count) || floor(lower.w) != lower.w
				|| upper.w < 0.0 || floor(upper.w) != upper.w) {
			receiver_triangle = -2;
			return ray_end;
		}
		if (!segment_hits_bounds(origin, direction, inverse_direction, nearest,
				lower.xyz, upper.xyz)) {
			node = int(lower.w);
			continue;
		}
		int leaf_range = int(upper.w);
		if (leaf_range > 0) {
			int first = leaf_range / 8 - 1;
			int count = leaf_range % 8;
			if (first < 0 || count <= 0 || first + count > triangle_count) {
				receiver_triangle = -2;
				return ray_end;
			}
			for (int leaf = 0; leaf < count; leaf++) {
				int triangle = (first + leaf) * 3;
				vec4 a_record = visibility_geometry.triangles[triangle];
				vec4 edge1_record = visibility_geometry.triangles[triangle + 1];
				vec4 edge2_record = visibility_geometry.triangles[triangle + 2];
				vec3 a = a_record.xyz;
				vec3 edge1 = edge1_record.xyz;
				vec3 edge2 = edge2_record.xyz;
				float patch_value = edge2_record.w;
				float determinant_epsilon = edge1_record.w;
				if (!visibility_finite_vec3(a) || !visibility_finite_vec3(edge1)
						|| !visibility_finite_vec3(edge2) || isnan(patch_value)
						|| isinf(patch_value) || abs(patch_value) > 2147480000.0
						|| floor(patch_value) != patch_value || isnan(determinant_epsilon)
						|| isinf(determinant_epsilon) || determinant_epsilon < 0.0) {
					receiver_triangle = -2;
					return ray_end;
				}
				vec3 geometric_normal = cross(edge2, edge1);
				float normal_length_squared = dot(geometric_normal, geometric_normal);
				if (!visibility_finite_vec3(geometric_normal)
						|| isnan(normal_length_squared) || isinf(normal_length_squared)) {
					receiver_triangle = -2;
					return ray_end;
				}
				// A degenerate triangle cannot be a receiver. It is safe to ignore it
				// while continuing the bounded search for farther usable faces.
				if (!(normal_length_squared > 1e-12)) { continue; }
				vec3 p = cross(direction, edge2);
				float determinant = dot(edge1, p);
				if (abs(determinant) < determinant_epsilon) { continue; }
				vec3 from_a = origin - a;
				float u = dot(from_a, p) / determinant;
				vec3 q = cross(from_a, edge1);
				float v = dot(direction, q) / determinant;
				float distance = dot(edge2, q) / determinant;
				if (u < -1e-6 || v < -1e-6 || u + v > 1.000001
						|| !(distance > 0.00001) || !(distance < nearest)
						|| isnan(distance) || isinf(distance)) {
					continue;
				}
				vec3 found = a + edge1 * u + edge2 * v;
				float receiver_side = dot(origin - found,
						geometric_normal * inversesqrt(normal_length_squared));
				if (!visibility_finite_vec3(found) || isnan(receiver_side)
						|| isinf(receiver_side) || receiver_side < -1e-5) {
					continue;
				}
				nearest = distance;
				resolved = found;
				receiver_triangle = first + leaf;
			}
		}
		node++;
	}
	if (node < node_count) { receiver_triangle = -2; }
	return resolved;
}

void main() {
	uint index = gl_GlobalInvocationID.x;
	if (index >= uint(config.jobs)) { return; }
	ivec4 job = jobs.cells[index];
	float step_size = config.base_spacing * float(1 << job.w);
	float search_spacing = max(params.control.y, step_size);
	vec3 world = (vec3(job.xyz) + 0.5) * step_size;
	ivec3 slot = ((job.xyz % config.resolution) + config.resolution) % config.resolution;
	slot.z += job.w * config.resolution;
	ivec4 previous_tag = imageLoad(cache_tags, slot);
	bool reuse_geometry = all(equal(previous_tag.xyz, job.xyz)) && previous_tag.w == config.epoch;
	if (!reuse_geometry) { imageStore(support_image, slot, uvec4(0u)); }
	vec3 grid_position = (params.world_to_grid * vec4(world, 1.0)).xyz;
	vec3 grid_dimensions = params.grid.xyz;
	bool grid_dimensions_valid = visibility_finite_vec3(grid_dimensions)
			&& all(greaterThan(grid_dimensions, vec3(0.0)))
			&& all(lessThan(grid_dimensions, vec3(2147480000.0)))
			&& all(equal(floor(grid_dimensions), grid_dimensions));
	bool grid_position_valid = visibility_finite_vec3(grid_position);
	vec3 grid_cell = grid_position_valid ? floor(grid_position) : vec3(-1.0);
	bool inside_probe_grid = grid_dimensions_valid && grid_position_valid
			&& all(greaterThanEqual(grid_cell, vec3(0.0)))
			&& all(lessThan(grid_cell, grid_dimensions));
	if (!inside_probe_grid) {
		// The old path would emit six empty nearest-surface searches and publish the
		// same invalid metadata. Clear it directly, preserving the cell tag.
		vec3 invalid_anchor = visibility_finite_vec3(world) ? world : vec3(0.0);
		for (int axis = 0; axis < CLV_FACE_SLOT_COUNT; axis++) {
			for (int k = 0; k < CLV_FACE_RADIANCE_COLUMNS; k++) {
				int column = clv_face_column(axis, k);
				imageStore(cache_image, slot + ivec3(column * config.resolution, 0, 0), vec4(0.0));
			}
			int metadata_column = clv_face_column(axis, CLV_FACE_METADATA_COLUMN);
			int anchor_column = clv_face_column(axis, CLV_FACE_ANCHOR_COLUMN);
			imageStore(cache_image, slot + ivec3(metadata_column * config.resolution, 0, 0),
					vec4(0.0, 0.0, 0.0, -1.0));
			imageStore(cache_image, slot + ivec3(anchor_column * config.resolution, 0, 0),
					vec4(invalid_anchor, 0.0));
			for (int k = 0; k < 2; k++) {
				imageStore(cache_image, slot + ivec3(clv_face_column(axis,
						CLV_FACE_DIFFUSE_COLUMN + k) * config.resolution, 0, 0), vec4(0.0));
			}
		}
		imageStore(cache_tags, slot, ivec4(job.xyz, config.epoch));
		return;
	}
	float nearest_distance[CLV_FACE_SLOT_COUNT];
	int nearest_triangle[CLV_FACE_SLOT_COUNT];
	vec3 face_surface[CLV_FACE_SLOT_COUNT];
	vec3 face_normal[CLV_FACE_SLOT_COUNT];
	bool face_certificate[CLV_FACE_SLOT_COUNT];
	for (int axis = 0; axis < CLV_FACE_SLOT_COUNT; axis++) {
		nearest_distance[axis] = search_spacing * 3.0;
		nearest_triangle[axis] = -1;
		face_surface[axis] = world;
		face_normal[axis] = vec3(0.0);
		face_certificate[axis] = false;
		if (reuse_geometry) {
			vec4 metadata = imageLoad(cache_image,
					slot + ivec3(clv_face_column(axis, CLV_FACE_METADATA_COLUMN) * config.resolution, 0, 0));
			vec4 anchor = imageLoad(cache_image,
					slot + ivec3(clv_face_column(axis, CLV_FACE_ANCHOR_COLUMN) * config.resolution, 0, 0));
			float id = abs(anchor.w);
			if (metadata.w > 0.0 && id >= 1.0 && floor(id) == id
					&& id <= float(visibility_geometry.triangles.length() / 3)) {
				nearest_triangle[axis] = int(id) - 1;
				face_surface[axis] = anchor.xyz;
				face_normal[axis] = metadata.xyz;
				face_certificate[axis] = anchor.w > 0.0;
			}
		}
	}
	bool complete_search = true;
	// Each axis-aligned receiver family gets its own nearest legal surface.
	// Validate front-side ownership before comparing distance so a closer backside
	// hit cannot hide a farther usable receiver face.
	for (int ray = 0; !reuse_geometry && ray < 6; ray++) {
		vec3 direction = vec3(0.0); direction[ray / 2] = (ray % 2) == 0 ? 1.0 : -1.0;
		int triangle;
		float half_distance = search_spacing * 1.5;
		vec3 found = clv_nearest_front_surface(world + direction * half_distance,
				direction, half_distance, triangle);
		if (triangle == -2) { complete_search = false; break; }
		if (triangle < 0) { continue; }
		if (triangle * 3 + 2 >= visibility_geometry.triangles.length()
				|| !all(not(isnan(found))) || !all(not(isinf(found)))) {
			complete_search = false;
			break;
		}
		vec3 edge1 = visibility_geometry.triangles[triangle * 3 + 1].xyz;
		vec3 edge2 = visibility_geometry.triangles[triangle * 3 + 2].xyz;
		vec3 unnormalized_normal = cross(edge2, edge1);
		float normal_length_squared = dot(unnormalized_normal, unnormalized_normal);
		float patch_value = visibility_geometry.triangles[triangle * 3 + 2].w;
		if (!all(not(isnan(edge1))) || !all(not(isinf(edge1)))
				|| !all(not(isnan(edge2))) || !all(not(isinf(edge2)))
				|| !all(not(isnan(unnormalized_normal))) || !all(not(isinf(unnormalized_normal)))
				|| !(normal_length_squared > 1e-12) || isnan(normal_length_squared)
				|| isinf(normal_length_squared) || isnan(patch_value) || isinf(patch_value)
				|| abs(patch_value) > 2147480000.0 || floor(patch_value) != patch_value) {
			complete_search = false;
			break;
		}
		vec3 normal = unnormalized_normal * inversesqrt(normal_length_squared);
		float receiver_side = dot(world - found, normal);
		if (!all(not(isnan(normal))) || !all(not(isinf(normal)))
				|| isnan(receiver_side) || isinf(receiver_side)) {
			complete_search = false;
			break;
		}
		if (receiver_side < -0.00001) { continue; }
		int axis = clv_dominant_absolute_normal_axis(normal);
		float distance = length(found - world);
		if (isnan(distance) || isinf(distance)) {
			complete_search = false;
			break;
		}
		if (distance < nearest_distance[axis]) {
			nearest_distance[axis] = distance;
			nearest_triangle[axis] = triangle;
			face_surface[axis] = found;
			face_normal[axis] = normal;
		}
	}
	for (int axis = 0; axis < CLV_FACE_SLOT_COUNT; axis++) {
		vec4 coefficients[CLV_FACE_RADIANCE_COLUMNS];
		for (int k = 0; k < CLV_FACE_RADIANCE_COLUMNS; k++) { coefficients[k] = vec4(0.0); }
		vec3 normal = face_normal[axis];
		vec3 surface = face_surface[axis];
		int triangle = nearest_triangle[axis];
		int surface_patch = -1;
		float candidate_weight = 0.0;
		float visible_support_weight = 0.0;
		bool has_candidate = complete_search && triangle >= 0;
		clv_stencil_reset(slot, axis);
		if (has_candidate) {
			surface_patch = int(visibility_geometry.triangles[triangle * 3 + 2].w);
			if (!reuse_geometry || !clv_stencil_relight(coefficients, candidate_weight, visible_support_weight)) {
				gather_probe_field(surface, normal, triangle, true, true, coefficients,
						candidate_weight, visible_support_weight, false);
				clv_stencil_publish(coefficients[0].w, candidate_weight, visible_support_weight);
			}
		}
		bool supported = has_candidate && visible_support_weight > 1e-10;
		if (!supported) {
			for (int k = 0; k < CLV_FACE_RADIANCE_COLUMNS; k++) { coefficients[k] = vec4(0.0); }
			normal = vec3(0.0);
			surface_patch = -1;
			surface = world;
		}
		float box_margin = max(1e-5, max(step_size, max(max(abs(world.x), abs(world.y)), abs(world.z)))
				* 1.9073486328125e-6);
		float plane_tolerance = max(1e-5, step_size * 1e-4) + box_margin;
		bool certificate = reuse_geometry ? face_certificate[axis] : supported && surface_patch > 0
				&& clv_surface_box_certificate_clear(world, 1.75 * step_size,
					surface, normal, surface_patch, plane_tolerance, box_margin);
		for (int k = 0; k < CLV_FACE_RADIANCE_COLUMNS; k++) {
			int column = clv_face_column(axis, k);
			imageStore(cache_image, slot + ivec3(column * config.resolution, 0, 0), coefficients[k]);
		}
		float basis[9];
		diffuse_basis(normal, basis);
		vec3 secondary_diffuse = vec3(0.0);
		vec3 primary_diffuse = vec3(0.0);
		for (int k = 0; k < 9; k++) {
			secondary_diffuse += coefficients[k].rgb * basis[k];
			primary_diffuse += coefficients[k + 9].rgb * basis[k];
		}
		// Clamp after interpolation in the consumer, preserving signed SH lobes.
		imageStore(cache_image, slot + ivec3(clv_face_column(axis,
				CLV_FACE_DIFFUSE_COLUMN) * config.resolution, 0, 0), vec4(secondary_diffuse, 0.0));
		imageStore(cache_image, slot + ivec3(clv_face_column(axis,
				CLV_FACE_DIFFUSE_COLUMN + 1) * config.resolution, 0, 0), vec4(primary_diffuse, 0.0));
		int metadata_column = clv_face_column(axis, CLV_FACE_METADATA_COLUMN);
		int anchor_column = clv_face_column(axis, CLV_FACE_ANCHOR_COLUMN);
		// W = -1 means no visibility-supported reconstruction; supported black
		// surfaces remain valid, and each face has an independent anchor/certificate.
		imageStore(cache_image, slot + ivec3(metadata_column * config.resolution, 0, 0),
				vec4(normal, visible_support_weight > 1e-10 ? float(surface_patch) : -1.0));
		// Signed triangle identity: positive certifies the visibility box;
		// negative is a surface hint only, and zero has no supported receiver.
		imageStore(cache_image, slot + ivec3(anchor_column * config.resolution, 0, 0),
				vec4(surface, supported && triangle < 16777215
						? float(triangle + 1) * (certificate ? 1.0 : -1.0) : 0.0));
	}
	imageStore(cache_tags, slot, ivec4(job.xyz, config.epoch));
}
