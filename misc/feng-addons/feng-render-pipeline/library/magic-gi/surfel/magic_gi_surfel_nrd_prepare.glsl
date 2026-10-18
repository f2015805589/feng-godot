#[compute]
#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D surfel_signal;
layout(set = 0, binding = 1) uniform sampler2D surfel_auxiliary;
layout(set = 0, binding = 2) uniform sampler2D depth_texture;
layout(set = 0, binding = 3) uniform sampler2D normal_roughness_texture;
layout(set = 0, binding = 4) uniform sampler2D motion_vectors_texture;
layout(set = 0, binding = 5, rgba16f) uniform writeonly image2D nrd_signal;
layout(set = 0, binding = 6, rgba16f) uniform writeonly image2D nrd_normal_roughness;
layout(set = 0, binding = 7, r32f) uniform writeonly image2D nrd_view_z;
layout(set = 0, binding = 8, rgba16f) uniform writeonly image2D nrd_motion;
layout(set = 0, binding = 9, std140) uniform PrepareParameters {
	mat4 inverse_projection;
	mat4 view_to_world;
	vec4 full_half_size;
	vec4 range_parameters;
} params;

const float NRD_INF = 1.0e10;

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	ivec2 half_size = imageSize(nrd_signal);
	if (any(greaterThanEqual(p, half_size))) return;
	ivec2 full_size = textureSize(depth_texture, 0);
	ivec2 q = min(ivec2((vec2(p) + 0.5) / vec2(half_size) * vec2(full_size)),
		full_size - ivec2(1));
	vec4 raw = texelFetch(surfel_signal, p, 0);
	vec4 auxiliary = texelFetch(surfel_auxiliary, p, 0);
	float depth = texelFetch(depth_texture, q, 0).r;
	vec4 normal_roughness = texelFetch(normal_roughness_texture, q, 0);
	vec2 motion = texelFetch(motion_vectors_texture, q, 0).xy;
	vec3 view_normal_encoded = normal_roughness.xyz * 2.0 - 1.0;
	float normal_length = length(view_normal_encoded);
	bool valid = auxiliary.z > 0.5 && raw.a > 0.0 && depth > 0.0
			&& !isnan(depth) && !isinf(depth)
			&& normal_length > 1.0e-6 && !isnan(normal_length) && !isinf(normal_length);
	if (!valid) {
		imageStore(nrd_signal, p, vec4(0.0, 0.0, 0.0, max(params.range_parameters.z, 0.001)));
		imageStore(nrd_normal_roughness, p, vec4(0.0));
		imageStore(nrd_view_z, p, vec4(NRD_INF));
		imageStore(nrd_motion, p, vec4(0.0));
		return;
	}
	vec2 uv = (vec2(q) + 0.5) / vec2(full_size);
	vec4 view_h = params.inverse_projection * vec4(uv * 2.0 - 1.0, depth, 1.0);
	if (!(abs(view_h.w) > 1.0e-8) || isnan(view_h.w) || isinf(view_h.w)) {
		imageStore(nrd_signal, p, vec4(0.0, 0.0, 0.0, max(auxiliary.x, 0.001)));
		imageStore(nrd_normal_roughness, p, vec4(0.0));
		imageStore(nrd_view_z, p, vec4(NRD_INF));
		imageStore(nrd_motion, p, vec4(0.0));
		return;
	}
	vec3 view_position = view_h.xyz / view_h.w;
	vec3 view_normal = view_normal_encoded / normal_length;
	vec3 world_normal = normalize(mat3(params.view_to_world) * view_normal);
	vec3 oct = world_normal / max(dot(abs(world_normal), vec3(1.0)), 1.0e-6);
	float roughness = max(normal_roughness.w, 1.5 / 512.0);
	vec3 packed_normal = vec3((oct.x + oct.y) * 0.5 + 0.5,
		(oct.y - oct.x) * 0.5 + 0.5,
		(oct.z < 0.0 ? -roughness : roughness) * 0.5 + 0.5);
	float hit_distance = auxiliary.x;
	if (!(hit_distance > 0.0) || isnan(hit_distance) || isinf(hit_distance)) {
		hit_distance = max(params.range_parameters.z, 0.001);
	}
	vec3 signal = max(raw.rgb, vec3(0.0));
	if (any(isnan(signal)) || any(isinf(signal))) signal = vec3(0.0);
	bool motion_valid = !any(isnan(motion)) && !any(isinf(motion))
			&& !all(lessThanEqual(abs(motion + vec2(1.0)), vec2(1.0e-6)));
	// The gather stage already stores scene-linear E/pi scaled by 0.001 for FP16.
	// Feed it unchanged to RELAX and only undo that unit scale in final composition.
	imageStore(nrd_signal, p, vec4(signal, clamp(hit_distance, 0.001, 65504.0)));
	imageStore(nrd_normal_roughness, p, vec4(packed_normal, 0.0));
	// Godot supplies non-jittered prevUV-currentUV screen motion. Preserve its sign
	// and units; NRD gets no second jitter adjustment. Invalid velocity excludes
	// prior history for this guide pixel while keeping this frame's signal available.
	imageStore(nrd_view_z, p, vec4(motion_valid ? max(abs(view_position.z), 1.0e-6) : NRD_INF));
	imageStore(nrd_motion, p, vec4(motion_valid ? motion : vec2(0.0), 0.0, 0.0));
}
