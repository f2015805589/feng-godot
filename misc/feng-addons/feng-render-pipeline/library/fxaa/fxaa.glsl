#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D src_image;
layout(rgba16f, set = 0, binding = 1) uniform restrict image2D dst_image;
layout(push_constant, std430) uniform Parameters {
	vec4 strength; // x: edge threshold, y: edge threshold min, z: quality, w: unused
} params;

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(dst_image);
	if (any(greaterThanEqual(pixel, size))) {
		return;
	}
	vec2 texel = 1.0 / vec2(textureSize(src_image, 0));
	vec2 uv = (vec2(pixel) + 0.5) * texel;
	vec3 nw = texture(src_image, uv + vec2(-1.0, -1.0) * texel).rgb;
	vec3 ne = texture(src_image, uv + vec2(1.0, -1.0) * texel).rgb;
	vec3 sw = texture(src_image, uv + vec2(-1.0, 1.0) * texel).rgb;
	vec3 se = texture(src_image, uv + vec2(1.0, 1.0) * texel).rgb;
	vec3 m = texture(src_image, uv).rgb;
	float luma_nw = dot(nw, vec3(0.299, 0.587, 0.114));
	float luma_ne = dot(ne, vec3(0.299, 0.587, 0.114));
	float luma_sw = dot(sw, vec3(0.299, 0.587, 0.114));
	float luma_se = dot(se, vec3(0.299, 0.587, 0.114));
	float luma_m = dot(m, vec3(0.299, 0.587, 0.114));
	float luma_min = min(luma_m, min(min(luma_nw, luma_ne), min(luma_sw, luma_se)));
	float luma_max = max(luma_m, max(max(luma_nw, luma_ne), max(luma_sw, luma_se)));
	float contrast = luma_max - luma_min;
	float threshold = max(params.strength.x, params.strength.y);
	if (contrast < threshold || luma_max < 0.05) {
		imageStore(dst_image, pixel, vec4(m, 1.0));
		return;
	}
	// Simple 3x3 FXAA-style blend toward the average of the four neighbors.
	vec3 avg = (nw + ne + sw + se) * 0.25;
	float blend = clamp((contrast - threshold) / max(contrast, 1e-5) * 2.0, 0.0, 1.0);
	imageStore(dst_image, pixel, vec4(mix(m, avg, blend * 0.5), 1.0));
}
