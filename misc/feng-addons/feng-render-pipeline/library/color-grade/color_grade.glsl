#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D src_image;
layout(rgba16f, set = 0, binding = 1) uniform restrict image2D dst_image;
layout(push_constant, std430) uniform Parameters {
	vec4 grade; // x: saturation, y: contrast, z: brightness, w: gamma
} params;

vec3 apply_grade(vec3 c) {
	c *= params.grade.z; // brightness
	c = (c - 0.5) * params.grade.y + 0.5; // contrast
	float luma = dot(c, vec3(0.299, 0.587, 0.114));
	c = mix(vec3(luma), c, params.grade.x); // saturation
	c = pow(max(c, vec3(0.0)), vec3(1.0 / max(params.grade.w, 1e-5))); // gamma
	return c;
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(dst_image);
	if (any(greaterThanEqual(pixel, size))) {
		return;
	}
	vec2 texel = 1.0 / vec2(textureSize(src_image, 0));
	vec4 color = texture(src_image, (vec2(pixel) + 0.5) * texel);
	imageStore(dst_image, pixel, vec4(apply_grade(color.rgb), color.a));
}
