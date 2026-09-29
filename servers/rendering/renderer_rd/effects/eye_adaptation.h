/**************************************************************************/
/*  eye_adaptation.h                                                      */
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

#pragma once

#include "servers/rendering/renderer_rd/shaders/effects/eye_adaptation.glsl.gen.h"
#include "servers/rendering/renderer_rd/shaders/effects/eye_adaptation_histogram.glsl.gen.h"
#include "servers/rendering/renderer_rd/storage_rd/render_scene_buffers_rd.h"

#define RB_EYE_ADAPTATION_BUFFERS SNAME("eye_adaptation_buffers")

namespace RendererRD {

// UE-style eye adaptation: log-luminance histogram metering + exponential
// temporal adaptation. Replaces Luminance's mean-of-max reduction when the
// renderer opts in. The 1x1 luminance texture it produces carries
// buffer-space luminance so existing exposure consumers (tonemap, glow,
// FSR2) keep working unchanged.
class EyeAdaptation {
private:
	struct HistogramPushConstant {
		int32_t source_size[2];
		float log_min;
		float log_range_rcp;
		float pad[4];
	};

	struct AdaptationPushConstant {
		float exposure_adjust;
		float multiplier;
		float log_min;
		float log_range;
		float min_luminance;
		float max_luminance;
		float pixel_count;
		float set_immediate;
	};

	EyeAdaptationHistogramShaderRD histogram_shader;
	RID histogram_shader_version;
	RID histogram_pipeline;

	EyeAdaptationShaderRD adaptation_shader;
	RID adaptation_shader_version;
	RID adaptation_pipeline;

public:
	class EyeAdaptationBuffers : public RenderBufferCustomDataRD {
		GDCLASS(EyeAdaptationBuffers, RenderBufferCustomDataRD);

	public:
		RID params; // uint histogram[64] + float adapted_luminance
		RID luminance; // 1x1 R32F, buffer-space adapted luminance

		virtual void configure(RenderSceneBuffersRD *p_render_buffers) override;
		virtual void free_data() override;
	};

	Ref<EyeAdaptationBuffers> get_buffers(Ref<RenderSceneBuffersRD> p_render_buffers);
	RID get_current_luminance_buffer(Ref<RenderSceneBuffersRD> p_render_buffers);

	// Reads back the last adapted luminance (buffer space) for the caller to
	// drive the next frame's pre-exposure multiplier. Returns <= 0 when no
	// adaptation has run yet.
	float read_adapted_luminance(Ref<RenderSceneBuffersRD> p_render_buffers);

	void process(RID p_source_texture, const Size2i &p_source_size, Ref<EyeAdaptationBuffers> p_buffers,
			float p_min_luminance, float p_max_luminance, float p_adjust, float p_multiplier, bool p_set);

	EyeAdaptation();
	~EyeAdaptation();
};

} // namespace RendererRD
