#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D raw_ao_texture;
layout(set = 0, binding = 1) uniform sampler2D depth_texture;
layout(set = 0, binding = 2) uniform sampler2D normal_texture;
layout(rgba16f, set = 0, binding = 3) uniform writeonly image2D spatial_ao_image;
layout(set = 0, binding = 4, std140) uniform GTAOParams {
	mat4 inverse_projection;
	vec4 resolution; // full width/height, then previous-minus-current TAA jitter delta in UV.
	vec4 gtao;
	vec4 temporal;
} params;

const int FILTER_RADIUS = 2;

bool finite_float(float value) {
	return !isnan(value) && !isinf(value);
}

bool finite_vec3(vec3 value) {
	return !any(isnan(value)) && !any(isinf(value));
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

bool read_native_center(ivec2 pixel, ivec2 full_size, out float linear_depth, out vec3 normal) {
	float raw_depth = texelFetch(depth_texture, pixel, 0).r;
	vec3 encoded_normal = texelFetch(normal_texture, pixel, 0).rgb;
	if (!finite_float(raw_depth) || raw_depth <= 0.0 || !finite_vec3(encoded_normal)) {
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
	linear_depth = -(view_h.z / view_h.w);
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
	ivec2 half_pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 half_size = imageSize(spatial_ao_image);
	if (any(greaterThanEqual(half_pixel, half_size))) {
		return;
	}
	if (any(isnan(params.resolution.xy)) || any(isinf(params.resolution.xy))
			|| any(lessThanEqual(params.resolution.xy, vec2(0.0)))) {
		imageStore(spatial_ao_image, half_pixel, vec4(1.0, 0.0, 0.5, 0.5));
		return;
	}
	ivec2 full_size = ivec2(params.resolution.xy);
	ivec2 center_full_pixel = min(ivec2((vec2(half_pixel) + 0.5) * vec2(full_size) / vec2(half_size)), full_size - ivec2(1));
	vec4 center_packed = texelFetch(raw_ao_texture, half_pixel, 0);
	if (any(isnan(center_packed)) || any(isinf(center_packed))) {
		imageStore(spatial_ao_image, half_pixel, vec4(1.0, 0.0, 0.5, 0.5));
		return;
	}
	float packed_center_depth = center_packed.g;
	float center_depth;
	vec3 center_normal;
	if (packed_center_depth <= 0.0 || !read_native_center(center_full_pixel, full_size, center_depth, center_normal)) {
		imageStore(spatial_ao_image, half_pixel, vec4(1.0, 0.0, center_packed.zw));
		return;
	}
	float center_ao = clamp(center_packed.r, 0.0, 1.0);
	float depth_limit = max(0.02, center_depth * 0.04);
	float depth_scale = max(0.01, center_depth * 0.02);
	float ao_sum = 0.0;
	float weight_sum = 0.0;
	for (int y = -FILTER_RADIUS; y <= FILTER_RADIUS; y++) {
		for (int x = -FILTER_RADIUS; x <= FILTER_RADIUS; x++) {
			ivec2 neighbor_half = half_pixel + ivec2(x, y);
			if (any(lessThan(neighbor_half, ivec2(0))) || any(greaterThanEqual(neighbor_half, half_size))) {
				continue;
			}
			vec4 neighbor_packed = texelFetch(raw_ao_texture, neighbor_half, 0);
			if (any(isnan(neighbor_packed)) || any(isinf(neighbor_packed)) || neighbor_packed.g <= 0.0) {
				continue;
			}
			float neighbor_depth = neighbor_packed.g;
			vec3 neighbor_normal = oct_decode(neighbor_packed.zw);
			float depth_delta = abs(neighbor_depth - center_depth);
			float normal_dot = max(dot(neighbor_normal, center_normal), 0.0);
			if (depth_delta > depth_limit || normal_dot < 0.65) {
				continue;
			}
			float spatial_weight = exp(-0.35 * float(x * x + y * y));
			float depth_weight = exp(-depth_delta / depth_scale);
			float normal_weight = pow(normal_dot, 16.0);
			float weight = spatial_weight * depth_weight * normal_weight;
			ao_sum += clamp(neighbor_packed.r, 0.0, 1.0) * weight;
			weight_sum += weight;
		}
	}
	float filtered_ao = weight_sum > 1e-6 ? ao_sum / weight_sum : center_ao;
	imageStore(spatial_ao_image, half_pixel, vec4(clamp(filtered_ao, 0.0, 1.0),
			clamp(center_packed.g, 0.0, 65504.0), center_packed.zw));
}
