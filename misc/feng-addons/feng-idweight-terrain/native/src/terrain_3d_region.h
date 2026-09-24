// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_REGION_CLASS_H
#define TERRAIN3D_REGION_CLASS_H

#include <godot_cpp/classes/image.hpp>

#include "constants.h"
#include "terrain_3d_util.h"

class Terrain3DRegion : public Resource {
	GDCLASS(Terrain3DRegion, Resource);
	CLASS_NAME();

public: // Constants
	enum MapType {
		TYPE_HEIGHT,
		TYPE_CONTROL,
		TYPE_COLOR,
		TYPE_MAX,
	};

	static inline const Image::Format FORMAT[] = {
		Image::FORMAT_RF, // TYPE_HEIGHT
		Image::FORMAT_RF, // TYPE_CONTROL
		Image::FORMAT_RGBA8, // TYPE_COLOR
		Image::Format(TYPE_MAX), // Proper size of array instead of FORMAT_MAX
	};

	static inline const char *TYPESTR[] = {
		"TYPE_HEIGHT",
		"TYPE_CONTROL",
		"TYPE_COLOR",
		"TYPE_MAX",
	};

	static inline const Color COLOR[] = {
		COLOR_BLACK, // TYPE_HEIGHT
		COLOR_CONTROL, // TYPE_CONTROL
		COLOR_ROUGHNESS, // TYPE_COLOR
		COLOR_NAN, // TYPE_MAX, unused just in case someone indexes the array
	};

	// Surface source resolution, in texels per region texel (i.e. per metre at the
	// default 1 m vertex spacing). 1 means the surface map is region_size squared.
	static inline const int SURFACE_DENSITY_MIN = 1;
	static inline const int SURFACE_DENSITY_MAX = 8;
	// Hard cap on the stored surface map edge, so region_size 2048 cannot ask for a
	// 16384 squared image (512 MB per region).
	static inline const int SURFACE_MAP_MAX_SIZE = 8192;

private:
	// Saved data
	real_t _version = 0.8f; // Set to first version to ensure we always upgrades this
	int _region_size = 0;
	Vector2 _height_range = V2_ZERO;
	// Maps
	Ref<Image> _height_map;
	Ref<Image> _control_map;
	Ref<Image> _color_map;
	// Optional versioned surface payload. Legacy maps remain untouched during migration.
	Ref<Image> _surface_map;
	int _surface_version = 0;
	// Resolution the stored surface payload was authored at. Absent in files written
	// before surface_density existed, so it defaults to 1 there. The terrain's
	// surface_density is the authority; this field only records what is on disk.
	int _surface_density = SURFACE_DENSITY_MIN;
	// Instancer
	Dictionary _instances; // Meshes{int} -> Cells{v2i} -> [ Transform3D, Color, Modified ]
	real_t _vertex_spacing = 1.f; // Spacing that instancer transforms are currently scaled by.

	// Working data not saved to disk
	bool _deleted = false; // Marked for deletion on save
	bool _edited = false; // Marked for undo/redo storage
	bool _modified = false; // Marked for saving
	Vector2i _location = V2I_MAX;

public:
	Terrain3DRegion() {}
	~Terrain3DRegion() {}

	void clear();
	void set_version(const real_t p_version);
	real_t get_version() const { return _version; }
	void set_region_size(const int p_region_size);
	int get_region_size() const { return _region_size; }

	// Maps
	void set_map(const MapType p_map_type, const Ref<Image> &p_image);
	Ref<Image> get_map(const MapType p_map_type) const;
	Image *get_map_ptr(const MapType p_map_type) const;
	void set_maps(const TypedArray<Image> &p_maps);
	TypedArray<Image> get_maps() const;
	void set_height_map(const Ref<Image> &p_map);
	Ref<Image> get_height_map() const { return _height_map; }
	void set_control_map(const Ref<Image> &p_map);
	Ref<Image> get_control_map() const { return _control_map; }
	void set_color_map(const Ref<Image> &p_map);
	Ref<Image> get_color_map() const { return _color_map; }
	void set_surface_map(const Ref<Image> &p_map);
	Ref<Image> get_surface_map() const { return _surface_map; }
	Image *get_surface_map_ptr() const { return _surface_map.is_valid() ? _surface_map.ptr() : nullptr; }
	void set_surface_version(int p_version);
	int get_surface_version() const { return _surface_version; }
	void set_surface_density(const int p_density);
	int get_surface_density() const { return _surface_density; }
	// Edge of the stored surface payload: region_size * surface_density.
	int get_surface_map_size() const;
	// The image the region texture array carries: the stored payload when the
	// density is 1, otherwise a nearest region_size squared reduction of it. The
	// array is the fallback and must not grow with the density.
	Ref<Image> get_surface_map_array_image() const;
	bool ensure_surface_map();
	// Adopts p_density and resamples an existing surface map to it. Never re-derives
	// the payload from the legacy control map: after migration its material bits are
	// stale, so re-converting would wipe the painted materials.
	bool ensure_surface_density(const int p_density);
	Dictionary create_surface_conversion() const;
	void sanitize_maps();
	Ref<Image> sanitize_map(const MapType p_map_type, const Ref<Image> &p_map) const;
	bool validate_map_size(const Ref<Image> &p_map) const;

	void set_height_range(const Vector2 &p_range);
	Vector2 get_height_range() const { return _height_range; }
	void update_height(const real_t p_height);
	void update_heights(const Vector2 &p_low_high);
	void calc_height_range();

	// Instancer
	void set_instances(const Dictionary &p_instances);
	Dictionary get_instances() const { return _instances; }
	void set_vertex_spacing(const real_t p_vertex_spacing) { _vertex_spacing = CLAMP(p_vertex_spacing, 0.25f, 100.f); }
	real_t get_vertex_spacing() const { return _vertex_spacing; }

	// Working Data
	void set_deleted(const bool p_deleted) { _deleted = p_deleted; }
	bool is_deleted() const { return _deleted; }
	void set_edited(const bool p_edited) { _edited = p_edited; }
	bool is_edited() const { return _edited; }
	void set_modified(const bool p_modified) { _modified = p_modified; }
	bool is_modified() const { return _modified; }
	void set_location(const Vector2i &p_location);
	Vector2i get_location() const { return _location; }

	// File I/O
	Error save(const String &p_path = "", const bool p_16_bit = false);

	// Utility
	void set_data(const Dictionary &p_data);
	Dictionary get_data() const;
	Ref<Terrain3DRegion> duplicate(const bool p_deep = false);
	void dump(const bool verbose = false) const;

protected:
	static void _bind_methods();
};

using MapType = Terrain3DRegion::MapType;
VARIANT_ENUM_CAST(Terrain3DRegion::MapType);
constexpr Terrain3DRegion::MapType TYPE_HEIGHT = Terrain3DRegion::MapType::TYPE_HEIGHT;
constexpr Terrain3DRegion::MapType TYPE_CONTROL = Terrain3DRegion::MapType::TYPE_CONTROL;
constexpr Terrain3DRegion::MapType TYPE_COLOR = Terrain3DRegion::MapType::TYPE_COLOR;
constexpr Terrain3DRegion::MapType TYPE_MAX = Terrain3DRegion::MapType::TYPE_MAX;
constexpr inline const Image::Format *FORMAT = Terrain3DRegion::FORMAT;
constexpr inline const char **TYPESTR = Terrain3DRegion::TYPESTR;
constexpr inline const Color *COLOR = Terrain3DRegion::COLOR;

// Inline functions

// The height range's two widening rules, shared by a region's own range and by the data's master
// range: a range grows to include a height, or to include another range. Returning whether it grew
// is what lets the region mark itself modified without testing the range a second time.
inline bool merge_height_range(Vector2 &r_range, const real_t p_height) {
	if (p_height < r_range.x) {
		r_range.x = p_height;
		return true;
	}
	if (p_height > r_range.y) {
		r_range.y = p_height;
		return true;
	}
	return false;
}

inline bool merge_height_range(Vector2 &r_range, const Vector2 &p_low_high) {
	bool grew = false;
	if (p_low_high.x < r_range.x) {
		r_range.x = p_low_high.x;
		grew = true;
	}
	if (p_low_high.y > r_range.y) {
		r_range.y = p_low_high.y;
		grew = true;
	}
	return grew;
}

inline void Terrain3DRegion::update_height(const real_t p_height) {
	if (merge_height_range(_height_range, p_height)) {
		_modified = true;
	}
}

inline void Terrain3DRegion::update_heights(const Vector2 &p_low_high) {
	if (merge_height_range(_height_range, p_low_high)) {
		_modified = true;
	}
}

#endif // TERRAIN3D_REGION_CLASS_H
