// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3DEditor, part 4 of 4: the undo and redo snapshots.

// One of four files that define the editor. `_store_undo()` turns the region backups a finished
// stroke left behind into the two dictionaries the plugin's UndoRedo holds - one that restores the
// state before the stroke, one that reproduces it - and registers them as the action's undo and
// redo methods. `_apply_undo()` is those methods: put the saved regions back, mark the added and
// removed ones, restore the edited area and rebuild the maps. It runs from the UndoRedo's own
// callables, outside any operation, so it takes no state from the stroke that created it.
//
// The others: terrain_3d_editor.cpp (the object and its public API),
// terrain_3d_editor_paint.cpp (the map brush loop) and
// terrain_3d_editor_texel.cpp (one brush texel).

#include "constants.h"
#include "logger.h"
#include "terrain_3d.h"
#include "terrain_3d_data.h"
#include "terrain_3d_editor.h"
#include "terrain_3d_util.h"

#include <godot_cpp/variant/callable.hpp>

void Terrain3DEditor::_store_undo() {
	IS_INIT_COND_MESG(!_terrain->get_plugin(), "_terrain isn't initialized, returning", VOID);
	if (_tool < 0 || _tool >= TOOL_MAX) {
		return;
	}
	LOG(DEBUG, "Finalize undo & redo snapshots");
	Dictionary redo_data;
	// Store current locations; Original backed up in start_operation()
	redo_data["region_locations"] = _terrain->get_data()->get_region_locations().duplicate();
	// Store original and current backups of edited regions
	_undo_data["edited_regions"] = _original_regions;
	redo_data["edited_regions"] = _edited_regions;

	if (Terrain3D::debug_level >= DEBUG) {
		LOG(DEBUG, "Storing Original Regions:");
		for (const Ref<Terrain3DRegion> &region : _original_regions) {
			if (region.is_valid()) {
				region->dump();
			}
		}
		LOG(DEBUG, "Storing Edited Regions:");
		for (const Ref<Terrain3DRegion> &region : _edited_regions) {
			if (region.is_valid()) {
				region->dump();
			}
		}
	}

	// Store regions that were removed or added
	if (_added_removed_locations.size() > 0) {
		if (_tool == REGION && _operation == SUBTRACT) {
			_undo_data["removed_regions"] = _added_removed_locations;
			redo_data["added_regions"] = _added_removed_locations;
			LOG(DEBUG, "Removed regions: ", _added_removed_locations);
		} else {
			_undo_data["added_regions"] = _added_removed_locations;
			redo_data["removed_regions"] = _added_removed_locations;
			LOG(DEBUG, "Added regions: ", _added_removed_locations);
		}
	}

	if (_terrain->get_data()->get_edited_area().has_volume()) {
		_undo_data["edited_area"] = _terrain->get_data()->get_edited_area();
		redo_data["edited_area"] = _terrain->get_data()->get_edited_area();
		LOG(DEBUG, "Adding edited area to snapshots: ", _undo_data["edited_area"]);
	}

	// Request the plugin store the undo/redo data.
	if (_terrain->get_plugin()->has_method("create_undo_action")) {
		LOG(INFO, "Storing undo snapshot");
		String action_name = String("Terrain3D ") + OPNAME[_operation] + String(" ") + TOOLNAME[_tool];
		LOG(DEBUG, "Creating undo action: '", action_name, "'");
		_terrain->get_plugin()->call("create_undo_action", action_name);

		LOG(DEBUG, "Storing undo snapshot: ");
		Util::print_dict("_undo_data snapshot", _undo_data, DEBUG);
		_terrain->get_plugin()->call("add_undo_method", Callable(this, "apply_undo").bind(_undo_data.duplicate()));

		LOG(DEBUG, "Storing redo snapshot: ");
		Util::print_dict("redo_data snapshot", redo_data, DEBUG);
		_terrain->get_plugin()->call("add_do_method", Callable(this, "apply_undo").bind(redo_data));

		LOG(DEBUG, "Committing undo action");
		_terrain->get_plugin()->call("commit_action", false);
	}
}

void Terrain3DEditor::_apply_undo(const Dictionary &p_data) {
	IS_INIT_COND_MESG(!_terrain->get_plugin(), "_terrain isn't initialized, returning", VOID);
	LOG(INFO, "Applying Undo/Redo data");

	Terrain3DData *data = _terrain->get_data();

	if (p_data.has("edited_regions")) {
		Util::print_arr("Edited regions", p_data["edited_regions"]);
		TypedArray<Terrain3DRegion> undo_regions = p_data["edited_regions"];
		LOG(DEBUG, "Backup has ", undo_regions.size(), " edited regions");
		for (Ref<Terrain3DRegion> region : undo_regions) {
			if (region.is_null()) {
				LOG(ERROR, "Null region saved in undo data. Please report this error.");
				continue;
			}
			region->sanitize_maps(); // Live data may not have some maps so must be sanitized
			Dictionary regions = data->get_regions_all();
			regions[region->get_location()] = region;
			region->set_modified(true); // Tell update_maps() this region has layers that can be individually updated
			region->set_edited(true); // Flag so update_maps() will include it
			region->set_deleted(false); // Ensure region not marked for deletion
			if (Terrain3D::debug_level >= DEBUG) {
				LOG(DEBUG, "Restoring region:");
				region->dump();
			}
		}
	}

	if (p_data.has("edited_area")) {
		LOG(DEBUG, "Edited area: ", p_data["edited_area"]);
		data->add_edited_area(p_data["edited_area"]);
	}

	if (p_data.has("added_regions")) {
		LOG(DEBUG, "Added regions: ", p_data["added_regions"]);
		TypedArray<Vector2i> region_locs = p_data["added_regions"];
		for (const Vector2i region_loc : region_locs) {
			Ref<Terrain3DRegion> region = data->get_region(region_loc);
			if (region.is_valid()) {
				LOG(DEBUG, "Marking region: ", region_loc, " +deleted, +modified, ", ptr_to_str(*region));
				region->set_deleted(true);
				region->set_modified(true);
			}
		}
	}
	if (p_data.has("removed_regions")) {
		LOG(DEBUG, "Removed regions: ", p_data["removed_regions"]);
		TypedArray<Vector2i> region_locs = p_data["removed_regions"];
		for (const Vector2i region_loc : region_locs) {
			Ref<Terrain3DRegion> region = data->get_region(region_loc);
			if (region.is_valid()) {
				LOG(DEBUG, "Marking region: ", region_loc, " -deleted, +modified, ", ptr_to_str(*region));
				region->set_deleted(false);
				region->set_modified(true);
				_send_region_aabb(region_loc, region->get_height_range());
			}
		}
	}

	// After all regions are in place, reset the region map, which also calls update_maps
	if (p_data.has("region_locations")) {
		// Load w/ duplicate or it gets a bit wonky undoing removed regions w/ saves
		TypedArray<Vector2i> locations = p_data["region_locations"];
		_terrain->get_data()->set_region_locations(locations.duplicate());
		LOG(DEBUG, "Locations(", locations.size(), "): ", locations);
	}
	// If this undo set modifies the region qty, we must rebuild the arrays. Otherwise we can update individual layers
	if (p_data.has("added_regions") || p_data.has("removed_regions")) {
		data->update_maps(TYPE_MAX, true, false);
	} else {
		data->update_maps(TYPE_MAX, false, false);
	}
	// After TextureArray updates clear edited regions flag.
	if (p_data.has("edited_regions")) {
		TypedArray<Terrain3DRegion> undo_regions = p_data["edited_regions"];
		for (Ref<Terrain3DRegion> region : undo_regions) {
			if (region.is_valid()) {
				region->set_edited(false);
			}
		}
	}
	_terrain->get_instancer()->update_mmis(-1, V2I_MAX, true);
}
