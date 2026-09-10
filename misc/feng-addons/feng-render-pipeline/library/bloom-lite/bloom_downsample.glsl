#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D src_image;
layout(rgba16f, set = 0, binding = 1) uniform restrict image2D dst_image;
layout(push_constant, std430) uniform Parameters {
	vec4 threshold; // x: brightness threshold, yzw unused
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
	float luma = dot(color.rgb, vec3(0.299, 0.587, 0.114));
	vec4 bright = luma > params.threshold.x ? color : vec4(0.0);
	imageStore(dst_image, pixel, bright);
}
