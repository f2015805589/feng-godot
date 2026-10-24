#[compute]
#version 450
// Debug-only mirror of the native deferred CLV sampler. It reads the already
// relit layout-9 cache and never evaluates probe transfer matrices or a legacy
// screen-space PRT fallback.
// Reimport this parent when the diagnostic sampler include changes; the mirror
// uses the same interior filter and toroidal seam fallback as the native path.
// Curved-domain contract revision 2: same-facing geometric normals, fixed 1.25-cell AABB.
// Approximate-patch prefilter revision 2: READY tags and axis candidate bits.
// Signed SH route revision 3: clamp only after secondary/primary owner combine.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 1) uniform sampler2D depth_buffer;
layout(set = 0, binding = 2) uniform sampler2D normal_roughness;
layout(set = 0, binding = 3) uniform sampler2D gbuffer_albedo;
layout(set = 0, binding = 4) uniform sampler2D gbuffer_orm;
layout(rgba16f, set = 0, binding = 5) uniform writeonly image2D gi_output;
layout(set = 0, binding = 9, std140) uniform GIParams {
	mat4 inverse_projection;
	mat4 world_to_grid;
	mat4 view_to_world;
	vec4 grid;
	vec4 control;
	vec4 lighting_sh[7];
	vec4 sky_lighting_sh[7];
} params;
layout(set = 0, binding = 16) uniform sampler2D diffuse_ambient_occlusion_texture;

layout(set = 1, binding = 50) uniform texture3D frp_magic_gi_clv_texture0;
layout(set = 1, binding = 51) uniform itexture3D frp_magic_gi_clv_tags0;
layout(set = 1, binding = 52) uniform utexture3D frp_magic_gi_clv_support0;
layout(set = 1, binding = 53, std140) uniform FRPMagicGIClipmapParameters0 {
	ivec4 origins[3];
	vec4 spacing;
	ivec4 control;
} frp_magic_gi_clv_parameters0;
layout(set = 1, binding = 58, std140) uniform FRPMagicGIOwnerParameters0 {
	mat4 world_to_local;
	vec4 owner_size_enabled;
	vec4 control;
} frp_magic_gi_owner_parameters0;
layout(set = 1, binding = 60, std140) uniform FRPMagicGIBakeParameters {
	mat4 world_to_grid;
	vec4 grid;
	vec4 control;
} frp_magic_gi_bake_parameters;
layout(set = 1, binding = 61) uniform sampler SAMPLER_NEAREST_CLAMP;
layout(set = 1, binding = 62) uniform sampler SAMPLER_LINEAR_CLAMP;

layout(push_constant, std430) uniform DebugParameters {
	ivec2 output_size;
	int debug_view;
	float pre_exposure;
} pc;

#include "magic_gi_clv_approx_contract.glslinc"

const int CLV_DEBUG_OFF = 0;
const int CLV_DEBUG_CASCADE_LEVELS = 1;
const int CLV_DEBUG_CACHE_VALIDITY = 2;
const int CLV_DEBUG_CELLS = 3;
const int CLV_DEBUG_RECONSTRUCTED_LIGHTING = 4;
const int CLV_DEBUG_REJECTION_REASONS = 5;

const int CLV_DEBUG_REJECT_NONE = 0;
const int CLV_DEBUG_REJECT_OWNER_BOUNDS = 1;
const int CLV_DEBUG_REJECT_BAKE_BOUNDS = 2;
const int CLV_DEBUG_REJECT_WINDOW = 3;
const int CLV_DEBUG_REJECT_TAG_EPOCH = 4;
const int CLV_DEBUG_REJECT_AXIS_SUPPORT = 5;
const int CLV_DEBUG_REJECT_CERTIFICATE = 6;
const int CLV_DEBUG_REJECT_INVALID_LAYOUT = 7;
const int CLV_DEBUG_REJECT_RECEIVER_DISABLED = 8;
const int CLV_DEBUG_APPROX_REJECT_NONE = 0;
const int CLV_DEBUG_APPROX_REJECT_DISABLED = 9;
const int CLV_DEBUG_APPROX_REJECT_LAYOUT = 10;
const int CLV_DEBUG_APPROX_REJECT_INPUT = 11;
const int CLV_DEBUG_APPROX_REJECT_STEP = 12;
const int CLV_DEBUG_APPROX_REJECT_POSITION = 13;
const int CLV_DEBUG_APPROX_REJECT_WINDOW = 14;
const int CLV_DEBUG_APPROX_REJECT_BASE_TAG = 15;
const int CLV_DEBUG_APPROX_REJECT_READY_BIT = 16;
const int CLV_DEBUG_APPROX_REJECT_CORNER_TAG = 17;
const int CLV_DEBUG_APPROX_REJECT_NONFINITE_SAMPLES = 18;
const int CLV_DEBUG_APPROX_REJECT_CORNER_GEOMETRY = 19;
const int CLV_DEBUG_APPROX_REJECT_LOW_COVERAGE = 20;
const int CLV_DEBUG_APPROX_REJECT_NORMAL_MAGNITUDE = 21;
const int CLV_DEBUG_APPROX_REJECT_NORMAL_ALIGNMENT = 22;
const int CLV_DEBUG_APPROX_REJECT_PLANE_VARIANCE = 23;
const int CLV_DEBUG_APPROX_REJECT_PLANE_PRECISION = 24;
const int CLV_DEBUG_APPROX_REJECT_PATCH_VARIANCE = 25; // Reserved for older captures.
const int CLV_DEBUG_APPROX_REJECT_PATCH_INTEGER = 26; // Reserved for older captures.
const int CLV_DEBUG_APPROX_REJECT_RECEIVER_PLANE = 27;
const int CLV_DEBUG_APPROX_REJECT_RADIANCE = 28;
const int CLV_DEBUG_APPROX_REJECT_SAMPLER_DIVERGENCE = 29;
const int CLV_DEBUG_APPROX_REJECT_PLANE_RESIDUAL = 30;
const int CLV_DEBUG_APPROX_REJECT_PATCH_MISMATCH = 31;

#include "magic_gi_clv_debug_sample.glslinc"

vec3 clv_debug_level_color(int level) {
	if (level == 0) { return vec3(0.08, 0.9, 0.12); }
	if (level == 1) { return vec3(1.0, 0.55, 0.04); }
	if (level == 2) { return vec3(0.12, 0.35, 1.0); }
	return vec3(1.0, 1.0, 1.0);
}

vec3 clv_debug_rejection_color(int reason) {
	if (reason == CLV_DEBUG_REJECT_OWNER_BOUNDS) { return vec3(0.05, 0.25, 1.0); }
	if (reason == CLV_DEBUG_REJECT_BAKE_BOUNDS) { return vec3(0.0, 0.9, 1.0); }
	if (reason == CLV_DEBUG_REJECT_WINDOW) { return vec3(1.0, 0.9, 0.0); }
	if (reason == CLV_DEBUG_REJECT_TAG_EPOCH) { return vec3(1.0, 0.05, 0.05); }
	if (reason == CLV_DEBUG_REJECT_AXIS_SUPPORT) { return vec3(1.0, 0.35, 0.0); }
	if (reason == CLV_DEBUG_REJECT_CERTIFICATE) { return vec3(0.85, 0.05, 1.0); }
	if (reason == CLV_DEBUG_REJECT_RECEIVER_DISABLED) { return vec3(0.25, 0.25, 0.25); }
	if (reason == CLV_DEBUG_APPROX_REJECT_DISABLED) { return vec3(0.48, 0.48, 0.48); }
	if (reason == CLV_DEBUG_APPROX_REJECT_LAYOUT) { return vec3(0.08, 0.08, 0.5); }
	if (reason == CLV_DEBUG_APPROX_REJECT_INPUT) { return vec3(0.16, 0.16, 0.92); }
	if (reason == CLV_DEBUG_APPROX_REJECT_STEP) { return vec3(0.0, 0.52, 0.55); }
	if (reason == CLV_DEBUG_APPROX_REJECT_POSITION) { return vec3(0.0, 0.85, 0.86); }
	if (reason == CLV_DEBUG_APPROX_REJECT_WINDOW) { return vec3(0.95, 0.88, 0.0); }
	if (reason == CLV_DEBUG_APPROX_REJECT_BASE_TAG) { return vec3(0.75, 0.0, 0.0); }
	if (reason == CLV_DEBUG_APPROX_REJECT_READY_BIT) { return vec3(1.0, 0.22, 0.0); }
	if (reason == CLV_DEBUG_APPROX_REJECT_CORNER_TAG) { return vec3(0.6, 0.0, 0.24); }
	if (reason == CLV_DEBUG_APPROX_REJECT_NONFINITE_SAMPLES) { return vec3(0.95, 0.95, 0.95); }
	if (reason == CLV_DEBUG_APPROX_REJECT_CORNER_GEOMETRY) { return vec3(0.0, 0.3, 0.82); }
	if (reason == CLV_DEBUG_APPROX_REJECT_LOW_COVERAGE) { return vec3(0.95, 0.38, 0.0); }
	if (reason == CLV_DEBUG_APPROX_REJECT_NORMAL_MAGNITUDE) { return vec3(0.0, 0.58, 0.14); }
	if (reason == CLV_DEBUG_APPROX_REJECT_NORMAL_ALIGNMENT) { return vec3(0.25, 0.92, 0.15); }
	if (reason == CLV_DEBUG_APPROX_REJECT_PLANE_VARIANCE) { return vec3(0.72, 0.0, 0.88); }
	if (reason == CLV_DEBUG_APPROX_REJECT_PLANE_PRECISION) { return vec3(0.95, 0.15, 0.8); }
	if (reason == CLV_DEBUG_APPROX_REJECT_PATCH_VARIANCE) { return vec3(0.54, 0.1, 0.95); }
	if (reason == CLV_DEBUG_APPROX_REJECT_PATCH_INTEGER) { return vec3(0.98, 0.38, 0.82); }
	if (reason == CLV_DEBUG_APPROX_REJECT_RECEIVER_PLANE) { return vec3(0.78, 0.8, 0.0); }
	if (reason == CLV_DEBUG_APPROX_REJECT_RADIANCE) { return vec3(0.95, 0.72, 0.96); }
	if (reason == CLV_DEBUG_APPROX_REJECT_SAMPLER_DIVERGENCE) { return vec3(0.05, 1.0, 0.42); }
	if (reason == CLV_DEBUG_APPROX_REJECT_PLANE_RESIDUAL) { return vec3(0.42, 0.1, 0.65); }
	if (reason == CLV_DEBUG_APPROX_REJECT_PATCH_MISMATCH) { return vec3(0.95, 0.12, 0.08); }
	return vec3(1.0, 1.0, 1.0);
}

vec3 clv_debug_cell_color(vec3 world, int level) {
	float cell_size = max(frp_magic_gi_clv_parameters0.spacing.x, 0.001)
			* float(1 << max(level, 0));
	ivec3 cell = ivec3(floor(world / cell_size));
	ivec3 wrapped = ((cell % 7) + 7) % 7;
	return vec3(wrapped) / 6.0;
}

bool clv_debug_reconstruct_world(ivec2 pixel, out vec3 world) {
	ivec2 size = textureSize(depth_buffer, 0);
	if (any(lessThan(pixel, ivec2(0))) || any(greaterThanEqual(pixel, size))) { return false; }
	float depth = texelFetch(depth_buffer, pixel, 0).r;
	if (!(depth > 0.0) || isnan(depth) || isinf(depth)) { return false; }
	vec2 uv = (vec2(pixel) + vec2(0.5)) / vec2(pc.output_size);
	vec4 view_h = params.inverse_projection * vec4(uv * 2.0 - 1.0, depth, 1.0);
	if (!(abs(view_h.w) > 1e-8) || isnan(view_h.w) || isinf(view_h.w)) { return false; }
	vec3 view_position = view_h.xyz / view_h.w;
	world = (params.view_to_world * vec4(view_position, 1.0)).xyz;
	return frp_magic_gi_clv_finite(world);
}

vec3 clv_debug_geometric_normal(ivec2 pixel, vec3 world, vec3 view_to_camera_world) {
	ivec2 left_pixel = pixel - ivec2(1, 0);
	ivec2 right_pixel = pixel + ivec2(1, 0);
	ivec2 up_pixel = pixel - ivec2(0, 1);
	ivec2 down_pixel = pixel + ivec2(0, 1);
	vec3 left_world = world; vec3 right_world = world;
	vec3 up_world = world; vec3 down_world = world;
	bool have_left = clv_debug_reconstruct_world(left_pixel, left_world);
	bool have_right = clv_debug_reconstruct_world(right_pixel, right_world);
	bool have_up = clv_debug_reconstruct_world(up_pixel, up_world);
	bool have_down = clv_debug_reconstruct_world(down_pixel, down_world);
	vec3 derivative_x = have_left && have_right ? right_world - left_world
			: (have_right ? right_world - world : (have_left ? world - left_world : vec3(0.0)));
	vec3 derivative_y = have_up && have_down ? down_world - up_world
			: (have_down ? down_world - world : (have_up ? world - up_world : vec3(0.0)));
	vec3 geometric = cross(derivative_x, derivative_y);
	float length_squared = dot(geometric, geometric);
	if (!(length_squared > 1e-12) || isnan(length_squared) || isinf(length_squared)
		|| !frp_magic_gi_clv_finite(geometric)) { return view_to_camera_world; }
	geometric *= inversesqrt(length_squared);
	if (dot(geometric, view_to_camera_world) < 0.0) { geometric = -geometric; }
	return geometric;
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pixel, pc.output_size))) {
		return;
	}
	float depth = texelFetch(depth_buffer, pixel, 0).r;
	if (!(depth > 0.0) || isnan(depth) || isinf(depth)) {
		imageStore(gi_output, pixel, vec4(0.0));
		return;
	}
	vec2 uv = (vec2(pixel) + vec2(0.5)) / vec2(pc.output_size);
	vec4 view_h = params.inverse_projection * vec4(uv * 2.0 - 1.0, depth, 1.0);
	if (!(abs(view_h.w) > 1e-8) || isnan(view_h.w) || isinf(view_h.w)) {
		imageStore(gi_output, pixel, vec4(1.0, 0.0, 1.0, 1.0));
		return;
	}
	vec3 view_position = view_h.xyz / view_h.w;
	vec3 world = (params.view_to_world * vec4(view_position, 1.0)).xyz;
	vec3 view_normal = normalize(texelFetch(normal_roughness, pixel, 0).xyz * 2.0 - 1.0);
	vec3 world_normal = normalize(mat3(params.view_to_world) * view_normal);
	vec3 view_to_camera_world = mat3(params.view_to_world) * normalize(-view_position);
	float view_to_camera_length_squared = dot(view_to_camera_world, view_to_camera_world);
	if (view_to_camera_length_squared > 1e-12 && !isnan(view_to_camera_length_squared)
			&& !isinf(view_to_camera_length_squared)) {
		view_to_camera_world *= inversesqrt(view_to_camera_length_squared);
	} else {
		view_to_camera_world = world_normal;
	}
	vec3 world_geometric_normal = clv_debug_geometric_normal(pixel, world,
			view_to_camera_world);
	vec3 albedo = max(texelFetch(gbuffer_albedo, pixel, 0).rgb, vec3(0.0));
	vec4 orm = texelFetch(gbuffer_orm, pixel, 0);
	float ao = clamp(orm.r, 0.0, 1.0);
	float diffuse_ao = textureLod(diffuse_ambient_occlusion_texture, uv, 0.0).r;
	diffuse_ao = isnan(diffuse_ao) || isinf(diffuse_ao)
			? 1.0 : clamp(diffuse_ao, 0.0, 1.0);

	vec3 secondary = vec3(0.0);
	vec3 primary = vec3(0.0);
	int selected_level = -1;
	int sample_method = 0; // 1 = diffuse-domain, 2 = curved SH domain, 3 = strict legacy certificate.
	int rejection_level = -1;
	float confidence = 0.0;
	int sample_kind = 0; // 0 = outside/rejected, 1 = certified, 2 = approximate.
	int rejection_reason = CLV_DEBUG_REJECT_NONE;
	bool inside_owner = frp_magic_gi_owner_contains(world,
			frp_magic_gi_owner_parameters0.owner_size_enabled,
			frp_magic_gi_owner_parameters0.world_to_local);
	bool inside_bake = frp_magic_gi_in_bake_bounds(world);
	if (!inside_owner) {
		rejection_reason = CLV_DEBUG_REJECT_OWNER_BOUNDS;
	} else if (!inside_bake) {
		rejection_reason = CLV_DEBUG_REJECT_BAKE_BOUNDS;
	} else if (!(frp_magic_gi_owner_parameters0.control.x > 0.0)
			|| !(ao > 0.0) || !any(greaterThan(albedo, vec3(0.0)))) {
		rejection_reason = CLV_DEBUG_REJECT_RECEIVER_DISABLED;
	} else if (!frp_magic_gi_clv_finite(world_normal)) {
		rejection_reason = CLV_DEBUG_REJECT_INVALID_LAYOUT;
	}
	bool owner_valid = rejection_reason == CLV_DEBUG_REJECT_NONE;
	if (owner_valid && frp_magic_gi_clv_finite(world_normal)) {
		if (frp_magic_gi_sample_certified(world, world_geometric_normal, world_normal,
				secondary, primary, selected_level, sample_method)) {
			sample_kind = 1;
		} else if (frp_magic_gi_sample_approx(world, world_normal,
				secondary, primary, selected_level, confidence)) {
			sample_kind = 2;
		} else if (pc.debug_view == CLV_DEBUG_CACHE_VALIDITY
				|| pc.debug_view == CLV_DEBUG_REJECTION_REASONS) {
			if (pc.debug_view == CLV_DEBUG_REJECTION_REASONS) {
				ivec3 rejected_base;
				vec3 rejected_fraction;
				vec4 rejected_details;
				rejection_reason = frp_magic_gi_clv_debug_approx_first_reject(world,
						world_normal, rejection_level, rejected_base,
						rejected_fraction, rejected_details);
			} else {
				rejection_reason = frp_magic_gi_clv_debug_rejection(world, world_normal);
			}
		}
	}

	vec3 incident = max(secondary + primary, vec3(0.0));
	vec3 output_color = incident;
	float output_alpha = sample_kind == 0 ? 0.0 : 1.0;
	if (pc.debug_view == CLV_DEBUG_CASCADE_LEVELS) {
		output_color = sample_kind == 0 ? vec3(0.0)
				: (selected_level < 0 ? vec3(1.0) : clv_debug_level_color(selected_level));
	} else if (pc.debug_view == CLV_DEBUG_CACHE_VALIDITY) {
		output_color = sample_kind == 1 && sample_method == 2 ? vec3(0.0, 0.72, 1.0)
				: (sample_kind == 1 ? vec3(0.08, 1.0, 0.12)
				: (sample_kind == 2 ? vec3(1.0, 0.5, 0.04)
				: vec3(1.0, 0.02, 0.55)));
		output_alpha = 1.0;
	} else if (pc.debug_view == CLV_DEBUG_REJECTION_REASONS) {
		output_color = sample_kind == 1 && sample_method == 2 ? vec3(0.0, 0.72, 1.0)
				: (sample_kind == 1 ? vec3(0.08, 1.0, 0.12)
				: (sample_kind == 2 ? vec3(1.0, 0.5, 0.04)
				: clv_debug_rejection_color(rejection_reason)));
		// Finer (level 0) attempts are full brightness; each coarser fallback
		// level is dimmer so the image also reveals which LOD rejected first.
		if (sample_kind == 0 && rejection_level >= 0) {
			output_color *= max(0.52, 1.0 - float(rejection_level) * 0.22);
		}
		output_alpha = 1.0;
	} else if (pc.debug_view == CLV_DEBUG_CELLS) {
		output_color = sample_kind == 0 ? vec3(1.0, 0.02, 0.55)
				: clv_debug_cell_color(world, selected_level);
	} else if (pc.debug_view == CLV_DEBUG_RECONSTRUCTED_LIGHTING) {
		output_color = incident;
	}

	if (pc.debug_view == CLV_DEBUG_OFF) {
		float strength = max(params.control.x, 0.0)
				* max(frp_magic_gi_owner_parameters0.control.x, 0.0)
				* max(frp_magic_gi_owner_parameters0.control.z, 0.0);
		output_color *= albedo * ao * diffuse_ao * strength * max(pc.pre_exposure, 0.0);
	}
	if (any(isnan(output_color)) || any(isinf(output_color))) {
		output_color = vec3(1.0, 0.0, 1.0);
	}
	imageStore(gi_output, pixel, vec4(output_color, output_alpha));
}
