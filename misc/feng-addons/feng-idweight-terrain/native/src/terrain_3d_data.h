// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_DATA_CLASS_H
#define TERRAIN3D_DATA_CLASS_H

#include <vector>

#include "constants.h"
#include "generated_texture.h"
#include "terrain_3d_region.h"

class Terrain3D;

// How one region file load ended. Both load paths adopt a file the same way and differ only in
// what a failure means to them: a directory skips a file it cannot read and stops on a size
// mismatch, while a single-region load stops on either. See `_load_region_file()`.
enum class RegionFileLoad : uint8_t {
	LOADED = 0,
	UNREADABLE = 1,
	SIZE_MISMATCH = 2,
};

class Terrain3DData : public Object {
	GDCLASS(Terrain3DData, Object);
	CLASS_NAME();
	friend Terrain3D;

public: // Constants
	static inline const real_t CURRENT_DATA_VERSION = 0.93f; // Current Data format version
	// The world grid. This used to be 32 because the shader read the chunk -> layer
	// map from `uniform int _region_map[1024]`, and a bigger array runs into the
	// uniform buffer limit (64x64 would already be 16 KB, 128x128 64 KB). The shader
	// now reads a *texture* instead, so the grid is only bounded by that texture and
	// the region files on disk.
	// At the default region_size of 256 m this is a 32.8 km square world, and it
	// comfortably covers the clipmap's outermost ring (2 * mesh_size 48 * 2^6 =
	// 6144 m) which the old 32x32 grid could not even fill.
	static inline const int REGION_MAP_SIZE = 128;
	static inline const Vector2i REGION_MAP_VSIZE = V2I(REGION_MAP_SIZE);
	// Hard ceiling on resident layer slots, matching the largest MAX_REGIONS the
	// material can compile (`max_regions`, 64..1024). The shader drops any layer
	// index at or above it, so the slot table must never hand one out.
	static inline const int MAX_MAP_SLOTS = 1024;

	enum HeightFilter {
		HEIGHT_FILTER_NEAREST,
		HEIGHT_FILTER_MINIMUM
	};

	enum ExportMode {
		EXPORT_SLICES,
		EXPORT_REGIONS
	};

private:
	Terrain3D *_terrain = nullptr;

	// Data Settings & flags
	int _region_size = 0; // Set by Terrain3D::set_region_size
	Vector2i _region_sizev = V2I(_region_size);
	real_t _vertex_spacing = 1.f; // Set by Terrain3D::set_vertex_spacing

	AABB _edited_area;
	Vector2 _master_height_range = V2_ZERO;

	/////////
	// Terrain3DRegions house the maps, instances, and other data for each region.
	// Regions are dual indexed:
	// 1) By `region_location:Vector2i` as the primary key. This is the only stable index
	// so should be the main index for users.
	// 2) By `region_id:int`, which is now a *slot*: a stable index into the texture
	// arrays that a region keeps for as long as it stays in memory. It is only reused
	// after the region is unloaded, so unrelated add/remove no longer renumber it.
	// See the slot table below.

	// Private functions should be indexed by region_id or region_location
	// Public functions by region_location or global_position

	// `_regions` stores all loaded Terrain3DRegions, indexed by region_location. If marked for
	// deletion they are removed from here upon saving, however they may stay in memory if tracked
	// by the Undo system.
	Dictionary _regions; // Dict[region_location:Vector2i] -> Terrain3DRegion

	// All active region maps are maintained in these secondary indices.
	// Regions are considered active if and only if they exist in `_region_locations`.
	// This list stays dense and is the user facing index; the *layer* index the shader
	// and the image arrays use is the stable slot table below.
	// The image arrays are converted to TextureArrays for the shader.

	TypedArray<Vector2i> _region_locations;
	TypedArray<Image> _height_maps;
	TypedArray<Image> _control_maps;
	TypedArray<Image> _color_maps;
	TypedArray<Image> _surface_maps;

	/////////
	// Stable layer slots.
	//
	// `region_id` used to be the index of a region inside `_region_locations`, so
	// adding or removing any region renumbered every later one and forced all four
	// Texture2DArrays to be recreated and re-uploaded. Instead each resident region
	// now owns a slot: a stable layer index that is only reused after the region
	// leaves memory. `_region_map` stores `slot + 1` exactly where it used to store
	// `region_id + 1`, so the shader side is unchanged.
	//
	// `_slot_locations` is indexed by slot and holds V2I_MAX for free slots. The
	// image arrays above are slot indexed too, so a single region change costs one
	// layer upload instead of a full array rebuild.
	//
	// The capacity grows by doubling to fit the peak resident count and never
	// shrinks, so steady streaming stops reallocating. It must stay within the
	// material's `max_regions` (64..1024) because the shader rejects layer indices
	// at or above MAX_REGIONS.

	enum SlotMap {
		SLOT_MAP_HEIGHT = 0,
		SLOT_MAP_CONTROL,
		SLOT_MAP_COLOR,
		SLOT_MAP_SURFACE,
		SLOT_MAP_MAX,
	};
	// One bit per SlotMap entry: the "every map is stale" mask _slot_dirty uses when a
	// slot is assigned, and the mask a request for TYPE_MAX resolves to. Both were the
	// literal 0xF, which would have gone on meaning four maps after a fifth was added.
	static inline const int SLOT_MAP_ALL = (1 << SLOT_MAP_MAX) - 1;

	std::vector<Vector2i> _slot_locations; // slot -> region location, V2I_MAX when free
	Dictionary _region_slots; // Dict[region_location:Vector2i] -> slot:int
	std::vector<int> _free_slots; // LIFO free list so reuse is O(1)
	// Bitmask per slot of SlotMap entries that still need a layer upload.
	std::vector<uint8_t> _slot_dirty;
	// Force a full re-upload of one slot map on the next update_maps() call.
	bool _slot_map_full[SLOT_MAP_MAX] = { false, false, false, false };
	int _slot_capacity = 0;
	// Diagnostics for get_map_stats(): a steady streaming loop should show no
	// growth, no region map rebuilds and no full slot map syncs.
	int _slot_grow_count = 0;
	int _region_map_rebuild_count = 0;
	int _slot_full_sync_count = 0;

	int _acquire_slot(const Vector2i &p_region_loc);
	void _release_slot(const Vector2i &p_region_loc);
	void _reset_slots();
	void _grow_slot_capacity(const int p_needed);
	void _mark_slot_dirty(const int p_slot, const int p_maps);
	void _rebuild_region_map();
	// Chunk directory texture: mirrors _region_map for the shader.
	void _set_directory_entry(const int p_index, const int p_value);
	void _rebuild_region_directory();
	void _update_region_directory();
	// Cached blank layer per SlotMap, rebuilt only when the region size changes.
	// Every free layer and every region without a surface map shares it, so it must
	// stay read-only.
	Ref<Image> _blank_slot_maps[SLOT_MAP_MAX];
	Ref<Image> _get_blank_slot_map(const int p_slot_map);
	Ref<Image> _get_slot_map_image(const Terrain3DRegion *p_region, const int p_slot_map) const;
	bool _sync_slot_map(const int p_slot_map);
	static bool _slot_map_requested(const MapType p_map_type, const int p_slot_map);
	static int _slot_map_mask(const MapType p_map_type);
	// Samples whichever region owns a world position, on that region's density grid.
	// Page border texels belong to the neighbouring regions, so this is what keeps a
	// page seam reading real data instead of a copy of the page's own edge.
	uint16_t _sample_payload_world(const real_t p_world_x, const real_t p_world_z) const;

	// Editing occurs on the Image arrays above, which are converted to Texture arrays
	// below for the shader.

	// 32x32 grid with region_id:int at its location, no region = 0, region_ids >= 1
	PackedInt32Array _region_map;
	// GPU side of `_region_map`: a REGION_MAP_SIZE square R32F texture the shader
	// reads with texelFetch. Slot + 1 as a float, 0.0 = no region.
	Ref<Image> _region_directory_image;
	GeneratedTexture _region_directory;
	bool _region_directory_dirty = true;
	// _region_map_dirty means "recompute the whole map and the slot table".
	// _region_map_signal_dirty means "the map changed, tell the listeners", which
	// is now a separate concern because a single region add/remove patches
	// _region_map in place instead of rebuilding it.
	bool _region_map_dirty = true;
	bool _region_map_signal_dirty = true;

	// These contain the TextureArray RIDs from the RenderingServer
	GeneratedTexture _generated_height_maps;
	GeneratedTexture _generated_control_maps;
	GeneratedTexture _generated_color_maps;
	GeneratedTexture _generated_surface_maps;

	// Functions
	void _clear();
	// One region file, loaded, size-checked and adopted, for both load paths. It returns the
	// verdict instead of handling it because that is the one place the two callers differ.
	RegionFileLoad _load_region_file(const String &p_path, const Vector2i &p_region_loc, const bool p_update);
	void _copy_paste_dfr(const Terrain3DRegion *p_src_region, const Rect2i &p_src_rect, const Rect2i &p_dst_rect, const Terrain3DRegion *p_dst_region);
	Error _save_export_image(const MapType p_map_type, const Ref<Image> &p_img, const String &p_path, const String &p_ext) const;

public:
	Terrain3DData() {}
	void initialize(Terrain3D *p_terrain);
	~Terrain3DData() { _clear(); }

	// Regions

	int get_region_count() const { return _region_locations.size(); }
	void set_region_locations(const TypedArray<Vector2i> &p_locations);
	TypedArray<Vector2i> get_region_locations() const { return _region_locations; }
	TypedArray<Terrain3DRegion> get_regions_active(const bool p_copy = false, const bool p_deep = false) const;
	Dictionary get_regions_all() const { return _regions; }
	PackedInt32Array get_region_map() const { return _region_map; }
	static int get_region_map_index(const Vector2i &p_region_loc);
	// The chunk -> layer directory the shader samples as `_region_map`.
	RID get_region_directory_rid() const { return _region_directory.get_rid(); }
	bool is_region_directory_valid() const { return _region_directory.get_rid().is_valid(); }
	// Builds the R32F directory image from a region map array. Bound so the editor
	// preview, which writes a negative dummy entry for the hovered chunk, can build
	// its own copy without disturbing the live directory.
	Ref<Image> region_map_to_image(const PackedInt32Array &p_region_map);

	// Slot table accessors. `get_slot_locations()` is the layer -> region location
	// array the shader reads as `_region_locations`; free slots hold V2I_MAX and
	// are never addressed by the region map.
	int get_map_capacity() const { return _slot_capacity; }
	PackedVector2Array get_slot_locations() const;
	Dictionary get_map_stats() const;
	void reset_map_stats();

	void do_for_regions(const Rect2i &p_area, const Callable &p_callback);
	void change_region_size(int region_size);
	// Adopts a new surface resolution for every resident region: each stored surface
	// payload is resampled (never re-derived from the legacy control map), and only
	// the surface array layers are re-uploaded.
	void change_surface_density(int density);

	Vector2i world_to_vgrid(const Vector3 &p_global_position) const;
	Vector2i get_region_location(const Vector3 &p_global_position) const;
	int get_region_id(const Vector2i &p_region_loc) const;
	int get_region_idp(const Vector3 &p_global_position) const;

	bool has_region(const Vector2i &p_region_loc) const { return get_region_id(p_region_loc) != -1; }
	bool has_regionp(const Vector3 &p_global_position) const { return get_region_idp(p_global_position) != -1; }
	Ref<Terrain3DRegion> get_region(const Vector2i &p_region_loc) const;
	Terrain3DRegion *get_region_ptr(const Vector2i &p_region_loc) const;
	template <typename T> // Catch invalid types. See note below in implementation.
	Terrain3DRegion *get_region_ptr(const T &p_region_loc) const = delete;
	Ref<Terrain3DRegion> get_regionp(const Vector3 &p_global_position) const;

	void set_region_modified(const Vector2i &p_region_loc, const bool p_modified = true);
	bool is_region_modified(const Vector2i &p_region_loc) const;
	void set_region_deleted(const Vector2i &p_region_loc, const bool p_deleted = true);
	bool is_region_deleted(const Vector2i &p_region_loc) const;

	Ref<Terrain3DRegion> add_region_blankp(const Vector3 &p_global_position, const bool p_update = true);
	Ref<Terrain3DRegion> add_region_blank(const Vector2i &p_region_loc, const bool p_update = true);
	Error add_region(const Ref<Terrain3DRegion> &p_region, const bool p_update = true);
	void remove_regionp(const Vector3 &p_global_position, const bool p_update = true);
	void remove_regionl(const Vector2i &p_region_loc, const bool p_update = true);
	void remove_region(const Ref<Terrain3DRegion> &p_region, const bool p_update = true);
	// Streaming: free a region from memory without deleting or rewriting its
	// file. Unlike remove_region it does not mark the region deleted.
	void unload_region(const Vector2i &p_region_loc, const bool p_update = true);

	// File I/O
	void save_directory(const String &p_dir);
	void save_region(const Vector2i &p_region_loc, const String &p_dir, const bool p_16_bit = false);
	void load_directory(const String &p_dir);
	void load_region(const Vector2i &p_region_loc, const String &p_dir, const bool p_update = true);

	// Maps
	TypedArray<Image> get_height_maps() const { return _height_maps; }
	TypedArray<Image> get_control_maps() const { return _control_maps; }
	TypedArray<Image> get_color_maps() const { return _color_maps; }
	TypedArray<Image> get_surface_maps() const { return _surface_maps; }
	TypedArray<Image> get_maps(const MapType p_map_type) const;
	void update_maps(const MapType p_map_type = TYPE_MAX, const bool p_all_regions = true, const bool p_generate_mipmaps = false);
	RID get_height_maps_rid() const { return _generated_height_maps.get_rid(); }
	RID get_control_maps_rid() const { return _generated_control_maps.get_rid(); }
	RID get_color_maps_rid() const { return _generated_color_maps.get_rid(); }
	RID get_surface_maps_rid() const { return _generated_surface_maps.get_rid(); }
	// CPU source heights for a material page. The GPU writer uses these for world
	// positions and geometric normals; this never reads the GPU height array back.
	Ref<Image> make_vt_height_page(const Rect2 &p_world_rect, int p_page_size, int p_border) const;
	// p_region_id is a layer slot: the value get_region_id() returns.
	void update_surface_region(Image *p_surface_map, const int p_region_id);

	void set_pixel(const MapType p_map_type, const Vector3 &p_global_position, const Color &p_pixel);
	Color get_pixel(const MapType p_map_type, const Vector3 &p_global_position) const;
	Color get_pixel_descaled(const MapType p_map_type, const Vector2i &p_vgrid) const;

	// Height Map
	void set_height(const Vector3 &p_global_position, const real_t p_height);
	real_t get_height(const Vector3 &p_global_position) const;
	// The height map texel under a world XZ, by nearest vertex, and 0 anywhere no height map covers
	// it. Nearest, not the bilinear `get_height()`: one clipmap texel stands for one vertex, and a
	// bilinear read would make the ring's content depend on the level's texel size. 0, not NAN: the
	// ring caches what the height map array holds, and an array sample outside a filled layer is 0,
	// so a hole and a region blend stay decisions of whoever reads the ring. See
	// terrain_3d_clipmap_source_height.h.
	real_t get_height_texel_nearest(const Vector2 &p_world_xz) const;
	// The `R16` surface payload texel under a world XZ, by nearest payload texel, as the *packed*
	// integer the shader's own corner read takes (0 anywhere no surface map covers it). Nearest for the
	// same reason as the height read above: one clipmap texel stands for one payload texel, and a read
	// that depended on the ring's own texel size would make the ring's content a function of its shape.
	// Raw rather than UNORM because the ring's layer is `FORMAT_RF`: a packed id/weight pair is not a
	// colour and must not be rescaled on either side. See terrain_3d_clipmap_source_material.h.
	uint32_t get_surface_texel_nearest(const Vector2 &p_world_xz) const;
	real_t get_surface_height(const Vector3 &p_global_position) const;
	real_t get_modified_height(const Vector2i &p_vgrid) const;
	real_t get_region_blend(const Vector2 &p_uv2) const;
	Vector3 get_normal(const Vector3 &p_global_position) const;
	bool is_in_slope(const Vector3 &p_global_position, const Vector2 &p_slope_range, const Vector3 &p_normal = V3_ZERO) const;

	// Control Map
	void set_control(const Vector3 &p_global_position, const uint32_t p_control);
	uint32_t get_control(const Vector3 &p_global_position) const;
	void set_control_base_id(const Vector3 &p_global_position, const uint8_t p_base);
	uint32_t get_control_base_id(const Vector3 &p_global_position) const;
	void set_control_overlay_id(const Vector3 &p_global_position, const uint8_t p_overlay);
	uint32_t get_control_overlay_id(const Vector3 &p_global_position) const;
	void set_control_blend(const Vector3 &p_global_position, const real_t p_blend);
	real_t get_control_blend(const Vector3 &p_global_position) const;
	Vector3 get_texture_id(const Vector3 &p_global_position) const;
	void set_control_angle(const Vector3 &p_global_position, const real_t p_angle);
	real_t get_control_angle(const Vector3 &p_global_position) const;
	void set_control_scale(const Vector3 &p_global_position, const real_t p_scale);
	real_t get_control_scale(const Vector3 &p_global_position) const;
	void set_control_hole(const Vector3 &p_global_position, const bool p_hole);
	bool get_control_hole(const Vector3 &p_global_position) const;
	void set_control_navigation(const Vector3 &p_global_position, const bool p_navigation);
	bool get_control_navigation(const Vector3 &p_global_position) const;
	void set_control_auto(const Vector3 &p_global_position, const bool p_auto);
	bool get_control_auto(const Vector3 &p_global_position) const;

	// Color Map
	void set_color(const Vector3 &p_global_position, const Color &p_color);
	Color get_color(const Vector3 &p_global_position) const;
	void set_roughness(const Vector3 &p_global_position, const real_t p_roughness);
	real_t get_roughness(const Vector3 &p_global_position) const;

	Vector3 get_mesh_vertex(const int32_t p_lod, const HeightFilter p_filter, const Vector3 &p_global_position) const;
	real_t get_mesh_vertex_height(const int32_t p_lod, const HeightFilter p_filter, const Vector2i &p_vgrid) const;

	void add_edited_area(const AABB &p_area);
	void clear_edited_area() { _edited_area = AABB(); }
	AABB get_edited_area() const { return _edited_area; }

	Vector2 get_height_range() const { return _master_height_range; }
	void update_master_height(const real_t p_height);
	void update_master_heights(const Vector2 &p_low_high);
	void calc_height_range(const bool p_recursive = false);

	void import_images(const TypedArray<Image> &p_images, const Vector3 &p_global_position = V3_ZERO,
			const real_t p_offset = 0.f, const real_t p_scale = 1.f);
	Error export_image(const String &p_file_name, const MapType p_map_type = TYPE_HEIGHT, const ExportMode p_mode = EXPORT_SLICES) const;
	Ref<Image> layered_to_image(const MapType p_map_type, const Rect2i &p_bounds = Rect2i()) const;

	// Utility
	void dump(const bool verbose = false) const;

	// Virtual texture page production.
	//
	// Resamples a sector's surface map into the requested pages. Each request is
	// (page_x, page_y, local_mip), and pages come back in request order. The page grid
	// is derived from `p_pages_per_axis` at mip 0, so the sampling is correct whether a
	// page carries the region's texels 1:1 or at a different density: today the source
	// is region_size texels, so a page smaller than the region upsamples and a page
	// larger than the region downsamples.
	// Returns the number of pages written, or -1 when the region or the arguments are
	// unusable.
	int produce_surface_page_set(const Vector2i &p_region_loc, const int p_pages_per_axis,
			const int p_page_size, const int p_border, const std::vector<Vector3i> &p_requests,
			std::vector<Ref<Image>> &r_pages);

	// Far-field (sparse virtual texture) page production. Unlike the region-aligned
	// producer above, this one is world aligned: every page texel maps to a world
	// position and takes the payload of whichever region owns it. A page may therefore
	// span several regions, and its border texels come from the neighbours instead of a
	// clamped copy -- which is what keeps a bilinear tap at a page seam correct.
	//
	// `p_page_x/p_page_y` address the page at `p_local_mip`, where one page covers
	// `p_page_world_size << p_local_mip` metres. Texels with no region behind them are
	// material 0. Returns the stored page size, or -1 on unusable arguments.
	int produce_surface_rect_page(const Rect2 &p_rect, int p_page_size, int p_border, Ref<Image> &r_page);
	int produce_sparse_surface_page(const int p_page_x, const int p_page_y, const int p_local_mip,
			const real_t p_page_world_size, const int p_page_size, const int p_border,
			Ref<Image> &r_page);
	// Binding-friendly form of the above, for tests and tooling.
	Ref<Image> make_sparse_surface_page(const int p_page_x, const int p_page_y, const int p_local_mip,
			const real_t p_page_world_size, const int p_page_size, const int p_border);

protected:
	static void _bind_methods();
};

VARIANT_ENUM_CAST(Terrain3DData::HeightFilter);
VARIANT_ENUM_CAST(Terrain3DData::ExportMode);

// Inline Region Functions

// Verifies the location is within the bounds of the _region_map array and
// the world, returning the _region_map index, which contains the layer slot.
// Valid region locations are -REGION_MAP_SIZE/2 to REGION_MAP_SIZE/2 - 1, which
// offsets to 0 .. REGION_MAP_SIZE - 1. Any bit above the grid's own bits set means
// out of bounds and returns -1.
inline int Terrain3DData::get_region_map_index(const Vector2i &p_region_loc) {
	// Offset world to positive values only
	Vector2i loc = p_region_loc + (REGION_MAP_VSIZE / 2);
	// Catch values >= REGION_MAP_SIZE
	if ((uint32_t(loc.x | loc.y) & uint32_t(~(REGION_MAP_SIZE - 1))) > 0) {
		return -1;
	}
	return loc.y * REGION_MAP_SIZE + loc.x;
}

// Returns a region location given a global position. No bounds checking nor data access.
inline Vector2i Terrain3DData::get_region_location(const Vector3 &p_global_position) const {
	return V2I_DIVIDE_FLOOR(world_to_vgrid(p_global_position), _region_size);
}

// Returns id of any active region. -1 if out of bounds or no region, or region id
inline int Terrain3DData::get_region_id(const Vector2i &p_region_loc) const {
	int map_index = get_region_map_index(p_region_loc);
	if (map_index >= 0 && map_index < _region_map.size()) {
		int slot = _region_map[map_index] - 1; // 0 = no region
		// Validate against the slot table instead of trusting the region map, so a
		// stale _region_map cannot report a slot that now belongs to another region
		// or has been freed. That also makes has_region() correct immediately after
		// add_region()/unload_region(), before the next update_maps().
		if (slot >= 0 && slot < (int)_slot_locations.size() && _slot_locations[slot] == p_region_loc) {
			return slot;
		}
	}
	return -1;
}

inline int Terrain3DData::get_region_idp(const Vector3 &p_global_position) const {
	return get_region_id(get_region_location(p_global_position));
}

// This function is slower than the version below, but safer when interacting with Godot, which requires
// References. This includes backing up regions in the UndoRedoManager.
// Ref<> has a pointer constructor, so a reference can be created with Ref<>(ptr). Godot detects the
// pointer is already tracked and increments the reference counter.
// Passing the pointer to a function with a Ref<> parameter works, and there's an implicit conversion to Ref.
// However, let's require explicit conversions for clarity, so wrap a Ref around it:
// eg. backup_region(Ref<Terrain3D>(raw_ptr));
// Should be used for most functions in Editor and Instancer.
inline Ref<Terrain3DRegion> Terrain3DData::get_region(const Vector2i &p_region_loc) const {
	return _regions.get(p_region_loc, Ref<Terrain3DRegion>());
}

// Using the raw pointer is faster than creating a Ref<>. It can also safely be converted to a Ref as needed
// with Ref<>(ptr). Use this function when retreiving regions frequently, eg looping over get_pixel().
// Should be used for most data processing in Data, but not region handling.
// Re overloaded template
// get_region_ptr(region_locs[i]) worked with an implicit conversion of Variant::Vector2i to Vector2i.
// However it also worked for Variant::Object, which silently sent invalid data.
// The overloaded template was added to catch this. Pulling out of a dictionary/array gives a Variant,
// so now explicit conversion is required, eg. get_region_ptr(Vector2i(locs[i])).
inline Terrain3DRegion *Terrain3DData::get_region_ptr(const Vector2i &p_region_loc) const {
	if (_regions.has(p_region_loc)) {
		return cast_to<Terrain3DRegion>(_regions[p_region_loc]);
	}
	return nullptr;
}

inline Ref<Terrain3DRegion> Terrain3DData::get_regionp(const Vector3 &p_global_position) const {
	return _regions.get(get_region_location(p_global_position), Ref<Terrain3DRegion>());
}

// Inline Map Functions

// Descale and floor global position to vertex grid
inline Vector2i Terrain3DData::world_to_vgrid(const Vector3 &p_global_position) const {
	return Vector2i(Math::floor(p_global_position.x / _vertex_spacing),
			Math::floor(p_global_position.z / _vertex_spacing));
}

inline Color Terrain3DData::get_pixel(const MapType p_map_type, const Vector3 &p_global_position) const {
	return get_pixel_descaled(p_map_type, world_to_vgrid(p_global_position));
}

inline void Terrain3DData::set_height(const Vector3 &p_global_position, const real_t p_height) {
	set_pixel(TYPE_HEIGHT, p_global_position, Color(p_height, 0.f, 0.f, 1.f));
}

inline real_t Terrain3DData::get_height(const Vector3 &p_global_position) const {
	return get_pixel(TYPE_HEIGHT, p_global_position).r;
}

inline void Terrain3DData::set_control(const Vector3 &p_global_position, const uint32_t p_control) {
	set_pixel(TYPE_CONTROL, p_global_position, Color(as_float(p_control), 0.f, 0.f, 1.f));
}

inline uint32_t Terrain3DData::get_control(const Vector3 &p_global_position) const {
	// Always float: control map is packed as a float32 Color component
	// regardless of engine precision.
	float val = get_pixel(TYPE_CONTROL, p_global_position).r;
	return (std::isnan(val)) ? UINT32_MAX : as_uint(val);
}

inline void Terrain3DData::set_control_base_id(const Vector3 &p_global_position, const uint8_t p_base) {
	uint32_t control = get_control(p_global_position);
	uint8_t base = CLAMP(p_base, uint8_t(0), uint8_t(31));
	set_control(p_global_position, (control & ~(0x1F << 27)) | enc_base(base));
}

inline uint32_t Terrain3DData::get_control_base_id(const Vector3 &p_global_position) const {
	uint32_t control = get_control(p_global_position);
	return control == UINT32_MAX ? UINT32_MAX : get_base(control);
}

inline void Terrain3DData::set_control_overlay_id(const Vector3 &p_global_position, const uint8_t p_overlay) {
	uint32_t control = get_control(p_global_position);
	uint8_t overlay = CLAMP(p_overlay, uint8_t(0), uint8_t(31));
	set_control(p_global_position, (control & ~(0x1F << 22)) | enc_overlay(overlay));
}

inline uint32_t Terrain3DData::get_control_overlay_id(const Vector3 &p_global_position) const {
	uint32_t control = get_control(p_global_position);
	return control == UINT32_MAX ? UINT32_MAX : get_overlay(control);
}

// Expects 0.0 to 1.0 range
inline void Terrain3DData::set_control_blend(const Vector3 &p_global_position, const real_t p_blend) {
	uint32_t control = get_control(p_global_position);
	uint8_t blend = uint8_t(CLAMP(Math::round(p_blend * 255.f), 0.f, 255.f));
	set_control(p_global_position, (control & ~(0xFF << 14)) | enc_blend(blend));
}

inline real_t Terrain3DData::get_control_blend(const Vector3 &p_global_position) const {
	uint32_t control = get_control(p_global_position);
	return control == UINT32_MAX ? NAN : real_t(get_blend(control)) / 255.f;
}

// Expects angle in degrees
inline void Terrain3DData::set_control_angle(const Vector3 &p_global_position, const real_t p_angle) {
	uint32_t control = get_control(p_global_position);
	uint8_t uvrotation = uint8_t(CLAMP(Math::round(p_angle / 22.5f), 0.f, 15.f));
	set_control(p_global_position, (control & ~(0xF << 10)) | enc_uv_rotation(uvrotation));
}

// Returns angle in degrees
inline real_t Terrain3DData::get_control_angle(const Vector3 &p_global_position) const {
	uint32_t control = get_control(p_global_position);
	real_t angle = real_t(get_uv_rotation(control)) * 22.5f;
	return control == UINT32_MAX ? NAN : angle;
}

// Expects scale as a percentage modifier
inline void Terrain3DData::set_control_scale(const Vector3 &p_global_position, const real_t p_scale) {
	uint32_t control = get_control(p_global_position);
	std::array<uint32_t, 8> scale_align = { 5, 6, 7, 0, 1, 2, 3, 4 };
	uint8_t uvscale = scale_align[uint8_t(CLAMP(Math::round((p_scale + 60.f) / 20.f), 0.f, 7.f))];
	set_control(p_global_position, (control & ~(0x7 << 7)) | enc_uv_scale(uvscale));
}

inline real_t Terrain3DData::get_control_scale(const Vector3 &p_global_position) const {
	uint32_t control = get_control(p_global_position);
	std::array<real_t, 8> scale_values = { 0.0f, 20.0f, 40.0f, 60.0f, 80.0f, -60.0f, -40.0f, -20.0f };
	real_t scale = scale_values[get_uv_scale(control)]; //select from array UI return values
	return control == UINT32_MAX ? NAN : scale;
}

inline void Terrain3DData::set_control_hole(const Vector3 &p_global_position, const bool p_hole) {
	uint32_t control = get_control(p_global_position);
	set_control(p_global_position, (control & ~(0x1 << 2)) | enc_hole(p_hole));
}

inline bool Terrain3DData::get_control_hole(const Vector3 &p_global_position) const {
	uint32_t control = get_control(p_global_position);
	return control == UINT32_MAX ? false : is_hole(control);
}

inline void Terrain3DData::set_control_navigation(const Vector3 &p_global_position, const bool p_navigation) {
	uint32_t control = get_control(p_global_position);
	set_control(p_global_position, (control & ~(0x1 << 1)) | enc_nav(p_navigation));
}

inline bool Terrain3DData::get_control_navigation(const Vector3 &p_global_position) const {
	uint32_t control = get_control(p_global_position);
	return control == UINT32_MAX ? false : is_nav(control);
}

inline void Terrain3DData::set_control_auto(const Vector3 &p_global_position, const bool p_auto) {
	uint32_t control = get_control(p_global_position);
	set_control(p_global_position, (control & ~(0x1)) | enc_auto(p_auto));
}

inline bool Terrain3DData::get_control_auto(const Vector3 &p_global_position) const {
	uint32_t control = get_control(p_global_position);
	return control == UINT32_MAX ? false : is_auto(control);
}

inline void Terrain3DData::set_color(const Vector3 &p_global_position, const Color &p_color) {
	Color clr = p_color;
	clr.a = get_roughness(p_global_position);
	set_pixel(TYPE_COLOR, p_global_position, clr);
}

inline Color Terrain3DData::get_color(const Vector3 &p_global_position) const {
	Color clr = get_pixel(TYPE_COLOR, p_global_position);
	clr.a = 1.0f;
	return clr;
}

inline void Terrain3DData::set_roughness(const Vector3 &p_global_position, const real_t p_roughness) {
	Color clr = get_pixel(TYPE_COLOR, p_global_position);
	clr.a = p_roughness;
	set_pixel(TYPE_COLOR, p_global_position, clr);
}

inline real_t Terrain3DData::get_roughness(const Vector3 &p_global_position) const {
	return get_pixel(TYPE_COLOR, p_global_position).a;
}

inline void Terrain3DData::update_master_height(const real_t p_height) {
	if (p_height < _master_height_range.x) {
		_master_height_range.x = p_height;
	} else if (p_height > _master_height_range.y) {
		_master_height_range.y = p_height;
	}
}

inline void Terrain3DData::update_master_heights(const Vector2 &p_low_high) {
	if (p_low_high.x < _master_height_range.x) {
		_master_height_range.x = p_low_high.x;
	}
	if (p_low_high.y > _master_height_range.y) {
		_master_height_range.y = p_low_high.y;
	}
}

#endif // TERRAIN3D_DATA_CLASS_H
