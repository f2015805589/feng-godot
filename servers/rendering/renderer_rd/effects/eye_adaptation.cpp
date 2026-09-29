/**************************************************************************/
/*  eye_adaptation.cpp                                                    */
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
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

#include "eye_adaptation.h"

#include "core/math/math_funcs.h"
#include "servers/rendering/renderer_rd/storage_rd/material_storage.h"
#include "servers/rendering/renderer_rd/uniform_set_cache_rd.h"

using namespace RendererRD;

EyeAdaptation::EyeAdaptation() {
	{
		Vector<String> histogram_modes;
		histogram_modes.push_back("\n");

		histogram_shader.initialize(histogram_modes);
		histogram_shader_version = histogram_shader.version_create();
		histogram_pipeline = RD::get_singleton()->compute_pipeline_create(histogram_shader.version_get_shader(histogram_shader_version, 0));
	}
	{
		Vector<String> adaptation_modes;
		adaptation_modes.push_back("\n");

		adaptation_shader.initialize(adaptation_modes);
		adaptation_shader_version = adaptation_shader.version_create();
		adaptation_pipeline = RD::get_singleton()->compute_pipeline_create(adaptation_shader.version_get_shader(adaptation_shader_version, 0));
	}
}

EyeAdaptation::~EyeAdaptation() {
	histogram_shader.version_free(histogram_shader_version);
	adaptation_shader.version_free(adaptation_shader_version);
}

void EyeAdaptation::EyeAdaptationBuffers::configure(RenderSceneBuffersRD *p_render_buffers) {
	params = RD::get_singleton()->storage_buffer_create(64 * sizeof(uint32_t) + 4 * sizeof(float));

	RD::TextureFormat tf;
	tf.format = RD::DATA_FORMAT_R32_SFLOAT;
	tf.width = 1;
	tf.height = 1;
	tf.usage_bits = RD::TEXTURE_USAGE_STORAGE_BIT | RD::TEXTURE_USAGE_SAMPLING_BIT | RD::TEXTURE_USAGE_CAN_COPY_FROM_BIT | RD::TEXTURE_USAGE_CAN_COPY_TO_BIT;
	luminance = RD::get_singleton()->texture_create(tf, RD::TextureView());
	RD::get_singleton()->texture_clear(luminance, Color(0.0, 0.0, 0.0), 0u, 1u, 0u, 1u);
}

void EyeAdaptation::EyeAdaptationBuffers::free_data() {
	if (params.is_valid()) {
		RD::get_singleton()->free_rid(params);
		params = RID();
	}
	if (luminance.is_valid()) {
		RD::get_singleton()->free_rid(luminance);
		luminance = RID();
	}
}

Ref<EyeAdaptation::EyeAdaptationBuffers> EyeAdaptation::get_buffers(Ref<RenderSceneBuffersRD> p_render_buffers) {
	if (p_render_buffers->has_custom_data(RB_EYE_ADAPTATION_BUFFERS)) {
		return p_render_buffers->get_custom_data(RB_EYE_ADAPTATION_BUFFERS);
	}

	Ref<EyeAdaptationBuffers> buffers;
	buffers.instantiate();
	buffers->configure(p_render_buffers.ptr());

	p_render_buffers->set_custom_data(RB_EYE_ADAPTATION_BUFFERS, buffers);

	return buffers;
}

RID EyeAdaptation::get_current_luminance_buffer(Ref<RenderSceneBuffersRD> p_render_buffers) {
	if (p_render_buffers->has_custom_data(RB_EYE_ADAPTATION_BUFFERS)) {
		Ref<EyeAdaptationBuffers> buffers = p_render_buffers->get_custom_data(RB_EYE_ADAPTATION_BUFFERS);
		return buffers->luminance;
	}

	return RID();
}

float EyeAdaptation::read_adapted_luminance(Ref<RenderSceneBuffersRD> p_render_buffers) {
	if (!p_render_buffers->has_custom_data(RB_EYE_ADAPTATION_BUFFERS)) {
		return -1.0f;
	}
	Ref<EyeAdaptationBuffers> buffers = p_render_buffers->get_custom_data(RB_EYE_ADAPTATION_BUFFERS);

	Vector<uint8_t> data = RD::get_singleton()->texture_get_data(buffers->luminance, 0);
	if (data.size() != (int)sizeof(float)) {
		return -1.0f;
	}
	float adapted;
	memcpy(&adapted, data.ptr(), sizeof(float));
	return adapted;
}

void EyeAdaptation::process(RID p_source_texture, const Size2i &p_source_size, Ref<EyeAdaptationBuffers> p_buffers,
		float p_min_luminance, float p_max_luminance, float p_adjust, float p_multiplier, bool p_set) {
	UniformSetCacheRD *uniform_set_cache = UniformSetCacheRD::get_singleton();
	ERR_FAIL_NULL(uniform_set_cache);
	MaterialStorage *material_storage = MaterialStorage::get_singleton();
	ERR_FAIL_NULL(material_storage);

	RID default_sampler = material_storage->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_LINEAR, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);

	const double inv_log2 = 1.0 / Math::log(2.0);
	float log_min = float(Math::log(MAX(double(p_min_luminance), 0.0001)) * inv_log2);
	float log_max = float(Math::log(MAX(double(p_max_luminance), double(p_min_luminance))) * inv_log2);

	RD::ComputeListID compute_list = RD::get_singleton()->compute_list_begin();

	{
		// Bin the frame's luminance (buffer space).
		HistogramPushConstant push_constant;
		memset(&push_constant, 0, sizeof(HistogramPushConstant));
		push_constant.source_size[0] = p_source_size.x;
		push_constant.source_size[1] = p_source_size.y;
		push_constant.log_min = log_min;
		push_constant.log_range_rcp = 1.0f / MAX(log_max - log_min, 0.001f);

		RID shader = histogram_shader.version_get_shader(histogram_shader_version, 0);
		RD::Uniform u_source_texture(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, Vector<RID>({ default_sampler, p_source_texture }));
		RD::Uniform u_params(RD::UNIFORM_TYPE_STORAGE_BUFFER, 0, p_buffers->params);

		RD::get_singleton()->compute_list_bind_compute_pipeline(compute_list, histogram_pipeline);
		RD::get_singleton()->compute_list_bind_uniform_set(compute_list, uniform_set_cache->get_cache(shader, 0, u_source_texture), 0);
		RD::get_singleton()->compute_list_bind_uniform_set(compute_list, uniform_set_cache->get_cache(shader, 1, u_params), 1);
		RD::get_singleton()->compute_list_set_push_constant(compute_list, &push_constant, sizeof(HistogramPushConstant));
		RD::get_singleton()->compute_list_dispatch_threads(compute_list, p_source_size.x, p_source_size.y, 1);

		RD::get_singleton()->compute_list_add_barrier(compute_list);
	}

	{
		// Adapt towards the weighted log-average and publish buffer-space luminance.
		AdaptationPushConstant push_constant;
		memset(&push_constant, 0, sizeof(AdaptationPushConstant));
		push_constant.exposure_adjust = p_adjust;
		push_constant.multiplier = MAX(p_multiplier, 0.0001f);
		push_constant.log_min = log_min;
		push_constant.log_range = log_max - log_min;
		push_constant.min_luminance = p_min_luminance;
		push_constant.max_luminance = p_max_luminance;
		push_constant.pixel_count = float(p_source_size.x) * float(p_source_size.y);
		push_constant.set_immediate = p_set ? 1.0f : 0.0f;

		RID shader = adaptation_shader.version_get_shader(adaptation_shader_version, 0);
		RD::Uniform u_dest(RD::UNIFORM_TYPE_IMAGE, 0, p_buffers->luminance);
		RD::Uniform u_params(RD::UNIFORM_TYPE_STORAGE_BUFFER, 0, p_buffers->params);

		RD::get_singleton()->compute_list_bind_compute_pipeline(compute_list, adaptation_pipeline);
		RD::get_singleton()->compute_list_bind_uniform_set(compute_list, uniform_set_cache->get_cache(shader, 0, u_dest), 0);
		RD::get_singleton()->compute_list_bind_uniform_set(compute_list, uniform_set_cache->get_cache(shader, 1, u_params), 1);
		RD::get_singleton()->compute_list_set_push_constant(compute_list, &push_constant, sizeof(AdaptationPushConstant));
		RD::get_singleton()->compute_list_dispatch_threads(compute_list, 64, 1, 1);
	}

	RD::get_singleton()->compute_list_end();
}
