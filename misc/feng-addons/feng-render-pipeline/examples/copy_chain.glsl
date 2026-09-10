#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D src_image;
layout(rgba16f, set = 0, binding = 1) uniform restrict image2D dst_image;
layout(push_constant, std430) uniform Parameters {
	vec4 tint;
} params;

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pixel, imageSize(dst_image)))) {
		return;
	}
	vec4 color = texelFetch(src_image, pixel, 0);
	imageStore(dst_image, pixel, vec4(color.rgb * params.tint.rgb, color.a));
}
