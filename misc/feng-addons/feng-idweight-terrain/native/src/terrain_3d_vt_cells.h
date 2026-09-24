// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_VT_CELL_STORE_CLASS_H
#define TERRAIN3D_VT_CELL_STORE_CLASS_H

#include "constants.h"

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <cstdint>
#include <unordered_map>
#include <vector>

/**
 * Resident SVT cell sources.
 *
 * A cell is the offline-baked material picture of one region-sized square: three
 * RGBA16F channels (albedo+height, normal+roughness, parameters) with a full mip chain.
 * Far-field pages are assembled from several of them, and the page producer used to read
 * those channels back from the bake file for every page it built, on a worker thread,
 * for every frame a page appeared.
 *
 * This store keeps the baked channels in three GPU arrays instead, one layer per cell, so
 * page assembly is a device-to-device copy that touches no file. The bake file stays the
 * persistent artifact: it is imported once per cell, and every page after that is served
 * from device memory.
 *
 * Layer ownership is explicit. A cell owns one layer until it is replaced or evicted; the
 * store reports the layer with the cell so the page assembly can bind exactly that layer's
 * mip view. Nothing here writes a page or decides residency - the virtual texture view
 * does that, and it is the only reader of this store.
 */
class Terrain3DCellStore : public godot::RefCounted {
	GDCLASS(Terrain3DCellStore, godot::RefCounted);
	CLASS_NAME();

public:
	// One published cell. `layer` is only valid while the store holds the cell, and the
	// registry entry is what makes it discoverable.
	struct Cell {
		int layer = -1;
		int resolution = 0;
		int levels = 0;
		uint32_t signature = 0;
		godot::Rect2 world_rect;
		uint64_t last_use = 0;
	};

	// Creates the channel arrays. `p_resolution` is the side of one cell at mip 0 and
	// therefore the level count; a cell baked at another resolution is refused rather
	// than silently resampled.
	void initialize(godot::RenderingDevice *p_rd, int p_layer_capacity, int p_resolution);
	// Releases every array. Views created by get_sample_view() must be freed by their
	// caller before this, which is why the page assembly frees them per piece.
	void clear();

	bool is_initialized() const { return _rd != nullptr && _layers > 0 && _level_count > 0; }
	int get_resolution() const { return _resolution; }
	int get_level_count() const { return _level_count; }
	int get_cell_count() const { return int(_cells.size()); }

	// A cell is only reusable when it was baked from the same material and edit state,
	// which is what the signature carries.
	const Cell *find_cell(const godot::Vector2i &p_cell, uint32_t p_signature) const;
	// Publishes one baked cell. The channels are the mipmapped images the bake produced;
	// a chain that stops short of the store's level count is padded with its coarsest
	// level, because one texture update writes one layer's whole chain. When every layer
	// is taken, the least recently used cell is evicted and reported, so the caller can
	// drop the pages that were assembled from it.
	bool publish_cell(const godot::Vector2i &p_cell, uint32_t p_signature, const godot::Rect2 &p_world_rect,
			const godot::Ref<godot::Image> *p_channels, int p_resolution, godot::Vector2i *r_evicted = nullptr);
	void touch_cell(const godot::Vector2i &p_cell);

	godot::RID get_texture_rid(int p_channel) const;
	// A 2D view of one channel's layer/mip for the page assembly shader. Created on the
	// render thread and owned by the caller: freeing views here would need a lock that
	// the render callback must not take while the main thread publishes a bake.
	godot::RID create_sample_view(int p_channel, int p_layer, int p_mip) const;

	// The catalog the editor browser lists: one entry per resident cell, keyed the way
	// the bake file was.
	godot::Array get_catalog() const;
	godot::Dictionary get_stats() const;

	~Terrain3DCellStore() override;

protected:
	static void _bind_methods();

private:
	int _acquire_layer(const godot::Vector2i &p_cell, godot::Vector2i *r_evicted);
	void _release_layer(int p_layer);

	godot::RenderingDevice *_rd = nullptr;
	int _layers = 0;
	int _resolution = 0;
	int _level_count = 0;
	godot::RID _channel_rd[3];
	std::vector<int> _free_layers;
	std::unordered_map<int64_t, Cell> _cells;
	uint64_t _use_counter = 0;
	uint64_t _published_cells = 0;
	uint64_t _evicted_cells = 0;
};

#endif // TERRAIN3D_VT_CELL_STORE_CLASS_H
