// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_CLIPMAP_SOURCE_MATERIAL_H
#define TERRAIN3D_CLIPMAP_SOURCE_MATERIAL_H

// The material channel of the clipmap: two values a texel - the `R16` surface payload texel under the
// clipmap texel's centre, read by *nearest* payload texel (`Terrain3DData::get_surface_texel_nearest()`),
// and the height under the same texel (`get_height_texel_nearest()`).
//
// The payload is the material group's *source*: the packed id/weight pair the texture assets are
// blended by. The three arrays a page carries - diffuse and height, an octahedral normal and
// roughness, the parameters - are baked from exactly this payload, and the ring carries them too:
// `get_baked_channel_count()` declares them and `Terrain3DSurfaceBaker` writes them from the ring's
// own texels (`queue_clipmap_ring()`, offered once a tick by the ring's owner), one *rect it produced*
// at a time, no page and no codec involved. A level that is baked serves the arrays; a level that is
// not is served by the payload through `evaluate_idweight_material()`, which is the same resolution at
// the payload's own density.
//
// The baked layers are indexed the way the payload layers are - by the *stored* texel, one layer per
// level - because that is the frame that keeps naming the same world position as the level turns: the
// centre moves and this source's ring offset turns with it, so a texel the movement did not touch still
// describes the world position it described. That is what lets the producer bake one *rect* of a level
// (the rect the ring produced, in stored texels) instead of the level's square, and a layer indexed in
// the level's own moving frame would leave the rest of the level describing world positions it no
// longer covers. The bake reads the payload through the ring either way
// (`surface_bake_source_coord()`), so a stored rect's world position is reached through the level's
// logical grid - the stored index turned back by the ring.
//
// The height is the second channel because the bake reads both inputs through two samplers at one
// layer index: a ring that carried only the payload could only be baked against a height array in
// step with it, which would be the height ring - a coupling between two channel groups that this
// ring does not need and should not have.
//
// The payload is stored raw, not as a UNORM encoding: the ring's layer is `FORMAT_RF` (4 bytes a
// value, which holds every 16-bit integer exactly) and the shader's ring read takes the integer back
// without rescaling, where the array's UNORM read scales by 65535. A packed id/weight pair is not a
// colour.

#include "terrain_3d_clipmap_source.h"

class Terrain3DData;

class Terrain3DClipmapSourceMaterial : public Terrain3DClipmapSource {
public:
	explicit Terrain3DClipmapSourceMaterial(const Terrain3DData *p_data) :
			_data(p_data) {}

	void fill_row(const Row &p_row, float *r_values) override;
	String get_source_name() const override { return "material"; }
	// The packed payload and the height under it, both in float layers because the payload is an
	// integer rather than a normalised value.
	int get_channel_count() const override { return 2; }
	Image::Format get_format() const override { return Image::FORMAT_RF; }
	// The three arrays the bake writes from those two texels, in the shader's own output format.
	int get_baked_channel_count() const override { return 3; }
	Image::Format get_baked_format() const override { return Image::FORMAT_RGBAH; }

private:
	const Terrain3DData *_data = nullptr;
};

#endif // TERRAIN3D_CLIPMAP_SOURCE_MATERIAL_H
