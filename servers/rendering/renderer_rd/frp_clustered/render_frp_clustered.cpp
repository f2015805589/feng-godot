/**************************************************************************/
/*  render_frp_clustered.cpp                                          */
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

#include "render_frp_clustered.h"

#include "core/config/project_settings.h"
#include "frp_pass_context.h"
#include "servers/rendering/renderer_rd/environment/fog.h"
#include "servers/rendering/renderer_rd/framebuffer_cache_rd.h"
#include "servers/rendering/renderer_rd/storage_rd/light_storage.h"
#include "servers/rendering/renderer_rd/storage_rd/mesh_storage.h"
#include "servers/rendering/renderer_rd/storage_rd/particles_storage.h"
#include "servers/rendering/renderer_rd/storage_rd/texture_storage.h"
#include "servers/rendering/renderer_rd/uniform_set_cache_rd.h"
#include "servers/rendering/rendering_device.h"
#include "servers/rendering/rendering_server.h"
#include "servers/rendering/rendering_server_default.h"
#include "servers/rendering/storage/compositor_storage.h"
#include "servers/rendering/storage/ltc_lut.gen.h"

#include "modules/modules_enabled.gen.h" // IWYU pragma: keep.
#if defined(TOOLS_ENABLED) && defined(MODULE_FENG_RENDERDOC_ENABLED)
#include "modules/feng_renderdoc/feng_renderdoc.h"
#endif

using namespace RendererSceneRenderImplementation;

#define PRELOAD_PIPELINES_ON_SURFACE_CACHE_CONSTRUCTION 1

#define FADE_ALPHA_PASS_THRESHOLD 0.999

// A pass label is only emitted by RenderingDeviceGraph when at least one graph
// command belongs to it.  Keep configured FRP passes visible in captures even
// when their actual operation has no work this frame.  This callback is
// intentionally empty: it records no GPU command and has no resource usage.
static void _frp_pass_debug_marker(RDD *, RDD::CommandBufferID, void *) {
}

// A GPU capture tool needs every pass label to own the work it names. The default pass
// order has no user-authored boundaries, so the command graph is normally free to move
// work between passes; in a capture that shows up as pass labels running empty while the
// real draws land under a later scope of the same name, which makes the frame unreadable.
// Pin the order only while a capture tool is attached, so a normal run keeps the
// scheduling freedom the default order is there for.
static bool _capture_tool_attached() {
#if defined(TOOLS_ENABLED) && defined(MODULE_FENG_RENDERDOC_ENABLED)
	return FengRenderDoc::is_hooked();
#else
	return false;
#endif
}

void RenderFRPClustered::RenderBufferDataFRPClustered::ensure_specular() {
	ERR_FAIL_NULL(render_buffers);

	if (!render_buffers->has_texture(RB_SCOPE_FRP_CLUSTERED, RB_TEX_SPECULAR)) {
		bool msaa = render_buffers->get_msaa_3d() != RSE::VIEWPORT_MSAA_DISABLED;
		render_buffers->create_texture(RB_SCOPE_FRP_CLUSTERED, RB_TEX_SPECULAR, get_specular_format(), get_specular_usage_bits(msaa, false, render_buffers->get_can_be_storage()));
		if (msaa) {
			render_buffers->create_texture(RB_SCOPE_FRP_CLUSTERED, RB_TEX_SPECULAR_MSAA, get_specular_format(), get_specular_usage_bits(false, msaa, render_buffers->get_can_be_storage()), render_buffers->get_texture_samples());
		}
	}
}

void RenderFRPClustered::RenderBufferDataFRPClustered::ensure_normal_roughness_texture() {
	ERR_FAIL_NULL(render_buffers);

	if (!render_buffers->has_texture(RB_SCOPE_FRP_CLUSTERED, RB_TEX_NORMAL_ROUGHNESS)) {
		bool msaa = render_buffers->get_msaa_3d() != RSE::VIEWPORT_MSAA_DISABLED;
		render_buffers->create_texture(RB_SCOPE_FRP_CLUSTERED, RB_TEX_NORMAL_ROUGHNESS, get_normal_roughness_format(), get_normal_roughness_usage_bits(msaa, false, render_buffers->get_can_be_storage()));
		if (msaa) {
			render_buffers->create_texture(RB_SCOPE_FRP_CLUSTERED, RB_TEX_NORMAL_ROUGHNESS_MSAA, get_normal_roughness_format(), get_normal_roughness_usage_bits(false, msaa, render_buffers->get_can_be_storage()), render_buffers->get_texture_samples());
		}
	}
}

void RenderFRPClustered::RenderBufferDataFRPClustered::ensure_gbuffer() {
	ERR_FAIL_NULL(render_buffers);

	if (!render_buffers->has_texture(RB_SCOPE_FRP_CLUSTERED, RB_TEX_GBUFFER_ALBEDO)) {
		bool msaa = render_buffers->get_msaa_3d() != RSE::VIEWPORT_MSAA_DISABLED;
		render_buffers->create_texture(RB_SCOPE_FRP_CLUSTERED, RB_TEX_GBUFFER_ALBEDO, get_gbuffer_albedo_format(), get_gbuffer_albedo_usage_bits(msaa, false, render_buffers->get_can_be_storage()));
		if (msaa) {
			render_buffers->create_texture(RB_SCOPE_FRP_CLUSTERED, RB_TEX_GBUFFER_ALBEDO_MSAA, get_gbuffer_albedo_format(), get_gbuffer_albedo_usage_bits(false, msaa, render_buffers->get_can_be_storage()), render_buffers->get_texture_samples());
		}
	}
	if (!render_buffers->has_texture(RB_SCOPE_FRP_CLUSTERED, RB_TEX_GBUFFER_ORM)) {
		bool msaa = render_buffers->get_msaa_3d() != RSE::VIEWPORT_MSAA_DISABLED;
		render_buffers->create_texture(RB_SCOPE_FRP_CLUSTERED, RB_TEX_GBUFFER_ORM, get_gbuffer_orm_format(), get_gbuffer_orm_usage_bits(msaa, false, render_buffers->get_can_be_storage()));
		if (msaa) {
			render_buffers->create_texture(RB_SCOPE_FRP_CLUSTERED, RB_TEX_GBUFFER_ORM_MSAA, get_gbuffer_orm_format(), get_gbuffer_orm_usage_bits(false, msaa, render_buffers->get_can_be_storage()), render_buffers->get_texture_samples());
		}
	}
	// Roughness lives in orm.g rather than folded into normal_roughness.a. FRP is the
	// only renderer that lays its G-buffer out this way, and it runs no shared code
	// that decodes roughness (no GI), so nothing else has to be told about it.
	if (!render_buffers->has_texture(RB_SCOPE_FRP_CLUSTERED, RB_TEX_GBUFFER_EMISSION)) {
		bool msaa = render_buffers->get_msaa_3d() != RSE::VIEWPORT_MSAA_DISABLED;
		render_buffers->create_texture(RB_SCOPE_FRP_CLUSTERED, RB_TEX_GBUFFER_EMISSION, get_gbuffer_emission_format(), get_gbuffer_emission_usage_bits(msaa, false, render_buffers->get_can_be_storage()));
		if (msaa) {
			render_buffers->create_texture(RB_SCOPE_FRP_CLUSTERED, RB_TEX_GBUFFER_EMISSION_MSAA, get_gbuffer_emission_format(), get_gbuffer_emission_usage_bits(false, msaa, render_buffers->get_can_be_storage()), render_buffers->get_texture_samples());
		}
	}
}

void RenderFRPClustered::RenderBufferDataFRPClustered::ensure_fsr2(RendererRD::FSR2Effect *p_effect) {
	if (fsr2_context == nullptr) {
		fsr2_context = p_effect->create_context(render_buffers->get_internal_size(), render_buffers->get_target_size());
	}
}

#ifdef METAL_MFXTEMPORAL_ENABLED
bool RenderFRPClustered::RenderBufferDataFRPClustered::ensure_mfx_temporal(RendererRD::MFXTemporalEffect *p_effect) {
	if (mfx_temporal_context == nullptr) {
		RendererRD::MFXTemporalEffect::CreateParams params;
		params.input_size = render_buffers->get_internal_size();
		params.output_size = render_buffers->get_target_size();
		params.input_format = render_buffers->get_base_data_format();
		params.depth_format = render_buffers->get_depth_format(false, false, render_buffers->get_can_be_storage());
		params.motion_format = render_buffers->get_velocity_format();
		params.reactive_format = render_buffers->get_base_data_format(); // Reactive is derived from input.
		params.output_format = render_buffers->get_base_data_format();
		params.motion_vector_scale = render_buffers->get_internal_size();
		mfx_temporal_context = p_effect->create_context(params);
		return true;
	}
	return false;
}
#endif

void RenderFRPClustered::RenderBufferDataFRPClustered::free_data() {
	// JIC, should already have been cleared
	if (render_buffers) {
		render_buffers->clear_context(RB_SCOPE_FRP_CLUSTERED);
		render_buffers->clear_context(RB_SCOPE_SSDS);
	}

	if (cluster_builder) {
		memdelete(cluster_builder);
		cluster_builder = nullptr;
	}

	if (fsr2_context) {
		memdelete(fsr2_context);
		fsr2_context = nullptr;
	}

#ifdef METAL_MFXTEMPORAL_ENABLED
	if (mfx_temporal_context) {
		memdelete(mfx_temporal_context);
		mfx_temporal_context = nullptr;
	}
#endif

}

void RenderFRPClustered::RenderBufferDataFRPClustered::configure(RenderSceneBuffersRD *p_render_buffers) {
	if (render_buffers) {
		// JIC
		free_data();
	}

	render_buffers = p_render_buffers;
	ERR_FAIL_NULL(render_buffers);

	if (cluster_builder == nullptr) {
		cluster_builder = memnew(ClusterBuilderRD);
	}
	cluster_builder->set_shared(RenderFRPClustered::get_singleton()->get_cluster_builder_shared());

	RID sampler = RendererRD::MaterialStorage::get_singleton()->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_NEAREST, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);
	cluster_builder->setup(p_render_buffers->get_internal_size(), p_render_buffers->get_max_cluster_elements(), p_render_buffers->get_depth_texture(), sampler, p_render_buffers->get_internal_texture());
}

RID RenderFRPClustered::RenderBufferDataFRPClustered::get_color_only_fb() {
	ERR_FAIL_NULL_V(render_buffers, RID());

	bool use_msaa = render_buffers->get_msaa_3d() != RSE::VIEWPORT_MSAA_DISABLED;

	RID color = use_msaa ? render_buffers->get_texture(RB_SCOPE_BUFFERS, RB_TEX_COLOR_MSAA) : render_buffers->get_internal_texture();
	RID depth = use_msaa ? render_buffers->get_texture(RB_SCOPE_BUFFERS, RB_TEX_DEPTH_MSAA) : render_buffers->get_depth_texture();

	if (render_buffers->has_texture(RB_SCOPE_VRS, RB_TEXTURE)) {
		RID vrs_texture = render_buffers->get_texture(RB_SCOPE_VRS, RB_TEXTURE);
		return FramebufferCacheRD::get_singleton()->get_cache_multiview(render_buffers->get_view_count(), color, depth, vrs_texture);
	} else {
		return FramebufferCacheRD::get_singleton()->get_cache_multiview(render_buffers->get_view_count(), color, depth);
	}
}

RID RenderFRPClustered::RenderBufferDataFRPClustered::get_color_pass_fb(uint32_t p_color_pass_flags) {
	ERR_FAIL_NULL_V(render_buffers, RID());
	bool use_msaa = render_buffers->get_msaa_3d() != RSE::VIEWPORT_MSAA_DISABLED;

	int v_count = (p_color_pass_flags & COLOR_PASS_FLAG_MULTIVIEW) ? render_buffers->get_view_count() : 1;
	RID color = use_msaa ? render_buffers->get_texture(RB_SCOPE_BUFFERS, RB_TEX_COLOR_MSAA) : render_buffers->get_internal_texture();

	RID specular;
	if (p_color_pass_flags & COLOR_PASS_FLAG_SEPARATE_SPECULAR) {
		ensure_specular();
		specular = render_buffers->get_texture(RB_SCOPE_FRP_CLUSTERED, use_msaa ? RB_TEX_SPECULAR_MSAA : RB_TEX_SPECULAR);
	}

	RID velocity_buffer;
	if (p_color_pass_flags & COLOR_PASS_FLAG_MOTION_VECTORS) {
		render_buffers->ensure_velocity();
		velocity_buffer = render_buffers->get_velocity_buffer(use_msaa);
	}

	RID depth = use_msaa ? render_buffers->get_texture(RB_SCOPE_BUFFERS, RB_TEX_DEPTH_MSAA) : render_buffers->get_depth_texture();

	if (render_buffers->has_texture(RB_SCOPE_VRS, RB_TEXTURE)) {
		RID vrs_texture = render_buffers->get_texture(RB_SCOPE_VRS, RB_TEXTURE);
		return FramebufferCacheRD::get_singleton()->get_cache_multiview(v_count, color, specular, velocity_buffer, depth, vrs_texture);
	} else {
		return FramebufferCacheRD::get_singleton()->get_cache_multiview(v_count, color, specular, velocity_buffer, depth);
	}
}

RID RenderFRPClustered::RenderBufferDataFRPClustered::get_depth_fb(DepthFrameBufferType p_type) {
	ERR_FAIL_NULL_V(render_buffers, RID());
	bool use_msaa = render_buffers->get_msaa_3d() != RSE::VIEWPORT_MSAA_DISABLED;

	RID depth = use_msaa ? render_buffers->get_texture(RB_SCOPE_BUFFERS, RB_TEX_DEPTH_MSAA) : render_buffers->get_depth_texture();

	switch (p_type) {
		case DEPTH_FB: {
			return FramebufferCacheRD::get_singleton()->get_cache_multiview(render_buffers->get_view_count(), depth);
		} break;
		case DEPTH_FB_ROUGHNESS: {
			ensure_normal_roughness_texture();

			RID normal_roughness_buffer = render_buffers->get_texture(RB_SCOPE_FRP_CLUSTERED, use_msaa ? RB_TEX_NORMAL_ROUGHNESS_MSAA : RB_TEX_NORMAL_ROUGHNESS);

			return FramebufferCacheRD::get_singleton()->get_cache_multiview(render_buffers->get_view_count(), depth, normal_roughness_buffer);
		} break;
		case DEPTH_FB_GBUFFER: {
			// Attachment order matches the shader: normal, albedo, ORM, emission.
			ensure_normal_roughness_texture();
			ensure_gbuffer();

			RID normal_roughness_buffer = render_buffers->get_texture(RB_SCOPE_FRP_CLUSTERED, use_msaa ? RB_TEX_NORMAL_ROUGHNESS_MSAA : RB_TEX_NORMAL_ROUGHNESS);
			RID albedo_buffer = render_buffers->get_texture(RB_SCOPE_FRP_CLUSTERED, use_msaa ? RB_TEX_GBUFFER_ALBEDO_MSAA : RB_TEX_GBUFFER_ALBEDO);
			RID orm_buffer = render_buffers->get_texture(RB_SCOPE_FRP_CLUSTERED, use_msaa ? RB_TEX_GBUFFER_ORM_MSAA : RB_TEX_GBUFFER_ORM);
			RID emission_buffer = render_buffers->get_texture(RB_SCOPE_FRP_CLUSTERED, use_msaa ? RB_TEX_GBUFFER_EMISSION_MSAA : RB_TEX_GBUFFER_EMISSION);
			return FramebufferCacheRD::get_singleton()->get_cache_multiview(render_buffers->get_view_count(), depth, normal_roughness_buffer, albedo_buffer, orm_buffer, emission_buffer);
		} break;
		case DEPTH_FB_GBUFFER_MOTION: {
			// Attachment order matches shader outputs: normal, albedo, ORM, emission,
			// then motion vectors.
			ensure_normal_roughness_texture();
			ensure_gbuffer();
			render_buffers->ensure_velocity();

			RID normal_roughness_buffer = render_buffers->get_texture(RB_SCOPE_FRP_CLUSTERED, use_msaa ? RB_TEX_NORMAL_ROUGHNESS_MSAA : RB_TEX_NORMAL_ROUGHNESS);
			RID albedo_buffer = render_buffers->get_texture(RB_SCOPE_FRP_CLUSTERED, use_msaa ? RB_TEX_GBUFFER_ALBEDO_MSAA : RB_TEX_GBUFFER_ALBEDO);
			RID orm_buffer = render_buffers->get_texture(RB_SCOPE_FRP_CLUSTERED, use_msaa ? RB_TEX_GBUFFER_ORM_MSAA : RB_TEX_GBUFFER_ORM);
			RID emission_buffer = render_buffers->get_texture(RB_SCOPE_FRP_CLUSTERED, use_msaa ? RB_TEX_GBUFFER_EMISSION_MSAA : RB_TEX_GBUFFER_EMISSION);
			RID velocity_buffer = render_buffers->get_velocity_buffer(use_msaa);

			return FramebufferCacheRD::get_singleton()->get_cache_multiview(render_buffers->get_view_count(), depth, normal_roughness_buffer, albedo_buffer, orm_buffer, emission_buffer, velocity_buffer);
		} break;
		default: {
			ERR_FAIL_V(RID());
		} break;
	}
}

RID RenderFRPClustered::RenderBufferDataFRPClustered::get_specular_only_fb() {
	bool use_msaa = render_buffers->get_msaa_3d() != RSE::VIEWPORT_MSAA_DISABLED;

	RID specular = render_buffers->get_texture(RB_SCOPE_FRP_CLUSTERED, use_msaa ? RB_TEX_SPECULAR_MSAA : RB_TEX_SPECULAR);

	return FramebufferCacheRD::get_singleton()->get_cache_multiview(render_buffers->get_view_count(), specular);
}

RID RenderFRPClustered::RenderBufferDataFRPClustered::get_velocity_only_fb() {
	bool use_msaa = render_buffers->get_msaa_3d() != RSE::VIEWPORT_MSAA_DISABLED;

	RID velocity = render_buffers->get_texture(RB_SCOPE_BUFFERS, use_msaa ? RB_TEX_VELOCITY_MSAA : RB_TEX_VELOCITY);

	return FramebufferCacheRD::get_singleton()->get_cache_multiview(render_buffers->get_view_count(), velocity);
}

RD::DataFormat RenderFRPClustered::RenderBufferDataFRPClustered::get_specular_format() {
	return RD::DATA_FORMAT_R16G16B16A16_SFLOAT;
}

uint32_t RenderFRPClustered::RenderBufferDataFRPClustered::get_specular_usage_bits(bool p_resolve, bool p_msaa, bool p_storage) {
	return RenderSceneBuffersRD::get_color_usage_bits(p_resolve, p_msaa, p_storage);
}

RD::DataFormat RenderFRPClustered::RenderBufferDataFRPClustered::get_normal_roughness_format() {
	// Unreal's GBufferA is PF_A2B10G10R10: 10 bits per normal axis (30 bits)
	// instead of this renderer's previous 24-bit best-fit normal in RGBA8. The
	// 2-bit alpha holds the dynamic/static flag, and roughness lives in
	// gbuffer_orm.g, so bytes per pixel are unchanged.
	return RD::DATA_FORMAT_A2B10G10R10_UNORM_PACK32;
}

uint32_t RenderFRPClustered::RenderBufferDataFRPClustered::get_normal_roughness_usage_bits(bool p_resolve, bool p_msaa, bool p_storage) {
	return RenderSceneBuffersRD::get_color_usage_bits(p_resolve, p_msaa, p_storage);
}

RD::DataFormat RenderFRPClustered::RenderBufferDataFRPClustered::get_gbuffer_albedo_format() {
	return RD::DATA_FORMAT_R8G8B8A8_UNORM;
}

uint32_t RenderFRPClustered::RenderBufferDataFRPClustered::get_gbuffer_albedo_usage_bits(bool p_resolve, bool p_msaa, bool p_storage) {
	return RenderSceneBuffersRD::get_color_usage_bits(p_resolve, p_msaa, p_storage);
}

RD::DataFormat RenderFRPClustered::RenderBufferDataFRPClustered::get_gbuffer_orm_format() {
	return RD::DATA_FORMAT_R8G8B8A8_UNORM;
}

uint32_t RenderFRPClustered::RenderBufferDataFRPClustered::get_gbuffer_orm_usage_bits(bool p_resolve, bool p_msaa, bool p_storage) {
	return RenderSceneBuffersRD::get_color_usage_bits(p_resolve, p_msaa, p_storage);
}

RD::DataFormat RenderFRPClustered::RenderBufferDataFRPClustered::get_gbuffer_emission_format() {
	return RD::DATA_FORMAT_R16G16B16A16_SFLOAT;
}

uint32_t RenderFRPClustered::RenderBufferDataFRPClustered::get_gbuffer_emission_usage_bits(bool p_resolve, bool p_msaa, bool p_storage) {
	return RenderSceneBuffersRD::get_color_usage_bits(p_resolve, p_msaa, p_storage);
}

void RenderFRPClustered::setup_render_buffer_data(Ref<RenderSceneBuffersRD> p_render_buffers) {
	Ref<RenderBufferDataFRPClustered> data;
	data.instantiate();
	p_render_buffers->set_custom_data(RB_SCOPE_FRP_CLUSTERED, data);

	// The engine's volumetric fog binds a voxel GI instance buffer and a voxel GI
	// texture array in its compute uniform set even when GI injection is disabled, so
	// the render buffers have to own that storage object. FRP never fills or reads it:
	// the frame's voxel GI count is zero, which keeps the fog's GI path off.
	Ref<RendererRD::GI::RenderBuffersGI> rbgi;
	rbgi.instantiate();
	p_render_buffers->set_custom_data(RB_SCOPE_GI, rbgi);
}

bool RenderFRPClustered::free(RID p_rid) {
	if (RendererSceneRenderRD::free(p_rid)) {
		return true;
	}
	return false;
}

void RenderFRPClustered::update() {
	RendererSceneRenderRD::update();
	_update_global_pipeline_data_requirements_from_project();
	_update_global_pipeline_data_requirements_from_light_storage();
}

/// RENDERING ///

template <RenderFRPClustered::PassMode p_pass_mode, uint32_t p_color_pass_flags>
void RenderFRPClustered::_render_list_template(RenderingDevice::DrawListID p_draw_list, RenderingDevice::FramebufferFormatID p_framebuffer_Format, RenderListParameters *p_params, uint32_t p_from_element, uint32_t p_to_element) {
	RendererRD::MeshStorage *mesh_storage = RendererRD::MeshStorage::get_singleton();
	RendererRD::ParticlesStorage *particles_storage = RendererRD::ParticlesStorage::get_singleton();
	RD::DrawListID draw_list = p_draw_list;
	RD::FramebufferFormatID framebuffer_format = p_framebuffer_Format;

	//global scope bindings
	RD::get_singleton()->draw_list_bind_uniform_set(draw_list, render_base_uniform_set, SCENE_UNIFORM_SET);
	RD::get_singleton()->draw_list_bind_uniform_set(draw_list, p_params->render_pass_uniform_set, RENDER_PASS_UNIFORM_SET);
	RD::get_singleton()->draw_list_bind_uniform_set(draw_list, scene_shader.default_vec4_xform_uniform_set, TRANSFORMS_UNIFORM_SET);

	RID prev_material_uniform_set;

	RID prev_vertex_array_rd;
	RID prev_index_array_rd;
	RID prev_xforms_uniform_set;

	SceneShaderFRPClustered::ShaderData *shader = nullptr;
	SceneShaderFRPClustered::ShaderData *prev_shader = nullptr;
	SceneShaderFRPClustered::ShaderData::PipelineKey pipeline_key;
	uint32_t pipeline_hash = 0;
	uint32_t prev_pipeline_hash = 0;

	bool shadow_pass = (p_pass_mode == PASS_MODE_SHADOW) || (p_pass_mode == PASS_MODE_SHADOW_DP);

	SceneState::PushConstant push_constant;

	if constexpr (p_pass_mode == PASS_MODE_DEPTH_MATERIAL || p_pass_mode == PASS_MODE_GBUFFER) {
		push_constant.uv_offset = Math::make_half_float(p_params->uv_offset.y) << 16;
		push_constant.uv_offset |= Math::make_half_float(p_params->uv_offset.x);
	} else {
		push_constant.uv_offset = 0;
	}

	bool should_request_redraw = false;

	for (uint32_t i = p_from_element; i < p_to_element; i++) {
		const GeometryInstanceSurfaceDataCache *surf = p_params->elements[i];
		const RenderElementInfo &element_info = p_params->element_info[i];

		if (p_pass_mode == PASS_MODE_COLOR && surf->color_pass_inclusion_mask && (p_color_pass_flags & surf->color_pass_inclusion_mask) == 0) {
			// Some surfaces can be repeated in multiple render lists. We exclude them from being rendered on the color pass based on the
			// features supported by the pass compared to the exclusion mask.
			continue;
		}

		if (surf->owner->instance_count == 0) {
			continue;
		}

		push_constant.base_index = i + p_params->element_offset;

		RID material_uniform_set;
		void *mesh_surface;

		if (shadow_pass || p_pass_mode == PASS_MODE_DEPTH) { //regular depth pass can use these too
			material_uniform_set = surf->material_uniform_set_shadow;
			shader = surf->shader_shadow;
			mesh_surface = surf->surface_shadow;

		} else {
#ifdef DEBUG_ENABLED
			if (unlikely(get_debug_draw_mode() == RSE::VIEWPORT_DEBUG_DRAW_LIGHTING)) {
				material_uniform_set = scene_shader.default_material_uniform_set;
				shader = scene_shader.default_material_shader_ptr;
			} else if (unlikely(get_debug_draw_mode() == RSE::VIEWPORT_DEBUG_DRAW_OVERDRAW)) {
				material_uniform_set = scene_shader.overdraw_material_uniform_set;
				shader = scene_shader.overdraw_material_shader_ptr;
			} else if (unlikely(get_debug_draw_mode() == RSE::VIEWPORT_DEBUG_DRAW_PSSM_SPLITS)) {
				material_uniform_set = scene_shader.debug_shadow_splits_material_uniform_set;
				shader = scene_shader.debug_shadow_splits_material_shader_ptr;
			} else {
#endif
				material_uniform_set = surf->material_uniform_set;
				shader = surf->shader;
				surf->material->set_as_used();
#ifdef DEBUG_ENABLED
			}
#endif
			mesh_surface = surf->surface;
		}

		if (!mesh_surface) {
			continue;
		}

		//request a redraw if one of the shaders uses TIME
		if (shader->uses_time) {
			should_request_redraw = true;
		}

		// Determine the cull variant.
		SceneShaderFRPClustered::ShaderData::CullVariant cull_variant = SceneShaderFRPClustered::ShaderData::CULL_VARIANT_MAX;
		if constexpr (p_pass_mode == PASS_MODE_DEPTH_MATERIAL || p_pass_mode == PASS_MODE_SDF || p_pass_mode == PASS_MODE_GBUFFER) {
			cull_variant = SceneShaderFRPClustered::ShaderData::CULL_VARIANT_DOUBLE_SIDED;
		} else {
			if constexpr (p_pass_mode == PASS_MODE_SHADOW || p_pass_mode == PASS_MODE_SHADOW_DP) {
				if (surf->flags & GeometryInstanceSurfaceDataCache::FLAG_USES_DOUBLE_SIDED_SHADOWS) {
					cull_variant = SceneShaderFRPClustered::ShaderData::CULL_VARIANT_DOUBLE_SIDED;
				}
			}

			if (cull_variant == SceneShaderFRPClustered::ShaderData::CULL_VARIANT_MAX) {
				bool mirror = surf->owner->mirror;
				if (p_params->reverse_cull) {
					mirror = !mirror;
				}

				cull_variant = mirror ? SceneShaderFRPClustered::ShaderData::CULL_VARIANT_REVERSED : SceneShaderFRPClustered::ShaderData::CULL_VARIANT_NORMAL;
			}
		}

		pipeline_key.primitive_type = surf->primitive;

		RID xforms_uniform_set = surf->owner->transforms_uniform_set;

		SceneShaderFRPClustered::ShaderSpecialization pipeline_specialization = p_params->base_specialization;
		pipeline_specialization.multimesh = bool(surf->owner->base_flags & INSTANCE_DATA_FLAG_MULTIMESH);
		pipeline_specialization.multimesh_format_2d = bool(surf->owner->base_flags & INSTANCE_DATA_FLAG_MULTIMESH_FORMAT_2D);
		pipeline_specialization.multimesh_has_color = bool(surf->owner->base_flags & INSTANCE_DATA_FLAG_MULTIMESH_HAS_COLOR);
		pipeline_specialization.multimesh_has_custom_data = bool(surf->owner->base_flags & INSTANCE_DATA_FLAG_MULTIMESH_HAS_CUSTOM_DATA);

		if constexpr (p_pass_mode == PASS_MODE_COLOR) {
			pipeline_specialization.use_light_soft_shadows = element_info.uses_softshadow;
			pipeline_specialization.use_light_projector = element_info.uses_projector;
			pipeline_specialization.use_directional_soft_shadows = p_params->use_directional_soft_shadow;
		}

		pipeline_key.color_pass_flags = 0;

		switch (p_pass_mode) {
			case PASS_MODE_COLOR: {
				if (element_info.uses_lightmap) {
					pipeline_key.color_pass_flags |= SceneShaderFRPClustered::PIPELINE_COLOR_PASS_FLAG_LIGHTMAP;
				} else {
					pipeline_specialization.use_forward_gi = element_info.uses_forward_gi;
				}

				if constexpr ((p_color_pass_flags & COLOR_PASS_FLAG_SEPARATE_SPECULAR) != 0) {
					pipeline_key.color_pass_flags |= SceneShaderFRPClustered::PIPELINE_COLOR_PASS_FLAG_SEPARATE_SPECULAR;
				}

				if constexpr ((p_color_pass_flags & COLOR_PASS_FLAG_MOTION_VECTORS) != 0) {
					pipeline_key.color_pass_flags |= SceneShaderFRPClustered::PIPELINE_COLOR_PASS_FLAG_MOTION_VECTORS;
				}

				if constexpr ((p_color_pass_flags & COLOR_PASS_FLAG_TRANSPARENT) != 0) {
					pipeline_key.color_pass_flags |= SceneShaderFRPClustered::PIPELINE_COLOR_PASS_FLAG_TRANSPARENT;
				}

				if constexpr ((p_color_pass_flags & COLOR_PASS_FLAG_MULTIVIEW) != 0) {
					pipeline_key.color_pass_flags |= SceneShaderFRPClustered::PIPELINE_COLOR_PASS_FLAG_MULTIVIEW;
				}

				pipeline_key.version = SceneShaderFRPClustered::PIPELINE_VERSION_COLOR_PASS;
			} break;
			case PASS_MODE_SHADOW:
			case PASS_MODE_DEPTH: {
				pipeline_key.version = p_params->view_count > 1 ? SceneShaderFRPClustered::PIPELINE_VERSION_DEPTH_PASS_MULTIVIEW : SceneShaderFRPClustered::PIPELINE_VERSION_DEPTH_PASS;
			} break;
			case PASS_MODE_SHADOW_DP: {
				ERR_FAIL_COND_MSG(p_params->view_count > 1, "Multiview not supported for shadow DP pass");
				pipeline_key.version = SceneShaderFRPClustered::PIPELINE_VERSION_DEPTH_PASS_DP;
			} break;
			case PASS_MODE_DEPTH_NORMAL_ROUGHNESS: {
				pipeline_key.version = p_params->view_count > 1 ? SceneShaderFRPClustered::PIPELINE_VERSION_DEPTH_PASS_WITH_NORMAL_AND_ROUGHNESS_MULTIVIEW : SceneShaderFRPClustered::PIPELINE_VERSION_DEPTH_PASS_WITH_NORMAL_AND_ROUGHNESS;
			} break;
			case PASS_MODE_DEPTH_MATERIAL: {
				ERR_FAIL_COND_MSG(p_params->view_count > 1, "Multiview not supported for material pass");
				pipeline_key.version = SceneShaderFRPClustered::PIPELINE_VERSION_DEPTH_PASS_WITH_MATERIAL;
			} break;
			case PASS_MODE_GBUFFER: {
				ERR_FAIL_COND_MSG(p_params->view_count > 1, "Multiview not supported for G-buffer pass");
				if constexpr ((p_color_pass_flags & COLOR_PASS_FLAG_MOTION_VECTORS) != 0) {
					// The G-buffer pass writes motion vectors in the same geometry draw
					// when the velocity attachment is present.
					pipeline_key.color_pass_flags |= SceneShaderFRPClustered::PIPELINE_COLOR_PASS_FLAG_MOTION_VECTORS;
					pipeline_key.version = SceneShaderFRPClustered::PIPELINE_VERSION_GBUFFER_PASS_MOTION_VECTORS;
				} else {
					pipeline_key.version = SceneShaderFRPClustered::PIPELINE_VERSION_GBUFFER_PASS;
				}
			} break;
			case PASS_MODE_SDF: {
				// Note, SDF is prepared in world space, this shouldn't be a multiview buffer even when stereoscopic rendering is used.
				ERR_FAIL_COND_MSG(p_params->view_count > 1, "Multiview not supported for SDF pass");
				pipeline_key.version = SceneShaderFRPClustered::PIPELINE_VERSION_DEPTH_PASS_WITH_SDF;
			} break;
		}

		pipeline_key.framebuffer_format_id = framebuffer_format;
		pipeline_key.wireframe = p_params->force_wireframe;
		pipeline_key.opaque_fallback = p_params->opaque_fallback;
		pipeline_key.ubershader = 0;

		bool emulate_point_size = shader->uses_point_size && scene_shader.emulate_point_size;

		const RD::PolygonCullMode cull_mode = shader->get_cull_mode_from_cull_variant(cull_variant);
		RID vertex_array_rd;
		RID index_array_rd;
		RID pipeline_rd;
		const uint32_t ubershader_iterations = 2;
		bool pipeline_valid = false;
		while (pipeline_key.ubershader < ubershader_iterations) {
			// Skeleton and blend shape.
			RD::VertexFormatID vertex_format = -1;
			bool pipeline_motion_vectors = pipeline_key.color_pass_flags & SceneShaderFRPClustered::PIPELINE_COLOR_PASS_FLAG_MOTION_VECTORS;
			uint64_t input_mask = shader->get_vertex_input_mask(pipeline_key.version, pipeline_key.color_pass_flags, pipeline_key.ubershader);
			if (surf->owner->mesh_instance.is_valid()) {
				mesh_storage->mesh_instance_surface_get_vertex_arrays_and_format(surf->owner->mesh_instance, surf->surface_index, input_mask, pipeline_motion_vectors, emulate_point_size, vertex_array_rd, vertex_format);
			} else {
				mesh_storage->mesh_surface_get_vertex_arrays_and_format(mesh_surface, input_mask, pipeline_motion_vectors, emulate_point_size, vertex_array_rd, vertex_format);
			}

			pipeline_key.vertex_format_id = vertex_format;

			if (pipeline_key.ubershader) {
				pipeline_key.shader_specialization = {};
				pipeline_key.cull_mode = RD::POLYGON_CULL_DISABLED;
			} else {
				pipeline_key.shader_specialization = pipeline_specialization;
				pipeline_key.cull_mode = cull_mode;
			}

			pipeline_hash = pipeline_key.hash();

			if (shader != prev_shader || pipeline_hash != prev_pipeline_hash) {
				RSE::PipelineSource pipeline_source = pipeline_key.ubershader ? RSE::PIPELINE_SOURCE_DRAW : RSE::PIPELINE_SOURCE_SPECIALIZATION;
				pipeline_rd = shader->pipeline_hash_map.get_pipeline(pipeline_key, pipeline_hash, pipeline_key.ubershader, pipeline_source);

				if (pipeline_rd.is_valid()) {
					pipeline_valid = true;
					prev_shader = shader;
					prev_pipeline_hash = pipeline_hash;
					break;
				} else {
					pipeline_key.ubershader++;
				}
			} else {
				// The same pipeline is bound already.
				pipeline_valid = true;
				break;
			}
		}

		if (pipeline_valid) {
			if (!emulate_point_size) {
				index_array_rd = mesh_storage->mesh_surface_get_index_array(mesh_surface, element_info.lod_index);
			} else {
				index_array_rd = RID();
			}

			if (prev_vertex_array_rd != vertex_array_rd) {
				RD::get_singleton()->draw_list_bind_vertex_array(draw_list, vertex_array_rd);
				prev_vertex_array_rd = vertex_array_rd;
			}

			if (prev_index_array_rd != index_array_rd) {
				if (index_array_rd.is_valid()) {
					RD::get_singleton()->draw_list_bind_index_array(draw_list, index_array_rd);
				}
				prev_index_array_rd = index_array_rd;
			}

			if (!pipeline_rd.is_null()) {
				RD::get_singleton()->draw_list_bind_render_pipeline(draw_list, pipeline_rd);
			}

			if (xforms_uniform_set.is_valid() && prev_xforms_uniform_set != xforms_uniform_set) {
				RD::get_singleton()->draw_list_bind_uniform_set(draw_list, xforms_uniform_set, TRANSFORMS_UNIFORM_SET);
				prev_xforms_uniform_set = xforms_uniform_set;
			}

			if (material_uniform_set != prev_material_uniform_set) {
				// Update uniform set.
				if (material_uniform_set.is_valid() && RD::get_singleton()->uniform_set_is_valid(material_uniform_set)) { // Material may not have a uniform set.
					RD::get_singleton()->draw_list_bind_uniform_set(draw_list, material_uniform_set, MATERIAL_UNIFORM_SET);
				}

				prev_material_uniform_set = material_uniform_set;
			}

			if (surf->owner->base_flags & INSTANCE_DATA_FLAG_PARTICLES) {
				particles_storage->particles_get_instance_buffer_motion_vectors_offsets(surf->owner->data->base, push_constant.multimesh_motion_vectors_current_offset, push_constant.multimesh_motion_vectors_previous_offset);
			} else if (surf->owner->base_flags & INSTANCE_DATA_FLAG_MULTIMESH) {
				mesh_storage->_multimesh_get_motion_vectors_offsets(surf->owner->data->base, push_constant.multimesh_motion_vectors_current_offset, push_constant.multimesh_motion_vectors_previous_offset);
			} else {
				push_constant.multimesh_motion_vectors_current_offset = 0;
				push_constant.multimesh_motion_vectors_previous_offset = 0;
			}

			size_t push_constant_size = 0;
			if (pipeline_key.ubershader) {
				push_constant_size = sizeof(SceneState::PushConstant);
				push_constant.ubershader.specialization = pipeline_specialization;
				push_constant.ubershader.constants = {};
				push_constant.ubershader.constants.cull_mode = cull_mode;
			} else {
				push_constant_size = sizeof(SceneState::PushConstant) - sizeof(SceneState::PushConstantUbershader);
			}

			RD::get_singleton()->draw_list_set_push_constant(draw_list, &push_constant, push_constant_size);

			uint32_t instance_count = surf->owner->instance_count > 1 ? surf->owner->instance_count : element_info.repeat;
			if (surf->flags & GeometryInstanceSurfaceDataCache::FLAG_USES_PARTICLE_TRAILS) {
				instance_count /= surf->owner->trail_steps;
			}

			bool indirect = bool(surf->owner->base_flags & INSTANCE_DATA_FLAG_MULTIMESH_INDIRECT);

			if (emulate_point_size) {
				if (indirect) {
					WARN_PRINT("Indirect draws are not supported when emulating point size.");
				}
				RD::get_singleton()->draw_list_draw(draw_list, false, mesh_storage->mesh_surface_get_vertex_count(mesh_surface), instance_count * 6);
			} else if (indirect) {
				RD::get_singleton()->draw_list_draw_indirect(draw_list, index_array_rd.is_valid(), mesh_storage->_multimesh_get_command_buffer_rd_rid(surf->owner->data->base), surf->surface_index * sizeof(uint32_t) * mesh_storage->INDIRECT_MULTIMESH_COMMAND_STRIDE, 1, 0);
			} else {
				RD::get_singleton()->draw_list_draw(draw_list, index_array_rd.is_valid(), instance_count);
			}
		}

		i += element_info.repeat - 1; //skip equal elements
	}

	// Make the actual redraw request
	if (should_request_redraw) {
		RenderingServerDefault::redraw_request();
	}
}

void RenderFRPClustered::_render_list(RenderingDevice::DrawListID p_draw_list, RenderingDevice::FramebufferFormatID p_framebuffer_Format, RenderListParameters *p_params, uint32_t p_from_element, uint32_t p_to_element) {
	//use template for faster performance (pass mode comparisons are inlined)

	switch (p_params->pass_mode) {
#define VALID_FLAG_COMBINATION(f) \
	case f: { \
		_render_list_template<PASS_MODE_COLOR, f>(p_draw_list, p_framebuffer_Format, p_params, p_from_element, p_to_element); \
	} break;

		case PASS_MODE_COLOR: {
			switch (p_params->color_pass_flags) {
				VALID_FLAG_COMBINATION(0);
				VALID_FLAG_COMBINATION(COLOR_PASS_FLAG_TRANSPARENT);
				VALID_FLAG_COMBINATION(COLOR_PASS_FLAG_TRANSPARENT | COLOR_PASS_FLAG_MULTIVIEW);
				VALID_FLAG_COMBINATION(COLOR_PASS_FLAG_TRANSPARENT | COLOR_PASS_FLAG_MOTION_VECTORS);
				VALID_FLAG_COMBINATION(COLOR_PASS_FLAG_SEPARATE_SPECULAR);
				VALID_FLAG_COMBINATION(COLOR_PASS_FLAG_SEPARATE_SPECULAR | COLOR_PASS_FLAG_MULTIVIEW);
				VALID_FLAG_COMBINATION(COLOR_PASS_FLAG_SEPARATE_SPECULAR | COLOR_PASS_FLAG_MOTION_VECTORS);
				VALID_FLAG_COMBINATION(COLOR_PASS_FLAG_MULTIVIEW);
				VALID_FLAG_COMBINATION(COLOR_PASS_FLAG_MULTIVIEW | COLOR_PASS_FLAG_MOTION_VECTORS);
				VALID_FLAG_COMBINATION(COLOR_PASS_FLAG_MOTION_VECTORS);
				VALID_FLAG_COMBINATION(COLOR_PASS_FLAG_SEPARATE_SPECULAR | COLOR_PASS_FLAG_MULTIVIEW | COLOR_PASS_FLAG_MOTION_VECTORS);
				VALID_FLAG_COMBINATION(COLOR_PASS_FLAG_TRANSPARENT | COLOR_PASS_FLAG_MULTIVIEW | COLOR_PASS_FLAG_MOTION_VECTORS);
				default: {
					ERR_FAIL_MSG("Invalid color pass flag combination " + itos(p_params->color_pass_flags));
				}
			}

		} break;
		case PASS_MODE_SHADOW: {
			_render_list_template<PASS_MODE_SHADOW>(p_draw_list, p_framebuffer_Format, p_params, p_from_element, p_to_element);
		} break;
		case PASS_MODE_SHADOW_DP: {
			_render_list_template<PASS_MODE_SHADOW_DP>(p_draw_list, p_framebuffer_Format, p_params, p_from_element, p_to_element);
		} break;
		case PASS_MODE_DEPTH: {
			_render_list_template<PASS_MODE_DEPTH>(p_draw_list, p_framebuffer_Format, p_params, p_from_element, p_to_element);
		} break;
		case PASS_MODE_DEPTH_NORMAL_ROUGHNESS: {
			_render_list_template<PASS_MODE_DEPTH_NORMAL_ROUGHNESS>(p_draw_list, p_framebuffer_Format, p_params, p_from_element, p_to_element);
		} break;
		case PASS_MODE_DEPTH_MATERIAL: {
			_render_list_template<PASS_MODE_DEPTH_MATERIAL>(p_draw_list, p_framebuffer_Format, p_params, p_from_element, p_to_element);
		} break;
		case PASS_MODE_GBUFFER: {
			// The G-buffer pass is instantiated twice: writing only the G-buffer, or
			// writing the G-buffer plus the motion vector attachment in the same draw.
			switch (p_params->color_pass_flags) {
				case 0: {
					_render_list_template<PASS_MODE_GBUFFER>(p_draw_list, p_framebuffer_Format, p_params, p_from_element, p_to_element);
				} break;
				case COLOR_PASS_FLAG_MOTION_VECTORS: {
					_render_list_template<PASS_MODE_GBUFFER, COLOR_PASS_FLAG_MOTION_VECTORS>(p_draw_list, p_framebuffer_Format, p_params, p_from_element, p_to_element);
				} break;
				default: {
					ERR_FAIL_MSG("Invalid G-buffer pass flag combination " + itos(p_params->color_pass_flags));
				} break;
			}
		} break;
		case PASS_MODE_SDF: {
			_render_list_template<PASS_MODE_SDF>(p_draw_list, p_framebuffer_Format, p_params, p_from_element, p_to_element);
		} break;
		default: {
			// Unknown pass mode.
		} break;
	}
}

void RenderFRPClustered::_render_list_with_draw_list(RenderListParameters *p_params, RID p_framebuffer, BitField<RD::DrawFlags> p_draw_flags, const Vector<Color> &p_clear_color_values, float p_clear_depth_value, uint32_t p_clear_stencil_value, const Rect2 &p_region) {
	RD::FramebufferFormatID fb_format = RD::get_singleton()->framebuffer_get_format(p_framebuffer);
	p_params->framebuffer_format = fb_format;

	RD::DrawListID draw_list = RD::get_singleton()->draw_list_begin(p_framebuffer, p_draw_flags, p_clear_color_values, p_clear_depth_value, p_clear_stencil_value, p_region);
	_render_list(draw_list, fb_format, p_params, 0, p_params->element_count);
	RD::get_singleton()->draw_list_end();
}

uint32_t RenderFRPClustered::_setup_environment(const RenderDataRD *p_render_data, bool p_no_fog, const Size2i &p_screen_size, const Size2 &p_viewport_size, const Color &p_default_bg_color, bool p_opaque_render_buffers, bool p_apply_alpha_multiplier, bool p_pancake_shadows) {
	RendererRD::LightStorage *light_storage = RendererRD::LightStorage::get_singleton();

	Ref<RenderSceneBuffersRD> rd = p_render_data->render_buffers;
	RID env = is_environment(p_render_data->environment) ? p_render_data->environment : RID();
	RID reflection_probe_instance = p_render_data->reflection_probe.is_valid() ? light_storage->reflection_probe_instance_get_probe(p_render_data->reflection_probe) : RID();

	// May do this earlier in RenderSceneRenderRD::render_scene
	uint32_t uniform_buffer_index = scene_state.used_uniform_buffer_count;
	++scene_state.used_uniform_buffer_count;

	if (uniform_buffer_index >= scene_state.uniform_buffers.size()) {
		uint32_t from = scene_state.uniform_buffers.size();
		scene_state.uniform_buffers.resize(uniform_buffer_index + 1);
		for (uint32_t i = from; i < scene_state.uniform_buffers.size(); i++) {
			scene_state.uniform_buffers[i] = p_render_data->scene_data->create_uniform_buffer();
		}
	}

	float luminance_multiplier = rd.is_valid() ? rd->get_luminance_multiplier() : 1.0;

	p_render_data->scene_data->update_ubo(scene_state.uniform_buffers[uniform_buffer_index], get_debug_draw_mode(), env, reflection_probe_instance, p_render_data->camera_attributes, p_pancake_shadows, p_screen_size, p_viewport_size, p_default_bg_color, luminance_multiplier, p_opaque_render_buffers, p_apply_alpha_multiplier);

	// now do implementation UBO

	scene_state.ubo.cluster_shift = Math::get_shift_from_power_of_2(p_render_data->cluster_size);
	scene_state.ubo.max_cluster_element_count_div_32 = p_render_data->cluster_max_elements / 32;
	{
		uint32_t cluster_screen_width = Math::division_round_up((uint32_t)p_screen_size.width, p_render_data->cluster_size);
		uint32_t cluster_screen_height = Math::division_round_up((uint32_t)p_screen_size.height, p_render_data->cluster_size);
		scene_state.ubo.cluster_type_size = cluster_screen_width * cluster_screen_height * (scene_state.ubo.max_cluster_element_count_div_32 + 32);
		scene_state.ubo.cluster_width = cluster_screen_width;
	}

	scene_state.ubo.gi_upscale_for_msaa = false;
	scene_state.ubo.volumetric_fog_enabled = false;

	if (rd.is_valid()) {
		if (rd->get_msaa_3d() != RSE::VIEWPORT_MSAA_DISABLED) {
			scene_state.ubo.gi_upscale_for_msaa = true;
		}

		if (rd->has_custom_data(RB_SCOPE_FOG)) {
			Ref<RendererRD::Fog::VolumetricFog> fog = rd->get_custom_data(RB_SCOPE_FOG);

			scene_state.ubo.volumetric_fog_enabled = true;
			float fog_end = fog->length;
			if (fog_end > 0.0) {
				scene_state.ubo.volumetric_fog_inv_length = 1.0 / fog_end;
			} else {
				scene_state.ubo.volumetric_fog_inv_length = 1.0;
			}

			float fog_detail_spread = fog->spread; //reverse lookup
			if (fog_detail_spread > 0.0) {
				scene_state.ubo.volumetric_fog_detail_spread = 1.0 / fog_detail_spread;
			} else {
				scene_state.ubo.volumetric_fog_detail_spread = 1.0;
			}
		}
	}

	// FRP has no screen space effects and no global illumination: the lighting shader
	// never samples an SSAO / SSIL / SSR / GI attachment, so the flags stay zero and
	// every such sampler binds the engine's default black texture.
	scene_state.ubo.ss_effects_flags = 0;

	if (uniform_buffer_index >= scene_state.implementation_uniform_buffers.size()) {
		uint32_t from = scene_state.implementation_uniform_buffers.size();
		scene_state.implementation_uniform_buffers.resize(uniform_buffer_index + 1);
		for (uint32_t i = from; i < scene_state.implementation_uniform_buffers.size(); i++) {
			scene_state.implementation_uniform_buffers[i] = RD::get_singleton()->uniform_buffer_create(sizeof(SceneState::UBO));
		}
	}

	RD::get_singleton()->buffer_update(scene_state.implementation_uniform_buffers[uniform_buffer_index], 0, sizeof(SceneState::UBO), &scene_state.ubo);

	return uniform_buffer_index;
}

void RenderFRPClustered::SceneState::grow_instance_buffer(RenderListType p_render_list, uint32_t p_req_element_count, bool p_append) {
	if (p_req_element_count > 0) {
		if (instance_buffer[p_render_list].get_size(0u) < p_req_element_count * sizeof(SceneState::InstanceData)) {
			instance_buffer[p_render_list].uninit();
			uint32_t new_size = Math::nearest_power_of_2_templated(MAX(uint64_t(INSTANCE_DATA_BUFFER_MIN_SIZE), p_req_element_count));
			instance_buffer[p_render_list].set_storage_size(0u, new_size * sizeof(SceneState::InstanceData));
			curr_gpu_ptr[p_render_list] = nullptr;
		}

		const bool must_remap = instance_buffer[p_render_list].prepare_for_map(p_append);
		if (must_remap) {
			curr_gpu_ptr[p_render_list] = nullptr;
		}
	}
}

void RenderFRPClustered::_fill_instance_data(RenderListType p_render_list, int *p_render_info, uint32_t p_offset, int32_t p_max_elements, bool p_update_buffer) {
	RenderList *rl = &render_list[p_render_list];
	uint32_t element_total = p_max_elements >= 0 ? uint32_t(p_max_elements) : rl->elements.size();

	rl->element_info.resize(p_offset + element_total);

	// If p_offset == 0, grow_instance_buffer resets and increment the buffer.
	// If this behavior ever changes, _render_shadow_begin may need to change.
	scene_state.grow_instance_buffer(p_render_list, p_offset + element_total, p_offset != 0u);
	if (!scene_state.curr_gpu_ptr[p_render_list] && element_total > 0u) {
		// The old buffer was replaced for another larger one. We must start copying from scratch.
		element_total += p_offset;
		p_offset = 0u;
		scene_state.curr_gpu_ptr[p_render_list] = reinterpret_cast<SceneState::InstanceData *>(scene_state.instance_buffer[p_render_list].map_raw_for_upload(0u));
	}

	if (p_render_info) {
		p_render_info[RSE::VIEWPORT_RENDER_INFO_OBJECTS_IN_FRAME] += element_total;
	}

	uint32_t repeats = 0;
	GeometryInstanceSurfaceDataCache *prev_surface = nullptr;
	for (uint32_t i = 0; i < element_total; i++) {
		GeometryInstanceSurfaceDataCache *surface = rl->elements[i + p_offset];
		GeometryInstanceFRPClustered *inst = surface->owner;

		SceneState::InstanceData instance_data;

		if (likely(inst->store_transform_cache)) {
			RendererRD::MaterialStorage::store_transform_transposed_3x4(inst->transform, instance_data.transform);
			RendererRD::MaterialStorage::store_transform_transposed_3x4(inst->prev_transform, instance_data.prev_transform);

#ifdef REAL_T_IS_DOUBLE
			// Split the origin into two components, the float approximation and the missing precision.
			// In the shader we will combine these back together to restore the lost precision.
			RendererRD::MaterialStorage::split_double(inst->transform.origin.x, &instance_data.transform[3], &instance_data.model_precision[0]);
			RendererRD::MaterialStorage::split_double(inst->transform.origin.y, &instance_data.transform[7], &instance_data.model_precision[1]);
			RendererRD::MaterialStorage::split_double(inst->transform.origin.z, &instance_data.transform[11], &instance_data.model_precision[2]);
			RendererRD::MaterialStorage::split_double(inst->prev_transform.origin.x, &instance_data.prev_transform[3], &instance_data.prev_model_precision[0]);
			RendererRD::MaterialStorage::split_double(inst->prev_transform.origin.y, &instance_data.prev_transform[7], &instance_data.prev_model_precision[1]);
			RendererRD::MaterialStorage::split_double(inst->prev_transform.origin.z, &instance_data.prev_transform[11], &instance_data.prev_model_precision[2]);
#endif
		} else {
			RendererRD::MaterialStorage::store_transform_transposed_3x4(Transform3D(), instance_data.transform);
			RendererRD::MaterialStorage::store_transform_transposed_3x4(Transform3D(), instance_data.prev_transform);
#ifdef REAL_T_IS_DOUBLE
			memset(instance_data.model_precision, 0, sizeof(instance_data.model_precision));
			memset(instance_data.prev_model_precision, 0, sizeof(instance_data.prev_model_precision));
#endif
		}

		instance_data.flags = inst->flags_cache;
		instance_data.gi_offset = inst->gi_offset_cache;
		instance_data.layer_mask = inst->layer_mask;
		instance_data.instance_uniforms_ofs = uint32_t(inst->shader_uniforms_offset);
		instance_data.set_lightmap_uv_scale(inst->lightmap_uv_scale);

		AABB surface_aabb = AABB(Vector3(0.0, 0.0, 0.0), Vector3(1.0, 1.0, 1.0));
		uint64_t format = RendererRD::MeshStorage::get_singleton()->mesh_surface_get_format(surface->surface);
		Vector4 uv_scale = Vector4(0.0, 0.0, 0.0, 0.0);

		if (format & RSE::ARRAY_FLAG_COMPRESS_ATTRIBUTES) {
			surface_aabb = RendererRD::MeshStorage::get_singleton()->mesh_surface_get_aabb(surface->surface);
			uv_scale = RendererRD::MeshStorage::get_singleton()->mesh_surface_get_uv_scale(surface->surface);
		}

		instance_data.set_compressed_aabb(surface_aabb);
		instance_data.set_uv_scale(uv_scale);

		scene_state.curr_gpu_ptr[p_render_list][i + p_offset] = instance_data;

		const bool cant_repeat = instance_data.flags & INSTANCE_DATA_FLAG_MULTIMESH || inst->mesh_instance.is_valid();

		if (prev_surface != nullptr && !cant_repeat && prev_surface->sort.sort_key1 == surface->sort.sort_key1 && prev_surface->sort.sort_key2 == surface->sort.sort_key2 && inst->mirror == prev_surface->owner->mirror && repeats < RenderElementInfo::MAX_REPEATS) {
			//this element is the same as the previous one, count repeats to draw it using instancing
			repeats++;
		} else {
			if (repeats > 0) {
				for (uint32_t j = 1; j <= repeats; j++) {
					rl->element_info[p_offset + i - j].repeat = j;
				}
			}
			repeats = 1;
			if (p_render_info) {
				p_render_info[RSE::VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME]++;
			}
		}

		RenderElementInfo &element_info = rl->element_info[p_offset + i];

		element_info.value = uint32_t(surface->sort.sort_key1 & 0xFFF);

		if (cant_repeat) {
			prev_surface = nullptr;
		} else {
			prev_surface = surface;
		}
	}

	if (repeats > 0) {
		for (uint32_t j = 1; j <= repeats; j++) {
			rl->element_info[p_offset + element_total - j].repeat = j;
		}
	}

	if (p_update_buffer && element_total > 0u) {
		RenderingDevice::get_singleton()->buffer_flush(scene_state.instance_buffer[p_render_list]._get(0u));
	}
}

_FORCE_INLINE_ static uint32_t _indices_to_primitives(RSE::PrimitiveType p_primitive, uint32_t p_indices) {
	static const uint32_t divisor[RSE::PRIMITIVE_MAX] = { 1, 2, 1, 3, 1 };
	static const uint32_t subtractor[RSE::PRIMITIVE_MAX] = { 0, 0, 1, 0, 2 };
	return (p_indices - subtractor[p_primitive]) / divisor[p_primitive];
}
void RenderFRPClustered::_fill_render_list(RenderListType p_render_list, const RenderDataRD *p_render_data, PassMode p_pass_mode, bool p_using_opaque_gi, bool p_using_motion_pass, bool p_append) {
	RendererRD::MeshStorage *mesh_storage = RendererRD::MeshStorage::get_singleton();
	uint64_t frame = RSG::rasterizer->get_frame_number();

	if (p_render_list == RENDER_LIST_OPAQUE) {
		scene_state.used_sss = false;
		scene_state.used_screen_texture = false;
		scene_state.used_normal_texture = false;
		scene_state.used_depth_texture = false;
		scene_state.used_lightmap = false;
		scene_state.used_opaque_stencil = false;
	}
	uint32_t lightmap_captures_used = 0;

	Plane near_plane = Plane(-p_render_data->scene_data->cam_transform.basis.get_column(Vector3::AXIS_Z), p_render_data->scene_data->cam_transform.origin);
	near_plane.d += p_render_data->scene_data->cam_projection.get_z_near();
	float z_max = p_render_data->scene_data->cam_projection.get_z_far() - p_render_data->scene_data->cam_projection.get_z_near();

	RenderList *rl = &render_list[p_render_list];
	_update_dirty_geometry_instances();

	if (!p_append) {
		rl->clear();
		if (p_render_list == RENDER_LIST_OPAQUE) {
			// Opaque fills motion and alpha lists.
			render_list[RENDER_LIST_MOTION].clear();
			render_list[RENDER_LIST_ALPHA].clear();
			render_list[RENDER_LIST_OPAQUE_FALLBACK].clear();
		}
	}

	//fill list

	for (int i = 0; i < (int)p_render_data->instances->size(); i++) {
		GeometryInstanceFRPClustered *inst = static_cast<GeometryInstanceFRPClustered *>((*p_render_data->instances)[i]);

		Vector3 center = inst->transform.origin;
		if (p_render_data->scene_data->cam_orthogonal) {
			if (inst->use_aabb_center) {
				center = inst->transformed_aabb.get_support(-near_plane.normal);
			}
			inst->depth = near_plane.distance_to(center) - inst->sorting_offset;
		} else {
			if (inst->use_aabb_center) {
				center = inst->transformed_aabb.position + (inst->transformed_aabb.size * 0.5);
			}
			inst->depth = p_render_data->scene_data->cam_transform.origin.distance_to(center) - inst->sorting_offset;
		}
		uint32_t depth_layer = CLAMP(int(inst->depth * 16 / z_max), 0, 15);

		uint32_t flags = inst->base_flags; //fill flags if appropriate

		if (inst->non_uniform_scale) {
			flags |= INSTANCE_DATA_FLAGS_NON_UNIFORM_SCALE;
		}
		bool uses_lightmap = false;
		bool uses_motion = false;
		float fade_alpha = 1.0;

		if (inst->fade_near || inst->fade_far) {
			float fade_dist = inst->transformed_aabb.get_center().distance_to(p_render_data->scene_data->cam_transform.origin);
			// Use `smoothstep()` to make opacity changes more gradual and less noticeable to the player.
			if (inst->fade_far && fade_dist > inst->fade_far_begin) {
				fade_alpha = Math::smoothstep(0.0f, 1.0f, 1.0f - (fade_dist - inst->fade_far_begin) / (inst->fade_far_end - inst->fade_far_begin));
			} else if (inst->fade_near && fade_dist < inst->fade_near_end) {
				fade_alpha = Math::smoothstep(0.0f, 1.0f, (fade_dist - inst->fade_near_begin) / (inst->fade_near_end - inst->fade_near_begin));
			}
		}

		fade_alpha *= inst->force_alpha * inst->parent_fade_alpha;

		flags = (flags & ~INSTANCE_DATA_FLAGS_FADE_MASK) | (uint32_t(fade_alpha * 255.0) << INSTANCE_DATA_FLAGS_FADE_SHIFT);

		if (p_render_list == RENDER_LIST_OPAQUE) {
			// Setup GI
			if (inst->lightmap_instance.is_valid()) {
				// find index of the lightmap_instance of the instance being rendered
				int32_t lightmap_cull_index = -1;
				for (uint32_t j = 0; j < scene_state.lightmaps_used; j++) {
					if (scene_state.lightmap_ids[j] == inst->lightmap_instance) {
						lightmap_cull_index = j;
						break;
					}
				}
				if (lightmap_cull_index >= 0) {
					inst->gi_offset_cache = inst->lightmap_slice_index << 16;
					inst->gi_offset_cache |= lightmap_cull_index;
					flags |= INSTANCE_DATA_FLAG_USE_LIGHTMAP;
					if (scene_state.lightmap_has_sh[lightmap_cull_index]) {
						flags |= INSTANCE_DATA_FLAG_USE_SH_LIGHTMAP;
					}
					uses_lightmap = true;
				} else {
					inst->gi_offset_cache = 0xFFFFFFFF;
				}

			} else if (inst->lightmap_sh) {
				if (lightmap_captures_used < scene_state.max_lightmap_captures) {
					const Color *src_capture = inst->lightmap_sh->sh;
					LightmapCaptureData &lcd = scene_state.lightmap_captures[lightmap_captures_used];
					for (int j = 0; j < 9; j++) {
						lcd.sh[j * 4 + 0] = src_capture[j].r;
						lcd.sh[j * 4 + 1] = src_capture[j].g;
						lcd.sh[j * 4 + 2] = src_capture[j].b;
						lcd.sh[j * 4 + 3] = src_capture[j].a;
					}
					flags |= INSTANCE_DATA_FLAG_USE_LIGHTMAP_CAPTURE;
					inst->gi_offset_cache = lightmap_captures_used;
					lightmap_captures_used++;
					uses_lightmap = true;
				}

			} else {
				if (p_using_opaque_gi) {
					flags |= INSTANCE_DATA_FLAG_USE_GI_BUFFERS;
				}

				// FRP has no VoxelGI: an instance without a lightmap never gets a probe
				// index, so the shader's voxel GI path stays unused.
				inst->gi_offset_cache = 0xFFFFFFFF;
			}
			if (p_pass_mode == PASS_MODE_DEPTH_NORMAL_ROUGHNESS || p_pass_mode == PASS_MODE_COLOR || p_pass_mode == PASS_MODE_GBUFFER) {
				bool transform_changed = inst->transform_status == GeometryInstanceFRPClustered::TransformStatus::MOVED;
				bool has_mesh_instance = inst->mesh_instance.is_valid();
				bool uses_particles = inst->base_flags & INSTANCE_DATA_FLAG_PARTICLES;
				bool is_multimesh_with_motion = !uses_particles && (inst->base_flags & INSTANCE_DATA_FLAG_MULTIMESH) && mesh_storage->_multimesh_uses_motion_vectors_offsets(inst->data->base);
				bool is_dynamic = transform_changed || has_mesh_instance || uses_particles || is_multimesh_with_motion;
				if (p_pass_mode == PASS_MODE_COLOR && p_using_motion_pass) {
					uses_motion = is_dynamic;
				} else if (is_dynamic) {
					flags |= INSTANCE_DATA_FLAGS_DYNAMIC;
				}
			}
		}
		inst->flags_cache = flags;

		GeometryInstanceSurfaceDataCache *surf = inst->surface_caches;

		float lod_distance = 0.0;

		if (p_render_data->scene_data->cam_orthogonal) {
			lod_distance = 1.0;
		} else {
			Vector3 aabb_min = inst->transformed_aabb.position;
			Vector3 aabb_max = inst->transformed_aabb.position + inst->transformed_aabb.size;
			Vector3 camera_position = p_render_data->scene_data->main_cam_transform.origin;
			Vector3 surface_distance = Vector3(0.0, 0.0, 0.0).max(aabb_min - camera_position).max(camera_position - aabb_max);

			lod_distance = surface_distance.length();
		}

		if (unlikely(inst->transform_status != GeometryInstanceFRPClustered::TransformStatus::NONE && frame > inst->prev_transform_change_frame && inst->prev_transform_change_frame)) {
			inst->prev_transform = inst->transform;
			inst->transform_status = GeometryInstanceFRPClustered::TransformStatus::NONE;
		}

		while (surf) {
			surf->sort.uses_forward_gi = 0;
			surf->sort.uses_lightmap = 0;

			// LOD
			if (p_render_data->scene_data->screen_mesh_lod_threshold > 0.0 && mesh_storage->mesh_surface_has_lod(surf->surface)) {
				uint32_t indices = 0;
				surf->sort.lod_index = mesh_storage->mesh_surface_get_lod(surf->surface, inst->lod_model_scale * inst->lod_bias, lod_distance * p_render_data->scene_data->lod_distance_multiplier, p_render_data->scene_data->screen_mesh_lod_threshold, indices);
				if (p_render_data->render_info) {
					indices = _indices_to_primitives(surf->primitive, indices);
					if (p_render_list == RENDER_LIST_OPAQUE) { //opaque
						p_render_data->render_info->info[RSE::VIEWPORT_RENDER_INFO_TYPE_VISIBLE][RSE::VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME] += indices;
					} else if (p_render_list == RENDER_LIST_SECONDARY) { //shadow
						p_render_data->render_info->info[RSE::VIEWPORT_RENDER_INFO_TYPE_SHADOW][RSE::VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME] += indices;
					}
				}
			} else {
				surf->sort.lod_index = 0;
				if (p_render_data->render_info) {
					// This does not include primitives rendered via indirect draw calls.
					uint32_t to_draw = mesh_storage->mesh_surface_get_vertices_drawn_count(surf->surface);
					to_draw = _indices_to_primitives(surf->primitive, to_draw);
					to_draw *= inst->instance_count;
					if (p_render_list == RENDER_LIST_OPAQUE) { //opaque
						p_render_data->render_info->info[RSE::VIEWPORT_RENDER_INFO_TYPE_VISIBLE][RSE::VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME] += to_draw;
					} else if (p_render_list == RENDER_LIST_SECONDARY) { //shadow
						p_render_data->render_info->info[RSE::VIEWPORT_RENDER_INFO_TYPE_SHADOW][RSE::VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME] += to_draw;
					}
				}
			}

			// ADD Element
			if (p_pass_mode == PASS_MODE_COLOR) {
#ifdef DEBUG_ENABLED
				bool force_alpha = unlikely(get_debug_draw_mode() == RSE::VIEWPORT_DEBUG_DRAW_OVERDRAW);
#else
				bool force_alpha = false;
#endif

				if (fade_alpha < FADE_ALPHA_PASS_THRESHOLD) {
					force_alpha = true;
				}

				if (!force_alpha && (surf->flags & (GeometryInstanceSurfaceDataCache::FLAG_PASS_DEPTH | GeometryInstanceSurfaceDataCache::FLAG_PASS_OPAQUE))) {
					// In the FRP renderer, materials that cannot be expressed in the G-buffer
					// (unshaded, lightmap, SSS/transmittance, screen/depth/normal texture reads,
					// point size, world coords, stencil, etc.) are rendered forward in a fallback
					// pass. Vertex() is part of every FRP depth/G-buffer shader variant, so vertex
					// deformation can use the same generated code and remain in the G-buffer.
					// Everything else (roughness/normal map/tangent/alpha clip writes) is fully
					// expressible in the G-buffer and goes through FRP lighting.
					SceneShaderFRPClustered::ShaderData *shader_data = surf->shader;
					bool needs_forward_fallback = shader_data->unshaded ||
							shader_data->uses_sss ||
							shader_data->uses_transmittance ||
							shader_data->uses_screen_texture ||
							shader_data->uses_depth_texture ||
							shader_data->uses_normal_texture ||
							shader_data->uses_point_size ||
							shader_data->uses_world_coordinates ||
							shader_data->writes_modelview_or_projection ||
							shader_data->uses_z_clip_scale ||
							shader_data->stencil_enabled ||
							shader_data->uses_clearcoat ||
							shader_data->uses_anisotropy ||
							shader_data->uses_rim ||
							shader_data->uses_backlight ||
							shader_data->uses_ao_light_affect ||
							shader_data->uses_custom_radiance ||
							shader_data->uses_custom_irradiance ||
							shader_data->uses_custom_fog ||
							shader_data->uses_non_default_diffuse ||
							shader_data->uses_non_default_specular ||
							shader_data->uses_vertex_lighting ||
							shader_data->uses_custom_light_code ||
							uses_lightmap;

					if (needs_forward_fallback) {
						surf->color_pass_inclusion_mask = COLOR_PASS_FLAG_TRANSPARENT;
						render_list[RENDER_LIST_OPAQUE_FALLBACK].add_element(surf);
					} else {
						rl->add_element(surf);
					}
				}

				if (force_alpha || (surf->flags & GeometryInstanceSurfaceDataCache::FLAG_PASS_ALPHA)) {
					surf->color_pass_inclusion_mask = COLOR_PASS_FLAG_TRANSPARENT;
					render_list[RENDER_LIST_ALPHA].add_element(surf);
				} else if (p_using_motion_pass && (uses_motion || (surf->flags & GeometryInstanceSurfaceDataCache::FLAG_USES_MOTION_VECTOR))) {
					// Motion vectors are written by the G-buffer pass itself (the velocity
					// attachment is part of its framebuffer), so these surfaces stay in the
					// opaque list and no second geometry pass over them is needed. The mask
					// still excludes them from colour passes that do not want velocity.
					surf->color_pass_inclusion_mask = COLOR_PASS_FLAG_MOTION_VECTORS;
				} else {
					surf->color_pass_inclusion_mask = 0;
				}

				if (uses_lightmap) {
					surf->sort.uses_lightmap = 1;
					scene_state.used_lightmap = true;
				}

				if (surf->flags & GeometryInstanceSurfaceDataCache::FLAG_USES_SUBSURFACE_SCATTERING) {
					scene_state.used_sss = true;
				}
				if (surf->flags & GeometryInstanceSurfaceDataCache::FLAG_USES_SCREEN_TEXTURE) {
					scene_state.used_screen_texture = true;
				}
				if (surf->flags & GeometryInstanceSurfaceDataCache::FLAG_USES_NORMAL_TEXTURE) {
					scene_state.used_normal_texture = true;
				}
				if (surf->flags & GeometryInstanceSurfaceDataCache::FLAG_USES_DEPTH_TEXTURE) {
					scene_state.used_depth_texture = true;
				}
				if ((surf->flags & GeometryInstanceSurfaceDataCache::FLAG_USES_STENCIL) && !force_alpha && (surf->flags & (GeometryInstanceSurfaceDataCache::FLAG_PASS_DEPTH | GeometryInstanceSurfaceDataCache::FLAG_PASS_OPAQUE))) {
					scene_state.used_opaque_stencil = true;
				}
			} else if (p_pass_mode == PASS_MODE_SHADOW || p_pass_mode == PASS_MODE_SHADOW_DP) {
				if (surf->flags & GeometryInstanceSurfaceDataCache::FLAG_PASS_SHADOW) {
					rl->add_element(surf);
				}
			} else if (p_pass_mode == PASS_MODE_DEPTH_MATERIAL || p_pass_mode == PASS_MODE_GBUFFER) {
				if (surf->flags & (GeometryInstanceSurfaceDataCache::FLAG_PASS_DEPTH | GeometryInstanceSurfaceDataCache::FLAG_PASS_OPAQUE | GeometryInstanceSurfaceDataCache::FLAG_PASS_ALPHA)) {
					rl->add_element(surf);
				}
			} else {
				if (surf->flags & (GeometryInstanceSurfaceDataCache::FLAG_PASS_DEPTH | GeometryInstanceSurfaceDataCache::FLAG_PASS_OPAQUE)) {
					rl->add_element(surf);
				}
			}

			surf->sort.depth_layer = depth_layer;

			surf = surf->next;
		}
	}

	if (p_render_list == RENDER_LIST_OPAQUE && lightmap_captures_used) {
		RD::get_singleton()->buffer_update(scene_state.lightmap_capture_buffer, 0, sizeof(LightmapCaptureData) * lightmap_captures_used, scene_state.lightmap_captures);
	}
}

void RenderFRPClustered::_setup_lightmaps(const RenderDataRD *p_render_data, const PagedArray<RID> &p_lightmaps, const Transform3D &p_cam_transform) {
	RendererRD::LightStorage *light_storage = RendererRD::LightStorage::get_singleton();

	scene_state.lightmaps_used = 0;
	for (int i = 0; i < (int)p_lightmaps.size(); i++) {
		if (i >= (int)scene_state.max_lightmaps) {
			break;
		}

		RID lightmap = light_storage->lightmap_instance_get_lightmap(p_lightmaps[i]);

		// Transform (for directional lightmaps).
		Basis to_lm = light_storage->lightmap_instance_get_transform(p_lightmaps[i]).basis.inverse() * p_cam_transform.basis;
		to_lm = to_lm.inverse().transposed(); //will transform normals
		RendererRD::MaterialStorage::store_transform_3x3(to_lm, scene_state.lightmaps[i].normal_xform);

		// Light texture size.
		Vector2i lightmap_size = light_storage->lightmap_get_light_texture_size(lightmap);
		scene_state.lightmaps[i].texture_size[0] = lightmap_size[0];
		scene_state.lightmaps[i].texture_size[1] = lightmap_size[1];

		// Exposure.
		scene_state.lightmaps[i].exposure_normalization = 1.0;
		scene_state.lightmaps[i].flags = light_storage->lightmap_get_shadowmask_mode(lightmap);
		if (p_render_data->camera_attributes.is_valid()) {
			float baked_exposure = light_storage->lightmap_get_baked_exposure_normalization(lightmap);
			float enf = RSG::camera_attributes->camera_attributes_get_exposure_normalization_factor(p_render_data->camera_attributes);
			scene_state.lightmaps[i].exposure_normalization = enf / baked_exposure;
		}

		scene_state.lightmap_ids[i] = p_lightmaps[i];
		scene_state.lightmap_has_sh[i] = light_storage->lightmap_uses_spherical_harmonics(lightmap);

		scene_state.lightmaps_used++;
	}
	if (scene_state.lightmaps_used > 0) {
		RD::get_singleton()->buffer_update(scene_state.lightmap_buffer, 0, sizeof(LightmapData) * scene_state.lightmaps_used, scene_state.lightmaps);
	}
}

/* SDFGI */


/* Debug */

void RenderFRPClustered::_debug_draw_cluster(Ref<RenderSceneBuffersRD> p_render_buffers) {
	if (p_render_buffers.is_valid() && current_cluster_builder != nullptr) {
		RSE::ViewportDebugDraw dd = get_debug_draw_mode();

		if (dd == RSE::VIEWPORT_DEBUG_DRAW_CLUSTER_OMNI_LIGHTS || dd == RSE::VIEWPORT_DEBUG_DRAW_CLUSTER_SPOT_LIGHTS || dd == RSE::VIEWPORT_DEBUG_DRAW_CLUSTER_AREA_LIGHTS || dd == RSE::VIEWPORT_DEBUG_DRAW_CLUSTER_DECALS || dd == RSE::VIEWPORT_DEBUG_DRAW_CLUSTER_REFLECTION_PROBES) {
			ClusterBuilderRD::ElementType elem_type = ClusterBuilderRD::ELEMENT_TYPE_MAX;
			switch (dd) {
				case RSE::VIEWPORT_DEBUG_DRAW_CLUSTER_OMNI_LIGHTS:
					elem_type = ClusterBuilderRD::ELEMENT_TYPE_OMNI_LIGHT;
					break;
				case RSE::VIEWPORT_DEBUG_DRAW_CLUSTER_SPOT_LIGHTS:
					elem_type = ClusterBuilderRD::ELEMENT_TYPE_SPOT_LIGHT;
					break;
				case RSE::VIEWPORT_DEBUG_DRAW_CLUSTER_AREA_LIGHTS:
					elem_type = ClusterBuilderRD::ELEMENT_TYPE_AREA_LIGHT;
					break;
				case RSE::VIEWPORT_DEBUG_DRAW_CLUSTER_DECALS:
					elem_type = ClusterBuilderRD::ELEMENT_TYPE_DECAL;
					break;
				case RSE::VIEWPORT_DEBUG_DRAW_CLUSTER_REFLECTION_PROBES:
					elem_type = ClusterBuilderRD::ELEMENT_TYPE_REFLECTION_PROBE;
					break;
				default: {
				}
			}
			current_cluster_builder->debug(elem_type);
		}
	}
}

////////////////////////////////////////////////////////////////////////////////
// FOG SHADER

void RenderFRPClustered::_update_volumetric_fog(Ref<RenderSceneBuffersRD> p_render_buffers, RID p_environment, const Projection &p_cam_projection, const Transform3D &p_cam_transform, const Transform3D &p_prev_cam_inv_transform, RID p_shadow_atlas, int p_directional_light_count, bool p_use_directional_shadows, int p_positional_light_count, int p_voxel_gi_count, const PagedArray<RID> &p_fog_volumes) {
	ERR_FAIL_COND(p_render_buffers.is_null());

	Ref<RenderBufferDataFRPClustered> rb_data = p_render_buffers->get_custom_data(RB_SCOPE_FRP_CLUSTERED);
	ERR_FAIL_COND(rb_data.is_null());

	ERR_FAIL_COND(!p_render_buffers->has_custom_data(RB_SCOPE_GI));
	Ref<RendererRD::GI::RenderBuffersGI> rbgi = p_render_buffers->get_custom_data(RB_SCOPE_GI);

	// FRP has no SDFGI, so volumetric fog gets no SDFGI input: its own buffers and
	// the voxel GI buffer are what remains.
	Size2i size = p_render_buffers->get_internal_size();
	float ratio = float(size.x) / float((size.x + size.y) / 2);
	uint32_t target_width = uint32_t(float(get_volumetric_fog_size()) * ratio);
	uint32_t target_height = uint32_t(float(get_volumetric_fog_size()) / ratio);

	if (p_render_buffers->has_custom_data(RB_SCOPE_FOG)) {
		Ref<RendererRD::Fog::VolumetricFog> fog = p_render_buffers->get_custom_data(RB_SCOPE_FOG);
		//validate
		if (p_environment.is_null() || !environment_get_volumetric_fog_enabled(p_environment) || fog->width != target_width || fog->height != target_height || fog->depth != get_volumetric_fog_depth()) {
			p_render_buffers->set_custom_data(RB_SCOPE_FOG, Ref<RenderBufferCustomDataRD>());
		}
	}

	if (p_environment.is_null() || !environment_get_volumetric_fog_enabled(p_environment)) {
		//no reason to enable or update, bye
		return;
	}

	if (p_environment.is_valid() && environment_get_volumetric_fog_enabled(p_environment) && !p_render_buffers->has_custom_data(RB_SCOPE_FOG)) {
		//required volumetric fog but not existing, create
		Ref<RendererRD::Fog::VolumetricFog> fog;

		fog.instantiate();
		fog->init(Vector3i(target_width, target_height, get_volumetric_fog_depth()), sky.sky_shader.default_shader_rd);

		p_render_buffers->set_custom_data(RB_SCOPE_FOG, fog);
	}

	if (p_render_buffers->has_custom_data(RB_SCOPE_FOG)) {
		Ref<RendererRD::Fog::VolumetricFog> fog = p_render_buffers->get_custom_data(RB_SCOPE_FOG);

		RendererRD::Fog::VolumetricFogSettings settings;
		settings.rb_size = size;
		settings.time = time;
		settings.is_using_radiance_octmap_array = is_using_radiance_octmap_array();
		settings.max_cluster_elements = RendererRD::LightStorage::get_singleton()->get_max_cluster_elements();
		settings.volumetric_fog_filter_active = get_volumetric_fog_filter_active();

		settings.shadow_sampler = shadow_sampler;
		settings.shadow_atlas_depth = RendererRD::LightStorage::get_singleton()->owns_shadow_atlas(p_shadow_atlas) ? RendererRD::LightStorage::get_singleton()->shadow_atlas_get_texture(p_shadow_atlas) : RID();
		settings.voxel_gi_buffer = rbgi->get_voxel_gi_buffer();
		settings.omni_light_buffer = RendererRD::LightStorage::get_singleton()->get_omni_light_buffer();
		settings.spot_light_buffer = RendererRD::LightStorage::get_singleton()->get_spot_light_buffer();
		settings.area_light_buffer = RendererRD::LightStorage::get_singleton()->get_area_light_buffer();
		settings.area_light_atlas = RendererRD::TextureStorage::get_singleton()->area_light_atlas_get_texture();
		settings.directional_shadow_depth = RendererRD::LightStorage::get_singleton()->directional_shadow_get_texture();
		settings.directional_light_buffer = RendererRD::LightStorage::get_singleton()->get_directional_light_buffer();

		settings.vfog = fog;
		settings.cluster_builder = rb_data->cluster_builder;
		settings.rbgi = rbgi;
		settings.env = p_environment;
		settings.sky = &sky;
		// FRP has no global illumination, so the fog's SDFGI/GI injection stays off:
		// `settings.sdfgi` is left invalid and the voxel GI count is zero, which means
		// the fog never dereferences `settings.gi`.
		settings.gi = nullptr;

		RendererRD::Fog::get_singleton()->volumetric_fog_update(settings, p_cam_projection, p_cam_transform, p_prev_cam_inv_transform, p_shadow_atlas, p_directional_light_count, p_use_directional_shadows, p_positional_light_count, p_voxel_gi_count, p_fog_volumes);
	}
}

/* Lighting */

void RenderFRPClustered::setup_added_reflection_probe(const Transform3D &p_transform, const Vector3 &p_half_size) {
	if (current_cluster_builder != nullptr) {
		current_cluster_builder->add_box(ClusterBuilderRD::BOX_TYPE_REFLECTION_PROBE, p_transform, p_half_size);
	}
}

void RenderFRPClustered::setup_added_light(const RSE::LightType p_type, const Transform3D &p_transform, float p_radius, float p_spot_aperture, const Vector2 &p_area_size) {
	if (current_cluster_builder != nullptr) {
		ClusterBuilderRD::LightType type;
		if (p_type == RSE::LIGHT_SPOT) {
			type = ClusterBuilderRD::LIGHT_TYPE_SPOT;
		} else if (p_type == RSE::LIGHT_OMNI) {
			type = ClusterBuilderRD::LIGHT_TYPE_OMNI;
		} else {
			type = ClusterBuilderRD::LIGHT_TYPE_AREA;
		}

		current_cluster_builder->add_light(type, p_transform, p_radius, p_spot_aperture, p_area_size);
	}
}

void RenderFRPClustered::setup_added_decal(const Transform3D &p_transform, const Vector3 &p_half_size) {
	if (current_cluster_builder != nullptr) {
		current_cluster_builder->add_box(ClusterBuilderRD::BOX_TYPE_DECAL, p_transform, p_half_size);
	}
}

/* Render scene */

void RenderFRPClustered::_precompute_shadows(RenderDataRD *p_render_data) {
	// Pass 0. Drawing the shadow maps is the one piece of frame preparation that
	// depends on nothing else: it renders from each light's point of view, so it reads
	// no scene depth, no G-buffer and no material page. That is why it runs before the
	// virtual texture pass and the G-buffer.
	//
	// The rest of the preparation (light and cluster buffers, decal buffer, volumetric
	// fog) stays in the Lighting pass: it is consumed there, so it belongs there.
	RendererRD::LightStorage *light_storage = RendererRD::LightStorage::get_singleton();

	Ref<RenderSceneBuffersRD> rb = p_render_data->render_buffers;
	RENDER_TIMESTAMP("Setup Shadows");

	Size2i viewport_size = Size2i(1, 1);
	if (rb.is_valid()) {
		viewport_size = rb->get_internal_size();
	}

	p_render_data->cube_shadows.clear();
	p_render_data->shadows.clear();
	p_render_data->directional_shadows.clear();

	float lod_distance_multiplier = p_render_data->scene_data->cam_projection.get_lod_multiplier();
	{
		for (int i = 0; i < p_render_data->render_shadow_count; i++) {
			RID li = p_render_data->render_shadows[i].light;
			RID base = light_storage->light_instance_get_base_light(li);

			if (light_storage->light_get_type(base) == RSE::LIGHT_DIRECTIONAL) {
				p_render_data->directional_shadows.push_back(i);
			} else if (light_storage->light_get_type(base) == RSE::LIGHT_OMNI && light_storage->light_omni_get_shadow_mode(base) == RSE::LIGHT_OMNI_SHADOW_CUBE) {
				p_render_data->cube_shadows.push_back(i);
			} else {
				p_render_data->shadows.push_back(i);
			}
		}

		if (p_render_data->cube_shadows.size()) {
			RENDER_TIMESTAMP("Render OmniLight Shadows");
			// Cube shadows are rendered in their own way.
			for (const int &index : p_render_data->cube_shadows) {
				_render_shadow_pass(p_render_data->render_shadows[index].light, p_render_data->shadow_atlas, p_render_data->render_shadows[index].pass, p_render_data->render_shadows[index].instances, lod_distance_multiplier, p_render_data->scene_data->screen_mesh_lod_threshold, true, true, true, p_render_data->render_info, viewport_size, p_render_data->scene_data->cam_transform);
			}
		}

		if (p_render_data->directional_shadows.size()) {
			//open the pass for directional shadows
			light_storage->update_directional_shadow_atlas();
			RD::get_singleton()->draw_list_begin(light_storage->direction_shadow_get_fb(), RD::DRAW_CLEAR_DEPTH, Vector<Color>(), 0.0f);
			RD::get_singleton()->draw_list_end();
		}
	}

	bool render_shadows = p_render_data->directional_shadows.size() || p_render_data->shadows.size();

	if (render_shadows) {
		RENDER_TIMESTAMP("Render Directional/SpotLight Shadows");

		_render_shadow_begin();

		//render directional shadows
		for (uint32_t i = 0; i < p_render_data->directional_shadows.size(); i++) {
			_render_shadow_pass(p_render_data->render_shadows[p_render_data->directional_shadows[i]].light, p_render_data->shadow_atlas, p_render_data->render_shadows[p_render_data->directional_shadows[i]].pass, p_render_data->render_shadows[p_render_data->directional_shadows[i]].instances, lod_distance_multiplier, p_render_data->scene_data->screen_mesh_lod_threshold, false, i == p_render_data->directional_shadows.size() - 1, false, p_render_data->render_info, viewport_size, p_render_data->scene_data->cam_transform);
		}
		//render positional shadows
		for (uint32_t i = 0; i < p_render_data->shadows.size(); i++) {
			_render_shadow_pass(p_render_data->render_shadows[p_render_data->shadows[i]].light, p_render_data->shadow_atlas, p_render_data->render_shadows[p_render_data->shadows[i]].pass, p_render_data->render_shadows[p_render_data->shadows[i]].instances, lod_distance_multiplier, p_render_data->scene_data->screen_mesh_lod_threshold, i == 0, i == p_render_data->shadows.size() - 1, true, p_render_data->render_info, viewport_size, p_render_data->scene_data->cam_transform);
		}

		_render_shadow_process();
		_render_shadow_end();
	}
}

void RenderFRPClustered::_prepare_lighting(RenderDataRD *p_render_data) {
	// First step of the Lighting pass: everything the lighting shader consumes, plus
	// the PRE_LIGHTING compositor stage that may still edit the G-buffer the previous
	// pass wrote.
	RendererRD::LightStorage *light_storage = RendererRD::LightStorage::get_singleton();
	RendererRD::TextureStorage *texture_storage = RendererRD::TextureStorage::get_singleton();

	Ref<RenderSceneBuffersRD> rb = p_render_data->render_buffers;
	Ref<RenderBufferDataFRPClustered> rb_data;
	if (rb.is_valid() && rb->has_custom_data(RB_SCOPE_FRP_CLUSTERED)) {
		// Our forward clustered custom data buffer will only be available when we're rendering our normal view.
		// This will not be available when rendering reflection probes.
		rb_data = rb->get_custom_data(RB_SCOPE_FRP_CLUSTERED);
	}

	RENDER_TIMESTAMP("Prepare Lighting");

	if (current_cluster_builder) {
		// Note: when rendering stereoscopic (multiview) we are using our combined frustum projection to create
		// our cluster data. We use reprojection in the shader to adjust for our left/right eye.
		// This only works as we don't filter our cluster by depth buffer.
		// If we ever make this optimization we should make it optional and only use it in mono.
		// What we win by filtering out a few lights, we loose by having to do the work double for stereo.
		current_cluster_builder->begin(p_render_data->scene_data->cam_transform, p_render_data->scene_data->cam_projection, !p_render_data->reflection_probe.is_valid());
	}

	bool using_shadows = true;

	if (p_render_data->reflection_probe.is_valid()) {
		if (!RSG::light_storage->reflection_probe_renders_shadows(light_storage->reflection_probe_instance_get_probe(p_render_data->reflection_probe))) {
			using_shadows = false;
		}
	} else {
		//do not render reflections when rendering a reflection probe
		light_storage->update_reflection_probe_buffer(p_render_data, *p_render_data->reflection_probes, p_render_data->scene_data->cam_transform.affine_inverse(), p_render_data->environment);
	}

	uint32_t directional_light_count = 0;
	uint32_t positional_light_count = 0;
	light_storage->update_light_buffers(p_render_data, *p_render_data->lights, p_render_data->scene_data->cam_transform, p_render_data->shadow_atlas, using_shadows, directional_light_count, positional_light_count, p_render_data->directional_light_soft_shadows);
	texture_storage->update_decal_buffer(*p_render_data->decals, p_render_data->scene_data->cam_transform);

	p_render_data->directional_light_count = directional_light_count;

	if (current_cluster_builder) {
		current_cluster_builder->bake_cluster();
	}

	if (rb_data.is_valid()) {
		RENDER_TIMESTAMP("Update Volumetric Fog");
		bool directional_shadows = RendererRD::LightStorage::get_singleton()->has_directional_shadows(directional_light_count);
		_update_volumetric_fog(rb, p_render_data->environment, p_render_data->scene_data->cam_projection, p_render_data->scene_data->cam_transform, p_render_data->scene_data->prev_cam_transform.affine_inverse(), p_render_data->shadow_atlas, directional_light_count, directional_shadows, positional_light_count, p_render_data->voxel_gi_count, *p_render_data->fog_volumes);
	}
}

// FRP has no global illumination. SDFGI is never created, so the engine's SDFGI
// queries report "nothing pending" and its render entry point is never reached.
// The overrides have to exist: RendererSceneRender declares them pure virtual, and
// the scene culling side keeps asking whether a region needs an update.
void RenderFRPClustered::_render_sdfgi(Ref<RenderSceneBuffersRD> p_render_buffers, const Vector3i &p_from, const Vector3i &p_size, const AABB &p_bounds, const PagedArray<RenderGeometryInstance *> &p_instances, const RID &p_albedo_texture, const RID &p_emission_texture, const RID &p_emission_aniso_texture, const RID &p_geom_facing_texture, float p_exposure_normalization) {
}

void RenderFRPClustered::sdfgi_update(const Ref<RenderSceneBuffers> &p_render_buffers, RID p_environment, const Vector3 &p_world_position) {
}

int RenderFRPClustered::sdfgi_get_pending_region_count(const Ref<RenderSceneBuffers> &p_render_buffers) const {
	return 0;
}

AABB RenderFRPClustered::sdfgi_get_pending_region_bounds(const Ref<RenderSceneBuffers> &p_render_buffers, int p_region) const {
	return AABB();
}

uint32_t RenderFRPClustered::sdfgi_get_pending_region_cascade(const Ref<RenderSceneBuffers> &p_render_buffers, int p_region) const {
	return 0;
}

void RenderFRPClustered::_process_sss(Ref<RenderSceneBuffersRD> p_render_buffers, const Projection &p_camera) {
	ERR_FAIL_COND(p_render_buffers.is_null());

	Size2i internal_size = p_render_buffers->get_internal_size();
	bool can_use_effects = internal_size.x >= 8 && internal_size.y >= 8;

	if (!can_use_effects) {
		//just copy
		return;
	}

	p_render_buffers->allocate_blur_textures();

	for (uint32_t v = 0; v < p_render_buffers->get_view_count(); v++) {
		RID internal_texture = p_render_buffers->get_internal_texture(v);
		RID depth_texture = p_render_buffers->get_depth_texture(v);
		ss_effects->sub_surface_scattering(p_render_buffers, internal_texture, depth_texture, p_camera, internal_size);
	}
}

void RenderFRPClustered::_present_frame(RenderDataRD *p_render_data, const StringName &p_texture) {
	ERR_FAIL_NULL(p_render_data);
	Ref<RenderSceneBuffersRD> rb = p_render_data->render_buffers;
	ERR_FAIL_COND(rb.is_null());

	RID source;
	if (p_texture == StringName()) {
		// The engine's tone mapped image, produced by the deferred tone mapping step.
		ERR_FAIL_COND_MSG(!rb->has_texture(SNAME("Tonemapper"), SNAME("destination")), "present() without a texture needs a deferred tone mapping step first.");
		source = rb->get_texture(SNAME("Tonemapper"), SNAME("destination"));
	} else {
		ERR_FAIL_COND_MSG(!rb->has_texture(SNAME("frp_pipeline"), p_texture), vformat("present(): the pipeline texture '%s' does not exist.", p_texture));
		source = rb->get_texture(SNAME("frp_pipeline"), p_texture);
	}

	RID render_target = rb->get_render_target();
	RID dest_fb = RendererRD::TextureStorage::get_singleton()->render_target_get_rd_framebuffer(render_target);
	// A viewport-sized blit with bilinear filtering: the tone mapped image is at the
	// internal size, the render target at the target size.
	copy_effects->copy_to_fb_rect(source, dest_fb, Rect2i(Point2i(), rb->get_target_size()), false, false, false, false, RID(), rb->get_view_count() > 1, false, false, false, Rect2(), 1.0, true);
}

void RenderFRPClustered::_fill_missing_velocity(Ref<RenderSceneBuffersRD> p_render_buffers, const RenderDataRD *p_render_data) {
	UniformSetCacheRD *uniform_set_cache = UniformSetCacheRD::get_singleton();
	ERR_FAIL_NULL(uniform_set_cache);

	Size2i internal_size = p_render_buffers->get_internal_size();
	// The depth is read per texel and only used to reconstruct the position, so a
	// nearest, non-repeating sampler is what this pass wants.
	RID depth_sampler = RendererRD::MaterialStorage::get_singleton()->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_NEAREST, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);

	VelocityFill::PushConstant push_constant;
	push_constant.resolution[0] = internal_size.width;
	push_constant.resolution[1] = internal_size.height;
	{
		Projection correction;
		correction.set_depth_correction(true, true, false);
		Projection reprojection = (correction * p_render_data->scene_data->prev_cam_projection) * p_render_data->scene_data->prev_cam_transform.affine_inverse() * p_render_data->scene_data->cam_transform * (correction * p_render_data->scene_data->cam_projection).inverse();
		RendererRD::MaterialStorage::store_camera(reprojection, push_constant.reprojection_matrix);
	}

	RID shader = velocity_fill.shader.version_get_shader(velocity_fill.shader_version, 0);
	ERR_FAIL_COND(shader.is_null());

	RD::get_singleton()->draw_command_begin_label("Fill Missing Motion Vectors");

	RD::ComputeListID compute_list = RD::get_singleton()->compute_list_begin();
	RD::get_singleton()->compute_list_bind_compute_pipeline(compute_list, velocity_fill.pipeline);

	for (uint32_t v = 0; v < p_render_buffers->get_view_count(); v++) {
		RD::Uniform u_depth(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, Vector<RID>({ depth_sampler, p_render_buffers->get_depth_texture(v) }));
		RD::Uniform u_velocity(RD::UNIFORM_TYPE_IMAGE, 1, p_render_buffers->get_velocity_buffer(false, v));

		RID uniform_set = uniform_set_cache->get_cache(shader, 0, u_depth, u_velocity);
		RD::get_singleton()->compute_list_bind_uniform_set(compute_list, uniform_set, 0);
		RD::get_singleton()->compute_list_set_push_constant(compute_list, &push_constant, sizeof(VelocityFill::PushConstant));
		RD::get_singleton()->compute_list_dispatch_threads(compute_list, internal_size.width, internal_size.height, 1);
	}

	RD::get_singleton()->compute_list_end();

	RD::get_singleton()->draw_command_end_label();
}

void RenderFRPClustered::_render_scene(RenderDataRD *p_render_data, const Color &p_default_bg_color) {
	scene_state.used_uniform_buffer_count = 0;

	RendererRD::LightStorage *light_storage = RendererRD::LightStorage::get_singleton();

	ERR_FAIL_NULL(p_render_data);

	Ref<RenderSceneBuffersRD> rb = p_render_data->render_buffers;
	ERR_FAIL_COND(rb.is_null());
	Ref<RenderBufferDataFRPClustered> rb_data;
	if (rb->has_custom_data(RB_SCOPE_FRP_CLUSTERED)) {
		// Our forward clustered custom data buffer will only be available when we're rendering our normal view.
		// This will not be available when rendering reflection probes.
		rb_data = rb->get_custom_data(RB_SCOPE_FRP_CLUSTERED);
	}
	bool is_reflection_probe = p_render_data->reflection_probe.is_valid();

	static const int texture_multisamples[RSE::VIEWPORT_MSAA_MAX] = { 1, 2, 4, 8 };

	//first of all, make a new render pass
	//fill up ubo

	RENDER_TIMESTAMP("Prepare 3D Scene");

	// get info about our rendering effects
	bool ce_needs_motion_vectors = _compositor_effects_has_flag(p_render_data, RSE::COMPOSITOR_EFFECT_FLAG_NEEDS_MOTION_VECTORS);
	bool ce_needs_normal_roughness = _compositor_effects_has_flag(p_render_data, RSE::COMPOSITOR_EFFECT_FLAG_NEEDS_ROUGHNESS);
	bool ce_needs_separate_specular = _compositor_effects_has_flag(p_render_data, RSE::COMPOSITOR_EFFECT_FLAG_NEEDS_SEPARATE_SPECULAR);

	// FRP has no VoxelGI, so no probe instance ever needs a render index and the
	// frame's voxel GI count stays zero.

	// obtain cluster builder
	if (light_storage->owns_reflection_probe_instance(p_render_data->reflection_probe)) {
		current_cluster_builder = light_storage->reflection_probe_instance_get_cluster_builder(p_render_data->reflection_probe, &cluster_builder_shared);

		if (p_render_data->camera_attributes.is_valid()) {
			light_storage->reflection_probe_set_baked_exposure(light_storage->reflection_probe_instance_get_probe(p_render_data->reflection_probe), RSG::camera_attributes->camera_attributes_get_exposure_normalization_factor(p_render_data->camera_attributes));
		}
	} else if (rb_data.is_valid()) {
		current_cluster_builder = rb_data->cluster_builder;
		p_render_data->voxel_gi_count = 0;
	} else {
		ERR_PRINT("No render buffer nor reflection atlas, bug"); // Should never happen!
		current_cluster_builder = nullptr;
		return; // No point in continuing, we'll just crash.
	}

	ERR_FAIL_NULL(current_cluster_builder);

	p_render_data->cluster_buffer = current_cluster_builder->get_cluster_buffer();
	p_render_data->cluster_size = current_cluster_builder->get_cluster_size();
	p_render_data->cluster_max_elements = current_cluster_builder->get_max_cluster_elements();

	_update_vrs(rb);

	RENDER_TIMESTAMP("Setup 3D Scene");

	// FRP's resource-authored schedule executes these real render operations.
	// Reflection probes and ordinary Compositors retain the legacy stage path.
	// The schedule is read here, before the frame's feature flags are derived,
	// because a disabled optional entry has to switch its consumer off as well:
	// the lighting shader must not sample an attachment whose producer was
	// removed from the schedule.
	RendererCompositorStorage *pipeline_storage = RendererCompositorStorage::get_singleton();
	PackedInt32Array pipeline;
	PackedStringArray pipeline_names;
	PackedInt32Array pipeline_provided;
	Dictionary pipeline_parameters;
	Vector<RID> pipeline_effects;
	if (!is_reflection_probe && p_render_data->compositor.is_valid()) {
		pipeline = pipeline_storage->compositor_get_frp_pipeline(p_render_data->compositor);
		pipeline_names = pipeline_storage->compositor_get_frp_pipeline_names(p_render_data->compositor);
		pipeline_provided = pipeline_storage->compositor_get_frp_pipeline_provided(p_render_data->compositor);
		pipeline_parameters = pipeline_storage->compositor_get_frp_pipeline_parameters(p_render_data->compositor);
		pipeline_effects = pipeline_storage->compositor_get_compositor_effects(p_render_data->compositor, RSE::COMPOSITOR_EFFECT_CALLBACK_TYPE_ANY, false);
	}
	// An empty schedule means the default order, which contains every operation. A
	// pass a plugin runs itself (declared through the provided pass ids) counts as
	// present: the schedule dropped its engine entry, so feature setup would
	// otherwise switch the effect off even though a pass is there to draw it.
	auto schedule_has = [&](int p_pass_id) -> bool {
		return pipeline.is_empty() || pipeline.has(p_pass_id) || pipeline_provided.has(p_pass_id);
	};

	bool using_debug_mvs = get_debug_draw_mode() == RSE::VIEWPORT_DEBUG_DRAW_MOTION_VECTORS;
	bool using_taa = rb->get_use_taa();

	enum {
		SCALE_NONE,
		SCALE_FSR2,
		SCALE_MFX,
	} scale_type = SCALE_NONE;

	switch (rb->get_scaling_3d_mode()) {
		case RSE::VIEWPORT_SCALING_3D_MODE_FSR2:
			scale_type = SCALE_FSR2;
			break;
		case RSE::VIEWPORT_SCALING_3D_MODE_METALFX_TEMPORAL:
#ifdef METAL_MFXTEMPORAL_ENABLED
			scale_type = SCALE_MFX;
#else
			scale_type = SCALE_NONE;
#endif
			break;
		default:
			break;
	}

	bool using_upscaling = scale_type != SCALE_NONE;

	// The Temporal AA entry is the switch when a schedule is authored: the viewport
	// jitter follows it (see RendererSceneCull::render_camera), so enabling the entry
	// turns TAA on and disabling the entry turns it off. The viewport's own use_taa is
	// deliberately not consulted while a schedule exists: the jitter rule drops it to
	// zero phases for a missing entry, and resolving a frame that is never jittered is
	// the blur the entry is supposed to avoid. A plugin pass that runs the pass itself
	// counts the same way. A viewport temporal upscaler brings its own jitter and keeps
	// TAA off, exactly as the viewport decided.
	using_taa = scale_type != SCALE_FSR2 && scale_type != SCALE_MFX &&
			(pipeline.is_empty() ? rb->get_use_taa() : schedule_has(FRPPipelineSpec::PASS_TEMPORAL_AA));

	// check if we need motion vectors
	bool motion_vectors_required;
	if (using_debug_mvs) {
		motion_vectors_required = true;
	} else if (ce_needs_motion_vectors) {
		motion_vectors_required = true;
	} else if (!is_reflection_probe && using_taa) {
		motion_vectors_required = true;
	} else if (!is_reflection_probe && using_upscaling) {
		motion_vectors_required = true;
	} else {
		motion_vectors_required = false;
	}

	//p_render_data->scene_data->subsurface_scatter_width = subsurface_scatter_size;
	p_render_data->scene_data->calculate_motion_vectors = motion_vectors_required;
	p_render_data->scene_data->directional_light_count = 0;
	p_render_data->scene_data->opaque_prepass_threshold = 0.99f;

	Size2i screen_size;
	RID color_framebuffer;
	RID color_only_framebuffer;
	RID depth_framebuffer;
	// True when the G-buffer pass has to write the velocity attachment as well.
	bool gbuffer_motion_vectors = false;
	RendererRD::MaterialStorage::Samplers samplers;

	// FRP's schedule was read above, before the frame's feature flags were derived.

	PassMode depth_pass_mode = PASS_MODE_DEPTH;
	uint32_t color_pass_flags = 0;
	Vector<Color> depth_pass_clear;
	bool using_separate_specular = false;
	// FRP has no screen space effects (SSAO / SSIL / SSR) and no global illumination
	// (SDFGI / VoxelGI) - neither exists in this renderer at all - and no debug
	// geometry: those are not FRP passes, so the frame never allocates, generates or
	// composites their attachments. The flags the engine copies expect stay false,
	// which is what keeps the lighting shader on its default (black) samplers.
	bool using_ssr = false;
	bool using_ssil = false;
	bool reverse_cull = p_render_data->scene_data->cam_transform.basis.determinant() < 0;
	bool using_motion_pass = rb_data.is_valid() && using_upscaling;

	if (is_reflection_probe) {
		uint32_t resolution = light_storage->reflection_probe_instance_get_resolution(p_render_data->reflection_probe);
		screen_size.x = resolution;
		screen_size.y = resolution;

		color_framebuffer = light_storage->reflection_probe_instance_get_framebuffer(p_render_data->reflection_probe, p_render_data->reflection_probe_pass);
		color_only_framebuffer = color_framebuffer;
		depth_framebuffer = light_storage->reflection_probe_instance_get_depth_framebuffer(p_render_data->reflection_probe, p_render_data->reflection_probe_pass);

		if (light_storage->reflection_probe_is_interior(light_storage->reflection_probe_instance_get_probe(p_render_data->reflection_probe))) {
			p_render_data->environment = RID(); //no environment on interiors
		}

		reverse_cull = true; // for some reason our views are inverted
		samplers = RendererRD::MaterialStorage::get_singleton()->samplers_rd_get_default();

		// Indicate pipelines for reflection probes are required.
		global_pipeline_data_required.use_reflection_probes = true;
	} else {
		screen_size = rb->get_internal_size();

		if (p_render_data->scene_data->calculate_motion_vectors) {
			color_pass_flags |= COLOR_PASS_FLAG_MOTION_VECTORS;
			scene_shader.enable_advanced_shader_group();

			// Indicate pipelines for motion vectors are required.
			global_pipeline_data_required.use_motion_vectors = true;
		}

		if (p_render_data->scene_data->view_count > 1) {
			color_pass_flags |= COLOR_PASS_FLAG_MULTIVIEW;
			// Try enabling here in case is_xr_enabled() returns false.
			scene_shader.shader.enable_group(SceneShaderFRPClustered::SHADER_GROUP_MULTIVIEW);

			// Indicate pipelines for multiview are required.
			global_pipeline_data_required.use_multiview = true;
		}

		color_framebuffer = rb_data->get_color_pass_fb(color_pass_flags);
		color_only_framebuffer = rb_data->get_color_only_fb();
		samplers = rb->get_samplers();
	}

	p_render_data->scene_data->emissive_exposure_normalization = -1.0;

	// Every pass below opens its own debug label, and the FRP schedule names those
	// labels after the authored passes. Wrapping the whole frame in one more label
	// would make that wrapper the only top-level entry in a RenderDoc capture, so the
	// pass names are deliberately the outermost markers here.
	RD::get_singleton()->draw_command_begin_label("Render Setup");

	_setup_lightmaps(p_render_data, *p_render_data->lightmaps, p_render_data->scene_data->cam_transform);
	uint32_t depth_prepass_uniform_buffer_index = _setup_environment(p_render_data, is_reflection_probe, screen_size, screen_size, p_default_bg_color, false);

	// May have changed due to the above (light buffer enlarged, as an example).
	_update_render_base_uniform_set();

	// The FRP G-buffer pass is the only geometry pass over opaque surfaces, so it
	// cannot write per-object motion vectors the way upstream's forward colour
	// pass does. Whenever the frame needs motion vectors (TAA, 3D upscaling, the
	// motion debug view, or a compositor effect that asks for them) the dedicated
	// motion list has to be populated instead of only being filled for upscaling.
	_fill_render_list(RENDER_LIST_OPAQUE, p_render_data, PASS_MODE_COLOR, false, motion_vectors_required);
	render_list[RENDER_LIST_OPAQUE].sort_by_key();
	render_list[RENDER_LIST_OPAQUE_FALLBACK].sort_by_key();
	render_list[RENDER_LIST_ALPHA].sort_by_reverse_depth_and_priority();

	int *render_info = p_render_data->render_info ? p_render_data->render_info->info[RSE::VIEWPORT_RENDER_INFO_TYPE_VISIBLE] : (int *)nullptr;
	_fill_instance_data(RENDER_LIST_OPAQUE, render_info);
	_fill_instance_data(RENDER_LIST_OPAQUE_FALLBACK, render_info);
	_fill_instance_data(RENDER_LIST_ALPHA, render_info);

	RD::get_singleton()->draw_command_end_label();

	if (!is_reflection_probe) {
		// The G-buffer pass is mandatory in the FRP renderer and replaces the optional depth pre-pass.
		depth_pass_mode = PASS_MODE_GBUFFER;
		// Frames that need velocity (TAA, 3D upscaling, motion debug view) get the
		// G-buffer framebuffer that also carries the motion vector attachment, so the
		// opacity geometry is still drawn exactly once.
		gbuffer_motion_vectors = using_motion_pass || motion_vectors_required;
		depth_framebuffer = rb_data->get_depth_fb(gbuffer_motion_vectors ? RenderBufferDataFRPClustered::DEPTH_FB_GBUFFER_MOTION : RenderBufferDataFRPClustered::DEPTH_FB_GBUFFER);
		depth_pass_clear.push_back(Color(0, 0, 0, 0)); // normal_roughness
		depth_pass_clear.push_back(Color(0, 0, 0, 0)); // albedo
		depth_pass_clear.push_back(Color(0, 0, 0, 0)); // orm
		depth_pass_clear.push_back(Color(0, 0, 0, 0)); // emission
		if (gbuffer_motion_vectors) {
			// (0, 0) would mean "moved to this pixel from everywhere"; -1 marks the
			// attachment as having no motion, which is what the velocity buffer needs.
			depth_pass_clear.push_back(Color(-1, -1, 0, 0)); // motion vectors
		}
	}

	bool using_sss = rb_data.is_valid() && !is_reflection_probe && scene_state.used_sss && ss_effects->sss_get_quality() != RSE::SUB_SURFACE_SCATTERING_QUALITY_DISABLED;

	if (using_sss && p_render_data->transparent_bg) {
		WARN_PRINT_ONCE("Sub-surface scattering is not supported in viewports with a transparent background. Disabling SSS in transparent viewport.");
		using_sss = false;
	}

	if ((using_sss || ce_needs_separate_specular) && !using_separate_specular) {
		using_separate_specular = true;
		color_pass_flags |= COLOR_PASS_FLAG_SEPARATE_SPECULAR;
		color_framebuffer = rb_data->get_color_pass_fb(color_pass_flags);
	}

	// Ensure this is allocated so we don't get a stutter the first time an object with SSS appears on screen.
	if (global_surface_data.sss_used && !is_reflection_probe) {
		rb_data->ensure_specular();
	}

	if (global_surface_data.normal_texture_used && !is_reflection_probe) {
		rb_data->ensure_normal_roughness_texture();
	}

	// The mandatory G-buffer pass belongs to the advanced shader group.
	if (!is_reflection_probe || using_sss || using_separate_specular || scene_state.used_lightmap || global_surface_data.sss_used) {
		scene_shader.enable_advanced_shader_group(p_render_data->scene_data->view_count > 1);
	}

	// Update the global pipeline requirements with all the features found to be in use in this scene.
	if (depth_pass_mode == PASS_MODE_DEPTH_NORMAL_ROUGHNESS || global_surface_data.normal_texture_used) {
		global_pipeline_data_required.use_normal_and_roughness = true;
	}

	if (scene_state.used_lightmap || scene_state.lightmaps_used > 0) {
		global_pipeline_data_required.use_lightmaps = true;
	}

	if (using_separate_specular || global_surface_data.sss_used) {
		global_pipeline_data_required.use_separate_specular = true;
	}

	// Update the compiled pipelines if any of the requirements have changed.
	_update_dirty_geometry_pipelines();

	RID radiance_texture;
	bool draw_sky = false;
	bool draw_sky_fog_only = false;
	// We invert luminance_multiplier for sky so that we can combine it with exposure value.
	float sky_luminance_multiplier = 1.0 / rb->get_luminance_multiplier();
	float sky_brightness_multiplier = 1.0;

	Color clear_color;
	bool load_color = false;

	if (get_debug_draw_mode() == RSE::VIEWPORT_DEBUG_DRAW_OVERDRAW) {
		clear_color = Color(0, 0, 0, 1); //in overdraw mode, BG should always be black
	} else if (is_environment(p_render_data->environment)) {
		RSE::EnvironmentBG bg_mode = environment_get_background(p_render_data->environment);
		float bg_energy_multiplier = environment_get_bg_energy_multiplier(p_render_data->environment);
		bg_energy_multiplier *= environment_get_bg_intensity(p_render_data->environment);
		RSE::EnvironmentReflectionSource reflection_source = environment_get_reflection_source(p_render_data->environment);

		if (p_render_data->camera_attributes.is_valid()) {
			bg_energy_multiplier *= RSG::camera_attributes->camera_attributes_get_exposure_normalization_factor(p_render_data->camera_attributes);
		}

		switch (bg_mode) {
			case RSE::ENV_BG_CLEAR_COLOR: {
				clear_color = p_default_bg_color;
				clear_color.r *= bg_energy_multiplier;
				clear_color.g *= bg_energy_multiplier;
				clear_color.b *= bg_energy_multiplier;
				if (!p_render_data->transparent_bg && (rb->has_custom_data(RB_SCOPE_FOG) || environment_get_fog_enabled(p_render_data->environment))) {
					draw_sky_fog_only = true;
					RendererRD::MaterialStorage::get_singleton()->material_set_param(sky.sky_scene_state.fog_material, "clear_color", Variant(clear_color.srgb_to_linear()));
				}
			} break;
			case RSE::ENV_BG_COLOR: {
				clear_color = environment_get_bg_color(p_render_data->environment);
				clear_color.r *= bg_energy_multiplier;
				clear_color.g *= bg_energy_multiplier;
				clear_color.b *= bg_energy_multiplier;
				if (!p_render_data->transparent_bg && (rb->has_custom_data(RB_SCOPE_FOG) || environment_get_fog_enabled(p_render_data->environment))) {
					draw_sky_fog_only = true;
					RendererRD::MaterialStorage::get_singleton()->material_set_param(sky.sky_scene_state.fog_material, "clear_color", Variant(clear_color.srgb_to_linear()));
				}
			} break;
			case RSE::ENV_BG_SKY: {
				draw_sky = !p_render_data->transparent_bg;
			} break;
			case RSE::ENV_BG_CANVAS: {
				if (!is_reflection_probe) {
					RID texture = RendererRD::TextureStorage::get_singleton()->render_target_get_rd_texture(rb->get_render_target());
					bool convert_to_linear = !RendererRD::TextureStorage::get_singleton()->render_target_is_using_hdr(rb->get_render_target());
					copy_effects->copy_to_fb_rect(texture, color_only_framebuffer, Rect2i(), false, false, false, false, RID(), false, false, convert_to_linear);
				}
				load_color = true;
			} break;
			case RSE::ENV_BG_KEEP: {
				load_color = true;
			} break;
			case RSE::ENV_BG_CAMERA_FEED: {
			} break;
			default: {
			}
		}

		// setup sky if used for ambient, reflections, or background
		if (draw_sky || draw_sky_fog_only || (reflection_source == RSE::ENV_REFLECTION_SOURCE_BG && bg_mode == RSE::ENV_BG_SKY) || reflection_source == RSE::ENV_REFLECTION_SOURCE_SKY || environment_get_ambient_source(p_render_data->environment) == RSE::ENV_AMBIENT_SOURCE_SKY) {
			RENDER_TIMESTAMP("Setup Sky");
			RD::get_singleton()->draw_command_begin_label("Setup Sky");

			// Setup our sky render information for this frame/viewport
			sky.setup_sky(p_render_data, screen_size);

			sky_brightness_multiplier *= bg_energy_multiplier;

			RID sky_rid = environment_get_sky(p_render_data->environment);
			if (sky_rid.is_valid()) {
				sky.update_radiance_buffers(rb, p_render_data->environment, p_render_data->scene_data->cam_transform.origin, time, sky_luminance_multiplier, sky_brightness_multiplier);
				radiance_texture = sky.sky_get_radiance_texture_rd(sky_rid);
			} else {
				// do not try to draw sky if invalid
				draw_sky = false;
			}

			if (draw_sky || draw_sky_fog_only) {
				// update sky half/quarter res buffers (if required)
				sky.update_res_buffers(rb, p_render_data->environment, time, sky_luminance_multiplier, sky_brightness_multiplier);
			}

			RD::get_singleton()->draw_command_end_label();
		}
	} else {
		clear_color = p_default_bg_color;
	}

	RSE::ViewportMSAA msaa = rb->get_msaa_3d();
	bool use_msaa = msaa != RSE::VIEWPORT_MSAA_DISABLED;

	bool ce_pre_opaque_resolved_color = use_msaa && _compositor_effects_has_flag(p_render_data, RSE::COMPOSITOR_EFFECT_FLAG_ACCESS_RESOLVED_COLOR, RSE::COMPOSITOR_EFFECT_CALLBACK_TYPE_PRE_OPAQUE);
	bool ce_post_opaque_resolved_color = use_msaa && _compositor_effects_has_flag(p_render_data, RSE::COMPOSITOR_EFFECT_FLAG_ACCESS_RESOLVED_COLOR, RSE::COMPOSITOR_EFFECT_CALLBACK_TYPE_POST_OPAQUE);
	bool ce_pre_transparent_resolved_color = use_msaa && _compositor_effects_has_flag(p_render_data, RSE::COMPOSITOR_EFFECT_FLAG_ACCESS_RESOLVED_COLOR, RSE::COMPOSITOR_EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT);

	bool ce_pre_opaque_resolved_depth = use_msaa && _compositor_effects_has_flag(p_render_data, RSE::COMPOSITOR_EFFECT_FLAG_ACCESS_RESOLVED_DEPTH, RSE::COMPOSITOR_EFFECT_CALLBACK_TYPE_PRE_OPAQUE);
	bool ce_post_opaque_resolved_depth = use_msaa && _compositor_effects_has_flag(p_render_data, RSE::COMPOSITOR_EFFECT_FLAG_ACCESS_RESOLVED_DEPTH, RSE::COMPOSITOR_EFFECT_CALLBACK_TYPE_POST_OPAQUE);
	bool ce_pre_transparent_resolved_depth = use_msaa && _compositor_effects_has_flag(p_render_data, RSE::COMPOSITOR_EFFECT_FLAG_ACCESS_RESOLVED_DEPTH, RSE::COMPOSITOR_EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT);

	bool force_depth_pre_pass = scene_state.used_opaque_stencil;
	bool depth_pre_pass = (force_depth_pre_pass || bool(GLOBAL_GET_CACHED(bool, "rendering/driver/depth_prepass/enable"))) && depth_framebuffer.is_valid();

	// In the FRP renderer the G-buffer pass is mandatory, regardless of the depth pre-pass setting.
	if (!is_reflection_probe) {
		depth_pre_pass = true;
	}

	SceneShaderFRPClustered::ShaderSpecialization base_specialization = scene_shader.default_specialization;
	base_specialization.use_depth_fog = p_render_data->environment.is_valid() && environment_get_fog_mode(p_render_data->environment) == RSE::EnvironmentFogMode::ENV_FOG_MODE_DEPTH;

	bool using_ssao = false;

	// FRP runs no screen-space effect and no global illumination, so the frame
	// state's per-frame flags for them stay zero (see _setup_environment()).

	// Every entry owns the internal operations it needs (MSAA resolve, screen and
	// depth copies, SSIL/SSR history, specular merge, motion vectors), and the
	// Temporal AA entry is the TAA switch with the viewport jitter following it, so a
	// schedule never has to be repaired for a viewport or material setting.
	const bool explicit_pipeline = !pipeline.is_empty();
	auto stage_effects = [&](RSE::CompositorEffectCallbackType p_stage) {
		if (!explicit_pipeline) {
			_process_compositor_effects(p_stage, p_render_data);
		}
	};
	uint32_t opaque_pass_uniform_buffer_index = 0;
	bool opaque_pass_uniforms_ready = false;
	RID rp_uniform_set;
	// Resolves the frame's colour, depth and velocity once per frame. Both the
	// temporal AA operation and the tone mapping operation need resolved inputs, and
	// either of them can be the first to run.
	bool frame_color_resolved = false;
	auto resolve_frame_buffers = [&]() {
		if (frame_color_resolved || !(rb_data.is_valid() && use_msaa)) {
			return;
		}
		frame_color_resolved = true;

		RENDER_TIMESTAMP("Resolve");

		RD::get_singleton()->draw_command_begin_label("Resolve");

		bool resolve_velocity_buffer = (using_taa || using_upscaling || ce_needs_motion_vectors) && rb->has_velocity_buffer(true);
		for (uint32_t v = 0; v < rb->get_view_count(); v++) {
			RD::get_singleton()->texture_resolve_multisample(rb->get_color_msaa(v), rb->get_internal_texture(v));
			resolve_effects->resolve_depth(rb->get_depth_msaa(v), rb->get_depth_texture(v), rb->get_internal_size(), texture_multisamples[msaa]);

			if (resolve_velocity_buffer) {
				RD::get_singleton()->texture_resolve_multisample(rb->get_velocity_buffer(true, v), rb->get_velocity_buffer(false, v));
			}
		}

		RD::get_singleton()->draw_command_end_label();
	};

	// One internal renderer operation. A user-facing pass expands to one or more of
	// these; operations are implementation units and are not separately switchable
	// (see FRPPipelineSpec).
	auto run_builtin_operation = [&](int p_operation) {
		switch (p_operation) {
			case FRPPipelineSpec::OP_SHADOW_PRECOMPUTE: { // Shadow maps. Runs before everything else.
				if (!is_reflection_probe) {
					_precompute_shadows(p_render_data);
				}
			} break;
			case FRPPipelineSpec::OP_VIRTUAL_TEXTURE: { // Virtual texture updates. Must run before the G-buffer.
				if (!is_reflection_probe) {
					RenderingServer::get_singleton()->execute_virtual_texture_updates();
				}
			} break;
			case FRPPipelineSpec::OP_GBUFFER: { // GBuffer.
				if (!is_reflection_probe) {
					stage_effects(RSE::COMPOSITOR_EFFECT_CALLBACK_TYPE_PRE_GBUFFER);
				}
				if (depth_pre_pass) { // G-buffer, or depth pre-pass for reflection probes.
					// No GI work runs beside the depth pre-pass any more, so it always
					// clears instead of pre-resolving into a running compute pass.
					RENDER_TIMESTAMP("Render Depth Pre-Pass");

					if (is_reflection_probe) {
						RD::get_singleton()->draw_command_begin_label("Render Depth Pre-Pass");
					} else {
						RD::get_singleton()->draw_command_begin_label("Render GBuffer");
					}

					RID depth_uniform_set = _setup_render_pass_uniform_set(RENDER_LIST_OPAQUE, nullptr, RID(), samplers, depth_prepass_uniform_buffer_index);

					bool finish_depth = using_ssao || using_ssil || ce_pre_opaque_resolved_depth || ce_post_opaque_resolved_depth;
					// Motion vectors ride along in this same geometry draw when the
					// framebuffer carries the velocity attachment.
					const uint32_t gbuffer_color_pass_flags = gbuffer_motion_vectors ? uint32_t(COLOR_PASS_FLAG_MOTION_VECTORS) : 0u;
					RenderListParameters render_list_params(render_list[RENDER_LIST_OPAQUE].elements.ptr(), render_list[RENDER_LIST_OPAQUE].element_info.ptr(), render_list[RENDER_LIST_OPAQUE].elements.size(), reverse_cull, depth_pass_mode, gbuffer_color_pass_flags, rb_data.is_null(), p_render_data->directional_light_soft_shadows, depth_uniform_set, get_debug_draw_mode() == RSE::VIEWPORT_DEBUG_DRAW_WIREFRAME, Vector2(), p_render_data->scene_data->lod_distance_multiplier, p_render_data->scene_data->screen_mesh_lod_threshold, p_render_data->scene_data->view_count, 0, base_specialization);
					_render_list_with_draw_list(&render_list_params, depth_framebuffer, RD::DRAW_CLEAR_ALL, depth_pass_clear, 0.0f, 0u, p_render_data->render_region);

					RD::get_singleton()->draw_command_end_label();

					if (use_msaa) {
						RENDER_TIMESTAMP("Resolve Depth Pre-Pass (MSAA)");
						RD::get_singleton()->draw_command_begin_label("Resolve Depth Pre-Pass (MSAA)");
						if (depth_pass_mode == PASS_MODE_GBUFFER) {
							for (uint32_t v = 0; v < rb->get_view_count(); v++) {
								resolve_effects->resolve_gi(rb->get_depth_msaa(v), rb_data->get_normal_roughness_msaa(v), RID(), rb->get_depth_texture(v), rb_data->get_normal_roughness(v), RID(), rb->get_internal_size(), texture_multisamples[msaa], Vector<RID>({ rb_data->get_gbuffer_albedo_msaa(v), rb_data->get_gbuffer_orm_msaa(v), rb_data->get_gbuffer_emission_msaa(v) }), Vector<RID>({ rb_data->get_gbuffer_albedo(v), rb_data->get_gbuffer_orm(v), rb_data->get_gbuffer_emission(v) }));
							}
						} else if (depth_pass_mode == PASS_MODE_DEPTH_NORMAL_ROUGHNESS) {
							for (uint32_t v = 0; v < rb->get_view_count(); v++) {
								resolve_effects->resolve_gi(rb->get_depth_msaa(v), rb_data->get_normal_roughness_msaa(v), RID(), rb->get_depth_texture(v), rb_data->get_normal_roughness(v), RID(), rb->get_internal_size(), texture_multisamples[msaa]);
							}
						} else if (finish_depth) {
							for (uint32_t v = 0; v < rb->get_view_count(); v++) {
								resolve_effects->resolve_depth(rb->get_depth_msaa(v), rb->get_depth_texture(v), rb->get_internal_size(), texture_multisamples[msaa]);
							}
						}
						RD::get_singleton()->draw_command_end_label();
					}
				}

				if (!is_reflection_probe) {
					stage_effects(RSE::COMPOSITOR_EFFECT_CALLBACK_TYPE_POST_GBUFFER);
				}

				{
					if (ce_pre_opaque_resolved_color) {
						// We haven't rendered color data yet so...
						WARN_PRINT_ONCE("Pre opaque rendering effects can't access resolved color buffers.");
					}

					if (ce_pre_opaque_resolved_depth && !depth_pre_pass) {
						// We haven't rendered depth data yet so...
						WARN_PRINT_ONCE("Pre opaque rendering effects can't access resolved depth buffers.");
					}

					RENDER_TIMESTAMP("Process Pre Opaque Compositor Effects");
					stage_effects(RSE::COMPOSITOR_EFFECT_CALLBACK_TYPE_PRE_OPAQUE);
				}
			} break;
			case FRPPipelineSpec::OP_LIGHTING_PREPARE: { // Light/cluster data, decals, volumetric fog.
				_prepare_lighting(p_render_data);
			} break;
			case FRPPipelineSpec::OP_PRE_LIGHTING_STAGE: { // PRE_LIGHTING compositor stage.
				if (current_cluster_builder) {
					base_specialization.cluster_has_area_light = current_cluster_builder->get_cluster_count_by_type(ClusterBuilderRD::ELEMENT_TYPE_AREA_LIGHT) != 0;
				}

				if (!is_reflection_probe) {
					stage_effects(RSE::COMPOSITOR_EFFECT_CALLBACK_TYPE_PRE_LIGHTING);
				}
			} break;
			case FRPPipelineSpec::OP_DEFERRED_LIGHTING: { // Deferred lighting.
				// In the FRP renderer the opaque color pass is replaced by the FRP lighting pass.
				RENDER_TIMESTAMP("Render FRP Lighting Pass");

				RD::get_singleton()->draw_command_begin_label("Render FRP Lighting Pass");

				p_render_data->scene_data->directional_light_count = p_render_data->directional_light_count;
				p_render_data->scene_data->opaque_prepass_threshold = 0.0f;

				// Shadow pass can change the base uniform set samplers.
				_update_render_base_uniform_set();

				opaque_pass_uniform_buffer_index = _setup_environment(p_render_data, is_reflection_probe, screen_size, screen_size, p_default_bg_color, true, using_motion_pass);
				opaque_pass_uniforms_ready = true;

				{
					Vector<Color> c;
					if (!load_color) {
						Color cc = clear_color.srgb_to_linear();
						if (using_separate_specular || rb_data.is_valid()) {
							// Effects that rely on separate specular, like subsurface scattering, must clear the alpha to zero.
							cc.a = 0;
						}
						c.push_back(cc);

						if (rb_data.is_valid()) {
							c.push_back(Color(0, 0, 0, 0)); // Separate specular.
							c.push_back(Color(0, 0, 0, 0)); // Motion vector. Pushed to the clear color vector even if the framebuffer isn't bound.
						}
					}

					uint32_t opaque_color_pass_flags = using_motion_pass ? (color_pass_flags & ~uint32_t(COLOR_PASS_FLAG_MOTION_VECTORS)) : color_pass_flags;
					RID opaque_framebuffer = using_motion_pass ? rb_data->get_color_pass_fb(opaque_color_pass_flags) : color_framebuffer;

					if (is_reflection_probe) {
						// Probe faces have no G-buffer; render their opaque geometry directly.
						rp_uniform_set = _setup_render_pass_uniform_set(RENDER_LIST_OPAQUE, p_render_data, radiance_texture, samplers, opaque_pass_uniform_buffer_index, true);
						RenderListParameters params(render_list[RENDER_LIST_OPAQUE].elements.ptr(), render_list[RENDER_LIST_OPAQUE].element_info.ptr(), render_list[RENDER_LIST_OPAQUE].elements.size(), reverse_cull, PASS_MODE_COLOR, opaque_color_pass_flags, true, p_render_data->directional_light_soft_shadows, rp_uniform_set, false, Vector2(), p_render_data->scene_data->lod_distance_multiplier, p_render_data->scene_data->screen_mesh_lod_threshold, 1, 0, base_specialization);
						_render_list_with_draw_list(&params, opaque_framebuffer, RD::DrawFlags(load_color ? RD::DRAW_DEFAULT_ALL : RD::DRAW_CLEAR_COLOR_ALL) | (depth_pre_pass ? RD::DRAW_DEFAULT_ALL : RD::DRAW_CLEAR_DEPTH), c, 0.0f, 0u, p_render_data->render_region);
					} else {
						// Lighting samples depth; it must not also attach that texture for
						// drawing. Keep only color outputs, including optional specular/MV.
						RID lighting_color = use_msaa ? rb->get_texture(RB_SCOPE_BUFFERS, RB_TEX_COLOR_MSAA) : rb->get_internal_texture();
						RID lighting_specular = (opaque_color_pass_flags & COLOR_PASS_FLAG_SEPARATE_SPECULAR) ? rb->get_texture(RB_SCOPE_FRP_CLUSTERED, use_msaa ? RB_TEX_SPECULAR_MSAA : RB_TEX_SPECULAR) : RID();
						// The full-screen lighting shader writes colour and, optionally,
						// separate specular. The velocity texture must not be attached:
						// it would give this framebuffer a colour output mask the shader
						// does not declare, which fails pipeline creation. Motion vectors
						// are produced by the Motion Vectors pass instead.
						opaque_framebuffer = FramebufferCacheRD::get_singleton()->get_cache_multiview(rb->get_view_count(), lighting_color, lighting_specular);
						// FRP lighting pass: full-screen triangle that reads the G-buffer and computes lighting.
						RD::DrawListID draw_list = RD::get_singleton()->draw_list_begin(opaque_framebuffer, RD::DrawFlags(load_color ? RD::DRAW_DEFAULT_ALL : RD::DRAW_CLEAR_COLOR_ALL) | (depth_pre_pass ? RD::DRAW_DEFAULT_ALL : RD::DRAW_CLEAR_DEPTH), c, 0.0f, 0u, p_render_data->render_region);
						uint32_t lighting_mode = 0;
						if (using_separate_specular) {
							lighting_mode |= 1;
						}
						if (p_render_data->scene_data->view_count > 1) {
							lighting_mode |= 2;
						}

						SceneShaderFRPClustered::ShaderSpecialization lighting_specialization = base_specialization;
						lighting_specialization.use_light_projector = true;
						lighting_specialization.use_light_soft_shadows = true;
						lighting_specialization.use_directional_soft_shadows = p_render_data->directional_light_soft_shadows;
						if (!frp_lighting.specialization_initialized || frp_lighting.specialization.packed_0 != lighting_specialization.packed_0 || frp_lighting.specialization.packed_1 != lighting_specialization.packed_1) {
							Vector<RD::PipelineSpecializationConstant> constants;
							RD::PipelineSpecializationConstant constant;
							constant.type = RD::PIPELINE_SPECIALIZATION_CONSTANT_TYPE_INT;
							constant.constant_id = 0;
							constant.int_value = lighting_specialization.packed_0;
							constants.push_back(constant);
							constant.constant_id = 1;
							constant.int_value = lighting_specialization.packed_1;
							constants.push_back(constant);
							for (int i = 0; i < FRP_LIGHTING_MODE_MAX; i++) {
								frp_lighting.pipelines[i].update_specialization_constants(constants);
							}
							frp_lighting.specialization = lighting_specialization;
							frp_lighting.specialization_initialized = true;
						}
						RID shader = frp_lighting.shader.version_get_shader(frp_lighting.shader_version, lighting_mode);
						// Descriptor layouts include shader-stage visibility, not just binding types.
						RID lighting_base_uniform_set = UniformSetCacheRD::get_singleton()->get_cache_vec(shader, SCENE_UNIFORM_SET, render_base_uniforms);
						rp_uniform_set = _setup_render_pass_uniform_set(RENDER_LIST_OPAQUE, p_render_data, radiance_texture, samplers, opaque_pass_uniform_buffer_index, true, shader);
						RD::get_singleton()->draw_list_bind_uniform_set(draw_list, lighting_base_uniform_set, SCENE_UNIFORM_SET);
						RD::get_singleton()->draw_list_bind_uniform_set(draw_list, rp_uniform_set, RENDER_PASS_UNIFORM_SET);
						RD::get_singleton()->draw_list_bind_render_pipeline(draw_list, frp_lighting.pipelines[lighting_mode].get_render_pipeline(RD::INVALID_ID, RD::get_singleton()->framebuffer_get_format(opaque_framebuffer)));

						RD::get_singleton()->draw_list_draw(draw_list, false, 1u, 3u);
						RD::get_singleton()->draw_list_end();
					}
				}

				RD::get_singleton()->draw_command_end_label();

				if (!is_reflection_probe) {
					if (use_msaa && _compositor_effects_has_flag(p_render_data, RSE::COMPOSITOR_EFFECT_FLAG_ACCESS_RESOLVED_COLOR, RSE::COMPOSITOR_EFFECT_CALLBACK_TYPE_POST_LIGHTING)) {
						for (uint32_t v = 0; v < rb->get_view_count(); v++) {
							RD::get_singleton()->texture_resolve_multisample(rb->get_color_msaa(v), rb->get_internal_texture(v));
						}
					}
					stage_effects(RSE::COMPOSITOR_EFFECT_CALLBACK_TYPE_POST_LIGHTING);
				}
			} break;
			case FRPPipelineSpec::OP_OPAQUE_FORWARD_FALLBACK: { // Opaque forward fallback.
				// Forward fallback pass: renders opaque materials that cannot be expressed in the G-buffer.
				if (!render_list[RENDER_LIST_OPAQUE_FALLBACK].elements.is_empty()) {
					RENDER_TIMESTAMP("Render Opaque Fallback Pass");

					RD::get_singleton()->draw_command_begin_label("Render Opaque Fallback Pass");

					uint32_t fallback_color_pass_flags = using_motion_pass ? (color_pass_flags & ~uint32_t(COLOR_PASS_FLAG_MOTION_VECTORS)) : color_pass_flags;
					RID fallback_framebuffer = using_motion_pass ? rb_data->get_color_pass_fb(fallback_color_pass_flags) : color_framebuffer;

					rp_uniform_set = _setup_render_pass_uniform_set(RENDER_LIST_OPAQUE_FALLBACK, p_render_data, radiance_texture, samplers, opaque_pass_uniform_buffer_index, true);

					RenderListParameters render_list_params(render_list[RENDER_LIST_OPAQUE_FALLBACK].elements.ptr(), render_list[RENDER_LIST_OPAQUE_FALLBACK].element_info.ptr(), render_list[RENDER_LIST_OPAQUE_FALLBACK].elements.size(), reverse_cull, PASS_MODE_COLOR, fallback_color_pass_flags, rb_data.is_null(), p_render_data->directional_light_soft_shadows, rp_uniform_set, get_debug_draw_mode() == RSE::VIEWPORT_DEBUG_DRAW_WIREFRAME, Vector2(), p_render_data->scene_data->lod_distance_multiplier, p_render_data->scene_data->screen_mesh_lod_threshold, p_render_data->scene_data->view_count, 0, base_specialization);
					// Fallback geometry skipped the G-buffer depth pass and must write its own depth.
					render_list_params.opaque_fallback = true;
					_render_list_with_draw_list(&render_list_params, fallback_framebuffer, RD::DRAW_DEFAULT_ALL, Vector<Color>(), 0.0f, 0u, p_render_data->render_region);

					RD::get_singleton()->draw_command_end_label();
				}
			} break;
			case FRPPipelineSpec::OP_MOTION_VECTORS: { // Motion vectors.
				{
					if (using_motion_pass || motion_vectors_required) {
						if (scale_type == SCALE_MFX) {
							// MetalFX consumes its own velocity layout, so the buffer has to
							// be converted after the G-buffer pass wrote it.
							motion_vectors_store->process(rb,
									p_render_data->scene_data->cam_projection, p_render_data->scene_data->cam_transform,
									p_render_data->scene_data->prev_cam_projection, p_render_data->scene_data->prev_cam_transform);
						}
						// The velocity attachment itself is cleared by the G-buffer pass:
						// its framebuffer carries the motion vector attachment and the
						// clear colour marks "no motion".
					}
				}
			} break;
			case FRPPipelineSpec::OP_OPAQUE_RESOLVE: { // Opaque resolve.
				{
					if (ce_post_opaque_resolved_color) {
						for (uint32_t v = 0; v < rb->get_view_count(); v++) {
							RD::get_singleton()->texture_resolve_multisample(rb->get_color_msaa(v), rb->get_internal_texture(v));
						}
					}

					if (ce_post_opaque_resolved_depth) {
						for (uint32_t v = 0; v < rb->get_view_count(); v++) {
							resolve_effects->resolve_depth(rb->get_depth_msaa(v), rb->get_depth_texture(v), rb->get_internal_size(), texture_multisamples[msaa]);
						}
					}

					RENDER_TIMESTAMP("Process Post Opaque Compositor Effects");
					stage_effects(RSE::COMPOSITOR_EFFECT_CALLBACK_TYPE_POST_OPAQUE);
				}
			} break;
			case FRPPipelineSpec::OP_SKY: { // Sky.
				if (draw_sky || draw_sky_fog_only) {
					RENDER_TIMESTAMP("Render Sky");

					RD::get_singleton()->draw_command_begin_label("Draw Sky");
					RD::DrawListID draw_list = RD::get_singleton()->draw_list_begin(color_only_framebuffer, RD::DRAW_DEFAULT_ALL, Vector<Color>(), 1.0f, 0u, p_render_data->render_region);

					sky.draw_sky(draw_list, rb, p_render_data->environment, color_only_framebuffer, time, sky_luminance_multiplier, sky_brightness_multiplier);

					RD::get_singleton()->draw_list_end();
					RD::get_singleton()->draw_command_end_label();
				}
			} break;
			case FRPPipelineSpec::OP_SKY_RESOLVE: { // Sky resolve.
				if (use_msaa) {
					RENDER_TIMESTAMP("Resolve MSAA");

					if (scene_state.used_screen_texture || using_separate_specular || ce_pre_transparent_resolved_color) {
						for (uint32_t v = 0; v < rb->get_view_count(); v++) {
							RD::get_singleton()->texture_resolve_multisample(rb->get_color_msaa(v), rb->get_internal_texture(v));
						}
						if (using_separate_specular) {
							for (uint32_t v = 0; v < rb->get_view_count(); v++) {
								RD::get_singleton()->texture_resolve_multisample(rb_data->get_specular_msaa(v), rb_data->get_specular(v));
							}
						}
					}

					if (scene_state.used_depth_texture || scene_state.used_normal_texture || using_separate_specular || ce_needs_normal_roughness || ce_pre_transparent_resolved_depth) {
						for (uint32_t v = 0; v < rb->get_view_count(); v++) {
							resolve_effects->resolve_depth(rb->get_depth_msaa(v), rb->get_depth_texture(v), rb->get_internal_size(), texture_multisamples[msaa]);
						}
					}
				}

				{
					RENDER_TIMESTAMP("Process Post Sky Compositor Effects");
					// Don't need to check for depth or color resolve here, we've already triggered it.
					stage_effects(RSE::COMPOSITOR_EFFECT_CALLBACK_TYPE_POST_SKY);
				}
			} break;
			case FRPPipelineSpec::OP_SUBSURFACE_AND_SPECULAR: { // Subsurface and specular.
				if (using_separate_specular) {
					if (using_sss) {
						RENDER_TIMESTAMP("Sub-Surface Scattering");
						RD::get_singleton()->draw_command_begin_label("Process Sub-Surface Scattering");
						_process_sss(rb, p_render_data->scene_data->cam_projection);
						RD::get_singleton()->draw_command_end_label();
					}

					{
						//just mix specular back
						RENDER_TIMESTAMP("Merge Specular");
						copy_effects->merge_specular(color_only_framebuffer, rb_data->get_specular(), !use_msaa ? RID() : rb->get_internal_texture(), RID(), p_render_data->scene_data->view_count);
					}
				}

				if (using_separate_specular && is_environment(p_render_data->environment) && (environment_get_background(p_render_data->environment) == RSE::ENV_BG_CANVAS)) {
					// Canvas background mode does not clear the color buffer, but copies over it. If screen-space specular effects are enabled and the background is blank,
					// this results in ghosting due to the separate specular buffer copy. Need to explicitly clear the specular buffer once we're done with it to fix it.
					RENDER_TIMESTAMP("Clear Separate Specular (Canvas Background Mode)");
					Vector<Color> blank_clear_color;
					blank_clear_color.push_back(Color(0.0, 0.0, 0.0));
					RD::get_singleton()->draw_list_begin(rb_data->get_specular_only_fb(), RD::DRAW_CLEAR_ALL, blank_clear_color);
					RD::get_singleton()->draw_list_end();
				}
			} break;
			case FRPPipelineSpec::OP_SCREEN_AND_DEPTH_COPY: { // Screen and depth copies.
				if (rb_data.is_valid() && using_upscaling) {
					// Make sure the upscaled texture is initialized, but not necessarily filled, before running screen copies
					// so it properly detect if a dedicated copy texture should be used.
					rb->ensure_upscaled();
				}

				if (scene_state.used_screen_texture || global_surface_data.screen_texture_used) {
					RENDER_TIMESTAMP("Copy Screen Texture");

					_render_buffers_ensure_screen_texture(p_render_data);

					if (scene_state.used_screen_texture) {
						// Copy screen texture to backbuffer so we can read from it
						_render_buffers_copy_screen_texture(p_render_data);
					}
				}

				if (scene_state.used_depth_texture || global_surface_data.depth_texture_used) {
					RENDER_TIMESTAMP("Copy Depth Texture");

					_render_buffers_ensure_depth_texture(p_render_data);

					if (scene_state.used_depth_texture) {
						// Copy depth texture to backbuffer so we can read from it
						_render_buffers_copy_depth_texture(p_render_data);
					}
				}

				{
					if (using_separate_specular) {
						// Our specular will be combined back in (and effects, subsurface scattering and/or ssr applied),
						// so if we've requested this, we need another copy.
						// Fairly unlikely scenario though.

						if (ce_pre_transparent_resolved_color) {
							for (uint32_t v = 0; v < rb->get_view_count(); v++) {
								RD::get_singleton()->texture_resolve_multisample(rb->get_color_msaa(v), rb->get_internal_texture(v));
							}
						}

						if (ce_pre_transparent_resolved_depth) {
							for (uint32_t v = 0; v < rb->get_view_count(); v++) {
								resolve_effects->resolve_depth(rb->get_depth_msaa(v), rb->get_depth_texture(v), rb->get_internal_size(), texture_multisamples[msaa]);
							}
						}
					}

					RENDER_TIMESTAMP("Process Pre Transparent Compositor Effects");
					stage_effects(RSE::COMPOSITOR_EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT);
				}
			} break;
			case FRPPipelineSpec::OP_TRANSPARENT: { // Transparent.
				if (!render_list[RENDER_LIST_ALPHA].elements.is_empty()) {
					RENDER_TIMESTAMP("Render 3D Transparent Pass");

					RD::get_singleton()->draw_command_begin_label("Render 3D Transparent Pass");

					uint32_t transparent_pass_uniform_buffer_index = _setup_environment(p_render_data, is_reflection_probe, screen_size, screen_size, p_default_bg_color, false);

					rp_uniform_set = _setup_render_pass_uniform_set(RENDER_LIST_ALPHA, p_render_data, radiance_texture, samplers, transparent_pass_uniform_buffer_index, true);

					{
						uint32_t transparent_color_pass_flags = (color_pass_flags | uint32_t(COLOR_PASS_FLAG_TRANSPARENT)) & ~uint32_t(COLOR_PASS_FLAG_SEPARATE_SPECULAR);
						// Motion vectors should not be overwritten by transparent objects.
						transparent_color_pass_flags &= ~uint32_t(COLOR_PASS_FLAG_MOTION_VECTORS);

						RID alpha_framebuffer = rb_data.is_valid() ? rb_data->get_color_pass_fb(transparent_color_pass_flags) : color_only_framebuffer;
						RenderListParameters render_list_params(render_list[RENDER_LIST_ALPHA].elements.ptr(), render_list[RENDER_LIST_ALPHA].element_info.ptr(), render_list[RENDER_LIST_ALPHA].elements.size(), reverse_cull, PASS_MODE_COLOR, transparent_color_pass_flags, rb_data.is_null(), p_render_data->directional_light_soft_shadows, rp_uniform_set, get_debug_draw_mode() == RSE::VIEWPORT_DEBUG_DRAW_WIREFRAME, Vector2(), p_render_data->scene_data->lod_distance_multiplier, p_render_data->scene_data->screen_mesh_lod_threshold, p_render_data->scene_data->view_count, 0, base_specialization);
						_render_list_with_draw_list(&render_list_params, alpha_framebuffer, RD::DRAW_DEFAULT_ALL, Vector<Color>(), 0.0f, 0u, p_render_data->render_region);
					}

					RD::get_singleton()->draw_command_end_label();
				}
			} break;
			case FRPPipelineSpec::OP_FINAL_RESOLVE: { // Final resolve.
				resolve_frame_buffers();
			} break;
			case FRPPipelineSpec::OP_HISTORY_COPY: { // Post-transparent compositor effects.
				{
					RENDER_TIMESTAMP("Process Post Transparent Compositor Effects");
					stage_effects(RSE::COMPOSITOR_EFFECT_CALLBACK_TYPE_POST_TRANSPARENT);
				}
			} break;
			case FRPPipelineSpec::OP_TEMPORAL_AA: { // Temporal AA and upscale.
				// TAA and the temporal upscalers read resolved colour, depth and
				// velocity, and this entry can run before the tone mapping entry.
				resolve_frame_buffers();

				if (rb_data.is_valid() && (using_upscaling || using_taa)) {
					if (scale_type == SCALE_FSR2) {
						rb_data->ensure_fsr2(fsr2_effect);

						RID exposure;
						if (RSG::camera_attributes->camera_attributes_uses_auto_exposure(p_render_data->camera_attributes)) {
							exposure = luminance->get_current_luminance_buffer(rb);
						}

						RD::get_singleton()->draw_command_begin_label("FSR2");
						RENDER_TIMESTAMP("FSR2");

						for (uint32_t v = 0; v < rb->get_view_count(); v++) {
							real_t fov = p_render_data->scene_data->cam_projection.get_fov();
							real_t aspect = p_render_data->scene_data->cam_projection.get_aspect();
							real_t fovy = p_render_data->scene_data->cam_projection.get_fovy(fov, 1.0 / aspect);
							Vector2 jitter = p_render_data->scene_data->taa_jitter * Vector2(rb->get_internal_size()) * 0.5f;
							RendererRD::FSR2Effect::Parameters params;
							params.context = rb_data->get_fsr2_context();
							params.internal_size = rb->get_internal_size();
							params.sharpness = CLAMP(1.0f - (rb->get_fsr_sharpness() / 2.0f), 0.0f, 1.0f);
							params.color = rb->get_internal_texture(v);
							params.depth = rb->get_depth_texture(v);
							params.velocity = rb->get_velocity_buffer(false, v);
							params.reactive = rb->get_internal_texture_reactive(v);
							params.exposure = exposure;
							params.output = rb->get_upscaled_texture(v);
							params.z_near = p_render_data->scene_data->z_near;
							params.z_far = p_render_data->scene_data->z_far;
							params.fovy = fovy;
							params.jitter = jitter;
							params.delta_time = float(time_step);
							params.reset_accumulation = false; // FIXME: The engine does not provide a way to reset the accumulation.

							Projection correction;
							correction.set_depth_correction(true, true, false);

							const Projection &prev_proj = p_render_data->scene_data->prev_cam_projection;
							const Projection &cur_proj = p_render_data->scene_data->cam_projection;
							const Transform3D &prev_transform = p_render_data->scene_data->prev_cam_transform;
							const Transform3D &cur_transform = p_render_data->scene_data->cam_transform;
							params.reprojection = (correction * prev_proj) * prev_transform.affine_inverse() * cur_transform * (correction * cur_proj).inverse();

							fsr2_effect->upscale(params);
						}

						RD::get_singleton()->draw_command_end_label();
					} else if (scale_type == SCALE_MFX) {
#ifdef METAL_MFXTEMPORAL_ENABLED
						bool reset = rb_data->ensure_mfx_temporal(mfx_temporal_effect);

						RID exposure;
						if (RSG::camera_attributes->camera_attributes_uses_auto_exposure(p_render_data->camera_attributes)) {
							exposure = luminance->get_current_luminance_buffer(rb);
						}

						RD::get_singleton()->draw_command_begin_label("MetalFX Temporal");
						// Scale to +/-0.5.
						Vector2 jitter = p_render_data->scene_data->taa_jitter * 0.5f;
						jitter *= Vector2(1.0, -1.0); // Flip y-axis as bottom left is origin.

						for (uint32_t v = 0; v < rb->get_view_count(); v++) {
							RendererRD::MFXTemporalEffect::Params params;
							params.src = rb->get_internal_texture(v);
							params.depth = rb->get_depth_texture(v);
							params.motion = rb->get_velocity_buffer(false, v);
							params.exposure = exposure;
							params.dst = rb->get_upscaled_texture(v);
							params.jitter_offset = jitter;
							params.reset = reset;

							mfx_temporal_effect->process(rb_data->get_mfx_temporal_context(), params);
						}

						RD::get_singleton()->draw_command_end_label();
#endif
					} else if (using_taa) {
						// The temporal resolve reprojects every pixel, including the sky
						// and the clear colour behind a silhouette, which the velocity
						// attachment only has the engine's "no data" marker for. Filling
						// those in first is what makes the background accumulate instead
						// of being replaced every frame.
						_fill_missing_velocity(rb, p_render_data);

						RD::get_singleton()->draw_command_begin_label("TAA");
						RENDER_TIMESTAMP("TAA");
						taa->process(rb, rb->get_base_data_format(), p_render_data->scene_data->z_near, p_render_data->scene_data->z_far);
						RD::get_singleton()->draw_command_end_label();
					}
				}
			} break;
			case FRPPipelineSpec::OP_POST_PROCESS: { // Post-process stages: glow, DoF, auto exposure, AA prep.
				if (rb_data.is_valid()) {
					_debug_draw_cluster(rb);

					RENDER_TIMESTAMP("Post Process");

					_render_buffers_post_process(p_render_data);
				}
			} break;
			case FRPPipelineSpec::OP_TONEMAP: { // Tone mapping, post AA and scaling, presented by the engine.
				if (rb_data.is_valid()) {
					RENDER_TIMESTAMP("Tonemap");

					_render_buffers_tonemap(p_render_data);
				}
			} break;
			case FRPPipelineSpec::OP_TONEMAP_DEFERRED: { // Tone mapping into the engine's intermediate texture.
				if (rb_data.is_valid()) {
					RENDER_TIMESTAMP("Tonemap (deferred present)");

					// The engine's own present steps are skipped: the caller runs its
					// post-tonemap effects on the toned image and presents it itself
					// with present().
					_render_buffers_tonemap(p_render_data, true);
				}
			} break;
		}
	};
	// A pass is what the pipeline resource orders, enables and disables. It runs the
	// operations its spec entry declares, in that order.
	auto run_builtin_pass = [&](int p_pass, const String &p_name) {
		RD::get_singleton()->draw_command_begin_label(p_name.utf8().span());
		RD::get_singleton()->driver_callback_add(_frp_pass_debug_marker, nullptr, VectorView<RD::CallbackResource>());
		const FRPPipelineSpec::NativePass &definition = FRPPipelineSpec::native_pass(p_pass);
		for (int i = 0; i < definition.operation_count; i++) {
			run_builtin_operation(definition.operations[i]);
		}
		RD::get_singleton()->draw_command_end_label();
	};
	// The Core surface a scripted pass runs on. It forwards every primitive to the
	// same operations the built-in passes call, so a plugin pass and the engine's own
	// pass execute identical code.
	Ref<FRPPassContext> pass_context;
	pass_context.instantiate();
	pass_context->setup(
			const_cast<RenderDataRD *>(p_render_data),
			[&](int p_operation) { run_builtin_operation(p_operation); },
			[&](int p_stage) { stage_effects(RSE::CompositorEffectCallbackType(p_stage)); },
			pipeline_parameters,
			[&](const StringName &p_texture) { _present_frame(p_render_data, p_texture); });

	if (explicit_pipeline) {
		for (int slot = 0; slot < pipeline.size(); slot++) {
			const int token = pipeline[slot];
			const String pass_name = pipeline_names.size() == pipeline.size() && !pipeline_names[slot].is_empty() ? pipeline_names[slot] : (token >= 0 ? String(FRPPipelineSpec::native_pass_name(token)) : "Custom Pass " + itos(-int64_t(token) - 1));
			// A user-authored pass boundary is an execution dependency, even if
			// adjacent passes touch unrelated resources. Keep graph optimizations
			// inside each pass without moving work across the configured order.
			RD::get_singleton()->draw_command_insert_ordering_barrier();
			if (token >= 0) {
				run_builtin_pass(token, pass_name);
				continue;
			}
			const int64_t index = -int64_t(token) - 1;
			if (index >= pipeline_effects.size()) {
				continue;
			}
			RID effect = pipeline_effects[index];
			if (!pipeline_storage->is_compositor_effect(effect) || !pipeline_storage->compositor_effect_get_enabled(effect)) {
				continue;
			}
			RD::get_singleton()->draw_command_begin_label(pass_name.utf8().span());
			RD::get_singleton()->driver_callback_add(_frp_pass_debug_marker, nullptr, VectorView<RD::CallbackResource>());
			// Custom passes can move across built-in operations. Resolve requested
			// attachments at their actual position, not their old stage anchor.
			if (use_msaa) {
				for (uint32_t v = 0; v < rb->get_view_count(); v++) {
					if (pipeline_storage->compositor_effect_get_flag(effect, RSE::COMPOSITOR_EFFECT_FLAG_ACCESS_RESOLVED_COLOR)) {
						RD::get_singleton()->texture_resolve_multisample(rb->get_color_msaa(v), rb->get_internal_texture(v));
					}
					if (pipeline_storage->compositor_effect_get_flag(effect, RSE::COMPOSITOR_EFFECT_FLAG_ACCESS_RESOLVED_DEPTH)) {
						resolve_effects->resolve_depth(rb->get_depth_msaa(v), rb->get_depth_texture(v), rb->get_internal_size(), texture_multisamples[msaa]);
					}
				}
			}
			Callable callback = pipeline_storage->compositor_effect_get_callback(effect);
			Object *callback_object = callback.get_object();
			if (callback_object != nullptr && callback_object->has_method("_frp_execute")) {
				// A pass that knows the FRP Core drives the frame itself. Everything
				// else keeps using the CompositorEffect callback contract.
				Array arguments;
				arguments.push_back(pass_context);
				callback_object->callv("_frp_execute", arguments);
			} else {
				Array arguments;
				arguments.push_back(pipeline_storage->compositor_effect_get_callback_type(effect));
				arguments.push_back(p_render_data);
				callback.callv(arguments);
			}
			if (use_msaa && pipeline_storage->compositor_effect_get_flag(effect, RSE::COMPOSITOR_EFFECT_FLAG_ACCESS_RESOLVED_COLOR)) {
				// Keep later geometry and resolves from overwriting custom color
				// writes with an older multisample attachment.
				copy_effects->copy_to_fb_rect(rb->get_internal_texture(), color_only_framebuffer, Rect2i(), false, false, false, false, RID(), rb->get_view_count() > 1);
			}
			RD::get_singleton()->draw_command_end_label();
		}
		RD::get_singleton()->draw_command_insert_ordering_barrier();
	} else {
		// Default order used when no explicit schedule is configured. The order,
		// names and dependency constraints all come from FRPPipelineSpec, so the
		// renderer, the validator and FengRenderer cannot disagree.
		const bool pinned_pass_order = _capture_tool_attached();
		if (pinned_pass_order) {
			RD::get_singleton()->draw_command_insert_ordering_barrier();
		}
		for (int i = 0; i < FRPPipelineSpec::DEFAULT_PASS_ORDER_COUNT; i++) {
			const int pass = FRPPipelineSpec::DEFAULT_PASS_ORDER[i];
			if (pinned_pass_order) {
				RD::get_singleton()->draw_command_insert_ordering_barrier();
			}
			run_builtin_pass(pass, FRPPipelineSpec::native_pass_name(pass));
		}
	}

	if (rb_data.is_valid()) {
		_render_buffers_debug_draw(p_render_data);

	}
}

void RenderFRPClustered::_render_buffers_debug_draw(const RenderDataRD *p_render_data) {
	RendererRD::TextureStorage *texture_storage = RendererRD::TextureStorage::get_singleton();

	Ref<RenderSceneBuffersRD> rb = p_render_data->render_buffers;
	ERR_FAIL_COND(rb.is_null());

	Ref<RenderBufferDataFRPClustered> rb_data = rb->get_custom_data(RB_SCOPE_FRP_CLUSTERED);
	ERR_FAIL_COND(rb_data.is_null());

	RendererSceneRenderRD::_render_buffers_debug_draw(p_render_data);

	RID render_target = rb->get_render_target();

	if (get_debug_draw_mode() == RSE::VIEWPORT_DEBUG_DRAW_GI_BUFFER && rb->has_texture(RB_SCOPE_GI, RB_TEX_AMBIENT)) {
		Size2i rtsize = texture_storage->render_target_get_size(render_target);
		RID ambient_texture = rb->get_texture(RB_SCOPE_GI, RB_TEX_AMBIENT);
		RID reflection_texture = rb->get_texture(RB_SCOPE_GI, RB_TEX_REFLECTION);
		copy_effects->copy_to_fb_rect(ambient_texture, texture_storage->render_target_get_rd_framebuffer(render_target), Rect2(Vector2(), rtsize), false, false, false, true, reflection_texture, rb->get_view_count() > 1);
	}
}

void RenderFRPClustered::_render_shadow_pass(RID p_light, RID p_shadow_atlas, int p_pass, const PagedArray<RenderGeometryInstance *> &p_instances, float p_lod_distance_multiplier, float p_screen_mesh_lod_threshold, bool p_open_pass, bool p_close_pass, bool p_clear_region, RenderingServerTypes::RenderInfo *p_render_info, const Size2i &p_viewport_size, const Transform3D &p_main_cam_transform) {
	RendererRD::LightStorage *light_storage = RendererRD::LightStorage::get_singleton();

	ERR_FAIL_COND(!light_storage->owns_light_instance(p_light));

	RID base = light_storage->light_instance_get_base_light(p_light);

	Rect2i atlas_rect;
	uint32_t atlas_size = 1;
	RID atlas_fb;

	bool reverse_cull_face = light_storage->light_get_reverse_cull_face_mode(base);
	bool using_dual_paraboloid = false;
	bool using_dual_paraboloid_flip = false;
	Vector2i dual_paraboloid_offset;
	RID render_fb;
	RID render_texture;
	float zfar;

	bool use_pancake = false;
	bool render_cubemap = false;
	bool finalize_cubemap = false;

	bool flip_y = false;

	Projection light_projection;
	Transform3D light_transform;

	if (light_storage->light_get_type(base) == RSE::LIGHT_DIRECTIONAL) {
		//set pssm stuff
		uint64_t last_scene_shadow_pass = light_storage->light_instance_get_shadow_pass(p_light);
		if (last_scene_shadow_pass != get_scene_pass()) {
			light_storage->light_instance_set_directional_rect(p_light, light_storage->get_directional_shadow_rect());
			light_storage->directional_shadow_increase_current_light();
			light_storage->light_instance_set_shadow_pass(p_light, get_scene_pass());
		}

		use_pancake = light_storage->light_get_param(base, RSE::LIGHT_PARAM_SHADOW_PANCAKE_SIZE) > 0;
		light_projection = light_storage->light_instance_get_shadow_camera(p_light, p_pass);
		light_transform = light_storage->light_instance_get_shadow_transform(p_light, p_pass);

		atlas_rect = light_storage->light_instance_get_directional_rect(p_light);

		if (light_storage->light_directional_get_shadow_mode(base) == RSE::LIGHT_DIRECTIONAL_SHADOW_PARALLEL_4_SPLITS) {
			atlas_rect.size.width /= 2;
			atlas_rect.size.height /= 2;

			if (p_pass == 1) {
				atlas_rect.position.x += atlas_rect.size.width;
			} else if (p_pass == 2) {
				atlas_rect.position.y += atlas_rect.size.height;
			} else if (p_pass == 3) {
				atlas_rect.position += atlas_rect.size;
			}
		} else if (light_storage->light_directional_get_shadow_mode(base) == RSE::LIGHT_DIRECTIONAL_SHADOW_PARALLEL_2_SPLITS) {
			atlas_rect.size.height /= 2;

			if (p_pass == 0) {
			} else {
				atlas_rect.position.y += atlas_rect.size.height;
			}
		}

		float directional_shadow_size = light_storage->directional_shadow_get_size();
		Rect2 atlas_rect_norm = atlas_rect;
		atlas_rect_norm.position /= directional_shadow_size;
		atlas_rect_norm.size /= directional_shadow_size;
		light_storage->light_instance_set_directional_shadow_atlas_rect(p_light, p_pass, atlas_rect_norm);

		zfar = RSG::light_storage->light_get_param(base, RSE::LIGHT_PARAM_RANGE);

		render_fb = light_storage->direction_shadow_get_fb();
		render_texture = RID();
		flip_y = true;

	} else {
		//set from shadow atlas

		ERR_FAIL_COND(!light_storage->owns_shadow_atlas(p_shadow_atlas));
		ERR_FAIL_COND(!light_storage->shadow_atlas_owns_light_instance(p_shadow_atlas, p_light));

		RSG::light_storage->shadow_atlas_update(p_shadow_atlas);

		uint32_t key = light_storage->shadow_atlas_get_light_instance_key(p_shadow_atlas, p_light);

		uint32_t quadrant = (key >> RendererRD::LightStorage::QUADRANT_SHIFT) & 0x3;
		uint32_t shadow = key & RendererRD::LightStorage::SHADOW_INDEX_MASK;
		uint32_t subdivision = light_storage->shadow_atlas_get_quadrant_subdivision(p_shadow_atlas, quadrant);

		ERR_FAIL_INDEX((int)shadow, light_storage->shadow_atlas_get_quadrant_shadow_size(p_shadow_atlas, quadrant));

		uint32_t shadow_atlas_size = light_storage->shadow_atlas_get_size(p_shadow_atlas);
		uint32_t quadrant_size = shadow_atlas_size >> 1;

		atlas_rect.position.x = (quadrant & 1) * quadrant_size;
		atlas_rect.position.y = (quadrant >> 1) * quadrant_size;

		uint32_t shadow_size = (quadrant_size / subdivision);
		atlas_rect.position.x += (shadow % subdivision) * shadow_size;
		atlas_rect.position.y += (shadow / subdivision) * shadow_size;

		atlas_rect.size.width = shadow_size;
		atlas_rect.size.height = shadow_size;

		zfar = light_storage->light_get_param(base, RSE::LIGHT_PARAM_RANGE);

		if (light_storage->light_get_type(base) == RSE::LIGHT_OMNI) {
			bool wrap = (shadow + 1) % subdivision == 0;
			dual_paraboloid_offset = wrap ? Vector2i(1 - subdivision, 1) : Vector2i(1, 0);

			if (light_storage->light_omni_get_shadow_mode(base) == RSE::LIGHT_OMNI_SHADOW_CUBE) {
				render_texture = light_storage->get_cubemap(shadow_size / 2);
				render_fb = light_storage->get_cubemap_fb(shadow_size / 2, p_pass);

				light_projection = light_storage->light_instance_get_shadow_camera(p_light, p_pass);
				light_transform = light_storage->light_instance_get_shadow_transform(p_light, p_pass);
				render_cubemap = true;
				finalize_cubemap = p_pass == 5;
				atlas_fb = light_storage->shadow_atlas_get_fb(p_shadow_atlas);

				atlas_size = shadow_atlas_size;

				if (p_pass == 0) {
					_render_shadow_begin();
				}

			} else {
				atlas_rect.position.x += 1;
				atlas_rect.position.y += 1;
				atlas_rect.size.x -= 2;
				atlas_rect.size.y -= 2;

				atlas_rect.position += p_pass * atlas_rect.size * dual_paraboloid_offset;

				light_projection = light_storage->light_instance_get_shadow_camera(p_light, 0);
				light_transform = light_storage->light_instance_get_shadow_transform(p_light, 0);

				using_dual_paraboloid = true;
				using_dual_paraboloid_flip = p_pass == 1;
				render_fb = light_storage->shadow_atlas_get_fb(p_shadow_atlas);
				flip_y = true;
			}

		} else if (light_storage->light_get_type(base) == RSE::LIGHT_SPOT) {
			light_projection = light_storage->light_instance_get_shadow_camera(p_light, 0);
			light_transform = light_storage->light_instance_get_shadow_transform(p_light, 0);

			render_fb = light_storage->shadow_atlas_get_fb(p_shadow_atlas);

			flip_y = true;
		} else if (light_storage->light_get_type(base) == RSE::LIGHT_AREA) {
			Vector2 area_size = light_storage->light_area_get_size(base);

			zfar = light_storage->light_get_param(base, RSE::LIGHT_PARAM_RANGE) + area_size.length() / 2.0;

			light_transform = light_storage->light_instance_get_shadow_transform(p_light, 0);

			light_projection = light_storage->light_instance_get_shadow_camera(p_light, 0);

			render_fb = light_storage->shadow_atlas_get_fb(p_shadow_atlas);

			flip_y = true;

			using_dual_paraboloid = true;
		}
	}

	if (render_cubemap) {
		//rendering to cubemap
		_render_shadow_append(render_fb, p_instances, light_projection, light_transform, zfar, 0, 0, reverse_cull_face, false, false, use_pancake, p_lod_distance_multiplier, p_screen_mesh_lod_threshold, Rect2(), false, true, true, true, p_render_info, p_viewport_size, p_main_cam_transform);
		if (finalize_cubemap) {
			_render_shadow_process();
			_render_shadow_end();
			//reblit
			Rect2 atlas_rect_norm = atlas_rect;
			atlas_rect_norm.position /= float(atlas_size);
			atlas_rect_norm.size /= float(atlas_size);
			copy_effects->copy_cubemap_to_dp(render_texture, atlas_fb, atlas_rect_norm, atlas_rect.size, light_projection.get_z_near(), zfar, false);
			atlas_rect_norm.position += Vector2(dual_paraboloid_offset) * atlas_rect_norm.size;
			copy_effects->copy_cubemap_to_dp(render_texture, atlas_fb, atlas_rect_norm, atlas_rect.size, light_projection.get_z_near(), zfar, true);

			//restore transform so it can be properly used
			light_storage->light_instance_set_shadow_transform(p_light, Projection(), light_storage->light_instance_get_base_transform(p_light), zfar, 0, 0, 0);
		}

	} else {
		//render shadow
		_render_shadow_append(render_fb, p_instances, light_projection, light_transform, zfar, 0, 0, reverse_cull_face, using_dual_paraboloid, using_dual_paraboloid_flip, use_pancake, p_lod_distance_multiplier, p_screen_mesh_lod_threshold, atlas_rect, flip_y, p_clear_region, p_open_pass, p_close_pass, p_render_info, p_viewport_size, p_main_cam_transform);
	}
}

void RenderFRPClustered::_render_shadow_begin() {
	scene_state.shadow_passes.clear();
	RD::get_singleton()->draw_command_begin_label("Shadow Setup");
	_update_render_base_uniform_set();

	render_list[RENDER_LIST_SECONDARY].clear();
	// No need to reset scene_state.curr_gpu_ptr or scene_state.instance_buffer[RENDER_LIST_SECONDARY]
	// because _fill_instance_data will do that if it detects p_offset == 0u.
}

void RenderFRPClustered::_render_shadow_append(RID p_framebuffer, const PagedArray<RenderGeometryInstance *> &p_instances, const Projection &p_projection, const Transform3D &p_transform, float p_zfar, float p_bias, float p_normal_bias, bool p_reverse_cull_face, bool p_use_dp, bool p_use_dp_flip, bool p_use_pancake, float p_lod_distance_multiplier, float p_screen_mesh_lod_threshold, const Rect2i &p_rect, bool p_flip_y, bool p_clear_region, bool p_begin, bool p_end, RenderingServerTypes::RenderInfo *p_render_info, const Size2i &p_viewport_size, const Transform3D &p_main_cam_transform) {
	SceneState::ShadowPass shadow_pass;

	RenderSceneDataRD scene_data;
	scene_data.flip_y = !p_flip_y; // Q: Why is this inverted? Do we assume flip in shadow logic?
	scene_data.cam_projection = p_projection;
	scene_data.cam_transform = p_transform;
	scene_data.view_projection[0] = p_projection;
	scene_data.z_far = p_zfar;
	scene_data.z_near = 0.0;
	scene_data.lod_distance_multiplier = p_lod_distance_multiplier;
	scene_data.dual_paraboloid_side = p_use_dp_flip ? -1 : 1;
	scene_data.opaque_prepass_threshold = 0.1f;
	scene_data.time = time;
	scene_data.time_step = time_step;
	scene_data.main_cam_transform = p_main_cam_transform;
	scene_data.shadow_pass = true;

	RenderDataRD render_data;
	render_data.scene_data = &scene_data;
	render_data.cluster_size = 1;
	render_data.cluster_max_elements = 32;
	render_data.instances = &p_instances;
	render_data.render_info = p_render_info;

	Size2i screen_size = RD::get_singleton()->framebuffer_get_size(p_framebuffer);
	Size2i viewport_size = p_rect.size;
	if (viewport_size == Size2()) {
		viewport_size = screen_size;
	}
	uint32_t uniform_buffer_index = _setup_environment(&render_data, true, screen_size, viewport_size, Color(), false, false, p_use_pancake);

	if (get_debug_draw_mode() == RSE::VIEWPORT_DEBUG_DRAW_DISABLE_LOD) {
		scene_data.screen_mesh_lod_threshold = 0.0;
	} else {
		scene_data.screen_mesh_lod_threshold = p_screen_mesh_lod_threshold;
	}

	PassMode pass_mode = p_use_dp ? PASS_MODE_SHADOW_DP : PASS_MODE_SHADOW;

	uint32_t render_list_from = render_list[RENDER_LIST_SECONDARY].elements.size();
	_fill_render_list(RENDER_LIST_SECONDARY, &render_data, pass_mode, false, false, true);
	uint32_t render_list_size = render_list[RENDER_LIST_SECONDARY].elements.size() - render_list_from;
	render_list[RENDER_LIST_SECONDARY].sort_by_key_range(render_list_from, render_list_size);
	_fill_instance_data(RENDER_LIST_SECONDARY, p_render_info ? p_render_info->info[RSE::VIEWPORT_RENDER_INFO_TYPE_SHADOW] : (int *)nullptr, render_list_from, render_list_size, false);

	{
		//regular forward for now
		bool flip_cull = p_use_dp_flip;
		if (p_flip_y) {
			flip_cull = !flip_cull;
		}

		if (p_reverse_cull_face) {
			flip_cull = !flip_cull;
		}

		shadow_pass.element_from = render_list_from;
		shadow_pass.element_count = render_list_size;
		shadow_pass.flip_cull = flip_cull;
		shadow_pass.pass_mode = pass_mode;

		shadow_pass.rp_uniform_set = RID(); //will be filled later when instance buffer is complete
		shadow_pass.screen_mesh_lod_threshold = scene_data.screen_mesh_lod_threshold;
		shadow_pass.lod_distance_multiplier = scene_data.lod_distance_multiplier;

		shadow_pass.framebuffer = p_framebuffer;
		shadow_pass.clear_depth = p_begin || p_clear_region;
		shadow_pass.rect = p_rect;

		shadow_pass.uniform_buffer_index = uniform_buffer_index;

		scene_state.shadow_passes.push_back(shadow_pass);
	}
}

void RenderFRPClustered::_render_shadow_process() {
	RenderingDevice *rd = RenderingDevice::get_singleton();
	if (scene_state.instance_buffer[RENDER_LIST_SECONDARY].get_size(0u) > 0u) {
		rd->buffer_flush(scene_state.instance_buffer[RENDER_LIST_SECONDARY]._get(0u));
	}

	//render shadows one after the other, so this can be done un-barriered and the driver can optimize (as well as allow us to run compute at the same time)

	for (uint32_t i = 0; i < scene_state.shadow_passes.size(); i++) {
		//render passes need to be configured after instance buffer is done, since they need the latest version
		SceneState::ShadowPass &shadow_pass = scene_state.shadow_passes[i];
		shadow_pass.rp_uniform_set = _setup_render_pass_uniform_set(RENDER_LIST_SECONDARY, nullptr, RID(), RendererRD::MaterialStorage::get_singleton()->samplers_rd_get_default(), shadow_pass.uniform_buffer_index, false);
	}

	RD::get_singleton()->draw_command_end_label();
}
void RenderFRPClustered::_render_shadow_end() {
	RD::get_singleton()->draw_command_begin_label("Shadow Render");

	for (SceneState::ShadowPass &shadow_pass : scene_state.shadow_passes) {
		RenderListParameters render_list_parameters(render_list[RENDER_LIST_SECONDARY].elements.ptr() + shadow_pass.element_from, render_list[RENDER_LIST_SECONDARY].element_info.ptr() + shadow_pass.element_from, shadow_pass.element_count, shadow_pass.flip_cull, shadow_pass.pass_mode, 0, true, false, shadow_pass.rp_uniform_set, false, Vector2(), shadow_pass.lod_distance_multiplier, shadow_pass.screen_mesh_lod_threshold, 1, shadow_pass.element_from);
		_render_list_with_draw_list(&render_list_parameters, shadow_pass.framebuffer, shadow_pass.clear_depth ? RD::DRAW_CLEAR_DEPTH : RD::DRAW_DEFAULT_ALL, Vector<Color>(), 0.0f, 0, shadow_pass.rect);
	}

	RD::get_singleton()->draw_command_end_label();
}

void RenderFRPClustered::_render_particle_collider_heightfield(RID p_fb, const Transform3D &p_cam_transform, const Projection &p_cam_projection, const PagedArray<RenderGeometryInstance *> &p_instances) {
	RENDER_TIMESTAMP("Setup GPUParticlesCollisionHeightField3D");

	RD::get_singleton()->draw_command_begin_label("Render Collider Heightfield");

	RenderSceneDataRD scene_data;
	scene_data.flip_y = true;
	scene_data.cam_projection = p_cam_projection;
	scene_data.cam_transform = p_cam_transform;
	scene_data.view_projection[0] = p_cam_projection;
	scene_data.z_near = 0.0;
	scene_data.z_far = p_cam_projection.get_z_far();
	scene_data.dual_paraboloid_side = 0;
	scene_data.opaque_prepass_threshold = 0.0;
	scene_data.time = time;
	scene_data.time_step = time_step;
	scene_data.main_cam_transform = p_cam_transform;
	scene_data.shadow_pass = true; // Not a shadow pass, but should be treated like one.

	RenderDataRD render_data;
	render_data.scene_data = &scene_data;
	render_data.cluster_size = 1;
	render_data.cluster_max_elements = 32;
	render_data.instances = &p_instances;

	_update_render_base_uniform_set();

	Size2i screen_size = RD::get_singleton()->framebuffer_get_size(p_fb);
	uint32_t uniform_buffer_index = _setup_environment(&render_data, true, screen_size, screen_size, Color(), false, false, false);

	PassMode pass_mode = PASS_MODE_SHADOW;

	_fill_render_list(RENDER_LIST_SECONDARY, &render_data, pass_mode);
	render_list[RENDER_LIST_SECONDARY].sort_by_key();
	_fill_instance_data(RENDER_LIST_SECONDARY);

	RID rp_uniform_set = _setup_render_pass_uniform_set(RENDER_LIST_SECONDARY, nullptr, RID(), RendererRD::MaterialStorage::get_singleton()->samplers_rd_get_default(), uniform_buffer_index);

	RENDER_TIMESTAMP("Render Collider Heightfield");

	{
		//regular forward for now
		RenderListParameters render_list_params(render_list[RENDER_LIST_SECONDARY].elements.ptr(), render_list[RENDER_LIST_SECONDARY].element_info.ptr(), render_list[RENDER_LIST_SECONDARY].elements.size(), false, pass_mode, 0, true, false, rp_uniform_set);
		_render_list_with_draw_list(&render_list_params, p_fb, RD::DRAW_CLEAR_ALL);
	}
	RD::get_singleton()->draw_command_end_label();
}

void RenderFRPClustered::_render_material(const Transform3D &p_cam_transform, const Projection &p_cam_projection, bool p_cam_orthogonal, const PagedArray<RenderGeometryInstance *> &p_instances, RID p_framebuffer, const Rect2i &p_region, float p_exposure_normalization) {
	RENDER_TIMESTAMP("Setup Rendering 3D Material");

	RD::get_singleton()->draw_command_begin_label("Render 3D Material");

	RenderSceneDataRD scene_data;
	scene_data.cam_projection = p_cam_projection;
	scene_data.cam_transform = p_cam_transform;
	scene_data.view_projection[0] = p_cam_projection;
	scene_data.dual_paraboloid_side = 0;
	scene_data.material_uv2_mode = false;
	scene_data.opaque_prepass_threshold = 0.0f;
	scene_data.emissive_exposure_normalization = p_exposure_normalization;
	scene_data.time = time;
	scene_data.time_step = time_step;
	scene_data.main_cam_transform = p_cam_transform;

	RenderDataRD render_data;
	render_data.scene_data = &scene_data;
	render_data.cluster_size = 1;
	render_data.cluster_max_elements = 32;
	render_data.instances = &p_instances;

	scene_shader.enable_advanced_shader_group();

	_update_render_base_uniform_set();

	Size2i screen_size = RD::get_singleton()->framebuffer_get_size(p_framebuffer);
	Size2i viewport_size = p_region.size;
	if (viewport_size == Size2()) {
		viewport_size = screen_size;
	}
	uint32_t uniform_buffer_index = _setup_environment(&render_data, true, screen_size, viewport_size, Color());

	PassMode pass_mode = PASS_MODE_DEPTH_MATERIAL;
	_fill_render_list(RENDER_LIST_SECONDARY, &render_data, pass_mode);
	render_list[RENDER_LIST_SECONDARY].sort_by_key();
	_fill_instance_data(RENDER_LIST_SECONDARY);

	RID rp_uniform_set = _setup_render_pass_uniform_set(RENDER_LIST_SECONDARY, nullptr, RID(), RendererRD::MaterialStorage::get_singleton()->samplers_rd_get_default(), uniform_buffer_index);

	RENDER_TIMESTAMP("Render 3D Material");

	{
		RenderListParameters render_list_params(render_list[RENDER_LIST_SECONDARY].elements.ptr(), render_list[RENDER_LIST_SECONDARY].element_info.ptr(), render_list[RENDER_LIST_SECONDARY].elements.size(), true, pass_mode, 0, true, false, rp_uniform_set);
		//regular forward for now
		Vector<Color> clear = {
			Color(0, 0, 0, 0),
			Color(0, 0, 0, 0),
			Color(0, 0, 0, 0),
			Color(0, 0, 0, 0),
			Color(0, 0, 0, 0)
		};

		RD::DrawListID draw_list = RD::get_singleton()->draw_list_begin(p_framebuffer, RD::DRAW_CLEAR_ALL, clear, 0.0f, 0, p_region);
		_render_list(draw_list, RD::get_singleton()->framebuffer_get_format(p_framebuffer), &render_list_params, 0, render_list_params.element_count);
		RD::get_singleton()->draw_list_end();
	}

	RD::get_singleton()->draw_command_end_label();
}

void RenderFRPClustered::_render_uv2(const PagedArray<RenderGeometryInstance *> &p_instances, RID p_framebuffer, const Rect2i &p_region) {
	RENDER_TIMESTAMP("Setup Rendering UV2");

	RD::get_singleton()->draw_command_begin_label("Render UV2");

	RenderSceneDataRD scene_data;
	scene_data.dual_paraboloid_side = 0;
	scene_data.material_uv2_mode = true;
	scene_data.opaque_prepass_threshold = 0.0;
	scene_data.emissive_exposure_normalization = -1.0;

	RenderDataRD render_data;
	render_data.scene_data = &scene_data;
	render_data.cluster_size = 1;
	render_data.cluster_max_elements = 32;
	render_data.instances = &p_instances;

	scene_shader.enable_advanced_shader_group();

	_update_render_base_uniform_set();

	Size2i screen_size = RD::get_singleton()->framebuffer_get_size(p_framebuffer);
	Size2i viewport_size = p_region.size;
	if (viewport_size == Size2()) {
		viewport_size = screen_size;
	}
	uint32_t uniform_buffer_index = _setup_environment(&render_data, true, screen_size, viewport_size, Color());

	PassMode pass_mode = PASS_MODE_DEPTH_MATERIAL;
	_fill_render_list(RENDER_LIST_SECONDARY, &render_data, pass_mode);
	render_list[RENDER_LIST_SECONDARY].sort_by_key();
	_fill_instance_data(RENDER_LIST_SECONDARY);

	RID rp_uniform_set = _setup_render_pass_uniform_set(RENDER_LIST_SECONDARY, nullptr, RID(), RendererRD::MaterialStorage::get_singleton()->samplers_rd_get_default(), uniform_buffer_index);

	RENDER_TIMESTAMP("Render 3D Material");

	{
		RenderListParameters render_list_params(render_list[RENDER_LIST_SECONDARY].elements.ptr(), render_list[RENDER_LIST_SECONDARY].element_info.ptr(), render_list[RENDER_LIST_SECONDARY].elements.size(), true, pass_mode, 0, true, false, rp_uniform_set, true);
		//regular forward for now
		Vector<Color> clear = {
			Color(0, 0, 0, 0),
			Color(0, 0, 0, 0),
			Color(0, 0, 0, 0),
			Color(0, 0, 0, 0),
			Color(0, 0, 0, 0)
		};
		RD::DrawListID draw_list = RD::get_singleton()->draw_list_begin(p_framebuffer, RD::DRAW_CLEAR_ALL, clear, 0.0f, 0, p_region);

		const int uv_offset_count = 9;
		static const Vector2 uv_offsets[uv_offset_count] = {
			Vector2(-1, 1),
			Vector2(1, 1),
			Vector2(1, -1),
			Vector2(-1, -1),
			Vector2(-1, 0),
			Vector2(1, 0),
			Vector2(0, -1),
			Vector2(0, 1),
			Vector2(0, 0),

		};

		for (int i = 0; i < uv_offset_count; i++) {
			Vector2 ofs = uv_offsets[i];
			ofs.x /= p_region.size.width;
			ofs.y /= p_region.size.height;
			render_list_params.uv_offset = ofs;
			_render_list(draw_list, RD::get_singleton()->framebuffer_get_format(p_framebuffer), &render_list_params, 0, render_list_params.element_count); //first wireframe, for pseudo conservative
		}
		render_list_params.uv_offset = Vector2();
		render_list_params.force_wireframe = false;
		_render_list(draw_list, RD::get_singleton()->framebuffer_get_format(p_framebuffer), &render_list_params, 0, render_list_params.element_count); //second regular triangles

		RD::get_singleton()->draw_list_end();
	}

	RD::get_singleton()->draw_command_end_label();
}


void RenderFRPClustered::base_uniforms_changed() {
	if (!render_base_uniform_set.is_null() && RD::get_singleton()->uniform_set_is_valid(render_base_uniform_set)) {
		RD::get_singleton()->free_rid(render_base_uniform_set);
	}
	render_base_uniform_set = RID();
}

void RenderFRPClustered::_update_render_base_uniform_set() {
	RendererRD::LightStorage *light_storage = RendererRD::LightStorage::get_singleton();

	if (render_base_uniform_set.is_null() || !RD::get_singleton()->uniform_set_is_valid(render_base_uniform_set) || (lightmap_texture_array_version != light_storage->lightmap_array_get_version())) {
		if (render_base_uniform_set.is_valid() && RD::get_singleton()->uniform_set_is_valid(render_base_uniform_set)) {
			RD::get_singleton()->free_rid(render_base_uniform_set);
		}

		lightmap_texture_array_version = light_storage->lightmap_array_get_version();

		Vector<RD::Uniform> uniforms;

		{
			RD::Uniform u;
			u.binding = 2;
			u.uniform_type = RD::UNIFORM_TYPE_SAMPLER;
			u.append_id(scene_shader.shadow_sampler);
			uniforms.push_back(u);
		}

		{
			RD::Uniform u;
			u.binding = 3;
			u.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
			u.append_id(RendererRD::LightStorage::get_singleton()->get_omni_light_buffer());
			uniforms.push_back(u);
		}
		{
			RD::Uniform u;
			u.binding = 4;
			u.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
			u.append_id(RendererRD::LightStorage::get_singleton()->get_spot_light_buffer());
			uniforms.push_back(u);
		}
		{
			RD::Uniform u;
			u.binding = 5;
			u.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
			u.append_id(RendererRD::LightStorage::get_singleton()->get_area_light_buffer());
			uniforms.push_back(u);
		}

		{
			RD::Uniform u;
			u.binding = 6;
			u.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
			u.append_id(RendererRD::LightStorage::get_singleton()->get_reflection_probe_buffer());
			uniforms.push_back(u);
		}
		{
			RD::Uniform u;
			u.binding = 7;
			u.uniform_type = RD::UNIFORM_TYPE_UNIFORM_BUFFER;
			u.append_id(RendererRD::LightStorage::get_singleton()->get_directional_light_buffer());
			uniforms.push_back(u);
		}
		{
			RD::Uniform u;
			u.binding = 8;
			u.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
			u.append_id(scene_state.lightmap_buffer);
			uniforms.push_back(u);
		}
		{
			RD::Uniform u;
			u.binding = 9;
			u.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
			u.append_id(scene_state.lightmap_capture_buffer);
			uniforms.push_back(u);
		}
		{
			RD::Uniform u;
			u.binding = 10;
			u.uniform_type = RD::UNIFORM_TYPE_TEXTURE;
			RID decal_atlas = RendererRD::TextureStorage::get_singleton()->decal_atlas_get_texture();
			u.append_id(decal_atlas);
			uniforms.push_back(u);
		}
		{
			RD::Uniform u;
			u.binding = 11;
			u.uniform_type = RD::UNIFORM_TYPE_TEXTURE;
			RID decal_atlas = RendererRD::TextureStorage::get_singleton()->decal_atlas_get_texture_srgb();
			u.append_id(decal_atlas);
			uniforms.push_back(u);
		}
		{
			RD::Uniform u;
			u.binding = 12;
			u.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
			u.append_id(RendererRD::TextureStorage::get_singleton()->get_decal_buffer());
			uniforms.push_back(u);
		}

		{
			RD::Uniform u;
			u.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
			u.binding = 13;
			u.append_id(RendererRD::MaterialStorage::get_singleton()->global_shader_uniforms_get_storage_buffer());
			uniforms.push_back(u);
		}

		// Binding 14 (the SDFGI data buffer) is gone: FRP has no global illumination
		// and its shaders no longer declare that uniform block.

		{
			RD::Uniform u;
			u.binding = 15;
			u.uniform_type = RD::UNIFORM_TYPE_SAMPLER;
			u.append_id(RendererRD::MaterialStorage::get_singleton()->sampler_rd_get_default(RSE::CanvasItemTextureFilter::CANVAS_ITEM_TEXTURE_FILTER_LINEAR_WITH_MIPMAPS, RSE::CanvasItemTextureRepeat::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED));
			uniforms.push_back(u);
		}

		{
			RD::Uniform u;
			u.binding = 16;
			u.uniform_type = RD::UNIFORM_TYPE_TEXTURE;
			u.append_id(best_fit_normal.texture);
			uniforms.push_back(u);
		}

		{
			RD::Uniform u;
			u.binding = 17;
			u.uniform_type = RD::UNIFORM_TYPE_TEXTURE;
			u.append_id(dfg_lut.texture);
			uniforms.push_back(u);
		}

		{ // Lookup-table for Area Lights - Linearly transformed cosines (LTC)
			if (ltc.lut1_texture.is_null() || ltc.lut2_texture.is_null()) {
				Ref<Image> lut1_image;
				int dimensions = LTC_LUT_DIMENSIONS;
				int lut1_bytes = 4 * dimensions * dimensions;
				size_t lut1_size = lut1_bytes * 4; // float

				Vector<uint8_t> lut1_data;
				lut1_data.resize(lut1_size);

				memcpy(lut1_data.ptrw(), LTC_LUT1, lut1_size);
				lut1_image = Image::create_from_data(dimensions, dimensions, false, Image::FORMAT_RGBAF, lut1_data);

				ltc.lut1_texture = RS::get_singleton()->texture_2d_create(lut1_image);

				int lut2_bytes = 4 * dimensions * dimensions;
				size_t lut2_size = lut2_bytes * 4;

				Ref<Image> lut2_image;
				Vector<uint8_t> lut2_data;
				lut2_data.resize(lut2_size);

				memcpy(lut2_data.ptrw(), LTC_LUT2, lut2_size);
				lut2_image = Image::create_from_data(dimensions, dimensions, false, Image::FORMAT_RGBAF, lut2_data);

				ltc.lut2_texture = RS::get_singleton()->texture_2d_create(lut2_image);
			}
		}

		{
			RD::Uniform u;
			u.binding = 18;
			u.uniform_type = RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE;
			u.append_id(RendererRD::MaterialStorage::get_singleton()->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_LINEAR, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED));
			u.append_id(RendererRD::TextureStorage::get_singleton()->texture_get_rd_texture(ltc.lut1_texture));
			uniforms.push_back(u);
		}

		{
			RD::Uniform u;
			u.binding = 19;
			u.uniform_type = RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE;
			u.append_id(RendererRD::MaterialStorage::get_singleton()->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_LINEAR, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED));
			u.append_id(RendererRD::TextureStorage::get_singleton()->texture_get_rd_texture(ltc.lut2_texture));
			uniforms.push_back(u);
		}
		{
			RD::Uniform u;
			u.binding = 20;
			u.uniform_type = RD::UNIFORM_TYPE_TEXTURE;
			RID area_light_atlas = RendererRD::TextureStorage::get_singleton()->area_light_atlas_get_texture();
			u.append_id(area_light_atlas);
			uniforms.push_back(u);
		}

		render_base_uniforms.clear();
		// Cache the lighting subset only when base resources change.
		for (const RD::Uniform &uniform : uniforms) {
			switch (uniform.binding) {
				case 8:
				case 9:
				case 10:
				case 12:
				case 13:
				case 14:
				case 16:
					break; // Geometry-only resources; match MODE_FRP_LIGHTING.
				default:
					render_base_uniforms.push_back(uniform);
			}
		}
		render_base_uniform_set = RD::get_singleton()->uniform_set_create(uniforms, scene_shader.default_shader_rd, SCENE_UNIFORM_SET);
	}
}

RID RenderFRPClustered::_setup_render_pass_uniform_set(RenderListType p_render_list, const RenderDataRD *p_render_data, RID p_radiance_texture, const RendererRD::MaterialStorage::Samplers &p_samplers, uint32_t p_uniform_buffer_index, bool p_use_directional_shadow_atlas, RID p_lighting_shader) {
	RendererRD::TextureStorage *texture_storage = RendererRD::TextureStorage::get_singleton();
	RendererRD::LightStorage *light_storage = RendererRD::LightStorage::get_singleton();

	bool is_multiview = false;

	Ref<RenderSceneBuffersRD> rb; // handy for not having to fully type out p_render_data->render_buffers all the time...
	Ref<RenderBufferDataFRPClustered> rb_data;
	if (p_render_data && p_render_data->render_buffers.is_valid()) {
		rb = p_render_data->render_buffers;
		is_multiview = rb->get_view_count() > 1;
		if (rb->has_custom_data(RB_SCOPE_FRP_CLUSTERED)) {
			// Our forward clustered custom data buffer will only be available when we're rendering our normal view.
			// This will not be available when rendering reflection probes.
			rb_data = rb->get_custom_data(RB_SCOPE_FRP_CLUSTERED);
		}
	}

	//default render buffer and scene state uniform set

	thread_local LocalVector<RD::Uniform> uniforms;
	uniforms.clear();

	{
		RD::Uniform u;
		u.binding = 0;
		u.uniform_type = RD::UNIFORM_TYPE_UNIFORM_BUFFER;
		u.append_id(scene_state.uniform_buffers[p_uniform_buffer_index]);
		uniforms.push_back(u);
	}
	{
		RD::Uniform u;
		u.binding = 1;
		u.uniform_type = RD::UNIFORM_TYPE_UNIFORM_BUFFER;
		u.append_id(scene_state.implementation_uniform_buffers[p_uniform_buffer_index]);
		uniforms.push_back(u);
	}
	if (p_lighting_shader.is_null()) {
		RD::Uniform u;
		u.binding = 2;
		u.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER_DYNAMIC;
		if (p_lighting_shader.is_valid()) {
			// Full-screen lighting does not access per-instance data.
			u.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
			u.append_id(scene_shader.default_vec4_xform_buffer);
		} else if (scene_state.instance_buffer[p_render_list].get_size(0u) == 0u) {
			// Any buffer will do since it's not used, so just create one.
			// We can't use scene_shader.default_vec4_xform_buffer because it's not dynamic.
			scene_state.instance_buffer[p_render_list].set_storage_size(0u, INSTANCE_DATA_BUFFER_MIN_SIZE * sizeof(SceneState::InstanceData));
			scene_state.instance_buffer[p_render_list].prepare_for_upload();
		}
		if (p_lighting_shader.is_null()) {
			RID instance_buffer = scene_state.instance_buffer[p_render_list]._get(0u);
			u.append_id(instance_buffer);
		}
		uniforms.push_back(u);
	}
	{
		RID radiance_texture;
		if (p_radiance_texture.is_valid()) {
			radiance_texture = p_radiance_texture;
		} else {
			radiance_texture = texture_storage->texture_rd_get_default(is_using_radiance_octmap_array() ? RendererRD::TextureStorage::DEFAULT_RD_TEXTURE_2D_ARRAY_BLACK : RendererRD::TextureStorage::DEFAULT_RD_TEXTURE_BLACK);
		}
		RD::Uniform u;
		u.binding = 3;
		u.uniform_type = RD::UNIFORM_TYPE_TEXTURE;
		u.append_id(radiance_texture);
		uniforms.push_back(u);
	}
	{
		RID ref_texture = (p_render_data && p_render_data->reflection_atlas.is_valid()) ? light_storage->reflection_atlas_get_texture(p_render_data->reflection_atlas) : RID();
		RD::Uniform u;
		u.binding = 4;
		u.uniform_type = RD::UNIFORM_TYPE_TEXTURE;
		if (ref_texture.is_valid()) {
			u.append_id(ref_texture);
		} else {
			u.append_id(texture_storage->texture_rd_get_default(RendererRD::TextureStorage::DEFAULT_RD_TEXTURE_2D_ARRAY_BLACK));
		}
		uniforms.push_back(u);
	}
	{
		RD::Uniform u;
		u.binding = 5;
		u.uniform_type = RD::UNIFORM_TYPE_TEXTURE;
		RID texture;
		if (p_render_data && p_render_data->shadow_atlas.is_valid()) {
			texture = RendererRD::LightStorage::get_singleton()->shadow_atlas_get_texture(p_render_data->shadow_atlas);
		}
		if (!texture.is_valid()) {
			texture = texture_storage->texture_rd_get_default(RendererRD::TextureStorage::DEFAULT_RD_TEXTURE_DEPTH);
		}
		u.append_id(texture);
		uniforms.push_back(u);
	}
	{
		RD::Uniform u;
		u.binding = 6;
		u.uniform_type = RD::UNIFORM_TYPE_TEXTURE;
		if (p_use_directional_shadow_atlas && RendererRD::LightStorage::get_singleton()->directional_shadow_get_texture().is_valid()) {
			u.append_id(RendererRD::LightStorage::get_singleton()->directional_shadow_get_texture());
		} else {
			u.append_id(texture_storage->texture_rd_get_default(RendererRD::TextureStorage::DEFAULT_RD_TEXTURE_DEPTH));
		}
		uniforms.push_back(u);
	}
	if (p_lighting_shader.is_null()) {
		Vector<RID> textures;
		textures.resize(scene_state.max_lightmaps * 2);

		RID default_tex = texture_storage->texture_rd_get_default(RendererRD::TextureStorage::DEFAULT_RD_TEXTURE_2D_ARRAY_WHITE);
		for (uint32_t i = 0; i < scene_state.max_lightmaps * 2; i++) {
			uint32_t current_lightmap_index = i < scene_state.max_lightmaps ? i : i - scene_state.max_lightmaps;

			if (p_render_data && current_lightmap_index < p_render_data->lightmaps->size()) {
				RID base = light_storage->lightmap_instance_get_lightmap((*p_render_data->lightmaps)[current_lightmap_index]);
				RID texture;

				if (i < scene_state.max_lightmaps) {
					// Lightmap
					texture = light_storage->lightmap_get_texture(base);
				} else {
					// Shadowmask
					texture = light_storage->shadowmask_get_texture(base);
				}

				if (texture.is_valid()) {
					RID rd_texture = texture_storage->texture_get_rd_texture(texture);
					textures.write[i] = rd_texture;
					continue;
				}
			}

			textures.write[i] = default_tex;
		}
		RD::Uniform u(RD::UNIFORM_TYPE_TEXTURE, 7, textures);
		uniforms.push_back(u);
	}
	{
		RD::Uniform u;
		u.binding = 9;
		u.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
		RID cb = (p_render_data && p_render_data->cluster_buffer.is_valid()) ? p_render_data->cluster_buffer : scene_shader.default_vec4_xform_buffer;
		u.append_id(cb);
		uniforms.push_back(u);
	}

	if (p_lighting_shader.is_null()) {
		RD::Uniform u;
		u.binding = 10;
		u.uniform_type = RD::UNIFORM_TYPE_SAMPLER;
		RID sampler;
		switch (decals_get_filter()) {
			case RSE::DECAL_FILTER_NEAREST: {
				sampler = p_samplers.get_sampler(RSE::CANVAS_ITEM_TEXTURE_FILTER_NEAREST, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);
			} break;
			case RSE::DECAL_FILTER_LINEAR: {
				sampler = p_samplers.get_sampler(RSE::CANVAS_ITEM_TEXTURE_FILTER_LINEAR, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);
			} break;
			case RSE::DECAL_FILTER_NEAREST_MIPMAPS: {
				sampler = p_samplers.get_sampler(RSE::CANVAS_ITEM_TEXTURE_FILTER_NEAREST_WITH_MIPMAPS, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);
			} break;
			case RSE::DECAL_FILTER_LINEAR_MIPMAPS: {
				sampler = p_samplers.get_sampler(RSE::CANVAS_ITEM_TEXTURE_FILTER_LINEAR_WITH_MIPMAPS, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);
			} break;
			case RSE::DECAL_FILTER_NEAREST_MIPMAPS_ANISOTROPIC: {
				sampler = p_samplers.get_sampler(RSE::CANVAS_ITEM_TEXTURE_FILTER_NEAREST_WITH_MIPMAPS_ANISOTROPIC, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);
			} break;
			case RSE::DECAL_FILTER_LINEAR_MIPMAPS_ANISOTROPIC: {
				sampler = p_samplers.get_sampler(RSE::CANVAS_ITEM_TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);
			} break;
		}

		u.append_id(sampler);
		uniforms.push_back(u);
	}

	{
		RD::Uniform u;
		u.binding = 11;
		u.uniform_type = RD::UNIFORM_TYPE_SAMPLER;
		RID sampler;
		switch (light_projectors_get_filter()) {
			case RSE::LIGHT_PROJECTOR_FILTER_NEAREST: {
				sampler = p_samplers.get_sampler(RSE::CANVAS_ITEM_TEXTURE_FILTER_NEAREST, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);
			} break;
			case RSE::LIGHT_PROJECTOR_FILTER_LINEAR: {
				sampler = p_samplers.get_sampler(RSE::CANVAS_ITEM_TEXTURE_FILTER_LINEAR, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);
			} break;
			case RSE::LIGHT_PROJECTOR_FILTER_NEAREST_MIPMAPS: {
				sampler = p_samplers.get_sampler(RSE::CANVAS_ITEM_TEXTURE_FILTER_NEAREST_WITH_MIPMAPS, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);
			} break;
			case RSE::LIGHT_PROJECTOR_FILTER_LINEAR_MIPMAPS: {
				sampler = p_samplers.get_sampler(RSE::CANVAS_ITEM_TEXTURE_FILTER_LINEAR_WITH_MIPMAPS, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);
			} break;
			case RSE::LIGHT_PROJECTOR_FILTER_NEAREST_MIPMAPS_ANISOTROPIC: {
				sampler = p_samplers.get_sampler(RSE::CANVAS_ITEM_TEXTURE_FILTER_NEAREST_WITH_MIPMAPS_ANISOTROPIC, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);
			} break;
			case RSE::LIGHT_PROJECTOR_FILTER_LINEAR_MIPMAPS_ANISOTROPIC: {
				sampler = p_samplers.get_sampler(RSE::CANVAS_ITEM_TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);
			} break;
		}

		u.append_id(sampler);
		uniforms.push_back(u);
	}

	if (p_lighting_shader.is_null()) {
		p_samplers.append_uniforms(uniforms, 12);
	} else {
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER, 12, p_samplers.get_sampler(RSE::CANVAS_ITEM_TEXTURE_FILTER_NEAREST, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED)));
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER, 13, p_samplers.get_sampler(RSE::CANVAS_ITEM_TEXTURE_FILTER_LINEAR, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED)));
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER, 15, p_samplers.get_sampler(RSE::CANVAS_ITEM_TEXTURE_FILTER_LINEAR_WITH_MIPMAPS, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED)));
	}

	{
		RD::Uniform u;
		u.binding = 24;
		u.uniform_type = RD::UNIFORM_TYPE_TEXTURE;
		RID texture;
		if (p_lighting_shader.is_valid() && rb.is_valid()) {
			// Lighting consumes this frame's G-buffer depth, not the optional
			// screen-reading copy used by forward materials.
			texture = rb->get_depth_texture();
		} else if (rb.is_valid() && rb->has_texture(RB_SCOPE_BUFFERS, RB_TEX_BACK_DEPTH)) {
			texture = rb->get_texture(RB_SCOPE_BUFFERS, RB_TEX_BACK_DEPTH);
		} else {
			texture = texture_storage->texture_rd_get_default(is_multiview ? RendererRD::TextureStorage::DEFAULT_RD_TEXTURE_2D_ARRAY_DEPTH : RendererRD::TextureStorage::DEFAULT_RD_TEXTURE_DEPTH);
		}
		u.append_id(texture);
		uniforms.push_back(u);
	}
	if (p_lighting_shader.is_null()) {
		RD::Uniform u;
		u.binding = 25;
		u.uniform_type = RD::UNIFORM_TYPE_TEXTURE;
		RID bbt = rb_data.is_valid() ? rb->get_back_buffer_texture() : RID();
		RID texture = bbt.is_valid() ? bbt : texture_storage->texture_rd_get_default(is_multiview ? RendererRD::TextureStorage::DEFAULT_RD_TEXTURE_2D_ARRAY_BLACK : RendererRD::TextureStorage::DEFAULT_RD_TEXTURE_BLACK);
		u.append_id(texture);
		uniforms.push_back(u);
	}

	{
		RD::Uniform u;
		u.binding = 26;
		u.uniform_type = RD::UNIFORM_TYPE_TEXTURE;
		RID texture = rb_data.is_valid() && rb_data->has_normal_roughness() ? rb_data->get_normal_roughness() : texture_storage->texture_rd_get_default(is_multiview ? RendererRD::TextureStorage::DEFAULT_RD_TEXTURE_2D_ARRAY_NORMAL : RendererRD::TextureStorage::DEFAULT_RD_TEXTURE_NORMAL);
		u.append_id(texture);
		uniforms.push_back(u);
	}

	{
		// Binding 27 (ambient occlusion), 28/29 (GI ambient/reflection), 30/31 (SDFGI
		// lightprobe/occlusion), 32 (VoxelGI instances) and 34/35/36 (SSIL/SSR) are
		// intentionally absent: FRP has no screen space effects and no global
		// illumination, and its shaders no longer declare those bindings.
	}

	if (p_lighting_shader.is_null()) {
		RD::Uniform u;
		u.binding = 33;
		u.uniform_type = RD::UNIFORM_TYPE_TEXTURE;
		RID vfog;
		if (rb_data.is_valid() && rb->has_custom_data(RB_SCOPE_FOG)) {
			Ref<RendererRD::Fog::VolumetricFog> fog = rb->get_custom_data(RB_SCOPE_FOG);
			vfog = fog->fog_map;
			if (vfog.is_null()) {
				vfog = texture_storage->texture_rd_get_default(RendererRD::TextureStorage::DEFAULT_RD_TEXTURE_3D_WHITE);
			}
		} else {
			vfog = texture_storage->texture_rd_get_default(RendererRD::TextureStorage::DEFAULT_RD_TEXTURE_3D_WHITE);
		}
		u.append_id(vfog);
		uniforms.push_back(u);
	}

	// Geometry passes do not declare the lighting-only G-buffer bindings.
	if (p_lighting_shader.is_null()) {
		return UniformSetCacheRD::get_singleton()->get_cache_vec(scene_shader.default_shader_rd, RENDER_PASS_UNIFORM_SET, uniforms);
	}

	// G-buffer textures, used by the FRP lighting pass.
	{
		RD::Uniform u;
		u.binding = 37;
		u.uniform_type = RD::UNIFORM_TYPE_TEXTURE;
		RID texture = rb_data.is_valid() && rb_data->has_gbuffer() ? rb_data->get_gbuffer_albedo() : texture_storage->texture_rd_get_default(is_multiview ? RendererRD::TextureStorage::DEFAULT_RD_TEXTURE_2D_ARRAY_BLACK : RendererRD::TextureStorage::DEFAULT_RD_TEXTURE_BLACK);
		u.append_id(texture);
		uniforms.push_back(u);
	}
	{
		RD::Uniform u;
		u.binding = 38;
		u.uniform_type = RD::UNIFORM_TYPE_TEXTURE;
		RID texture = rb_data.is_valid() && rb_data->has_gbuffer() ? rb_data->get_gbuffer_orm() : texture_storage->texture_rd_get_default(is_multiview ? RendererRD::TextureStorage::DEFAULT_RD_TEXTURE_2D_ARRAY_BLACK : RendererRD::TextureStorage::DEFAULT_RD_TEXTURE_BLACK);
		u.append_id(texture);
		uniforms.push_back(u);
	}
	{
		RD::Uniform u;
		u.binding = 39;
		u.uniform_type = RD::UNIFORM_TYPE_TEXTURE;
		RID texture = rb_data.is_valid() && rb_data->has_gbuffer() ? rb_data->get_gbuffer_emission() : texture_storage->texture_rd_get_default(is_multiview ? RendererRD::TextureStorage::DEFAULT_RD_TEXTURE_2D_ARRAY_BLACK : RendererRD::TextureStorage::DEFAULT_RD_TEXTURE_BLACK);
		u.append_id(texture);
		uniforms.push_back(u);
	}

	return UniformSetCacheRD::get_singleton()->get_cache_vec(p_lighting_shader, RENDER_PASS_UNIFORM_SET, uniforms);
}


RID RenderFRPClustered::_render_buffers_get_normal_texture(Ref<RenderSceneBuffersRD> p_render_buffers) {
	Ref<RenderBufferDataFRPClustered> rb_data = p_render_buffers->get_custom_data(RB_SCOPE_FRP_CLUSTERED);

	return rb_data->get_normal_roughness();
}

RID RenderFRPClustered::_render_buffers_get_velocity_texture(Ref<RenderSceneBuffersRD> p_render_buffers) {
	return p_render_buffers->get_velocity_buffer(false);
}

// FRP has no screen space effects, so the quality knobs the engine forwards from the
// Environment are accepted and ignored - the same thing RenderForwardMobile does. The
// overrides have to exist (RendererSceneRender declares them pure virtual); doing
// nothing is what keeps a project's SSAO / SSIL / SSR settings from changing an FRP
// frame. Subsurface scattering keeps its own settings below, because that one is part
// of the Lighting pass.
void RenderFRPClustered::environment_set_ssao_quality(RSE::EnvironmentSSAOQuality p_quality, bool p_half_size, float p_adaptive_target, int p_blur_passes, float p_fadeout_from, float p_fadeout_to) {
}

void RenderFRPClustered::environment_set_ssil_quality(RSE::EnvironmentSSILQuality p_quality, bool p_half_size, float p_adaptive_target, int p_blur_passes, float p_fadeout_from, float p_fadeout_to) {
}

void RenderFRPClustered::environment_set_ssr_half_size(bool p_half_size) {
}

void RenderFRPClustered::environment_set_ssr_roughness_quality(RSE::EnvironmentSSRRoughnessQuality p_quality) {
	WARN_PRINT_ONCE("environment_set_ssr_roughness_quality has been deprecated and no longer does anything.");
}

void RenderFRPClustered::sub_surface_scattering_set_quality(RSE::SubSurfaceScatteringQuality p_quality) {
	ERR_FAIL_NULL(ss_effects);
	ERR_FAIL_COND(p_quality < RSE::SubSurfaceScatteringQuality::SUB_SURFACE_SCATTERING_QUALITY_DISABLED || p_quality > RSE::SubSurfaceScatteringQuality::SUB_SURFACE_SCATTERING_QUALITY_HIGH);
	ss_effects->sss_set_quality(p_quality);
}

void RenderFRPClustered::sub_surface_scattering_set_scale(float p_scale, float p_depth_scale) {
	ERR_FAIL_NULL(ss_effects);
	ss_effects->sss_set_scale(p_scale, p_depth_scale);
}

RenderFRPClustered *RenderFRPClustered::singleton = nullptr;





void RenderFRPClustered::GeometryInstanceFRPClustered::_mark_dirty() {
	if (dirty_list_element.in_list()) {
		return;
	}

	//clear surface caches
	GeometryInstanceSurfaceDataCache *surf = surface_caches;

	while (surf) {
		GeometryInstanceSurfaceDataCache *next = surf->next;
		RenderFRPClustered::get_singleton()->geometry_instance_surface_alloc.free(surf);
		surf = next;
	}

	surface_caches = nullptr;

	RenderFRPClustered::get_singleton()->geometry_instance_dirty_list.add(&dirty_list_element);
}

void RenderFRPClustered::_update_global_pipeline_data_requirements_from_project() {
	const int msaa_3d_mode = GLOBAL_GET_CACHED(int, "rendering/anti_aliasing/quality/msaa_3d");
	const bool directional_shadow_16_bits = GLOBAL_GET_CACHED(bool, "rendering/lights_and_shadows/directional_shadow/16_bits");
	const bool positional_shadow_16_bits = GLOBAL_GET_CACHED(bool, "rendering/lights_and_shadows/positional_shadow/atlas_16_bits");
	global_pipeline_data_required.use_16_bit_shadows = directional_shadow_16_bits || positional_shadow_16_bits;
	global_pipeline_data_required.use_32_bit_shadows = !directional_shadow_16_bits || !positional_shadow_16_bits;
	global_pipeline_data_required.texture_samples = RenderSceneBuffersRD::msaa_to_samples(RSE::ViewportMSAA(msaa_3d_mode));
}

void RenderFRPClustered::_update_global_pipeline_data_requirements_from_light_storage() {
	RendererRD::LightStorage *light_storage = RendererRD::LightStorage::get_singleton();
	global_pipeline_data_required.use_shadow_cubemaps = light_storage->get_shadow_cubemaps_used();
	global_pipeline_data_required.use_shadow_dual_paraboloid = light_storage->get_shadow_dual_paraboloid_used();
}

void RenderFRPClustered::_geometry_instance_add_surface_with_material(GeometryInstanceFRPClustered *ginstance, uint32_t p_surface, SceneShaderFRPClustered::MaterialData *p_material, uint32_t p_material_id, uint32_t p_shader_id, RID p_mesh) {
	RendererRD::MeshStorage *mesh_storage = RendererRD::MeshStorage::get_singleton();
	uint32_t flags = 0;

	if (p_material->shader_data->uses_sss) {
		flags |= GeometryInstanceSurfaceDataCache::FLAG_USES_SUBSURFACE_SCATTERING;
		global_surface_data.sss_used = true;
	}

	if (p_material->shader_data->uses_screen_texture) {
		flags |= GeometryInstanceSurfaceDataCache::FLAG_USES_SCREEN_TEXTURE;
		global_surface_data.screen_texture_used = true;
	}

	if (p_material->shader_data->uses_depth_texture) {
		flags |= GeometryInstanceSurfaceDataCache::FLAG_USES_DEPTH_TEXTURE;
		global_surface_data.depth_texture_used = true;
	}

	if (p_material->shader_data->uses_normal_texture) {
		flags |= GeometryInstanceSurfaceDataCache::FLAG_USES_NORMAL_TEXTURE;
		global_surface_data.normal_texture_used = true;
	}

	if (ginstance->data->cast_double_sided_shadows) {
		flags |= GeometryInstanceSurfaceDataCache::FLAG_USES_DOUBLE_SIDED_SHADOWS;
	}

	if (p_material->shader_data->stencil_enabled) {
		flags |= GeometryInstanceSurfaceDataCache::FLAG_USES_STENCIL;
	}

	if (p_material->shader_data->uses_alpha_pass()) {
		flags |= GeometryInstanceSurfaceDataCache::FLAG_PASS_ALPHA;
		if (p_material->shader_data->uses_depth_in_alpha_pass()) {
			flags |= GeometryInstanceSurfaceDataCache::FLAG_PASS_DEPTH;
			flags |= GeometryInstanceSurfaceDataCache::FLAG_PASS_SHADOW;
		}
	} else {
		flags |= GeometryInstanceSurfaceDataCache::FLAG_PASS_OPAQUE;
		flags |= GeometryInstanceSurfaceDataCache::FLAG_PASS_DEPTH;
		flags |= GeometryInstanceSurfaceDataCache::FLAG_PASS_SHADOW;
	}

	if (p_material->shader_data->uses_particle_trails) {
		flags |= GeometryInstanceSurfaceDataCache::FLAG_USES_PARTICLE_TRAILS;
	}

	if (p_material->shader_data->is_animated()) {
		flags |= GeometryInstanceSurfaceDataCache::FLAG_USES_MOTION_VECTOR;
	}

	if (p_material->shader_data->stencil_enabled) {
		if (p_material->shader_data->stencil_flags & SceneShaderFRPClustered::ShaderData::STENCIL_FLAG_READ) {
			// Stencil materials which read from the stencil buffer must be in the alpha pass.
			// This is critical to preserve compatibility once we'll have the compositor.
			if (!(flags & GeometryInstanceSurfaceDataCache::FLAG_PASS_ALPHA)) {
				String shader_path = p_material->shader_data->path.is_empty() ? "" : "(" + p_material->shader_data->path + ")";
				ERR_PRINT_ED(vformat("Attempting to use a shader %s that reads stencil but is not in the alpha queue. Ensure the material uses alpha blending or has depth_draw disabled or depth_test disabled.", shader_path));
			}
		}
	}

	SceneShaderFRPClustered::MaterialData *material_shadow = nullptr;
	void *surface_shadow = nullptr;
	if (p_material->shader_data->uses_shared_shadow_material()) {
		flags |= GeometryInstanceSurfaceDataCache::FLAG_USES_SHARED_SHADOW_MATERIAL;
		material_shadow = static_cast<SceneShaderFRPClustered::MaterialData *>(RendererRD::MaterialStorage::get_singleton()->material_get_data(scene_shader.default_material, RendererRD::MaterialStorage::SHADER_TYPE_3D));

		RID shadow_mesh = mesh_storage->mesh_get_shadow_mesh(p_mesh);
		if (shadow_mesh.is_valid()) {
			surface_shadow = mesh_storage->mesh_get_surface(shadow_mesh, p_surface);
		}
	} else {
		material_shadow = p_material;
	}

	GeometryInstanceSurfaceDataCache *sdcache = geometry_instance_surface_alloc.alloc();

	sdcache->flags = flags;

	sdcache->shader = p_material->shader_data;
	sdcache->material = p_material;
	sdcache->material_uniform_set = p_material->uniform_set;
	sdcache->surface = mesh_storage->mesh_get_surface(p_mesh, p_surface);
	sdcache->primitive = mesh_storage->mesh_surface_get_primitive(sdcache->surface);
	sdcache->surface_index = p_surface;

	if (ginstance->data->dirty_dependencies) {
		RSG::utilities->base_update_dependency(p_mesh, &ginstance->data->dependency_tracker);
	}

	//shadow
	sdcache->shader_shadow = material_shadow->shader_data;
	sdcache->material_uniform_set_shadow = material_shadow->uniform_set;

	sdcache->surface_shadow = surface_shadow ? surface_shadow : sdcache->surface;

	sdcache->owner = ginstance;

	sdcache->next = ginstance->surface_caches;
	ginstance->surface_caches = sdcache;

	//sortkey

	sdcache->sort.sort_key1 = 0;
	sdcache->sort.sort_key2 = 0;

	sdcache->sort.surface_index = p_surface;
	sdcache->sort.material_id_hi = (p_material_id & 0xFF000000) >> 24;
	sdcache->sort.material_id_lo = (p_material_id & 0x00FFFFFF);
	sdcache->sort.shader_id = p_shader_id;
	sdcache->sort.geometry_id = p_mesh.get_local_index(); //only meshes can repeat anyway
	// FRP has no global illumination, so no surface is ever a forward GI surface.
	sdcache->sort.uses_forward_gi = 0;
	sdcache->sort.priority = p_material->priority;
	sdcache->sort.uses_projector = ginstance->using_projectors;
	sdcache->sort.uses_softshadow = ginstance->using_softshadows;

	uint64_t format = RendererRD::MeshStorage::get_singleton()->mesh_surface_get_format(sdcache->surface);
	if (p_material->shader_data->uses_tangent && !p_material->shader_data->writes_tangent && !(format & RSE::ARRAY_FORMAT_TANGENT)) {
		String shader_path = p_material->shader_data->path.is_empty() ? "" : "(" + p_material->shader_data->path + ")";
		String mesh_path = mesh_storage->mesh_get_path(p_mesh).is_empty() ? "" : "(" + mesh_storage->mesh_get_path(p_mesh) + ")";
		WARN_PRINT_ED(vformat("Attempting to use a shader %s that requires tangents with a mesh %s that doesn't contain tangents. Ensure that meshes are imported with the 'ensure_tangents' option. If creating your own meshes, add an `ARRAY_TANGENT` array (when using ArrayMesh) or call `generate_tangents()` (when using SurfaceTool).", shader_path, mesh_path));
	}

#if PRELOAD_PIPELINES_ON_SURFACE_CACHE_CONSTRUCTION
	if (!sdcache->compilation_dirty_element.in_list()) {
		geometry_surface_compilation_dirty_list.add(&sdcache->compilation_dirty_element);
	}

	if (!sdcache->compilation_all_element.in_list()) {
		geometry_surface_compilation_all_list.add(&sdcache->compilation_all_element);
	}
#endif
}

void RenderFRPClustered::_geometry_instance_add_surface_with_material_chain(GeometryInstanceFRPClustered *ginstance, uint32_t p_surface, SceneShaderFRPClustered::MaterialData *p_material, RID p_mat_src, RID p_mesh) {
	SceneShaderFRPClustered::MaterialData *material = p_material;
	RendererRD::MaterialStorage *material_storage = RendererRD::MaterialStorage::get_singleton();

	_geometry_instance_add_surface_with_material(ginstance, p_surface, material, p_mat_src.get_local_index(), material_storage->material_get_shader_id(p_mat_src), p_mesh);

	while (material->next_pass.is_valid()) {
		RID next_pass = material->next_pass;
		material = static_cast<SceneShaderFRPClustered::MaterialData *>(material_storage->material_get_data(next_pass, RendererRD::MaterialStorage::SHADER_TYPE_3D));
		if (!material || !material->shader_data->is_valid()) {
			break;
		}
		if (ginstance->data->dirty_dependencies) {
			material_storage->material_update_dependency(next_pass, &ginstance->data->dependency_tracker);
		}
		_geometry_instance_add_surface_with_material(ginstance, p_surface, material, next_pass.get_local_index(), material_storage->material_get_shader_id(next_pass), p_mesh);
	}
}

void RenderFRPClustered::_geometry_instance_add_surface(GeometryInstanceFRPClustered *ginstance, uint32_t p_surface, RID p_material, RID p_mesh) {
	RendererRD::MaterialStorage *material_storage = RendererRD::MaterialStorage::get_singleton();
	RID m_src;

	m_src = ginstance->data->material_override.is_valid() ? ginstance->data->material_override : p_material;

	SceneShaderFRPClustered::MaterialData *material = nullptr;

	if (m_src.is_valid()) {
		material = static_cast<SceneShaderFRPClustered::MaterialData *>(material_storage->material_get_data(m_src, RendererRD::MaterialStorage::SHADER_TYPE_3D));
		if (!material || !material->shader_data->is_valid()) {
			material = nullptr;
		}
	}

	if (material) {
		if (ginstance->data->dirty_dependencies) {
			material_storage->material_update_dependency(m_src, &ginstance->data->dependency_tracker);
		}
	} else {
		material = static_cast<SceneShaderFRPClustered::MaterialData *>(material_storage->material_get_data(scene_shader.default_material, RendererRD::MaterialStorage::SHADER_TYPE_3D));
		m_src = scene_shader.default_material;
	}

	ERR_FAIL_NULL(material);

	_geometry_instance_add_surface_with_material_chain(ginstance, p_surface, material, m_src, p_mesh);

	if (ginstance->data->material_overlay.is_valid()) {
		m_src = ginstance->data->material_overlay;

		material = static_cast<SceneShaderFRPClustered::MaterialData *>(material_storage->material_get_data(m_src, RendererRD::MaterialStorage::SHADER_TYPE_3D));
		if (material && material->shader_data->is_valid()) {
			if (ginstance->data->dirty_dependencies) {
				material_storage->material_update_dependency(m_src, &ginstance->data->dependency_tracker);
			}

			_geometry_instance_add_surface_with_material_chain(ginstance, p_surface, material, m_src, p_mesh);
		}
	}
}

void RenderFRPClustered::_geometry_instance_update(RenderGeometryInstance *p_geometry_instance) {
	RendererRD::MeshStorage *mesh_storage = RendererRD::MeshStorage::get_singleton();
	RendererRD::ParticlesStorage *particles_storage = RendererRD::ParticlesStorage::get_singleton();
	GeometryInstanceFRPClustered *ginstance = static_cast<GeometryInstanceFRPClustered *>(p_geometry_instance);

	if (ginstance->data->dirty_dependencies) {
		ginstance->data->dependency_tracker.update_begin();
	}

	//add geometry for drawing
	switch (ginstance->data->base_type) {
		case RSE::INSTANCE_MESH: {
			const RID *materials = nullptr;
			uint32_t surface_count;
			RID mesh = ginstance->data->base;

			materials = mesh_storage->mesh_get_surface_count_and_materials(mesh, surface_count);
			if (materials) {
				//if no materials, no surfaces.
				const RID *inst_materials = ginstance->data->surface_materials.ptr();
				uint32_t surf_mat_count = ginstance->data->surface_materials.size();

				for (uint32_t j = 0; j < surface_count; j++) {
					RID material = (j < surf_mat_count && inst_materials[j].is_valid()) ? inst_materials[j] : materials[j];
					_geometry_instance_add_surface(ginstance, j, material, mesh);
				}
			}

			ginstance->instance_count = 1;

		} break;

		case RSE::INSTANCE_MULTIMESH: {
			RID mesh = mesh_storage->multimesh_get_mesh(ginstance->data->base);
			if (mesh.is_valid()) {
				const RID *materials = nullptr;
				uint32_t surface_count;

				materials = mesh_storage->mesh_get_surface_count_and_materials(mesh, surface_count);
				if (materials) {
					for (uint32_t j = 0; j < surface_count; j++) {
						_geometry_instance_add_surface(ginstance, j, materials[j], mesh);
					}
				}

				ginstance->instance_count = mesh_storage->multimesh_get_instances_to_draw(ginstance->data->base);
			}

		} break;
#if 0
		case RSE::INSTANCE_IMMEDIATE: {
			RasterizerStorageGLES3::Immediate *immediate = storage->immediate_owner.get_or_null(inst->base);
			ERR_CONTINUE(!immediate);

			_add_geometry(immediate, inst, nullptr, -1, p_depth_pass, p_shadow_pass);

		} break;
#endif
		case RSE::INSTANCE_PARTICLES: {
			int draw_passes = particles_storage->particles_get_draw_passes(ginstance->data->base);

			for (int j = 0; j < draw_passes; j++) {
				RID mesh = particles_storage->particles_get_draw_pass_mesh(ginstance->data->base, j);
				if (!mesh.is_valid()) {
					continue;
				}

				const RID *materials = nullptr;
				uint32_t surface_count;

				materials = mesh_storage->mesh_get_surface_count_and_materials(mesh, surface_count);
				if (materials) {
					for (uint32_t k = 0; k < surface_count; k++) {
						_geometry_instance_add_surface(ginstance, k, materials[k], mesh);
					}
				}
			}

			ginstance->instance_count = particles_storage->particles_get_amount(ginstance->data->base, ginstance->trail_steps);

		} break;

		default: {
		}
	}

	//Fill push constant

	ginstance->base_flags = 0;

	bool store_transform = true;
	if (ginstance->data->base_type == RSE::INSTANCE_MULTIMESH) {
		ginstance->base_flags |= INSTANCE_DATA_FLAG_MULTIMESH;

		if (mesh_storage->multimesh_get_transform_format(ginstance->data->base) == RSE::MULTIMESH_TRANSFORM_2D) {
			ginstance->base_flags |= INSTANCE_DATA_FLAG_MULTIMESH_FORMAT_2D;
		}
		if (mesh_storage->multimesh_uses_colors(ginstance->data->base)) {
			ginstance->base_flags |= INSTANCE_DATA_FLAG_MULTIMESH_HAS_COLOR;
		}
		if (mesh_storage->multimesh_uses_custom_data(ginstance->data->base)) {
			ginstance->base_flags |= INSTANCE_DATA_FLAG_MULTIMESH_HAS_CUSTOM_DATA;
		}
		if (mesh_storage->multimesh_uses_indirect(ginstance->data->base)) {
			ginstance->base_flags |= INSTANCE_DATA_FLAG_MULTIMESH_INDIRECT;
		}

		ginstance->transforms_uniform_set = mesh_storage->multimesh_get_3d_uniform_set(ginstance->data->base, scene_shader.default_shader_rd, TRANSFORMS_UNIFORM_SET);

	} else if (ginstance->data->base_type == RSE::INSTANCE_PARTICLES) {
		ginstance->base_flags |= INSTANCE_DATA_FLAG_PARTICLES;
		ginstance->base_flags |= INSTANCE_DATA_FLAG_MULTIMESH;

		ginstance->base_flags |= INSTANCE_DATA_FLAG_MULTIMESH_HAS_COLOR;
		ginstance->base_flags |= INSTANCE_DATA_FLAG_MULTIMESH_HAS_CUSTOM_DATA;

		//for particles, stride is the trail size
		ginstance->base_flags |= (ginstance->trail_steps << INSTANCE_DATA_FLAGS_PARTICLE_TRAIL_SHIFT);

		if (!particles_storage->particles_is_using_local_coords(ginstance->data->base)) {
			store_transform = false;
		}
		ginstance->transforms_uniform_set = particles_storage->particles_get_instance_buffer_uniform_set(ginstance->data->base, scene_shader.default_shader_rd, TRANSFORMS_UNIFORM_SET);

		if (particles_storage->particles_get_frame_counter(ginstance->data->base) == 0) {
			// Particles haven't been cleared or updated, update once now to ensure they are ready to render.
			particles_storage->update_particles();
		}

		if (ginstance->data->dirty_dependencies) {
			particles_storage->particles_update_dependency(ginstance->data->base, &ginstance->data->dependency_tracker);
		}
	} else if (ginstance->data->base_type == RSE::INSTANCE_MESH) {
		if (mesh_storage->skeleton_is_valid(ginstance->data->skeleton)) {
			ginstance->transforms_uniform_set = mesh_storage->skeleton_get_3d_uniform_set(ginstance->data->skeleton, scene_shader.default_shader_rd, TRANSFORMS_UNIFORM_SET);
			if (ginstance->data->dirty_dependencies) {
				mesh_storage->skeleton_update_dependency(ginstance->data->skeleton, &ginstance->data->dependency_tracker);
			}
		} else {
			ginstance->transforms_uniform_set = RID();
		}
	}

	ginstance->store_transform_cache = store_transform;
	if (ginstance->data->dirty_dependencies) {
		ginstance->data->dependency_tracker.update_end();
		ginstance->data->dirty_dependencies = false;
	}

	ginstance->dirty_list_element.remove_from_list();
}

static RD::FramebufferFormatID _get_color_framebuffer_format_for_pipeline(RD::DataFormat p_color_format, bool p_can_be_storage, RD::TextureSamples p_samples, bool p_specular, bool p_velocity, uint32_t p_view_count) {
	const bool multisampling = p_samples > RD::TEXTURE_SAMPLES_1;
	RD::AttachmentFormat attachment;
	attachment.samples = p_samples;

	RD::AttachmentFormat unused_attachment;
	unused_attachment.usage_flags = RD::AttachmentFormat::UNUSED_ATTACHMENT;

	thread_local Vector<RD::AttachmentFormat> attachments;
	attachments.clear();

	// Color attachment.
	attachment.format = p_color_format;
	attachment.usage_flags = RenderSceneBuffersRD::get_color_usage_bits(false, multisampling, p_can_be_storage);
	attachments.push_back(attachment);

	if (p_specular) {
		attachment.format = RenderFRPClustered::RenderBufferDataFRPClustered::get_specular_format();
		attachment.usage_flags = RenderFRPClustered::RenderBufferDataFRPClustered::get_specular_usage_bits(false, multisampling, p_can_be_storage);
		attachments.push_back(attachment);
	} else {
		attachments.push_back(unused_attachment);
	}

	if (p_velocity) {
		attachment.format = RenderSceneBuffersRD::get_velocity_format();
		attachment.usage_flags = RenderSceneBuffersRD::get_velocity_usage_bits(false, multisampling, p_can_be_storage);
		attachments.push_back(attachment);
	} else {
		attachments.push_back(unused_attachment);
	}

	// Depth attachment.
	attachment.format = RenderSceneBuffersRD::get_depth_format(false, multisampling, p_can_be_storage);
	attachment.usage_flags = RenderSceneBuffersRD::get_depth_usage_bits(false, multisampling, p_can_be_storage);
	attachments.push_back(attachment);

	thread_local Vector<RD::FramebufferPass> passes;
	passes.resize(1);
	passes.ptrw()[0].color_attachments.resize(attachments.size() - 1);

	int *color_attachments = passes.ptrw()[0].color_attachments.ptrw();
	for (int64_t i = 0; i < attachments.size() - 1; i++) {
		color_attachments[i] = (attachments[i].usage_flags == RD::AttachmentFormat::UNUSED_ATTACHMENT) ? RD::ATTACHMENT_UNUSED : i;
	}

	passes.ptrw()[0].depth_attachment = attachments.size() - 1;

	return RD::get_singleton()->framebuffer_format_create_multipass(attachments, passes, p_view_count);
}

static RD::FramebufferFormatID _get_reflection_probe_color_framebuffer_format_for_pipeline(bool p_storage) {
	RD::AttachmentFormat attachment;
	thread_local Vector<RD::AttachmentFormat> attachments;
	attachments.clear();

	attachment.format = RendererRD::LightStorage::get_reflection_probe_color_format();
	attachment.usage_flags = RendererRD::LightStorage::get_reflection_probe_color_usage_bits(p_storage);
	attachments.push_back(attachment);

	attachment.format = RendererRD::LightStorage::get_reflection_probe_depth_format();
	attachment.usage_flags = RendererRD::LightStorage::get_reflection_probe_depth_usage_bits();
	attachments.push_back(attachment);

	return RD::get_singleton()->framebuffer_format_create(attachments);
}

static RD::FramebufferFormatID _get_depth_framebuffer_format_for_pipeline(bool p_can_be_storage, RD::TextureSamples p_samples, bool p_normal_roughness) {
	const bool multisampling = p_samples > RD::TEXTURE_SAMPLES_1;
	RD::AttachmentFormat attachment;
	attachment.samples = p_samples;

	thread_local LocalVector<RD::AttachmentFormat> attachments;
	attachments.clear();

	attachment.format = RenderSceneBuffersRD::get_depth_format(false, multisampling, p_can_be_storage);
	attachment.usage_flags = RenderSceneBuffersRD::get_depth_usage_bits(false, multisampling, p_can_be_storage);
	attachments.push_back(attachment);

	if (p_normal_roughness) {
		attachment.format = RenderFRPClustered::RenderBufferDataFRPClustered::get_normal_roughness_format();
		attachment.usage_flags = RenderFRPClustered::RenderBufferDataFRPClustered::get_normal_roughness_usage_bits(false, multisampling, p_can_be_storage);
		attachments.push_back(attachment);
	}

	thread_local Vector<RD::FramebufferPass> passes;
	passes.resize(1);
	passes.ptrw()[0].color_attachments.resize(attachments.size() - 1);

	int *color_attachments = passes.ptrw()[0].color_attachments.ptrw();
	for (int64_t i = 1; i < attachments.size(); i++) {
		color_attachments[i - 1] = (attachments[i].usage_flags == RD::AttachmentFormat::UNUSED_ATTACHMENT) ? RD::ATTACHMENT_UNUSED : i;
	}

	passes.ptrw()[0].depth_attachment = 0;

	return RD::get_singleton()->framebuffer_format_create_multipass(Vector<RD::AttachmentFormat>(attachments), passes);
}

static RD::FramebufferFormatID _get_shadow_cubemap_framebuffer_format_for_pipeline() {
	thread_local LocalVector<RD::AttachmentFormat> attachments;
	attachments.clear();

	RD::AttachmentFormat attachment;
	attachment.format = RendererRD::LightStorage::get_cubemap_depth_format();
	attachment.usage_flags = RendererRD::LightStorage::get_cubemap_depth_usage_bits();
	attachments.push_back(attachment);

	return RD::get_singleton()->framebuffer_format_create(Vector<RD::AttachmentFormat>(attachments));
}

static RD::FramebufferFormatID _get_shadow_atlas_framebuffer_format_for_pipeline(bool p_use_16_bits) {
	thread_local LocalVector<RD::AttachmentFormat> attachments;
	attachments.clear();

	RD::AttachmentFormat attachment;
	attachment.format = RendererRD::LightStorage::get_shadow_atlas_depth_format(p_use_16_bits);
	attachment.usage_flags = RendererRD::LightStorage::get_shadow_atlas_depth_usage_bits();
	attachments.push_back(attachment);

	return RD::get_singleton()->framebuffer_format_create(Vector<RD::AttachmentFormat>(attachments));
}

static RD::FramebufferFormatID _get_reflection_probe_depth_framebuffer_format_for_pipeline() {
	thread_local LocalVector<RD::AttachmentFormat> attachments;
	attachments.clear();

	RD::AttachmentFormat attachment;
	attachment.format = RendererRD::LightStorage::get_reflection_probe_depth_format();
	attachment.usage_flags = RendererRD::LightStorage::get_reflection_probe_depth_usage_bits();
	attachments.push_back(attachment);

	return RD::get_singleton()->framebuffer_format_create(Vector<RD::AttachmentFormat>(attachments));
}

void RenderFRPClustered::_mesh_compile_pipeline_for_surface(SceneShaderFRPClustered::ShaderData *p_shader, void *p_mesh_surface, bool p_ubershader, bool p_instanced_surface, RSE::PipelineSource p_source, SceneShaderFRPClustered::ShaderData::PipelineKey &r_pipeline_key, Vector<ShaderPipelinePair> *r_pipeline_pairs) {
	RendererRD::MeshStorage *mesh_storage = RendererRD::MeshStorage::get_singleton();
	uint64_t input_mask = p_shader->get_vertex_input_mask(r_pipeline_key.version, r_pipeline_key.color_pass_flags, p_ubershader);
	bool pipeline_motion_vectors = r_pipeline_key.color_pass_flags & SceneShaderFRPClustered::PIPELINE_COLOR_PASS_FLAG_MOTION_VECTORS;
	bool emulate_point_size = p_shader->uses_point_size && scene_shader.emulate_point_size;
	r_pipeline_key.vertex_format_id = mesh_storage->mesh_surface_get_vertex_format(p_mesh_surface, input_mask, p_instanced_surface, pipeline_motion_vectors, emulate_point_size);
	r_pipeline_key.ubershader = p_ubershader;

	p_shader->pipeline_hash_map.compile_pipeline(r_pipeline_key, r_pipeline_key.hash(), p_source, p_ubershader);

	if (r_pipeline_pairs != nullptr) {
		r_pipeline_pairs->push_back({ p_shader, r_pipeline_key });
	}
}

void RenderFRPClustered::_mesh_compile_pipelines_for_surface(const SurfacePipelineData &p_surface, const GlobalPipelineData &p_global, RSE::PipelineSource p_source, Vector<ShaderPipelinePair> *r_pipeline_pairs) {
	RendererRD::MeshStorage *mesh_storage = RendererRD::MeshStorage::get_singleton();
	bool octmap_use_storage = !copy_effects->get_raster_effects().has_flag(RendererRD::CopyEffects::RASTER_EFFECT_OCTMAP);

	// Retrieve from the scene shader which groups are currently enabled.
	const bool multiview_enabled = p_global.use_multiview && scene_shader.is_multiview_shader_group_enabled();
	const RD::DataFormat buffers_color_format = _render_buffers_get_preferred_color_format();
	const bool buffers_can_be_storage = _render_buffers_can_be_storage();

	// Set the attributes common to all pipelines.
	SceneShaderFRPClustered::ShaderData::PipelineKey pipeline_key;
	pipeline_key.cull_mode = RD::POLYGON_CULL_DISABLED;
	pipeline_key.primitive_type = mesh_storage->mesh_surface_get_primitive(p_surface.mesh_surface);
	pipeline_key.wireframe = false;

	// Grab the shader and surface used for most passes.
	const uint32_t multiview_iterations = multiview_enabled ? 2 : 1;
	const uint32_t lightmap_iterations = p_global.use_lightmaps && p_surface.can_use_lightmap ? 2 : 1;
	const uint32_t alpha_iterations = p_surface.uses_transparent ? 2 : 1;
	for (uint32_t multiview = 0; multiview < multiview_iterations; multiview++) {
		for (uint32_t lightmap = 0; lightmap < lightmap_iterations; lightmap++) {
			for (uint32_t alpha = p_surface.uses_opaque ? 0 : 1; alpha < alpha_iterations; alpha++) {
				// Generate all the possible variants used during the color pass.
				pipeline_key.version = SceneShaderFRPClustered::PIPELINE_VERSION_COLOR_PASS;
				pipeline_key.color_pass_flags = 0;

				if (lightmap) {
					pipeline_key.color_pass_flags |= SceneShaderFRPClustered::PIPELINE_COLOR_PASS_FLAG_LIGHTMAP;
				}

				if (alpha) {
					pipeline_key.color_pass_flags |= SceneShaderFRPClustered::PIPELINE_COLOR_PASS_FLAG_TRANSPARENT;
				}

				if (multiview) {
					pipeline_key.color_pass_flags |= SceneShaderFRPClustered::PIPELINE_COLOR_PASS_FLAG_MULTIVIEW;
				} else if (p_global.use_reflection_probes) {
					// Reflection probe can't be rendered in multiview.
					pipeline_key.framebuffer_format_id = _get_reflection_probe_color_framebuffer_format_for_pipeline(octmap_use_storage);
					_mesh_compile_pipeline_for_surface(p_surface.shader, p_surface.mesh_surface, true, p_surface.instanced, p_source, pipeline_key, r_pipeline_pairs);
				}

				// View count is assumed to be 2 as the configuration is dependent on the viewport. It's likely a safe assumption for stereo rendering.
				uint32_t view_count = multiview ? 2 : 1;
				pipeline_key.framebuffer_format_id = _get_color_framebuffer_format_for_pipeline(buffers_color_format, buffers_can_be_storage, RD::TextureSamples(p_global.texture_samples), false, false, view_count);
				_mesh_compile_pipeline_for_surface(p_surface.shader, p_surface.mesh_surface, true, p_surface.instanced, p_source, pipeline_key, r_pipeline_pairs);

				// Generate all the possible variants used during the advanced color passes.
				const uint32_t separate_specular_iterations = p_global.use_separate_specular ? 2 : 1;
				const uint32_t motion_vectors_iterations = p_global.use_motion_vectors ? 2 : 1;
				uint32_t base_color_pass_flags = pipeline_key.color_pass_flags;
				for (uint32_t separate_specular = 0; separate_specular < separate_specular_iterations; separate_specular++) {
					for (uint32_t motion_vectors = 0; motion_vectors < motion_vectors_iterations; motion_vectors++) {
						if (!separate_specular && !motion_vectors) {
							// This case was already generated.
							continue;
						}

						pipeline_key.color_pass_flags = base_color_pass_flags;

						if (separate_specular) {
							pipeline_key.color_pass_flags |= SceneShaderFRPClustered::PIPELINE_COLOR_PASS_FLAG_SEPARATE_SPECULAR;
						}

						if (motion_vectors) {
							pipeline_key.color_pass_flags |= SceneShaderFRPClustered::PIPELINE_COLOR_PASS_FLAG_MOTION_VECTORS;
						}

						pipeline_key.framebuffer_format_id = _get_color_framebuffer_format_for_pipeline(buffers_color_format, buffers_can_be_storage, RD::TextureSamples(p_global.texture_samples), separate_specular, motion_vectors, view_count);
						_mesh_compile_pipeline_for_surface(p_surface.shader, p_surface.mesh_surface, true, p_surface.instanced, p_source, pipeline_key, r_pipeline_pairs);
					}
				}
			}
		}
	}

	if (!p_surface.uses_depth) {
		return;
	}

	// Generate the depth pipelines if the material supports depth or it must be part of the shadow pass.
	pipeline_key.color_pass_flags = 0;

	if (p_global.use_normal_and_roughness) {
		// A lot of different effects rely on normal and roughness being written to during the depth pass.
		pipeline_key.version = SceneShaderFRPClustered::PIPELINE_VERSION_DEPTH_PASS_WITH_NORMAL_AND_ROUGHNESS;
		pipeline_key.framebuffer_format_id = _get_depth_framebuffer_format_for_pipeline(buffers_can_be_storage, RD::TextureSamples(p_global.texture_samples), true);
		_mesh_compile_pipeline_for_surface(p_surface.shader, p_surface.mesh_surface, true, p_surface.instanced, p_source, pipeline_key, r_pipeline_pairs);
	}

	// The dedicated depth passes use a different version of the surface and the shader.
	pipeline_key.primitive_type = mesh_storage->mesh_surface_get_primitive(p_surface.mesh_surface_shadow);
	pipeline_key.version = SceneShaderFRPClustered::PIPELINE_VERSION_DEPTH_PASS;
	pipeline_key.framebuffer_format_id = _get_depth_framebuffer_format_for_pipeline(buffers_can_be_storage, RD::TextureSamples(p_global.texture_samples), false);
	_mesh_compile_pipeline_for_surface(p_surface.shader_shadow, p_surface.mesh_surface_shadow, true, p_surface.instanced, p_source, pipeline_key, r_pipeline_pairs);

	if (p_global.use_shadow_dual_paraboloid) {
		pipeline_key.version = SceneShaderFRPClustered::PIPELINE_VERSION_DEPTH_PASS_DP;
		_mesh_compile_pipeline_for_surface(p_surface.shader_shadow, p_surface.mesh_surface_shadow, true, p_surface.instanced, p_source, pipeline_key, r_pipeline_pairs);
	}

	if (p_global.use_shadow_cubemaps) {
		pipeline_key.version = SceneShaderFRPClustered::PIPELINE_VERSION_DEPTH_PASS;
		pipeline_key.framebuffer_format_id = _get_shadow_cubemap_framebuffer_format_for_pipeline();
		_mesh_compile_pipeline_for_surface(p_surface.shader_shadow, p_surface.mesh_surface_shadow, true, p_surface.instanced, p_source, pipeline_key, r_pipeline_pairs);
	}

	// Atlas shadowmaps (omni lights) can be in both 16-bit and 32-bit versions.
	const uint32_t use_16_bits_start = p_global.use_32_bit_shadows ? 0 : 1;
	const uint32_t use_16_bits_iterations = p_global.use_16_bit_shadows ? 2 : 1;
	for (uint32_t use_16_bits = use_16_bits_start; use_16_bits < use_16_bits_iterations; use_16_bits++) {
		pipeline_key.version = SceneShaderFRPClustered::PIPELINE_VERSION_DEPTH_PASS;
		pipeline_key.framebuffer_format_id = _get_shadow_atlas_framebuffer_format_for_pipeline(use_16_bits);
		_mesh_compile_pipeline_for_surface(p_surface.shader_shadow, p_surface.mesh_surface_shadow, true, p_surface.instanced, p_source, pipeline_key, r_pipeline_pairs);

		if (p_global.use_shadow_dual_paraboloid) {
			pipeline_key.version = SceneShaderFRPClustered::PIPELINE_VERSION_DEPTH_PASS_DP;
			_mesh_compile_pipeline_for_surface(p_surface.shader_shadow, p_surface.mesh_surface_shadow, true, p_surface.instanced, p_source, pipeline_key, r_pipeline_pairs);
		}
	}

	if (p_global.use_reflection_probes) {
		// Depth pass for reflection probes. Normally this will be redundant as the format is the exact same as the shadow cubemap.
		pipeline_key.version = SceneShaderFRPClustered::PIPELINE_VERSION_DEPTH_PASS;
		pipeline_key.framebuffer_format_id = _get_reflection_probe_depth_framebuffer_format_for_pipeline();
		_mesh_compile_pipeline_for_surface(p_surface.shader_shadow, p_surface.mesh_surface_shadow, true, p_surface.instanced, p_source, pipeline_key, r_pipeline_pairs);
	}
}

void RenderFRPClustered::_mesh_generate_all_pipelines_for_surface_cache(GeometryInstanceSurfaceDataCache *p_surface_cache, const GlobalPipelineData &p_global) {
	bool uses_alpha_pass = (p_surface_cache->flags & GeometryInstanceSurfaceDataCache::FLAG_PASS_ALPHA) != 0;
	float multiplied_fade_alpha = p_surface_cache->owner->force_alpha * p_surface_cache->owner->parent_fade_alpha;
	bool uses_fade = (multiplied_fade_alpha < FADE_ALPHA_PASS_THRESHOLD) || p_surface_cache->owner->fade_near || p_surface_cache->owner->fade_far;
	SurfacePipelineData surface;
	surface.mesh_surface = p_surface_cache->surface;
	surface.mesh_surface_shadow = p_surface_cache->surface_shadow;
	surface.shader = p_surface_cache->shader;
	surface.shader_shadow = p_surface_cache->shader_shadow;
	surface.instanced = p_surface_cache->owner->mesh_instance.is_valid();
	surface.uses_opaque = !uses_alpha_pass;
	surface.uses_transparent = uses_alpha_pass || uses_fade;
	surface.uses_depth = (p_surface_cache->flags & (GeometryInstanceSurfaceDataCache::FLAG_PASS_DEPTH | GeometryInstanceSurfaceDataCache::FLAG_PASS_OPAQUE | GeometryInstanceSurfaceDataCache::FLAG_PASS_SHADOW)) != 0;
	surface.can_use_lightmap = p_surface_cache->owner->lightmap_instance.is_valid() || p_surface_cache->owner->lightmap_sh;
	_mesh_compile_pipelines_for_surface(surface, p_global, RSE::PIPELINE_SOURCE_SURFACE);
}

void RenderFRPClustered::_update_dirty_geometry_instances() {
	while (geometry_instance_dirty_list.first()) {
		_geometry_instance_update(geometry_instance_dirty_list.first()->self());
	}

	_update_dirty_geometry_pipelines();
}

void RenderFRPClustered::_update_dirty_geometry_pipelines() {
	if (global_pipeline_data_required.key != global_pipeline_data_compiled.key) {
		// Go through the entire list of surfaces and compile pipelines for everything again.
		SelfList<GeometryInstanceSurfaceDataCache> *list = geometry_surface_compilation_all_list.first();
		while (list != nullptr) {
			GeometryInstanceSurfaceDataCache *surface_cache = list->self();
			_mesh_generate_all_pipelines_for_surface_cache(surface_cache, global_pipeline_data_required);

			if (surface_cache->compilation_dirty_element.in_list()) {
				// Remove any elements from the dirty list as they don't need to be processed again.
				geometry_surface_compilation_dirty_list.remove(&surface_cache->compilation_dirty_element);
			}

			list = list->next();
		}

		global_pipeline_data_compiled.key = global_pipeline_data_required.key;
	} else {
		// Compile pipelines only for the dirty list.
		if (!geometry_surface_compilation_dirty_list.first()) {
			return;
		}

		while (geometry_surface_compilation_dirty_list.first() != nullptr) {
			GeometryInstanceSurfaceDataCache *surface_cache = geometry_surface_compilation_dirty_list.first()->self();
			_mesh_generate_all_pipelines_for_surface_cache(surface_cache, global_pipeline_data_compiled);
			surface_cache->compilation_dirty_element.remove_from_list();
		}
	}
}

void RenderFRPClustered::_geometry_instance_dependency_changed(Dependency::DependencyChangedNotification p_notification, DependencyTracker *p_tracker) {
	switch (p_notification) {
		case Dependency::DEPENDENCY_CHANGED_MATERIAL:
		case Dependency::DEPENDENCY_CHANGED_MESH:
		case Dependency::DEPENDENCY_CHANGED_PARTICLES:
		case Dependency::DEPENDENCY_CHANGED_PARTICLES_INSTANCES:
		case Dependency::DEPENDENCY_CHANGED_MULTIMESH:
		case Dependency::DEPENDENCY_CHANGED_SKELETON_DATA: {
			static_cast<RenderGeometryInstance *>(p_tracker->userdata)->_mark_dirty();
			static_cast<GeometryInstanceFRPClustered *>(p_tracker->userdata)->data->dirty_dependencies = true;
		} break;
		case Dependency::DEPENDENCY_CHANGED_MULTIMESH_VISIBLE_INSTANCES: {
			GeometryInstanceFRPClustered *ginstance = static_cast<GeometryInstanceFRPClustered *>(p_tracker->userdata);
			if (ginstance->data->base_type == RSE::INSTANCE_MULTIMESH) {
				ginstance->instance_count = RendererRD::MeshStorage::get_singleton()->multimesh_get_instances_to_draw(ginstance->data->base);
			}
		} break;
		default: {
			//rest of notifications of no interest
		} break;
	}
}
void RenderFRPClustered::_geometry_instance_dependency_deleted(const RID &p_dependency, DependencyTracker *p_tracker) {
	static_cast<RenderGeometryInstance *>(p_tracker->userdata)->_mark_dirty();
	static_cast<GeometryInstanceFRPClustered *>(p_tracker->userdata)->data->dirty_dependencies = true;
}

RenderGeometryInstance *RenderFRPClustered::geometry_instance_create(RID p_base) {
	RSE::InstanceType type = RSG::utilities->get_base_type(p_base);
	ERR_FAIL_COND_V(!((1 << type) & RSE::INSTANCE_GEOMETRY_MASK), nullptr);

	GeometryInstanceFRPClustered *ginstance = geometry_instance_alloc.alloc();
	ginstance->data = memnew(GeometryInstanceFRPClustered::Data);

	ginstance->data->base = p_base;
	ginstance->data->base_type = type;
	ginstance->data->dependency_tracker.userdata = ginstance;
	ginstance->data->dependency_tracker.changed_callback = _geometry_instance_dependency_changed;
	ginstance->data->dependency_tracker.deleted_callback = _geometry_instance_dependency_deleted;

	ginstance->_mark_dirty();

	return ginstance;
}

void RenderFRPClustered::GeometryInstanceFRPClustered::set_transform(const Transform3D &p_transform, const AABB &p_aabb, const AABB &p_transformed_aabb) {
	uint64_t frame = RSG::rasterizer->get_frame_number();
	if (frame != prev_transform_change_frame) {
		prev_transform = transform;
		prev_transform_change_frame = frame;
		transform_status = TransformStatus::MOVED;
	} else if (unlikely(transform_status == TransformStatus::TELEPORTED)) {
		prev_transform = transform;
	}

	RenderGeometryInstanceBase::set_transform(p_transform, p_aabb, p_transformed_aabb);
}

void RenderFRPClustered::GeometryInstanceFRPClustered::reset_motion_vectors() {
	prev_transform = transform;
	transform_status = TransformStatus::TELEPORTED;
}

void RenderFRPClustered::GeometryInstanceFRPClustered::set_use_lightmap(RID p_lightmap_instance, const Rect2 &p_lightmap_uv_scale, int p_lightmap_slice_index) {
	lightmap_instance = p_lightmap_instance;
	lightmap_uv_scale = p_lightmap_uv_scale;
	lightmap_slice_index = p_lightmap_slice_index;

	_mark_dirty();
}

void RenderFRPClustered::GeometryInstanceFRPClustered::set_lightmap_capture(const Color *p_sh9) {
	if (p_sh9) {
		if (lightmap_sh == nullptr) {
			lightmap_sh = RenderFRPClustered::get_singleton()->geometry_instance_lightmap_sh.alloc();
		}

		memcpy(lightmap_sh->sh, p_sh9, sizeof(Color) * 9);
	} else {
		if (lightmap_sh != nullptr) {
			RenderFRPClustered::get_singleton()->geometry_instance_lightmap_sh.free(lightmap_sh);
			lightmap_sh = nullptr;
		}
	}
	_mark_dirty();
}

void RenderFRPClustered::geometry_instance_free(RenderGeometryInstance *p_geometry_instance) {
	GeometryInstanceFRPClustered *ginstance = static_cast<GeometryInstanceFRPClustered *>(p_geometry_instance);
	ERR_FAIL_NULL(ginstance);
	if (ginstance->lightmap_sh != nullptr) {
		geometry_instance_lightmap_sh.free(ginstance->lightmap_sh);
	}
	GeometryInstanceSurfaceDataCache *surf = ginstance->surface_caches;
	while (surf) {
		GeometryInstanceSurfaceDataCache *next = surf->next;
		geometry_instance_surface_alloc.free(surf);
		surf = next;
	}
	memdelete(ginstance->data);
	geometry_instance_alloc.free(ginstance);
}

uint32_t RenderFRPClustered::geometry_instance_get_pair_mask() {
	return (1 << RSE::INSTANCE_VOXEL_GI);
}

void RenderFRPClustered::mesh_generate_pipelines(RID p_mesh, bool p_background_compilation) {
	RendererRD::MaterialStorage *material_storage = RendererRD::MaterialStorage::get_singleton();
	RendererRD::MeshStorage *mesh_storage = RendererRD::MeshStorage::get_singleton();
	RID shadow_mesh = mesh_storage->mesh_get_shadow_mesh(p_mesh);
	uint32_t surface_count = 0;
	const RID *materials = mesh_storage->mesh_get_surface_count_and_materials(p_mesh, surface_count);
	Vector<ShaderPipelinePair> pipeline_pairs;
	for (uint32_t i = 0; i < surface_count; i++) {
		if (materials[i].is_null()) {
			continue;
		}

		void *mesh_surface = mesh_storage->mesh_get_surface(p_mesh, i);
		void *mesh_surface_shadow = mesh_surface;
		SceneShaderFRPClustered::MaterialData *material = static_cast<SceneShaderFRPClustered::MaterialData *>(material_storage->material_get_data(materials[i], RendererRD::MaterialStorage::SHADER_TYPE_3D));
		if (material == nullptr || !material->shader_data->is_valid()) {
			continue;
		}

		SceneShaderFRPClustered::ShaderData *shader = material->shader_data;
		SceneShaderFRPClustered::ShaderData *shader_shadow = shader;
		if (material->shader_data->uses_shared_shadow_material()) {
			SceneShaderFRPClustered::MaterialData *material_shadow = static_cast<SceneShaderFRPClustered::MaterialData *>(material_storage->material_get_data(scene_shader.default_material, RendererRD::MaterialStorage::SHADER_TYPE_3D));
			if (material_shadow != nullptr) {
				shader_shadow = material_shadow->shader_data;
				if (shadow_mesh.is_valid()) {
					mesh_surface_shadow = mesh_storage->mesh_get_surface(shadow_mesh, i);
				}
			}
		}

		if (!shader->is_valid()) {
			continue;
		}

		SurfacePipelineData surface;
		surface.mesh_surface = mesh_surface;
		surface.mesh_surface_shadow = mesh_surface_shadow;
		surface.shader = shader;
		surface.shader_shadow = shader_shadow;
		surface.instanced = mesh_storage->mesh_needs_instance(p_mesh, true);
		surface.uses_opaque = !material->shader_data->uses_alpha_pass();
		surface.uses_transparent = material->shader_data->uses_alpha_pass();
		surface.uses_depth = surface.uses_opaque || (surface.uses_transparent && material->shader_data->uses_depth_in_alpha_pass());
		surface.can_use_lightmap = mesh_storage->mesh_surface_get_format(mesh_surface) & RSE::ARRAY_FORMAT_TEX_UV2;
		_mesh_compile_pipelines_for_surface(surface, global_pipeline_data_required, RSE::PIPELINE_SOURCE_MESH, &pipeline_pairs);
	}

	// Wait for all the pipelines that were compiled. This will force the loader to wait on all ubershader pipelines to be ready.
	if (!p_background_compilation && !pipeline_pairs.is_empty()) {
		for (ShaderPipelinePair pair : pipeline_pairs) {
			pair.first->pipeline_hash_map.wait_for_pipeline(pair.second.hash());
		}
	}
}

uint32_t RenderFRPClustered::get_pipeline_compilations(RSE::PipelineSource p_source) {
	return scene_shader.get_pipeline_compilations(p_source);
}

void RenderFRPClustered::enable_features(BitField<FeatureBits> p_feature_bits) {
	if (p_feature_bits.has_flag(FEATURE_MULTIVIEW_BIT)) {
		scene_shader.enable_multiview_shader_group();
	}

	if (p_feature_bits.has_flag(FEATURE_ADVANCED_BIT)) {
		scene_shader.enable_advanced_shader_group(p_feature_bits.has_flag(FEATURE_MULTIVIEW_BIT));
	}

	if (p_feature_bits.has_flag(FEATURE_VRS_BIT)) {
		// FRP has no VRS-dependent GI shader to enable here; the scene shader group is
		// the only one FRP compiles.
	}
}

String RenderFRPClustered::get_name() const {
	return "frp_clustered";
}

void RenderFRPClustered::GeometryInstanceFRPClustered::set_softshadow_projector_pairing(bool p_softshadow, bool p_projector) {
	using_projectors = p_projector;
	using_softshadows = p_softshadow;
	_mark_dirty();
}

void RenderFRPClustered::_update_shader_quality_settings() {
	SceneShaderFRPClustered::ShaderSpecialization specialization = {};
	specialization.decal_use_mipmaps = decals_get_filter() == RSE::DECAL_FILTER_NEAREST_MIPMAPS ||
			decals_get_filter() == RSE::DECAL_FILTER_LINEAR_MIPMAPS ||
			decals_get_filter() == RSE::DECAL_FILTER_NEAREST_MIPMAPS_ANISOTROPIC ||
			decals_get_filter() == RSE::DECAL_FILTER_LINEAR_MIPMAPS_ANISOTROPIC;
	;
	specialization.projector_use_mipmaps = light_projectors_get_filter() == RSE::LIGHT_PROJECTOR_FILTER_NEAREST_MIPMAPS ||
			light_projectors_get_filter() == RSE::LIGHT_PROJECTOR_FILTER_LINEAR_MIPMAPS ||
			light_projectors_get_filter() == RSE::LIGHT_PROJECTOR_FILTER_NEAREST_MIPMAPS_ANISOTROPIC ||
			light_projectors_get_filter() == RSE::LIGHT_PROJECTOR_FILTER_LINEAR_MIPMAPS_ANISOTROPIC;

	specialization.soft_shadow_samples = soft_shadow_samples_get();
	specialization.penumbra_shadow_samples = penumbra_shadow_samples_get();
	specialization.directional_soft_shadow_samples = directional_soft_shadow_samples_get();
	specialization.directional_penumbra_shadow_samples = directional_penumbra_shadow_samples_get();
	specialization.use_lightmap_bicubic_filter = lightmap_filter_bicubic_get();
	specialization.fog_use_legacy_blending = fog_use_legacy_blending_get();
	scene_shader.set_default_specialization(specialization);

	base_uniforms_changed(); //also need this
}

RenderFRPClustered::RenderFRPClustered() {
	singleton = this;

	/* SCENE SHADER */

	{
		String defines;
		defines += "\n#define MAX_ROUGHNESS_LOD " + itos(get_roughness_layers() - 1) + ".0\n";
		if (is_using_radiance_octmap_array()) {
			defines += "\n#define USE_RADIANCE_OCTMAP_ARRAY \n";
		}
		defines += "\n#define MAX_DIRECTIONAL_LIGHT_DATA_STRUCTS " + itos(MAX_DIRECTIONAL_LIGHTS) + "\n";

		bool force_vertex_shading = GLOBAL_GET("rendering/shading/overrides/force_vertex_shading");
		if (force_vertex_shading) {
			defines += "\n#define USE_VERTEX_LIGHTING\n";
		}

		bool specular_occlusion = GLOBAL_GET("rendering/reflections/specular_occlusion/enabled");
		if (!specular_occlusion) {
			defines += "\n#define SPECULAR_OCCLUSION_DISABLED\n";
		}

		{
			//lightmaps
			scene_state.max_lightmaps = MAX_LIGHTMAPS;
			defines += "\n#define MAX_LIGHTMAP_TEXTURES " + itos(scene_state.max_lightmaps) + "\n";
			defines += "\n#define MAX_LIGHTMAPS " + itos(scene_state.max_lightmaps) + "\n";

			scene_state.lightmap_buffer = RD::get_singleton()->storage_buffer_create(sizeof(LightmapData) * scene_state.max_lightmaps);
		}
		{
			//captures
			scene_state.max_lightmap_captures = 2048;
			scene_state.lightmap_captures = memnew_arr(LightmapCaptureData, scene_state.max_lightmap_captures);
			scene_state.lightmap_capture_buffer = RD::get_singleton()->storage_buffer_create(sizeof(LightmapCaptureData) * scene_state.max_lightmap_captures);
		}
		{
			defines += "\n#define MATERIAL_UNIFORM_SET " + itos(MATERIAL_UNIFORM_SET) + "\n";
		}
#ifdef REAL_T_IS_DOUBLE
		{
			defines += "\n#define USE_DOUBLE_PRECISION \n";
		}
#endif

		scene_shader.init(defines);
	}

	/* shadow sampler */
	{
		RD::SamplerState sampler;
		sampler.mag_filter = RD::SAMPLER_FILTER_NEAREST;
		sampler.min_filter = RD::SAMPLER_FILTER_NEAREST;
		sampler.enable_compare = true;
		sampler.compare_op = RD::COMPARE_OP_GREATER;
		shadow_sampler = RD::get_singleton()->sampler_create(sampler);
	}

	{
		Vector<String> modes;
		modes.push_back("\n");
		best_fit_normal.shader.initialize(modes);
		best_fit_normal.shader_version = best_fit_normal.shader.version_create();
		best_fit_normal.pipeline = RD::get_singleton()->compute_pipeline_create(best_fit_normal.shader.version_get_shader(best_fit_normal.shader_version, 0));

		RD::TextureFormat tformat;
		tformat.format = RD::DATA_FORMAT_R8_UNORM;
		tformat.width = 1024;
		tformat.height = 1024;
		tformat.usage_bits = RD::TEXTURE_USAGE_SAMPLING_BIT | RD::TEXTURE_USAGE_STORAGE_BIT;
		tformat.texture_type = RD::TEXTURE_TYPE_2D;
		best_fit_normal.texture = RD::get_singleton()->texture_create(tformat, RD::TextureView());

		RID shader = best_fit_normal.shader.version_get_shader(best_fit_normal.shader_version, 0);
		ERR_FAIL_COND(shader.is_null());

		Vector<RD::Uniform> uniforms;

		{
			RD::Uniform u;
			u.binding = 0;
			u.uniform_type = RD::UNIFORM_TYPE_IMAGE;
			u.append_id(best_fit_normal.texture);
			uniforms.push_back(u);
		}
		RID uniform_set = RD::get_singleton()->uniform_set_create(uniforms, shader, 0);

		RD::ComputeListID compute_list = RD::get_singleton()->compute_list_begin();
		RD::get_singleton()->compute_list_bind_compute_pipeline(compute_list, best_fit_normal.pipeline);
		RD::get_singleton()->compute_list_bind_uniform_set(compute_list, uniform_set, 0);
		RD::get_singleton()->compute_list_dispatch_threads(compute_list, tformat.width, tformat.height, 1);
		RD::get_singleton()->compute_list_end();
	}

	/* DFG LUT */
	{
		Vector<String> modes;
		modes.push_back("\n");
		dfg_lut.shader.initialize(modes);
		dfg_lut.shader_version = dfg_lut.shader.version_create();
		dfg_lut.pipeline = RD::get_singleton()->compute_pipeline_create(dfg_lut.shader.version_get_shader(dfg_lut.shader_version, 0));

		RD::TextureFormat tformat;
		tformat.format = RD::DATA_FORMAT_R16G16B16A16_SFLOAT;
		tformat.width = 128;
		tformat.height = 128;
		tformat.usage_bits = RD::TEXTURE_USAGE_SAMPLING_BIT | RD::TEXTURE_USAGE_STORAGE_BIT;
		tformat.texture_type = RD::TEXTURE_TYPE_2D;
		dfg_lut.texture = RD::get_singleton()->texture_create(tformat, RD::TextureView());

		RID shader = dfg_lut.shader.version_get_shader(dfg_lut.shader_version, 0);
		ERR_FAIL_COND(shader.is_null());

		Vector<RD::Uniform> uniforms;

		{
			RD::Uniform u;
			u.binding = 0;
			u.uniform_type = RD::UNIFORM_TYPE_IMAGE;
			u.append_id(dfg_lut.texture);
			uniforms.push_back(u);
		}
		RID uniform_set = RD::get_singleton()->uniform_set_create(uniforms, shader, 0);

		RD::ComputeListID compute_list = RD::get_singleton()->compute_list_begin();
		RD::get_singleton()->compute_list_bind_compute_pipeline(compute_list, dfg_lut.pipeline);
		RD::get_singleton()->compute_list_bind_uniform_set(compute_list, uniform_set, 0);
		RD::get_singleton()->compute_list_dispatch_threads(compute_list, tformat.width, tformat.height, 1);
		RD::get_singleton()->compute_list_end();
	}

	/* FRP lighting pass */
	{
		String defines;
		defines += "\n#define MAX_ROUGHNESS_LOD " + itos(get_roughness_layers() - 1) + ".0\n";
		if (is_using_radiance_octmap_array()) {
			defines += "\n#define USE_RADIANCE_OCTMAP_ARRAY \n";
		}
		defines += "\n#define MAX_DIRECTIONAL_LIGHT_DATA_STRUCTS " + itos(MAX_DIRECTIONAL_LIGHTS) + "\n";
		defines += "\n#define MAX_LIGHTMAP_TEXTURES " + itos(scene_state.max_lightmaps) + "\n";
		defines += "\n#define MAX_LIGHTMAPS " + itos(scene_state.max_lightmaps) + "\n";
#ifdef REAL_T_IS_DOUBLE
		defines += "\n#define USE_DOUBLE_PRECISION \n";
#endif

		Vector<String> modes;
		modes.push_back(defines + "\n"); // FRP_LIGHTING_MODE_BASE
		modes.push_back(defines + "\n#define MODE_SEPARATE_SPECULAR\n"); // FRP_LIGHTING_MODE_SEPARATE_SPECULAR
		modes.push_back(defines + "\n#define USE_MULTIVIEW\n"); // FRP_LIGHTING_MODE_MULTIVIEW
		modes.push_back(defines + "\n#define MODE_SEPARATE_SPECULAR\n#define USE_MULTIVIEW\n"); // FRP_LIGHTING_MODE_SEPARATE_SPECULAR_MULTIVIEW

		frp_lighting.shader.initialize(modes);
		frp_lighting.shader_version = frp_lighting.shader.version_create();

		for (int i = 0; i < FRP_LIGHTING_MODE_MAX; i++) {
			RID shader = frp_lighting.shader.version_get_shader(frp_lighting.shader_version, i);
			ERR_FAIL_COND(shader.is_null());
			// The lighting pass can render to color + separate specular + motion vectors (3 attachments).
			frp_lighting.pipelines[i].setup(shader, RD::RENDER_PRIMITIVE_TRIANGLES, RD::PipelineRasterizationState(), RD::PipelineMultisampleState(), RD::PipelineDepthStencilState(), RD::PipelineColorBlendState::create_disabled(3));
		}
	}

	_update_shader_quality_settings();
	_update_global_pipeline_data_requirements_from_project();

	taa = memnew(RendererRD::TAA);
	fsr2_effect = memnew(RendererRD::FSR2Effect);
	ss_effects = memnew(RendererRD::SSEffects);
	{
		Vector<String> modes;
		modes.push_back("\n");
		velocity_fill.shader.initialize(modes);
		velocity_fill.shader_version = velocity_fill.shader.version_create();
		velocity_fill.pipeline = RD::get_singleton()->compute_pipeline_create(velocity_fill.shader.version_get_shader(velocity_fill.shader_version, 0));
	}
#ifdef METAL_MFXTEMPORAL_ENABLED
	motion_vectors_store = memnew(RendererRD::MotionVectorsStore);
	mfx_temporal_effect = memnew(RendererRD::MFXTemporalEffect);
#endif
}

RenderFRPClustered::~RenderFRPClustered() {
	if (ss_effects != nullptr) {
		memdelete(ss_effects);
		ss_effects = nullptr;
	}

	if (taa != nullptr) {
		memdelete(taa);
		taa = nullptr;
	}

	if (fsr2_effect) {
		memdelete(fsr2_effect);
		fsr2_effect = nullptr;
	}

#ifdef METAL_MFXTEMPORAL_ENABLED
	if (mfx_temporal_effect) {
		memdelete(mfx_temporal_effect);
		mfx_temporal_effect = nullptr;
	}

	if (motion_vectors_store) {
		memdelete(motion_vectors_store);
		motion_vectors_store = nullptr;
	}
#endif

	RD::get_singleton()->free_rid(shadow_sampler);
	RSG::light_storage->directional_shadow_atlas_set_size(0);

	RD::get_singleton()->free_rid(velocity_fill.pipeline);
	velocity_fill.shader.version_free(velocity_fill.shader_version);

	RD::get_singleton()->free_rid(best_fit_normal.pipeline);
	RD::get_singleton()->free_rid(best_fit_normal.texture);
	best_fit_normal.shader.version_free(best_fit_normal.shader_version);

	RD::get_singleton()->free_rid(dfg_lut.pipeline);
	RD::get_singleton()->free_rid(dfg_lut.texture);
	dfg_lut.shader.version_free(dfg_lut.shader_version);

	frp_lighting.shader.version_free(frp_lighting.shader_version);

	if (ltc.lut1_texture.is_valid()) {
		RS::get_singleton()->free_rid(ltc.lut1_texture);
	}
	if (ltc.lut2_texture.is_valid()) {
		RS::get_singleton()->free_rid(ltc.lut2_texture);
	}

	{
		for (const RID &rid : scene_state.uniform_buffers) {
			RD::get_singleton()->free_rid(rid);
		}
		for (const RID &rid : scene_state.implementation_uniform_buffers) {
			RD::get_singleton()->free_rid(rid);
		}
		RD::get_singleton()->free_rid(scene_state.lightmap_buffer);
		RD::get_singleton()->free_rid(scene_state.lightmap_capture_buffer);
		for (uint32_t i = 0; i < RENDER_LIST_MAX; i++) {
			scene_state.instance_buffer[i].uninit();
		}
		memdelete_arr(scene_state.lightmap_captures);
	}

}
