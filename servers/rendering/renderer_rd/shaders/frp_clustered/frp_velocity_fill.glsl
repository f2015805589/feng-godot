#[compute]

#version 450

#VERSION_DEFINES

// Completes the frame's velocity attachment before the temporal resolve.
//
// The attachment holds a value only where the G-buffer pass drew geometry: the sky,
// and everything else the frame clears, keeps the engine's "no data" marker (-1, -1)
// (see the velocity attachment's clear colour). A temporal resolve cannot reproject
// those pixels from the marker - it reads it as a velocity, puts the lookup outside
// the frame and blends the current sample in whole, so the background never
// accumulates and a silhouette against it flickers with the jitter. Their depth is
// what they have to be reprojected by instead, and a background pixel sits on the far
// plane. For screen-space reprojection, treat it as a direction at infinity: keep
// camera rotation but discard the finite far-plane translation term. Changes in
// atmosphere radiance with camera altitude remain current-frame color changes.

#include "../effects/motion_vector_inc.glsl"

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D depth_buffer;
layout(rg16f, set = 0, binding = 1) uniform restrict image2D velocity_buffer;

layout(push_constant, std430) uniform Params {
	highp mat4 reprojection_matrix;
	highp vec4 sky_translation_clip_offset;
	vec2 resolution;
	uint pad[2];
}
params;

void main() {
	// Out of bounds check.
	if (any(greaterThanEqual(vec2(gl_GlobalInvocationID.xy), params.resolution))) {
		return;
	}

	ivec2 pos = ivec2(gl_GlobalInvocationID.xy);

	// The pixels the frame already has a motion vector for are left alone.
	if (!all(lessThanEqual(imageLoad(velocity_buffer, pos).xy, vec2(-1.0f)))) {
		return;
	}

	float depth = texelFetch(depth_buffer, pos, 0).x;
	vec2 uv = (vec2(pos) + 0.5f) / params.resolution;
	vec2 motion_vector;
	if (depth == 0.0f) {
		// Reverse-Z depth zero is the cleared background. Remove only the finite
		// far-plane translation term; camera rotation still reprojects the sky ray.
		vec4 current_clip_position = vec4(uv * 2.0f - 1.0f, depth * 2.0f - 1.0f, 1.0f);
		vec4 previous_clip_position = params.reprojection_matrix * current_clip_position - params.sky_translation_clip_offset;
		motion_vector = 0.5f + (previous_clip_position.xy / previous_clip_position.w) * 0.5f - uv;
	} else {
		motion_vector = derive_motion_vector(uv, depth, params.reprojection_matrix);
	}
	imageStore(velocity_buffer, pos, vec4(motion_vector, 0.0f, 0.0f));
}
