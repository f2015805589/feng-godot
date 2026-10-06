/**************************************************************************/
/*  frp_pass_context.h                                                    */
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

#include "core/object/ref_counted.h"
#include "core/math/basis.h"
#include "core/os/mutex.h"
#include "core/templates/hash_map.h"
#include "servers/rendering/frp_pipeline_spec.h"

#include <functional>

class RenderDataRD;
class RenderSceneBuffersRD;

// The FRP Core surface a pass runs on, in the sense URP gives a ScriptableRenderPass:
// the frame's state plus the engine's rendering primitives. A pass that is part of an
// FRP pipeline receives one of these instead of a bare CompositorEffect callback, so
// it can drive the frame (draw the G-buffer, run deferred lighting, resolve, tone map)
// with the engine's own implementations instead of reimplementing them.
//
// Every primitive maps to exactly one internal renderer operation, which is also what
// the engine's built-in passes call: the default path and a scripted pass therefore
// execute the same code.
class FRPPassContext : public RefCounted {
	GDCLASS(FRPPassContext, RefCounted);

	RenderDataRD *render_data = nullptr;
	std::function<void(int)> operation_runner;
	std::function<void(int)> stage_runner;
	// Presents a texture to the viewport's render target. Only the renderer can reach
	// the render target, so the primitive goes through this callback.
	std::function<void(const StringName &)> present_runner;
	std::function<float(int)> pre_exposure_reader;
	std::function<void(int, float)> pre_exposure_writer;
	std::function<void(RID)> eye_exposure_texture_writer;
	// Resolved frame parameters, keyed by native pass id or custom pass name.
	Dictionary pass_parameters;
	// Render-local Feng Height Fog snapshot. It is written by the Sky-anchored
	// HeightFog pass and consumed by the later forward fallback/transparent ops.
	PackedFloat32Array height_fog_parameters;
	// Frame-local atmosphere handoff. No scene-node mutation or addon lookup.
	PackedFloat32Array atmosphere_parameters;
	RID atmosphere_light_rids[2];
	RID atmosphere_optical_texture;
	RID atmosphere_multiple_texture;
	// Optional per-frame capture of the global SkyLight diffuse term for GI passes.
	bool sky_light_diffuse_requested = false;
	// Current scene exposure scale excluding pre-exposure, matching the FRP lighting UBO.
	float scene_exposure_normalization = 1.0f;
	// Optional mode selected by the FRP Post Process pass for this frame only.
	// -1 leaves the Environment's renderer mode untouched; 5 is FRP's UE film LUT.
	int tonemap_mode_override = -1;

	void _run_operation(int p_operation);
	static void _finish_pre_exposure_readback(const PackedByteArray &p_data, const Ref<FRPPassContext> &p_context, int p_view);

protected:
	static void _bind_methods();

public:
	struct SkyLightingSource {
		uint64_t owner_id = 0;
		RID sky;
		float energy = 1.0f;
		Basis rotation;
		float captured_exposure = 1.0f;
		uint64_t revision = 0;
	};

	static void set_sky_lighting_source(RID p_render_target, uint64_t p_owner_id, RID p_sky, float p_energy, const Basis &p_rotation, float p_captured_exposure, uint64_t p_revision);
	static void clear_sky_lighting_source(RID p_render_target, uint64_t p_owner_id);
	static void clear_all_sky_lighting_sources();
	static bool get_sky_lighting_source(RID p_render_target, SkyLightingSource &r_source);

	void setup(RenderDataRD *p_render_data, const std::function<void(int)> &p_operation_runner, const std::function<void(int)> &p_stage_runner, const Dictionary &p_pass_parameters = Dictionary(), const std::function<void(const StringName &)> &p_present_runner = std::function<void(const StringName &)>(), const std::function<float(int)> &p_pre_exposure_reader = std::function<float(int)>(), const std::function<void(int, float)> &p_pre_exposure_writer = std::function<void(int, float)>(), const std::function<void(RID)> &p_eye_exposure_texture_writer = std::function<void(RID)>(), float p_scene_exposure_normalization = 1.0f);

	// Frame state.
	RenderDataRD *get_render_data() const { return render_data; }
	Ref<RenderSceneBuffersRD> get_render_scene_buffers() const;
	int get_view_count() const;
	Vector2i get_internal_size() const;
	String get_pass_name(int p_pass_id) const;
	bool is_valid_pass_id(int p_pass_id) const;
	// Parameters the pipeline resource authored for a pass. A pass script reads its
	// own settings this way, so the pipeline resource is the single place a project
	// configures a pass.
	Dictionary get_pass_parameters(const Variant &p_pass_id) const;
	float get_pre_exposure(int p_view) const;
	float get_scene_exposure_normalization() const { return scene_exposure_normalization; }
	void set_next_pre_exposure(int p_view, float p_exposure);
	void set_height_fog_parameters(const PackedFloat32Array &p_parameters);
	PackedFloat32Array get_height_fog_parameters() const { return height_fog_parameters; }
	void set_atmosphere_parameters(const PackedFloat32Array &p_parameters, RID p_light, RID p_secondary_light, RID p_optical_texture, RID p_multiple_texture);
	PackedFloat32Array get_atmosphere_parameters() const { return atmosphere_parameters; }
	// Requests the deferred opaque lighting pass to publish its global SkyLight diffuse contribution.
	void request_sky_light_diffuse();
	bool is_sky_light_diffuse_requested() const { return sky_light_diffuse_requested; }
	RID get_atmosphere_light_rid(int p_index) const { return p_index >= 0 && p_index < 2 ? atmosphere_light_rids[p_index] : RID(); }
	RID get_atmosphere_optical_texture() const { return atmosphere_optical_texture; }
	RID get_atmosphere_multiple_texture() const { return atmosphere_multiple_texture; }
	void set_tonemap_exposure_texture(RID p_texture);
	void set_tonemap_mode_override(int p_mode);
	int get_tonemap_mode_override() const { return tonemap_mode_override; }
	Error request_next_pre_exposure(RID p_buffer, int p_view, int p_offset);

	// Core primitives. One per engine operation, in execution order.
	void precompute_shadows();
	void execute_virtual_texture_updates();
	void prepare_lighting();
	void draw_gbuffer();
	void draw_motion_vectors();
	void draw_deferred_lighting();
	void merge_subsurface_and_specular();
	void resolve_opaque();
	void draw_sky();
	void resolve_sky();
	void draw_opaque_fallback();
	void copy_screen_and_depth();
	void draw_transparent();
	void temporal_aa_and_upscale();
	void prepare_bloom();
	void resolve_final();
	void copy_history();
	// Bloom preparation, post-processing (DoF and auto exposure), and tone mapping are
	// separate operations. A pass decides where its HDR/LDR effects run:
	//   prepare_bloom(); post_process(); <effects on HDR>; tonemap();
	//   post_process(); tonemap_deferred(); <effects on LDR>; present();
	void post_process();
	void tonemap();
	// Tone mapping that leaves the engine's present step to the caller: the toned image
	// lands in the engine's intermediate texture, which effects can read and write.
	void tonemap_deferred();
	// Copies a pipeline texture (empty name: the engine's toned image) to the viewport's
	// render target, i.e. presents it.
	void present(const StringName &p_texture = StringName());
	// Compatibility: both steps in order, exactly as one entry used to run them.
	void post_process_and_tonemap();

	// Runs every operation of an engine pass (see RenderingServer.get_frp_pipeline_spec()).
	void run_pass(int p_pass_id);
	// Runs a CompositorEffect callback stage, exactly as the engine's own passes do.
	void stage_compositor_effects(int p_callback_type);
};
