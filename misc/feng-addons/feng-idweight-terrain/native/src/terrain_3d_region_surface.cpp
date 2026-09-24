// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3DRegion, part 2 of 3: the R16 IdWeight surface map.

// One of three files that define a region. The surface map is authored and stored differently from
// the three legacy maps: one region texel is a whole density x density block of packed material
// IDs, so it is resampled nearest (never averaged - averaging packed IDs is meaningless) and its
// size is `region_size * surface_density` rather than `region_size`. `ensure_surface_map()` creates
// it lazily, converting a legacy control map's material pair when there is one, and
// `create_surface_conversion()` is that conversion. The file-scope `_resample_surface_map()` is
// here because these five functions are its only callers.
//
// The other two: `terrain_3d_region.cpp` (the record and its maps) and
// `terrain_3d_region_io.cpp` (save, the map dictionary, duplicate and dump).

#include "terrain_3d_region.h"

#include "logger.h"
#include "terrain_3d.h"
#include "terrain_3d_util.h"
#include "terrain_surface_idweight.h"

#include "constants.h"

#include <cstring>

// Nearest resample of an R16 surface payload. The payload is packed material IDs,
// not numbers, so averaging is meaningless: a coarser texel takes the block origin
// and a finer one replicates its source texel over the whole block. Both directions
// are `source = destination * src_size / dst_size`, the same rule the page producer
// and the shader's array fallback use.
static Ref<Image> _resample_surface_map(const Ref<Image> &p_source, const int p_dst_size) {
	if (p_source.is_null() || p_dst_size <= 0 || p_source->get_format() != IDWEIGHT_IMAGE_FORMAT) {
		return Ref<Image>();
	}
	const int src_size = p_source->get_width();
	if (src_size <= 0 || p_source->get_height() != src_size) {
		return Ref<Image>();
	}
	if (src_size == p_dst_size) {
		return p_source;
	}
	const PackedByteArray source_bytes = p_source->get_data();
	PackedByteArray destination;
	destination.resize(int64_t(p_dst_size) * p_dst_size * 2);
	const uint8_t *source = source_bytes.ptr();
	uint8_t *output = destination.ptrw();
	for (int y = 0; y < p_dst_size; y++) {
		const int src_y = int(int64_t(y) * src_size / p_dst_size);
		for (int x = 0; x < p_dst_size; x++) {
			const int src_x = int(int64_t(x) * src_size / p_dst_size);
			std::memcpy(output + (int64_t(y) * p_dst_size + x) * 2,
					source + (int64_t(src_y) * src_size + src_x) * 2, 2);
		}
	}
	return Image::create_from_data(p_dst_size, p_dst_size, false, IDWEIGHT_IMAGE_FORMAT, destination);
}

void Terrain3DRegion::set_surface_map(const Ref<Image> &p_map) {
	if (p_map.is_valid()) {
		// R16 UNORM is the only format that preserves the packed 16-bit IDs
		// bit-exactly: a numeric conversion would re-quantise them.
		ERR_FAIL_COND_MSG(p_map->get_format() != IDWEIGHT_IMAGE_FORMAT || p_map->has_mipmaps(),
				"Surface data must be R16 UNORM without mipmaps; numeric format conversion corrupts packed IDs.");
		ERR_FAIL_COND_MSG(p_map->get_width() != p_map->get_height() ||
						p_map->get_width() != get_surface_map_size(),
				"Surface map must be region_size * surface_density squared.");
	}
	if (_surface_map != p_map) {
		_surface_map = p_map;
		_modified = true;
	}
}

void Terrain3DRegion::set_surface_version(int p_version) {
	ERR_FAIL_COND_MSG(p_version < 0 || p_version > int(TerrainSurfaceIdWeight::FORMAT_VERSION),
			"Unsupported terrain surface format version.");
	if (_surface_version != p_version) {
		_surface_version = p_version;
		_modified = true;
	}
}

void Terrain3DRegion::set_surface_density(const int p_density) {
	int density = CLAMP(p_density, SURFACE_DENSITY_MIN, SURFACE_DENSITY_MAX);
	if (_region_size > 0) {
		density = MIN(density, MAX(SURFACE_DENSITY_MIN, SURFACE_MAP_MAX_SIZE / _region_size));
	}
	if (_surface_density == density) {
		return;
	}
	_surface_density = density;
	_modified = true;
}

int Terrain3DRegion::get_surface_map_size() const {
	if (_region_size <= 0) {
		return 0;
	}
	int density = CLAMP(_surface_density, SURFACE_DENSITY_MIN, SURFACE_DENSITY_MAX);
	density = MIN(density, MAX(SURFACE_DENSITY_MIN, SURFACE_MAP_MAX_SIZE / _region_size));
	return _region_size * density;
}

// The array layer stays at region_size: the texture array is the fallback and the
// far field, and growing it with the density would multiply resident VRAM by
// density squared, which is exactly the cost the virtual texture exists to avoid.
Ref<Image> Terrain3DRegion::get_surface_map_array_image() const {
	if (_surface_map.is_null()) {
		return Ref<Image>();
	}
	if (_region_size <= 0 || _surface_map->get_width() == _region_size) {
		return _surface_map;
	}
	return _resample_surface_map(_surface_map, _region_size);
}

// Adopts p_density and resamples an existing payload to it. A region without a
// surface map stays without one: creating 2 MB images for every streamed region
// that was never painted would be worse than the detail is worth.
bool Terrain3DRegion::ensure_surface_density(const int p_density) {
	const int previous_size = get_surface_map_size();
	set_surface_density(p_density);
	const int target = get_surface_map_size();
	if (target <= 0 || _surface_map.is_null()) {
		return false;
	}
	if (_surface_map->get_width() == target && _surface_map->get_height() == target) {
		return false;
	}
	Ref<Image> resampled = _resample_surface_map(_surface_map, target);
	if (resampled.is_null()) {
		LOG(ERROR, "Region ", _location, ": cannot resample surface map from ", previous_size, " to ", target);
		return false;
	}
	_surface_map = resampled;
	_surface_version = TerrainSurfaceIdWeight::FORMAT_VERSION;
	_modified = true;
	LOG(INFO, "Region ", _location, ": surface map resampled ", previous_size, " -> ", target,
			" (density ", _surface_density, ")");
	return true;
}

// Lazily creates an R16 surface map for this region. If a legacy control map
// exists, its material pair is converted; otherwise the map is blank (single
// material 0). Non-material metadata (holes, navigation, UV, auto) stays in
// the control map and is not migrated.
bool Terrain3DRegion::ensure_surface_map() {
	if (_region_size == 0) {
		LOG(ERROR, "Set region_size before creating a surface map");
		return false;
	}
	const int target = get_surface_map_size();
	if (_surface_map.is_valid() && _surface_version == TerrainSurfaceIdWeight::FORMAT_VERSION &&
			_surface_map->get_width() == target && _surface_map->get_height() == target) {
		return true;
	}
	if (_surface_map.is_valid()) {
		// An existing payload at the wrong size only needs a resample. It must NOT
		// fall through to the legacy conversion below: after migration the control
		// map no longer carries the painted materials, so re-converting would wipe
		// the region back to material 0.
		Ref<Image> resampled = _resample_surface_map(_surface_map, target);
		if (resampled.is_null()) {
			LOG(ERROR, "Region ", _location, ": cannot resample existing surface map to ", target);
			return false;
		}
		_surface_map = resampled;
		_surface_version = TerrainSurfaceIdWeight::FORMAT_VERSION;
		_modified = true;
		LOG(INFO, "Region ", _location, ": surface map resampled to ", target, " for density ", _surface_density);
		return true;
	}
	// No payload yet: convert the legacy control map, or start blank, at the
	// region's own resolution and replicate it up to the requested density.
	PackedByteArray converted;
	converted.resize(int64_t(_region_size) * _region_size * 2);
	uint8_t *destination = converted.ptrw();
	if (_control_map.is_valid() && _control_map->get_format() == Image::FORMAT_RF &&
			validate_map_size(_control_map)) {
		PackedByteArray source = _control_map->get_data();
		for (int i = 0; i < _region_size * _region_size; ++i) {
			uint32_t control;
			memcpy(&control, source.ptr() + int64_t(i) * 4, sizeof(control));
			auto value = TerrainSurfaceIdWeight::convert_legacy(control);
			TerrainSurfaceIdWeight::write_le(value.packed, destination + int64_t(i) * 2);
		}
	} else {
		// Blank: all-zero packed values encode single material 0.
		memset(destination, 0, size_t(_region_size) * _region_size * 2);
	}
	Ref<Image> base = Image::create_from_data(_region_size, _region_size, false, IDWEIGHT_IMAGE_FORMAT, converted);
	if (target == _region_size) {
		_surface_map = base;
	} else {
		_surface_map = _resample_surface_map(base, target);
		if (_surface_map.is_null()) {
			LOG(ERROR, "Region ", _location, ": cannot create surface map at ", target);
			return false;
		}
	}
	_surface_version = TerrainSurfaceIdWeight::FORMAT_VERSION;
	_modified = true;
	return true;
}

Dictionary Terrain3DRegion::create_surface_conversion() const {
	Dictionary report;
	report["success"] = false;
	if (_control_map.is_null() || _control_map->get_format() != Image::FORMAT_RF ||
			!validate_map_size(_control_map)) {
		report["error"] = "A valid legacy RF control map is required.";
		return report;
	}
	PackedByteArray source = _control_map->get_data();
	PackedByteArray converted;
	converted.resize(int64_t(_region_size) * _region_size * 2);
	uint8_t *destination = converted.ptrw();
	int auto_count = 0;
	int quantized_count = 0;
	float max_error = 0.f;
	for (int i = 0; i < _region_size * _region_size; ++i) {
		uint32_t control;
		memcpy(&control, source.ptr() + int64_t(i) * 4, sizeof(control));
		auto value = TerrainSurfaceIdWeight::convert_legacy(control);
		TerrainSurfaceIdWeight::write_le(value.packed, destination + int64_t(i) * 2);
		auto_count += int(value.needs_auto_material_bake);
		quantized_count += int(value.weight_error > 0.f);
		max_error = MAX(max_error, value.weight_error);
	}
	report["auto_material_texels"] = auto_count;
	report["quantized_texels"] = quantized_count;
	report["max_weight_error"] = max_error;
	// Automatic materials need terrain/material context. Refuse rather than silently lose them.
	if (auto_count != 0) {
		report["error"] = "Bake automatic material rules before converting this region.";
		return report;
	}
	Ref<Terrain3DRegion> copy;
	copy.instantiate();
	Dictionary data = get_data();
	data["height_map"] = _height_map.is_valid() ? _height_map->duplicate() : Ref<Resource>();
	data["control_map"] = _control_map->duplicate();
	data["color_map"] = _color_map.is_valid() ? _color_map->duplicate() : Ref<Resource>();
	data["instances"] = _instances.duplicate(true);
	copy->set_data(data);
	// The converted payload is built at the region's own resolution and then
	// replicated up to the copy's density, which set_data() carried over.
	Ref<Image> surface = Image::create_from_data(_region_size, _region_size, false, IDWEIGHT_IMAGE_FORMAT, converted);
	const int target = copy->get_surface_map_size();
	if (target > 0 && target != _region_size) {
		surface = _resample_surface_map(surface, target);
		if (surface.is_null()) {
			report["error"] = "Cannot build a surface map at the region's density.";
			return report;
		}
	}
	copy->set_surface_map(surface);
	copy->set_surface_version(TerrainSurfaceIdWeight::FORMAT_VERSION);
	// The copied control map retains non-material metadata until the runtime split is complete.
	report["region"] = copy;
	report["success"] = true;
	return report;
}
