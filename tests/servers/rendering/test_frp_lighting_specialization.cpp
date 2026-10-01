/**************************************************************************/
/*  test_frp_lighting_specialization.cpp                                */
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

TEST_FORCE_LINK(test_frp_lighting_specialization)

#include "servers/rendering/renderer_rd/frp_clustered/scene_shader_frp_clustered.h"

namespace TestFRPLightingSpecialization {

using ShaderSpecialization = RendererSceneRenderImplementation::SceneShaderFRPClustered::ShaderSpecialization;

TEST_CASE("[FRP] Lighting view variants occupy independent bounded pipeline slots") {
	bool occupied[ShaderSpecialization::LIGHTING_VIEW_VARIANT_COUNT] = {};
	for (uint32_t depth_fog = 0; depth_fog < 2; depth_fog++) {
		for (uint32_t soft_shadows = 0; soft_shadows < 2; soft_shadows++) {
			for (uint32_t area_light = 0; area_light < 2; area_light++) {
				ShaderSpecialization specialization = {};
				specialization.use_depth_fog = depth_fog;
				specialization.use_directional_soft_shadows = soft_shadows;
				specialization.cluster_has_area_light = area_light;
				const uint32_t variant = specialization.get_lighting_view_variant();
				REQUIRE(variant < ShaderSpecialization::LIGHTING_VIEW_VARIANT_COUNT);
				CHECK_FALSE(occupied[variant]);
				occupied[variant] = true;
				// Global quality must revalidate the same slot, never allocate an
				// unbounded new family or collide with another camera's flags.
				ShaderSpecialization quality = specialization;
				quality.directional_soft_shadow_samples = 16;
				quality.soft_shadow_samples = 32;
				quality.fog_use_legacy_blending = true;
				CHECK_EQ(variant, quality.get_lighting_view_variant());
				CHECK_FALSE(specialization.has_same_lighting_constants(quality));
			}
		}
	}
	for (bool used : occupied) {
		CHECK(used);
	}
}

TEST_CASE("[FRP] Lighting cache identity includes both shader constant words") {
	ShaderSpecialization first_camera = {};
	first_camera.use_light_projector = true;
	first_camera.use_light_soft_shadows = true;
	first_camera.directional_soft_shadow_samples = 16;
	ShaderSpecialization other_camera = first_camera;
	other_camera.use_depth_fog = true;
	CHECK_NE(first_camera.get_lighting_view_variant(), other_camera.get_lighting_view_variant());
	CHECK_FALSE(first_camera.has_same_lighting_constants(other_camera));

	// Returning to the first camera uses its original specialization without
	// invalidating it after the other view has rendered.
	ShaderSpecialization cached[ShaderSpecialization::LIGHTING_VIEW_VARIANT_COUNT] = {};
	cached[first_camera.get_lighting_view_variant()] = first_camera;
	cached[other_camera.get_lighting_view_variant()] = other_camera;
	CHECK(cached[first_camera.get_lighting_view_variant()].has_same_lighting_constants(first_camera));
	CHECK(cached[other_camera.get_lighting_view_variant()].has_same_lighting_constants(other_camera));

	ShaderSpecialization changed = first_camera;
	changed.fog_use_legacy_blending = true; // Second specialization word.
	CHECK_EQ(first_camera.get_lighting_view_variant(), changed.get_lighting_view_variant());
	CHECK_FALSE(first_camera.has_same_lighting_constants(changed));
	changed = first_camera;
	changed.projector_use_mipmaps = true; // First specialization word.
	CHECK_FALSE(first_camera.has_same_lighting_constants(changed));
	changed = first_camera;
	changed.packed_2 = 0xffffffff; // Not a lighting shader specialization constant.
	CHECK(first_camera.has_same_lighting_constants(changed));
}

} // namespace TestFRPLightingSpecialization
