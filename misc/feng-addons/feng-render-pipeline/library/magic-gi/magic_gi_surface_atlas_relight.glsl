#[compute]
#version 450
// Rebuild a native non-SH lightmap from the current per-probe directional SH.
// The atlas stores linear incident diffuse radiance; material albedo/AO and
// renderer exposure normalization are applied later by the native Lightmap path.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

const uint SURFACE_STENCIL_MIN_CAPACITY = 16u;
const uint SURFACE_STENCIL_MID_CAPACITY = 32u;
const uint SURFACE_STENCIL_MAX_CAPACITY = 40u;
const uint SURFACE_STENCIL_HEADER_WORDS = 2u;
const uint SURFACE_STENCIL_WORDS_PER_ENTRY = 2u;

const uint SURFACE_STENCIL_INPUT_VALID = 1u;
const uint SURFACE_STENCIL_RECEIVER_VALID = 2u;
const uint SURFACE_STENCIL_OVERFLOW = 16u;
const uint SURFACE_STENCIL_QUERY_FAILED = 32u;
const uint SURFACE_STENCIL_INVALID_DATA = 64u;

layout(set = 0, binding = 0, std430) readonly buffer SurfaceStencils {
	uint words[];
} surface_stencils;
layout(set = 0, binding = 1, std430) readonly buffer DirectionalLighting {
	vec4 values[];
} directional_lighting;
layout(set = 0, binding = 2) uniform sampler2DArray shading_normal;
layout(rgba16f, set = 0, binding = 3) uniform writeonly image2DArray radiance_atlas;
layout(set = 0, binding = 4, std140) uniform GIParams {
	mat4 inverse_projection;
	mat4 world_to_grid;
	mat4 view_to_world;
	vec4 grid;
	vec4 control;
	vec4 lighting_sh[7];
	vec4 sky_lighting_sh[7];
} params;

layout(push_constant, std430) uniform RelightConfiguration {
	ivec4 dimensions_capacity; // width, height, slices, capacity (16, 32, or 40).
	vec4 parameters; // x = pass strength; other lanes reserved.
} config;

bool surface_stencil_capacity_supported(int requested) {
	return requested == int(SURFACE_STENCIL_MIN_CAPACITY)
			|| requested == int(SURFACE_STENCIL_MID_CAPACITY)
			|| requested == int(SURFACE_STENCIL_MAX_CAPACITY);
}

void diffuse_basis(vec3 n, out float y[9]) {
	y[0] = 0.2820947918;
	y[1] = 0.4886025119 * n.y * (2.0 / 3.0);
	y[2] = 0.4886025119 * n.z * (2.0 / 3.0);
	y[3] = 0.4886025119 * n.x * (2.0 / 3.0);
	y[4] = 1.0925484306 * n.x * n.y * 0.25;
	y[5] = 1.0925484306 * n.y * n.z * 0.25;
	y[6] = 0.3153915653 * (3.0 * n.z * n.z - 1.0) * 0.25;
	y[7] = 1.0925484306 * n.x * n.z * 0.25;
	y[8] = 0.5462742153 * (n.x * n.x - n.y * n.y) * 0.25;
}

uint surface_texel_index(ivec3 coordinate) {
	return uint(coordinate.x) + uint(config.dimensions_capacity.x)
			* (uint(coordinate.y) + uint(config.dimensions_capacity.y) * uint(coordinate.z));
}

void main() {
	ivec3 coordinate = ivec3(gl_GlobalInvocationID.xyz);
	ivec3 dimensions = config.dimensions_capacity.xyz;
	if (any(lessThan(coordinate, ivec3(0))) || any(greaterThanEqual(coordinate, dimensions))) {
		return;
	}
	imageStore(radiance_atlas, coordinate, vec4(0.0));
	int requested_capacity = config.dimensions_capacity.w;
	if (!surface_stencil_capacity_supported(requested_capacity)) {
		return;
	}
	uint capacity = uint(requested_capacity);
	uint texel_index = surface_texel_index(coordinate);
	uint base = texel_index * (SURFACE_STENCIL_HEADER_WORDS
			+ capacity * SURFACE_STENCIL_WORDS_PER_ENTRY);
	uint count = surface_stencils.words[base];
	uint status = surface_stencils.words[base + 1u];
	uint invalid_status = SURFACE_STENCIL_OVERFLOW | SURFACE_STENCIL_QUERY_FAILED
			| SURFACE_STENCIL_INVALID_DATA;
	if ((status & (SURFACE_STENCIL_INPUT_VALID | SURFACE_STENCIL_RECEIVER_VALID))
			!= (SURFACE_STENCIL_INPUT_VALID | SURFACE_STENCIL_RECEIVER_VALID)
			|| (status & invalid_status) != 0u || count > capacity
			|| count == 0u) {
		return;
	}
	ivec3 normal_coord = coordinate;
	vec3 normal_world = texelFetch(shading_normal, normal_coord, 0).xyz;
	float normal_length_squared = dot(normal_world, normal_world);
	if (any(isnan(normal_world)) || any(isinf(normal_world))
			|| !(normal_length_squared > 1e-12) || isnan(normal_length_squared)
			|| isinf(normal_length_squared)) {
		return;
	}
	normal_world *= inversesqrt(normal_length_squared);
	float basis[9];
	diffuse_basis(normal_world, basis);
	int probe_count = directional_lighting.values.length() / 20;
	vec3 secondary = vec3(0.0);
	vec3 primary_sky = vec3(0.0);
	for (uint i = 0u; i < count; i++) {
		uint entry = base + SURFACE_STENCIL_HEADER_WORDS
				+ i * SURFACE_STENCIL_WORDS_PER_ENTRY;
		uint probe = surface_stencils.words[entry];
		vec2 weights = unpackHalf2x16(surface_stencils.words[entry + 1u]);
		if (probe >= uint(probe_count) || any(isnan(weights)) || any(isinf(weights))
				|| any(lessThan(weights, vec2(0.0)))) {
			imageStore(radiance_atlas, coordinate, vec4(0.0));
			return;
		}
		vec3 secondary_probe = vec3(0.0);
		vec3 sky_probe = vec3(0.0);
		for (uint k = 0u; k < 9u; k++) {
			secondary_probe += directional_lighting.values[probe * 20u + k].rgb * basis[k];
			sky_probe += directional_lighting.values[probe * 20u + 9u + k].rgb * basis[k];
		}
		secondary += secondary_probe * weights.x;
		primary_sky += sky_probe * weights.y;
	}
	if (params.control.z < 0.5) { primary_sky = vec3(0.0); }
	float total_strength = max(params.control.x * config.parameters.x, 0.0);
	vec3 incident = (max(secondary, vec3(0.0)) + max(primary_sky, vec3(0.0))) * total_strength;
	if (any(isnan(incident)) || any(isinf(incident))) {
		return;
	}
	imageStore(radiance_atlas, coordinate, vec4(incident, 1.0));
}
