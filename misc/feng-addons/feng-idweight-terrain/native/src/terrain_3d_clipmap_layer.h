// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_CLIPMAP_LAYER_H
#define TERRAIN3D_CLIPMAP_LAYER_H

// Owns one LOD or Atlas implementation and forwards the shared clipmap contract.
// Configuration selects storage; get_debug_layout assembles the common report.

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
	// Storage choice and shared configuration.
	struct Settings {
		TerrainClipmap::Implementation implementation = TerrainClipmap::Implementation::LOD;
		TerrainClipmap::Shape shape;
	};

	// Creates an owned source for each implementation build.
	using SourceFactory = std::function<std::unique_ptr<Terrain3DClipmapSource>()>;

	explicit Terrain3DClipmapLayer(SourceFactory p_factory);
	~Terrain3DClipmapLayer();

	// Rebuilds on storage changes; reconfigures shape in place. Returns configured state.
	bool configure(const Settings &p_settings);
	// Frees the selected implementation's storage. The layer can be configured again afterwards.
	void clear();
	// An immutable snapshot is installed before the worker can call the source. It is also the input
	// snapshot already used by page and detail production.
	void set_source_snapshot(const std::shared_ptr<const Terrain3DPagePipeline::Snapshot> &p_snapshot);
	// Queue changed work on the source planner. True skips the synchronous update;
	// unchanged mappings need no worker task.
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
	// Actual configured ladder, including implementation clamps.
	TerrainClipmap::Ladder get_ladder() const {
		wait_for_async_update();
		return _impl != nullptr ? _impl->get_ladder() : TerrainClipmap::ladder_of(_settings.shape);
	}
	// Source shape is available before storage is built.
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
	// Texels per metre at this world point; zero outside coverage.
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
		if (_impl == nullptr) {
			return 0;
		}
		const int produced = _impl->update(p_focus, p_budget_texels);
		_impl->publish_pending_uploads();
		return produced;
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
	// Storage-specific access for bake descriptor construction; null for the other type.
	Terrain3DClipmap *lod_impl();
	const Terrain3DClipmap *lod_impl() const;
	Terrain3DClipmapAtlas *atlas_impl();
	const Terrain3DClipmapAtlas *atlas_impl() const;
	// Common shape and per-unit reports, with storage-specific data under "impl".
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
