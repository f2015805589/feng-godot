#[compute]
#version 450

// Applies the adapted exposure to the color buffer: color *= scale / adapted.
// Placed early in the post chain this is the addon equivalent of UE's
// pre-exposure: downstream passes (and tone mapping) see luminance already
// folded around the middle-gray scale target.

#define BLOCK_SIZE 16

layout(local_size_x = BLOCK_SIZE, local_size_y = BLOCK_SIZE, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;

layout(set = 1, binding = 0, std430) readonly buffer EyeAdaptationBuffer {
	uint histogram[64];
	float adapted_luminance;
	float pad0;
	float pad1;
	float pad2;
}
params_buffer;

layout(push_constant, std430) uniform Params {
	vec4 exposure; // x = exposure scale
}
params;

void main() {
	ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(color_image);
	if (pos.x >= size.x || pos.y >= size.y) {
		return;
	}

	float adapted = max(params_buffer.adapted_luminance, 0.0001);
	vec4 color = imageLoad(color_image, pos);
	color.rgb *= params.exposure.x / adapted;
	imageStore(color_image, pos, color);
}
