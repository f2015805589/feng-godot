/**************************************************************************/
/*  frp_pass_context.cpp                                                  */
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

#include "frp_pass_context.h"

#include "core/io/marshalls.h"
#include "core/object/class_db.h"
#include "core/object/callable_mp.h"
#include "servers/rendering/rendering_device.h"
#include "servers/rendering/renderer_rd/storage_rd/render_data_rd.h"
#include "servers/rendering/renderer_rd/storage_rd/render_scene_buffers_rd.h"

namespace {
Mutex sky_lighting_sources_mutex;
HashMap<RID, FRPPassContext::SkyLightingSource> sky_lighting_sources;
}

void FRPPassContext::set_sky_lighting_source(RID p_render_target, uint64_t p_owner_id, RID p_sky, float p_energy, const Basis &p_rotation, float p_captured_exposure, uint64_t p_revision) {
	ERR_FAIL_COND(p_render_target.is_null());
	ERR_FAIL_COND(p_owner_id == 0);
	ERR_FAIL_COND(p_sky.is_null());
	MutexLock lock(sky_lighting_sources_mutex);
	SkyLightingSource source;
	source.owner_id = p_owner_id;
	source.sky = p_sky;
	source.energy = p_energy;
	source.rotation = p_rotation;
	source.captured_exposure = Math::is_finite(p_captured_exposure) && p_captured_exposure > 0.0f ? p_captured_exposure : 1.0f;
	source.revision = p_revision;
	sky_lighting_sources.insert(p_render_target, source);
}

void FRPPassContext::clear_sky_lighting_source(RID p_render_target, uint64_t p_owner_id) {
	MutexLock lock(sky_lighting_sources_mutex);
	SkyLightingSource *source = sky_lighting_sources.getptr(p_render_target);
	if (source && source->owner_id == p_owner_id) {
		sky_lighting_sources.erase(p_render_target);
	}
}

void FRPPassContext::clear_all_sky_lighting_sources() {
	MutexLock lock(sky_lighting_sources_mutex);
	sky_lighting_sources.clear();
}

bool FRPPassContext::get_sky_lighting_source(RID p_render_target, SkyLightingSource &r_source) {
	MutexLock lock(sky_lighting_sources_mutex);
	const SkyLightingSource *source = sky_lighting_sources.getptr(p_render_target);
	if (!source) {
		return false;
	}
	r_source = *source;
	return true;
}

void FRPPassContext::setup(RenderDataRD *p_render_data, const std::function<void(int)> &p_operation_runner, const std::function<void(int)> &p_stage_runner, const Dictionary &p_pass_parameters, const std::function<void(const StringName &)> &p_present_runner, const std::function<float(int)> &p_pre_exposure_reader, const std::function<void(int, float)> &p_pre_exposure_writer, const std::function<void(RID)> &p_eye_exposure_texture_writer) {
	render_data = p_render_data;
	operation_runner = p_operation_runner;
	stage_runner = p_stage_runner;
	present_runner = p_present_runner;
	pre_exposure_reader = p_pre_exposure_reader;
	pre_exposure_writer = p_pre_exposure_writer;
	eye_exposure_texture_writer = p_eye_exposure_texture_writer;
	pass_parameters = p_pass_parameters;
	height_fog_parameters.clear();
	atmosphere_parameters.clear();
	atmosphere_light_rids[0] = RID();
	atmosphere_light_rids[1] = RID();
	atmosphere_optical_texture = RID();
	atmosphere_multiple_texture = RID();
}

float FRPPassContext::get_pre_exposure(int p_view) const {
	return pre_exposure_reader ? pre_exposure_reader(p_view) : 1.0f;
}

void FRPPassContext::set_next_pre_exposure(int p_view, float p_exposure) {
	if (pre_exposure_writer) {
		pre_exposure_writer(p_view, p_exposure);
	}
}

void FRPPassContext::set_height_fog_parameters(const PackedFloat32Array &p_parameters) {
	// The payload is camera position plus the six vec4s used by the existing
	// Feng Height Fog compute pass. Keep the render-thread handoff typed and
	// bounded instead of retaining a script resource or a general Dictionary.
	if (p_parameters.is_empty()) {
		height_fog_parameters.clear();
		return;
	}
	ERR_FAIL_COND_MSG(p_parameters.size() != 28, "Height Fog parameters must contain 28 floats.");
	height_fog_parameters = p_parameters;
}

void FRPPassContext::set_atmosphere_parameters(const PackedFloat32Array &p_parameters, RID p_light, RID p_secondary_light, RID p_optical_texture, RID p_multiple_texture) {
	// Clear first: an invalid payload must not leave an earlier world's state.
	atmosphere_parameters.clear();
	atmosphere_light_rids[0] = RID();
	atmosphere_light_rids[1] = RID();
	atmosphere_optical_texture = RID();
	atmosphere_multiple_texture = RID();
	if (p_parameters.is_empty()) {
		return;
	}
	ERR_FAIL_COND_MSG(p_parameters.size() != 64, "Atmosphere parameters must contain sixteen vec4 values.");
	for (float value : p_parameters) {
		ERR_FAIL_COND_MSG(!Math::is_finite(value), "Atmosphere parameters must be finite.");
	}
	atmosphere_parameters = p_parameters;
	atmosphere_light_rids[0] = p_light;
	atmosphere_light_rids[1] = p_secondary_light;
	atmosphere_optical_texture = p_optical_texture;
	atmosphere_multiple_texture = p_multiple_texture;
}

void FRPPassContext::set_tonemap_exposure_texture(RID p_texture) {
	if (eye_exposure_texture_writer) {
		eye_exposure_texture_writer(p_texture);
	}
}

void FRPPassContext::_finish_pre_exposure_readback(const PackedByteArray &p_data, const Ref<FRPPassContext> &p_context, int p_view) {
	if (p_data.size() < int(sizeof(float)) || p_context.is_null()) {
		return;
	}
	const float exposure = decode_float(p_data.ptr());
	if (Math::is_finite(exposure) && exposure > 0.0f) {
		p_context->set_next_pre_exposure(p_view, exposure);
	}
}

Error FRPPassContext::request_next_pre_exposure(RID p_buffer, int p_view, int p_offset) {
	ERR_FAIL_COND_V(p_offset < 0 || !p_buffer.is_valid(), ERR_INVALID_PARAMETER);
	RD *rd = RD::get_singleton();
	ERR_FAIL_NULL_V(rd, ERR_UNAVAILABLE);
	return rd->buffer_get_data_async(p_buffer, callable_mp_static(&FRPPassContext::_finish_pre_exposure_readback).bind(Ref<FRPPassContext>(this), p_view), p_offset, sizeof(float));
}

Dictionary FRPPassContext::get_pass_parameters(const Variant &p_pass_id) const {
	const Variant parameters = pass_parameters.get(p_pass_id, Variant());
	if (parameters.get_type() == Variant::DICTIONARY) {
		return parameters;
	}
	return Dictionary();
}

void FRPPassContext::_run_operation(int p_operation) {
	ERR_FAIL_NULL_MSG(render_data, "FRP pass context used outside of an FRP frame.");
	ERR_FAIL_COND_MSG(!operation_runner, "FRP pass context has no operation runner.");
	operation_runner(p_operation);
}

Ref<RenderSceneBuffersRD> FRPPassContext::get_render_scene_buffers() const {
	return render_data != nullptr ? render_data->render_buffers : Ref<RenderSceneBuffersRD>();
}

int FRPPassContext::get_view_count() const {
	Ref<RenderSceneBuffersRD> buffers = get_render_scene_buffers();
	return buffers.is_valid() ? int(buffers->get_view_count()) : 0;
}

Vector2i FRPPassContext::get_internal_size() const {
	Ref<RenderSceneBuffersRD> buffers = get_render_scene_buffers();
	return buffers.is_valid() ? Vector2i(buffers->get_internal_size()) : Vector2i();
}

String FRPPassContext::get_pass_name(int p_pass_id) const {
	return FRPPipelineSpec::is_valid_pass_id(p_pass_id) ? String(FRPPipelineSpec::native_pass_name(p_pass_id)) : String();
}

bool FRPPassContext::is_valid_pass_id(int p_pass_id) const {
	return FRPPipelineSpec::is_valid_pass_id(p_pass_id);
}

void FRPPassContext::precompute_shadows() {
	_run_operation(FRPPipelineSpec::OP_SHADOW_PRECOMPUTE);
}

void FRPPassContext::execute_virtual_texture_updates() {
	_run_operation(FRPPipelineSpec::OP_VIRTUAL_TEXTURE);
}

void FRPPassContext::prepare_lighting() {
	_run_operation(FRPPipelineSpec::OP_LIGHTING_PREPARE);
}

void FRPPassContext::draw_gbuffer() {
	_run_operation(FRPPipelineSpec::OP_GBUFFER);
}

void FRPPassContext::draw_motion_vectors() {
	_run_operation(FRPPipelineSpec::OP_MOTION_VECTORS);
}

void FRPPassContext::draw_deferred_lighting() {
	_run_operation(FRPPipelineSpec::OP_DEFERRED_LIGHTING);
}

void FRPPassContext::merge_subsurface_and_specular() {
	_run_operation(FRPPipelineSpec::OP_SUBSURFACE_AND_SPECULAR);
}

void FRPPassContext::resolve_opaque() {
	_run_operation(FRPPipelineSpec::OP_OPAQUE_RESOLVE);
}

void FRPPassContext::draw_sky() {
	_run_operation(FRPPipelineSpec::OP_SKY);
}

void FRPPassContext::resolve_sky() {
	_run_operation(FRPPipelineSpec::OP_SKY_RESOLVE);
}

void FRPPassContext::draw_opaque_fallback() {
	_run_operation(FRPPipelineSpec::OP_OPAQUE_FORWARD_FALLBACK);
}

void FRPPassContext::copy_screen_and_depth() {
	_run_operation(FRPPipelineSpec::OP_SCREEN_AND_DEPTH_COPY);
}

void FRPPassContext::draw_transparent() {
	_run_operation(FRPPipelineSpec::OP_TRANSPARENT);
}

void FRPPassContext::temporal_aa_and_upscale() {
	_run_operation(FRPPipelineSpec::OP_TEMPORAL_AA);
}

void FRPPassContext::prepare_bloom() {
	_run_operation(FRPPipelineSpec::OP_BLOOM);
}

void FRPPassContext::resolve_final() {
	_run_operation(FRPPipelineSpec::OP_FINAL_RESOLVE);
}

void FRPPassContext::copy_history() {
	_run_operation(FRPPipelineSpec::OP_HISTORY_COPY);
}

void FRPPassContext::post_process() {
	_run_operation(FRPPipelineSpec::OP_POST_PROCESS);
}

void FRPPassContext::tonemap() {
	_run_operation(FRPPipelineSpec::OP_TONEMAP);
}

void FRPPassContext::tonemap_deferred() {
	_run_operation(FRPPipelineSpec::OP_TONEMAP_DEFERRED);
}

void FRPPassContext::present(const StringName &p_texture) {
	if (!present_runner) {
		ERR_FAIL_MSG("FRP pass context has no present callback.");
	}
	present_runner(p_texture);
}

void FRPPassContext::post_process_and_tonemap() {
	_run_operation(FRPPipelineSpec::OP_POST_PROCESS);
	_run_operation(FRPPipelineSpec::OP_TONEMAP);
}

void FRPPassContext::run_pass(int p_pass_id) {
	ERR_FAIL_COND_MSG(!FRPPipelineSpec::is_valid_pass_id(p_pass_id), vformat("Unknown FRP pass id %d.", p_pass_id));
	const FRPPipelineSpec::NativePass &definition = FRPPipelineSpec::native_pass(p_pass_id);
	for (int i = 0; i < definition.operation_count; i++) {
		_run_operation(definition.operations[i]);
	}
}

void FRPPassContext::stage_compositor_effects(int p_callback_type) {
	ERR_FAIL_INDEX_MSG(p_callback_type, int(RSE::COMPOSITOR_EFFECT_CALLBACK_TYPE_MAX), "Unknown compositor effect callback type.");
	if (stage_runner) {
		stage_runner(p_callback_type);
	}
}

void FRPPassContext::_bind_methods() {
	ClassDB::bind_method(D_METHOD("get_render_data"), &FRPPassContext::get_render_data);
	ClassDB::bind_method(D_METHOD("get_render_scene_buffers"), &FRPPassContext::get_render_scene_buffers);
	ClassDB::bind_method(D_METHOD("get_view_count"), &FRPPassContext::get_view_count);
	ClassDB::bind_method(D_METHOD("get_internal_size"), &FRPPassContext::get_internal_size);
	ClassDB::bind_method(D_METHOD("get_pass_name", "pass_id"), &FRPPassContext::get_pass_name);
	ClassDB::bind_method(D_METHOD("is_valid_pass_id", "pass_id"), &FRPPassContext::is_valid_pass_id);
	ClassDB::bind_method(D_METHOD("get_pass_parameters", "pass_id"), &FRPPassContext::get_pass_parameters);
	ClassDB::bind_method(D_METHOD("get_pre_exposure", "view"), &FRPPassContext::get_pre_exposure);
	ClassDB::bind_method(D_METHOD("set_next_pre_exposure", "view", "exposure"), &FRPPassContext::set_next_pre_exposure);
	ClassDB::bind_method(D_METHOD("set_atmosphere_parameters", "parameters", "light", "secondary_light", "optical_texture", "multiple_texture"), &FRPPassContext::set_atmosphere_parameters);
	ClassDB::bind_method(D_METHOD("get_atmosphere_parameters"), &FRPPassContext::get_atmosphere_parameters);
	ClassDB::bind_method(D_METHOD("set_height_fog_parameters", "parameters"), &FRPPassContext::set_height_fog_parameters);
	ClassDB::bind_method(D_METHOD("get_height_fog_parameters"), &FRPPassContext::get_height_fog_parameters);
	ClassDB::bind_method(D_METHOD("set_tonemap_exposure_texture", "texture"), &FRPPassContext::set_tonemap_exposure_texture);
	ClassDB::bind_method(D_METHOD("request_next_pre_exposure", "buffer", "view", "offset_bytes"), &FRPPassContext::request_next_pre_exposure);

	ClassDB::bind_method(D_METHOD("precompute_shadows"), &FRPPassContext::precompute_shadows);
	ClassDB::bind_method(D_METHOD("execute_virtual_texture_updates"), &FRPPassContext::execute_virtual_texture_updates);
	ClassDB::bind_method(D_METHOD("prepare_lighting"), &FRPPassContext::prepare_lighting);
	ClassDB::bind_method(D_METHOD("draw_gbuffer"), &FRPPassContext::draw_gbuffer);
	ClassDB::bind_method(D_METHOD("draw_motion_vectors"), &FRPPassContext::draw_motion_vectors);
	ClassDB::bind_method(D_METHOD("draw_deferred_lighting"), &FRPPassContext::draw_deferred_lighting);
	ClassDB::bind_method(D_METHOD("merge_subsurface_and_specular"), &FRPPassContext::merge_subsurface_and_specular);
	ClassDB::bind_method(D_METHOD("resolve_opaque"), &FRPPassContext::resolve_opaque);
	ClassDB::bind_method(D_METHOD("draw_sky"), &FRPPassContext::draw_sky);
	ClassDB::bind_method(D_METHOD("resolve_sky"), &FRPPassContext::resolve_sky);
	ClassDB::bind_method(D_METHOD("draw_opaque_fallback"), &FRPPassContext::draw_opaque_fallback);
	ClassDB::bind_method(D_METHOD("copy_screen_and_depth"), &FRPPassContext::copy_screen_and_depth);
	ClassDB::bind_method(D_METHOD("draw_transparent"), &FRPPassContext::draw_transparent);
	ClassDB::bind_method(D_METHOD("temporal_aa_and_upscale"), &FRPPassContext::temporal_aa_and_upscale);
	ClassDB::bind_method(D_METHOD("prepare_bloom"), &FRPPassContext::prepare_bloom);
	ClassDB::bind_method(D_METHOD("resolve_final"), &FRPPassContext::resolve_final);
	ClassDB::bind_method(D_METHOD("copy_history"), &FRPPassContext::copy_history);
	ClassDB::bind_method(D_METHOD("post_process"), &FRPPassContext::post_process);
	ClassDB::bind_method(D_METHOD("tonemap"), &FRPPassContext::tonemap);
	ClassDB::bind_method(D_METHOD("tonemap_deferred"), &FRPPassContext::tonemap_deferred);
	ClassDB::bind_method(D_METHOD("present", "texture"), &FRPPassContext::present, DEFVAL(StringName()));
	ClassDB::bind_method(D_METHOD("post_process_and_tonemap"), &FRPPassContext::post_process_and_tonemap);

	ClassDB::bind_method(D_METHOD("run_pass", "pass_id"), &FRPPassContext::run_pass);
	ClassDB::bind_method(D_METHOD("stage_compositor_effects", "callback_type"), &FRPPassContext::stage_compositor_effects);
}
