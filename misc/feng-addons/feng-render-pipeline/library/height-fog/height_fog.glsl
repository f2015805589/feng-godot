#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D depth_buffer;

layout(set = 0, binding = 2, std140) uniform FogParams {
	mat4 inverse_projection;
	mat4 view_to_world;
	vec4 camera_position;
	vec4 exponential_fog_parameters; // x = GlobalDensity at ObserverY, y = FogHeightFalloff, z = ObserverY, w = StartDistance.
	vec4 exponential_fog_parameters2; // x = GlobalDensitySecond, y = FogHeightFalloffSecond, z = FogDensitySecond, w = FogHeightSecond.
	vec4 exponential_fog_parameters3; // x = FogDensity, y = FogHeight, z = unused, w = FogCutoffDistance.
	vec4 exponential_fog_color; // rgb = FogInscatteringColor, a = MinFogOpacity (1 - FogMaxOpacity).
	vec4 inscattering_light_direction; // xyz = direction toward sun, w = DirectionalInscatteringStartDistance or -1 when disabled.
	vec4 directional_inscattering_color; // rgb = inscattering color premultiplied by sun luminance, w = DirectionalInscatteringExponent.
	vec4 atmosphere_parameters[16];
} params;

layout(set = 0, binding = 3) uniform sampler2D atmosphere_optical_texture;
layout(set = 0, binding = 4) uniform sampler2D atmosphere_multiple_texture;
#define ATMO_PARAMS params.atmosphere_parameters
#define ATMO_OPTICAL atmosphere_optical_texture
#define ATMO_MULTIPLE atmosphere_multiple_texture
#include "atmosphere_inc.glslinc"
#undef ATMO_PARAMS
#undef ATMO_OPTICAL
#undef ATMO_MULTIPLE

layout(push_constant, std430) uniform PassParameters {
	vec4 parameters;
} pc;

const float FLT_EPSILON2 = 0.01;
const float SKY_DISTANCE = 1000000.0;
// UE 5.7's default SkyAtmosphere-affects-height-fog branch uses a uniform
// phase normalization with its cosine lobe (HeightFogCommon.ush).
const float UNIFORM_PHASE_FUNCTION = 0.07957747154594767; // 1 / (4 * PI).

float default_directional_phase(vec3 ray_direction, vec3 sun_direction, float exponent) {
	return pow(clamp(dot(ray_direction, sun_direction), 0.0, 1.0), exponent) * UNIFORM_PHASE_FUNCTION;
}

// Reserved for UE's PROJECT_EXPFOG_MATCHES_VFOG path. That path also changes
// the light source, start distance, and albedo, so do not select HG alone.
// UE's PBRT convention takes cos(-ray_direction, sun_direction).
float henyey_greenstein_phase(float g, float cos_theta) {
	g = clamp(g, -0.99, 0.99);
	float denominator = 1.0 + g * g + 2.0 * g * cos_theta;
	return (1.0 - g * g) * UNIFORM_PHASE_FUNCTION / (denominator * sqrt(denominator));
}

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
// camera_to_receiver is (WorldPosition - camera).
vec4 get_exponential_height_fog(vec3 camera_to_receiver) {
	const float min_fog_opacity = params.exponential_fog_color.w;
	float observer_y = params.exponential_fog_parameters.z;
	// Unreal caps perspective observers above the active fog layers. Rebase the
	// ray before distance, phase, start-distance, and extinction calculations;
	// the endpoint remains fixed, including for the depth-zero sky ray.
	camera_to_receiver.y += params.camera_position.y - observer_y;

	float camera_to_receiver_length_sqr = dot(camera_to_receiver, camera_to_receiver);
	float camera_to_receiver_length_inv = inversesqrt(max(camera_to_receiver_length_sqr, 1e-8));
	float camera_to_receiver_length = camera_to_receiver_length_sqr * camera_to_receiver_length_inv;
	if (camera_to_receiver_length <= params.exponential_fog_parameters.w) {
		return vec4(0.0, 0.0, 0.0, 1.0);
	}
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
		// UE's default branch uses the cosine lobe normalized by 1 / (4 * PI).
		// The published RGB combines the artist light term with matching
		// SkyAtmosphere ground illuminance; both use this directional phase.
		vec3 directional_light_inscattering = params.directional_inscattering_color.rgb
				* default_directional_phase(camera_to_receiver_normalized,
						params.inscattering_light_direction.xyz, params.directional_inscattering_color.w);
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

vec3 view_from_clip(vec2 uv, float depth) {
	vec4 clip = vec4(uv * 2.0 - 1.0, depth, 1.0);
	vec4 view_h = params.inverse_projection * clip;
	if (abs(view_h.w) < 1e-7) {
		return vec3(0.0);
	}
	return view_h.xyz / view_h.w;
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 extent = imageSize(color_image);
	if (any(greaterThanEqual(pixel, extent))) {
		return;
	}

	vec2 screen_uv = (vec2(pixel) + vec2(0.5)) / vec2(extent);
	vec3 camera_to_receiver;
	float depth = texelFetch(depth_buffer, pixel, 0).r;
	if (depth <= 0.0) {
		// Reverse-Z depth zero is the infinite far plane and cannot be divided
		// by homogeneous w. Subtract finite depths in view space before camera
		// translation; subtracting nearby world positions loses ray precision
		// when the camera is far from the world origin.
		vec3 view_direction = normalize(view_from_clip(screen_uv, 0.5) - view_from_clip(screen_uv, 1.0));
		vec3 direction = normalize(mat3(params.view_to_world) * view_direction);
		camera_to_receiver = direction * SKY_DISTANCE;
	} else {
		// The fog integral takes a camera-relative ray, so no world-position
		// reconstruction or large world-coordinate subtraction is needed.
		camera_to_receiver = mat3(params.view_to_world) * view_from_clip(screen_uv, depth);
	}

	vec4 fog = get_exponential_height_fog(camera_to_receiver);
	vec4 scene_color = imageLoad(color_image, pixel);
	// Background sky has already traversed the whole atmosphere. Only surfaces
	// need aerial perspective; fog still retains its authored sky contribution.
	if (depth > 0.0 && params.atmosphere_parameters[12].z > 0.5) {
		vec3 atmospheric_radiance;
		vec3 atmospheric_transmission;
		frp_atmo_aerial(camera_to_receiver, vec3(0.0), atmospheric_radiance, atmospheric_transmission);
		scene_color.rgb = scene_color.rgb * atmospheric_transmission + atmospheric_radiance * pc.parameters.y;
	}
	vec3 fogged_rgb = fog.rgb * pc.parameters.y + scene_color.rgb * fog.a;
	fogged_rgb = mix(fogged_rgb, vec3(0.0), isnan(fogged_rgb));
	fogged_rgb = clamp(fogged_rgb, vec3(-65504.0), vec3(65504.0));
	imageStore(color_image, pixel, vec4(fogged_rgb, scene_color.a));
}
