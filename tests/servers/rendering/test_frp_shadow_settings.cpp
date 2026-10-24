/**************************************************************************/
/*  test_frp_shadow_settings.cpp                                          */
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

#include "tests/test_macros.h"

TEST_FORCE_LINK(test_frp_shadow_settings)

#include "servers/rendering/frp_shadow_settings.h"

#include <limits>

namespace TestFRPShadowSettings {

TEST_CASE("[FRP] Shadow Pass settings require an explicit valid opt-in") {
	Dictionary parameters;
	parameters["cascade_count"] = 2;
	parameters["shadow_bias"] = 0.7;
	FRPShadowSettings settings = FRPShadowSettings::from_parameters(parameters);
	CHECK_FALSE(settings.enabled);
	CHECK_EQ(settings.get_light_param(RSE::LIGHT_PARAM_SHADOW_BIAS, 0.3f), 0.3f);
	parameters["shadow_settings_enabled"] = "true";
	CHECK_FALSE(FRPShadowSettings::from_parameters(parameters).enabled);
	parameters["shadow_settings_enabled"] = true;
	settings = FRPShadowSettings::from_parameters(parameters);
	CHECK(settings.enabled);
	CHECK_EQ(settings.get_csm_count(), 2);
	CHECK_EQ(settings.get_light_param(RSE::LIGHT_PARAM_SHADOW_BIAS, 0.3f), doctest::Approx(0.7f));
	// PCSS's shadow-only angular diameter must not replace the physical sun size
	// or any ordinary light property while its view's shadow override is active.
	CHECK_EQ(settings.get_light_param(RSE::LIGHT_PARAM_SIZE, 0.53f), 0.53f);
	CHECK_EQ(settings.get_light_param(RSE::LIGHT_PARAM_ENERGY, 3.5f), 3.5f);
	parameters["shadow_settings_enabled"] = false;
	CHECK_EQ(FRPShadowSettings::from_parameters(parameters).get_light_param(RSE::LIGHT_PARAM_SHADOW_BIAS, 0.3f), 0.3f);
}

TEST_CASE("[FRP] Shadow Pass meter boundaries stay exact across near planes and far clamps") {
	Dictionary parameters;
	parameters["shadow_settings_enabled"] = true;
	const FRPShadowSettings settings = FRPShadowSettings::from_parameters(parameters);
	real_t first_camera[5] = {};
	real_t second_camera[5] = {};
	settings.get_cascade_distances(0.05, 500.0, first_camera);
	settings.get_cascade_distances(5.0, 60.0, second_camera);
	CHECK_EQ(first_camera[0], doctest::Approx(0.05));
	CHECK_EQ(second_camera[0], 5.0);
	for (int i = 1; i < 4; i++) {
		CHECK_EQ(first_camera[i], settings.cascade_distances[i - 1]);
		CHECK_EQ(second_camera[i], first_camera[i]);
	}
	CHECK_EQ(first_camera[4], 100.0);
	CHECK_EQ(second_camera[4], 60.0);
	settings.get_cascade_distances(0.1, 0.1005, second_camera);
	CHECK_EQ(second_camera[4], real_t(0.1005));
	for (int i = 1; i <= 4; i++) {
		CHECK(second_camera[i] > second_camera[i - 1]);
		CHECK(second_camera[i] <= real_t(0.1005));
	}
	// A narrow camera range and out-of-order authored distances must still
	// produce nondegenerate, ordered projection/culler planes, within camera far.
	parameters["cascade_1_distance"] = 80.0;
	parameters["cascade_2_distance"] = 2.0;
	parameters["cascade_3_distance"] = 0.1;
	const FRPShadowSettings unordered = FRPShadowSettings::from_parameters(parameters);
	unordered.get_cascade_distances(10.0, 10.01, second_camera);
	for (int i = 1; i <= 4; i++) {
		CHECK(second_camera[i] > second_camera[i - 1]);
		CHECK(Math::is_finite(second_camera[i]));
		CHECK(second_camera[i] <= real_t(10.01));
	}
}

TEST_CASE("[FRP] Shadow Pass reservation consumes one slot and its unused distance stays inactive") {
	Dictionary parameters;
	parameters["shadow_settings_enabled"] = true;
	parameters["reserve_object_shadow_slot"] = true;
	const RSE::LightDirectionalShadowMode modes[4] = {
		RSE::LIGHT_DIRECTIONAL_SHADOW_ORTHOGONAL,
		RSE::LIGHT_DIRECTIONAL_SHADOW_PARALLEL_2_SPLITS,
		RSE::LIGHT_DIRECTIONAL_SHADOW_PARALLEL_3_SPLITS,
		RSE::LIGHT_DIRECTIONAL_SHADOW_PARALLEL_4_SPLITS,
	};
	for (int slots = 1; slots <= 4; slots++) {
		parameters["cascade_count"] = slots;
		const FRPShadowSettings settings = FRPShadowSettings::from_parameters(parameters);
		CHECK_EQ(settings.get_shadow_mode(), modes[slots - 1]);
		CHECK_EQ(settings.reserve_object_shadow_slot, slots > 1);
		CHECK_EQ(settings.get_csm_count(), MAX(slots - 1, 1));
		real_t distances[5] = {};
		settings.get_cascade_distances(0.1, 500.0, distances);
		CHECK_EQ(distances[settings.get_csm_count()], settings.cascade_distances[settings.get_csm_count() - 1]);
	}
	parameters["cascade_count"] = 4;
	CHECK_EQ(FRPShadowSettings::from_parameters(parameters).get_light_param(RSE::LIGHT_PARAM_SHADOW_MAX_DISTANCE, 1000.0f), 50.0f);
	parameters["reserve_object_shadow_slot"] = false;
	CHECK_EQ(FRPShadowSettings::from_parameters(parameters).get_light_param(RSE::LIGHT_PARAM_SHADOW_MAX_DISTANCE, 1000.0f), 100.0f);
}

TEST_CASE("[FRP] Shadow Pass validation rejects nonfinite values and bounds texture resolution") {
	Dictionary parameters;
	parameters["shadow_settings_enabled"] = true;
	parameters["cascade_resolution"] = 3000;
	CHECK_EQ(FRPShadowSettings::from_parameters(parameters).cascade_resolution, 4096);
	parameters["cascade_resolution"] = 1e30;
	parameters["cascade_count"] = 1e30;
	parameters["shadow_filter_quality"] = -30;
	parameters["shadow_bias"] = std::numeric_limits<double>::quiet_NaN();
	parameters["cascade_1_distance"] = std::numeric_limits<double>::infinity();
	FRPShadowSettings settings = FRPShadowSettings::from_parameters(parameters);
	CHECK_EQ(settings.cascade_resolution, 8192);
	CHECK_EQ(settings.cascade_count, 4);
	CHECK_EQ(settings.filter_quality, RSE::SHADOW_QUALITY_HARD);
	CHECK_EQ(settings.bias, doctest::Approx(0.1f));
	CHECK_EQ(settings.cascade_distances[0], 10.0);
	parameters["cascade_resolution"] = -100;
	parameters["cascade_count"] = -100;
	settings = FRPShadowSettings::from_parameters(parameters);
	CHECK_EQ(settings.cascade_resolution, 256);
	CHECK_EQ(settings.cascade_count, 1);
}

TEST_CASE("[FRP] Shadow Pass hard PCF and PCSS modes resolve consistent projection and filter inputs") {
	Dictionary parameters;
	parameters["shadow_settings_enabled"] = true;
	parameters["pcss_angular_diameter"] = 1.5;
	for (int filter = 0; filter <= 2; filter++) {
		parameters["shadow_filter"] = filter;
		const FRPShadowSettings settings = FRPShadowSettings::from_parameters(parameters);
		CHECK_EQ(settings.get_angular_diameter(), filter == 2 ? 1.5f : 0.0f);
		CHECK_EQ(settings.get_blur(), filter == 0 ? 0.0f : 1.0f);
		CHECK_EQ(settings.get_filter_quality(), filter == 0 ? RSE::SHADOW_QUALITY_HARD : RSE::SHADOW_QUALITY_SOFT_LOW);
	}
	parameters["shadow_filter_quality"] = RSE::SHADOW_QUALITY_HARD;
	CHECK_EQ(FRPShadowSettings::from_parameters(parameters).get_angular_diameter(), 0.0f);
	CHECK_EQ(FRPShadowSettings::from_parameters(parameters).get_blur(), 0.0f);
	parameters["shadow_filter_quality"] = RSE::SHADOW_QUALITY_SOFT_HIGH;
	parameters["shadow_blur"] = 0.0;
	CHECK_EQ(FRPShadowSettings::from_parameters(parameters).get_angular_diameter(), 0.0f);
}

} // namespace TestFRPShadowSettings
