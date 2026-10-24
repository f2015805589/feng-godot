/**************************************************************************/
/*  frp_shadow_settings.h                                                 */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
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

#pragma once

#include "core/math/math_funcs.h"
#include "core/math/math_funcs_binary.h"
#include "core/variant/dictionary.h"
#include "servers/rendering/rendering_server_enums.h"

// Immutable, render-thread snapshot of native pass 0's authored parameters.
// Missing settings preserve scene-authored shadows; merely selecting a resource
// in the Inspector cannot alter a view's lights or its shadow allocation.
struct FRPShadowSettings {
	bool enabled = false;
	int cascade_count = 4; // Total slots, including an optional reserved object slot.
	int cascade_resolution = 4096;
	real_t cascade_distances[4] = { 10.0, 25.0, 50.0, 100.0 };
	bool blend_cascades = true;
	float fade_start = 0.8f;
	float pancake_size = 20.0f;
	bool reserve_object_shadow_slot = false;
	int filter = 2; // Hard, PCF, PCSS.
	float angular_diameter = 0.5f;
	float blur = 1.0f;
	RSE::ShadowQuality filter_quality = RSE::SHADOW_QUALITY_SOFT_LOW;
	float bias = 0.1f;
	float normal_bias = 2.0f;
	float transmittance_bias = 0.05f;
	float opacity = 1.0f;

private:
	static double _number(const Dictionary &p_parameters, const char *p_name, double p_default, double p_min, double p_max) {
		const Variant value = p_parameters.get(p_name, Variant());
		if (!value.is_num() || !Math::is_finite(double(value))) {
			return p_default;
		}
		return CLAMP(double(value), p_min, p_max);
	}

	static bool _boolean(const Dictionary &p_parameters, const char *p_name, bool p_default) {
		const Variant value = p_parameters.get(p_name, Variant());
		return value.get_type() == Variant::BOOL ? bool(value) : p_default;
	}

public:
	static FRPShadowSettings from_parameters(const Dictionary &p_parameters) {
		FRPShadowSettings settings;
		settings.enabled = _boolean(p_parameters, "shadow_settings_enabled", false);
		if (!settings.enabled) {
			return settings;
		}
		settings.cascade_count = int(_number(p_parameters, "cascade_count", 4, 1, 4));
		settings.cascade_resolution = Math::nearest_power_of_2_templated(int(_number(p_parameters, "cascade_resolution", 4096, 256, 8192)));
		const char *distance_keys[4] = { "cascade_1_distance", "cascade_2_distance", "cascade_3_distance", "cascade_4_distance" };
		for (int i = 0; i < 4; i++) {
			settings.cascade_distances[i] = _number(p_parameters, distance_keys[i], settings.cascade_distances[i], 0.001, 1e9);
		}
		settings.blend_cascades = _boolean(p_parameters, "blend_cascades", true);
		settings.fade_start = _number(p_parameters, "shadow_fade_start", 0.8, 0.0, 1.0);
		settings.pancake_size = _number(p_parameters, "shadow_pancake_size", 20.0, 0.0, 1e9);
		settings.reserve_object_shadow_slot = settings.cascade_count > 1 && _boolean(p_parameters, "reserve_object_shadow_slot", false);
		settings.filter = int(_number(p_parameters, "shadow_filter", 2, 0, 2));
		// A right angle would make the projected PCSS expansion unbounded.
		settings.angular_diameter = _number(p_parameters, "pcss_angular_diameter", 0.5, 0.0, 89.0);
		settings.blur = _number(p_parameters, "shadow_blur", 1.0, 0.0, 64.0);
		settings.filter_quality = RSE::ShadowQuality(int(_number(p_parameters, "shadow_filter_quality", RSE::SHADOW_QUALITY_SOFT_LOW, RSE::SHADOW_QUALITY_HARD, RSE::SHADOW_QUALITY_MAX - 1)));
		settings.bias = _number(p_parameters, "shadow_bias", 0.1, 0.0, 1e6);
		settings.normal_bias = _number(p_parameters, "shadow_normal_bias", 2.0, 0.0, 1e6);
		settings.transmittance_bias = _number(p_parameters, "shadow_transmittance_bias", 0.05, 0.0, 1e6);
		settings.opacity = _number(p_parameters, "shadow_opacity", 1.0, 0.0, 1.0);
		return settings;
	}

	int get_csm_count() const { return cascade_count - (reserve_object_shadow_slot ? 1 : 0); }
	float get_angular_diameter() const { return filter == 2 && filter_quality != RSE::SHADOW_QUALITY_HARD && blur > 0.0f ? angular_diameter : 0.0f; }
	float get_blur() const { return filter == 0 || filter_quality == RSE::SHADOW_QUALITY_HARD ? 0.0f : blur; }
	RSE::ShadowQuality get_filter_quality() const { return filter == 0 ? RSE::SHADOW_QUALITY_HARD : filter_quality; }
	RSE::LightDirectionalShadowMode get_shadow_mode() const {
		const RSE::LightDirectionalShadowMode modes[4] = { RSE::LIGHT_DIRECTIONAL_SHADOW_ORTHOGONAL, RSE::LIGHT_DIRECTIONAL_SHADOW_PARALLEL_2_SPLITS, RSE::LIGHT_DIRECTIONAL_SHADOW_PARALLEL_3_SPLITS, RSE::LIGHT_DIRECTIONAL_SHADOW_PARALLEL_4_SPLITS };
		return modes[cascade_count - 1];
	}

	// One set of camera-view distances is shared by projection setup and the
	// tighter light culler. Converting meters to normalized offsets separately
	// would disagree at nonzero camera near planes and camera far clamps.
	void get_cascade_distances(real_t p_camera_near, real_t p_camera_far, real_t *r_distances) const {
		const int count = get_csm_count();
		const real_t camera_far = MAX(p_camera_far, p_camera_near);
		const real_t minimum_step = MIN(real_t(0.001), (camera_far - p_camera_near) / real_t(count + 1));
		const real_t far_distance = CLAMP(cascade_distances[count - 1], p_camera_near + minimum_step * count, camera_far);
		const real_t epsilon = MIN(real_t(0.001), (far_distance - p_camera_near) / real_t(count + 1));
		r_distances[0] = p_camera_near;
		for (int i = 1; i < count; i++) {
			r_distances[i] = CLAMP(cascade_distances[i - 1], r_distances[i - 1] + epsilon, far_distance - epsilon * (count - i));
		}
		r_distances[count] = far_distance;
	}

	// Only shadow parameters are overridden. In particular LIGHT_PARAM_SIZE
	// remains the authored sun/specular size; PCSS has its own shadow-only angle.
	float get_light_param(RSE::LightParam p_param, float p_authored) const {
		if (!enabled) {
			return p_authored;
		}
		switch (p_param) {
			case RSE::LIGHT_PARAM_SHADOW_MAX_DISTANCE:
				return cascade_distances[get_csm_count() - 1];
			case RSE::LIGHT_PARAM_SHADOW_FADE_START:
				return fade_start;
			case RSE::LIGHT_PARAM_SHADOW_PANCAKE_SIZE:
				return pancake_size;
			case RSE::LIGHT_PARAM_SHADOW_BLUR:
				return get_blur();
			case RSE::LIGHT_PARAM_SHADOW_BIAS:
				return bias;
			case RSE::LIGHT_PARAM_SHADOW_NORMAL_BIAS:
				return normal_bias;
			case RSE::LIGHT_PARAM_TRANSMITTANCE_BIAS:
				return transmittance_bias;
			case RSE::LIGHT_PARAM_SHADOW_OPACITY:
				return opacity;
			default:
				return p_authored;
		}
	}
};
