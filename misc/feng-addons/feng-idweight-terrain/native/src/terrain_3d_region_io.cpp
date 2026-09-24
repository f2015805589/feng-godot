// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3DRegion, part 3 of 3: serialization and introspection.

// One of three files that define a region. `save()` writes the region and its maps to disk,
// `set_data()` / `get_data()` are the map dictionary the scene and the region file carry, and
// `duplicate()` and `dump()` are the deep copy and the debug read-out. Every one of them has to
// know which maps a region may hold, which is why they read `get_map()` / `set_map()` rather than
// reaching for the members.
//
// The other two: `terrain_3d_region.cpp` (the record and its maps) and
// `terrain_3d_region_surface.cpp` (the R16 surface map).

#include "terrain_3d_region.h"

#include "logger.h"
#include "terrain_3d.h"

#include <godot_cpp/classes/resource_saver.hpp>

Error Terrain3DRegion::save(const String &p_path, const bool p_16_bit) {
	// Initiate save to external file. The scene will save itself.
	if (_location.x == INT32_MAX) {
		LOG(ERROR, "Region has not been setup. Location is INT32_MAX. Skipping ", p_path);
	}
	if (!_modified) {
		LOG(DEBUG, "Region ", _location, " not modified. Skipping ", p_path);
		return ERR_SKIP;
	}
	if (p_path.is_empty() && get_path().is_empty()) {
		LOG(ERROR, "No valid path provided");
		return ERR_FILE_NOT_FOUND;
	}
	if (!p_path.is_empty()) {
		LOG(DEBUG, "Setting file path for region ", _location, " to ", p_path);
		take_over_path(p_path);
		// Set region path and take over the path from any other cached resources,
		// incuding those in the undo queue
	}
	LOG(MESG, "Writing", (p_16_bit) ? " 16-bit" : "", " region ", _location, " to ", get_path());
	set_version(Terrain3DData::CURRENT_DATA_VERSION);
	Error err = OK;
	if (p_16_bit) {
		Ref<Image> original_map;
		original_map.instantiate();
		original_map->copy_from(_height_map);
		_height_map->convert(Image::FORMAT_RH);
		err = ResourceSaver::get_singleton()->save(this, get_path(), ResourceSaver::FLAG_COMPRESS);
		_height_map = original_map;
	} else {
		err = ResourceSaver::get_singleton()->save(this, get_path(), ResourceSaver::FLAG_COMPRESS);
	}
	if (err == OK) {
		_modified = false;
		LOG(INFO, "File saved successfully");
	} else {
		LOG(ERROR, "Cannot save region file: ", get_path(), ". Error code: ", ERROR, ". Look up @GlobalScope Error enum in the Godot docs");
	}
	return err;
}

void Terrain3DRegion::set_data(const Dictionary &p_data) {
#define SET_IF_HAS(var, str) \
	if (p_data.has(str)) { \
		var = p_data[str]; \
	}
	SET_IF_HAS(_location, "location");
	SET_IF_HAS(_deleted, "deleted");
	SET_IF_HAS(_edited, "edited");
	SET_IF_HAS(_modified, "modified");
	SET_IF_HAS(_version, "version");
	SET_IF_HAS(_region_size, "region_size");
	SET_IF_HAS(_vertex_spacing, "vertex_spacing");
	SET_IF_HAS(_height_range, "height_range");
	SET_IF_HAS(_height_map, "height_map");
	SET_IF_HAS(_control_map, "control_map");
	SET_IF_HAS(_color_map, "color_map");
	SET_IF_HAS(_surface_map, "surface_map");
	SET_IF_HAS(_surface_version, "surface_version");
	SET_IF_HAS(_surface_density, "surface_density");
	SET_IF_HAS(_instances, "instances");
}

Dictionary Terrain3DRegion::get_data() const {
	Dictionary dict;
	dict["location"] = _location;
	dict["deleted"] = _deleted;
	dict["edited"] = _edited;
	dict["modified"] = _modified;
	dict["version"] = _version;
	dict["region_size"] = _region_size;
	dict["vertex_spacing"] = _vertex_spacing;
	dict["height_range"] = _height_range;
	dict["height_map"] = _height_map;
	dict["control_map"] = _control_map;
	dict["color_map"] = _color_map;
	dict["surface_map"] = _surface_map;
	dict["surface_version"] = _surface_version;
	dict["surface_density"] = _surface_density;
	dict["instances"] = _instances;
	return dict;
}

Ref<Terrain3DRegion> Terrain3DRegion::duplicate(const bool p_deep) {
	Ref<Terrain3DRegion> region;
	region.instantiate();
	if (!p_deep) {
		region->set_data(get_data());
	} else {
		Dictionary dict;
		// Native type copies
		dict["version"] = _version;
		dict["region_size"] = _region_size;
		dict["vertex_spacing"] = _vertex_spacing;
		dict["height_range"] = _height_range;
		dict["modified"] = _modified;
		dict["deleted"] = _deleted;
		dict["location"] = _location;
		// Resource duplicates
		dict["height_map"] = _height_map->duplicate();
		dict["control_map"] = _control_map->duplicate();
		dict["color_map"] = _color_map->duplicate();
		dict["surface_version"] = _surface_version;
		dict["surface_density"] = _surface_density;
		if (_surface_map.is_valid()) {
			dict["surface_map"] = _surface_map->duplicate();
		}
		dict["instances"] = _instances.duplicate(true);
		region->set_data(dict);
	}
	return region;
}

void Terrain3DRegion::dump(const bool verbose) const {
	LOG(MESG, "Region: ", _location, ", version: ", vformat("%.2f", _version), ", size: ", _region_size,
			", spacing: ", vformat("%.1f", _vertex_spacing), ", range: ", vformat("%.2v", _height_range),
			", flags (", _edited ? "ed," : "", _modified ? "mod," : "", _deleted ? "del" : "", "), ",
			ptr_to_str(this));
	LOG(MESG, "Height map: ", ptr_to_str(*_height_map), ", Control map: ", ptr_to_str(*_control_map),
			", Color map: ", ptr_to_str(*_color_map));
	LOG(MESG, "Instances: Mesh IDs: ", _instances.size(), ", ", ptr_to_str(_instances._native_ptr()));
	Array mesh_ids = _instances.keys();
	for (const int &mesh_id : mesh_ids) {
		int counter = 0;
		Dictionary cell_inst_dict = _instances[mesh_id];
		Array cells = cell_inst_dict.keys();
		for (const Vector2i &cell : cells) {
			Array triple = cell_inst_dict[cell];
			if (triple.size() == 3) {
				counter += Array(triple[0]).size();
			} else {
				LOG(WARN, "Malformed triple at cell ", cell, ": ", triple);
				continue;
			}
			if (verbose) {
				Array xforms = triple[0];
				Array colors = triple[1];
				bool modified = triple[2];
				LOG(MESG, "Mesh ID: ", mesh_id, " cell: ", cell, " xforms: ", xforms.size(),
						", colors: ", colors.size(), modified ? ", modified" : "");
			}
		}
		LOG(MESG, "Mesh ID: ", mesh_id, ", instance count: ", counter);
	}
}
