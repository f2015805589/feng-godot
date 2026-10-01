#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D src_image;
layout(rgba16f, set = 0, binding = 1) uniform restrict image2D dst_image;
layout(push_constant, std430) uniform Parameters {
	vec4 grade; // x: saturation, y: contrast, z: brightness, w: gamma
} params;

vec3 apply_grade(vec3 c) {
	// A sun brighter than RGBA16F can represent may already be Inf here.
	// Even neutral saturation would then evaluate Inf * 0 in mix(), turning
	// the pixel into NaN. Repair only invalid components before grading.
	c = mix(c, vec3(0.0), isnan(c));
	c = mix(c, clamp(c, vec3(0.0), vec3(65504.0)), isinf(c));
	c *= params.grade.z; // brightness
	c = (c - 0.5) * params.grade.y + 0.5; // contrast
	float luma = dot(c, vec3(0.299, 0.587, 0.114));
	c = mix(vec3(luma), c, params.grade.x); // saturation
	c = max(c, vec3(0.0));
	// pow(x, 1) is not necessarily an exact identity on the GPU: a small
	// approximation below 65504 can round down an entire half-float step.
	if (params.grade.w != 1.0) {
		c = pow(c, vec3(1.0 / max(params.grade.w, 1e-5))); // gamma
	}
	// Grading can itself exceed the destination's finite range. Keep the
	// representable HDR result rather than storing Inf for the tone mapper.
	return min(c, vec3(65504.0));
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(dst_image);
	if (any(greaterThanEqual(pixel, size))) {
		return;
	}
	// This pass grades the color attachment in place. Fetch exactly this
	// texel; filtering can read neighbors concurrently being written and
	// propagate a single invalid sun sample into otherwise finite pixels.
	vec4 color = texelFetch(src_image, pixel, 0);
	imageStore(dst_image, pixel, vec4(apply_grade(color.rgb), color.a));
}
