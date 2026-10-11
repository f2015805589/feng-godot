#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D depth_texture;
layout(set = 0, binding = 1) uniform sampler2D normal_texture;
layout(set = 0, binding = 2) uniform sampler2D resolved_history_texture;
layout(r16f, set = 0, binding = 3) uniform writeonly image2D fullres_ao_image;
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

bool read_full_surface(ivec2 pixel, ivec2 full_size, out float linear_depth, out vec3 normal) {
	float raw_depth = texelFetch(depth_texture, pixel, 0).r;
	if (!finite_float(raw_depth) || raw_depth <= 0.0) {
		linear_depth = 0.0;
		normal = vec3(0.0, 0.0, 1.0);
		return false;
	}
	vec2 uv = (vec2(pixel) + 0.5) / vec2(full_size);
	vec4 view_h = params.inverse_projection * vec4(uv * 2.0 - 1.0, raw_depth, 1.0);
	if (!finite_float(view_h.w) || abs(view_h.w) < 1e-7 || any(isnan(view_h)) || any(isinf(view_h))) {
		linear_depth = 0.0;
		normal = vec3(0.0, 0.0, 1.0);
		return false;
	}
	vec3 view_position = view_h.xyz / view_h.w;
	vec3 encoded_normal = texelFetch(normal_texture, pixel, 0).rgb;
	if (any(isnan(view_position)) || any(isinf(view_position)) || any(isnan(encoded_normal)) || any(isinf(encoded_normal))) {
		linear_depth = 0.0;
		normal = vec3(0.0, 0.0, 1.0);
		return false;
	}
	linear_depth = -view_position.z;
	normal = encoded_normal * 2.0 - 1.0;
	float normal_length_squared = dot(normal, normal);
	if (!finite_float(linear_depth) || linear_depth <= 0.0 || !finite_float(normal_length_squared) || normal_length_squared < 1e-8) {
		linear_depth = 0.0;
		normal = vec3(0.0, 0.0, 1.0);
		return false;
	}
	normal *= inversesqrt(normal_length_squared);
	return true;
}

void main() {
	ivec2 full_pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 full_size = imageSize(fullres_ao_image);
	if (any(greaterThanEqual(full_pixel, full_size))) {
		return;
	}
	ivec2 half_size = textureSize(resolved_history_texture, 0);
	float center_depth;
	vec3 center_normal;
	if (!read_full_surface(full_pixel, full_size, center_depth, center_normal)) {
		imageStore(fullres_ao_image, full_pixel, vec4(1.0));
		return;
	}

	vec2 half_position = (vec2(full_pixel) + 0.5) * vec2(half_size) / vec2(full_size) - 0.5;
	ivec2 base_pixel = ivec2(floor(half_position));
	vec2 fraction = fract(half_position);
	float depth_limit = max(0.015, center_depth * 0.03);
	float depth_scale = max(0.005, center_depth * 0.015);
	float ao_sum = 0.0;
	float weight_sum = 0.0;
	float nearest_ao = 1.0;
	float nearest_weight = -1.0;
	for (int y = 0; y < 2; y++) {
		for (int x = 0; x < 2; x++) {
			ivec2 sample_pixel = clamp(base_pixel + ivec2(x, y), ivec2(0), half_size - ivec2(1));
			vec4 packed = texelFetch(resolved_history_texture, sample_pixel, 0);
			if (any(isnan(packed)) || any(isinf(packed)) || packed.g <= 0.0) {
				continue;
			}
			vec3 sample_normal = oct_decode(packed.ba);
			float depth_delta = abs(packed.g - center_depth);
			float normal_dot = max(dot(sample_normal, center_normal), 0.0);
			if (depth_delta > depth_limit || normal_dot < 0.75) {
				continue;
			}
			vec2 bilinear = vec2(x == 0 ? 1.0 - fraction.x : fraction.x,
					y == 0 ? 1.0 - fraction.y : fraction.y);
			float spatial_weight = bilinear.x * bilinear.y;
			float depth_weight = exp(-depth_delta / depth_scale);
			float normal_weight = pow(normal_dot, 24.0);
			float weight = spatial_weight * depth_weight * normal_weight;
			if (weight > nearest_weight) {
				nearest_weight = weight;
				nearest_ao = clamp(packed.r, 0.0, 1.0);
			}
			ao_sum += clamp(packed.r, 0.0, 1.0) * weight;
			weight_sum += weight;
		}
	}
	float ao = weight_sum > 1e-6 ? ao_sum / weight_sum : (nearest_weight >= 0.0 ? nearest_ao : 1.0);
	imageStore(fullres_ao_image, full_pixel, vec4(clamp(ao, 0.0, 1.0)));
}
