// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3DData's on-disk path: region files, map export and map import.
//
// One of five files that define Terrain3DData. This one moves regions and images in and out of the
// project on disk. The others: `terrain_3d_data.cpp` (slots, the chunk directory and the slot maps),
// `terrain_3d_data_regions.cpp` (region lifecycle and the region table), `terrain_3d_data_maps.cpp`
// (the map arrays, their upload and the queries) and `terrain_3d_data_edit.cpp` (edit bookkeeping,
// the height range and the bindings), with page production in `terrain_3d_data_surface.cpp`.
//
// This file includes what it uses, not the family's old shared block: that block named
// terrain_surface_idweight.h, <algorithm> and <unordered_map>, none of which appears here.
// `engine.hpp` is not dead weight either, and a grep for `Engine` will not say so: the file writes
// the addon's `IS_EDITOR` macro (constants.h), which expands to `Engine::get_singleton()`.
// `editor_file_system.hpp` is here for the complete type behind
// `EditorInterface::get_resource_filesystem()`, which the code calls `is_scanning()` and `scan()` on.

#include "terrain_3d.h"
#include "terrain_3d_data.h"

#include "logger.h"

#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/editor_file_system.hpp>
#include <godot_cpp/classes/editor_interface.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/resource_saver.hpp>

#include <cmath>

Error Terrain3DData::_save_export_image(const MapType p_map_type, const Ref<Image> &p_img, const String &p_path,
		const String &p_ext) const {
	if (p_map_type == TYPE_HEIGHT && (p_ext == "r16" || p_ext == "raw")) {
		Ref<FileAccess> file = FileAccess::open(p_path, FileAccess::WRITE);
		if (file.is_null()) {
			return ERR_CANT_OPEN;
		}
		Vector2 minmax = _master_height_range;
		if (minmax.x >= minmax.y) {
			// Global height range wasn't calculated, fall back to range for this image
			minmax = Util::get_min_max(p_img);
			LOG(MESG, "  Height range (per image fallback): ", vformat("%.2f", minmax.x), " to ", vformat("%.2f", minmax.y));
		} else {
			LOG(MESG, "  Height range (global scale): ", vformat("%.2f", minmax.x), " to ", vformat("%.2f", minmax.y));
		}
		float range = minmax.y - minmax.x;
		real_t hscale = 65535.f / (range != 0.f ? range : 1.f);
		for (int y = 0; y < p_img->get_height(); y++) {
			for (int x = 0; x < p_img->get_width(); x++) {
				int h = int((p_img->get_pixel(x, y).r - minmax.x) * hscale);
				h = CLAMP(h, 0, 65535);
				file->store_16(h);
			}
		}
		return file->get_error();
	} else if (p_ext == "exr") {
		return p_img->save_exr(p_path, (p_map_type == TYPE_HEIGHT));
	} else if (p_ext == "png") {
		return p_img->save_png(p_path);
	} else if (p_ext == "jpg") {
		return p_img->save_jpg(p_path);
	} else if (p_ext == "webp") {
		return p_img->save_webp(p_path);
	} else if (p_ext == "res" || p_ext == "tres") {
		return ResourceSaver::get_singleton()->save(p_img, p_path, ResourceSaver::FLAG_COMPRESS);
	}
	return ERR_FILE_UNRECOGNIZED;
}

void Terrain3DData::save_directory(const String &p_dir) {
	LOG(INFO, "Saving data files to ", p_dir);
	Array locations = _regions.keys();
	for (const Vector2i &region_loc : locations) {
		save_region(region_loc, p_dir, _terrain->get_save_16_bit());
	}
	if (IS_EDITOR && !EditorInterface::get_singleton()->get_resource_filesystem()->is_scanning()) {
		EditorInterface::get_singleton()->get_resource_filesystem()->scan();
	}
}

// You may need to do a file system scan to update FileSystem panel
void Terrain3DData::save_region(const Vector2i &p_region_loc, const String &p_dir, const bool p_16_bit) {
	Ref<Terrain3DRegion> region = get_region(p_region_loc);
	if (region.is_null()) {
		LOG(ERROR, "No region found at: ", p_region_loc);
		return;
	}
	String fname = Util::location_to_filename(p_region_loc);
	String path = p_dir + String("/") + fname;
	// If region marked for deletion, remove from disk and from _regions, but don't free in case stored in undo
	if (region->is_deleted()) {
		LOG(DEBUG, "Removing ", p_region_loc, " from _regions");
		_regions.erase(p_region_loc);
		LOG(DEBUG, "File to be deleted: ", path);
		if (!FileAccess::file_exists(path)) {
			LOG(INFO, "File to delete ", path, " doesn't exist. (Maybe from add, undo, save)");
			return;
		}
		Ref<DirAccess> da = DirAccess::open(p_dir);
		if (da.is_null()) {
			LOG(ERROR, "Cannot open directory for writing: ", p_dir, " error: ", DirAccess::get_open_error());
			return;
		}
		Error err = da->remove(fname);
		if (err != OK) {
			LOG(ERROR, "Could not remove file: ", fname, ", error code: ", err);
		}
		LOG(INFO, "File ", path, " deleted");
		return;
	}
	Error err = region->save(path, p_16_bit);
	if (!(err == OK || err == ERR_SKIP)) {
		LOG(ERROR, "Could not save file: ", path, ", error: ", UtilityFunctions::error_string(err), " (", err, ")");
	}
}

// One region file, loaded, size-checked and adopted. Both load paths do exactly this much and
// differ only in what a failure means to them, so the verdict is returned rather than handled:
// `load_directory()` goes on to the next file after an unreadable one and stops the whole load
// on a size mismatch, while `load_region()` stops on either.
RegionFileLoad Terrain3DData::_load_region_file(const String &p_path, const Vector2i &p_region_loc, const bool p_update) {
	Ref<Terrain3DRegion> region = ResourceLoader::get_singleton()->load(p_path, "Terrain3DRegion", ResourceLoader::CACHE_MODE_IGNORE);
	if (region.is_null()) {
		LOG(ERROR, "Cannot load region at ", p_path);
		return RegionFileLoad::UNREADABLE;
	}
	LOG(INFO, "Loaded region: ", p_region_loc, " size: ", region->get_region_size());
	// The first region loaded sets the terrain's size; every later one has to agree with it.
	if (_regions.is_empty()) {
		_terrain->set_region_size((Terrain3D::RegionSize)region->get_region_size());
	} else if (_terrain->get_region_size() != (Terrain3D::RegionSize)region->get_region_size()) {
		LOG(ERROR, "Region size mismatch. First loaded: ", _terrain->get_region_size(), " next: ",
				region->get_region_size(), " in file: ", p_path);
		return RegionFileLoad::SIZE_MISMATCH;
	}
	region->take_over_path(p_path);
	region->set_location(p_region_loc);
	region->set_version(CURRENT_DATA_VERSION); // Sends upgrade warning if old version
	add_region(region, p_update);
	return RegionFileLoad::LOADED;
}

void Terrain3DData::load_directory(const String &p_dir) {
	if (p_dir.is_empty()) {
		LOG(ERROR, "Specified directory name is blank");
		return;
	}

	LOG(INFO, "Loading region files from ", p_dir);
	PackedStringArray files = Util::get_files(p_dir, "terrain3d*.res");
	if (files.size() == 0) {
		LOG(INFO, "No Terrain3D region files found in: ", p_dir);
		return;
	}

	_clear();
	for (const String &fname : files) {
		String path = p_dir + String("/") + fname;
		LOG(DEBUG, "Loading region from ", path);
		Vector2i loc = Util::filename_to_location(fname);
		if (loc.x == INT32_MAX) {
			LOG(ERROR, "Cannot get region location from file name: ", fname);
			continue;
		}
		if (_load_region_file(path, loc, false) == RegionFileLoad::SIZE_MISMATCH) {
			// A directory is one terrain: a region that disagrees with the size the first one
			// set stops the load. The log above names the file and both sizes.
			return;
		}
	}
	update_maps(TYPE_MAX, true, false);
}

void Terrain3DData::load_region(const Vector2i &p_region_loc, const String &p_dir, const bool p_update) {
	LOG(INFO, "Loading region from location ", p_region_loc);
	String path = p_dir + String("/") + Util::location_to_filename(p_region_loc);
	if (!FileAccess::file_exists(path)) {
		LOG(ERROR, "File ", path, " doesn't exist");
		return;
	}
	// Either failure is final here: a caller that asked for one location has nothing else to try,
	// so the verdict is dropped after the load path has logged why it failed.
	_load_region_file(path, p_region_loc, p_update);
}

/**
 * Imports an Image set (Height, Control, Color) into Terrain3DData
 * It does NOT normalize values to 0-1. You must do that using get_min_max() and adjusting scale and offset.
 * Parameters:
 *	p_images - MapType.TYPE_MAX sized array of Images for Height, Control, Color. Images can be blank or null
 *	p_global_position - X,0,Z location on the region map. Valid range is +/-16 * region_size
 *	p_offset - Add this factor to all height values, can be negative
 *	p_scale - Scale all height values by this factor (applied after offset)
 */
void Terrain3DData::import_images(const TypedArray<Image> &p_images, const Vector3 &p_global_position, const real_t p_offset, const real_t p_scale) {
	IS_INIT_MESG("Data not initialized", VOID);
	// Validate images and determine common size
	if (p_images.size() != TYPE_MAX) {
		LOG(ERROR, "p_images.size() is ", p_images.size(), ". It should be ", TYPE_MAX, " even if some Images are blank or null");
		return;
	}
	Vector2i img_size = V2I_ZERO;
	for (int i = 0; i < TYPE_MAX; i++) {
		Ref<Image> img = p_images[i];
		if (img.is_valid() && !img->is_empty()) {
			LOG(INFO, "Importing image type ", TYPESTR[i], ", size: ", img->get_size(), ", format: ", img->get_format());
			if (i == TYPE_HEIGHT) {
				LOG(INFO, "Applying offset: ", p_offset, ", scale: ", p_scale);
			}
			if (img_size == V2I_ZERO) {
				img_size = img->get_size();
			} else if (img_size != img->get_size()) {
				LOG(ERROR, "Included Images in p_images have different dimensions. Aborting import");
				return;
			}
		}
	}
	if (img_size == V2I_ZERO) {
		LOG(ERROR, "All images are empty. Nothing to import");
		return;
	}

	// Convert import origin to floored, descaled vertex grid
	const Vector2i img_start = world_to_vgrid(p_global_position);
	const Vector2i img_end = img_start + img_size - Vector2i(1, 1);

	// Validate vertex-grid range for the current region_size
	// Regions run from -HALF .. HALF-1, each covering _region_size vertices
	const int half = REGION_MAP_SIZE / 2;
	const int min_v = -half * _region_size;
	const int max_v = (half * _region_size) - 1; // inclusive

	if (img_start.x < min_v || img_start.y < min_v ||
			img_end.x > max_v || img_end.y > max_v) {
		// How large does region_size need to be for this image to fit
		// (centred or placed at the requested position)?
		const int required_span = MAX(img_size.x, img_size.y);
		int min_region_size = _region_size;
		while (min_region_size < Terrain3D::RegionSize::SIZE_2048 &&
				required_span > min_region_size * REGION_MAP_SIZE) {
			min_region_size <<= 1;
		}

		LOG(ERROR, "Image of size ", img_size, " at ", v3v2i(p_global_position),
				" does not fit within max width of ", REGION_MAP_SIZE, " * region_size ", _region_size,
				" = ", REGION_MAP_SIZE * _region_size);

		if (min_region_size > _region_size) {
			LOG(ERROR, "Increase region_size to at least ", min_region_size,
					" and place the image so its center covers the the origin.");
		} else {
			LOG(ERROR, "Try a position near ",
					-Vector3(img_size.x, 0.f, img_size.y) * _vertex_spacing * 0.5f,
					" to center the image.");
		}
		return;
	}

	// Apply scale and offsets to the heightmap and filter out invalid data
	TypedArray<Image> src_images;
	src_images.resize(TYPE_MAX);
	for (int i = 0; i < TYPE_MAX; i++) {
		Ref<Image> img = p_images[i];
		src_images[i] = img;
		if (img.is_null() || img->is_empty()) {
			continue;
		}
		if (i == TYPE_HEIGHT && (p_scale != 1.f || p_offset != 0.f)) {
			LOG(DEBUG, "Creating new temp image to adjust scale: ", p_scale, " offset: ", p_offset);
			Ref<Image> newimg = Image::create_empty(img_size.x, img_size.y, false, FORMAT[TYPE_HEIGHT]);
			for (int y = 0; y < img_size.y; y++) {
				for (int x = 0; x < img_size.x; x++) {
					Color clr = img->get_pixel(x, y);
					if (std::isnormal(clr.r)) {
						clr.r = (clr.r * p_scale) + p_offset;
					} else {
						clr.r = p_offset;
					}
					newimg->set_pixel(x, y, clr);
				}
			}
			src_images[i] = newimg;
		}
	}

	// Calculate regions this image will span
	const Vector2i start_region = V2I_DIVIDE_FLOOR(img_start, _region_size);
	const Vector2i end_region = V2I_DIVIDE_FLOOR(img_end, _region_size);
	LOG(DEBUG, "Image spans regions ", start_region, " to ", end_region);

	bool generate_mipmaps = false;
	for (int rz = start_region.y; rz <= end_region.y; rz++) {
		for (int rx = start_region.x; rx <= end_region.x; rx++) {
			const Vector2i region_loc = Vector2i(rx, rz);
			const Vector2i region_origin = region_loc * _region_size;

			// Overlap in descaled vertex space
			const int overlap_start_x = MAX(region_origin.x, img_start.x);
			const int overlap_start_z = MAX(region_origin.y, img_start.y);
			const int overlap_end_x = MIN(region_origin.x + _region_size - 1, img_end.x);
			const int overlap_end_z = MIN(region_origin.y + _region_size - 1, img_end.y);

			// Skip if no overlap
			if (overlap_end_x < overlap_start_x || overlap_end_z < overlap_start_z) {
				continue;
			}

			const int copy_width = overlap_end_x - overlap_start_x + 1;
			const int copy_height = overlap_end_z - overlap_start_z + 1;
			const Vector2i src_pos(overlap_start_x - img_start.x, overlap_start_z - img_start.y);
			const Vector2i dst_pos(overlap_start_x - region_origin.x, overlap_start_z - region_origin.y);

			LOG(DEBUG, "Region ", region_loc, ": copying ", Vector2i(copy_width, copy_height),
					" from img", src_pos, " to region", dst_pos);

			Ref<Terrain3DRegion> region = get_region(region_loc);
			if (region.is_null()) {
				region.instantiate();
				region->set_location(region_loc);
				region->set_region_size(_region_size);
				region->set_vertex_spacing(_vertex_spacing);
				add_region(region, false);
			} else if (region->is_deleted()) {
				region->clear();
				region->set_location(region_loc);
				region->set_region_size(_region_size);
				region->set_vertex_spacing(_vertex_spacing);
			}

			for (int i = 0; i < TYPE_MAX; i++) {
				Ref<Image> img = src_images[i];
				if (img.is_valid() && !img->is_empty()) {
					Ref<Image> region_map;
					Ref<Image> existing_map = region->get_map(static_cast<MapType>(i));
					if (existing_map.is_valid() && !existing_map->is_empty()) {
						region_map.instantiate();
						region_map->copy_from(existing_map);
						if (region_map->get_format() != img->get_format()) {
							region_map->convert(img->get_format());
						}
					} else {
						region_map = Util::get_filled_image(_region_sizev, COLOR[i], false, img->get_format());
					}
					region_map->blit_rect(img, Rect2i(src_pos, Vector2i(copy_width, copy_height)), dst_pos);
					region->set_map(static_cast<MapType>(i), region_map);
					if (i == TYPE_COLOR) {
						generate_mipmaps = true;
					}
				}
			}
			region->set_modified(true);
			region->sanitize_maps();
		}
	}
	update_maps(TYPE_MAX, true, generate_mipmaps);

	if (_master_height_range.y - _master_height_range.x < 2.f) {
		Ref<Image> htimg = p_images[TYPE_HEIGHT];
		if (htimg.is_valid() && !htimg->is_empty()) {
			LOG(WARN, "No heights > 2m detected. Are you importing a normalized (0-1) heightmap? Scale it 300-500x");
		}
	}
}

/** Exports a specified map as one of r16/raw, exr, jpg, png, webp, res, tres
 * r16 or exr are recommended for roundtrip external editing
 * r16 can be edited by Krita, however you must know the dimensions and min/max before reimporting
 * res/tres stores in Godot's native format.
 */
Error Terrain3DData::export_image(const String &p_file_name, const MapType p_map_type, const ExportMode p_mode) const {
	if (p_map_type < 0 || p_map_type >= TYPE_MAX) {
		LOG(ERROR, "Invalid map type specified: ", p_map_type, " max: ", TYPE_MAX - 1);
		return FAILED;
	}
	if (p_file_name.is_empty()) {
		LOG(ERROR, "No file specified. Nothing to export");
		return FAILED;
	}
	if (get_region_count() == 0) {
		LOG(ERROR, "No valid regions. Nothing to export");
		return FAILED;
	}

	// Simple file name validation
	static const String bad_chars = "?*|%<>\"";
	for (int i = 0; i < bad_chars.length(); ++i) {
		for (int j = 0; j < p_file_name.length(); ++j) {
			if (bad_chars[i] == p_file_name[j]) {
				LOG(ERROR, "Invalid file path '" + p_file_name + "'");
				return FAILED;
			}
		}
	}

	// Update path delimiter
	String file_name = p_file_name.replace("\\", "/");

	// Check if p_file_name has a path and prepend "res://" if not
	bool is_simple_filename = true;
	for (int i = 0; i < file_name.length(); ++i) {
		char32_t c = file_name[i];
		if (c == '/' || c == ':') {
			is_simple_filename = false;
			break;
		}
	}
	if (is_simple_filename) {
		file_name = "res://" + file_name;
	}
	String base_path = file_name.get_basename();
	String ext = file_name.get_extension().to_lower();

	// Validate extension
	if (ext != "r16" && ext != "raw" && ext != "exr" && ext != "png" &&
			ext != "jpg" && ext != "webp" && ext != "res" && ext != "tres") {
		LOG(ERROR, "No recognized file type. See docs for valid extensions");
		return FAILED;
	}

	// Calculate terrain extents
	Vector2i top_left = V2I_MAX;
	Vector2i bottom_right = V2I_MIN;
	for (const Vector2i &region_loc : _region_locations) {
		if (region_loc.x < top_left.x) {
			top_left.x = region_loc.x;
		}
		if (region_loc.x > bottom_right.x) {
			bottom_right.x = region_loc.x;
		}
		if (region_loc.y < top_left.y) {
			top_left.y = region_loc.y;
		}
		if (region_loc.y > bottom_right.y) {
			bottom_right.y = region_loc.y;
		}
	}
	Vector2i start_pos = top_left * _region_size;
	Vector2i end_pos = (Vector2i(1, 1) + bottom_right) * _region_size;
	Vector2i export_size = end_pos - start_pos;

	LOG(MESG, "=== Terrain3D Export ===");
	LOG(MESG, "Map type: ", TYPESTR[p_map_type]);
	LOG(MESG, "Region locations: ", top_left, " to ", bottom_right);
	LOG(MESG, "Start pos: ", Vector2(start_pos) * _vertex_spacing, " to: ", Vector2(end_pos) * _vertex_spacing);

	int files_exported = 0;
	Error last_error = OK;

	if (p_mode == EXPORT_REGIONS) {
		LOG(MESG, "Mode: Per-Region (", _region_locations.size(), " regions)");

		for (const Vector2i &region_loc : _region_locations) {
			const Terrain3DRegion *region = get_region_ptr(region_loc);
			if (!region || region->is_deleted()) {
				continue;
			}

			String path = base_path + Util::location_to_string(region_loc) + "." + ext;
			Ref<Image> img = region->get_map(p_map_type);
			if (img.is_null() || img->is_empty()) {
				continue;
			}

			LOG(MESG, "Exporting: ", path);
			LOG(MESG, "  Region location: ", region_loc);
			LOG(MESG, "  Position: ", Vector2(region_loc * _region_size) * _vertex_spacing);
			LOG(MESG, "  Image Size: ", img->get_size(), " px");

			Error err = _save_export_image(p_map_type, img, path, ext);
			if (err != OK) {
				last_error = err;
			} else {
				files_exported++;
			}
		}
	} else { // EXPORT_SLICED
		const int MAX_SIZE = 16384;
		int slices_x = (export_size.x + MAX_SIZE - 1) / MAX_SIZE;
		int slices_y = (export_size.y + MAX_SIZE - 1) / MAX_SIZE;

		LOG(MESG, "Mode: Sliced (", slices_x, " x ", slices_y, " slices, max ", MAX_SIZE, " px)");

		for (int sy = 0; sy < slices_y; sy++) {
			for (int sx = 0; sx < slices_x; sx++) {
				Vector2i slice_origin = start_pos + Vector2i(sx * MAX_SIZE, sy * MAX_SIZE);
				Vector2i slice_size;
				slice_size.x = MIN(MAX_SIZE, start_pos.x + export_size.x - slice_origin.x);
				slice_size.y = MIN(MAX_SIZE, start_pos.y + export_size.y - slice_origin.y);

				Ref<Image> img = layered_to_image(p_map_type, Rect2i(slice_origin, slice_size));
				if (img.is_null() || img->is_empty()) {
					continue;
				}

				String suffix = (slices_x == 1 && slices_y == 1) ? "" : vformat("_slice_%02d_%02d", sx, sy);
				String path = base_path + suffix + "." + ext;

				LOG(MESG, "Exporting: ", path);
				LOG(MESG, "  Position: ", Vector2(slice_origin) * _vertex_spacing);
				LOG(MESG, "  Image Size: ", img->get_size(), "px");

				Error err = _save_export_image(p_map_type, img, path, ext);
				if (err != OK) {
					last_error = err;
				} else {
					files_exported++;
				}
			}
		}
	}

	LOG(MESG, "=== Export complete: ", files_exported, " file(s) ===");
	return last_error;
}

Ref<Image> Terrain3DData::layered_to_image(const MapType p_map_type, const Rect2i &p_bounds) const {
	LOG(INFO, "Generating an image for all regions, including empty regions, within ", p_bounds);
	MapType map_type = p_map_type;
	if (map_type < TYPE_HEIGHT || map_type >= TYPE_MAX) {
		LOG(ERROR, "Map type: ", p_map_type, " does not exist");
		return Ref<Image>();
	}
	if (_region_locations.is_empty()) {
		return Ref<Image>();
	}

	// Identify outside region coordinate bounds
	Vector2i top_left = V2I_MAX;
	Vector2i bottom_right = V2I_MIN;
	for (const Vector2i &region_loc : _region_locations) {
		LOG(DEBUG, "Region location: ", region_loc);
		if (region_loc.x < top_left.x) {
			top_left.x = region_loc.x;
		}
		if (region_loc.x > bottom_right.x) {
			bottom_right.x = region_loc.x;
		}
		if (region_loc.y < top_left.y) {
			top_left.y = region_loc.y;
		}
		if (region_loc.y > bottom_right.y) {
			bottom_right.y = region_loc.y;
		}
	}

	LOG(DEBUG, "Found active regions: ", top_left, " to ", bottom_right);
	Vector2i start_pos = top_left * _region_size;
	Vector2i export_size = Vector2i(1 + bottom_right.x - top_left.x, 1 + bottom_right.y - top_left.y) * _region_size;
	Rect2i data_rect(start_pos, export_size);
	Rect2i export_rect = p_bounds.has_area() ? p_bounds.intersection(data_rect) : data_rect;
	if (!export_rect.has_area()) {
		LOG(ERROR, "Export bounds don't intersect terrain data");
		return Ref<Image>();
	}

	LOG(DEBUG, "Export rect: ", export_rect);
	Ref<Image> img = Util::get_filled_image(export_rect.size, COLOR[map_type], false, FORMAT[map_type]);

	for (const Vector2i &region_loc : _region_locations) {
		const Terrain3DRegion *region = get_region_ptr(region_loc);
		if (!region) {
			continue;
		}
		Rect2i region_rect(region_loc * _region_size, _region_sizev);
		Rect2i overlap = region_rect.intersection(export_rect);
		if (!overlap.has_area()) {
			continue;
		}
		Rect2i src_rect(overlap.position - region_rect.position, overlap.size);
		Vector2i dst_pos = overlap.position - export_rect.position;
		LOG(DEBUG, "Region ", region_loc, ": src=", src_rect, " dst=", dst_pos);
		img->blit_rect(region->get_map(map_type), src_rect, dst_pos);
	}
	return img;
}
