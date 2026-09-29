#[compute]
#version 450

// Histogram-based luminance metering for eye adaptation, matching UE's
// PostProcessHistogram approach (64 log bins over the metering range).
// Source: http://www.alextardif.com/HistogramLuminance.html

#define BLOCK_SIZE 16
#define NUM_BINS 64

layout(local_size_x = BLOCK_SIZE, local_size_y = BLOCK_SIZE, local_size_z = 1) in;

shared uint shared_bins[NUM_BINS];

layout(set = 0, binding = 0) uniform sampler2D source_texture;

layout(set = 1, binding = 0, std430) buffer restrict EyeAdaptationBuffer {
	uint histogram[NUM_BINS];
	float adapted_luminance;
	float pad0;
	float pad1;
	float pad2;
}
params_buffer;

layout(push_constant, std430) uniform Params {
	ivec2 source_size;
	float log_min;
	float log_range_rcp;
	vec4 pad;
}
params;

void main() {
	uint t = gl_LocalInvocationID.y * BLOCK_SIZE + gl_LocalInvocationID.x;
	if (t < NUM_BINS) {
		shared_bins[t] = 0;
	}

	groupMemoryBarrier();
	barrier();

	ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
	if (all(lessThan(pos, params.source_size))) {
		vec3 color = texelFetch(source_texture, pos, 0).rgb;
		float luminance = dot(color, vec3(0.2127, 0.7152, 0.0722));

		uint bin_index = 0;
		if (luminance > 0.0001 && !isinf(luminance) && !isnan(luminance)) {
			float log_luminance = clamp((log2(luminance) - params.log_min) * params.log_range_rcp, 0.0, 1.0);
			bin_index = 1 + uint(log_luminance * float(NUM_BINS - 2));
		}

		atomicAdd(shared_bins[bin_index], 1u);
	}

	groupMemoryBarrier();
	barrier();

	if (t < NUM_BINS) {
		atomicAdd(params_buffer.histogram[t], shared_bins[t]);
	}
}
