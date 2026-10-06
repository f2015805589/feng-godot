/**************************************************************************/
/*  test_environment_tonemap_override.cpp                                 */
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

#include "tests/test_macros.h"

TEST_FORCE_LINK(test_environment_tonemap_override)

#include "core/math/math_funcs.h"
#include "servers/rendering/renderer_rd/effects/tone_mapper_ue_film_lut.h"
#include "servers/rendering/storage/environment_storage.h"

#include <cmath>
#include <cstring>

namespace TestEnvironmentTonemapOverride {

static void check_tonemap_parameters_equal(const RendererEnvironmentStorage::TonemapParameters &p_actual, const RendererEnvironmentStorage::TonemapParameters &p_expected) {
	for (int i = 0; i < 4; i++) {
		CHECK_EQ(p_actual.tonemapper_params[i], p_expected.tonemapper_params[i]);
	}
}

TEST_CASE("[Rendering] Explicit native tonemap overrides use their own parameters") {
	RendererEnvironmentStorage storage;
	RID source_env = storage.environment_allocate();
	storage.environment_initialize(source_env);
	storage.environment_set_tonemap(source_env, RSE::ENV_TONE_MAPPER_AGX, 1.0f, 3.5f);
	storage.environment_set_tonemap_agx_contrast(source_env, 1.7f);

	for (int mode = RSE::ENV_TONE_MAPPER_LINEAR; mode <= RSE::ENV_TONE_MAPPER_AGX; mode++) {
		RID matching_env = storage.environment_allocate();
		storage.environment_initialize(matching_env);
		storage.environment_set_tonemap(matching_env, RSE::EnvironmentToneMapper(mode), 1.0f, 3.5f);
		storage.environment_set_tonemap_agx_contrast(matching_env, 1.7f);

		const RendererEnvironmentStorage::TonemapParameters overridden = storage.environment_get_tonemap_parameters(source_env, false, 1.0f, mode);
		const RendererEnvironmentStorage::TonemapParameters expected = storage.environment_get_tonemap_parameters(matching_env, false, 1.0f);
		check_tonemap_parameters_equal(overridden, expected);
		CHECK_EQ(storage.environment_get_white(source_env, false, 1.0f, mode), storage.environment_get_white(matching_env, false, 1.0f));

		RID default_env = storage.environment_allocate();
		storage.environment_initialize(default_env);
		storage.environment_set_tonemap(default_env, RSE::EnvironmentToneMapper(mode), 1.0f, 1.0f);

		const RendererEnvironmentStorage::TonemapParameters without_env = storage.environment_get_tonemap_parameters(RID(), false, 1.0f, mode);
		const RendererEnvironmentStorage::TonemapParameters expected_without_env = storage.environment_get_tonemap_parameters(default_env, false, 1.0f);
		check_tonemap_parameters_equal(without_env, expected_without_env);
		CHECK_EQ(storage.environment_get_white(RID(), false, 1.0f, mode), storage.environment_get_white(default_env, false, 1.0f));

		storage.environment_free(default_env);
		storage.environment_free(matching_env);
	}

	// The no-override API remains driven by the stored Environment mode.
	const RendererEnvironmentStorage::TonemapParameters legacy = storage.environment_get_tonemap_parameters(source_env, false, 1.0f);
	const RendererEnvironmentStorage::TonemapParameters legacy_expected = storage.environment_get_tonemap_parameters(source_env, false, 1.0f, RSE::ENV_TONE_MAPPER_AGX);
	check_tonemap_parameters_equal(legacy, legacy_expected);
	storage.environment_free(source_env);
}

TEST_CASE("[Rendering] Explicit native overrides select the authored white for their effective mode") {
	RendererEnvironmentStorage storage;
	RID source_env = storage.environment_allocate();
	storage.environment_initialize(source_env);
	storage.environment_set_tonemap_with_authored_whites(source_env, RSE::ENV_TONE_MAPPER_AGX, 1.0f, 1.0f, 16.29f);

	for (int mode = RSE::ENV_TONE_MAPPER_LINEAR; mode <= RSE::ENV_TONE_MAPPER_AGX; mode++) {
		const RSE::EnvironmentToneMapper effective_mode = RSE::EnvironmentToneMapper(mode);
		const float expected_authored_white = effective_mode == RSE::ENV_TONE_MAPPER_AGX ? 16.29f : 1.0f;

		RID matching_env = storage.environment_allocate();
		storage.environment_initialize(matching_env);
		storage.environment_set_tonemap(matching_env, effective_mode, 1.0f, expected_authored_white);

		const RendererEnvironmentStorage::TonemapParameters overridden = storage.environment_get_tonemap_parameters(source_env, false, 1.0f, mode);
		const RendererEnvironmentStorage::TonemapParameters expected = storage.environment_get_tonemap_parameters(matching_env, false, 1.0f);
		check_tonemap_parameters_equal(overridden, expected);
		CHECK_EQ(storage.environment_get_white(source_env, false, 1.0f, mode), storage.environment_get_white(matching_env, false, 1.0f));

		storage.environment_free(matching_env);
	}

	// Inherit mode continues to use the current Environment mapper and its authored white.
	const RendererEnvironmentStorage::TonemapParameters inherited = storage.environment_get_tonemap_parameters(source_env, false, 1.0f);
	const RendererEnvironmentStorage::TonemapParameters inherited_expected = storage.environment_get_tonemap_parameters(source_env, false, 1.0f, RSE::ENV_TONE_MAPPER_AGX);
	check_tonemap_parameters_equal(inherited, inherited_expected);
	CHECK_EQ(storage.environment_get_white(source_env, false, 1.0f), 16.29f);

	// No Environment keeps the legacy authored-white fallback of 1.0 (AgX's existing minimum still applies).
	CHECK_EQ(storage.environment_get_white(RID(), false, 1.0f, RSE::ENV_TONE_MAPPER_AGX), 2.0f);

	// A storage Environment not synchronized from a scene Resource also defaults to white 1.0.
	RID default_storage_env = storage.environment_allocate();
	storage.environment_initialize(default_storage_env);
	CHECK_EQ(storage.environment_get_white(default_storage_env, false, 1.0f, RSE::ENV_TONE_MAPPER_AGX), 2.0f);
	storage.environment_free(default_storage_env);
	storage.environment_free(source_env);
}

TEST_CASE("[Rendering] UE 5.8 SDR film LUT keeps highlight headroom and finite texels") {
	const Vector<uint8_t> lut = RendererRD::ToneMapperUEFilmLUT::build_data();
	const int expected_size = RendererRD::ToneMapperUEFilmLUT::SIZE * RendererRD::ToneMapperUEFilmLUT::SIZE * RendererRD::ToneMapperUEFilmLUT::SIZE * 4 * int(sizeof(uint16_t));
	REQUIRE_EQ(lut.size(), expected_size);

	const uint8_t *bytes = lut.ptr();
	bool all_finite = true;
	bool rgb_payload_in_range = true;
	bool has_restored_headroom = false;
	for (int i = 0; i < expected_size / int(sizeof(uint16_t)); i++) {
		uint16_t half_value;
		std::memcpy(&half_value, bytes + i * int(sizeof(uint16_t)), sizeof(half_value));
		const float value = Math::half_to_float(half_value);
		all_finite &= std::isfinite(value);
		if ((i % 4) != 3) {
			rgb_payload_in_range &= value >= 0.0f && value <= 1.0f;
			has_restored_headroom |= value * 1.05f > 1.0f;
		}
	}
	CHECK(all_finite);
	CHECK(rgb_payload_in_range);
	CHECK(has_restored_headroom);

	auto read_gray = [&](int p_index) {
		const int texel = ((p_index * RendererRD::ToneMapperUEFilmLUT::SIZE + p_index) * RendererRD::ToneMapperUEFilmLUT::SIZE + p_index) * 4;
		uint16_t red;
		uint16_t green;
		uint16_t blue;
		std::memcpy(&red, bytes + (texel + 0) * int(sizeof(uint16_t)), sizeof(red));
		std::memcpy(&green, bytes + (texel + 1) * int(sizeof(uint16_t)), sizeof(green));
		std::memcpy(&blue, bytes + (texel + 2) * int(sizeof(uint16_t)), sizeof(blue));
		return ((Math::half_to_float(red) + Math::half_to_float(green) + Math::half_to_float(blue)) * 1.05f) / 3.0f;
	};
	// Sampling restores the 1.05 scale after 10-bit UNORM-emulated storage.
	// Log-lattice samples near 18% gray, diffuse white, and a highlight across
	// the shoulder must remain ordered after that scale is restored.
	CHECK_LE(read_gray(14), read_gray(19));
	CHECK_LE(read_gray(19), read_gray(23));
}

} // namespace TestEnvironmentTonemapOverride
