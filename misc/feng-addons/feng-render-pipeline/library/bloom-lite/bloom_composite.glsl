#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D src_image;
layout(set = 0, binding = 1) uniform sampler2D bloom_image;
layout(rgba16f, set = 0, binding = 2) uniform restrict image2D dst_image;
layout(push_constant, std430) uniform Parameters {
	vec4 strength; // x: bloom strength, yzw unused
} params;

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(dst_image);
	if (any(greaterThanEqual(pixel, size))) {
		return;
	}
	vec2 src_size = vec2(textureSize(src_image, 0));
	vec2 uv = (vec2(pixel) + 0.5) / src_size;
	vec4 color = texture(src_image, uv);
	vec4 bloom = texture(bloom_image, uv);
	imageStore(dst_image, pixel, vec4(color.rgb + bloom.rgb * params.strength.x, color.a));
}
