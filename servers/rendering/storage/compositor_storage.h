/**************************************************************************/
/*  compositor_storage.h                                                  */
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

#include "core/templates/rid_owner.h"
#include "servers/rendering/rendering_server_enums.h"

class RendererCompositorStorage {
private:
	static RendererCompositorStorage *singleton;
	int num_compositor_effects_with_motion_vectors = 0;

	// Compositor effect
	struct CompositorEffect {
		bool is_enabled = true;
		RSE::CompositorEffectCallbackType callback_type;
		Callable callback;

		BitField<RSE::CompositorEffectFlags> flags = {};
	};

	mutable RID_Owner<CompositorEffect, true> compositor_effects_owner;

	// Compositor
	struct Compositor {
		// Compositor effects
		Vector<RID> compositor_effects;
		// FRP pipeline tokens. Empty means use the legacy stage-based path.
		PackedInt32Array frp_pipeline;
		PackedStringArray frp_pipeline_names;
		// Native FRP pass ids this schedule provides through plugin passes instead
		// of engine entries (see FRPPipelineSpec). A plugin pass that runs a pass's
		// work itself declares it, which lets the schedule drop the entry while the
		// renderer's per-frame feature queries still see the pass as present.
		PackedInt32Array frp_pipeline_provided;
		// Per-pass parameters, keyed by native FRP pass id. The pipeline resource
		// authors them next to the pass it orders, and both the engine (for the few
		// values it consumes, such as the Temporal AA jitter phases) and the pass
		// scripts (through FRPPassContext::get_pass_parameters) read them.
		Dictionary frp_pipeline_parameters;
	};

	mutable RID_Owner<Compositor, true> compositor_owner;

public:
	static RendererCompositorStorage *get_singleton() { return singleton; }
	int get_num_compositor_effects_with_motion_vectors() const { return num_compositor_effects_with_motion_vectors; }

	RendererCompositorStorage();
	virtual ~RendererCompositorStorage();

	// Compositor effect
	RID compositor_effect_allocate();
	void compositor_effect_initialize(RID p_rid);
	void compositor_effect_free(RID p_rid);

	bool is_compositor_effect(RID p_effect) const {
		return compositor_effects_owner.owns(p_effect);
	}

	void compositor_effect_set_enabled(RID p_effect, bool p_enabled);
	bool compositor_effect_get_enabled(RID p_effect) const;

	void compositor_effect_set_callback(RID p_effect, RSE::CompositorEffectCallbackType p_callback_type, const Callable &p_callback);
	RSE::CompositorEffectCallbackType compositor_effect_get_callback_type(RID p_effect) const;
	Callable compositor_effect_get_callback(RID p_effect) const;

	void compositor_effect_set_flag(RID p_effect, RSE::CompositorEffectFlags p_flag, bool p_set);
	bool compositor_effect_get_flag(RID p_effect, RSE::CompositorEffectFlags p_flag) const;

	// Compositor
	RID compositor_allocate();
	void compositor_initialize(RID p_rid);
	void compositor_free(RID p_rid);

	bool is_compositor(RID p_compositor) const {
		return compositor_owner.owns(p_compositor);
	}

	void compositor_set_compositor_effects(RID p_compositor, const Vector<RID> &p_effects);
	Vector<RID> compositor_get_compositor_effects(RID p_compositor, RSE::CompositorEffectCallbackType p_callback_type = RSE::COMPOSITOR_EFFECT_CALLBACK_TYPE_ANY, bool p_enabled_only = true) const;

	void compositor_set_frp_pipeline(RID p_compositor, const PackedInt32Array &p_pipeline, const PackedStringArray &p_names, const PackedInt32Array &p_provided = PackedInt32Array(), const Dictionary &p_parameters = Dictionary());
	PackedInt32Array compositor_get_frp_pipeline(RID p_compositor) const;
	PackedStringArray compositor_get_frp_pipeline_names(RID p_compositor) const;
	PackedInt32Array compositor_get_frp_pipeline_provided(RID p_compositor) const;
	Dictionary compositor_get_frp_pipeline_parameters(RID p_compositor) const;
};
