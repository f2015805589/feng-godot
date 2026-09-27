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

layout(set = 0, binding = 9, std140) uniform GIParams {
	mat4 inverse_projection;
	mat4 world_to_grid;
	mat4 view_to_world;
	vec4 grid; // xyz = lookup grid dimensions; w = surface sample count.
	vec4 control; // x = strength; y = world-space probe spacing.
	vec4 lighting_sh[7]; // 27 world-space RGB SH floats, coefficient-major.
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
	return max(value, vec3(0.0));
}

ivec2 index_texel(ivec3 cell, int slot, ivec3 dimensions) {
	return ivec2(cell.x * 8 + slot, cell.y + cell.z * dimensions.y);
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 extent = imageSize(color_image);
	if (any(greaterThanEqual(pixel, extent))) {
		return;
	}
	imageStore(gi_output, pixel, vec4(0.0));
	float depth = texelFetch(depth_buffer, pixel, 0).r;
	if (depth <= 0.0 || params.control.x <= 0.0 || params.grid.w <= 0.0) {
		return;
	}

	vec2 screen_uv = (vec2(pixel) + vec2(0.5)) / vec2(extent);
	vec4 clip = vec4(screen_uv * 2.0 - 1.0, depth, 1.0);
	vec4 view_h = params.inverse_projection * clip;
	if (abs(view_h.w) < 1e-7) {
		return;
	}
	vec3 view_position = view_h.xyz / view_h.w;
	vec3 world = (params.view_to_world * vec4(view_position, 1.0)).xyz;
	vec3 normal_view = normalize(texelFetch(normal_roughness, pixel, 0).xyz * 2.0 - 1.0);
	vec3 normal_world = normalize(mat3(params.view_to_world) * normal_view);
	vec4 orm = texelFetch(gbuffer_orm, pixel, 0);
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
	int selected[4];
	float selected_score[4];
	for (int i = 0; i < 4; i++) {
		selected[i] = -1;
		selected_score[i] = 3.402823e+38;
	}
	for (int dz = -1; dz <= 1; dz++) {
		for (int dy = -1; dy <= 1; dy++) {
			for (int dx = -1; dx <= 1; dx++) {
				ivec3 cell = center + ivec3(dx, dy, dz);
				if (any(lessThan(cell, ivec3(0))) || any(greaterThanEqual(cell, grid_dims))) {
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
					ivec2 geometry_xy = ivec2((probe % 32) * 2, probe / 32);
					vec3 sample_position = texelFetch(geometry_atlas, geometry_xy, 0).xyz;
					vec3 sample_normal = normalize(texelFetch(geometry_atlas, geometry_xy + ivec2(1, 0), 0).xyz);
					float normal_match = dot(normal_world, sample_normal);
					if (normal_match < 0.25) {
						continue;
					}
					vec3 delta = world - sample_position;
					float sample_plane_distance = abs(dot(delta, sample_normal));
					float receiver_plane_distance = abs(dot(delta, normal_world));
					if (sample_plane_distance > spacing * 0.75) {
						continue;
					}
					float asymmetry = abs(sample_plane_distance - receiver_plane_distance);
					float normalized_asymmetry = asymmetry / (0.25 * spacing);
					float score = dot(delta, delta)
						+ sample_plane_distance * sample_plane_distance * 4.0
						+ (1.0 - normal_match) * (1.0 - normal_match) * spacing * spacing
						+ normalized_asymmetry * normalized_asymmetry * spacing * spacing;
					for (int candidate = 0; candidate < 4; candidate++) {
						if (score >= selected_score[candidate]) {
						continue;
					}
						for (int move = 3; move > candidate; move--) {
							selected[move] = selected[move - 1];
							selected_score[move] = selected_score[move - 1];
						}
						selected[candidate] = probe;
						selected_score[candidate] = score;
						break;
					}
				}
			}
		}
	}

	vec3 indirect = vec3(0.0);
	float interpolation_weight = 0.0;
	for (int i = 0; i < 4; i++) {
		if (selected[i] < 0) {
			continue;
		}
		float weight = inversesqrt(0.01 + selected_score[i]);
		indirect += evaluate_probe(selected[i]) * weight;
		interpolation_weight += weight;
	}
	if (interpolation_weight <= 0.0) {
		return;
	}
	vec3 contribution = indirect / interpolation_weight
			* albedo * (1.0 - metallic) * ao * params.control.x * pc.parameters.x;
	imageStore(gi_output, pixel, vec4(contribution, 1.0));
	vec4 scene_color = imageLoad(color_image, pixel);
	imageStore(color_image, pixel, vec4(scene_color.rgb + contribution, scene_color.a));
}
