// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_STREAMER_CLASS_H
#define TERRAIN3D_STREAMER_CLASS_H

#include <unordered_set>

#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include "constants.h"

class Terrain3D;
class Terrain3DData;

/**
 * Region streaming: keeps a square ring of regions resident around a moving
 * center, loading missing regions from the terrain data directory and dropping
 * regions that left the ring. Region files on disk are never written unless
 * `save_on_unload` is enabled, and regions authored by the user (not loaded by
 * this streamer) are never unloaded.
 *
 * Chunking stays where it already is: regions are the storage and texture array
 * chunks, and Terrain3DMesher draws the clipmap ring around the same target.
 * The streamer only decides which regions exist in memory.
 */
class Terrain3DStreamer : public Object {
	GDCLASS(Terrain3DStreamer, Object);
	CLASS_NAME();

public:
	enum LoadResult {
		LOAD_OK,
		LOAD_MISSING_FILE,
		LOAD_FAILED,
	};

private:
	Terrain3D *_terrain = nullptr;
	// Terrain3D::set_data_directory() recreates Terrain3DData, so this pointer is
	// re-resolved on every entry point instead of being trusted across calls.
	mutable Terrain3DData *_data = nullptr;

	// Settings
	bool _enabled = false;
	bool _use_terrain_directory = true;
	String _directory;
	int _load_radius = 2;
	int _unload_radius = 3;
	int _loads_per_update = 1;
	int _unloads_per_update = 1;
	bool _save_on_unload = false;
	bool _protect_modified = true;
	int _max_resident = 0;

	// Runtime state
	// Regions this streamer put in memory and is therefore allowed to remove.
	std::unordered_set<Vector2i, Vector2iHash> _streamed;
	// Region locations whose file does not exist. Retried only on reset.
	std::unordered_set<Vector2i, Vector2iHash> _missing;
	Vector2i _last_center = V2I_MAX;
	bool _has_last_center = false;

	// Stats
	int _loaded_total = 0;
	int _unloaded_total = 0;
	int _saved_total = 0;
	int _skipped_missing_total = 0;
	int _failed_total = 0;
	int _protected_total = 0;
	int _last_loads = 0;
	int _last_unloads = 0;

	String _resolve_directory() const;
	// Defined in the .cpp: it needs the complete Terrain3D type.
	void _sync_data() const;
	bool _is_inside_world(const Vector2i &p_region_loc) const;
	bool _is_resident(const Vector2i &p_region_loc) const;
	void _collect_desired(const Vector2i &p_center, std::vector<Vector2i> &r_desired) const;
	void _collect_unload_candidates(const Vector2i &p_center, std::vector<Vector2i> &r_candidates) const;
	LoadResult _try_load(const Vector2i &p_region_loc);
	bool _try_unload(const Vector2i &p_region_loc);
	void _notify_region_set_changed();

public:
	Terrain3DStreamer() {}
	~Terrain3DStreamer() {}

	void initialize(Terrain3D *p_terrain);
	bool is_initialized() const { return _terrain != nullptr; }

	// Runs one streaming step around p_center (global position). Returns true
	// when the resident region set changed this step.
	bool update(const Vector3 &p_center);
	// Repeats update() until it stops changing the resident set.
	// Returns the number of steps taken, capped by p_max_steps.
	int flush(const Vector3 &p_center, const int p_max_steps = 64);
	// Loads a single region regardless of the ring, for tests and manual pokes.
	LoadResult load_region(const Vector2i &p_region_loc);
	// Unloads a single streamed region regardless of the ring.
	bool unload_region(const Vector2i &p_region_loc);
	// Forgets the missing-file cache so absent regions are probed again.
	void reset_missing() { _missing.clear(); }
	// Drops all streamer bookkeeping without touching loaded regions.
	void clear_tracking();

	// Settings
	void set_enabled(const bool p_enabled) { _enabled = p_enabled; }
	bool is_enabled() const { return _enabled; }
	void set_use_terrain_directory(const bool p_enabled) { _use_terrain_directory = p_enabled; }
	bool get_use_terrain_directory() const { return _use_terrain_directory; }
	void set_directory(const String &p_directory);
	String get_directory() const { return _resolve_directory(); }
	void set_load_radius(const int p_radius);
	int get_load_radius() const { return _load_radius; }
	void set_unload_radius(const int p_radius);
	int get_unload_radius() const { return _unload_radius; }
	void set_loads_per_update(const int p_count);
	int get_loads_per_update() const { return _loads_per_update; }
	void set_unloads_per_update(const int p_count);
	int get_unloads_per_update() const { return _unloads_per_update; }
	void set_save_on_unload(const bool p_enabled) { _save_on_unload = p_enabled; }
	bool get_save_on_unload() const { return _save_on_unload; }
	void set_protect_modified(const bool p_enabled) { _protect_modified = p_enabled; }
	bool get_protect_modified() const { return _protect_modified; }
	void set_max_resident(const int p_count);
	int get_max_resident() const { return _max_resident; }

	// Introspection
	int get_streamed_count() const { return int(_streamed.size()); }
	int get_missing_count() const { return int(_missing.size()); }
	Array get_streamed_locations() const;
	Array get_missing_locations() const;
	// Region locations the current center wants resident.
	Array get_desired_locations(const Vector3 &p_center) const;
	int get_loaded_total() const { return _loaded_total; }
	int get_unloaded_total() const { return _unloaded_total; }
	int get_saved_total() const { return _saved_total; }
	int get_skipped_missing_total() const { return _skipped_missing_total; }
	int get_failed_total() const { return _failed_total; }
	int get_protected_total() const { return _protected_total; }
	int get_last_loads() const { return _last_loads; }
	int get_last_unloads() const { return _last_unloads; }
	Dictionary get_stats() const;
	void reset_stats();

	// Utility
	static int chebyshev_distance(const Vector2i &p_a, const Vector2i &p_b);

protected:
	static void _bind_methods();
};

VARIANT_ENUM_CAST(Terrain3DStreamer::LoadResult);

#endif // TERRAIN3D_STREAMER_CLASS_H
