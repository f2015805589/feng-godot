#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D current_ao_texture;
layout(set = 0, binding = 1) uniform sampler2D motion_vectors_texture;
layout(set = 0, binding = 2) uniform sampler2D previous_history_texture;
layout(rgba16f, set = 0, binding = 3) uniform writeonly image2D next_history_image;
layout(set = 0, binding = 4, std140) uniform GTAOParams {
	mat4 inverse_projection;
	vec4 resolution; // full width/height, then previous-minus-current TAA jitter delta in UV.
	vec4 gtao;
	vec4 temporal;
} params;

bool finite_float(float value) {
	return !isnan(value) && !isinf(value);
}

float sign_not_zero(float value) {
	return value < 0.0 ? -1.0 : 1.0;
}

vec3 oct_decode(vec2 encoded) {
	vec2 f = encoded * 2.0 - 1.0;
	vec3 n = vec3(f, 1.0 - abs(f.x) - abs(f.y));
	if (n.z < 0.0) {
		n.xy = (1.0 - abs(n.yx)) * vec2(sign_not_zero(n.x), sign_not_zero(n.y));
	}
	float length_squared = dot(n, n);
	return length_squared > 1e-8 ? n * inversesqrt(length_squared) : vec3(0.0, 0.0, 1.0);
}

bool compatible_surface(vec4 a, vec4 b) {
	if (any(isnan(a)) || any(isinf(a)) || any(isnan(b)) || any(isinf(b)) || a.g <= 0.0 || b.g <= 0.0) {
		return false;
	}
	float depth_tolerance = max(0.03, a.g * 0.03);
	if (abs(a.g - b.g) > depth_tolerance) {
		return false;
	}
	return dot(oct_decode(a.ba), oct_decode(b.ba)) >= 0.82;
}

void main() {
	ivec2 half_pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 half_size = imageSize(next_history_image);
	if (any(greaterThanEqual(half_pixel, half_size))) {
		return;
	}
	ivec2 full_size = ivec2(params.resolution.xy);
	ivec2 full_pixel = min(ivec2((vec2(half_pixel) + 0.5) * vec2(full_size) / vec2(half_size)), full_size - ivec2(1));
	vec4 current = texelFetch(current_ao_texture, half_pixel, 0);
	if (any(isnan(current)) || any(isinf(current))) {
		imageStore(next_history_image, half_pixel, vec4(1.0, 0.0, 0.5, 0.5));
		return;
	}
	current.r = clamp(current.r, 0.0, 1.0);
	current.g = clamp(current.g, 0.0, 65504.0);
	if (current.g <= 0.0) {
		current.r = 1.0;
		current.g = 0.0;
		imageStore(next_history_image, half_pixel, current);
		return;
	}
	if (!finite_float(params.temporal.y) || !finite_float(params.temporal.z)
			|| params.temporal.y < 0.5 || params.temporal.z >= 0.5) {
		imageStore(next_history_image, half_pixel, current);
		return;
	}

	vec2 velocity = texelFetch(motion_vectors_texture, full_pixel, 0).xy;
	if (any(isnan(velocity)) || any(isinf(velocity)) || all(lessThanEqual(velocity, vec2(-1.0)))) {
		imageStore(next_history_image, half_pixel, current);
		return;
	}
	vec2 current_uv = (vec2(full_pixel) + 0.5) / vec2(full_size);
	vec2 previous_uv = current_uv + velocity + params.resolution.zw;
	if (any(lessThan(previous_uv, vec2(0.0))) || any(greaterThanEqual(previous_uv, vec2(1.0)))) {
		imageStore(next_history_image, half_pixel, current);
		return;
	}
	ivec2 previous_half_pixel = ivec2(floor(previous_uv * vec2(half_size)));
	if (any(lessThan(previous_half_pixel, ivec2(0))) || any(greaterThanEqual(previous_half_pixel, half_size))) {
		imageStore(next_history_image, half_pixel, current);
		return;
	}
	vec4 history = texelFetch(previous_history_texture, previous_half_pixel, 0);
	if (!compatible_surface(current, history)) {
		imageStore(next_history_image, half_pixel, current);
		return;
	}

	float neighborhood_min = current.r;
	float neighborhood_max = current.r;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			ivec2 neighbor_pixel = half_pixel + ivec2(x, y);
			if (any(lessThan(neighbor_pixel, ivec2(0))) || any(greaterThanEqual(neighbor_pixel, half_size))) {
				continue;
			}
			vec4 neighbor = texelFetch(current_ao_texture, neighbor_pixel, 0);
			if (!compatible_surface(current, neighbor)) {
				continue;
			}
			neighborhood_min = min(neighborhood_min, clamp(neighbor.r, 0.0, 1.0));
			neighborhood_max = max(neighborhood_max, clamp(neighbor.r, 0.0, 1.0));
		}
	}
	float clipped_history = clamp(history.r, max(0.0, neighborhood_min - 0.05), min(1.0, neighborhood_max + 0.05));
	float history_weight = finite_float(params.temporal.x) ? clamp(params.temporal.x, 0.0, 0.98) : 0.0;
	current.r = mix(current.r, clipped_history, history_weight);
	imageStore(next_history_image, half_pixel, current);
}
