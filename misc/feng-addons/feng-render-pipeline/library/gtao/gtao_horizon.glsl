#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D depth_texture;
layout(set = 0, binding = 1) uniform sampler2D normal_texture;
layout(set = 0, binding = 2) uniform sampler2D orm_texture;
layout(rgba16f, set = 0, binding = 3) uniform writeonly image2D raw_ao_image;
layout(set = 0, binding = 4, std140) uniform GTAOParams {
	mat4 inverse_projection;
	vec4 resolution; // full width/height, then previous-minus-current TAA jitter delta in UV.
	vec4 gtao; // world radius in meters, falloff start ratio, thickness blend, strength/power.
	vec4 temporal; // history weight, history valid, camera cut, frame index modulo 65536.
} params;

const float GTAO_PI = 3.14159265358979323846;
const int GTAO_ANGLE_COUNT = 2;
const int GTAO_TAP_COUNT = 8;

bool finite_float(float value) {
	return !isnan(value) && !isinf(value);
}

bool finite_vec3(vec3 value) {
	return !any(isnan(value)) && !any(isinf(value));
}

float sign_not_zero(float value) {
	return value < 0.0 ? -1.0 : 1.0;
}

vec2 oct_encode(vec3 normal) {
	vec3 n = normalize(normal);
	float denominator = max(abs(n.x) + abs(n.y) + abs(n.z), 1e-7);
	vec2 p = n.xy / denominator;
	if (n.z < 0.0) {
		p = (1.0 - abs(p.yx)) * vec2(sign_not_zero(p.x), sign_not_zero(p.y));
	}
	return p * 0.5 + 0.5;
}

bool reconstruct_view_position(vec2 uv, float raw_depth, out vec3 view_position) {
	vec4 clip = vec4(uv * 2.0 - 1.0, raw_depth, 1.0);
	vec4 view_h = params.inverse_projection * clip;
	if (!finite_float(view_h.w) || abs(view_h.w) < 1e-7 || any(isnan(view_h)) || any(isinf(view_h))) {
		view_position = vec3(0.0);
		return false;
	}
	view_position = view_h.xyz / view_h.w;
	return finite_vec3(view_position);
}

bool read_view_position(ivec2 pixel, ivec2 full_size, out vec3 view_position) {
	if (any(lessThan(pixel, ivec2(0))) || any(greaterThanEqual(pixel, full_size))) {
		view_position = vec3(0.0);
		return false;
	}
	float raw_depth = texelFetch(depth_texture, pixel, 0).r;
	if (!finite_float(raw_depth) || raw_depth <= 0.0) {
		view_position = vec3(0.0);
		return false;
	}
	vec2 uv = (vec2(pixel) + 0.5) / vec2(full_size);
	if (!reconstruct_view_position(uv, raw_depth, view_position)) {
		return false;
	}
	float linear_depth = -view_position.z;
	return finite_float(linear_depth) && linear_depth > 0.0;
}

bool read_surface(ivec2 pixel, ivec2 full_size, out vec3 view_position, out vec3 view_normal, out float linear_depth) {
	if (!read_view_position(pixel, full_size, view_position)) {
		view_normal = vec3(0.0, 0.0, 1.0);
		linear_depth = 0.0;
		return false;
	}
	linear_depth = -view_position.z;
	vec3 encoded_normal = texelFetch(normal_texture, pixel, 0).rgb;
	if (!finite_vec3(encoded_normal)) {
		view_normal = vec3(0.0, 0.0, 1.0);
		return false;
	}
	view_normal = encoded_normal * 2.0 - 1.0;
	float normal_length_squared = dot(view_normal, view_normal);
	if (!finite_float(linear_depth) || linear_depth <= 0.0 || !finite_float(normal_length_squared) || normal_length_squared < 1e-8) {
		view_normal = vec3(0.0, 0.0, 1.0);
		return false;
	}
	view_normal *= inversesqrt(normal_length_squared);
	return true;
}

float interleaved_gradient_noise(vec2 pixel) {
	return fract(52.9829189 * fract(dot(pixel, vec2(0.06711056, 0.00583715))));
}

vec2 horizon_cosines(
		ivec2 center_pixel,
		ivec2 full_size,
		vec3 center_position,
		vec3 view_direction,
		vec2 screen_direction,
		vec2 pixel_axis_sign,
		float radius_pixels,
		float world_radius,
		float falloff_start_ratio,
		float thickness_blend,
		float sample_offset) {
	vec2 best_cosine = vec2(0.0); // An unobstructed slice has a pi/2 horizon on either side.
	// Convert the view-space slice direction to pixel-axis signs. The active
	// inverse projection can flip either screen axis (including reflection views).
	vec2 pixel_direction = screen_direction * pixel_axis_sign;
	float radius_squared = world_radius * world_radius;
	float start_squared = radius_squared * falloff_start_ratio * falloff_start_ratio;
	for (int tap = 0; tap < GTAO_TAP_COUNT; tap++) {
		float fraction = (float(tap) + sample_offset) / float(GTAO_TAP_COUNT);
		float distance_pixels = max(radius_pixels * fraction, float(tap + 1));
		ivec2 pixel_offset = ivec2(round(pixel_direction * distance_pixels));
		if (all(equal(pixel_offset, ivec2(0)))) {
			pixel_offset = ivec2(sign(pixel_direction));
		}
		for (int side = 0; side < 2; side++) {
			ivec2 sample_pixel = center_pixel + (side == 0 ? pixel_offset : -pixel_offset);
			vec3 sample_position;
			if (!read_view_position(sample_pixel, full_size, sample_position)) {
				continue;
			}
			vec3 delta = sample_position - center_position;
			float distance_squared = dot(delta, delta);
			if (!finite_float(distance_squared) || distance_squared < 1e-8 || distance_squared >= radius_squared) {
				continue;
			}
			float inverse_distance = inversesqrt(distance_squared);
			float candidate_cosine = dot(delta * inverse_distance, view_direction);
			float radial_falloff = smoothstep(start_squared, radius_squared, distance_squared);
			float current_best = best_cosine[side];
			candidate_cosine = mix(candidate_cosine, current_best, radial_falloff);
			if (candidate_cosine > current_best) {
				best_cosine[side] = candidate_cosine;
			} else {
				best_cosine[side] = mix(candidate_cosine, current_best, thickness_blend);
			}
		}
	}
	return clamp(best_cosine, vec2(-1.0), vec2(1.0));
}

float inner_slice_integral(vec2 horizon_angles, vec2 screen_direction, vec3 view_direction, vec3 view_normal) {
	vec3 plane_normal = cross(vec3(screen_direction, 0.0), view_direction);
	float plane_length_squared = dot(plane_normal, plane_normal);
	if (!finite_float(plane_length_squared) || plane_length_squared < 1e-8) {
		return 0.0;
	}
	plane_normal *= inversesqrt(plane_length_squared);
	vec3 perpendicular = cross(view_direction, plane_normal);
	vec3 projected_normal = view_normal - plane_normal * dot(view_normal, plane_normal);
	float projected_length = length(projected_normal);
	if (!finite_float(projected_length) || projected_length < 1e-6) {
		return 0.0;
	}
	float inverse_projected_length = 1.0 / projected_length;
	float cos_angle = clamp(dot(projected_normal, perpendicular) * inverse_projected_length, -1.0, 1.0);
	float gamma = acos(cos_angle) - 0.5 * GTAO_PI;
	float cos_gamma = dot(projected_normal, view_direction) * inverse_projected_length;
	float sin_gamma = -2.0 * cos_angle;

	// Clamp both horizon arcs to the normal-facing hemisphere, as in UE's analytic inner integral.
	horizon_angles.x = gamma + max(-horizon_angles.x - gamma, -0.5 * GTAO_PI);
	horizon_angles.y = gamma + min(horizon_angles.y - gamma, 0.5 * GTAO_PI);
	float first = horizon_angles.x * sin_gamma + cos_gamma - cos(2.0 * horizon_angles.x - gamma);
	float second = horizon_angles.y * sin_gamma + cos_gamma - cos(2.0 * horizon_angles.y - gamma);
	return projected_length * 0.25 * (first + second);
}

vec4 pack_result(float ao, float linear_depth, vec3 view_normal) {
	return vec4(clamp(ao, 0.0, 1.0), clamp(linear_depth, 0.0, 65504.0), oct_encode(view_normal));
}

void main() {
	ivec2 half_pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 half_size = imageSize(raw_ao_image);
	if (any(greaterThanEqual(half_pixel, half_size))) {
		return;
	}
	ivec2 full_size = ivec2(params.resolution.xy);
	ivec2 center_pixel = min(ivec2((vec2(half_pixel) + 0.5) * vec2(full_size) / vec2(half_size)), full_size - ivec2(1));
	vec3 center_position;
	vec3 center_normal;
	float center_depth;
	if (!read_surface(center_pixel, full_size, center_position, center_normal, center_depth)) {
		imageStore(raw_ao_image, half_pixel, vec4(1.0, 0.0, 0.5, 0.5));
		return;
	}

	float packed_alpha = texelFetch(orm_texture, center_pixel, 0).a;
	if (!finite_float(packed_alpha)) {
		imageStore(raw_ao_image, half_pixel, pack_result(1.0, center_depth, center_normal));
		return;
	}
	uint material_metadata = uint(round(clamp(packed_alpha, 0.0, 1.0) * 255.0));
	if ((material_metadata & 0x0Fu) == 0u) {
		imageStore(raw_ao_image, half_pixel, pack_result(1.0, center_depth, center_normal));
		return;
	}

	float world_radius = params.gtao.x;
	float strength = params.gtao.w;
	if (!finite_float(world_radius) || world_radius <= 1e-4 || !finite_float(strength) || strength <= 0.0) {
		imageStore(raw_ao_image, half_pixel, pack_result(1.0, center_depth, center_normal));
		return;
	}
	float center_raw_depth = texelFetch(depth_texture, center_pixel, 0).r;
	vec2 uv = (vec2(center_pixel) + 0.5) / vec2(full_size);
	vec3 adjacent_x;
	vec3 adjacent_y;
	if (!reconstruct_view_position(uv + vec2(1.0 / float(full_size.x), 0.0), center_raw_depth, adjacent_x)
			|| !reconstruct_view_position(uv + vec2(0.0, 1.0 / float(full_size.y)), center_raw_depth, adjacent_y)) {
		imageStore(raw_ao_image, half_pixel, pack_result(1.0, center_depth, center_normal));
		return;
	}
	float world_per_pixel = max(0.5 * (length(adjacent_x - center_position) + length(adjacent_y - center_position)), 1e-6);
	vec2 pixel_axis_sign = vec2(
		sign_not_zero(adjacent_x.x - center_position.x),
		sign_not_zero(adjacent_y.y - center_position.y));
	float radius_pixels = min(world_radius / world_per_pixel, float(min(256, max(full_size.x, full_size.y))));
	if (!finite_float(radius_pixels) || radius_pixels < 0.5) {
		imageStore(raw_ao_image, half_pixel, pack_result(1.0, center_depth, center_normal));
		return;
	}

	vec3 view_direction = normalize(-center_position);
	uint frame_index = finite_float(params.temporal.w) ? uint(max(params.temporal.w, 0.0)) & 65535u : 0u;
	float noise = interleaved_gradient_noise(vec2(center_pixel));
	float frame_phase = float(frame_index & 7u) / 8.0;
	float base_angle = noise * GTAO_PI + frame_phase * (0.5 * GTAO_PI);
	float sample_offset = fract(noise + frame_phase);
	float thickness_input = finite_float(params.gtao.z) ? clamp(params.gtao.z, 0.0, 1.0) : 0.5;
	float thickness_blend = clamp(1.0 - thickness_input * thickness_input, 0.0, 0.99);
	float radius_falloff_start = finite_float(params.gtao.y) ? clamp(params.gtao.y, 0.0, 0.999) : 0.5;
	float sum_integral = 0.0;
	float sum_unoccluded = 0.0;
	for (int angle_index = 0; angle_index < GTAO_ANGLE_COUNT; angle_index++) {
		float angle = base_angle + float(angle_index) * (0.5 * GTAO_PI);
		vec2 screen_direction = vec2(cos(angle), sin(angle));
		vec2 side_cosines = horizon_cosines(center_pixel, full_size, center_position, view_direction,
				screen_direction, pixel_axis_sign, radius_pixels, world_radius,
				radius_falloff_start, thickness_blend, sample_offset);
		vec2 horizon_angles = acos(side_cosines);
		float integral = inner_slice_integral(horizon_angles, screen_direction, view_direction, center_normal);
		float open_integral = inner_slice_integral(vec2(0.5 * GTAO_PI), screen_direction, view_direction, center_normal);
		sum_integral += max(integral, 0.0);
		sum_unoccluded += max(open_integral, 1e-5);
	}
	float visibility = clamp(sum_integral / max(sum_unoccluded, 1e-5), 0.0, 1.0);
	visibility = pow(visibility, strength);
	imageStore(raw_ao_image, half_pixel, pack_result(visibility, center_depth, center_normal));
}
