// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_CLIPMAP_LAYER_H
#define TERRAIN3D_CLIPMAP_LAYER_H

// The **one clipmap layer**: a facade over the two implementations, and the only clipmap object the
// rest of the addon names.
//
// There is one clipmap *delivery*. What a user chooses inside it is an *implementation* - the
// toroidal level ring (`LOD`) or the block atlas (`Atlas`) - and this class is where that choice
// lives:
//
//   * it owns exactly one implementation at a time, built from the shared `TerrainClipmap::Shape`
//     (`configure()`), and frees the other when the choice moves, so the two can never disagree about
//     the shape of the layer;
//   * it forwards the whole of the shared contract (`terrain_3d_clipmap_impl.h`) without branching on
//     which implementation is selected, so the tick, the assembly rule, the bake offer, the reports
//     and the debug view have one call each;
//   * it assembles the one **debug schema** (`get_debug_layout()`) from the contract's per-unit
//     entries plus whatever the implementation adds privately, so a debug view or a test reads the
//     same keys whichever implementation is selected.
//
// What is *not* here is the point of the layer: no storage, no upload, no rolling, no layout, no
// addressing arithmetic beyond the shared ladder. Those are the implementations'. The shared half - the
// ladder, the rect math, the bake-queue entry and the per-unit schema - is in
// `terrain_3d_clipmap_common.h`, once.

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/packed_vector4_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector2.hpp>

#include <cstdint>
#include <atomic>
#include <functional>
#include <memory>

#include "terrain_3d_clipmap_common.h"
#include "terrain_3d_clipmap_impl.h"
#include "terrain_3d_clipmap_source.h"

class Terrain3DClipmap;
class Terrain3DClipmapAtlas;

class Terrain3DClipmapLayer {
	CLASS_NAME_STATIC("Terrain3DClipmapLayer");

public:
	// Everything the layer is built from. One struct for both implementations: the shared `Shape`
	// carries the numbers, and `implementation` says which storage answers them.
	struct Settings {
		TerrainClipmap::Implementation implementation = TerrainClipmap::Implementation::LOD;
		TerrainClipmap::Shape shape;
	};

	// The channel's source, made fresh for each build: a source holds the channel's shape and its
	// reader (`Terrain3DClipmapSource`), and an implementation takes ownership of it. The facade asks
	// for one when it builds an implementation, so switching does not have to move ownership back out
	// of the one being replaced - and a channel is one line in the owner's factory, unchanged.
	using SourceFactory = std::function<std::unique_ptr<Terrain3DClipmapSource>()>;

	explicit Terrain3DClipmapLayer(SourceFactory p_factory);
	~Terrain3DClipmapLayer();

	// Applies the settings. A change of implementation frees the selected one's storage and builds the
	// other; a shape change reconfigures the selected one in place. Returns whether a layer exists
	// afterwards, which is what the caller's debug entry reports as "-1 rather than produced nothing".
	bool configure(const Settings &p_settings);
	// Frees the selected implementation's storage. The layer can be configured again afterwards.
	void clear();
	// An immutable snapshot is installed before the worker can call the source. It is also the input
	// snapshot already used by page and detail production.
	void set_source_snapshot(const std::shared_ptr<const Terrain3DPagePipeline::Snapshot> &p_snapshot);
	// The LOD ring's full-layer pack and publish can dominate a moving tick. Schedule changed work on
	// the existing source planner, and treat unchanged mappings as handled without a worker task; Atlas
	// retains its implementation-specific frame pacing. True means the caller should skip sync update.
	bool schedule_async_update(const Vector2 &p_focus, int p_budget_texels,
			const std::shared_ptr<const Terrain3DPagePipeline::Snapshot> &p_snapshot,
			Terrain3DPagePipeline *p_pipeline);
	bool async_update_in_progress() const;
	bool consume_async_update(int &r_produced, uint64_t &r_worker_usec, PackedVector4Array &r_addresses,
			PackedVector4Array &r_outstanding, PackedInt32Array &r_outstanding_counts);
	void get_address_uniforms(PackedVector4Array &r_addresses, PackedVector4Array &r_outstanding,
			PackedInt32Array &r_outstanding_counts) const {
		wait_for_async_update();
		if (_impl != nullptr) {
			_impl->get_address_uniforms(r_addresses, r_outstanding, r_outstanding_counts);
		} else {
			r_addresses.clear();
			r_outstanding.clear();
			r_outstanding_counts.clear();
		}
	}
	void get_outstanding_uniforms(PackedVector4Array &r_outstanding,
			PackedInt32Array &r_outstanding_counts) const {
		wait_for_async_update();
		if (_impl != nullptr) {
			_impl->get_outstanding_uniforms(r_outstanding, r_outstanding_counts);
		} else {
			r_outstanding.clear();
			r_outstanding_counts.clear();
		}
	}
	void wait_for_async_update() const;

	bool exists() const { return _impl != nullptr; }
	bool is_configured() const { return _impl != nullptr && _impl->is_configured(); }
	TerrainClipmap::Implementation get_implementation() const {
		return _impl != nullptr ? _impl->get_implementation() : _settings.implementation;
	}
	const Settings &get_settings() const { wait_for_async_update(); return _settings; }
	// The shape the implementation was actually configured with, which is the shared ladder a report or
	// a test measures against - clamped by the implementation, not by the settings.
	TerrainClipmap::Ladder get_ladder() const {
		wait_for_async_update();
		return _impl != nullptr ? _impl->get_ladder() : TerrainClipmap::ladder_of(_settings.shape);
	}
	// The source's shape, asked before an implementation exists so the owner can configure one from the
	// channel's own declaration (the same rule the ring followed).
	int get_source_channel_count() const;
	Image::Format get_source_format() const;
	int get_source_baked_channel_count() const;
	Image::Format get_source_baked_format() const;
	String get_source_name() const { wait_for_async_update(); return _impl != nullptr ? _impl->get_source_name() : String(); }

	// ---- The shared contract, forwarded ---------------------------------------------------------
	int get_unit_count() const { wait_for_async_update(); return _impl != nullptr ? _impl->get_unit_count() : 0; }
	int get_size() const { wait_for_async_update(); return _impl != nullptr ? _impl->get_size() : _settings.shape.size; }
	int get_channel_count() const { wait_for_async_update(); return _impl != nullptr ? _impl->get_channel_count() : 0; }
	Image::Format get_format() const {
		wait_for_async_update();
		return _impl != nullptr ? _impl->get_format() : _settings.shape.format;
	}
	real_t get_unit_world_size(const int p_unit) const {
		wait_for_async_update();
		return _impl != nullptr ? _impl->get_unit_world_size(p_unit) : 0.f;
	}
	real_t get_texel_world_at(const Vector2 &p_world) const {
		wait_for_async_update();
		return _impl != nullptr ? _impl->get_texel_world_at(p_world) : 0.f;
	}
	// The density a fragment is served at a world point, in texels a metre: the shared ladder's
	// reciprocal. Both implementations answer it through the one function, which is what makes the
	// "density - distance" curve a reading of the layer rather than of the storage.
	real_t get_density_at(const Vector2 &p_world) const {
		const real_t texel = get_texel_world_at(p_world);
		return texel > 0.f ? 1.f / texel : 0.f;
	}
	real_t sample(const Vector2 &p_world, const int p_channel = 0) const {
		wait_for_async_update();
		return _impl != nullptr ? _impl->sample(p_world, p_channel) : NAN;
	}

	int update(const Vector2 &p_focus, const int p_budget_texels) {
		wait_for_async_update();
		return _impl != nullptr ? _impl->update(p_focus, p_budget_texels) : 0;
	}
	int invalidate_rect(const Rect2 &p_world) {
		wait_for_async_update();
		return _impl != nullptr ? _impl->invalidate_rect(p_world) : 0;
	}

	RID get_texture_rid() const { wait_for_async_update(); return _impl != nullptr ? _impl->get_texture_rid() : RID(); }
	int get_texture_layer_count() const { wait_for_async_update(); return _impl != nullptr ? _impl->get_texture_layer_count() : 0; }
	int get_baked_channel_count() const { wait_for_async_update(); return _impl != nullptr ? _impl->get_baked_channel_count() : 0; }
	Image::Format get_baked_format() const {
		wait_for_async_update();
		return _impl != nullptr ? _impl->get_baked_format() : Image::FORMAT_RGBAH;
	}
	RID get_baked_texture_rid(const int p_channel) const {
		wait_for_async_update();
		return _impl != nullptr ? _impl->get_baked_texture_rid(p_channel) : RID();
	}
	RID get_baked_device_rid(const int p_channel) const {
		wait_for_async_update();
		return _impl != nullptr ? _impl->get_baked_device_rid(p_channel) : RID();
	}

	// ---- The bake queue, in the one shared shape -------------------------------------------------
	int get_pending_bake_count() const { wait_for_async_update(); return _impl != nullptr ? _impl->get_pending_bake_count() : 0; }
	const TerrainClipmap::BakeRect &get_pending_bake(const int p_index) const;
	bool acknowledge_bake(const TerrainClipmap::BakeRect &p_rect) {
		wait_for_async_update();
		return _impl != nullptr && _impl->acknowledge_bake(p_rect);
	}
	void mark_baked_stale() {
		wait_for_async_update();
		if (_impl != nullptr) {
			_impl->mark_baked_stale();
		}
	}

	// ---- Readings -------------------------------------------------------------------------------
	uint64_t get_state_stamp() const { wait_for_async_update(); return _impl != nullptr ? _impl->get_state_stamp() : 0; }
	uint64_t get_produced_texels() const { wait_for_async_update(); return _impl != nullptr ? _impl->get_produced_texels() : 0; }
	uint64_t get_upload_bytes() const { wait_for_async_update(); return _impl != nullptr ? _impl->get_upload_bytes() : 0; }
	uint64_t get_update_calls() const { wait_for_async_update(); return _impl != nullptr ? _impl->get_update_calls() : 0; }
	uint64_t get_idle_updates() const { wait_for_async_update(); return _impl != nullptr ? _impl->get_idle_updates() : 0; }
	int get_pending_jobs() const { wait_for_async_update(); return _impl != nullptr ? _impl->get_pending_jobs() : 0; }

	// ---- The arm and the debug payload -----------------------------------------------------------
	// The shader's copy of the selected implementation's addressing, in that implementation's uniform
	// names. `arm["implementation"]` is what the material's one binding path reads to pick the names.
	// Empty when no layer is configured, which is the gate the material's arm uses.
	Dictionary get_arm() const { wait_for_async_update(); return _impl != nullptr ? _impl->get_arm() : Dictionary(); }
	Dictionary get_address_arm() const { wait_for_async_update(); return _impl != nullptr ? _impl->get_address_arm() : Dictionary(); }
	// The selected implementation as its own type. It exists for the **one** consumer whose plumbing is
	// genuinely per-storage - the bake producer's descriptor sets name either a level array or a rect
	// array, and the shader it dispatches is the same - so that consumer has one branch instead of the
	// whole addon. Null when the *other* implementation is selected, so the wrong one cannot be used by
	// accident, and the shared contract above stays the only door everything else goes through.
	Terrain3DClipmap *lod_impl();
	const Terrain3DClipmap *lod_impl() const;
	Terrain3DClipmapAtlas *atlas_impl();
	const Terrain3DClipmapAtlas *atlas_impl() const;
	// The **one debug schema**: the shared per-unit entries every implementation answers, the layer's
	// own shape and coverage curve, and the implementation's private payload nested under `"impl"`.
	// A debug view draws the implementation's picture from `"impl"` and the coverage/density numbers
	// from the shared keys, so neither has to know which implementation is selected to be correct.
	Dictionary get_debug_layout(const String &p_group) const;

private:
	// Builds `_impl` for the settings' implementation, with a source from the factory. Returns false
	// when the channel's source does not exist - the height/material registry's own answer.
	bool _build();
	void _destroy();
	struct AsyncUpdate {
		std::atomic<bool> complete{ false };
		int produced = 0;
		uint64_t worker_usec = 0;
		PackedVector4Array addresses;
		PackedVector4Array outstanding;
		PackedInt32Array outstanding_counts;
	};
	// A source made only to be asked its shape, for the window before an implementation exists.
	std::unique_ptr<Terrain3DClipmapSource> _probe_source() const;

	SourceFactory _source_factory;
	Settings _settings;
	std::unique_ptr<Terrain3DClipmapImpl> _impl;
	std::shared_ptr<AsyncUpdate> _async_update;
};

#endif // TERRAIN3D_CLIPMAP_LAYER_H
