#[compute]

#version 450

#VERSION_DEFINES

// Weighted log-average of the luminance histogram + exponential temporal
// adaptation, matching UE's PostProcessEyeAdaptation. Metering happens in
// pre-exposed buffer space; the multiplier maps it back to true luminance.

#define NUM_BINS 64

layout(local_size_x = NUM_BINS, local_size_y = 1, local_size_z = 1) in;

shared float shared_weighted[NUM_BINS];

layout(r32f, set = 0, binding = 0) uniform restrict writeonly image2D dest_luminance;

layout(set = 1, binding = 0, std430) buffer restrict EyeAdaptationBuffer {
	uint histogram[NUM_BINS];
	float adapted_luminance;
	float pad0;
	float pad1;
	float pad2;
}
params_buffer;

layout(push_constant, std430) uniform Params {
	float exposure_adjust; // adaptation speed * frame dt
	float multiplier; // luminance multiplier used when shading this frame (OneOverPreExposure)
	float log_min;
	float log_range;
	float min_luminance;
	float max_luminance;
	float pixel_count;
	float set_immediate;
}
params;

void main() {
	uint t = gl_LocalInvocationID.x;

	float count = float(params_buffer.histogram[t]);
	shared_weighted[t] = count * float(t);

	groupMemoryBarrier();
	barrier();

	for (uint size = NUM_BINS >> 1; size > 0; size >>= 1) {
		if (t < size) {
			shared_weighted[t] += shared_weighted[t + size];
		}
		groupMemoryBarrier();
		barrier();
	}

	if (t == 0) {
		// Bin 0 holds pixels below the metering floor; exclude them.
		float valid_count = max(params.pixel_count - float(params_buffer.histogram[0]), 1.0);
		float weighted_log_average = shared_weighted[0] / valid_count - 1.0;
		float measured = exp2(weighted_log_average / float(NUM_BINS - 2) * params.log_range + params.log_min);
		measured *= params.multiplier; // buffer space -> true luminance

		float adapted = params_buffer.adapted_luminance;
		if (params.set_immediate > 0.5 || adapted <= 0.0) {
			adapted = measured;
		} else {
			adapted = adapted + (measured - adapted) * (1.0 - exp(-params.exposure_adjust));
		}
		adapted = clamp(adapted, params.min_luminance, params.max_luminance);
		params_buffer.adapted_luminance = adapted;

		// Consumers of the luminance texture expect buffer-space luminance.
		imageStore(dest_luminance, ivec2(0), vec4(adapted / params.multiplier));
	}

	groupMemoryBarrier();
	barrier();

	params_buffer.histogram[t] = 0u; // clear for next frame
}
