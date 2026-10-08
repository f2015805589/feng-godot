// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_CLIPMAP_SOURCE_MATERIAL_H
#define TERRAIN3D_CLIPMAP_SOURCE_MATERIAL_H

// Material source: raw packed R16 id/weight payload plus nearest height, stored
// as RF scalars. The payload is an integer, so sampling performs no UNORM rescale.
// Baking emits diffuse/height, octahedral normal/roughness and parameter arrays.
// Baked rectangles use physical storage coordinates; the ring offset converts
// them to logical coordinates, preserving unchanged texels as the focus moves.

#include "terrain_3d_clipmap_source.h"

class Terrain3DData;

class Terrain3DClipmapSourceMaterial : public Terrain3DClipmapSource {
public:
	explicit Terrain3DClipmapSourceMaterial(const Terrain3DData *p_data) :
			_data(p_data) {}

	void fill_row(const Row &p_row, float *r_values) override;
	void set_source_snapshot(const std::shared_ptr<const Terrain3DPagePipeline::Snapshot> &p_snapshot) override {
		_snapshot = p_snapshot;
	}
	String get_source_name() const override { return "material"; }
	// Raw payload and height use separate scalar layers.
	int get_channel_count() const override { return 2; }
	Image::Format get_format() const override { return Image::FORMAT_RF; }
	// The three arrays the bake writes from those two texels, in the shader's own output format.
	int get_baked_channel_count() const override { return 3; }
	Image::Format get_baked_format() const override { return Image::FORMAT_RGBAH; }

private:
	const Terrain3DData *_data = nullptr;
	std::shared_ptr<const Terrain3DPagePipeline::Snapshot> _snapshot;
};

#endif // TERRAIN3D_CLIPMAP_SOURCE_MATERIAL_H
