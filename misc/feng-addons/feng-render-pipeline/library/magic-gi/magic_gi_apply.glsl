#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D depth_buffer;
layout(set = 0, binding = 2) uniform sampler2D normal_roughness;
layout(set = 0, binding = 3) uniform sampler2D gbuffer_albedo;
layout(set = 0, binding = 4) uniform sampler2D gbuffer_orm;
layout(rgba16f, set = 0, binding = 5) uniform writeonly image2D gi_output;
layout(set = 0, binding = 6) uniform sampler2D transfer_atlas;
layout(set = 0, binding = 7) uniform sampler2D geometry_atlas;
layout(set = 0, binding = 8) uniform isampler2D index_map;
layout(set = 0, binding = 10) uniform sampler2D emission_atlas;
layout(set = 0, binding = 11) uniform sampler2D primary_sky_atlas;
layout(set = 0, binding = 12) uniform sampler2D sky_light_diffuse_buffer;
layout(set = 0, binding = 13) uniform sampler2D visibility_moment_atlas;
layout(set = 0, binding = 14, std430) readonly buffer VisibilityNodes {
	vec4 nodes[]; // min.xyz / escape index, max.xyz / packed leaf range.
} visibility_bvh;
layout(set = 0, binding = 15, std430) readonly buffer VisibilityTriangles {
	vec4 triangles[]; // vertex, edge1, edge2; two-sided opaque blockers.
} visibility_geometry;

layout(set = 0, binding = 9, std140) uniform GIParams {
	mat4 inverse_projection;
	mat4 world_to_grid;
	mat4 view_to_world;
	vec4 grid; // xyz = lookup grid dimensions; w = surface sample count.
	vec4 control; // x = strength; y = probe spacing; z = SkyLight replacement; w = static BVH available.
	vec4 lighting_sh[7]; // 27 combined SkyLight + Directional SH floats for secondary transport.
	vec4 sky_lighting_sh[7]; // 27 SkyLight-only SH floats for primary v4 transport.
} params;

layout(push_constant, std430) uniform PassParameters {
	vec4 parameters;
} pc;

vec3 unpack_sh(vec4 blocks[7], int coefficient) {
	int first = coefficient * 3;
	int block0 = first / 4;
	int lane0 = first % 4;
	int second = first + 1;
	int third = first + 2;
	return vec3(
		blocks[block0][lane0],
		blocks[second / 4][second % 4],
		blocks[third / 4][third % 4]
	);
}

vec3 evaluate_probe(int probe) {
	vec4 transfer_blocks[7];
	int atlas_x = (probe % 32) * 7;
	int atlas_y = probe / 32;
	for (int texel = 0; texel < 7; texel++) {
		transfer_blocks[texel] = texelFetch(transfer_atlas, ivec2(atlas_x + texel, atlas_y), 0);
	}
	vec3 value = vec3(0.0);
	for (int coefficient = 0; coefficient < 9; coefficient++) {
		value += unpack_sh(transfer_blocks, coefficient)
				* unpack_sh(params.lighting_sh, coefficient);
	}
	if (params.control.z > 0.5) {
		vec4 primary_blocks[3];
		int primary_x = (probe % 32) * 3;
		for (int texel = 0; texel < 3; texel++) {
			primary_blocks[texel] = texelFetch(primary_sky_atlas, ivec2(primary_x + texel, atlas_y), 0);
		}
		for (int coefficient = 0; coefficient < 9; coefficient++) {
			int block = coefficient / 4;
			int lane = coefficient % 4;
			// Primary transport stores irradiance; Lambert's BRDF is albedo / PI.
			// Secondary transport already cancels that factor against its cosine PDF.
			value += primary_blocks[block][lane] * 0.3183098861837907
					* unpack_sh(params.sky_lighting_sh, coefficient);
		}
	}
	vec3 emission = texelFetch(emission_atlas, ivec2(probe % 32, probe / 32), 0).rgb;
	return max(value, vec3(0.0)) + max(emission, vec3(0.0));
}

float sign_not_zero(float value) {
	return value < 0.0 ? -1.0 : 1.0;
}

vec2 octahedral_encode(vec3 direction) {
	vec3 unit_direction = normalize(direction);
	float denominator = abs(unit_direction.x) + abs(unit_direction.y) + abs(unit_direction.z);
	vec2 p = unit_direction.xy / max(denominator, 1e-7);
	if (unit_direction.z < 0.0) {
		p = (1.0 - abs(p.yx)) * vec2(sign_not_zero(p.x), sign_not_zero(p.y));
	}
	return p * 0.5 + 0.5;
}

ivec2 fold_visibility_texel(ivec2 texel) {
	const int tile_size = 8;
	for (int iteration = 0; iteration < 4; iteration++) {
		if (texel.x < 0) {
			texel = ivec2(-texel.x - 1, tile_size - 1 - texel.y);
		} else if (texel.x >= tile_size) {
			texel = ivec2(tile_size * 2 - 1 - texel.x, tile_size - 1 - texel.y);
		}
		if (texel.y < 0) {
			texel = ivec2(tile_size - 1 - texel.x, -texel.y - 1);
		} else if (texel.y >= tile_size) {
			texel = ivec2(tile_size - 1 - texel.x, tile_size * 2 - 1 - texel.y);
		}
		if (all(greaterThanEqual(texel, ivec2(0)))
				&& all(lessThan(texel, ivec2(tile_size)))) {
			return texel;
		}
	}
	return clamp(texel, ivec2(0), ivec2(tile_size - 1));
}

vec2 fetch_visibility_moments(int probe, ivec2 tile_texel) {
	ivec2 folded = fold_visibility_texel(tile_texel);
	ivec2 tile_origin = ivec2((probe % 32) * 8, (probe / 32) * 8);
	return texelFetch(visibility_moment_atlas, tile_origin + folded, 0).rg;
}

vec2 sample_visibility_moments(int probe, vec3 direction) {
	vec2 texel_position = octahedral_encode(direction) * 8.0 - 0.5;
	ivec2 base = ivec2(floor(texel_position));
	vec2 fraction = texel_position - vec2(base);
	vec2 moments = vec2(0.0);
	for (int y = 0; y < 2; y++) {
		for (int x = 0; x < 2; x++) {
			float weight = (x == 1 ? fraction.x : 1.0 - fraction.x)
					* (y == 1 ? fraction.y : 1.0 - fraction.y);
			moments += fetch_visibility_moments(probe, base + ivec2(x, y)) * weight;
		}
	}
	return moments;
}

float chebyshev_visibility(vec2 moments, float receiver_distance, float variance_floor) {
	float mean_distance = max(moments.x, 0.0);
	float delta = receiver_distance - mean_distance;
	if (delta <= 0.0) {
		return 1.0;
	}
	float variance = max(max(moments.y - mean_distance * mean_distance, 0.0), variance_floor);
	float delta_squared = delta * delta;
	float denominator = variance + delta_squared;
	if (isnan(denominator) || isinf(denominator) || denominator <= 0.0) {
		return 0.0;
	}
	float bound = clamp(variance / denominator, 0.0, 1.0);
	return bound * bound;
}

ivec2 index_texel(ivec3 cell, int slot, ivec3 dimensions) {
	return ivec2(cell.x * 8 + slot, cell.y + cell.z * dimensions.y);
}

bool segment_hits_bounds(vec3 origin, vec3 direction, vec3 inverse_direction, float distance, vec3 lower, vec3 upper) {
	float near_distance = 0.00001;
	float far_distance = distance - 0.00001;
	for (int axis = 0; axis < 3; axis++) {
		if (abs(direction[axis]) < 1e-8) {
			if (origin[axis] < lower[axis] - 0.00001 || origin[axis] > upper[axis] + 0.00001) {
				return false;
			}
		} else {
			float a = (lower[axis] - 0.00001 - origin[axis]) * inverse_direction[axis];
			float b = (upper[axis] + 0.00001 - origin[axis]) * inverse_direction[axis];
			near_distance = max(near_distance, min(a, b));
			far_distance = min(far_distance, max(a, b));
		}
	}
	return near_distance <= far_distance;
}

vec3 nearest_surface(vec3 world, vec3 view_direction, float radius, int ignored_triangle, out int receiver_triangle) {
	vec3 origin = world - view_direction * radius;
	vec3 inverse_direction = 1.0 / mix(view_direction, vec3(1.0), lessThan(abs(view_direction), vec3(1e-8)));
	float nearest = radius * 2.0;
	vec3 resolved = world;
	receiver_triangle = -1;
	int node_count = visibility_bvh.nodes.length() / 2;
	int node = 0;
	for (int visit = 0; visit < 256 && node < node_count; visit++) {
		vec4 lower = visibility_bvh.nodes[node * 2];
		vec4 upper = visibility_bvh.nodes[node * 2 + 1];
		if (!segment_hits_bounds(origin, view_direction, inverse_direction, nearest, lower.xyz, upper.xyz)) {
			node = int(lower.w);
			continue;
		}
		int leaf_range = int(upper.w);
		if (leaf_range > 0) {
			int first = leaf_range / 8 - 1;
			int count = leaf_range % 8;
			for (int leaf = 0; leaf < count; leaf++) {
				if (first + leaf == ignored_triangle) {
					continue;
				}
				int triangle = (first + leaf) * 3;
				vec3 a = visibility_geometry.triangles[triangle].xyz;
				vec3 edge1 = visibility_geometry.triangles[triangle + 1].xyz;
				vec3 edge2 = visibility_geometry.triangles[triangle + 2].xyz;
				vec3 p = cross(view_direction, edge2);
				float determinant = dot(edge1, p);
				if (abs(determinant) < visibility_geometry.triangles[triangle + 1].w) {
					continue;
				}
				vec3 from_a = origin - a;
				float u = dot(from_a, p) / determinant;
				vec3 q = cross(from_a, edge1);
				float v = dot(view_direction, q) / determinant;
				float distance = dot(edge2, q) / determinant;
				if (u >= -1e-6 && v >= -1e-6 && u + v <= 1.000001
						&& distance > 0.00001 && distance < nearest) {
					nearest = distance;
					resolved = a + edge1 * u + edge2 * v;
					receiver_triangle = first + leaf;
				}
			}
		}
		node++;
	}
	if (node < node_count) {
		receiver_triangle = -2;
		return world; // An incomplete search cannot identify the receiving face.
	}
	return resolved;
}

bool segment_blocked(vec3 origin, vec3 target, int receiver_triangle, int receiver_patch) {
	vec3 delta = target - origin;
	float distance = length(delta);
	if (distance <= 0.00002) {
		return false;
	}
	vec3 direction = delta / distance;
	vec3 inverse_direction = 1.0 / mix(direction, vec3(1.0), lessThan(abs(direction), vec3(1e-8)));
	int node_count = visibility_bvh.nodes.length() / 2;
	int node = 0;
	// Keep work bounded on very dense geometry. Exhaustion rejects the candidate;
	// neither an incomplete traversal nor an averaged moment can grant visibility.
	for (int visit = 0; visit < 256 && node < node_count; visit++) {
		vec4 lower = visibility_bvh.nodes[node * 2];
		vec4 upper = visibility_bvh.nodes[node * 2 + 1];
		if (!segment_hits_bounds(origin, direction, inverse_direction, distance, lower.xyz, upper.xyz)) {
			node = int(lower.w);
			continue;
		}
		int leaf_range = int(upper.w);
		if (leaf_range > 0) {
			int first = leaf_range / 8 - 1;
			int count = leaf_range % 8;
			for (int leaf = 0; leaf < count; leaf++) {
				if (first + leaf == receiver_triangle) {
					continue;
				}
				int triangle = (first + leaf) * 3;
				if (receiver_patch > 0 && int(visibility_geometry.triangles[triangle + 2].w) == receiver_patch) {
					continue;
				}
				vec3 a = visibility_geometry.triangles[triangle].xyz;
				vec3 edge1 = visibility_geometry.triangles[triangle + 1].xyz;
				vec3 edge2 = visibility_geometry.triangles[triangle + 2].xyz;
				vec3 p = cross(direction, edge2);
				float determinant = dot(edge1, p);
				if (abs(determinant) < visibility_geometry.triangles[triangle + 1].w) {
					continue;
				}
				vec3 from_a = origin - a;
				float u = dot(from_a, p) / determinant;
				vec3 q = cross(from_a, edge1);
				float v = dot(direction, q) / determinant;
				float hit_distance = dot(edge2, q) / determinant;
				// Exclude the receiver's own plane in normal distance, so grazing
				// rays do not amplify depth reconstruction error into false blockers.
				if (abs(distance - hit_distance) * abs(determinant)
						<= 0.00001 * visibility_geometry.triangles[triangle].w) {
					continue;
				}
				if (u >= -1e-6 && v >= -1e-6 && u + v <= 1.000001
						&& hit_distance > 0.00001 && hit_distance < distance - 0.00001) {
					return true;
				}
			}
		}
		node++;
	}
	return node < node_count;
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 extent = imageSize(color_image);
	if (any(greaterThanEqual(pixel, extent))) {
		return;
	}
	imageStore(gi_output, pixel, vec4(0.0));
	float depth = texelFetch(depth_buffer, pixel, 0).r;
	if (depth <= 0.0 || params.control.x <= 0.0 || pc.parameters.x <= 0.0 || params.grid.w <= 0.0) {
		return;
	}
	vec4 orm = texelFetch(gbuffer_orm, pixel, 0);
	uint packed_metadata = uint(round(clamp(orm.a, 0.0, 1.0) * 255.0));
	uint shading_model_id = packed_metadata & 0x0Fu;
	if (shading_model_id == 0u) {
		return; // Unlit G-buffer pixels have no SkyLight diffuse term to replace.
	}

	vec2 screen_uv = (vec2(pixel) + vec2(0.5)) / vec2(extent);
	vec4 clip = vec4(screen_uv * 2.0 - 1.0, depth, 1.0);
	vec4 view_h = params.inverse_projection * clip;
	if (abs(view_h.w) < 1e-7) {
		return;
	}
	vec3 view_position = view_h.xyz / view_h.w;
	vec3 world = (params.view_to_world * vec4(view_position, 1.0)).xyz;
	// Resolved MSAA depth can refer to a sample away from the pixel center. Locate
	// the first actual surface in a one-pixel neighborhood along this view ray,
	// once per pixel, instead of pushing every probe endpoint through thin walls.
	vec4 adjacent_x = params.inverse_projection * vec4(clip.xy + vec2(2.0 / float(extent.x), 0.0), depth, 1.0);
	vec4 adjacent_y = params.inverse_projection * vec4(clip.xy + vec2(0.0, 2.0 / float(extent.y)), depth, 1.0);
	float receiver_radius = max(length(adjacent_x.xyz / adjacent_x.w - view_position),
			length(adjacent_y.xyz / adjacent_y.w - view_position)) + 0.00001;
	vec3 view_direction = abs(params.inverse_projection[2][3]) > 1e-6
			? normalize(world - params.view_to_world[3].xyz)
			: -normalize(params.view_to_world[2].xyz);
	int receiver_triangle = -1;
	if (params.control.w > 0.5) {
		world = nearest_surface(world, view_direction, receiver_radius, -1, receiver_triangle);
	}
	vec3 normal_view = normalize(texelFetch(normal_roughness, pixel, 0).xyz * 2.0 - 1.0);
	vec3 normal_world = normalize(mat3(params.view_to_world) * normal_view);
	vec3 albedo = texelFetch(gbuffer_albedo, pixel, 0).rgb;
	float ao = clamp(orm.r, 0.0, 1.0);
	float metallic = clamp(orm.b, 0.0, 1.0);
	float spacing = max(params.control.y, 0.001);
	vec3 dimensions = params.grid.xyz;
	vec3 grid_position = (params.world_to_grid * vec4(world, 1.0)).xyz;
	mat3 world_to_grid_basis = mat3(params.world_to_grid);
	float grid_epsilon = max(1e-5, spacing * 0.001 * max(
		length(world_to_grid_basis[0]),
		max(length(world_to_grid_basis[1]), length(world_to_grid_basis[2]))));
	if (any(lessThan(grid_position, vec3(-grid_epsilon)))
			|| any(greaterThan(grid_position, dimensions + vec3(grid_epsilon)))) {
		return;
	}
	grid_position = clamp(grid_position, vec3(0.0), dimensions);

	ivec3 grid_dims = ivec3(dimensions);
	ivec3 center = clamp(ivec3(floor(grid_position)), ivec3(0), grid_dims - 1);
	vec3 indirect = vec3(0.0);
	float unoccluded_weight = 0.0;
	float candidate_weight = 0.0;
	float receiver_bias = max(0.001, spacing * 0.002);
	vec3 biased_world = world + normal_world * receiver_bias;
	int endpoint_triangle = receiver_triangle;
	int receiver_patch = receiver_triangle >= 0 ? int(visibility_geometry.triangles[receiver_triangle * 3 + 2].w) : 0;
	if (params.control.w > 0.5) {
		biased_world = world;
		if (receiver_triangle >= 0) {
			// Curved receivers may interpolate around their own continuous patch.
			// This endpoint is only used after a direct check against other patches.
			float clearance = spacing * 0.3;
			int clearance_triangle;
			vec3 clearance_hit = nearest_surface(world + normal_world * clearance * 0.5,
					normal_world, clearance * 0.5, receiver_triangle, clearance_triangle);
			if (clearance_triangle >= 0) {
				clearance = max(0.0, dot(clearance_hit - world, normal_world) * 0.5 - 0.00001);
			} else if (clearance_triangle == -2) {
				clearance = 0.0;
			}
			biased_world = world + normal_world * clearance;
			endpoint_triangle = clearance > 0.00001 ? -1 : receiver_triangle;
		}
	}
	float variance_floor = max(0.0001, spacing * spacing * 0.0001);
	// Feather outer cells to zero at a query transition, so every in-window probe can
	// contribute without a hard top-K membership cutoff.
	vec3 grid_fraction = grid_position - vec3(center);
	float back_tolerance = max(spacing * 0.12, 0.02);
	float kernel_epsilon = max(spacing * spacing * 0.16, 0.0001);
	for (int dz = -1; dz <= 1; dz++) {
		for (int dy = -1; dy <= 1; dy++) {
			for (int dx = -1; dx <= 1; dx++) {
				ivec3 cell = center + ivec3(dx, dy, dz);
				if (any(lessThan(cell, ivec3(0))) || any(greaterThanEqual(cell, grid_dims))) {
					continue;
				}
				ivec3 cell_offset = cell - center;
				float cell_window = 1.0;
				for (int axis = 0; axis < 3; axis++) {
					if (cell_offset[axis] < 0) {
						cell_window *= 1.0 - smoothstep(0.0, 1.0, grid_fraction[axis]);
					} else if (cell_offset[axis] > 0) {
						cell_window *= smoothstep(0.0, 1.0, grid_fraction[axis]);
					}
				}
				if (cell_window <= 0.0) {
					continue;
				}
				for (int slot = 0; slot < 8; slot++) {
					int probe = texelFetch(index_map, index_texel(cell, slot, grid_dims), 0).r;
					if (probe < 0) {
						break; // Build slots are dense; the remaining slots in this cell are empty.
					}
					if (float(probe) >= params.grid.w) {
						continue;
					}
					ivec2 geometry_xy = ivec2((probe % 32) * 3, probe / 32);
					vec4 surface_record = texelFetch(geometry_atlas, geometry_xy, 0);
					vec3 sample_surface = surface_record.xyz;
					vec3 sample_position = texelFetch(geometry_atlas, geometry_xy + ivec2(1, 0), 0).xyz;
					vec3 sample_normal = normalize(texelFetch(geometry_atlas, geometry_xy + ivec2(2, 0), 0).xyz);
					float normal_match = dot(normal_world, sample_normal);
					vec3 surface_delta = world - sample_surface;
					// Curved same-surface samples have opposite signed planes that cancel;
					// parallel samples behind the receiver keep negative same-sign distances.
					float sample_plane_distance = dot(surface_delta, sample_normal);
					float receiver_signed_plane_distance = dot(surface_delta, normal_world);
					float symmetric_plane_distance = 0.5 * (sample_plane_distance + receiver_signed_plane_distance);
					float plane_residual = abs(sample_plane_distance + receiver_signed_plane_distance);
					float gate = smoothstep(-back_tolerance, -back_tolerance * 0.3, symmetric_plane_distance)
							* (1.0 - smoothstep(spacing * 0.55, spacing * 0.85, symmetric_plane_distance))
							* smoothstep(0.15, 0.5, normal_match);
					if (gate <= 0.0) {
						continue;
					}
					float normalized_residual = plane_residual / (0.25 * spacing);
					// Flat/parallel candidates always need a direct visible segment.
					// Only a convex continuation of this connected smooth patch may use
					// the checked outward endpoint to avoid sparse curved self-shadowing.
					bool curved_patch = params.control.w > 0.5 && receiver_patch > 0
							&& int(surface_record.w) == receiver_patch && normal_match < 0.95
							&& sample_plane_distance < -0.00001 && receiver_signed_plane_distance > 0.00001
							&& plane_residual < spacing * 0.15;
					vec3 candidate_target = params.control.w > 0.5 && !curved_patch ? world : biased_world;
					vec3 visibility_delta = candidate_target - sample_position;
					float distance_squared = dot(visibility_delta, visibility_delta);
					float score = distance_squared
						+ symmetric_plane_distance * symmetric_plane_distance * 4.0
						+ (1.0 - normal_match) * (1.0 - normal_match) * spacing * spacing
						+ normalized_residual * normalized_residual * spacing * spacing;
					float weight = gate * cell_window * inversesqrt(kernel_epsilon + score);
					candidate_weight += weight;
					// A complete geometry query supersedes the coarse directional moments.
					// Near corners their angular footprint includes an adjacent wall even
					// when this connection is visible, producing dark probe-shaped patches.
					if (params.control.w > 0.5 && (segment_blocked(sample_position, world, receiver_triangle,
							curved_patch ? receiver_patch : 0) || (curved_patch
							&& segment_blocked(sample_position, biased_world, endpoint_triangle, 0)))) {
						continue;
					}
					unoccluded_weight += weight;
					float visibility_distance = length(visibility_delta);
					float visibility = 1.0;
					if (params.control.w < 0.5 && visibility_distance > 1e-6) {
						vec2 moments = sample_visibility_moments(probe, visibility_delta / visibility_distance);
						visibility = chebyshev_visibility(moments, visibility_distance, variance_floor);
					}
					if (visibility <= 0.0001) {
						continue;
					}
					vec3 probe_light = evaluate_probe(probe);
					indirect += probe_light * weight * visibility;
				}
			}
		}
	}
	if (candidate_weight <= 0.0) {
		return;
	}
	float total_strength = max(params.control.x * pc.parameters.x, 0.0);
	float ownership_weight = params.control.z > 0.5 ? clamp(total_strength, 0.0, 1.0) : 0.0;
	vec3 contribution = indirect / max(unoccluded_weight, 1e-7)
			* albedo * (1.0 - metallic) * ao * total_strength * pc.parameters.y;
	imageStore(gi_output, pixel, vec4(contribution, ownership_weight));
	vec4 scene_color = imageLoad(color_image, pixel);
	if (ownership_weight > 0.0) {
		vec3 sky_light_diffuse = texelFetch(sky_light_diffuse_buffer, pixel, 0).rgb;
		scene_color.rgb -= sky_light_diffuse * ownership_weight;
	}
	imageStore(color_image, pixel, vec4(scene_color.rgb + contribution, scene_color.a));
}
