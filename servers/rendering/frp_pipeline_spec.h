/**************************************************************************/
/*  frp_pipeline_spec.h                                                   */
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

#include "core/string/string_name.h"

// The FRP pass set is described exactly once, here.
//
// Ids, table order and execution order are the same thing: pass N runs after pass
// N-1 unless the pipeline resource lists them in another order, and the resource's
// order is what the renderer executes (see run_builtin_pass). There is no hidden
// reorder and no second "execution order" table.
//
// A *pass* is what the user sees: one entry in the pipeline resource that can be
// enabled, disabled and reordered. An *operation* is one grouped renderer step
// (draw the G-buffer, run deferred lighting, resolve MSAA, ...). A pass expands to
// one or more operations, which is how the bookkeeping steps (resolves, copies,
// history, specular merge) stopped being separately switchable passes without
// changing any of the verified rendering code.
//
// The engine ships eight native passes; the pipeline's ninth entry (Color Grade) is
// a pass the addon provides, seeded between Temporal AA and Post Process. Nothing
// outside that set exists: FRP has no screen space effects, no global illumination
// and no debug geometry of its own.
//
// Consumers: the pipeline validator, the FRP renderer's execution and the addon
// (through RenderingServer::get_frp_pipeline_spec()).
namespace FRPPipelineSpec {

// Internal renderer operations, in the order the default frame reaches them. These
// are implementation units, not user-facing passes; a plugin pass reaches them
// through FRPPassContext.
enum Operation {
	// Pass 0: drawing the shadow maps. Pure drawing work, so it goes first: it reads
	// no scene depth and no material page.
	OP_SHADOW_PRECOMPUTE = 0,
	OP_VIRTUAL_TEXTURE = 1,
	OP_GBUFFER = 2,
	OP_MOTION_VECTORS = 3,
	// Pass 3 starts here: the light and cluster buffers, the decal buffer and the
	// volumetric fog are prepared, and the PRE_LIGHTING compositor stage may still
	// edit the G-buffer the previous pass wrote.
	OP_LIGHTING_PREPARE = 4,
	OP_PRE_LIGHTING_STAGE = 5,
	OP_DEFERRED_LIGHTING = 6,
	OP_SUBSURFACE_AND_SPECULAR = 7,
	OP_OPAQUE_RESOLVE = 8,
	OP_SKY = 9,
	OP_SKY_RESOLVE = 10,
	OP_OPAQUE_FORWARD_FALLBACK = 11,
	OP_SCREEN_AND_DEPTH_COPY = 12,
	OP_TRANSPARENT = 13,
	OP_TEMPORAL_AA = 14,
	OP_FINAL_RESOLVE = 15,
	OP_HISTORY_COPY = 16,
	// Post-processing and tone mapping are two steps, so a pass can run effects on the
	// HDR image between them or on the toned image after them. OP_TONEMAP_DEFERRED is
	// the same tone mapping with the engine's present step left to the caller, which is
	// what makes an "after tonemap" effect visible: it is reached through
	// FRPPassContext, not through a pass entry.
	OP_POST_PROCESS = 17,
	OP_TONEMAP = 18,
	OP_TONEMAP_DEFERRED = 19,
	OP_MAX = 20,
};

inline constexpr int MAX_OPERATIONS_PER_PASS = 6;

// Pass ids the engine itself has to know by name: the Temporal AA entry is the TAA
// switch (the viewport jitter follows it, and its `jitter_phases` parameter sizes
// that jitter), and the post entry is where the frame ends.
enum PassId {
	PASS_SHADOW_PRECOMPUTE = 0,
	PASS_VIRTUAL_TEXTURE = 1,
	PASS_TEMPORAL_AA = 6,
	PASS_POST_PROCESS = 7,
};

struct NativePass {
	int id;
	const char *name;
	int operations[MAX_OPERATIONS_PER_PASS];
	int operation_count;
	// Kept for the spec format: a pass that seeds disabled. Temporal AA is the only
	// such entry, and enabling its pipeline entry is what turns TAA on.
	bool optional;
};

// The passes, in id order, which is also the order a fresh pipeline seeds and the
// order a frame without a pipeline resource executes them in.
//
// Why this order: the shadow maps are drawn first, because drawing them depends on
// nothing else in the frame (see OP_SHADOW_PRECOMPUTE); virtual texture updates must
// finish before the G-buffer reads material pages; the G-buffer writes depth; the
// Lighting pass prepares the light and cluster data, lets the PRE_LIGHTING compositor
// stage edit that G-buffer, and then runs deferred lighting; sky is drawn before
// transparent geometry so the background exists behind it; temporal AA and colour
// grading run on the resolved frame before the final tone mapping.
//
// "Light precompute" here means drawing, not every preparation step: the light and
// cluster buffers stay with the Lighting pass, because they are consumed by it.
//
// Colour grading is not a native entry: it is a pass the addon provides, seeded
// between Temporal AA and Post Process, which is what lets its shader and its
// parameters be replaced without an engine change.
inline constexpr NativePass NATIVE_PASSES[] = {
	{ 0, "Shadow Precompute", { OP_SHADOW_PRECOMPUTE }, 1, false },
	{ 1, "VT Pass", { OP_VIRTUAL_TEXTURE }, 1, false },
	{ 2, "GBuffer", { OP_GBUFFER, OP_MOTION_VECTORS }, 2, false },
	{ 3, "Lighting", { OP_LIGHTING_PREPARE, OP_PRE_LIGHTING_STAGE, OP_DEFERRED_LIGHTING, OP_SUBSURFACE_AND_SPECULAR, OP_OPAQUE_RESOLVE }, 5, false },
	{ 4, "Sky", { OP_SKY, OP_SKY_RESOLVE }, 2, false },
	{ 5, "Transparent", { OP_OPAQUE_FORWARD_FALLBACK, OP_SCREEN_AND_DEPTH_COPY, OP_TRANSPARENT }, 3, false },
	// Enabling this entry enables TAA: the viewport jitter follows it, so the entry is
	// the switch and the project setting only decides for viewports without a
	// pipeline. It ships disabled, the one pass a project opts into. The viewport's
	// own temporal upscaler (FSR 2, MetalFX) always runs here too: an upscaler is
	// requested by the viewport, not by the pipeline. The operation resolves the frame
	// itself when MSAA is on, so the entry can be switched off without leaving an
	// unresolved frame behind.
	{ 6, "Temporal AA", { OP_TEMPORAL_AA }, 1, true },
	// The frame always ends here, so the resolve and the history live with the tone
	// mapping rather than with TAA. Post-processing and tone mapping are separate
	// operations: a scripted pass can run its own effects between them, or after the
	// tone mapping (see FRPPassContext::tonemap_deferred()/present()).
	{ 7, "Post Process / Tonemap", { OP_FINAL_RESOLVE, OP_HISTORY_COPY, OP_POST_PROCESS, OP_TONEMAP }, 4, false },
};

inline constexpr int PASS_COUNT = sizeof(NATIVE_PASSES) / sizeof(NATIVE_PASSES[0]);
inline constexpr int FIRST_PASS_ID = 0;
inline constexpr int LAST_PASS_ID = PASS_COUNT - 1;

// Passes a frame cannot do without. They may not be removed or disabled, and there
// is no custom-pass replacement for them.
inline constexpr int MANDATORY_PASSES[] = { 0, 1, 2, 3, 7 };

// Order constraints between enabled passes. A disabled entry does not invalidate
// another entry; if both are enabled the prerequisite must come first. With ids in
// execution order the constraint set is the "must not be moved past" list: the
// shadow maps before the lighting that samples them, virtual textures before the
// G-buffer that reads them, and each stage before the one after it.
inline constexpr int PASS_DEPENDENCIES[][2] = {
	{ 0, 3 }, // Shadow maps before the lighting pass samples them.
	{ 1, 2 }, // Virtual textures before the G-buffer reads them.
	{ 2, 3 }, // The PRE_LIGHTING stage and the lighting pass read the G-buffer.
	{ 3, 4 }, // Sky is drawn over the lit opaque result.
	{ 4, 5 }, // Sky must exist before transparent geometry is blended over it.
	{ 5, 6 },
	{ 6, 7 },
};

// Execution order used when no pipeline resource is configured: id order, which is
// the order a fresh pipeline resource seeds as well.
inline constexpr int DEFAULT_PASS_ORDER[] = { 0, 1, 2, 3, 4, 5, 6, 7 };

inline constexpr int MANDATORY_PASS_COUNT = sizeof(MANDATORY_PASSES) / sizeof(MANDATORY_PASSES[0]);
inline constexpr int PASS_DEPENDENCY_COUNT = sizeof(PASS_DEPENDENCIES) / sizeof(PASS_DEPENDENCIES[0]);
inline constexpr int DEFAULT_PASS_ORDER_COUNT = sizeof(DEFAULT_PASS_ORDER) / sizeof(DEFAULT_PASS_ORDER[0]);

inline const NativePass &native_pass(int p_id) {
	for (const NativePass &pass : NATIVE_PASSES) {
		if (pass.id == p_id) {
			return pass;
		}
	}
	static const NativePass invalid = { -1, "", {}, 0, false };
	return invalid;
}

inline const char *native_pass_name(int p_id) {
	return native_pass(p_id).name;
}

inline bool is_valid_pass_id(int p_id) {
	return p_id >= FIRST_PASS_ID && p_id < PASS_COUNT;
}

} // namespace FRPPipelineSpec
