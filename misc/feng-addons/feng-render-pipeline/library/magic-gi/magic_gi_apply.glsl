#[compute]
#version 450
#define MAGIC_GI_WIDE_CANDIDATE_POOL_LIMIT 16
#define MAGIC_GI_WIDE_VISIBLE_PROBE_LIMIT 8

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

const int LOOKUP_CELL_RADIUS = 2;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D depth_buffer;
layout(set = 0, binding = 2) uniform sampler2D normal_roughness;
layout(set = 0, binding = 3) uniform sampler2D gbuffer_albedo;
layout(set = 0, binding = 4) uniform sampler2D gbuffer_orm;
layout(rgba16f, set = 0, binding = 5) uniform writeonly image2D gi_output;
layout(set = 0, binding = 7) uniform sampler2D geometry_atlas;
layout(set = 0, binding = 8) uniform isampler2D index_map;
layout(set = 0, binding = 12) uniform sampler2D sky_light_diffuse_buffer;
layout(set = 0, binding = 13) uniform sampler2D visibility_moment_atlas;
layout(set = 0, binding = 14, std430) readonly buffer VisibilityNodes {
	vec4 nodes[]; // min.xyz / escape index, max.xyz / packed leaf range.
} visibility_bvh;
layout(set = 0, binding = 15, std430) readonly buffer VisibilityTriangles {
	vec4 triangles[]; // vertex, edge1, edge2; two-sided opaque blockers.
} visibility_geometry;
layout(set = 0, binding = 16) uniform sampler2D diffuse_ambient_occlusion_texture;
layout(set = 0, binding = 17, std430) readonly buffer ProbeLighting {
	vec4 values[];
} probe_lighting;
layout(set = 0, binding = 23, std140) uniform PageParams {
	vec4 core_min_enabled;
	vec4 core_max;
	ivec4 dispatch_rect; // xy = pixel offset, zw = dispatched rectangle size.
	mat4 owner_world_to_local;
	vec4 owner_size_enabled; // xyz = original oriented volume size.
} page;

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

#define MAGIC_INDEX_BINDING 22
#define MAGIC_CLUSTER_BINDING 24
#include "magic_gi_index.glslinc"
#include "magic_gi_probe_clusters.glslinc"

#include "magic_gi_visibility.glslinc"
#include "magic_gi_sh.glslinc"
#include "magic_gi_clv_sample.glslinc"
#include "magic_gi_gather.glslinc"

const int CLV_DEBUG_OFF = 0;
const int CLV_DEBUG_CASCADE_LEVELS = 1;
const int CLV_DEBUG_CACHE_VALIDITY = 2;
const int CLV_DEBUG_CELLS = 3;
const int CLV_DEBUG_RECONSTRUCTED_LIGHTING = 4;

vec3 clv_level_color(int level) {
	switch (level) {
		case 0: return vec3(0.08, 0.9, 0.12);
		case 1: return vec3(1.0, 0.55, 0.04);
		case 2: return vec3(0.12, 0.35, 1.0);
	}
	return vec3(0.0);
}

vec3 clv_reject_color(int reason) {
	switch (reason) {
		case CLV_REJECT_DISABLED: return vec3(0.8, 0.05, 0.8);
		case CLV_REJECT_OUTSIDE: return vec3(0.05, 0.15, 0.8);
		case CLV_REJECT_NO_VALID_CORNERS: return vec3(1.0, 0.45, 0.02);
		case CLV_REJECT_GEOMETRY_BLOCKED: return vec3(1.0, 0.04, 0.02);
		case CLV_REJECT_NO_EXACT_SUPPORT: return vec3(0.95, 0.1, 0.65);
		case CLV_REJECT_NO_EXACT_CANDIDATE: return vec3(0.18, 0.18, 0.18);
		case CLV_REJECT_OUTSIDE_BAKE_GRID: return vec3(0.1, 0.65, 0.8);
		case CLV_REJECT_INCOMPLETE_SUPPORT: return vec3(1.0, 0.45, 0.02);
	}
	return vec3(0.0);
}

vec3 clv_debug_color(int view, int sample_status, int reject_reason,
		int selected_level, float coverage, vec3 cell_fraction, vec3 lighting) {
	if (view == CLV_DEBUG_RECONSTRUCTED_LIGHTING) {
		return max(lighting, vec3(0.0));
	}
	vec3 level_color = clv_level_color(selected_level);
	if (view == CLV_DEBUG_CASCADE_LEVELS) {
		return sample_status == CLV_SAMPLE_EXACT ? vec3(1.0, 0.0, 1.0) : level_color;
	}
	if (view == CLV_DEBUG_CACHE_VALIDITY) {
		if (sample_status == CLV_SAMPLE_EXACT) {
			vec3 reject_color = clv_reject_color(reject_reason);
			if (reject_reason == CLV_REJECT_INCOMPLETE_SUPPORT) {
				return mix(reject_color, vec3(1.0, 0.82, 0.03), clamp(coverage, 0.0, 1.0));
			}
			return reject_color;
		}
		if (sample_status == CLV_SAMPLE_FULL) {
			return vec3(0.05, 0.9, 0.12);
		}
		return clv_reject_color(reject_reason);
	}
	if (view == CLV_DEBUG_CELLS) {
		if (sample_status == CLV_SAMPLE_EXACT) {
			return vec3(1.0, 0.0, 1.0);
		}
		vec3 edge_distance = min(cell_fraction, vec3(1.0) - cell_fraction);
		float edge = min(edge_distance.x, min(edge_distance.y, edge_distance.z));
		float line = 1.0 - smoothstep(0.02, 0.06, edge);
		return level_color * mix(0.12, 1.0, line);
	}
	return vec3(0.0);
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy) + page.dispatch_rect.xy;
	ivec2 extent = imageSize(color_image);
	if (any(greaterThanEqual(pixel, extent))
			|| any(greaterThanEqual(gl_GlobalInvocationID.xy, uvec2(page.dispatch_rect.zw)))) {
		return;
	}
	int debug_view = int(round(pc.parameters.w));
	bool debug_enabled = debug_view != CLV_DEBUG_OFF;
	float depth = texelFetch(depth_buffer, pixel, 0).r;
	if (depth <= 0.0 || (!debug_enabled
			&& (params.control.x <= 0.0 || pc.parameters.x <= 0.0 || params.grid.w <= 0.0))) {
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
	if (page.core_min_enabled.w > 0.5 && (any(lessThan(world, page.core_min_enabled.xyz))
			|| any(greaterThanEqual(world, page.core_max.xyz)))) {
		return; // Support halos never own pixels; ownership stays half-open and unique.
	}
	if (page.owner_size_enabled.w > 0.5) {
		vec3 owner_local = (page.owner_world_to_local * vec4(world, 1.0)).xyz;
		if (any(greaterThan(abs(owner_local), page.owner_size_enabled.xyz * 0.5))) {
			return; // World-aligned page AABBs are additionally clipped to the source OBB.
		}
	}
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
		if (debug_enabled) {
			imageStore(gi_output, pixel,
					vec4(clv_debug_color(debug_view, CLV_SAMPLE_EXACT,
							CLV_REJECT_OUTSIDE_BAKE_GRID, -1, 0.0, vec3(0.0), vec3(0.0)), 0.0));
		}
		return;
	}
	grid_position = clamp(grid_position, vec3(0.0), dimensions);

	vec3 secondary_emission;
	vec3 primary_sky;
	float candidate_weight = 1.0;
	float cache_weight = 0.0;
	bool complete_support = false;
	int selected_level = -1;
	int sample_status = CLV_SAMPLE_EXACT;
	int reject_reason = CLV_REJECT_NONE;
	vec3 cell_fraction = vec3(0.0);
	int receiver_patch = receiver_triangle >= 0 ? int(visibility_geometry.triangles[receiver_triangle * 3 + 2].w) : 0;
	// Cache radiance is used only when every positive-weight corner has valid metadata and clear LOS.
	// Incomplete support falls through to one exact gather so both paths reconstruct the same field.
	bool cached_light;
	if (debug_enabled) {
		cached_light = sample_clv_diagnostic(world, normal_world, receiver_triangle, receiver_patch,
				secondary_emission, primary_sky, cache_weight, complete_support,
				selected_level, sample_status, reject_reason, cell_fraction);
	} else {
		cached_light = sample_clv(world, normal_world, receiver_triangle, receiver_patch,
				secondary_emission, primary_sky, cache_weight, complete_support);
	}
	if (!cached_light) {
		vec4 coefficients[18];
		float visible_support_weight = 0.0;
		gather_probe_field(world, normal_world, receiver_triangle, false, clv.control.w > 0,
				coefficients, candidate_weight, visible_support_weight);
		secondary_emission = max(coefficients[0].rgb, vec3(0.0));
		primary_sky = max(coefficients[9].rgb, vec3(0.0));
		if (debug_enabled && reject_reason == CLV_REJECT_INCOMPLETE_SUPPORT
				&& visible_support_weight <= 1e-10) {
			sample_status = CLV_SAMPLE_EXACT;
			reject_reason = CLV_REJECT_NO_EXACT_SUPPORT;
		}
	}
	if (params.control.z < 0.5) { primary_sky = vec3(0.0); }
	if (candidate_weight <= 0.0) {
		if (debug_enabled) {
			if (reject_reason == CLV_REJECT_NONE) {
				reject_reason = CLV_REJECT_NO_EXACT_CANDIDATE;
			}
			imageStore(gi_output, pixel,
					vec4(clv_debug_color(debug_view, CLV_SAMPLE_EXACT, reject_reason,
							selected_level, cache_weight, cell_fraction, vec3(0.0)), 0.0));
		}
		return;
	}
	float total_strength = max(params.control.x * pc.parameters.x, 0.0);
	float ownership_weight = params.control.z > 0.5 ? clamp(total_strength, 0.0, 1.0) : 0.0;
	float diffuse_ao = texture(diffuse_ambient_occlusion_texture, (vec2(pixel) + 0.5) / vec2(extent)).r;
	if (isnan(diffuse_ao) || isinf(diffuse_ao)) {
		diffuse_ao = 1.0;
	}
	vec3 contribution = (secondary_emission + primary_sky)
			* albedo * (1.0 - metallic) * ao * clamp(diffuse_ao, 0.0, 1.0) * total_strength * pc.parameters.y;
	vec3 output_rgb = debug_enabled
			? clv_debug_color(debug_view, sample_status, reject_reason, selected_level,
					cache_weight, cell_fraction, secondary_emission + primary_sky)
			: contribution;
	if (debug_enabled && debug_view == CLV_DEBUG_RECONSTRUCTED_LIGHTING) {
		output_rgb *= pc.parameters.y;
	}
	imageStore(gi_output, pixel, vec4(output_rgb, ownership_weight));
	vec4 scene_color = imageLoad(color_image, pixel);
	if (ownership_weight > 0.0) {
		vec3 sky_light_diffuse = texelFetch(sky_light_diffuse_buffer, pixel, 0).rgb;
		scene_color.rgb -= sky_light_diffuse * ownership_weight;
	}
	imageStore(color_image, pixel, vec4(scene_color.rgb + contribution, scene_color.a));
}
