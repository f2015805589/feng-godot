#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D src_image;
layout(rgba16f, set = 0, binding = 1) uniform restrict image2D dst_image;
layout(push_constant, std430) uniform Parameters {
	vec4 radius; // x: blur radius in pixels, yzw unused
} params;

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(dst_image);
	if (any(greaterThanEqual(pixel, size))) {
		return;
	}
	float radius = max(params.radius.x, 0.0);
	vec2 src_size = vec2(textureSize(src_image, 0));
	vec2 uv = (vec2(pixel) + 0.5) / src_size;
	vec2 texel = 1.0 / src_size;
	vec4 sum = vec4(0.0);
	float weight_sum = 0.0;
	int r = int(ceil(radius));
	for (int i = -r; i <= r; i++) {
		for (int j = -r; j <= r; j++) {
			float w = exp(-float(i * i + j * j) / (2.0 * radius * radius + 1e-5));
			sum += texture(src_image, uv + vec2(float(i), float(j)) * texel) * w;
			weight_sum += w;
		}
	}
	imageStore(dst_image, pixel, sum / weight_sum);
}
