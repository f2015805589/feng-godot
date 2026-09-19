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
	// Per-pass parameters the pipeline resource authored, keyed by native pass id.
	Dictionary pass_parameters;

	void _run_operation(int p_operation);

protected:
	static void _bind_methods();

public:
	void setup(RenderDataRD *p_render_data, const std::function<void(int)> &p_operation_runner, const std::function<void(int)> &p_stage_runner, const Dictionary &p_pass_parameters = Dictionary(), const std::function<void(const StringName &)> &p_present_runner = std::function<void(const StringName &)>());

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
	Dictionary get_pass_parameters(int p_pass_id) const;

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
	void resolve_final();
	void copy_history();
	// Post-processing (glow, DoF, auto exposure, AA prep) and tone mapping are separate
	// steps, so a pass decides where its own effects run:
	//   post_process(); <effects on the HDR image>; tonemap();
	//   post_process(); tonemap_deferred(); <effects on the toned image>; present();
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
