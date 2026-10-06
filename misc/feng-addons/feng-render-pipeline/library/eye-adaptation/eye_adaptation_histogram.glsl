#[compute]
#version 450

// UE 5.7 PostProcessHistogram: 64 log bins with fractional neighbouring weights.

#define BLOCK_SIZE 16
#define NUM_BINS 64
#define WEIGHT_SCALE 524288.0

layout(local_size_x = BLOCK_SIZE, local_size_y = BLOCK_SIZE, local_size_z = 1) in;

shared uint shared_bins[NUM_BINS];

layout(set = 0, binding = 0) uniform sampler2D source_texture;
layout(set = 0, binding = 1) uniform sampler2D meter_mask;

layout(set = 1, binding = 0, std430) buffer restrict EyeAdaptationBuffer {
	uint histogram[NUM_BINS];
	uint histogram_overflow[NUM_BINS];
	float adapted_exposure;
	float exposure_scale;
	float pad0;
	float pad1;
}
params_buffer;

layout(push_constant, std430) uniform Params {
	ivec2 source_size;
	float log_min;
	float log_range_rcp;
	float one_over_pre_exposure;
	float luminance_min;
	float black_bucket_influence;
	float use_meter_mask;
	float basic_mode;
	float minimum_meter_weight;
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
		vec3 color = texelFetch(source_texture, pos, 0).rgb * params.one_over_pre_exposure;
		// UE's default r.AutoExposure.LuminanceMethod=0 uses uniform RGB weights.
		float luminance = max(dot(color, vec3(1.0 / 3.0)), params.luminance_min);
		float log_luminance = log2(luminance);
		if (params.basic_mode > 0.5) {
			log_luminance = clamp(log_luminance, -10.0, 20.0);
		}
		float location = clamp((log_luminance - params.log_min) * params.log_range_rcp, 0.0, 1.0) * float(NUM_BINS - 1);
		if (any(isnan(color))) {
			location = 0.0;
		} else if (any(isinf(color))) {
			// Positive FP16 overflow is bright radiance, not the black bucket.
			// Discarding it would drive exposure up and keep the scene overflowed.
			bool positive_overflow = (isinf(color.r) && color.r > 0.0) ||
					(isinf(color.g) && color.g > 0.0) || (isinf(color.b) && color.b > 0.0);
			location = positive_overflow ? float(NUM_BINS - 1) : 0.0;
		}
		uint lower = min(uint(location), NUM_BINS - 1u);
		uint upper = min(lower + 1u, NUM_BINS - 1u);
		float upper_weight = fract(location);
		float screen_weight = params.use_meter_mask > 0.5 ? max(texture(meter_mask, (vec2(pos) + 0.5) / vec2(params.source_size)).r, params.minimum_meter_weight) : 1.0;
		float lower_weight = (1.0 - upper_weight) * (lower == 0u ? params.black_bucket_influence : 1.0) * screen_weight;
		upper_weight *= screen_weight;
		atomicAdd(shared_bins[lower], uint(lower_weight * WEIGHT_SCALE));
		atomicAdd(shared_bins[upper], uint(upper_weight * WEIGHT_SCALE));
	}

	groupMemoryBarrier();
	barrier();

	if (t < NUM_BINS) {
		uint bin_sum = shared_bins[t];
		if (bin_sum != 0u) {
			uint old_value = atomicAdd(params_buffer.histogram[t], bin_sum);
			if (old_value > 0xffffffffu - bin_sum) {
				atomicAdd(params_buffer.histogram_overflow[t], 1u);
			}
		}
	}
}
