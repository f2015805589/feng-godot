#[compute]
#version 450

// UE 5.7 PostProcessHistogramCommon.ush / PostProcessEyeAdaptation.usf.
#define NUM_BINS 64
#define WEIGHT_SCALE 524288.0
layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) buffer restrict EyeAdaptationBuffer {
	uint histogram[NUM_BINS];
	uint histogram_overflow[NUM_BINS];
	float adapted_exposure;
	float exposure_scale;
	float pad0;
	float pad1;
} state;
layout(set = 1, binding = 0) uniform sampler2D exposure_curve;
layout(r32f, set = 2, binding = 0) uniform writeonly image2D tonemap_exposure;

layout(push_constant, std430) uniform Params {
	float log_min;
	float log_range;
	float min_white_luminance;
	float max_white_luminance;
	float low_percent;
	float high_percent;
	float speed_up;
	float speed_down;
	float delta_time;
	float exposure_compensation;
	float manual_white_luminance;
	float force_target;
	float set_immediate;
	float metering_mode;
	float use_exposure_curve;
	float previous_pre_exposure;
} params;

void main() {
	float total = 0.0;
	for (uint i = 0u; i < NUM_BINS; ++i) {
		total += float(state.histogram[i]) / WEIGHT_SCALE + float(state.histogram_overflow[i]) * 8192.0;
	}
	float min_fraction_sum = total * params.low_percent;
	float max_fraction_sum = total * params.high_percent;
	float weighted_log_sum = 0.0;
	float retained = 0.0;
	for (uint i = 0u; i < NUM_BINS; ++i) {
		float count = float(state.histogram[i]) / WEIGHT_SCALE + float(state.histogram_overflow[i]) * 8192.0;
		float below = min(count, min_fraction_sum);
		count -= below;
		min_fraction_sum -= below;
		max_fraction_sum -= below;
		count = min(count, max_fraction_sum);
		max_fraction_sum -= count;
		weighted_log_sum += (params.log_min + float(i) / float(NUM_BINS - 1) * params.log_range) * count;
		retained += count;
		state.histogram[i] = 0u;
		state.histogram_overflow[i] = 0u;
	}
	float measured = exp2(weighted_log_sum / max(retained, 0.0001));
	float compensation = params.exposure_compensation;
	if (params.use_exposure_curve > 0.5) {
		float ev100 = log2(max(measured / 0.18, 0.0001));
		// UE's 64-sample LUT maps its [-10, 20] EV100 domain to texel centers.
		float lut_scale = 63.0 / (64.0 * 30.0);
		float curve_u = clamp(ev100 * lut_scale + 0.5 / 64.0 + 10.0 * lut_scale, 0.0, 1.0);
		compensation *= exp2(texture(exposure_curve, vec2(curve_u, 0.5)).r);
	}
	float min_average = min(params.min_white_luminance, params.max_white_luminance) * 0.18;
	float max_average = max(params.min_white_luminance, params.max_white_luminance) * 0.18;
	float target_exposure = clamp(measured, min_average, max_average) / 0.18;
	if (params.metering_mode > 1.5) {
		target_exposure = params.manual_white_luminance;
	}
	float old_exposure = compensation / max(state.exposure_scale, 1e-12);
	if (params.set_immediate > 0.5 || params.force_target > 0.5 || state.exposure_scale <= 0.0) {
		old_exposure = target_exposure;
	}
	float log_target = log2(max(target_exposure, 0.0001));
	float log_old = log2(max(old_exposure, 0.0001));
	float log_diff = log_target - log_old;
	float speed = log_diff > 0.0 ? params.speed_up : params.speed_down;
	float start_distance = 1.5;
	float start_time = start_distance / max(speed, 0.001);
	float exponential_m = (1.0 / 60.0) / ((1.0 - exp2(-speed / 60.0)) * start_time);
	// The 60 Hz slope correction can exceed one at high adaptation speeds.
	// Bound the interpolation weight, not just the final exposure limits: a
	// long frame must approach the target EV without crossing it and oscillating.
	float exponential_weight = clamp((1.0 - exp2(-params.delta_time * speed)) * exponential_m, 0.0, 1.0);
	float exponential = log_old + log_diff * exponential_weight;
	float linear = log_old + sign(log_diff) * min(abs(log_diff), params.delta_time * speed);
	float adapted = exp2(abs(log_diff) > start_distance ? linear : exponential);
	if (params.force_target > 0.5 || params.set_immediate > 0.5) {
		adapted = target_exposure;
	}
	adapted = clamp(adapted, min_average / 0.18, max_average / 0.18);
	state.adapted_exposure = adapted;
	state.exposure_scale = compensation / max(adapted, 0.0001);
	// Godot's Tonemap samples this reciprocal and multiplies the HDR color by
	// current exposure / previous scene pre-exposure, like UE's Tonemap pass.
	imageStore(tonemap_exposure, ivec2(0), vec4(params.previous_pre_exposure / max(state.exposure_scale, 1e-12), 0.0, 0.0, 0.0));
}
