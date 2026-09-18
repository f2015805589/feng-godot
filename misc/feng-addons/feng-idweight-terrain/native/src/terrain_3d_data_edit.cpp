// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3DData's edit bookkeeping, the master height range and the ClassDB bindings.

// One of five files that define Terrain3DData. `add_edited_area()` is what an edit tells the data
// so the virtual texture republishes the regions it touched; `calc_height_range()` maintains the
// `_master_height_range` the mesher and the CDLOD selection read; `dump()` is the diagnostic the
// editor's debug output and several tests print; `_bind_methods()` is the whole script-facing
// surface of the class, which is why it is here rather than beside any one half's definitions.

#include "terrain_3d_data.h"

#include "logger.h"

void Terrain3DData::add_edited_area(const AABB &p_area) {
	if (_terrain && (_terrain->is_surface_vt_enabled() || _terrain->is_surface_svt_enabled())) {
		float world = _region_size * _vertex_spacing;
		Vector3 end = p_area.position + p_area.size;
		for (int z = int(Math::floor((p_area.position.z - _vertex_spacing) / world)); z <= int(Math::floor((end.z + _vertex_spacing) / world)); z++) {
			for (int x = int(Math::floor((p_area.position.x - _vertex_spacing) / world)); x <= int(Math::floor((end.x + _vertex_spacing) / world)); x++) {
				_terrain->invalidate_surface_pages(Vector2i(x, z));
			}
		}
	}
	if (_edited_area.has_surface()) {
		_edited_area = _edited_area.merge(p_area);
	} else {
		_edited_area = p_area;
	}
	LOG(DEBUG, "Emitting maps_edited");
	emit_signal("maps_edited", p_area);
}

// Recalculates master height range from all active regions current height ranges
// Recursive mode has all regions to recalculate from each heightmap pixel
void Terrain3DData::calc_height_range(const bool p_recursive) {
	_master_height_range = V2_ZERO;
	for (const Vector2i &region_loc : _region_locations) {
		Terrain3DRegion *region = get_region_ptr(region_loc);
		if (!region) {
			continue;
		}
		if (p_recursive) {
			region->calc_height_range();
		}
		update_master_heights(region->get_height_range());
	}
	LOG(EXTREME, "Accumulated height range for all regions: ", _master_height_range);
}

void Terrain3DData::dump(const bool verbose) const {
	LOG(MESG, "_region_locations (", _region_locations.size(), "): ", _region_locations);
	LOG(MESG, "Map slots: ", _slot_capacity, " capacity, ", _region_slots.size(), " used, ", _free_slots.size(), " free");
	Array keys = _regions.keys();
	LOG(MESG, "_regions (", keys.size(), "):");
	for (const Vector2i &region_loc : keys) {
		const Terrain3DRegion *region = get_region_ptr(region_loc);
		if (!region) {
			LOG(WARN, "No region found at: ", region_loc);
			continue;
		}
		region->dump(verbose);
	}
	if (verbose) {
		for (int slot = 0; slot < _slot_capacity; slot++) {
			if (_slot_locations[slot] != V2I_MAX) {
				LOG(MESG, "Slot ", slot, " / ", _slot_capacity - 1, " -> region ", _slot_locations[slot]);
			}
		}
		for (int i = 0; i < _region_map.size(); i++) {
			if (_region_map[i]) {
				LOG(MESG, "Region map array index: ", i, " / ", _region_map.size() - 1, ", Slot: ", _region_map[i] - 1);
			}
		}
		Util::dump_maps(_height_maps, "Height maps");
		Util::dump_gentex(_generated_height_maps, "height");
		Util::dump_maps(_control_maps, "Control maps");
		Util::dump_gentex(_generated_control_maps, "control");
		Util::dump_maps(_color_maps, "Color maps");
		Util::dump_gentex(_generated_color_maps, "color");
	}
}

///////////////////////////
// Protected Functions
///////////////////////////

void Terrain3DData::_bind_methods() {
	BIND_ENUM_CONSTANT(HEIGHT_FILTER_NEAREST);
	BIND_ENUM_CONSTANT(HEIGHT_FILTER_MINIMUM);

	BIND_ENUM_CONSTANT(EXPORT_SLICES);
	BIND_ENUM_CONSTANT(EXPORT_REGIONS);

	BIND_CONSTANT(REGION_MAP_SIZE);

	ClassDB::bind_method(D_METHOD("get_region_count"), &Terrain3DData::get_region_count);
	ClassDB::bind_method(D_METHOD("set_region_locations", "region_locations"), &Terrain3DData::set_region_locations);
	ClassDB::bind_method(D_METHOD("get_region_locations"), &Terrain3DData::get_region_locations);
	ClassDB::bind_method(D_METHOD("get_regions_active", "copy", "deep"), &Terrain3DData::get_regions_active, DEFVAL(false), DEFVAL(false));
	ClassDB::bind_method(D_METHOD("get_regions_all"), &Terrain3DData::get_regions_all);
	ClassDB::bind_method(D_METHOD("get_region_map"), &Terrain3DData::get_region_map);
	ClassDB::bind_method(D_METHOD("get_region_directory_rid"), &Terrain3DData::get_region_directory_rid);
	ClassDB::bind_method(D_METHOD("is_region_directory_valid"), &Terrain3DData::is_region_directory_valid);
	ClassDB::bind_method(D_METHOD("region_map_to_image", "region_map"), &Terrain3DData::region_map_to_image);
	ClassDB::bind_method(D_METHOD("get_map_capacity"), &Terrain3DData::get_map_capacity);
	ClassDB::bind_method(D_METHOD("get_slot_locations"), &Terrain3DData::get_slot_locations);
	ClassDB::bind_method(D_METHOD("get_map_stats"), &Terrain3DData::get_map_stats);
	ClassDB::bind_method(D_METHOD("reset_map_stats"), &Terrain3DData::reset_map_stats);
	ClassDB::bind_static_method("Terrain3DData", D_METHOD("get_region_map_index", "region_location"), &Terrain3DData::get_region_map_index);

	ClassDB::bind_method(D_METHOD("do_for_regions", "area", "callback"), &Terrain3DData::do_for_regions);
	ClassDB::bind_method(D_METHOD("change_region_size", "region_size"), &Terrain3DData::change_region_size);
	ClassDB::bind_method(D_METHOD("change_surface_density", "density"), &Terrain3DData::change_surface_density);
	ClassDB::bind_method(D_METHOD("make_sparse_surface_page", "page_x", "page_y", "local_mip",
								 "page_world_size", "page_size", "border"),
			&Terrain3DData::make_sparse_surface_page);

	ClassDB::bind_method(D_METHOD("get_region_location", "global_position"), &Terrain3DData::get_region_location);
	ClassDB::bind_method(D_METHOD("get_region_id", "region_location"), &Terrain3DData::get_region_id);
	ClassDB::bind_method(D_METHOD("get_region_idp", "global_position"), &Terrain3DData::get_region_idp);

	ClassDB::bind_method(D_METHOD("has_region", "region_location"), &Terrain3DData::has_region);
	ClassDB::bind_method(D_METHOD("has_regionp", "global_position"), &Terrain3DData::has_regionp);
	ClassDB::bind_method(D_METHOD("get_region", "region_location"), &Terrain3DData::get_region);
	ClassDB::bind_method(D_METHOD("get_regionp", "global_position"), &Terrain3DData::get_regionp);

	ClassDB::bind_method(D_METHOD("set_region_modified", "region_location", "modified"), &Terrain3DData::set_region_modified);
	ClassDB::bind_method(D_METHOD("is_region_modified", "region_location"), &Terrain3DData::is_region_modified);
	ClassDB::bind_method(D_METHOD("set_region_deleted", "region_location", "deleted"), &Terrain3DData::set_region_deleted);
	ClassDB::bind_method(D_METHOD("is_region_deleted", "region_location"), &Terrain3DData::is_region_deleted);

	ClassDB::bind_method(D_METHOD("add_region_blankp", "global_position", "update"), &Terrain3DData::add_region_blankp, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("add_region_blank", "region_location", "update"), &Terrain3DData::add_region_blank, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("add_region", "region", "update"), &Terrain3DData::add_region, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("remove_regionp", "global_position", "update"), &Terrain3DData::remove_regionp, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("remove_regionl", "region_location", "update"), &Terrain3DData::remove_regionl, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("remove_region", "region", "update"), &Terrain3DData::remove_region, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("unload_region", "region_location", "update"), &Terrain3DData::unload_region, DEFVAL(true));

	ClassDB::bind_method(D_METHOD("save_directory", "directory"), &Terrain3DData::save_directory);
	ClassDB::bind_method(D_METHOD("save_region", "region_location", "directory", "save_16_bit"), &Terrain3DData::save_region, DEFVAL(false));
	ClassDB::bind_method(D_METHOD("load_directory", "directory"), &Terrain3DData::load_directory);
	ClassDB::bind_method(D_METHOD("load_region", "region_location", "directory", "update"), &Terrain3DData::load_region, DEFVAL(true));

	ClassDB::bind_method(D_METHOD("get_height_maps"), &Terrain3DData::get_height_maps);
	ClassDB::bind_method(D_METHOD("get_control_maps"), &Terrain3DData::get_control_maps);
	ClassDB::bind_method(D_METHOD("get_color_maps"), &Terrain3DData::get_color_maps);
	ClassDB::bind_method(D_METHOD("get_surface_maps"), &Terrain3DData::get_surface_maps);
	ClassDB::bind_method(D_METHOD("get_maps", "map_type"), &Terrain3DData::get_maps);
	ClassDB::bind_method(D_METHOD("update_maps", "map_type", "all_regions", "generate_mipmaps"), &Terrain3DData::update_maps, DEFVAL(TYPE_MAX), DEFVAL(true), DEFVAL(false));
	ClassDB::bind_method(D_METHOD("get_height_maps_rid"), &Terrain3DData::get_height_maps_rid);
	ClassDB::bind_method(D_METHOD("get_control_maps_rid"), &Terrain3DData::get_control_maps_rid);
	ClassDB::bind_method(D_METHOD("get_color_maps_rid"), &Terrain3DData::get_color_maps_rid);
	ClassDB::bind_method(D_METHOD("get_surface_maps_rid"), &Terrain3DData::get_surface_maps_rid);

	ClassDB::bind_method(D_METHOD("set_pixel", "map_type", "global_position", "pixel"), &Terrain3DData::set_pixel);
	ClassDB::bind_method(D_METHOD("get_pixel", "map_type", "global_position"), &Terrain3DData::get_pixel);

	// Height Map
	ClassDB::bind_method(D_METHOD("set_height", "global_position", "height"), &Terrain3DData::set_height);
	ClassDB::bind_method(D_METHOD("get_height", "global_position"), &Terrain3DData::get_height);
	ClassDB::bind_method(D_METHOD("get_surface_height", "global_position"), &Terrain3DData::get_surface_height);
	ClassDB::bind_method(D_METHOD("get_normal", "global_position"), &Terrain3DData::get_normal);
	ClassDB::bind_method(D_METHOD("is_in_slope", "global_position", "slope_range", "normal"), &Terrain3DData::is_in_slope, DEFVAL(V3_ZERO));

	// Control Map
	ClassDB::bind_method(D_METHOD("set_control", "global_position", "control"), &Terrain3DData::set_control);
	ClassDB::bind_method(D_METHOD("get_control", "global_position"), &Terrain3DData::get_control);
	ClassDB::bind_method(D_METHOD("set_control_base_id", "global_position", "texture_id"), &Terrain3DData::set_control_base_id);
	ClassDB::bind_method(D_METHOD("get_control_base_id", "global_position"), &Terrain3DData::get_control_base_id);
	ClassDB::bind_method(D_METHOD("set_control_overlay_id", "global_position", "texture_id"), &Terrain3DData::set_control_overlay_id);
	ClassDB::bind_method(D_METHOD("get_control_overlay_id", "global_position"), &Terrain3DData::get_control_overlay_id);
	ClassDB::bind_method(D_METHOD("set_control_blend", "global_position", "blend_value"), &Terrain3DData::set_control_blend);
	ClassDB::bind_method(D_METHOD("get_control_blend", "global_position"), &Terrain3DData::get_control_blend);
	ClassDB::bind_method(D_METHOD("get_texture_id", "global_position"), &Terrain3DData::get_texture_id);
	ClassDB::bind_method(D_METHOD("set_control_angle", "global_position", "degrees"), &Terrain3DData::set_control_angle);
	ClassDB::bind_method(D_METHOD("get_control_angle", "global_position"), &Terrain3DData::get_control_angle);
	ClassDB::bind_method(D_METHOD("set_control_scale", "global_position", "percentage_modifier"), &Terrain3DData::set_control_scale);
	ClassDB::bind_method(D_METHOD("get_control_scale", "global_position"), &Terrain3DData::get_control_scale);
	ClassDB::bind_method(D_METHOD("set_control_hole", "global_position", "enable"), &Terrain3DData::set_control_hole);
	ClassDB::bind_method(D_METHOD("get_control_hole", "global_position"), &Terrain3DData::get_control_hole);
	ClassDB::bind_method(D_METHOD("set_control_navigation", "global_position", "enable"), &Terrain3DData::set_control_navigation);
	ClassDB::bind_method(D_METHOD("get_control_navigation", "global_position"), &Terrain3DData::get_control_navigation);
	ClassDB::bind_method(D_METHOD("set_control_auto", "global_position", "enable"), &Terrain3DData::set_control_auto);
	ClassDB::bind_method(D_METHOD("get_control_auto", "global_position"), &Terrain3DData::get_control_auto);

	// Color Map
	ClassDB::bind_method(D_METHOD("set_color", "global_position", "color"), &Terrain3DData::set_color);
	ClassDB::bind_method(D_METHOD("get_color", "global_position"), &Terrain3DData::get_color);
	ClassDB::bind_method(D_METHOD("set_roughness", "global_position", "roughness"), &Terrain3DData::set_roughness);
	ClassDB::bind_method(D_METHOD("get_roughness", "global_position"), &Terrain3DData::get_roughness);

	ClassDB::bind_method(D_METHOD("get_mesh_vertex", "lod", "filter", "global_position"), &Terrain3DData::get_mesh_vertex);

	ClassDB::bind_method(D_METHOD("get_height_range"), &Terrain3DData::get_height_range);
	ClassDB::bind_method(D_METHOD("calc_height_range", "recursive"), &Terrain3DData::calc_height_range, DEFVAL(false));

	ClassDB::bind_method(D_METHOD("import_images", "images", "global_position", "offset", "scale"), &Terrain3DData::import_images, DEFVAL(V3_ZERO), DEFVAL(0.f), DEFVAL(1.f));
	ClassDB::bind_method(D_METHOD("export_image", "file_name", "map_type", "mode"), &Terrain3DData::export_image, DEFVAL(TYPE_HEIGHT), DEFVAL(EXPORT_SLICES));
	ClassDB::bind_method(D_METHOD("layered_to_image", "map_type", "bounds"), &Terrain3DData::layered_to_image, DEFVAL(Rect2i()));
	ClassDB::bind_method(D_METHOD("dump", "verbose"), &Terrain3DData::dump, DEFVAL(false));

	int ro_flags = PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY;
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "region_locations", PROPERTY_HINT_ARRAY_TYPE, "Vector2i", ro_flags), "set_region_locations", "get_region_locations");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "height_maps", PROPERTY_HINT_ARRAY_TYPE, "Image", ro_flags), "", "get_height_maps");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "control_maps", PROPERTY_HINT_ARRAY_TYPE, "Image", ro_flags), "", "get_control_maps");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "color_maps", PROPERTY_HINT_ARRAY_TYPE, "Image", ro_flags), "", "get_color_maps");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "surface_maps", PROPERTY_HINT_ARRAY_TYPE, "Image", ro_flags), "", "get_surface_maps");

	ADD_SIGNAL(MethodInfo("maps_changed"));
	ADD_SIGNAL(MethodInfo("region_map_changed"));
	ADD_SIGNAL(MethodInfo("height_maps_changed"));
	ADD_SIGNAL(MethodInfo("control_maps_changed"));
	ADD_SIGNAL(MethodInfo("color_maps_changed"));
	ADD_SIGNAL(MethodInfo("surface_maps_changed"));
	ADD_SIGNAL(MethodInfo("maps_edited", PropertyInfo(Variant::AABB, "edited_area")));
}
