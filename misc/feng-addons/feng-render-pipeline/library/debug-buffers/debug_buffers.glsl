#[compute]
#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform restrict writeonly image2D output_image;
layout(set = 0, binding = 1) uniform sampler2D source_buffer;
layout(push_constant, std430) uniform Params { vec4 options; } pc;

vec3 linear_to_srgb(vec3 c) {
	return mix(12.92 * c, 1.055 * pow(max(c, vec3(0.0)), vec3(1.0 / 2.4)) - 0.055,
			greaterThan(c, vec3(0.0031308)));
}

vec3 aces_fitted(vec3 c) {
	const float a = 2.51;
	const float b = 0.03;
	const float d = 0.59;
	const float e = 0.14;
	const float f = 2.43;
	return clamp((c * (a * c + b)) / (c * (f * c + d) + e), 0.0, 1.0);
}

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(p, imageSize(output_image)))) return;
	vec4 sample_value = texelFetch(source_buffer, p, 0);
	int mode = int(pc.options.x);
	vec3 result = sample_value.rgb;
	if (mode == 0) result = linear_to_srgb(result);
	if (mode == 1) result = normalize(result * 2.0 - 1.0) * 0.5 + 0.5;
	if (mode >= 2 && mode <= 4) result = vec3(sample_value[mode - 2]);
	if (mode == 5) {
		vec2 velocity = sample_value.xy;
		result = all(lessThanEqual(velocity, vec2(-1.0))) ? vec3(0.0)
				: vec3(clamp(0.5 + velocity * pc.options.y, 0.0, 1.0), 0.5);
	}
	if (mode == 6) {
		vec3 gi = max(result, vec3(0.0)) * pc.options.z;
		if (any(isnan(gi)) || any(isinf(gi))) gi = vec3(0.0);
		if (pc.options.w < 0.5) gi = aces_fitted(gi);
		result = linear_to_srgb(gi);
	}
	imageStore(output_image, p, vec4(result, 1.0));
}
