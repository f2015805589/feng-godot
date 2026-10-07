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

void FRPPassContext::setup(RenderDataRD *p_render_data, const std::function<void(int)> &p_operation_runner, const std::function<void(int)> &p_stage_runner, const Dictionary &p_pass_parameters, const std::function<void(const StringName &)> &p_present_runner, const std::function<float(int)> &p_pre_exposure_reader, const std::function<void(int, float)> &p_pre_exposure_writer, const std::function<void(RID)> &p_eye_exposure_texture_writer, float p_scene_exposure_normalization) {
	render_data = p_render_data;
	operation_runner = p_operation_runner;
	stage_runner = p_stage_runner;
	present_runner = p_present_runner;
	pre_exposure_reader = p_pre_exposure_reader;
	pre_exposure_writer = p_pre_exposure_writer;
	eye_exposure_texture_writer = p_eye_exposure_texture_writer;
	scene_exposure_normalization = Math::is_finite(p_scene_exposure_normalization) && p_scene_exposure_normalization > 0.0f ? p_scene_exposure_normalization : 1.0f;
	pass_parameters = p_pass_parameters;
	height_fog_parameters.clear();
	atmosphere_parameters.clear();
	atmosphere_light_rids[0] = RID();
	atmosphere_light_rids[1] = RID();
	atmosphere_optical_texture = RID();
	atmosphere_multiple_texture = RID();
	clear_cloud_snapshot();
	clear_cloud_native_inputs();
	clear_cloud_projection_parameters();
	clear_cloud_outputs();
	set_cloud_capture_context(false, 0, -1, 0, Vector3(), 1.0f);
	sky_light_diffuse_requested = false;
	tonemap_mode_override = -1;
}

float FRPPassContext::get_pre_exposure(int p_view) const {
	return pre_exposure_reader ? pre_exposure_reader(p_view) : 1.0f;
}

bool FRPPassContext::supports_cloud_holdout() const {
	return !cloud_capture_active && render_data != nullptr && render_data->transparent_bg;
}

float FRPPassContext::get_cloud_time_seconds() const {
	const float time = render_data != nullptr && render_data->scene_data != nullptr ? render_data->scene_data->time : 0.0f;
	return Math::is_finite(time) ? time : 0.0f;
}

Vector2 FRPPassContext::get_taa_jitter() const {
	if (render_data == nullptr || render_data->scene_data == nullptr) {
		return Vector2();
	}
	const Vector2 jitter = render_data->scene_data->taa_jitter;
	return Math::is_finite(jitter.x) && Math::is_finite(jitter.y) ? jitter : Vector2();
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

void FRPPassContext::clear_cloud_snapshot() {
	cloud_material_parameters.clear();
	cloud_snapshot_source_signature = 0;
	for (int i = 0; i < 4; i++) {
		cloud_textures[i] = RID();
	}
	for (int i = 0; i < 3; i++) {
		cloud_layout_textures[i] = RID();
	}
	for (int i = 0; i < 2; i++) {
		cloud_suns[i] = RID();
		cloud_sun_cast_shadows_on_clouds[i] = false;
		cloud_sun_ground_transmittance[i] = Vector3(1, 1, 1);
	}
}

void FRPPassContext::set_cloud_layout_textures(RID p_pattern_texture, RID p_cloud_mask_texture, RID p_height_profile_texture) {
	// Layout inputs are borrowed from the cloud material snapshot. Keeping them
	// in dedicated slots avoids aliasing the stock detail/weather/curl bindings.
	cloud_layout_textures[0] = p_pattern_texture;
	cloud_layout_textures[1] = p_cloud_mask_texture;
	cloud_layout_textures[2] = p_height_profile_texture;
}

void FRPPassContext::set_cloud_snapshot(const PackedFloat32Array &p_material_parameters, RID p_shape_texture, RID p_detail_texture, RID p_weather_texture, RID p_curl_texture, RID p_primary_sun, RID p_secondary_sun, int64_t p_source_signature) {
	// A frame handoff is all-or-empty. This keeps malformed or stale input from
	// leaving a previous world's cloud state visible to native lighting stages.
	clear_cloud_snapshot();
	if (p_material_parameters.is_empty()) {
		return;
	}
	ERR_FAIL_COND_MSG(p_material_parameters.size() != 76, "Cloud material parameters must contain nineteen vec4 values.");
	for (float value : p_material_parameters) {
		ERR_FAIL_COND_MSG(!Math::is_finite(value), "Cloud material parameters must be finite.");
	}
	cloud_material_parameters = p_material_parameters;
	cloud_textures[0] = p_shape_texture;
	cloud_textures[1] = p_detail_texture;
	cloud_textures[2] = p_weather_texture;
	cloud_textures[3] = p_curl_texture;
	cloud_suns[0] = p_primary_sun;
	cloud_suns[1] = p_secondary_sun;
	cloud_snapshot_source_signature = p_source_signature;
}

void FRPPassContext::set_cloud_sun_ground_transmittance(int p_index, const Vector3 &p_transmittance) {
	ERR_FAIL_INDEX(p_index, 2);
	ERR_FAIL_COND_MSG(!p_transmittance.is_finite(), "Cloud sun ground transmittance must be finite.");
	cloud_sun_ground_transmittance[p_index] = p_transmittance.max(Vector3()).min(Vector3(1, 1, 1));
}

void FRPPassContext::set_cloud_sun_cast_shadows_on_clouds(int p_index, bool p_enabled) {
	ERR_FAIL_INDEX(p_index, 2);
	cloud_sun_cast_shadows_on_clouds[p_index] = p_enabled;
}

void FRPPassContext::clear_cloud_native_inputs() {
	cloud_lighting_parameters.clear();
	cloud_native_shadow_parameters.clear();
	cloud_sky_octmap = RID();
	cloud_directional_shadow_atlas = RID();
	cloud_shadow_sampler = RID();
}

void FRPPassContext::set_cloud_native_inputs(const PackedFloat32Array &p_lighting, const PackedFloat32Array &p_native_shadow, RID p_sky_octmap, RID p_directional_shadow_atlas, RID p_shadow_sampler) {
	clear_cloud_native_inputs();
	if (p_lighting.size() != 48 || p_native_shadow.size() != 156) {
		return;
	}
	for (float value : p_lighting) {
		if (!Math::is_finite(value)) {
			return;
		}
	}
	for (float value : p_native_shadow) {
		if (!Math::is_finite(value)) {
			return;
		}
	}
	cloud_lighting_parameters = p_lighting;
	cloud_native_shadow_parameters = p_native_shadow;
	cloud_sky_octmap = p_sky_octmap;
	cloud_directional_shadow_atlas = p_directional_shadow_atlas;
	cloud_shadow_sampler = p_shadow_sampler;
}

void FRPPassContext::clear_cloud_projection_parameters() {
	cloud_projection_parameters.clear();
}

void FRPPassContext::set_cloud_projection_parameters(const PackedFloat32Array &p_projection) {
	clear_cloud_projection_parameters();
	if (p_projection.size() != 140) {
		return;
	}
	for (float value : p_projection) {
		if (!Math::is_finite(value)) {
			return;
		}
	}
	cloud_projection_parameters = p_projection;
}

void FRPPassContext::clear_cloud_outputs() {
	for (RID &output : cloud_outputs) {
		output = RID();
	}
}

void FRPPassContext::set_cloud_outputs(RID p_radiance, RID p_transmittance, RID p_depth, RID p_ambient) {
	if (p_radiance.is_null() || p_transmittance.is_null() || p_depth.is_null()) {
		cloud_outputs[0] = RID();
		cloud_outputs[1] = RID();
		cloud_outputs[2] = RID();
		cloud_outputs[6] = RID();
		return;
	}
	cloud_outputs[0] = p_radiance;
	cloud_outputs[1] = p_transmittance;
	cloud_outputs[2] = p_depth;
	cloud_outputs[6] = p_ambient;
}

void FRPPassContext::set_cloud_shadow_outputs(RID p_sun0_shadow, RID p_sun1_shadow, RID p_ambient_occlusion, RID p_raw_ao_statistics) {
	cloud_outputs[3] = p_sun0_shadow;
	cloud_outputs[4] = p_sun1_shadow;
	cloud_outputs[5] = p_ambient_occlusion;
	cloud_outputs[7] = p_raw_ao_statistics;
}

PackedFloat32Array FRPPassContext::get_cloud_atmosphere_parameters() const {
	PackedFloat32Array parameters;
	parameters.resize_initialized(148);

	if (cloud_projection_parameters.size() == 140) {
		memcpy(parameters.ptrw(), cloud_projection_parameters.ptr(), sizeof(float) * 140);
	}
	float *mapping = parameters.ptrw() + 140;
	mapping[0] = -1.0f;
	mapping[1] = -1.0f;

	RD *rd = RD::get_singleton();
	if (rd == nullptr || cloud_projection_parameters.size() != 140) {
		return parameters;
	}

	bool cloud_map_valid[2] = {};
	for (int cloud_slot = 0; cloud_slot < 2; cloud_slot++) {
		const RID map = cloud_outputs[3 + cloud_slot];
		cloud_map_valid[cloud_slot] = map.is_valid() && rd->texture_is_valid(map) && cloud_projection_parameters[27 * 4 + cloud_slot] > 0.5f;
	}
	mapping[2] = cloud_map_valid[0] ? 1.0f : 0.0f;
	mapping[3] = cloud_map_valid[1] ? 1.0f : 0.0f;

	// Map atmosphere slots by the exact DirectionalLight base RID. This also
	// admits Sky-only lights, whose native surface-light index is intentionally -1.
	for (int atmo_slot = 0; atmo_slot < 2; atmo_slot++) {
		const RID atmo_light = atmosphere_light_rids[atmo_slot];
		if (!atmo_light.is_valid()) {
			continue;
		}
		for (int cloud_slot = 0; cloud_slot < 2; cloud_slot++) {
			if (cloud_suns[cloud_slot] == atmo_light && cloud_map_valid[cloud_slot]) {
				mapping[atmo_slot] = float(cloud_slot);
				break;
			}
		}
	}

	const RID raw_ao = cloud_outputs[7];
	// Lane 27.w is reserved in the addon packet. The native-only raw-statistics
	// validity bit is derived from the authored AO enable lane and the borrowed RID.
	const bool raw_ao_valid = raw_ao.is_valid() && rd->texture_is_valid(raw_ao) && cloud_projection_parameters[27 * 4 + 2] > 0.5f;
	parameters.ptrw()[144] = raw_ao_valid ? 1.0f : 0.0f;
	return parameters;
}

void FRPPassContext::set_cloud_capture_context(bool p_active, uint64_t p_batch_id, int p_face_index, int p_face_count, const Vector3 &p_origin_world_m, float p_exposure_normalization) {
	cloud_capture_active = false;
	cloud_capture_batch_id = 0;
	cloud_capture_face_index = -1;
	cloud_capture_face_count = 0;
	cloud_capture_origin_world_m = Vector3();
	cloud_capture_exposure_normalization = 1.0f;
	if (!p_active || p_batch_id == 0 || p_face_count <= 0 || p_face_index < 0 || p_face_index >= p_face_count || !p_origin_world_m.is_finite()) {
		return;
	}
	cloud_capture_active = true;
	cloud_capture_batch_id = p_batch_id;
	cloud_capture_face_index = p_face_index;
	cloud_capture_face_count = p_face_count;
	cloud_capture_origin_world_m = p_origin_world_m;
	cloud_capture_exposure_normalization = Math::is_finite(p_exposure_normalization) && p_exposure_normalization > 0.0f ? p_exposure_normalization : 1.0f;
}

void FRPPassContext::set_tonemap_exposure_texture(RID p_texture) {
	if (eye_exposure_texture_writer) {
		eye_exposure_texture_writer(p_texture);
	}
}

void FRPPassContext::set_tonemap_mode_override(int p_mode) {
	ERR_FAIL_COND(p_mode < -1 || p_mode > 5);
	tonemap_mode_override = p_mode;
}

void FRPPassContext::request_sky_light_diffuse() {
	ERR_FAIL_NULL_MSG(render_data, "FRP pass context used outside of an FRP frame.");
	sky_light_diffuse_requested = true;
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
	ClassDB::bind_method(D_METHOD("get_scene_exposure_normalization"), &FRPPassContext::get_scene_exposure_normalization);
	ClassDB::bind_method(D_METHOD("set_next_pre_exposure", "view", "exposure"), &FRPPassContext::set_next_pre_exposure);
	ClassDB::bind_method(D_METHOD("set_atmosphere_parameters", "parameters", "light", "secondary_light", "optical_texture", "multiple_texture"), &FRPPassContext::set_atmosphere_parameters);
	ClassDB::bind_method(D_METHOD("get_atmosphere_parameters"), &FRPPassContext::get_atmosphere_parameters);
	ClassDB::bind_method(D_METHOD("request_sky_light_diffuse"), &FRPPassContext::request_sky_light_diffuse);
	ClassDB::bind_method(D_METHOD("set_cloud_snapshot", "material_parameters", "shape_texture", "detail_texture", "weather_texture", "curl_texture", "primary_sun", "secondary_sun", "source_signature"), &FRPPassContext::set_cloud_snapshot, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("clear_cloud_snapshot"), &FRPPassContext::clear_cloud_snapshot);
	ClassDB::bind_method(D_METHOD("has_cloud_snapshot"), &FRPPassContext::has_cloud_snapshot);
	ClassDB::bind_method(D_METHOD("get_cloud_material_parameters"), &FRPPassContext::get_cloud_material_parameters);
	ClassDB::bind_method(D_METHOD("get_cloud_snapshot_source_signature"), &FRPPassContext::get_cloud_snapshot_source_signature);
	ClassDB::bind_method(D_METHOD("get_cloud_texture", "index"), &FRPPassContext::get_cloud_texture);
	ClassDB::bind_method(D_METHOD("set_cloud_layout_textures", "pattern_texture", "cloud_mask_texture", "height_profile_texture"), &FRPPassContext::set_cloud_layout_textures);
	ClassDB::bind_method(D_METHOD("get_cloud_layout_texture", "index"), &FRPPassContext::get_cloud_layout_texture);
	ClassDB::bind_method(D_METHOD("get_cloud_sun", "index"), &FRPPassContext::get_cloud_sun);
	ClassDB::bind_method(D_METHOD("set_cloud_sun_ground_transmittance", "index", "transmittance"), &FRPPassContext::set_cloud_sun_ground_transmittance);
	ClassDB::bind_method(D_METHOD("get_cloud_sun_ground_transmittance", "index"), &FRPPassContext::get_cloud_sun_ground_transmittance);
	ClassDB::bind_method(D_METHOD("set_cloud_sun_cast_shadows_on_clouds", "index", "enabled"), &FRPPassContext::set_cloud_sun_cast_shadows_on_clouds);
	ClassDB::bind_method(D_METHOD("get_cloud_sun_cast_shadows_on_clouds", "index"), &FRPPassContext::get_cloud_sun_cast_shadows_on_clouds);
	ClassDB::bind_method(D_METHOD("get_cloud_lighting_parameters"), &FRPPassContext::get_cloud_lighting_parameters);
	ClassDB::bind_method(D_METHOD("get_cloud_native_shadow_parameters"), &FRPPassContext::get_cloud_native_shadow_parameters);
	ClassDB::bind_method(D_METHOD("set_cloud_projection_parameters", "parameters"), &FRPPassContext::set_cloud_projection_parameters);
	ClassDB::bind_method(D_METHOD("clear_cloud_projection_parameters"), &FRPPassContext::clear_cloud_projection_parameters);
	ClassDB::bind_method(D_METHOD("get_cloud_projection_parameters"), &FRPPassContext::get_cloud_projection_parameters);
	ClassDB::bind_method(D_METHOD("get_cloud_atmosphere_parameters"), &FRPPassContext::get_cloud_atmosphere_parameters);
	ClassDB::bind_method(D_METHOD("get_cloud_sky_octmap"), &FRPPassContext::get_cloud_sky_octmap);
	ClassDB::bind_method(D_METHOD("get_cloud_directional_shadow_atlas"), &FRPPassContext::get_cloud_directional_shadow_atlas);
	ClassDB::bind_method(D_METHOD("get_cloud_shadow_sampler"), &FRPPassContext::get_cloud_shadow_sampler);
	ClassDB::bind_method(D_METHOD("set_cloud_outputs", "radiance", "transmittance", "depth", "ambient"), &FRPPassContext::set_cloud_outputs);
	ClassDB::bind_method(D_METHOD("set_cloud_shadow_outputs", "sun0_shadow", "sun1_shadow", "ambient_occlusion", "raw_ao_statistics"), &FRPPassContext::set_cloud_shadow_outputs);
	ClassDB::bind_method(D_METHOD("clear_cloud_outputs"), &FRPPassContext::clear_cloud_outputs);
	ClassDB::bind_method(D_METHOD("has_cloud_outputs"), &FRPPassContext::has_cloud_outputs);
	ClassDB::bind_method(D_METHOD("has_cloud_shadow_outputs"), &FRPPassContext::has_cloud_shadow_outputs);
	ClassDB::bind_method(D_METHOD("get_cloud_output", "index"), &FRPPassContext::get_cloud_output);
	ClassDB::bind_method(D_METHOD("is_cloud_capture"), &FRPPassContext::is_cloud_capture);
	ClassDB::bind_method(D_METHOD("get_cloud_capture_batch_id"), &FRPPassContext::get_cloud_capture_batch_id);
	ClassDB::bind_method(D_METHOD("get_cloud_capture_face_index"), &FRPPassContext::get_cloud_capture_face_index);
	ClassDB::bind_method(D_METHOD("get_cloud_capture_face_count"), &FRPPassContext::get_cloud_capture_face_count);
	ClassDB::bind_method(D_METHOD("get_cloud_capture_origin_world_m"), &FRPPassContext::get_cloud_capture_origin_world_m);
	ClassDB::bind_method(D_METHOD("get_cloud_capture_exposure_normalization"), &FRPPassContext::get_cloud_capture_exposure_normalization);
	ClassDB::bind_method(D_METHOD("get_cloud_time_seconds"), &FRPPassContext::get_cloud_time_seconds);
	ClassDB::bind_method(D_METHOD("get_taa_jitter"), &FRPPassContext::get_taa_jitter);
	ClassDB::bind_method(D_METHOD("supports_cloud_holdout"), &FRPPassContext::supports_cloud_holdout);
	ClassDB::bind_method(D_METHOD("set_height_fog_parameters", "parameters"), &FRPPassContext::set_height_fog_parameters);
	ClassDB::bind_method(D_METHOD("get_height_fog_parameters"), &FRPPassContext::get_height_fog_parameters);
	ClassDB::bind_method(D_METHOD("set_tonemap_exposure_texture", "texture"), &FRPPassContext::set_tonemap_exposure_texture);
	ClassDB::bind_method(D_METHOD("set_tonemap_mode_override", "mode"), &FRPPassContext::set_tonemap_mode_override);
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
