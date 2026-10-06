/**************************************************************************/
/*  tone_mapper_ue_film_lut.cpp                                           */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,     */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to   */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

#include "tone_mapper_ue_film_lut.h"

#include "core/math/math_defs.h"
#include "core/math/math_funcs.h"

#include <cmath>
#include <cstring>

namespace RendererRD::ToneMapperUEFilmLUT {

namespace {

constexpr int UE_FILM_LUT_SIZE = SIZE;

struct UEFilmVec3 {
	double x;
	double y;
	double z;
};

struct UEFilmMat3 {
	double m[3][3];
};

static UEFilmVec3 ue_film_mul(const UEFilmMat3 &p_matrix, const UEFilmVec3 &p_value) {
	return {
		p_matrix.m[0][0] * p_value.x + p_matrix.m[0][1] * p_value.y + p_matrix.m[0][2] * p_value.z,
		p_matrix.m[1][0] * p_value.x + p_matrix.m[1][1] * p_value.y + p_matrix.m[1][2] * p_value.z,
		p_matrix.m[2][0] * p_value.x + p_matrix.m[2][1] * p_value.y + p_matrix.m[2][2] * p_value.z,
	};
}

static UEFilmMat3 ue_film_mul(const UEFilmMat3 &p_a, const UEFilmMat3 &p_b) {
	UEFilmMat3 result = {};
	for (int row = 0; row < 3; row++) {
		for (int column = 0; column < 3; column++) {
			for (int inner = 0; inner < 3; inner++) {
				result.m[row][column] += p_a.m[row][inner] * p_b.m[inner][column];
			}
		}
	}
	return result;
}

static UEFilmVec3 ue_film_add(const UEFilmVec3 &p_a, const UEFilmVec3 &p_b) {
	return { p_a.x + p_b.x, p_a.y + p_b.y, p_a.z + p_b.z };
}

static UEFilmVec3 ue_film_scale(const UEFilmVec3 &p_value, double p_scale) {
	return { p_value.x * p_scale, p_value.y * p_scale, p_value.z * p_scale };
}

static UEFilmVec3 ue_film_lerp(const UEFilmVec3 &p_a, const UEFilmVec3 &p_b, double p_weight) {
	return ue_film_add(ue_film_scale(p_a, 1.0 - p_weight), ue_film_scale(p_b, p_weight));
}

static UEFilmVec3 ue_film_apply_blue_correction(const UEFilmVec3 &p_color, bool p_inverse) {
	static const UEFilmMat3 ap1_to_ap0 = { { { 0.6954522414, 0.1406786965, 0.1638690622 }, { 0.0447945634, 0.8596711185, 0.0955343182 }, { -0.0055258826, 0.0040252103, 1.0015006723 } } };
	static const UEFilmMat3 ap0_to_ap1 = { { { 1.4514393161, -0.2365107469, -0.2149285693 }, { -0.0765537734, 1.1762296998, -0.0996759264 }, { 0.0083161484, -0.0060324498, 0.9977163014 } } };
	static const UEFilmMat3 blue_correct = { { { 0.9404372683, -0.0183068787, 0.0778696104 }, { 0.0083786969, 0.8286599939, 0.1629613092 }, { 0.0005471261, -0.0008833746, 1.0003362486 } } };
	static const UEFilmMat3 blue_correct_inverse = { { { 1.06318, 0.0233956, -0.0865726 }, { -0.0106337, 1.20632, -0.19569 }, { -0.000590887, 0.00105248, 0.999538 } } };
	static const UEFilmMat3 blue_correct_ap1 = ue_film_mul(ap0_to_ap1, ue_film_mul(blue_correct, ap1_to_ap0));
	static const UEFilmMat3 blue_correct_inverse_ap1 = ue_film_mul(ap0_to_ap1, ue_film_mul(blue_correct_inverse, ap1_to_ap0));
	const UEFilmMat3 &correction = p_inverse ? blue_correct_inverse_ap1 : blue_correct_ap1;
	return ue_film_lerp(p_color, ue_film_mul(correction, p_color), 0.6);
}

static double ue_film_saturate(double p_value) {
	return CLAMP(p_value, 0.0, 1.0);
}

static double ue_film_smoothstep(double p_value) {
	const double t = ue_film_saturate(p_value);
	return t * t * (3.0 - 2.0 * t);
}

static double ue_film_log_to_linear(double p_log) {
	return std::exp2((p_log - 444.0 / 1023.0) * 14.0) * 0.18;
}

static double ue_film_rgb_saturation(const UEFilmVec3 &p_rgb) {
	const double minimum = MIN(p_rgb.x, MIN(p_rgb.y, p_rgb.z));
	const double maximum = MAX(p_rgb.x, MAX(p_rgb.y, p_rgb.z));
	return (MAX(maximum, 1e-10) - MAX(minimum, 1e-10)) / MAX(maximum, 1e-2);
}

static double ue_film_rgb_yc(const UEFilmVec3 &p_rgb) {
	const double chroma_radicand = p_rgb.z * (p_rgb.z - p_rgb.y) + p_rgb.y * (p_rgb.y - p_rgb.x) + p_rgb.x * (p_rgb.x - p_rgb.z);
	const double chroma = std::sqrt(MAX(chroma_radicand, 0.0));
	return (p_rgb.x + p_rgb.y + p_rgb.z + 1.75 * chroma) / 3.0;
}

static UEFilmVec3 ue_film_tone_map(const UEFilmVec3 &p_input_ap1) {
	static const UEFilmMat3 ap1_to_ap0 = { { { 0.6954522414, 0.1406786965, 0.1638690622 }, { 0.0447945634, 0.8596711185, 0.0955343182 }, { -0.0055258826, 0.0040252103, 1.0015006723 } } };
	static const UEFilmMat3 ap0_to_ap1 = { { { 1.4514393161, -0.2365107469, -0.2149285693 }, { -0.0765537734, 1.1762296998, -0.0996759264 }, { 0.0083161484, -0.0060324498, 0.9977163014 } } };
	static const double ap1_y[3] = { 0.2722287168, 0.6740817658, 0.0536895174 };

	UEFilmVec3 color_ap0 = ue_film_mul(ap1_to_ap0, p_input_ap1);
	const double saturation = ue_film_rgb_saturation(color_ap0);
	const double yc_input = ue_film_rgb_yc(color_ap0);
	const double sigmoid_x = (saturation - 0.4) / 0.2;
	const double sigmoid_t = MAX(1.0 - std::abs(0.5 * sigmoid_x), 0.0);
	const double sigmoid = 0.5 * (1.0 + ((sigmoid_x > 0.0) - (sigmoid_x < 0.0)) * (1.0 - sigmoid_t * sigmoid_t));
	const double glow_gain = 0.05 * sigmoid;
	double added_glow = glow_gain;
	if (yc_input <= 2.0 / 3.0 * 0.08) {
		added_glow = glow_gain;
	} else if (yc_input >= 2.0 * 0.08) {
		added_glow = 0.0;
	} else {
		added_glow = glow_gain * (0.08 / yc_input - 0.5);
	}
	color_ap0 = ue_film_scale(color_ap0, 1.0 + added_glow);

	double hue = 0.0;
	if (!(color_ap0.x == color_ap0.y && color_ap0.y == color_ap0.z)) {
		hue = (180.0 / Math::PI) * std::atan2(std::sqrt(3.0) * (color_ap0.y - color_ap0.z), 2.0 * color_ap0.x - color_ap0.y - color_ap0.z);
		if (hue < 0.0) {
			hue += 360.0;
		}
	}
	hue = CLAMP(hue, 0.0, 360.0);
	const double centered_hue = hue > 180.0 ? hue - 360.0 : hue;
	const double hue_weight = std::pow(ue_film_smoothstep(1.0 - std::abs(2.0 * centered_hue / 135.0)), 2.0);
	color_ap0.x += hue_weight * saturation * (0.03 - color_ap0.x) * (1.0 - 0.82);

	UEFilmVec3 working = ue_film_mul(ap0_to_ap1, color_ap0);
	working = { MAX(working.x, 0.0), MAX(working.y, 0.0), MAX(working.z, 0.0) };
	const double luma = working.x * ap1_y[0] + working.y * ap1_y[1] + working.z * ap1_y[2];
	working = ue_film_lerp({ luma, luma, luma }, working, 0.96);

	constexpr double slope = 0.88;
	constexpr double toe = 0.55;
	constexpr double shoulder = 0.26;
	constexpr double black_clip = 0.0;
	constexpr double white_clip = 0.04;
	const double toe_scale = 1.0 + black_clip - toe;
	const double shoulder_scale = 1.0 + white_clip - shoulder;
	const double in_match = 0.18;
	const double out_match = 0.18;
	const double bt = (out_match + black_clip) / toe_scale - 1.0;
	const double toe_match = std::log10(in_match) - 0.5 * std::log((1.0 + bt) / (1.0 - bt)) * (toe_scale / slope);
	const double straight_match = (1.0 - toe) / slope - toe_match;
	const double shoulder_match = shoulder / slope - straight_match;

	UEFilmVec3 tone_color;
	for (int i = 0; i < 3; i++) {
		const double value = i == 0 ? working.x : (i == 1 ? working.y : working.z);
		double tone = 0.0;
		if (value > 0.0) {
			const double log_color = std::log10(value);
			const double straight = slope * (log_color + straight_match);
			const double toe_value = -black_clip + (2.0 * toe_scale) / (1.0 + std::exp((-2.0 * slope / toe_scale) * (log_color - toe_match)));
			const double shoulder_value = (1.0 + white_clip) - (2.0 * shoulder_scale) / (1.0 + std::exp((2.0 * slope / shoulder_scale) * (log_color - shoulder_match)));
			const double toe_curve = log_color < toe_match ? toe_value : straight;
			const double shoulder_curve = log_color > shoulder_match ? shoulder_value : straight;
			double blend = ue_film_saturate((log_color - toe_match) / (shoulder_match - toe_match));
			if (shoulder_match < toe_match) {
				blend = 1.0 - blend;
			}
			blend = (3.0 - 2.0 * blend) * blend * blend;
			tone = toe_curve * (1.0 - blend) + shoulder_curve * blend;
		}
		if (i == 0) {
			tone_color.x = tone;
		} else if (i == 1) {
			tone_color.y = tone;
		} else {
			tone_color.z = tone;
		}
	}
	const double tone_luma = tone_color.x * ap1_y[0] + tone_color.y * ap1_y[1] + tone_color.z * ap1_y[2];
	tone_color = ue_film_lerp({ tone_luma, tone_luma, tone_luma }, tone_color, 0.93);
	tone_color = { MAX(tone_color.x, 0.0), MAX(tone_color.y, 0.0), MAX(tone_color.z, 0.0) };
	return tone_color;
}

static UEFilmVec3 ue_film_srgb_encode(const UEFilmVec3 &p_linear) {
	auto encode = [](double p_value) {
		return p_value < 0.00313067 ? 12.92 * p_value : 1.055 * std::pow(p_value, 1.0 / 2.4) - 0.055;
	};
	return { encode(p_linear.x), encode(p_linear.y), encode(p_linear.z) };
}

// Fixed UE 5.8 Film defaults from PostProcessCombineLUTs.cpp and
// PostProcessCombineLUTs.usf: SDR/Rec.709 with the default film slope, toe,
// shoulder, clips, blue correction, gamut expansion, and tone curve. This
// profile is the SDR film curve, not UE's PQ/HLG display transform.
static UEFilmVec3 ue_film_generate_entry(const UEFilmVec3 &p_log) {
	static const UEFilmMat3 srgb_to_xyz = { { { 0.4123907993, 0.3575843394, 0.1804807884 }, { 0.2126390059, 0.7151686788, 0.0721923154 }, { 0.0193308187, 0.1191947798, 0.9505321522 } } };
	static const UEFilmMat3 xyz_to_ap1 = { { { 1.6410233797, -0.3248032942, -0.2364246952 }, { -0.6636628587, 1.6153315917, 0.0167563477 }, { 0.0117218943, -0.0082844420, 0.9883948585 } } };
	static const UEFilmMat3 d65_to_d60 = { { { 1.0130349146, 0.0061052578, -0.0149709436 }, { 0.0076982301, 0.9981633521, -0.0050320385 }, { -0.0028413174, 0.0046851567, 0.9245061375 } } };
	static const UEFilmMat3 ap1_to_xyz = { { { 0.6624541811, 0.1340042065, 0.1561876870 }, { 0.2722287168, 0.6740817658, 0.0536895174 }, { -0.0055746495, 0.0040607335, 1.0103391003 } } };
	static const UEFilmMat3 d60_to_d65 = { { { 0.9872240087, -0.0061132286, 0.0159532883 }, { -0.0075983718, 1.0018614847, 0.0053300358 }, { 0.0030725771, -0.0050959615, 1.0816806031 } } };
	static const UEFilmMat3 xyz_to_srgb = { { { 3.2409699419, -1.5373831776, -0.4986107603 }, { -0.9692436363, 1.8759675015, 0.0415550574 }, { 0.0556300797, -0.2039769589, 1.0569715142 } } };
	static const UEFilmMat3 srgb_to_ap1 = ue_film_mul(ue_film_mul(xyz_to_ap1, d65_to_d60), srgb_to_xyz);
	static const UEFilmMat3 ap1_to_srgb = ue_film_mul(ue_film_mul(xyz_to_srgb, d60_to_d65), ap1_to_xyz);
	static const UEFilmMat3 wide_to_xyz = { { { 0.5441691, 0.2395926, 0.1666943 }, { 0.2394656, 0.7021530, 0.0583814 }, { -0.0023439, 0.0361834, 1.0552183 } } };
	static const UEFilmMat3 wide_to_ap1 = ue_film_mul(xyz_to_ap1, wide_to_xyz);
	static const UEFilmMat3 expand_mat = ue_film_mul(wide_to_ap1, ap1_to_srgb);
	static const double ap1_y[3] = { 0.2722287168, 0.6740817658, 0.0536895174 };

	const double black_offset = ue_film_log_to_linear(0.0);
	UEFilmVec3 scene_linear = {
		MAX(ue_film_log_to_linear(p_log.x) - black_offset, 0.0),
		MAX(ue_film_log_to_linear(p_log.y) - black_offset, 0.0),
		MAX(ue_film_log_to_linear(p_log.z) - black_offset, 0.0),
	};
	UEFilmVec3 color_ap1 = ue_film_mul(srgb_to_ap1, scene_linear);
	const double luma = color_ap1.x * ap1_y[0] + color_ap1.y * ap1_y[1] + color_ap1.z * ap1_y[2];
	if (luma > 1e-10) {
		const UEFilmVec3 chroma = ue_film_scale(color_ap1, 1.0 / luma);
		const UEFilmVec3 delta = { chroma.x - 1.0, chroma.y - 1.0, chroma.z - 1.0 };
		const double chroma_distance_squared = delta.x * delta.x + delta.y * delta.y + delta.z * delta.z;
		const double expand_amount = (1.0 - std::exp2(-4.0 * chroma_distance_squared)) * (1.0 - std::exp2(-4.0 * luma * luma));
		color_ap1 = ue_film_lerp(color_ap1, ue_film_mul(expand_mat, color_ap1), expand_amount);
	}

	color_ap1 = ue_film_apply_blue_correction(color_ap1, false);
	UEFilmVec3 tone_mapped = ue_film_tone_map(color_ap1);
	constexpr double tone_curve_amount = 1.0;
	UEFilmVec3 film_ap1 = ue_film_lerp(color_ap1, tone_mapped, tone_curve_amount);
	film_ap1 = ue_film_apply_blue_correction(film_ap1, true);
	UEFilmVec3 film_color = ue_film_mul(ap1_to_srgb, film_ap1);
	return ue_film_srgb_encode(film_color);
}

static void ue_film_store_half(uint8_t *p_pixels, int p_index, float p_value) {
	const uint16_t value = Math::make_half_float(p_value);
	std::memcpy(p_pixels + p_index * int(sizeof(value)), &value, sizeof(value));
}

static Vector<uint8_t> ue_film_build_lut_data() {
	Vector<uint8_t> data;
	data.resize(UE_FILM_LUT_SIZE * UE_FILM_LUT_SIZE * UE_FILM_LUT_SIZE * 4 * sizeof(uint16_t));
	uint8_t *pixels = data.ptrw();
	for (int b = 0; b < UE_FILM_LUT_SIZE; b++) {
		for (int g = 0; g < UE_FILM_LUT_SIZE; g++) {
			for (int r = 0; r < UE_FILM_LUT_SIZE; r++) {
				const UEFilmVec3 log_color = { double(r) / (UE_FILM_LUT_SIZE - 1), double(g) / (UE_FILM_LUT_SIZE - 1), double(b) / (UE_FILM_LUT_SIZE - 1) };
				const UEFilmVec3 out = ue_film_generate_entry(log_color);
				const int offset = ((b * UE_FILM_LUT_SIZE + g) * UE_FILM_LUT_SIZE + r) * 4;
				ue_film_store_half(pixels, offset + 0, float(out.x));
				ue_film_store_half(pixels, offset + 1, float(out.y));
				ue_film_store_half(pixels, offset + 2, float(out.z));
				ue_film_store_half(pixels, offset + 3, 1.0f);
			}
		}
	}
	return data;
}

} // namespace

Vector<uint8_t> build_data() {
	return ue_film_build_lut_data();
}

} // namespace RendererRD::ToneMapperUEFilmLUT
