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
// plane: that is the camera motion the background actually has.

#include "../effects/motion_vector_inc.glsl"

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D depth_buffer;
layout(rg16f, set = 0, binding = 1) uniform restrict image2D velocity_buffer;

layout(push_constant, std430) uniform Params {
	highp mat4 reprojection_matrix;
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
	imageStore(velocity_buffer, pos, vec4(derive_motion_vector(uv, depth, params.reprojection_matrix), 0.0f, 0.0f));
}
