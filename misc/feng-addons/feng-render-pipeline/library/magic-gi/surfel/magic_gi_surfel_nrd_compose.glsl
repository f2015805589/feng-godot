#[compute]
#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D depth_texture;
layout(set = 0, binding = 1) uniform sampler2D normal_roughness_texture;
layout(set = 0, binding = 2) uniform sampler2D albedo_texture;
layout(set = 0, binding = 3) uniform sampler2D orm_texture;
layout(set = 0, binding = 4) uniform sampler2D sky_diffuse_texture;
layout(set = 0, binding = 5) uniform sampler2D diffuse_ao_texture;
layout(set = 0, binding = 6) uniform sampler2D denoised_signal;
layout(set = 0, binding = 7) uniform sampler2D raw_signal;
layout(set = 0, binding = 8) uniform sampler2D surfel_auxiliary;
layout(set = 0, binding = 9, rgba16f) uniform image2D scene_color;
layout(set = 0, binding = 10, rgba16f) uniform writeonly image2D gi_output;
layout(set = 0, binding = 11, std140) uniform ComposeParameters {
	mat4 inverse_projection;
	mat4 view_to_world;
	mat4 world_to_owner;
	vec4 owner_half_radius;
	vec4 controls; // Strength, replacement enabled, pre-exposure, scene normalization.
	uvec4 extents; // Full width/height, denoised width/height.
	uvec4 mode; // Debug view, frame token, reserved, reserved.
} params;

const uint MATERIAL_MODEL_MASK = 0x0fu;
const uint UNLIT_MATERIAL_MODEL = 0u;
const float NRD_SIGNAL_INV_SCALE = 1000.0;

bool read_full_geometry(ivec2 p, ivec2 full_size, out vec3 world_position,
		out vec3 world_normal, out vec4 orm) {
	world_position = vec3(0.0);
	world_normal = vec3(0.0);
	orm = vec4(0.0);
	if (any(lessThan(p, ivec2(0))) || any(greaterThanEqual(p, full_size))) return false;
	float depth = texelFetch(depth_texture, p, 0).r;
	if (!(depth > 0.0) || isnan(depth) || isinf(depth)) return false;
	orm = texelFetch(orm_texture, p, 0);
	uint model = uint(round(clamp(orm.a, 0.0, 1.0) * 255.0)) & MATERIAL_MODEL_MASK;
	if (model == UNLIT_MATERIAL_MODEL) return false;
	vec2 uv = (vec2(p) + 0.5) / vec2(full_size);
	vec4 view_h = params.inverse_projection * vec4(uv * 2.0 - 1.0, depth, 1.0);
	if (!(abs(view_h.w) > 1.0e-8) || isnan(view_h.w) || isinf(view_h.w)) return false;
	vec3 view_position = view_h.xyz / view_h.w;
	world_position = (params.view_to_world * vec4(view_position, 1.0)).xyz;
	if (any(isnan(world_position)) || any(isinf(world_position))) return false;
	vec3 owner_local = (params.world_to_owner * vec4(world_position, 1.0)).xyz;
	vec3 half_extent = params.owner_half_radius.xyz;
	vec3 epsilon = max(half_extent, vec3(1.0)) * 1.9073486328125e-6;
	if (any(greaterThan(abs(owner_local), half_extent + epsilon))) return false;
	vec3 normal_encoded = texelFetch(normal_roughness_texture, p, 0).xyz * 2.0 - 1.0;
	float normal_length = length(normal_encoded);
	if (!(normal_length > 1.0e-6) || isnan(normal_length) || isinf(normal_length)) return false;
	vec3 view_normal = normal_encoded / normal_length;
	world_normal = normalize(mat3(params.view_to_world) * view_normal);
	return all(not(isnan(world_normal))) && all(not(isinf(world_normal)));
}

bool compatible_guide(vec3 center_position, vec3 center_normal, vec3 guide_position,
		vec3 guide_normal) {
	if (dot(center_normal, guide_normal) < 0.995) return false;
	float plane_tolerance = max(0.0005, 0.05 * params.owner_half_radius.w);
	return abs(dot(guide_position - center_position, center_normal)) <= plane_tolerance
			&& abs(dot(center_position - guide_position, guide_normal)) <= plane_tolerance;
}

bool has_complete_zero_raw_platform(ivec2 center_half, ivec2 half_size,
		ivec2 full_size, vec3 center_position, vec3 center_normal) {
	int support_count = 0;
	for (int oy = -1; oy <= 1; oy++) {
		for (int ox = -1; ox <= 1; ox++) {
			ivec2 q = center_half + ivec2(ox, oy);
			if (any(lessThan(q, ivec2(0))) || any(greaterThanEqual(q, half_size))) continue;
			ivec2 guide = min(ivec2((vec2(q) + 0.5) / vec2(half_size)
					* vec2(full_size)), full_size - ivec2(1));
			vec3 guide_position;
			vec3 guide_normal;
			vec4 guide_orm;
			if (!read_full_geometry(guide, full_size, guide_position, guide_normal, guide_orm)
					|| !compatible_guide(center_position, center_normal,
						guide_position, guide_normal)) continue;
			vec4 auxiliary = texelFetch(surfel_auxiliary, q, 0);
			vec4 raw = texelFetch(raw_signal, q, 0);
			if (!all(not(isnan(auxiliary))) || !all(not(isinf(auxiliary)))
					|| !all(not(isnan(raw))) || !all(not(isinf(raw)))) return false;
			if (!(auxiliary.z > 0.5) || !(raw.a >= 0.999)
					|| !all(equal(raw.rgb, vec3(0.0)))) return false;
			support_count++;
		}
	}
	return support_count >= 4;
}

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	ivec2 full_size = imageSize(scene_color);
	if (any(greaterThanEqual(p, full_size))) return;
	imageStore(gi_output, p, vec4(0.0));
	vec3 world_position;
	vec3 world_normal;
	vec4 orm;
	if (!read_full_geometry(p, full_size, world_position, world_normal, orm)) return;
	ivec2 half_size = ivec2(params.extents.zw);
	vec2 denoised_position = ((vec2(p) + 0.5) / vec2(full_size)) * vec2(half_size) - 0.5;
	ivec2 base = ivec2(floor(denoised_position));
	vec2 fraction = fract(denoised_position);
	vec3 incident_sum = vec3(0.0);
	float coverage_sum = 0.0;
	float age_sum = 0.0;
	float weight_sum = 0.0;
	bool complete_zero_taps = true;
	for (int oy = 0; oy < 2; oy++) {
		for (int ox = 0; ox < 2; ox++) {
			ivec2 q = base + ivec2(ox, oy);
			if (any(lessThan(q, ivec2(0))) || any(greaterThanEqual(q, half_size))) continue;
			vec4 auxiliary = texelFetch(surfel_auxiliary, q, 0);
			vec4 raw = texelFetch(raw_signal, q, 0);
			if (!(auxiliary.z > 0.5) || !(raw.a > 0.0)) continue;
			ivec2 guide = min(ivec2((vec2(q) + 0.5) / vec2(half_size)
					* vec2(full_size)), full_size - ivec2(1));
			vec3 guide_position;
			vec3 guide_normal;
			vec4 guide_orm;
			if (!read_full_geometry(guide, full_size, guide_position, guide_normal, guide_orm)
					|| !compatible_guide(world_position, world_normal,
						guide_position, guide_normal)) continue;
			float wx = ox == 0 ? 1.0 - fraction.x : fraction.x;
			float wy = oy == 0 ? 1.0 - fraction.y : fraction.y;
			float weight = wx * wy;
			if (!(weight > 0.0)) continue;
			vec3 signal = texelFetch(denoised_signal, q, 0).rgb * NRD_SIGNAL_INV_SCALE;
			if (any(isnan(signal)) || any(isinf(signal))) continue;
			bool finite_support = all(not(isnan(raw))) && all(not(isinf(raw)))
					&& all(not(isnan(auxiliary))) && all(not(isinf(auxiliary)));
			if (!finite_support || raw.a < 0.999 || !all(equal(raw.rgb, vec3(0.0)))) {
				complete_zero_taps = false;
			}
			incident_sum += max(signal, vec3(0.0)) * weight;
			coverage_sum += clamp(raw.a, 0.0, 1.0) * weight;
			age_sum += max(auxiliary.y, 0.0) * weight;
			weight_sum += weight;
		}
	}
	if (!(weight_sum > 1.0e-6)) return;
	vec3 incident = incident_sum / weight_sum;
	float coverage = clamp(coverage_sum / weight_sum, 0.0, 1.0);
	float age = age_sum / weight_sum;
	if (!(coverage > 0.0)) return;
	if (complete_zero_taps && coverage >= 0.999
			&& any(greaterThan(incident, vec3(0.0)))) {
		ivec2 nearest_half = ivec2(floor(denoised_position + vec2(0.5)));
		if (has_complete_zero_raw_platform(nearest_half, half_size, full_size,
				world_position, world_normal)) incident = vec3(0.0);
	}
	float ao = clamp(orm.r, 0.0, 1.0);
	float diffuse_ao = textureLod(diffuse_ao_texture,
		(vec2(p) + 0.5) / vec2(full_size), 0.0).r;
	if (isnan(diffuse_ao) || isinf(diffuse_ao)) diffuse_ao = 1.0;
	vec3 albedo = max(texelFetch(albedo_texture, p, 0).rgb, vec3(0.0));
	float metallic = clamp(orm.b, 0.0, 1.0);
	vec3 contribution = incident * albedo * (1.0 - metallic) * ao
			* clamp(diffuse_ao, 0.0, 1.0) * max(params.controls.x, 0.0) * coverage
			* max(params.controls.z, 0.0) * max(params.controls.w, 0.0);
	float ownership = params.controls.y > 0.5
			? clamp(params.controls.x, 0.0, 1.0) * coverage : 0.0;
	vec4 scene = imageLoad(scene_color, p);
	if (ownership > 0.0) {
		vec3 sky = texelFetch(sky_diffuse_texture, p, 0).rgb;
		scene.rgb -= sky * ownership;
	}
	imageStore(scene_color, p, vec4(scene.rgb + contribution, scene.a));
	vec3 sidecar = contribution;
	if (params.mode.x == 1u) {
		sidecar = incident / (vec3(1.0) + incident);
	} else if (params.mode.x == 2u) {
		sidecar = vec3(coverage, 1.0 - coverage, 0.15);
	} else if (params.mode.x >= 3u) {
		float age_fraction = clamp(age / 600.0, 0.0, 1.0);
		sidecar = vec3(age_fraction, 1.0 - age_fraction, 0.1);
	}
	imageStore(gi_output, p, vec4(sidecar, ownership));
}
