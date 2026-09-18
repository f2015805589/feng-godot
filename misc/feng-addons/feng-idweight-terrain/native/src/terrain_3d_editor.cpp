// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3DEditor, part 1 of 4: the object's state, its public API and the region tool.

// One of four files that define the editor. This is what a caller or a script touches: the
// brush dictionary `set_brush_data()` sanitizes, `set_tool()` / `set_operation()`, and the
// start -> operate -> stop sequence that brackets one stroke. The sequence is where the undo
// snapshot is opened, the tool is dispatched (the region tool here, the map tools in
// `terrain_3d_editor_paint.cpp`) and the snapshot is closed. `_operate_region()` is the region
// tool's whole body: it makes, removes or fetches one region and reports the change to the data,
// and `_send_region_aabb()` is how it and the undo restore tell the data which area moved.
// `_bind_methods()` is here because this is the file that says what the class looks like from
// outside.
//
// The others: terrain_3d_editor_paint.cpp (the map brush loop),
// terrain_3d_editor_texel.cpp (one brush texel) and
// terrain_3d_editor_undo.cpp (the undo and redo snapshots).

#include "constants.h"
#include "logger.h"
#include "terrain_3d.h"
#include "terrain_3d_data.h"
#include "terrain_3d_editor.h"
#include "terrain_3d_util.h"

#include <godot_cpp/classes/time.hpp>

///////////////////////////
// Private Functions
///////////////////////////

// Sends the whole region aabb to edited_area
void Terrain3DEditor::_send_region_aabb(const Vector2i &p_region_loc, const Vector2 &p_height_range) {
	Terrain3D::RegionSize region_size = _terrain->get_region_size();
	AABB edited_area;
	edited_area.position = Vector3(p_region_loc.x * region_size, p_height_range.x, p_region_loc.y * region_size);
	edited_area.size = Vector3(region_size, p_height_range.y - p_height_range.x, region_size);
	edited_area.position *= _terrain->get_vertex_spacing();
	edited_area.size *= _terrain->get_vertex_spacing();
	_terrain->get_data()->add_edited_area(edited_area);
}

// Process location to add new region, mark as deleted, or just retrieve
Ref<Terrain3DRegion> Terrain3DEditor::_operate_region(const Vector2i &p_region_loc) {
	bool changed = false;
	Vector2 height_range;
	Terrain3DData *data = _terrain->get_data();

	// Check if in bounds, limiting errors
	bool can_print = false;
	uint64_t ticks = Time::get_singleton()->get_ticks_msec();
	if (ticks - _last_region_bounds_error > 1000) {
		_last_region_bounds_error = ticks;
		can_print = true;
	}
	if (data->get_region_map_index(p_region_loc) < 0) {
		if (can_print) {
			LOG(INFO, "Location ", p_region_loc, " out of bounds. Max: ",
					-Terrain3DData::REGION_MAP_SIZE / 2, " to ", Terrain3DData::REGION_MAP_SIZE / 2 - 1);
		}
		return Ref<Terrain3DRegion>();
	}

	// Get Region & dump data if debug
	Ref<Terrain3DRegion> region = data->get_region(p_region_loc);
	if (can_print) {
		LOG(DEBUG, "Tool: ", _tool, " Op: ", _operation, " processing region ", p_region_loc, ": ", ptr_to_str(*region));
	}

	// Create new region if location is null or deleted
	if (region.is_null() || (region.is_valid() && region->is_deleted())) {
		// And tool is Add Region, or Height + auto_regions
		if ((_tool == REGION && _operation == ADD) || ((_tool == SCULPT || _tool == HEIGHT) && _brush_data["auto_regions"])) {
			LOG(DEBUG, "Adding blank region at: ", p_region_loc, ", ptr: ", ptr_to_str(*region));
			region = data->add_region_blank(p_region_loc);
			if (region.is_null()) {
				LOG(ERROR, "A new region cannot be created");
				return region;
			}
			_edited_regions.push_back(region); // Ensure new region is added to the redo set
			changed = true;
		}
	}

	// If removing region
	else if (region.is_valid() && _tool == REGION && _operation == SUBTRACT) {
		LOG(DEBUG, "Removing region at: ", p_region_loc, ", ptr: ", ptr_to_str(*region));
		_original_regions.push_back(region);
		height_range = region->get_height_range();
		_terrain->get_data()->remove_region(region);
		changed = true;
	}

	if (changed) {
		_added_removed_locations.push_back(p_region_loc);
		region->set_modified(true);
		_send_region_aabb(p_region_loc, height_range);
	}
	return region;
}

///////////////////////////
// Public Functions
///////////////////////////

// Santize and set incoming brush data w/ defaults and clamps
// Only santizes data needed for the editor, other parameters (eg instancer) untouched here
void Terrain3DEditor::set_brush_data(const Dictionary &p_data) {
	_brush_data = p_data; // Same instance. Anything could be inserted after this, eg mouse_pressure

	// Sanitize image and textures
	Array brush_images = p_data["brush"];
	bool error = false;
	if (brush_images.size() == 2) {
		Ref<Image> img = brush_images[0];
		if (img.is_valid() && !img->is_empty()) {
			_brush_data["brush_image"] = img;
			_brush_data["brush_image_size"] = img->get_size();
			// Cache the R channel as floats so the mask can be sampled bilinearly
			// per vertex without repeated Image lookups. Convert a copy so the
			// caller's brush image (shared with the decal texture) is untouched.
			Ref<Image> mask_image = img;
			if (mask_image->get_format() != Image::FORMAT_RF) {
				mask_image = img->duplicate();
				mask_image->convert(Image::FORMAT_RF);
			}
			PackedByteArray mask_bytes = mask_image->get_data();
			PackedFloat32Array mask;
			const int64_t mask_count = int64_t(mask_image->get_width()) * mask_image->get_height();
			mask.resize(mask_count);
			const float *mask_src = reinterpret_cast<const float *>(mask_bytes.ptr());
			real_t *mask_dst = mask.ptrw();
			for (int64_t i = 0; i < mask_count; i++) {
				mask_dst[i] = real_t(mask_src[i]);
			}
			_brush_data["brush_mask"] = mask;
		} else {
			LOG(ERROR, "Brush data doesn't contain a valid image");
		}
		Ref<Texture2D> tex = brush_images[1];
		if (tex.is_valid() && tex->get_width() > 0 && tex->get_height() > 0) {
			_brush_data["brush_texture"] = tex;
		} else {
			LOG(ERROR, "Brush data doesn't contain a valid texture");
		}
	} else {
		LOG(ERROR, "Brush data doesn't contain an image and texture");
	}

	// Santize settings
	// size is redundantly clamped differently in _operate_map and instancer::add_transforms
	_brush_data["size"] = CLAMP(real_t(p_data.get("size", 10.f)), 0.1f, 4096.f); // Diameter in meters
	_brush_data["strength"] = CLAMP(real_t(p_data.get("strength", .1f)) * .01f, .01f, 1000.f); // 1-100k% (max of 1000m per click)
	// mouse_pressure injected in editor.gd and sanitized in _operate_map()
	Vector2 slope = p_data.get("slope", Vector2(0.f, 90.f));
	slope.x = CLAMP(slope.x, 0.f, 90.f);
	slope.y = CLAMP(slope.y, 0.f, 90.f);
	_brush_data["slope"] = slope; // 0-90 (degrees)
	_brush_data["height"] = CLAMP(real_t(p_data.get("height", 0.f)), -65536.f, 65536.f); // Meters
	Color col = p_data.get("color", COLOR_ROUGHNESS);
	col.r = CLAMP(col.r, 0.f, 5.f);
	col.g = CLAMP(col.g, 0.f, 5.f);
	col.b = CLAMP(col.b, 0.f, 5.f);
	col.a = CLAMP(col.a, 0.f, 1.f);
	_brush_data["color"] = col;
	_brush_data["roughness"] = CLAMP(real_t(p_data.get("roughness", 0.f)), -100.f, 100.f) * .01f; // Percentage

	_brush_data["enable_texture"] = p_data.get("enable_texture", true);
	_brush_data["texture_filter"] = p_data.get("texture_filter", false);
	_brush_data["asset_id"] = CLAMP(int(p_data.get("asset_id", 0)), 0, ((_tool == INSTANCER) ? Terrain3DAssets::MAX_MESHES : Terrain3DAssets::MAX_TEXTURES) - 1);
	_brush_data["margin"] = CLAMP(int(p_data.get("margin", 0)), -100, 100);
	// IdWeight pair painting parameters. Weight level 0 means the brush
	// uses its default of 8 (full contribution); modes are 0..3 = Set/Add/Sub/Mix.
	_brush_data["pair_overlay_id"] = CLAMP(int(p_data.get("pair_overlay_id", int(_brush_data["asset_id"]))), 0, Terrain3DAssets::MAX_TEXTURES - 1);
	_brush_data["pair_background_id"] = CLAMP(int(p_data.get("pair_background_id", int(_brush_data["asset_id"]))), 0, Terrain3DAssets::MAX_TEXTURES - 1);
	_brush_data["pair_mode"] = CLAMP(int(p_data.get("pair_mode", 0)), 0, 3);
	_brush_data["pair_weight_level"] = CLAMP(int(p_data.get("pair_weight_level", 8)), 1, 8);

	_brush_data["enable_angle"] = p_data.get("enable_angle", true);
	_brush_data["dynamic_angle"] = p_data.get("dynamic_angle", false);
	_brush_data["angle"] = CLAMP(real_t(p_data.get("angle", 0.f)), 0.f, 337.5f);

	_brush_data["enable_scale"] = p_data.get("enable_scale", true);
	_brush_data["scale"] = CLAMP(real_t(p_data.get("scale", 0.f)), -60.f, 80.f);

	_brush_data["auto_regions"] = bool(p_data.get("auto_regions", true));
	_brush_data["align_to_view"] = bool(p_data.get("align_to_view", true));
	_brush_data["gamma"] = CLAMP(real_t(p_data.get("gamma", 1.f)), 0.1f, 2.f);
	_brush_data["brush_spin_speed"] = CLAMP(real_t(p_data.get("brush_spin_speed", 0.f)), 0.f, 1.f);
	_brush_data["gradient_points"] = p_data.get("gradient_points", PackedVector3Array());

	Util::print_dict("set_brush_data() Santized brush data:", _brush_data, EXTREME);
}

void Terrain3DEditor::set_tool(const Tool p_tool) {
	Tool old_tool = _tool;
	SET_IF_DIFF(_tool, CLAMP(p_tool, Tool(0), TOOL_MAX));
	if (_terrain && (_tool == Tool::NAVIGATION || old_tool == Tool::NAVIGATION || _tool == Tool::REGION || old_tool == Tool::REGION)) {
		_terrain->get_material()->update(Terrain3DMaterial::FULL_REBUILD);
	}
}

void Terrain3DEditor::set_operation(const Operation p_operation) {
	SET_IF_DIFF(_operation, CLAMP(p_operation, Operation(0), OP_MAX));
}

// Called on mouse click
void Terrain3DEditor::start_operation(const Vector3 &p_global_position) {
	IS_DATA_INIT_MESG("Terrain isn't initialized", VOID);
	// In case mouse-up was intercepted (by a modal dialog, focus change, or a raycast miss, etc...)
	stop_operation();
	LOG(INFO, "Setting up undo snapshot");
	_undo_data.clear();
	_undo_data["region_locations"] = _terrain->get_data()->get_region_locations().duplicate();
	_is_operating = true;
	// Reset counter at start to ensure first click places an instance
	_terrain->get_instancer()->reset_density_counter();
	_operation_position = p_global_position;
	_operation_movement = V3_ZERO;
}

// Called on mouse movement with left mouse button down
void Terrain3DEditor::operate(const Vector3 &p_global_position, const real_t p_camera_direction) {
	IS_DATA_INIT_MESG("Terrain isn't initialized", VOID);
	if (!_is_operating) {
		LOG(ERROR, "Run start_operation() before operating");
		return;
	}
	_operation_movement = p_global_position - _operation_position;
	_operation_position = p_global_position;

	// Convolve the last 8 movement events, we dont clear on mouse release
	// so as to make repeated mouse strokes in the same direction consistent
	_operation_movement_history.push_back(_operation_movement);
	if (_operation_movement_history.size() > 8) {
		_operation_movement_history.pop_front();
	}
	// size -1, dont add the last appended entry
	for (int i = 0; i < _operation_movement_history.size() - 1; i++) {
		_operation_movement += _operation_movement_history[i];
	}
	_operation_movement *= 0.125f; // 1/8th

	if (_tool == REGION) {
		_operate_region(_terrain->get_data()->get_region_location(p_global_position));
	} else if (_tool >= 0 && _tool < TOOL_MAX) {
		_operate_map(p_global_position, p_camera_direction);
	}
}

void Terrain3DEditor::backup_region(const Ref<Terrain3DRegion> &p_region) {
	// Backup region once at the start of an operation. Once Edited is set, this is skipped
	if (_is_operating && p_region.is_valid() && !p_region->is_edited()) {
		LOG(DEBUG, "Storing original copy of region: ", p_region->get_location());
		Ref<Terrain3DRegion> orig_region = p_region->duplicate(true);
		_original_regions.push_back(orig_region);
		_edited_regions.push_back(p_region);
		p_region->set_edited(true);
		p_region->set_modified(true);
		if (Terrain3D::debug_level >= DEBUG) {
			LOG(DEBUG, "Backup original region");
			orig_region->dump();
			LOG(DEBUG, "Backup edited region");
			p_region->dump();
		}
	}
}

// Called on left mouse button released
void Terrain3DEditor::stop_operation() {
	IS_DATA_INIT_MESG("Terrain isn't initialized", VOID);
	// If undo was created and terrain actually modified, store it
	LOG(DEBUG, "Backed up regions: ", _original_regions.size(), ", Edited regions: ", _edited_regions.size(),
			", Added/Removed regions: ", _added_removed_locations.size());
	if (_is_operating && (!_added_removed_locations.is_empty() || !_edited_regions.is_empty())) {
		for (int i = 0; i < _edited_regions.size(); i++) {
			Ref<Terrain3DRegion> region = _edited_regions[i];
			region->set_edited(false);
			// Make duplicate for redo, necessary or redos won't work
			Ref<Terrain3DRegion> redo_region = region->duplicate(true);
			_edited_regions[i] = redo_region;
			if (Terrain3D::debug_level >= DEBUG) {
				LOG(DEBUG, "Edited region:");
				region->dump();
				LOG(DEBUG, "Redo region:");
				redo_region->dump();
			}
		}
		_store_undo();
	}
	_undo_data.clear();
	_original_regions = TypedArray<Terrain3DRegion>(); //New pointers instead of clear
	_edited_regions = TypedArray<Terrain3DRegion>();
	_added_removed_locations = TypedArray<Vector2i>();
	_terrain->get_data()->clear_edited_area();
	_is_operating = false;
}

///////////////////////////
// Protected Functions
///////////////////////////

void Terrain3DEditor::_bind_methods() {
	BIND_ENUM_CONSTANT(ADD);
	BIND_ENUM_CONSTANT(SUBTRACT);
	BIND_ENUM_CONSTANT(REPLACE);
	BIND_ENUM_CONSTANT(AVERAGE);
	BIND_ENUM_CONSTANT(GRADIENT);
	BIND_ENUM_CONSTANT(OP_MAX);

	BIND_ENUM_CONSTANT(SCULPT);
	BIND_ENUM_CONSTANT(HEIGHT);
	BIND_ENUM_CONSTANT(TEXTURE);
	BIND_ENUM_CONSTANT(COLOR);
	BIND_ENUM_CONSTANT(ROUGHNESS);
	BIND_ENUM_CONSTANT(ANGLE);
	BIND_ENUM_CONSTANT(SCALE);
	BIND_ENUM_CONSTANT(AUTOSHADER);
	BIND_ENUM_CONSTANT(HOLES);
	BIND_ENUM_CONSTANT(NAVIGATION);
	BIND_ENUM_CONSTANT(INSTANCER);
	BIND_ENUM_CONSTANT(REGION);
	BIND_ENUM_CONSTANT(TOOL_MAX);

	ClassDB::bind_method(D_METHOD("set_terrain", "terrain"), &Terrain3DEditor::set_terrain);
	ClassDB::bind_method(D_METHOD("get_terrain"), &Terrain3DEditor::get_terrain);

	ClassDB::bind_method(D_METHOD("set_brush_data", "data"), &Terrain3DEditor::set_brush_data);
	ClassDB::bind_method(D_METHOD("set_tool", "tool"), &Terrain3DEditor::set_tool);
	ClassDB::bind_method(D_METHOD("get_tool"), &Terrain3DEditor::get_tool);
	ClassDB::bind_method(D_METHOD("set_operation", "operation"), &Terrain3DEditor::set_operation);
	ClassDB::bind_method(D_METHOD("get_operation"), &Terrain3DEditor::get_operation);
	ClassDB::bind_method(D_METHOD("start_operation", "position"), &Terrain3DEditor::start_operation);
	ClassDB::bind_method(D_METHOD("is_operating"), &Terrain3DEditor::is_operating);
	ClassDB::bind_method(D_METHOD("operate", "position", "camera_direction"), &Terrain3DEditor::operate);
	ClassDB::bind_method(D_METHOD("backup_region", "region"), &Terrain3DEditor::backup_region);
	ClassDB::bind_method(D_METHOD("stop_operation"), &Terrain3DEditor::stop_operation);

	ClassDB::bind_method(D_METHOD("apply_undo", "data"), &Terrain3DEditor::_apply_undo);
}
