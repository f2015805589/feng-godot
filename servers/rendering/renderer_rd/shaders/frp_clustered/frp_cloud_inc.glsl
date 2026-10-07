layout(set = 1, binding = 42) uniform texture2D frp_cloud_sun0_shadow;
layout(set = 1, binding = 43) uniform texture2D frp_cloud_sun1_shadow;
layout(set = 1, binding = 44) uniform texture2D frp_cloud_sky_ao;
layout(set = 1, binding = 48) uniform texture2D frp_cloud_sky_ao_stats;

vec3 frp_cloud_world_position(vec3 p_view_position, SceneData p_scene_data) {
	mat4 inv_view = transpose(mat4(p_scene_data.inv_view_matrix[0], p_scene_data.inv_view_matrix[1], p_scene_data.inv_view_matrix[2], vec4(0.0, 0.0, 0.0, 1.0)));
	// The view-relative position was reconstructed from the inverse view-projection
	// that already includes the per-eye view offset. Transform it with the base view.
	vec3 world_position = (inv_view * vec4(p_view_position, 1.0)).xyz;
#ifdef USE_DOUBLE_PRECISION
	world_position += p_scene_data.inv_view_precision.xyz;
#endif
	return world_position;
}

bool frp_cloud_project_position(vec3 p_world_position, uint p_matrix_index, float p_far_depth_km, out vec2 r_uv, out float r_depth_km) {
	uint base = p_matrix_index * 4u;
	mat4 world_to_cloud = mat4(
		implementation_data.cloud_projection_parameters[base + 0u],
		implementation_data.cloud_projection_parameters[base + 1u],
		implementation_data.cloud_projection_parameters[base + 2u],
		implementation_data.cloud_projection_parameters[base + 3u]);
	vec4 projected = world_to_cloud * vec4(p_world_position, 1.0);
	if (!(projected.w > 0.0) || isnan(projected.w) || isinf(projected.w)) {
		return false;
	}
	vec3 ndc = projected.xyz / projected.w;
	if (any(lessThan(ndc.xy, vec2(-1.0))) || any(greaterThan(ndc.xy, vec2(1.0))) || ndc.z < 0.0 || ndc.z > 1.0) {
		return false;
	}
	r_uv = ndc.xy * 0.5 + 0.5;
	r_depth_km = clamp(1.0 - ndc.z, 0.0, 1.0) * max(p_far_depth_km, 0.0);
	return true;
}

float frp_cloud_shadow_visibility(vec4 p_shadow, float p_surface_depth_km, float p_surface_strength) {
	// Validity is coverage-filtered along with the statistics. Any positive
	// interpolated alpha denotes an overlapping valid sample, including edge taps.
	if (!(p_shadow.a > 0.0) || p_shadow.a > 1.0 || any(isnan(p_shadow)) || any(isinf(p_shadow)) || any(lessThan(p_shadow.rgb, vec3(0.0))) || any(greaterThan(p_shadow.rgb, vec3(65504.0)))) {
		return 1.0;
	}
	float distance_after_cloud = max(0.0, (p_surface_depth_km - max(p_shadow.r, 0.0)) * 1000.0);
	float optical_depth = min(max(p_shadow.b, 0.0), distance_after_cloud * max(p_shadow.g, 0.0));
	float cloud_transmittance = exp(-optical_depth);
	return mix(1.0, cloud_transmittance, clamp(p_surface_strength, 0.0, 1.0));
}

float frp_cloud_directional_shadow_visibility_strength(vec3 p_world_position, uint p_directional_light_index, float p_strength0, float p_strength1) {
	float visibility = 1.0;
	if (implementation_data.cloud_sun_light_indices_flags.z > 0.5 && abs(implementation_data.cloud_sun_light_indices_flags.x - float(p_directional_light_index)) < 0.5 && implementation_data.cloud_projection_parameters[27].x > 0.5) {
		vec2 cloud_uv;
		float surface_depth_km;
		if (frp_cloud_project_position(p_world_position, 0u, implementation_data.cloud_projection_parameters[24].x, cloud_uv, surface_depth_km)) {
			vec4 cloud_shadow = textureLod(sampler2D(frp_cloud_sun0_shadow, SAMPLER_LINEAR_CLAMP), cloud_uv, 0.0);
			visibility *= frp_cloud_shadow_visibility(cloud_shadow, surface_depth_km, p_strength0);
		}
	}
	if (implementation_data.cloud_sun_light_indices_flags.w > 0.5 && abs(implementation_data.cloud_sun_light_indices_flags.y - float(p_directional_light_index)) < 0.5 && implementation_data.cloud_projection_parameters[27].y > 0.5) {
		vec2 cloud_uv;
		float surface_depth_km;
		if (frp_cloud_project_position(p_world_position, 1u, implementation_data.cloud_projection_parameters[24].y, cloud_uv, surface_depth_km)) {
			vec4 cloud_shadow = textureLod(sampler2D(frp_cloud_sun1_shadow, SAMPLER_LINEAR_CLAMP), cloud_uv, 0.0);
			visibility *= frp_cloud_shadow_visibility(cloud_shadow, surface_depth_km, p_strength1);
		}
	}
	return visibility;
}

float frp_cloud_directional_shadow_visibility(vec3 p_world_position, uint p_directional_light_index) {
	return frp_cloud_directional_shadow_visibility_strength(
			p_world_position, p_directional_light_index,
			implementation_data.cloud_projection_parameters[26].x,
			implementation_data.cloud_projection_parameters[26].y);
}

float frp_cloud_atmosphere_sun_visibility(vec3 p_world_position, uint p_directional_light_index) {
	return frp_cloud_directional_shadow_visibility_strength(
			p_world_position, p_directional_light_index,
			implementation_data.cloud_projection_parameters[26].z,
			implementation_data.cloud_projection_parameters[26].w);
}

float frp_cloud_atmosphere_slot_visibility(vec3 p_world_position, int p_atmosphere_sun_slot) {
	if (p_atmosphere_sun_slot < 0 || p_atmosphere_sun_slot > 1) {
		return 1.0;
	}
	float cloud_slot_value = p_atmosphere_sun_slot == 0
			? implementation_data.atmosphere_cloud_mapping.x
			: implementation_data.atmosphere_cloud_mapping.y;
	if (cloud_slot_value < 0.0 || cloud_slot_value > 1.0) {
		return 1.0;
	}
	uint cloud_slot = uint(cloud_slot_value + 0.5);
	float map_valid = cloud_slot == 0u
			? implementation_data.atmosphere_cloud_mapping.z
			: implementation_data.atmosphere_cloud_mapping.w;
	if (map_valid <= 0.5 || implementation_data.cloud_projection_parameters[27][cloud_slot] <= 0.5) {
		return 1.0;
	}
	vec2 cloud_uv;
	float sample_depth_km;
	float far_depth_km = cloud_slot == 0u
			? implementation_data.cloud_projection_parameters[24].x
			: implementation_data.cloud_projection_parameters[24].y;
	if (!frp_cloud_project_position(p_world_position, cloud_slot, far_depth_km, cloud_uv, sample_depth_km)) {
		return 1.0;
	}
	vec4 cloud_shadow = cloud_slot == 0u
			? textureLod(sampler2D(frp_cloud_sun0_shadow, SAMPLER_LINEAR_CLAMP), cloud_uv, 0.0)
			: textureLod(sampler2D(frp_cloud_sun1_shadow, SAMPLER_LINEAR_CLAMP), cloud_uv, 0.0);
	float strength = cloud_slot == 0u
			? implementation_data.cloud_projection_parameters[26].z
			: implementation_data.cloud_projection_parameters[26].w;
	return frp_cloud_shadow_visibility(cloud_shadow, sample_depth_km, strength);
}

float frp_cloud_atmosphere_multiple_scattering_visibility(vec3 p_world_position) {
	// .w is the native-validated raw-statistics RID flag. It is intentionally
	// independent from .z, which gates the filtered map used by FengSkyLight.
	if (implementation_data.cloud_projection_parameters[27].w <= 0.5) {
		return 1.0;
	}
	vec2 cloud_ao_uv;
	float cloud_ao_depth_km;
	if (!frp_cloud_project_position(p_world_position, 4u, implementation_data.cloud_projection_parameters[31].x, cloud_ao_uv, cloud_ao_depth_km)) {
		return 1.0;
	}
	vec4 raw_ao = textureLod(sampler2D(frp_cloud_sky_ao_stats, SAMPLER_LINEAR_CLAMP), cloud_ao_uv, 0.0);
	if (!(raw_ao.a > 0.0) || raw_ao.a > 1.0 || any(isnan(raw_ao)) || any(isinf(raw_ao)) || any(lessThan(raw_ao.rgb, vec3(0.0)))) {
		return 1.0;
	}
	float distance_after_cloud_m = max(0.0, (cloud_ao_depth_km - max(raw_ao.r, 0.0)) * 1000.0);
	float optical_depth = min(max(raw_ao.b, 0.0), distance_after_cloud_m * max(raw_ao.g, 0.0));
	return exp(-min(optical_depth, 80.0));
}

float frp_cloud_provider_ao_visibility(vec3 p_world_position) {
	bool has_sky_provider = implementation_data.sky_lighting_enabled != 0u || implementation_data.sky_lighting_pad0 != 0u;
	if (!has_sky_provider || implementation_data.cloud_projection_parameters[27].z <= 0.5) {
		return 1.0;
	}
	vec2 cloud_ao_uv;
	float cloud_ao_depth_km;
	if (!frp_cloud_project_position(p_world_position, 4u, implementation_data.cloud_projection_parameters[31].x, cloud_ao_uv, cloud_ao_depth_km)) {
		return 1.0;
	}
	return clamp(textureLod(sampler2D(frp_cloud_sky_ao, SAMPLER_LINEAR_CLAMP), cloud_ao_uv, 0.0).r, 0.0, 1.0);
}
