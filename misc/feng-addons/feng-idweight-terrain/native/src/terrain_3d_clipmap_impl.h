// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_CLIPMAP_IMPL_H
#define TERRAIN3D_CLIPMAP_IMPL_H

// Storage-independent clipmap contract implemented by LOD and Atlas.
// Shared shape, ladder, bake leases and reports are defined in clipmap_common.h.

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector4_array.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector4.hpp>

#include <cstdint>
#include <memory>

#include "terrain_3d_clipmap_common.h"
#include "terrain_3d_page_pipeline.h"

class Terrain3DClipmapImpl {
public:
	virtual ~Terrain3DClipmapImpl() = default;

	// ---- Identity and shape ---------------------------------------------------------------------
	// Which implementation this is, so the facade, the material's arm binding and the debug view can
	// name the selected one without a downcast.
	virtual TerrainClipmap::Implementation get_implementation() const = 0;
	// The channel's own name ("height", "material"), which is what a report shows beside the shape.
	virtual String get_source_name() const = 0;
	virtual bool is_configured() const = 0;
	// Release storage; configure can rebuild it.
	virtual void clear() = 0;
	virtual int get_channel_count() const = 0;
	virtual Image::Format get_format() const = 0;
	// Supplies the immutable region bytes the source reads if this update runs on a worker.
	virtual void set_source_snapshot(const std::shared_ptr<const Terrain3DPagePipeline::Snapshot> &) {}
	// The shape the layer was configured with, in the shared vocabulary. A report or a test that asks
	// "what is the density at 40 m" needs only this.
	virtual TerrainClipmap::Ladder get_ladder() const = 0;
	virtual int get_unit_count() const = 0;
	// Finest level/block resolution in texels per axis.
	virtual int get_size() const = 0;
	// World width covered by a level or atlas shell.
	virtual real_t get_unit_world_size(const int p_unit) const = 0;

	// ---- The sampling contract ------------------------------------------------------------------
	// Sampling outside coverage returns unit -1 and texel width 0.
	virtual int get_unit_for_world(const Vector2 &p_world) const = 0;
	virtual real_t get_texel_world_at(const Vector2 &p_world) const = 0;
	virtual real_t sample(const Vector2 &p_world, const int p_channel = 0) const = 0;

	// ---- The tick -------------------------------------------------------------------------------
	// One update: re-derive what the focus implies, drain it under the budget, publish what drained.
	// Returns the channel texels produced.
	virtual int update(const Vector2 &p_focus, const int p_budget_texels) = 0;
	// Whether update has work for this focus. The facade uses this to avoid scheduling idle worker
	// tasks, while each storage layout keeps its own movement and pending-work test.
	virtual bool needs_update_at(const Vector2 &p_focus) const = 0;
	// Publish device work produced by update(). Implementations whose device API is render-thread-only
	// defer it here; the facade calls this before exposing the new addressing state.
	virtual void publish_pending_uploads() {}
	// The source changed under a world rect: the units the rect touches stop being readable and are
	// queued for re-production. Returns how many rect jobs were queued.
	virtual int invalidate_rect(const Rect2 &p_world) = 0;

	// ---- Storage the shader and the producer name -----------------------------------------------
	virtual RID get_texture_rid() const = 0;
	virtual int get_texture_layer_count() const = 0;
	virtual int get_baked_channel_count() const = 0;
	virtual Image::Format get_baked_format() const = 0;
	virtual RID get_baked_texture_rid(const int p_channel) const = 0;
	virtual RID get_baked_device_rid(const int p_channel) const = 0;

	// ---- The bake queue -------------------------------------------------------------------------
	// Produced rectangles awaiting baking; acknowledge with their content lease.
	virtual int get_pending_bake_count() const = 0;
	virtual const TerrainClipmap::BakeRect &get_pending_bake(const int p_index) const = 0;
	virtual bool acknowledge_bake(const TerrainClipmap::BakeRect &p_rect) = 0;
	// Invalidate derived material layers while retaining the readable source payload.
	virtual void mark_baked_stale() = 0;

	// ---- Readings -------------------------------------------------------------------------------
	// A counter that moves whenever something a *reader's addressing* depends on changed. The material
	// rebinds its arm on this comparison instead of every tick.
	virtual uint64_t get_state_stamp() const = 0;
	virtual uint64_t get_produced_texels() const = 0;
	virtual uint64_t get_upload_bytes() const = 0;
	virtual uint64_t get_update_calls() const = 0;
	virtual uint64_t get_idle_updates() const = 0;
	virtual int get_pending_jobs() const = 0;

	// ---- Debug / report -------------------------------------------------------------------------
	// One unit's entry in the shared schema. Filled by the implementation, assembled by the facade.
	virtual void get_unit_report(const int p_unit, TerrainClipmap::UnitReport &r_report) const = 0;
	// Storage-specific debug data, nested under "impl" by the facade.
	virtual Dictionary get_impl_payload() const = 0;
	// Shader bindings for this implementation; the material selects names from "implementation".
	virtual Dictionary get_arm() const = 0;
	// Address-only view for a moving arm. Implementations may override this to avoid building their
	// storage and content tables when only centre/offset/validity changed.
	virtual Dictionary get_address_arm() const {
		const Dictionary arm = get_arm();
		Dictionary result;
		result["centers"] = arm.get("centers", PackedVector2Array());
		result["rings"] = arm.get("rings", PackedVector2Array());
		result["valid"] = arm.get("valid", PackedFloat32Array());
		return result;
	}
	// The moving shader state in typed arrays. The LOD implementation fills these directly so a
	// moved ring does not allocate dictionaries on the main thread; the atlas fallback is infrequent
	// and can use the shared arm it already owns.
	virtual void get_address_uniforms(PackedVector4Array &r_addresses, PackedVector4Array &r_outstanding,
			PackedInt32Array &r_outstanding_counts) const {
		const Dictionary arm = get_address_arm();
		const PackedVector2Array centers = arm.get("centers", PackedVector2Array());
		const PackedVector2Array rings = arm.get("rings", PackedVector2Array());
		const PackedFloat32Array valid = arm.get("valid", PackedFloat32Array());
		const PackedVector4Array outstanding = arm.get("outstanding", PackedVector4Array());
		const PackedInt32Array counts = arm.get("outstanding_counts", PackedInt32Array());
		const int levels = TerrainClipmap::MAX_LEVELS;
		const int max_rects = TerrainClipmap::MAX_OUTSTANDING_RECTS;
		r_addresses.resize(levels);
		r_outstanding.resize(levels * max_rects);
		r_outstanding_counts.resize(levels);
		for (int level = 0; level < levels; level++) {
			const Vector2 center = level < centers.size() ? centers[level] : Vector2();
			const Vector2 ring = level < rings.size() ? rings[level] : Vector2();
			const float is_valid = level < valid.size() ? valid[level] : 0.f;
			r_addresses.set(level, Vector4(center.x, center.y, ring.x,
					ring.y + (is_valid > 0.5f ? 0.5f : 0.f)));
			r_outstanding_counts.set(level, level < counts.size() ? counts[level] : 0);
			for (int index = 0; index < max_rects; index++) {
				const int at = level * max_rects + index;
				r_outstanding.set(at, at < outstanding.size() ? outstanding[at] : Vector4());
			}
		}
	}
	virtual void get_outstanding_uniforms(PackedVector4Array &r_outstanding,
			PackedInt32Array &r_outstanding_counts) const {
		PackedVector4Array addresses;
		get_address_uniforms(addresses, r_outstanding, r_outstanding_counts);
	}
};

#endif // TERRAIN3D_CLIPMAP_IMPL_H
