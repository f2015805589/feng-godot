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
layout(set = 0, binding = 5, std140) uniform CloudVisibilityData {
	vec4 projection[35];
	vec4 sun_mapping; // atmosphere sun 0/1 -> cloud slot, then cloud-map validity.
	vec4 flags; // raw AO validity, reserved.
} cloud_visibility;
layout(set = 0, binding = 6) uniform sampler2D cloud_shadow0_texture;
layout(set = 0, binding = 7) uniform sampler2D cloud_shadow1_texture;
layout(set = 0, binding = 8) uniform sampler2D cloud_raw_ao_texture;
#include "height_fog_cloud_visibility.glslinc"

#define FRP_ATMO_CLOUD_SHADOW_VISIBILITY(world_position_m, atmo_sun_slot) frp_height_fog_cloud_shadow_visibility(world_position_m, atmo_sun_slot)
#define FRP_ATMO_CLOUD_MULTIPLE_VISIBILITY(world_position_m) frp_height_fog_cloud_multiple_visibility(world_position_m)
#define ATMO_PARAMS params.atmosphere_parameters
#define ATMO_OPTICAL atmosphere_optical_texture
#define ATMO_MULTIPLE atmosphere_multiple_texture
#include "atmosphere_inc.glslinc"
#undef FRP_ATMO_CLOUD_SHADOW_VISIBILITY
#undef FRP_ATMO_CLOUD_MULTIPLE_VISIBILITY
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
#include "volumetric_fog_sampling.glslinc"
#include "exponential_height_fog.glslinc"

// Ported from Unreal's GetExponentialHeightFog: returns (fogged rgb, fog factor).
// camera_to_receiver is (WorldPosition - camera).
vec4 get_exponential_height_fog(vec3 camera_to_receiver, float view_ray_cosine) {
	return frp_evaluate_exponential_height_fog(camera_to_receiver, view_ray_cosine,
			params.camera_position.xyz, params.exponential_fog_parameters,
			params.exponential_fog_parameters2, params.exponential_fog_parameters3,
			params.exponential_fog_color, params.inscattering_light_direction,
			params.directional_inscattering_color, pc.parameters.x,
			feng_volume_sampling.analytic_control.x,
			feng_volume_sampling.analytic_control.y);
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
	float view_ray_cosine;
	float depth = texelFetch(depth_buffer, pixel, 0).r;
	if (depth <= 0.0) {
		// Reverse-Z depth zero is the infinite far plane and cannot be divided
		// by homogeneous w. Subtract finite depths in view space before camera
		// translation; subtracting nearby world positions loses ray precision
		// when the camera is far from the world origin.
		vec3 view_direction = normalize(view_from_clip(screen_uv, 0.5) - view_from_clip(screen_uv, 1.0));
		vec3 direction = normalize(mat3(params.view_to_world) * view_direction);
		camera_to_receiver = direction * SKY_DISTANCE;
		view_ray_cosine = abs(view_direction.z);
	} else {
		// The fog integral takes a camera-relative ray, so no world-position
		// reconstruction or large world-coordinate subtraction is needed.
		vec3 view_position = view_from_clip(screen_uv, depth);
		view_ray_cosine = abs(view_position.z) / max(length(view_position), 1.0e-6);
		camera_to_receiver = mat3(params.view_to_world) * view_position;
	}

	vec4 fog = get_exponential_height_fog(camera_to_receiver, view_ray_cosine);
	vec4 scene_color = imageLoad(color_image, pixel);
	// Background sky has already traversed the whole atmosphere. Only surfaces
	// need aerial perspective; fog still retains its authored sky contribution.
	if (depth > 0.0 && params.atmosphere_parameters[12].z > 0.5) {
		vec3 atmospheric_radiance;
		vec3 atmospheric_transmission;
		frp_atmo_aerial(camera_to_receiver, vec3(0.0), params.camera_position.xyz, atmospheric_radiance, atmospheric_transmission);
		scene_color.rgb = scene_color.rgb * atmospheric_transmission + atmospheric_radiance * pc.parameters.y;
	}
	float scene_view_depth_m = depth > 0.0
			? max(-view_from_clip(screen_uv, depth).z, 0.0)
			: SKY_DISTANCE * view_ray_cosine;
	vec4 volume_fog = feng_sample_integrated_volume(screen_uv, scene_view_depth_m,
			vec2(extent));
	float combined_transmittance = clamp(fog.a * volume_fog.a, 0.0, 1.0);
	// UE's default path applies volumetric fog in front of the analytic height
	// fog result: L = Lv + Tv * Lh, T = Tv * Th.
	float fsss_amount = 0.0;
	vec3 fsss_scattering = vec3(0.0);
	float fsss_width = feng_fsss_blur_width(combined_transmittance, scene_view_depth_m);
	bool fsss_requested = feng_volume_sampling.frame_control.z > 0.5;
	if (fsss_requested && !(fsss_width > 0.0)) {
		// UE's W<=0 path clips the FSSS composite pixel. Preserve the input
		// scene exactly, including a cloud already present in the color buffer.
		imageStore(color_image, pixel, scene_color);
		return;
	}
	bool use_fsss = fsss_requested;
	if (use_fsss) {
		fsss_amount = feng_fsss_scene_scattering_amount(combined_transmittance);
		float maximum_mip = max(float(textureQueryLevels(feng_fsss_scattering_mips) - 1), 1.0);
		float final_transmittance = combined_transmittance * (1.0 - fsss_amount);
		float fsss_mip = feng_fsss_blur_mip(combined_transmittance,
				final_transmittance, scene_view_depth_m, maximum_mip);
		fsss_scattering = textureLod(feng_fsss_scattering_mips, screen_uv, fsss_mip).rgb;
		fsss_scattering *= clamp(fsss_width, 0.0, 1.0);
	}
	vec3 fogged_rgb;
	if (use_fsss) {
		// The FSSS pyramid stores the UE source term L + T*A*C. Keep only
		// its unblurred remainder here; adding L again would double-scatter it.
		fogged_rgb = fsss_scattering
				+ scene_color.rgb * combined_transmittance * (1.0 - fsss_amount);
	} else {
		vec3 combined_inscattering = volume_fog.rgb + volume_fog.a * fog.rgb * pc.parameters.y;
		fogged_rgb = combined_inscattering + scene_color.rgb * combined_transmittance;
	}
	fogged_rgb = mix(fogged_rgb, vec3(0.0), isnan(fogged_rgb));
	fogged_rgb = clamp(fogged_rgb, vec3(-65504.0), vec3(65504.0));
	imageStore(color_image, pixel, vec4(fogged_rgb, scene_color.a));
}
