// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_CLIPMAP_SOURCE_HEIGHT_H
#define TERRAIN3D_CLIPMAP_SOURCE_HEIGHT_H

// The height channel of the clipmap: one value a texel, the height-map texel under the clipmap
// texel's centre, read by *nearest* vertex (see `Terrain3DData::get_height_texel_nearest()` for why
// nearest and not the bilinear `get_height()`). The ring itself
// (`terrain_3d_clipmap.h`) knows nothing about this file: it is one implementation of
// `Terrain3DClipmapSource`, and the material channel is another.

#include "terrain_3d_clipmap_source.h"

class Terrain3DData;

class Terrain3DClipmapSourceHeight : public Terrain3DClipmapSource {
public:
	explicit Terrain3DClipmapSourceHeight(const Terrain3DData *p_data) :
			_data(p_data) {}

	void fill_row(const Row &p_row, float *r_values) override;
	void set_source_snapshot(const std::shared_ptr<const Terrain3DPagePipeline::Snapshot> &p_snapshot) override {
		_snapshot = p_snapshot;
	}
	String get_source_name() const override { return "height"; }
	// One value a texel, in the height map's own format: the layer the height arm samples in place
	// of the region array carries the same numbers in the same format.
	int get_channel_count() const override { return 1; }
	Image::Format get_format() const override { return Image::FORMAT_RF; }

private:
	const Terrain3DData *_data = nullptr;
	std::shared_ptr<const Terrain3DPagePipeline::Snapshot> _snapshot;
};

#endif // TERRAIN3D_CLIPMAP_SOURCE_HEIGHT_H
