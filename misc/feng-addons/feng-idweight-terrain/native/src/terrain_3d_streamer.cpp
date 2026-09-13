// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <algorithm>

#include <godot_cpp/classes/file_access.hpp>

#include "logger.h"
#include "terrain_3d.h"
#include "terrain_3d_data.h"
#include "terrain_3d_instancer.h"
#include "terrain_3d_region.h"
#include "terrain_3d_streamer.h"
#include "terrain_3d_util.h"

///////////////////////////
// Public Functions
///////////////////////////

void Terrain3DStreamer::initialize(Terrain3D *p_terrain) {
	_terrain = p_terrain;
	_sync_data();
	LOG(INFO, "Terrain3DStreamer initialized, terrain: ", p_terrain);
}

void Terrain3DStreamer::_sync_data() const {
	_data = _terrain ? _terrain->get_data() : nullptr;
}

void Terrain3DStreamer::clear_tracking() {
	_streamed.clear();
	_missing.clear();
	_has_last_center = false;
	_last_center = V2I_MAX;
}

String Terrain3DStreamer::_resolve_directory() const {
	if (!_use_terrain_directory && !_directory.is_empty()) {
		return _directory;
	}
	return _terrain ? _terrain->get_data_directory() : String();
}

bool Terrain3DStreamer::_is_inside_world(const Vector2i &p_region_loc) const {
	return Terrain3DData::get_region_map_index(p_region_loc) >= 0;
}

bool Terrain3DStreamer::_is_resident(const Vector2i &p_region_loc) const {
	// has_region() is now correct immediately (the slot table validates it), but the
	// pointer lookup skips a dictionary lookup per region and is what the load and
	// unload paths need anyway.
	_sync_data();
	return _data && _data->get_region_ptr(p_region_loc) != nullptr;
}

int Terrain3DStreamer::chebyshev_distance(const Vector2i &p_a, const Vector2i &p_b) {
	return MAX(std::abs(p_a.x - p_b.x), std::abs(p_a.y - p_b.y));
}

void Terrain3DStreamer::_collect_desired(const Vector2i &p_center, std::vector<Vector2i> &r_desired) const {
	r_desired.clear();
	const int radius = MAX(0, _load_radius);
	// Enumerate Chebyshev rings directly in the existing distance,y,x order.
	// Interior rows contain only the two sides; no sort or duplicate cells.
	for (int ring = 0; ring <= radius; ++ring) {
		for (int dz = -ring; dz <= ring; ++dz) {
			const int step = std::abs(dz) == ring ? 1 : ring * 2;
			for (int dx = -ring; dx <= ring; dx += step) {
				const Vector2i loc = p_center + Vector2i(dx, dz);
				if (_is_inside_world(loc)) { r_desired.push_back(loc); }
			}
		}
	}
}

void Terrain3DStreamer::_collect_unload_candidates(const Vector2i &p_center, std::vector<Vector2i> &r_candidates) const {
	r_candidates.clear();
	for (const Vector2i &loc : _streamed) {
		if (chebyshev_distance(loc, p_center) > _unload_radius) {
			r_candidates.push_back(loc);
		}
	}
	// Farthest first so the ring thins from the outside in.
	std::sort(r_candidates.begin(), r_candidates.end(), [p_center](const Vector2i &p_a, const Vector2i &p_b) {
		const int distance_a = chebyshev_distance(p_a, p_center);
		const int distance_b = chebyshev_distance(p_b, p_center);
		if (distance_a != distance_b) {
			return distance_a > distance_b;
		}
		if (p_a.y != p_b.y) {
			return p_a.y < p_b.y;
		}
		return p_a.x < p_b.x;
	});
}

Terrain3DStreamer::LoadResult Terrain3DStreamer::_try_load(const Vector2i &p_region_loc) {
	_sync_data();
	if (!_data) {
		return LOAD_FAILED;
	}
	const String directory = _resolve_directory();
	if (directory.is_empty()) {
		LOG(ERROR, "Streamer has no data directory; cannot load ", p_region_loc);
		_failed_total++;
		return LOAD_FAILED;
	}
	const String path = directory + String("/") + Util::location_to_filename(p_region_loc);
	if (!FileAccess::file_exists(path)) {
		_missing.insert(p_region_loc);
		_skipped_missing_total++;
		LOG(DEBUG, "Streamer skipping absent region file ", path);
		return LOAD_MISSING_FILE;
	}
	const int before = _data->get_region_count();
	_data->load_region(p_region_loc, directory, false);
	if (_data->get_region_ptr(p_region_loc) == nullptr || _data->get_region_count() <= before) {
		_failed_total++;
		LOG(ERROR, "Streamer failed to load ", path);
		return LOAD_FAILED;
	}
	_streamed.insert(p_region_loc);
	_missing.erase(p_region_loc);
	_loaded_total++;
	// The file on disk is the current state, so the freshly loaded region starts
	// clean. Terrain3DRegion::save() serializes before clearing the flag, which
	// would otherwise leave every streamed region permanently "modified" and
	// permanently protected from unloading.
	if (Terrain3DRegion *region = _data->get_region_ptr(p_region_loc)) {
		region->set_modified(false);
	}
	LOG(DEBUG, "Streamer loaded region ", p_region_loc, " from ", path);
	return LOAD_OK;
}

bool Terrain3DStreamer::_try_unload(const Vector2i &p_region_loc) {
	_sync_data();
	if (!_data || _streamed.find(p_region_loc) == _streamed.end()) {
		return false;
	}
	Terrain3DRegion *region = _data->get_region_ptr(p_region_loc);
	if (!region) {
		_streamed.erase(p_region_loc);
		return false;
	}
	if (_protect_modified && region->is_modified()) {
		_protected_total++;
		LOG(DEBUG, "Streamer keeping modified region ", p_region_loc);
		return false;
	}
	if (_save_on_unload && region->is_modified()) {
		const String directory = _resolve_directory();
		if (directory.is_empty()) {
			_failed_total++;
			LOG(WARN, "Keeping modified region ", p_region_loc, ": no save directory");
			return false;
		}
		const Error err = region->save(directory + String("/") + Util::location_to_filename(p_region_loc),
				_terrain->get_save_16_bit());
		if (err != OK && err != ERR_SKIP) {
			_failed_total++;
			LOG(WARN, "Keeping modified region ", p_region_loc, ": save failed: ", err);
			return false;
		}
		_saved_total++;
	}
	_data->unload_region(p_region_loc, false);
	_streamed.erase(p_region_loc);
	_unloaded_total++;
	LOG(DEBUG, "Streamer unloaded region ", p_region_loc);
	return true;
}

void Terrain3DStreamer::_notify_region_set_changed() {
	_sync_data();
	if (!_data) {
		return;
	}
	// all_regions = false: a budgeted step only changed a few slots, so update_maps
	// uploads those layers instead of reallocating and re-uploading every array.
	_data->update_maps(TYPE_MAX, false, false);
	if (_terrain && _terrain->get_instancer()) {
		_terrain->get_instancer()->update_mmis(-1, V2I_MAX, true);
	}
}

bool Terrain3DStreamer::update(const Vector3 &p_center) {
	_last_loads = 0;
	_last_unloads = 0;
	_sync_data();
	if (!_data) {
		return false;
	}

	const Vector2i center = _data->get_region_location(p_center);
	_has_last_center = true;
	_last_center = center;

	std::vector<Vector2i> desired;
	_collect_desired(center, desired);

	int changed = 0;

	// Unload first: it frees texture array layers before new ones are added, and
	// keeps the resident set inside the cap below.
	if (_unloads_per_update > 0) {
		std::vector<Vector2i> candidates;
		_collect_unload_candidates(center, candidates);
		for (const Vector2i &loc : candidates) {
			if (_last_unloads >= _unloads_per_update) {
				break;
			}
			if (_try_unload(loc)) {
				_last_unloads++;
				changed++;
			}
		}
	}

	if (_loads_per_update > 0) {
		for (const Vector2i &loc : desired) {
			if (_last_loads >= _loads_per_update) {
				break;
			}
			if (_is_resident(loc) || _missing.find(loc) != _missing.end()) {
				continue;
			}
			if (_max_resident > 0 && _data->get_region_count() >= _max_resident) {
				break;
			}
			const LoadResult result = _try_load(loc);
			if (result == LOAD_OK) {
				_last_loads++;
				changed++;
			}
		}
	}

	if (changed > 0) {
		_notify_region_set_changed();
	}
	return changed > 0;
}

int Terrain3DStreamer::flush(const Vector3 &p_center, const int p_max_steps) {
	int steps = 0;
	while (steps < p_max_steps && update(p_center)) {
		steps++;
	}
	return steps;
}

Terrain3DStreamer::LoadResult Terrain3DStreamer::load_region(const Vector2i &p_region_loc) {
	_sync_data();
	if (!_is_inside_world(p_region_loc)) {
		// A caller mistake, not a runtime fault: the 32x32 region map rejects it.
		LOG(WARN, "Streamer region ", p_region_loc, " is outside the region map");
		return LOAD_FAILED;
	}
	if (_is_resident(p_region_loc)) {
		_streamed.insert(p_region_loc);
		return LOAD_OK;
	}
	const LoadResult result = _try_load(p_region_loc);
	if (result == LOAD_OK) {
		_notify_region_set_changed();
	}
	return result;
}

bool Terrain3DStreamer::unload_region(const Vector2i &p_region_loc) {
	if (!_try_unload(p_region_loc)) {
		return false;
	}
	_notify_region_set_changed();
	return true;
}

///////////////////////////
// Settings
///////////////////////////

void Terrain3DStreamer::set_directory(const String &p_directory) {
	_directory = p_directory;
	_use_terrain_directory = p_directory.is_empty();
	reset_missing();
}

void Terrain3DStreamer::set_load_radius(const int p_radius) {
	_load_radius = MAX(0, p_radius);
	if (_unload_radius < _load_radius) {
		_unload_radius = _load_radius;
	}
}

void Terrain3DStreamer::set_unload_radius(const int p_radius) {
	// Hysteresis below the load radius would thrash the ring every step.
	_unload_radius = MAX(_load_radius, p_radius);
}

void Terrain3DStreamer::set_loads_per_update(const int p_count) {
	_loads_per_update = MAX(0, p_count);
}

void Terrain3DStreamer::set_unloads_per_update(const int p_count) {
	_unloads_per_update = MAX(0, p_count);
}

void Terrain3DStreamer::set_max_resident(const int p_count) {
	_max_resident = MAX(0, p_count);
}

///////////////////////////
// Introspection
///////////////////////////

Array Terrain3DStreamer::get_streamed_locations() const {
	Array out;
	std::vector<Vector2i> sorted(_streamed.begin(), _streamed.end());
	std::sort(sorted.begin(), sorted.end(), [](const Vector2i &p_a, const Vector2i &p_b) {
		return p_a.y != p_b.y ? p_a.y < p_b.y : p_a.x < p_b.x;
	});
	for (const Vector2i &loc : sorted) {
		out.push_back(loc);
	}
	return out;
}

Array Terrain3DStreamer::get_missing_locations() const {
	Array out;
	std::vector<Vector2i> sorted(_missing.begin(), _missing.end());
	std::sort(sorted.begin(), sorted.end(), [](const Vector2i &p_a, const Vector2i &p_b) {
		return p_a.y != p_b.y ? p_a.y < p_b.y : p_a.x < p_b.x;
	});
	for (const Vector2i &loc : sorted) {
		out.push_back(loc);
	}
	return out;
}

Array Terrain3DStreamer::get_desired_locations(const Vector3 &p_center) const {
	Array out;
	_sync_data();
	if (!_data) {
		return out;
	}
	std::vector<Vector2i> desired;
	_collect_desired(_data->get_region_location(p_center), desired);
	for (const Vector2i &loc : desired) {
		out.push_back(loc);
	}
	return out;
}

Dictionary Terrain3DStreamer::get_stats() const {
	_sync_data();
	Dictionary stats;
	stats["loaded_total"] = _loaded_total;
	stats["unloaded_total"] = _unloaded_total;
	stats["saved_total"] = _saved_total;
	stats["skipped_missing_total"] = _skipped_missing_total;
	stats["failed_total"] = _failed_total;
	stats["protected_total"] = _protected_total;
	stats["last_loads"] = _last_loads;
	stats["last_unloads"] = _last_unloads;
	stats["streamed_count"] = get_streamed_count();
	stats["missing_count"] = get_missing_count();
	stats["resident_count"] = _data ? _data->get_region_count() : 0;
	stats["last_center"] = _has_last_center ? _last_center : V2I_MAX;
	return stats;
}

void Terrain3DStreamer::reset_stats() {
	_loaded_total = 0;
	_unloaded_total = 0;
	_saved_total = 0;
	_skipped_missing_total = 0;
	_failed_total = 0;
	_protected_total = 0;
	_last_loads = 0;
	_last_unloads = 0;
}

///////////////////////////
// Bindings
///////////////////////////

void Terrain3DStreamer::_bind_methods() {
	ClassDB::bind_method(D_METHOD("initialize", "terrain"), &Terrain3DStreamer::initialize);
	ClassDB::bind_method(D_METHOD("is_initialized"), &Terrain3DStreamer::is_initialized);
	ClassDB::bind_method(D_METHOD("update", "center"), &Terrain3DStreamer::update);
	ClassDB::bind_method(D_METHOD("flush", "center", "max_steps"), &Terrain3DStreamer::flush, DEFVAL(64));
	ClassDB::bind_method(D_METHOD("load_region", "region_location"), &Terrain3DStreamer::load_region);
	ClassDB::bind_method(D_METHOD("unload_region", "region_location"), &Terrain3DStreamer::unload_region);
	ClassDB::bind_method(D_METHOD("reset_missing"), &Terrain3DStreamer::reset_missing);
	ClassDB::bind_method(D_METHOD("clear_tracking"), &Terrain3DStreamer::clear_tracking);

	ClassDB::bind_method(D_METHOD("set_enabled", "enabled"), &Terrain3DStreamer::set_enabled);
	ClassDB::bind_method(D_METHOD("is_enabled"), &Terrain3DStreamer::is_enabled);
	ClassDB::bind_method(D_METHOD("set_use_terrain_directory", "enabled"), &Terrain3DStreamer::set_use_terrain_directory);
	ClassDB::bind_method(D_METHOD("get_use_terrain_directory"), &Terrain3DStreamer::get_use_terrain_directory);
	ClassDB::bind_method(D_METHOD("set_directory", "directory"), &Terrain3DStreamer::set_directory);
	ClassDB::bind_method(D_METHOD("get_directory"), &Terrain3DStreamer::get_directory);
	ClassDB::bind_method(D_METHOD("set_load_radius", "radius"), &Terrain3DStreamer::set_load_radius);
	ClassDB::bind_method(D_METHOD("get_load_radius"), &Terrain3DStreamer::get_load_radius);
	ClassDB::bind_method(D_METHOD("set_unload_radius", "radius"), &Terrain3DStreamer::set_unload_radius);
	ClassDB::bind_method(D_METHOD("get_unload_radius"), &Terrain3DStreamer::get_unload_radius);
	ClassDB::bind_method(D_METHOD("set_loads_per_update", "count"), &Terrain3DStreamer::set_loads_per_update);
	ClassDB::bind_method(D_METHOD("get_loads_per_update"), &Terrain3DStreamer::get_loads_per_update);
	ClassDB::bind_method(D_METHOD("set_unloads_per_update", "count"), &Terrain3DStreamer::set_unloads_per_update);
	ClassDB::bind_method(D_METHOD("get_unloads_per_update"), &Terrain3DStreamer::get_unloads_per_update);
	ClassDB::bind_method(D_METHOD("set_save_on_unload", "enabled"), &Terrain3DStreamer::set_save_on_unload);
	ClassDB::bind_method(D_METHOD("get_save_on_unload"), &Terrain3DStreamer::get_save_on_unload);
	ClassDB::bind_method(D_METHOD("set_protect_modified", "enabled"), &Terrain3DStreamer::set_protect_modified);
	ClassDB::bind_method(D_METHOD("get_protect_modified"), &Terrain3DStreamer::get_protect_modified);
	ClassDB::bind_method(D_METHOD("set_max_resident", "count"), &Terrain3DStreamer::set_max_resident);
	ClassDB::bind_method(D_METHOD("get_max_resident"), &Terrain3DStreamer::get_max_resident);

	ClassDB::bind_method(D_METHOD("get_streamed_count"), &Terrain3DStreamer::get_streamed_count);
	ClassDB::bind_method(D_METHOD("get_missing_count"), &Terrain3DStreamer::get_missing_count);
	ClassDB::bind_method(D_METHOD("get_streamed_locations"), &Terrain3DStreamer::get_streamed_locations);
	ClassDB::bind_method(D_METHOD("get_missing_locations"), &Terrain3DStreamer::get_missing_locations);
	ClassDB::bind_method(D_METHOD("get_desired_locations", "center"), &Terrain3DStreamer::get_desired_locations);
	ClassDB::bind_method(D_METHOD("get_loaded_total"), &Terrain3DStreamer::get_loaded_total);
	ClassDB::bind_method(D_METHOD("get_unloaded_total"), &Terrain3DStreamer::get_unloaded_total);
	ClassDB::bind_method(D_METHOD("get_saved_total"), &Terrain3DStreamer::get_saved_total);
	ClassDB::bind_method(D_METHOD("get_skipped_missing_total"), &Terrain3DStreamer::get_skipped_missing_total);
	ClassDB::bind_method(D_METHOD("get_failed_total"), &Terrain3DStreamer::get_failed_total);
	ClassDB::bind_method(D_METHOD("get_protected_total"), &Terrain3DStreamer::get_protected_total);
	ClassDB::bind_method(D_METHOD("get_last_loads"), &Terrain3DStreamer::get_last_loads);
	ClassDB::bind_method(D_METHOD("get_last_unloads"), &Terrain3DStreamer::get_last_unloads);
	ClassDB::bind_method(D_METHOD("get_stats"), &Terrain3DStreamer::get_stats);
	ClassDB::bind_method(D_METHOD("reset_stats"), &Terrain3DStreamer::reset_stats);

	ClassDB::bind_static_method("Terrain3DStreamer", D_METHOD("chebyshev_distance", "a", "b"), &Terrain3DStreamer::chebyshev_distance);

	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "enabled"), "set_enabled", "is_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "use_terrain_directory"), "set_use_terrain_directory", "get_use_terrain_directory");
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "directory", PROPERTY_HINT_DIR), "set_directory", "get_directory");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "load_radius", PROPERTY_HINT_RANGE, "0,16,1"), "set_load_radius", "get_load_radius");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "unload_radius", PROPERTY_HINT_RANGE, "0,32,1"), "set_unload_radius", "get_unload_radius");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "loads_per_update", PROPERTY_HINT_RANGE, "0,64,1"), "set_loads_per_update", "get_loads_per_update");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "unloads_per_update", PROPERTY_HINT_RANGE, "0,64,1"), "set_unloads_per_update", "get_unloads_per_update");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "save_on_unload"), "set_save_on_unload", "get_save_on_unload");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "protect_modified"), "set_protect_modified", "get_protect_modified");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "max_resident", PROPERTY_HINT_RANGE, "0,1024,1"), "set_max_resident", "get_max_resident");

	BIND_ENUM_CONSTANT(LOAD_OK);
	BIND_ENUM_CONSTANT(LOAD_MISSING_FILE);
	BIND_ENUM_CONSTANT(LOAD_FAILED);
}
