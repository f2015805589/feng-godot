#[compute]
#version 450
// Build a geometry-only probe stencil for each UV2 lightmap texel. The layout
// mirrors the native LightmapGI Texture2DArray: x/y are UV2 texels, z is the
// receiver slice. The stencil is static until the scene/bake geometry changes.
#define MAGIC_GI_WIDE_CANDIDATE_POOL_LIMIT 16
#define MAGIC_GI_WIDE_VISIBLE_PROBE_LIMIT 8
#define MAGIC_GI_BAKED_VISIBILITY

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

const int LOOKUP_CELL_RADIUS = 2;
const uint SURFACE_STENCIL_MIN_CAPACITY = 16u;
const uint SURFACE_STENCIL_MID_CAPACITY = 32u;
const uint SURFACE_STENCIL_MAX_CAPACITY = 40u;
const uint SURFACE_STENCIL_HEADER_WORDS = 2u;
const uint SURFACE_STENCIL_WORDS_PER_ENTRY = 2u;

const uint SURFACE_STENCIL_INPUT_VALID = 1u;
const uint SURFACE_STENCIL_RECEIVER_VALID = 2u;
const uint SURFACE_STENCIL_HAS_CANDIDATE = 4u;
const uint SURFACE_STENCIL_HAS_SUPPORT = 8u;
const uint SURFACE_STENCIL_OVERFLOW = 16u;
const uint SURFACE_STENCIL_QUERY_FAILED = 32u;
const uint SURFACE_STENCIL_INVALID_DATA = 64u;
// Diagnostic reason bits supplement QUERY_FAILED without changing its meaning.
// Keep these in the header status word so readers can classify query failures
// while the existing relight rejection mask continues to work unchanged.
const uint SURFACE_STENCIL_QUERY_BVH_INCOMPLETE = 128u;
const uint SURFACE_STENCIL_QUERY_NO_TRIANGLE = 256u;
const uint SURFACE_STENCIL_QUERY_POSITION_MISMATCH = 512u;
const uint SURFACE_STENCIL_QUERY_TRIANGLE_INVALID = 1024u;
const uint SURFACE_STENCIL_WIDE_FALLBACK_INVOKED = 2048u;

layout(set = 0, binding = 0) uniform sampler2D geometry_atlas;
layout(set = 0, binding = 1) uniform isampler2D index_map;
layout(set = 0, binding = 2, std430) readonly buffer VisibilityNodes {
	vec4 nodes[];
} visibility_bvh;
layout(set = 0, binding = 3, std430) readonly buffer VisibilityTriangles {
	vec4 triangles[];
} visibility_geometry;
layout(set = 0, binding = 4, std430) readonly buffer DirectionalLighting {
	vec4 values[];
} directional_lighting;
layout(set = 0, binding = 5, std430) readonly buffer ProbeLighting {
	vec4 values[];
} probe_lighting;
layout(set = 0, binding = 6) uniform sampler2D visibility_moment_atlas;
layout(set = 0, binding = 7) uniform sampler2DArray position_valid;
layout(set = 0, binding = 8) uniform sampler2DArray shading_normal;
layout(set = 0, binding = 9) uniform sampler2DArray geometric_normal;
layout(set = 0, binding = 10, std140) uniform GIParams {
	mat4 inverse_projection;
	mat4 world_to_grid;
	mat4 view_to_world;
	vec4 grid;
	vec4 control;
	vec4 lighting_sh[7];
	vec4 sky_lighting_sh[7];
} params;
#define MAGIC_INDEX_BINDING 11
#define MAGIC_CLUSTER_BINDING 12
#include "magic_gi_index.glslinc"
#include "magic_gi_probe_clusters.glslinc"
layout(set = 0, binding = 13, std430) buffer SurfaceStencils {
	uint words[];
} surface_stencils;
layout(set = 0, binding = 14, std430) buffer SurfaceStencilDiagnostic {
	uint words[];
} surface_stencil_diagnostic;

layout(push_constant, std430) uniform BuildConfiguration {
	ivec4 dimensions_capacity; // width, height, slices, capacity (16, 32, or 40).
	ivec4 diagnostic_target; // xyz = target texel; w=1 UV2 diagnostic, w=2 direct query, w=3 gather with receiver -1.
} config;

bool surface_stencil_capacity_supported(int requested) {
	return requested == int(SURFACE_STENCIL_MIN_CAPACITY)
			|| requested == int(SURFACE_STENCIL_MID_CAPACITY)
			|| requested == int(SURFACE_STENCIL_MAX_CAPACITY);
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

#include "magic_gi_visibility.glslinc"
#include "magic_gi_sh.glslinc"

uint surface_stencil_base;
uint surface_stencil_capacity;
int surface_stencil_count;
int surface_stencil_begin;
int surface_stencil_narrow_count;
int surface_stencil_neighborhood;
bool surface_stencil_overflow;
bool surface_stencil_invalid_weight;
// Keep build-time weights at float precision through both neighborhood
// normalization and narrow/wide blending. Only the final accepted table is
// quantized to binary16 when it is published to the runtime SSBO.
int surface_stencil_probe_ids[40];
vec2 surface_stencil_weights[40];

void surface_stencil_reset(uint texel_index) {
	surface_stencil_base = texel_index
			* (SURFACE_STENCIL_HEADER_WORDS
			+ surface_stencil_capacity * SURFACE_STENCIL_WORDS_PER_ENTRY);
	surface_stencil_count = 0;
	surface_stencil_begin = 0;
	surface_stencil_narrow_count = 0;
	surface_stencil_neighborhood = 0;
	surface_stencil_overflow = false;
	surface_stencil_invalid_weight = false;
}

void surface_stencil_begin_neighborhood() {
	surface_stencil_begin = surface_stencil_count;
	// gather_probe_field visits the narrow neighborhood first, then may begin
	// one wide same-patch fallback. Capture the narrow prefix at the second
	// begin so the later blend applies narrow_mix and wide_mix to the right sets.
	if (surface_stencil_neighborhood++ == 1) {
		surface_stencil_narrow_count = surface_stencil_count;
	}
}

void surface_stencil_record(int probe, float secondary_weight, float sky_weight) {
	if (surface_stencil_count >= int(surface_stencil_capacity)) {
		surface_stencil_count = int(surface_stencil_capacity) + 1;
		surface_stencil_overflow = true;
		return;
	}
	if (probe < 0 || isnan(secondary_weight) || isinf(secondary_weight)
			|| isnan(sky_weight) || isinf(sky_weight)
			|| secondary_weight < 0.0 || sky_weight < 0.0) {
		surface_stencil_invalid_weight = true;
		return;
	}
	surface_stencil_probe_ids[surface_stencil_count] = probe;
	surface_stencil_weights[surface_stencil_count] = vec2(secondary_weight, sky_weight);
	surface_stencil_count++;
}

void surface_stencil_normalize(float secondary_total, float sky_total) {
	if (surface_stencil_count > int(surface_stencil_capacity)) { return; }
	if (isnan(secondary_total) || isinf(secondary_total) || secondary_total < 0.0
			|| isnan(sky_total) || isinf(sky_total) || sky_total < 0.0) {
		surface_stencil_invalid_weight = true;
		return;
	}
	for (int i = surface_stencil_begin; i < surface_stencil_count; i++) {
		vec2 weights = surface_stencil_weights[i];
		weights.x /= max(secondary_total, 1e-7);
		weights.y /= max(sky_total, 1e-7);
		if (any(isnan(weights)) || any(isinf(weights)) || any(lessThan(weights, vec2(0.0)))
				|| any(greaterThan(weights, vec2(65504.0)))) {
			surface_stencil_invalid_weight = true;
			return;
		}
		surface_stencil_weights[i] = weights;
	}
}

void surface_stencil_blend(float narrow_mix) {
	if (surface_stencil_count > int(surface_stencil_capacity)) { return; }
	if (isnan(narrow_mix) || isinf(narrow_mix) || narrow_mix < 0.0 || narrow_mix > 1.0) {
		surface_stencil_invalid_weight = true;
		return;
	}
	for (int i = 0; i < surface_stencil_count; i++) {
		float blend_weight = i < surface_stencil_narrow_count ? narrow_mix : 1.0 - narrow_mix;
		vec2 weights = surface_stencil_weights[i] * blend_weight;
		if (any(isnan(weights)) || any(isinf(weights)) || any(lessThan(weights, vec2(0.0)))
				|| any(greaterThan(weights, vec2(65504.0)))) {
			surface_stencil_invalid_weight = true;
			return;
		}
		surface_stencil_weights[i] = weights;
	}
}

void surface_stencil_publish() {
	if (surface_stencil_count > int(surface_stencil_capacity)
			|| surface_stencil_invalid_weight) { return; }
	for (int i = 0; i < surface_stencil_count; i++) {
		vec2 weights = surface_stencil_weights[i];
		if (surface_stencil_probe_ids[i] < 0 || any(isnan(weights)) || any(isinf(weights))
				|| any(lessThan(weights, vec2(0.0)))
				|| any(greaterThan(weights, vec2(65504.0)))) {
			surface_stencil_invalid_weight = true;
			return;
		}
		uint entry = surface_stencil_base + SURFACE_STENCIL_HEADER_WORDS
				+ uint(i) * SURFACE_STENCIL_WORDS_PER_ENTRY;
		surface_stencils.words[entry] = uint(surface_stencil_probe_ids[i]);
		// Runtime storage remains the compact K-entry binary16 format. Quantize
		// once, after all float normalization and neighborhood blending is done.
		surface_stencils.words[entry + 1u] = packHalf2x16(weights);
	}
}

#define MAGIC_GI_GATHER_BEGIN() surface_stencil_begin_neighborhood()
#define MAGIC_GI_GATHER_RECORD(probe, secondary, sky) surface_stencil_record(probe, secondary, sky)
#define MAGIC_GI_GATHER_NORMALIZE(secondary, sky) surface_stencil_normalize(secondary, sky)
#define MAGIC_GI_GATHER_BLEND(narrow_mix) surface_stencil_blend(narrow_mix)
#define MAGIC_GI_GATHER_DIAGNOSTIC_OUTPUTS
#include "magic_gi_gather.glslinc"

uint surface_texel_index(ivec3 coordinate) {
	return uint(coordinate.x) + uint(config.dimensions_capacity.x)
			* (uint(coordinate.y) + uint(config.dimensions_capacity.y) * uint(coordinate.z));
}

void write_surface_header(uint base, uint count, uint status) {
	surface_stencils.words[base] = count;
	surface_stencils.words[base + 1u] = status;
}

void write_surface_stencil_diagnostic(vec4 coefficients[18], vec3 normal_world,
		float candidate_weight, float visible_support_weight, int entry_count,
		uint status, int receiver_triangle) {
	float basis[9];
	diffuse_basis(normal_world, basis);
	vec3 secondary = vec3(0.0);
	vec3 primary_sky = vec3(0.0);
	for (int coefficient = 0; coefficient < 9; coefficient++) {
		secondary += coefficients[coefficient].rgb * basis[coefficient];
		primary_sky += coefficients[coefficient + 9].rgb * basis[coefficient];
	}
	// Diagnostic buffer words are: 0..2 secondary RGB float bits, 3..5 sky
	// RGB float bits, 6 candidate weight, 7 visible support, 8 entry count,
	// 9 final status, 10 signed receiver-triangle bits, 11 completion marker.
	surface_stencil_diagnostic.words[0] = floatBitsToUint(secondary.r);
	surface_stencil_diagnostic.words[1] = floatBitsToUint(secondary.g);
	surface_stencil_diagnostic.words[2] = floatBitsToUint(secondary.b);
	surface_stencil_diagnostic.words[3] = floatBitsToUint(primary_sky.r);
	surface_stencil_diagnostic.words[4] = floatBitsToUint(primary_sky.g);
	surface_stencil_diagnostic.words[5] = floatBitsToUint(primary_sky.b);
	surface_stencil_diagnostic.words[6] = floatBitsToUint(candidate_weight);
	surface_stencil_diagnostic.words[7] = floatBitsToUint(visible_support_weight);
	surface_stencil_diagnostic.words[8] = uint(max(entry_count, 0));
	surface_stencil_diagnostic.words[9] = status;
	surface_stencil_diagnostic.words[10] = receiver_triangle >= 0
			? uint(receiver_triangle) : 0xffffffffu;
	surface_stencil_diagnostic.words[11] = 0x4D474944u;
}

void main() {
	ivec3 coordinate = ivec3(gl_GlobalInvocationID.xyz);
	ivec3 dimensions = config.dimensions_capacity.xyz;
	if (any(lessThan(coordinate, ivec3(0))) || any(greaterThanEqual(coordinate, dimensions))) {
		return;
	}
	bool direct_query = config.diagnostic_target.w == 2;
	if (direct_query && any(notEqual(coordinate, ivec3(0)))) {
		return; // Direct-query diagnostics use a single scratch stencil at linear index 0.
	}
	int requested_capacity = config.dimensions_capacity.w;
	if (!surface_stencil_capacity_supported(requested_capacity)) {
		return;
	}
	surface_stencil_capacity = uint(requested_capacity);
	uint texel_index = surface_texel_index(coordinate);
	surface_stencil_reset(texel_index);
	uint base = surface_stencil_base;
	write_surface_header(base, 0u, 0u);
	if (direct_query) {
		surface_stencil_diagnostic.words[19] = 0u;
		surface_stencil_diagnostic.words[20] = floatBitsToUint(0.0);
		surface_stencil_diagnostic.words[21] = floatBitsToUint(0.0);
		// Binding 14 words 12..18 are caller inputs: world xyz float bits, normal
		// xyz float bits, and the signed triangle ID as uint bits (0xffffffff = -1).
		// Words 0..11 remain the diagnostic output, so the same buffer can carry
		// the input tuple and read back the exact-query reference without another binding.
		vec3 world = vec3(
				uintBitsToFloat(surface_stencil_diagnostic.words[12]),
				uintBitsToFloat(surface_stencil_diagnostic.words[13]),
				uintBitsToFloat(surface_stencil_diagnostic.words[14]));
		vec3 normal_record = vec3(
				uintBitsToFloat(surface_stencil_diagnostic.words[15]),
				uintBitsToFloat(surface_stencil_diagnostic.words[16]),
				uintBitsToFloat(surface_stencil_diagnostic.words[17]));
		uint receiver_bits = surface_stencil_diagnostic.words[18];
		int triangle_count = visibility_geometry.triangles.length() / 3;
		int receiver_triangle = -1;
		bool receiver_id_valid = receiver_bits == 0xffffffffu;
		if (receiver_bits != 0xffffffffu && receiver_bits < uint(triangle_count)) {
			receiver_triangle = int(receiver_bits);
			receiver_id_valid = true;
		}
		float normal_length_squared = dot(normal_record, normal_record);
		bool input_valid = visibility_finite_vec3(world)
				&& visibility_finite_vec3(normal_record)
				&& normal_length_squared > 1e-12
				&& !isnan(normal_length_squared) && !isinf(normal_length_squared)
				&& receiver_id_valid && params.control.w > 0.5;
		vec4 coefficients[18];
		for (int i = 0; i < 18; i++) { coefficients[i] = vec4(0.0); }
		float candidate_weight = 0.0;
		float visible_support_weight = 0.0;
		float narrow_confidence = 0.0;
		float narrow_support = 0.0;
		bool wide_fallback_invoked = false;
		uint status = SURFACE_STENCIL_INPUT_VALID;
		vec3 normal_world = vec3(0.0, 1.0, 0.0);
		if (!input_valid) {
			status |= SURFACE_STENCIL_INVALID_DATA;
			write_surface_header(base, 0u, status);
			write_surface_stencil_diagnostic(coefficients, normal_world, 0.0, 0.0,
					0, status, receiver_triangle);
			return;
		}
		normal_world = normal_record * inversesqrt(normal_length_squared);
		if (receiver_triangle >= 0) { status |= SURFACE_STENCIL_RECEIVER_VALID; }
		gather_probe_field(world, normal_world, receiver_triangle, true, true, false, coefficients,
				candidate_weight, visible_support_weight, false,
				narrow_confidence, narrow_support, wide_fallback_invoked);
		surface_stencil_publish();
		if (candidate_weight > 0.0) { status |= SURFACE_STENCIL_HAS_CANDIDATE; }
		if (visible_support_weight > 1e-10) { status |= SURFACE_STENCIL_HAS_SUPPORT; }
		if (wide_fallback_invoked) { status |= SURFACE_STENCIL_WIDE_FALLBACK_INVOKED; }
		if (surface_stencil_overflow) { status |= SURFACE_STENCIL_OVERFLOW; }
		if (surface_stencil_invalid_weight) { status |= SURFACE_STENCIL_INVALID_DATA; }
		write_surface_header(base, uint(max(surface_stencil_count, 0)), status);
		write_surface_stencil_diagnostic(coefficients, normal_world, candidate_weight,
				visible_support_weight, surface_stencil_count, status, receiver_triangle);
		surface_stencil_diagnostic.words[19] = wide_fallback_invoked ? 1u : 0u;
		surface_stencil_diagnostic.words[20] = floatBitsToUint(narrow_confidence);
		surface_stencil_diagnostic.words[21] = floatBitsToUint(narrow_support);
		return;
	}

	ivec2 pixel = coordinate.xy;
	int layer = coordinate.z;
	vec4 position_record = texelFetch(position_valid, ivec3(pixel, layer), 0);
	if (!(position_record.a > 0.5)) { return; }
	uint status = SURFACE_STENCIL_INPUT_VALID;
	vec3 world = position_record.xyz;
	vec3 normal_record = texelFetch(shading_normal, ivec3(pixel, layer), 0).xyz;
	vec3 geometric_record = texelFetch(geometric_normal, ivec3(pixel, layer), 0).xyz;
	float normal_length_squared = dot(normal_record, normal_record);
	float geometric_length_squared = dot(geometric_record, geometric_record);
	if (!visibility_finite_vec3(world) || !visibility_finite_vec3(normal_record)
			|| !visibility_finite_vec3(geometric_record)
			|| !(normal_length_squared > 1e-12) || !(geometric_length_squared > 1e-12)
			|| isnan(normal_length_squared) || isinf(normal_length_squared)
			|| isnan(geometric_length_squared) || isinf(geometric_length_squared)
			|| params.control.w <= 0.5) {
		write_surface_header(base, 0u, status | SURFACE_STENCIL_INVALID_DATA);
		return;
	}
	vec3 normal_world = normal_record * inversesqrt(normal_length_squared);
	vec3 geometric_world = geometric_record * inversesqrt(geometric_length_squared);
	float spacing = max(params.control.y, 0.001);
	float coordinate_scale = max(max(abs(world.x), abs(world.y)), abs(world.z));
	float position_tolerance = max(1e-5, max(coordinate_scale * 1e-6, spacing * 1e-4));
	float ray_radius = max(position_tolerance * 2.0, spacing * 0.01);
	int receiver_triangle = -1;
	vec3 receiver_position = nearest_surface(world, geometric_world, ray_radius, -1,
			receiver_triangle);
	int triangle_count = visibility_geometry.triangles.length() / 3;
	if (receiver_triangle == -2) {
		write_surface_header(base, 0u, status | SURFACE_STENCIL_QUERY_FAILED
				| SURFACE_STENCIL_QUERY_BVH_INCOMPLETE);
		return;
	}
	if (receiver_triangle == -1) {
		write_surface_header(base, 0u, status | SURFACE_STENCIL_QUERY_FAILED
				| SURFACE_STENCIL_QUERY_NO_TRIANGLE);
		return;
	}
	if (receiver_triangle < 0 || receiver_triangle >= triangle_count) {
		write_surface_header(base, 0u, status | SURFACE_STENCIL_QUERY_FAILED
				| SURFACE_STENCIL_QUERY_TRIANGLE_INVALID);
		return;
	}
	if (!visibility_finite_vec3(receiver_position)
			|| dot(receiver_position - world, receiver_position - world)
				> position_tolerance * position_tolerance) {
		write_surface_header(base, 0u, status | SURFACE_STENCIL_QUERY_FAILED
				| SURFACE_STENCIL_QUERY_POSITION_MISMATCH);
		return;
	}
	int triangle_base = receiver_triangle * 3;
	// Match the winding convention used by the existing BVH receiver queries.
	vec3 triangle_normal = cross(visibility_geometry.triangles[triangle_base + 2].xyz,
			visibility_geometry.triangles[triangle_base + 1].xyz);
	float triangle_normal_length_squared = dot(triangle_normal, triangle_normal);
	float patch_value = visibility_geometry.triangles[triangle_base + 2].w;
	if (!visibility_finite_vec3(triangle_normal) || !(triangle_normal_length_squared > 1e-12)
			|| isnan(patch_value) || isinf(patch_value) || patch_value <= 0.0
			|| floor(patch_value) != patch_value
			|| dot(triangle_normal * inversesqrt(triangle_normal_length_squared), geometric_world) < 0.95) {
		write_surface_header(base, 0u, status | SURFACE_STENCIL_QUERY_FAILED
				| SURFACE_STENCIL_QUERY_TRIANGLE_INVALID);
		return;
	}
	status |= SURFACE_STENCIL_RECEIVER_VALID;

	vec4 coefficients[18];
	float candidate_weight = 0.0;
	float visible_support_weight = 0.0;
	float narrow_confidence = 0.0;
	float narrow_support = 0.0;
	bool wide_fallback_invoked = false;
	// w=3 preserves the successful atlas BVH validation/status but deliberately
	// removes only the receiver-patch hint for the gather A/B comparison.
	int gather_receiver_triangle = config.diagnostic_target.w == 3 ? -1 : receiver_triangle;
	gather_probe_field(world, normal_world, gather_receiver_triangle, true, true, false, coefficients,
			candidate_weight, visible_support_weight, false,
			narrow_confidence, narrow_support, wide_fallback_invoked);
	surface_stencil_publish();
	if (candidate_weight > 0.0) { status |= SURFACE_STENCIL_HAS_CANDIDATE; }
	if (visible_support_weight > 1e-10) { status |= SURFACE_STENCIL_HAS_SUPPORT; }
	if (wide_fallback_invoked) { status |= SURFACE_STENCIL_WIDE_FALLBACK_INVOKED; }
	if (surface_stencil_overflow) { status |= SURFACE_STENCIL_OVERFLOW; }
	if (surface_stencil_invalid_weight) { status |= SURFACE_STENCIL_INVALID_DATA; }
	write_surface_header(base, uint(max(surface_stencil_count, 0)), status);
	if (config.diagnostic_target.w == 1
			&& all(greaterThanEqual(config.diagnostic_target.xyz, ivec3(0)))
			&& all(equal(coordinate, config.diagnostic_target.xyz))) {
		write_surface_stencil_diagnostic(coefficients, normal_world, candidate_weight,
				visible_support_weight, surface_stencil_count, status, receiver_triangle);
	}
}
