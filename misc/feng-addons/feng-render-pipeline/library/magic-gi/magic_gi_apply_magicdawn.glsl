#[compute]
#version 450
// Layout17 screen consumer: schema-rev2 baked total diffuse SH (secondary plus
// visibility-filtered primary Sky, excluding real-time direct Directional), one selected
// clipmap level (seven trilinear taps) or a real two-level boundary crossfade
// (fourteen taps). It has no source-probe gather, runtime relight, or B14 path.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D depth_buffer;
layout(set = 0, binding = 2) uniform sampler2D normal_roughness;
layout(set = 0, binding = 3) uniform sampler2D gbuffer_albedo;
layout(set = 0, binding = 4) uniform sampler2D gbuffer_orm;
layout(rgba16f, set = 0, binding = 5) uniform writeonly image2D gi_output;
// Required for rev2 ownership: this is the native unoccluded Sky diffuse term.
layout(set = 0, binding = 12) uniform sampler2D sky_light_diffuse_buffer;
layout(set = 0, binding = 16) uniform sampler2D diffuse_ambient_occlusion_texture;

layout(set = 0, binding = 40) uniform sampler3D clv_baked_sh_0;
layout(set = 0, binding = 41) uniform sampler3D clv_baked_sh_1;
layout(set = 0, binding = 42) uniform sampler3D clv_baked_sh_2;
layout(set = 0, binding = 43) uniform sampler3D clv_baked_sh_3;
layout(set = 0, binding = 44) uniform sampler3D clv_baked_sh_4;
layout(set = 0, binding = 45) uniform sampler3D clv_baked_sh_5;
layout(set = 0, binding = 46) uniform sampler3D clv_baked_sh_6;

layout(set = 0, binding = 9, std140) uniform GIParams {
	mat4 inverse_projection;
	mat4 world_to_grid;
	mat4 view_to_world;
	vec4 grid;
	vec4 control; // x = GI strength; y = source-probe spacing; z = Sky replacement ready.
	vec4 lighting_sh[7];
	vec4 sky_lighting_sh[7];
} params;

layout(set = 0, binding = 21, std140) uniform ClipmapParameters {
	ivec4 origins[3];
	vec4 spacing; // x = .25m base cell; yzw = camera world position.
	ivec4 control; // resolution, level count, geometry epoch, layout version.
	vec4 codec; // decode scale, encode scale, format tag (16/32), codec revision (1).
} clv;

layout(set = 0, binding = 23, std140) uniform PageParams {
	vec4 core_min_enabled;
	vec4 core_max;
	ivec4 dispatch_rect;
	mat4 owner_world_to_local;
	vec4 owner_size_enabled;
} page;

// Binding must always reference at least 8 uints (32 bytes). Normal frames do
// not execute atomics; the runner enables a one-frame QA capture with .w=201.
layout(set = 0, binding = 27, std430) buffer MagicDawnStats {
	uint counts[];
} magicdawn_stats;

layout(push_constant, std430) uniform PassParameters {
	vec4 parameters; // x = page GI strength; y = pre-exposure; z = receiver QA mode; w=201 enables stats.
} pc;

#include "magic_gi_clv_baked_sh_layout.glslinc"
#include "magic_gi_sh.glslinc"

const int MAGICDAWN_STATS_CAPTURE = 201;

bool magicdawn_finite1(float v) {
	return !isnan(v) && !isinf(v);
}

bool magicdawn_finite3(vec3 v) {
	return !any(isnan(v)) && !any(isinf(v));
}

bool magicdawn_finite4(vec4 v) {
	return !any(isnan(v)) && !any(isinf(v));
}

int magicdawn_axis_tag(vec3 n) {
	int axis = 0;
	float major = abs(n.x);
	if (abs(n.y) > major) {
		axis = 1;
		major = abs(n.y);
	}
	if (abs(n.z) > major) {
		axis = 2;
	}
	float perpendicular_squared;
	float axis_component;
	if (axis == 0) {
		perpendicular_squared = n.y * n.y + n.z * n.z;
		axis_component = n.x;
	} else if (axis == 1) {
		perpendicular_squared = n.x * n.x + n.z * n.z;
		axis_component = n.y;
	} else {
		perpendicular_squared = n.x * n.x + n.y * n.y;
		axis_component = n.z;
	}
	// sqrt(3)/1023 + 2e-5, squared. UNORM10 component quantization
	// bounds each signed-normal component error by 1/1023; the orthonormal
	// view-to-world transform preserves this conservative 3D error bound.
	if (perpendicular_squared > 2.9347435e-6) {
		return 0;
	}
	return axis_component < 0.0 ? -(axis + 1) : (axis + 1);
}

vec4 magicdawn_field_0(vec3 coordinate) { return textureLod(clv_baked_sh_0, coordinate, 0.0); }
vec4 magicdawn_field_1(vec3 coordinate) { return textureLod(clv_baked_sh_1, coordinate, 0.0); }
vec4 magicdawn_field_2(vec3 coordinate) { return textureLod(clv_baked_sh_2, coordinate, 0.0); }
vec4 magicdawn_field_3(vec3 coordinate) { return textureLod(clv_baked_sh_3, coordinate, 0.0); }
vec4 magicdawn_field_4(vec3 coordinate) { return textureLod(clv_baked_sh_4, coordinate, 0.0); }
vec4 magicdawn_field_5(vec3 coordinate) { return textureLod(clv_baked_sh_5, coordinate, 0.0); }
vec4 magicdawn_field_6(vec3 coordinate) { return textureLod(clv_baked_sh_6, coordinate, 0.0); }


bool magicdawn_sample_level(vec3 sample_position, vec3 normal_world, int axis_tag,
		int level, out vec3 incident, out float coverage) {
	incident = vec3(0.0);
	coverage = 0.0;
	ivec4 control = clv.control;
	vec4 spacing = clv.spacing;
	int resolution = control.x;
	int level_count = control.y;
	if (control.w != MAGIC_GI_CLV_BAKED_SH_LAYOUT_VERSION || level < 0 || level >= level_count ||
			level_count < 1 || level_count > MAGIC_GI_CLV_BAKED_SH_LEVEL_COUNT || !(resolution == 16 || resolution == 24 || resolution == 32) ||
			!(spacing.x > 0.0) || !magicdawn_finite3(sample_position)) { return false; }
	float step_size = spacing.x * float(1 << level);
	vec3 grid_position = sample_position / step_size - vec3(0.5);
	if (!magicdawn_finite3(grid_position)) { return false; }
	ivec3 base = ivec3(floor(grid_position));
	vec3 fraction = fract(grid_position);
	ivec3 origin = clv.origins[level].xyz;
	ivec3 min_corner = origin + ivec3(1);
	ivec3 max_corner = origin + ivec3(resolution - 2);
	if (any(lessThan(base, min_corner)) || any(greaterThan(base + ivec3(1), max_corner))) {
		return false;
	}
	ivec3 physical = ((base % resolution) + resolution) % resolution;
	int stride = resolution + MAGIC_GI_CLV_BAKED_SH_GUARD;
	ivec3 texture_extent = ivec3(stride, stride, level_count * stride);
	vec3 texel_center = vec3(physical.x, physical.y, level * stride + physical.z) +
			fraction + vec3(0.5);
	vec3 coordinate = texel_center / vec3(texture_extent);
	bool coverage_finite = true;
	if (axis_tag == 0) {
		// Layout17 stores the exact quadratic E/pi tensor. Stream seven taps in
		// pack order and keep only the two Qxy/Qyz scalar carries live.
		vec4 field_sample = magicdawn_field_0(coordinate);
		incident = field_sample.xyz * (normal_world.x * normal_world.x);
		float qxy_r = field_sample.w;
		field_sample = magicdawn_field_1(coordinate);
		incident += field_sample.xyz * normal_world.x;
		float qxy_g = field_sample.w;
		field_sample = magicdawn_field_2(coordinate);
		incident += field_sample.xyz * (normal_world.y * normal_world.y);
		incident += vec3(qxy_r, qxy_g, field_sample.w) * (normal_world.x * normal_world.y);
		field_sample = magicdawn_field_3(coordinate);
		incident += field_sample.xyz * normal_world.y;
		float qyz_r = field_sample.w;
		field_sample = magicdawn_field_4(coordinate);
		incident += field_sample.xyz * (normal_world.z * normal_world.z);
		float qyz_g = field_sample.w;
		field_sample = magicdawn_field_5(coordinate);
		incident += field_sample.xyz * normal_world.z;
		incident += vec3(qyz_r, qyz_g, field_sample.w) * (normal_world.y * normal_world.z);
		field_sample = magicdawn_field_6(coordinate);
		incident += field_sample.xyz * (normal_world.x * normal_world.z);
		coverage_finite = magicdawn_finite1(field_sample.a);
		coverage = clamp(field_sample.a, 0.0, 1.0);
	} else {
		// An accepted axis normal needs only its E/L pair plus F6 readiness.
		vec4 f6 = magicdawn_field_6(coordinate);
		coverage_finite = magicdawn_finite1(f6.a);
		coverage = clamp(f6.a, 0.0, 1.0);
		float sign_axis = axis_tag > 0 ? 1.0 : -1.0;
		if (abs(axis_tag) == 1) {
			vec4 e = magicdawn_field_0(coordinate);
			vec4 l = magicdawn_field_1(coordinate);
			incident = e.xyz + l.xyz * sign_axis;
		} else if (abs(axis_tag) == 2) {
			vec4 e = magicdawn_field_2(coordinate);
			vec4 l = magicdawn_field_3(coordinate);
			incident = e.xyz + l.xyz * sign_axis;
		} else {
			vec4 e = magicdawn_field_4(coordinate);
			vec4 l = magicdawn_field_5(coordinate);
			incident = e.xyz + l.xyz * sign_axis;
		}
	}
	if (!coverage_finite || !magicdawn_finite3(incident)) {
		incident = vec3(0.0);
		coverage = 0.0;
		return false;
	}
	// Tensor coefficients are already premultiplied by binary slot validity.
	return true;
}

float magicdawn_level_edge_distance(vec3 world, int level, out bool in_window) {
	float step_size = clv.spacing.x * float(1 << level);
	int resolution = clv.control.x;
	vec3 logical_position = world / step_size - vec3(0.5);
	ivec3 origin = clv.origins[level].xyz;
	// A base cell and its upper trilinear neighbor must both be interior. This
	// matches magicdawn_sample_level's scroll-safe sample window exactly.
	vec3 lower = vec3(origin + ivec3(1));
	vec3 upper = vec3(origin + ivec3(resolution - 2));
	in_window = all(greaterThanEqual(logical_position, lower))
			&& all(lessThan(logical_position, upper));
	vec3 axis_margin = min(logical_position - lower, upper - logical_position);
	return min(min(axis_margin.x, axis_margin.y), axis_margin.z) * step_size;
}

float magicdawn_level_fade_width(int level) {
	float step_size = clv.spacing.x * float(1 << level);
	float half_extent = 0.5 * float(max(clv.control.x - 3, 2)) * step_size;
	return max(2.0 * step_size, 0.15 * half_extent);
}

void main() {
	ivec2 local_pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 pixel = local_pixel + page.dispatch_rect.xy;
	if (any(greaterThanEqual(local_pixel, page.dispatch_rect.zw))) { return; }
	ivec2 extent = textureSize(depth_buffer, 0);
	if (any(lessThan(pixel, ivec2(0))) || any(greaterThanEqual(pixel, extent))) { return; }
	imageStore(gi_output, pixel, vec4(0.0));
	bool capture_stats = int(round(pc.parameters.w)) == MAGICDAWN_STATS_CAPTURE;
	if (capture_stats) { atomicAdd(magicdawn_stats.counts[0], 1u); }
	if (clv.control.w != MAGIC_GI_CLV_BAKED_SH_LAYOUT_VERSION
			|| !(clv.spacing.x > 0.0) || params.control.x <= 0.0
			|| params.control.z <= 0.5
			|| pc.parameters.x <= 0.0 || pc.parameters.y <= 0.0) { return; }
	if (any(isnan(clv.codec)) || any(isinf(clv.codec)) || !(clv.codec.x > 0.0)
			|| !(clv.codec.y > 0.0) || abs(clv.codec.x * clv.codec.y - 1.0) > 2e-6
			|| !(clv.codec.z == 16.0 || clv.codec.z == 32.0) || clv.codec.w != 1.0
			|| (clv.codec.z == 32.0 && (clv.codec.x != 1.0 || clv.codec.y != 1.0))) { return; }
	float depth = texelFetch(depth_buffer, pixel, 0).r;
	if (!(depth > 0.0) || isnan(depth) || isinf(depth)) { return; }
	vec4 orm = texelFetch(gbuffer_orm, pixel, 0);
	uint packed_metadata = uint(round(clamp(orm.a, 0.0, 1.0) * 255.0));
	if ((packed_metadata & 0x0fu) == 0u) { return; }
	if (capture_stats) { atomicAdd(magicdawn_stats.counts[1], 1u); }
	vec2 uv = (vec2(pixel) + vec2(0.5)) / vec2(extent);
	vec4 clip = vec4(uv * 2.0 - 1.0, depth, 1.0);
	vec4 view_h = params.inverse_projection * clip;
	if (any(isnan(view_h)) || any(isinf(view_h)) || abs(view_h.w) < 1e-7) { return; }
	vec3 view_position = view_h.xyz / view_h.w;
	vec4 world_h = params.view_to_world * vec4(view_position, 1.0);
	if (any(isnan(world_h)) || any(isinf(world_h)) || abs(world_h.w) < 1e-7) { return; }
	vec3 world = world_h.xyz / world_h.w;
	if (!magicdawn_finite3(world)) { return; }
	if (page.core_min_enabled.w > 0.5 && (any(lessThan(world, page.core_min_enabled.xyz))
			|| any(greaterThanEqual(world, page.core_max.xyz)))) { return; }
	if (page.owner_size_enabled.w > 0.5) {
		vec3 owner_local = (page.owner_world_to_local * vec4(world, 1.0)).xyz;
		if (any(greaterThan(abs(owner_local), page.owner_size_enabled.xyz * 0.5))) { return; }
	}
	vec3 normal_view = texelFetch(normal_roughness, pixel, 0).xyz * 2.0 - 1.0;
	float normal_length_squared = dot(normal_view, normal_view);
	if (!(normal_length_squared > 1e-12) || isnan(normal_length_squared)
			|| isinf(normal_length_squared)) { return; }
	normal_view *= inversesqrt(normal_length_squared);
	vec3 normal_world = mat3(params.view_to_world) * normal_view;
	float world_normal_length_squared = dot(normal_world, normal_world);
	if (!(world_normal_length_squared > 1e-12) || isnan(world_normal_length_squared)
			|| isinf(world_normal_length_squared)) { return; }
	normal_world *= inversesqrt(world_normal_length_squared);
	if (capture_stats) { atomicAdd(magicdawn_stats.counts[2], 1u); }

	int level_count = clamp(clv.control.y, 1, MAGIC_GI_CLV_BAKED_SH_LEVEL_COUNT);
	int fine_level = -1;
	float fine_edge_distance = 0.0;
	for (int level = 0; level < level_count; level++) {
		bool level_in_window;
		float edge_distance = magicdawn_level_edge_distance(world, level, level_in_window);
		if (level_in_window) {
			fine_level = level;
			fine_edge_distance = edge_distance;
			break;
		}
	}
	if (fine_level < 0) {
		if (capture_stats) { atomicAdd(magicdawn_stats.counts[4], 1u); }
		return;
	}
	float coarse_weight = 0.0;
	float outer_weight = 1.0;
	bool in_transition = false;
	bool outer_fade = false;
	float fade_width = magicdawn_level_fade_width(fine_level);
	bool coarse_in_window = false;
	if (fine_level + 1 < level_count) {
		magicdawn_level_edge_distance(world, fine_level + 1, coarse_in_window);
		if (fine_edge_distance < fade_width && coarse_in_window) {
			coarse_weight = 1.0 - smoothstep(0.0, fade_width, fine_edge_distance);
			in_transition = coarse_weight > 0.0;
		} else if (fine_edge_distance < fade_width) {
			// No coarser field covers this boundary, so fade the fine field to
			// zero over the same band instead of cutting it off at the ring edge.
			outer_weight = smoothstep(0.0, fade_width, fine_edge_distance);
			outer_fade = outer_weight < 1.0;
		}
	} else {
		// The last clipmap has no coarser neighbor. Its actual origin window,
		// rather than a camera-centered radius, defines the smooth outer fade.
		outer_weight = smoothstep(0.0, fade_width, fine_edge_distance);
		outer_fade = outer_weight < 1.0;
	}

	int axis_tag = magicdawn_axis_tag(normal_world);
	vec3 fine_incident;
	float fine_coverage;
	bool fine_valid = magicdawn_sample_level(world, normal_world, axis_tag, fine_level,
			fine_incident, fine_coverage);
	vec3 incident = fine_valid ? fine_incident : vec3(0.0);
	float sampled_coverage = fine_valid ? fine_coverage : 0.0;
	if (in_transition && coarse_weight > 0.0) {
		vec3 coarse_incident;
		float coarse_coverage;
		bool coarse_valid = magicdawn_sample_level(world, normal_world, axis_tag, fine_level + 1,
				coarse_incident, coarse_coverage);
		if (!coarse_valid) {
			coarse_incident = vec3(0.0);
			coarse_coverage = 0.0;
		}
		incident = mix(incident, coarse_incident, coarse_weight);
		sampled_coverage = mix(sampled_coverage, coarse_coverage, coarse_weight);
		if (capture_stats) { atomicAdd(magicdawn_stats.counts[6], 1u); }
	} else if (capture_stats) {
		atomicAdd(magicdawn_stats.counts[5], 1u);
	}
	bool normalize_valid_qa = int(round(pc.parameters.z)) == 3;
	bool outer_only_sky_qa = int(round(pc.parameters.z)) == 4;
	float sky_ownership_coverage = sampled_coverage;
	if (normalize_valid_qa) {
		if (sampled_coverage > 0.0) {
			// Normalize the fine/coarse premultiplied SH by its matching
			// pre-outer valid weight; mode 3 keeps the mode-0 sample position.
			incident /= sampled_coverage;
			sky_ownership_coverage = 1.0;
		} else {
			// c=0 remains a strict fallback: no invented SH or Sky ownership.
			incident = vec3(0.0);
			sky_ownership_coverage = 0.0;
		}
	}
	if (outer_only_sky_qa) {
		// Diagnostic only: remove Sky by owner/outer weight, not ready coverage.
		sky_ownership_coverage = 1.0;
	}
	incident *= outer_weight;
	// Decode coefficients after the fine/coarse blend. The raw valid coverage
	// remains available for diagnostics; mode 3 uses independent outer ownership.
	incident *= clv.codec.x;
	sampled_coverage *= outer_weight;
	sky_ownership_coverage *= outer_weight;
	if (capture_stats) {
		atomicAdd(magicdawn_stats.counts[sampled_coverage > 0.0 ? 3 : 4], 1u);
	}
	if (capture_stats && outer_fade) { atomicAdd(magicdawn_stats.counts[7], 1u); }
	if (!magicdawn_finite3(incident)) { return; }
	incident = max(incident, vec3(0.0));
	vec3 albedo = max(texelFetch(gbuffer_albedo, pixel, 0).rgb, vec3(0.0));
	float ao = clamp(orm.r, 0.0, 1.0);
	float metallic = clamp(orm.b, 0.0, 1.0);
	float strength = max(params.control.x * pc.parameters.x, 0.0);
	// Baked data is linear radiance. Apply the frame's pre-exposure exactly once,
	// here at the existing post-lighting tail boundary.
	vec3 contribution = incident * albedo * (1.0 - metallic) * ao
			* strength * pc.parameters.y;
	vec4 scene_color = imageLoad(color_image, pixel);
	// Modes 0–3 remove unoccluded native Sky by the matching ready fraction;
	// mode 4 diagnoses owner/outer subtraction independent of that fraction.
	float sky_ownership = clamp(strength, 0.0, 1.0) *
			sky_ownership_coverage;
	if (sky_ownership > 0.0) {
		scene_color.rgb -= texelFetch(sky_light_diffuse_buffer, pixel, 0).rgb * sky_ownership;
	}
	imageStore(color_image, pixel, vec4(scene_color.rgb + contribution, scene_color.a));
	imageStore(gi_output, pixel, vec4(contribution, sampled_coverage));
}
