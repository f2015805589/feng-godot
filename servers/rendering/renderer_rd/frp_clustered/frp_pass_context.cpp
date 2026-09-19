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

#include "core/object/class_db.h"
#include "servers/rendering/renderer_rd/storage_rd/render_data_rd.h"
#include "servers/rendering/renderer_rd/storage_rd/render_scene_buffers_rd.h"

void FRPPassContext::setup(RenderDataRD *p_render_data, const std::function<void(int)> &p_operation_runner, const std::function<void(int)> &p_stage_runner, const Dictionary &p_pass_parameters, const std::function<void(const StringName &)> &p_present_runner) {
	render_data = p_render_data;
	operation_runner = p_operation_runner;
	stage_runner = p_stage_runner;
	present_runner = p_present_runner;
	pass_parameters = p_pass_parameters;
}

Dictionary FRPPassContext::get_pass_parameters(int p_pass_id) const {
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
