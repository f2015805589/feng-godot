#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D depth_buffer;

layout(set = 0, binding = 2, std140) uniform FogParams {
	mat4 inverse_view_projection;
	vec4 camera_position;
	vec4 exponential_fog_parameters; // x = GlobalDensity, y = FogHeightFalloff, z = MaxObserverHeight, w = StartDistance.
	vec4 exponential_fog_parameters2; // x = GlobalDensitySecond, y = FogHeightFalloffSecond, z = FogDensitySecond, w = FogHeightSecond.
	vec4 exponential_fog_parameters3; // x = FogDensity, y = FogHeight, z = unused, w = FogCutoffDistance.
	vec4 exponential_fog_color; // rgb = FogInscatteringColor, a = MinFogOpacity (1 - FogMaxOpacity).
	vec4 inscattering_light_direction; // xyz = direction toward sun, w = DirectionalInscatteringStartDistance or -1 when disabled.
	vec4 directional_inscattering_color; // rgb = inscattering color premultiplied by sun luminance, w = DirectionalInscatteringExponent.
} params;

layout(push_constant, std430) uniform PassParameters {
	vec4 parameters;
} pc;

const float FLT_EPSILON2 = 0.01;
const float SKY_DISTANCE = 1000000.0;

// Line integral of d = GlobalDensity * exp2(-HeightFalloff * (y - Height)) along
// the ray, expressed as the shared factor the caller multiplies by ray length.
// Ported from Unreal's HeightFogCommon.ush CalculateLineIntegralShared.
float line_integral_shared(float height_falloff, float ray_delta_y, float origin_terms) {
	float falloff = max(-127.0, height_falloff * ray_delta_y);
	float line_integral = (1.0 - exp2(-falloff)) / falloff;
	float line_integral_taylor = log(2.0) - 0.5 * log(2.0) * log(2.0) * falloff;
	return origin_terms * (abs(falloff) > FLT_EPSILON2 ? line_integral : line_integral_taylor);
}

// Ported from Unreal's GetExponentialHeightFog: returns (fogged rgb, fog factor).
// camera_to_receiver is (WorldPosition - camera) before the observer-height
// compensation below.
vec4 get_exponential_height_fog(vec3 camera_to_receiver) {
	const float min_fog_opacity = params.exponential_fog_color.w;
	const float max_world_observer_height = params.exponential_fog_parameters.z;

	// Unreal clamps the observer height (WorldObserverOrigin) relative to the
	// fog height, then shifts CameraToReceiver.z to compensate: the fog stays
	// world-anchored instead of thinning toward zero as the camera rises.
	const float observer_y = min(params.camera_position.y, max_world_observer_height);
	camera_to_receiver.y += params.camera_position.y - observer_y;

	float camera_to_receiver_length_sqr = dot(camera_to_receiver, camera_to_receiver);
	float camera_to_receiver_length_inv = inversesqrt(camera_to_receiver_length_sqr);
	float camera_to_receiver_length = camera_to_receiver_length_sqr * camera_to_receiver_length_inv;
	vec3 camera_to_receiver_normalized = camera_to_receiver * camera_to_receiver_length_inv;

	float ray_origin_terms = params.exponential_fog_parameters.x;
	float ray_origin_terms_second = params.exponential_fog_parameters2.x;
	float ray_length = camera_to_receiver_length;
	float ray_direction_y = camera_to_receiver.y;

	// Factor in StartDistance: fog starts accumulating only past the exclusion
	// plane, so the line integral is restarted at the exclusion point.
	float exclude_distance = params.exponential_fog_parameters.w;
	if (exclude_distance > 0.0) {
		float exclude_intersection_time = exclude_distance * camera_to_receiver_length_inv;
		float camera_exclusion_intersection_y = exclude_intersection_time * camera_to_receiver.y;
		float exclusion_intersection_world_y = observer_y + camera_exclusion_intersection_y;
		float exclusion_intersection_to_receiver_y = camera_to_receiver.y - camera_exclusion_intersection_y;
		ray_length = (1.0 - exclude_intersection_time) * camera_to_receiver_length;
		ray_direction_y = exclusion_intersection_to_receiver_y;

		float exponent = max(-127.0, params.exponential_fog_parameters.y * (exclusion_intersection_world_y - params.exponential_fog_parameters3.y));
		ray_origin_terms = params.exponential_fog_parameters3.x * exp2(-exponent);
		float exponent_second = max(-127.0, params.exponential_fog_parameters2.y * (exclusion_intersection_world_y - params.exponential_fog_parameters2.w));
		ray_origin_terms_second = params.exponential_fog_parameters2.z * exp2(-exponent_second);
	}

	// Sum of the two fog layers' shared line integrals.
	float exponential_height_line_integral_shared = max(pc.parameters.x, 0.0) * (
		line_integral_shared(params.exponential_fog_parameters.y, ray_direction_y, ray_origin_terms)
		+ line_integral_shared(params.exponential_fog_parameters2.y, ray_direction_y, ray_origin_terms_second));
	float exponential_height_line_integral = exponential_height_line_integral_shared * ray_length;

	vec3 directional_inscattering = vec3(0.0);
	// InscatteringLightDirection.w is negative when the sun term is disabled.
	if (params.inscattering_light_direction.w >= 0.0) {
		float directional_inscattering_start_distance = params.inscattering_light_direction.w;
		// Cosine lobe around the light direction approximating inscattering
		// from the directional light off the ambient haze.
		vec3 directional_light_inscattering = params.directional_inscattering_color.rgb
				* pow(clamp(dot(camera_to_receiver_normalized, params.inscattering_light_direction.xyz), 0.0, 1.0),
						params.directional_inscattering_color.w);
		// Line integral of the eye ray through the haze, using a special
		// starting distance to limit the inscattering to the distance.
		float dir_exponential_height_line_integral = exponential_height_line_integral_shared
				* max(ray_length - directional_inscattering_start_distance, 0.0);
		float directional_inscattering_fog_factor = clamp(exp2(-dir_exponential_height_line_integral), 0.0, 1.0);
		directional_inscattering = directional_light_inscattering * (1.0 - directional_inscattering_fog_factor);
	}

	float exp_fog_factor = max(clamp(exp2(-exponential_height_line_integral), 0.0, 1.0), min_fog_opacity);

	// FogCutoffDistance removes fog (and the sun lobe) past a fixed distance.
	float cutoff_distance = params.exponential_fog_parameters3.w;
	if (cutoff_distance > 0.0 && camera_to_receiver_length > cutoff_distance) {
		exp_fog_factor = 1.0;
		directional_inscattering = vec3(0.0);
	}

	return vec4(params.exponential_fog_color.rgb * (1.0 - exp_fog_factor) + directional_inscattering, exp_fog_factor);
}

vec3 world_from_clip(vec2 uv, float depth) {
	vec4 clip = vec4(uv * 2.0 - 1.0, depth, 1.0);
	vec4 world_h = params.inverse_view_projection * clip;
	if (abs(world_h.w) < 1e-7) {
		return vec3(0.0);
	}
	return world_h.xyz / world_h.w;
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 extent = imageSize(color_image);
	if (any(greaterThanEqual(pixel, extent))) {
		return;
	}

	vec2 screen_uv = (vec2(pixel) + vec2(0.5)) / vec2(extent);
	vec3 camera_position = params.camera_position.xyz;
	vec3 camera_to_receiver;
	float depth = texelFetch(depth_buffer, pixel, 0).r;
	if (depth <= 0.0) {
		// Sky pixel: fog along a very long ray, matching Unreal's treatment of
		// the sky as a receiver at effectively infinite distance. The far plane
		// sits at clip z = 0 under this projection; 0.5 lands near the guard
		// region and reconstructs a degenerate point.
		vec3 direction = normalize(world_from_clip(screen_uv, 0.0) - camera_position);
		camera_to_receiver = direction * SKY_DISTANCE;
	} else {
		camera_to_receiver = world_from_clip(screen_uv, depth) - camera_position;
	}

	vec4 fog = get_exponential_height_fog(camera_to_receiver);
	vec4 scene_color = imageLoad(color_image, pixel);
	imageStore(color_image, pixel, vec4(fog.rgb + scene_color.rgb * fog.a, scene_color.a));
}
