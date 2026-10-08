// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_CLIPMAP_SOURCE_H
#define TERRAIN3D_CLIPMAP_SOURCE_H

// Channel data provider. Row-sized requests amortize source lookup work;
// logical coordinates keep toroidal and atlas storage inside their implementations.

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector2.hpp>

#include <memory>

// For `using namespace godot` (this is a GDExtension build) and `real_t`.
#include "constants.h"
#include "terrain_3d_page_pipeline.h"

class Terrain3DClipmapSource {
public:
	// Logical row request. Origin is the world-space centre of texel (0, 0).
	struct Row {
		int level = 0;
		int channel = 0;
		int y = 0;
		int x0 = 0;
		int x1 = 0; // Half-open.
		int size = 0;
		real_t texel_world = 1.f;
		Vector2 origin;

		Vector2 world_of(const int p_x) const {
			return Vector2(origin.x + real_t(p_x) * texel_world, origin.y + real_t(y) * texel_world);
		}
	};

	virtual ~Terrain3DClipmapSource() {}
	// Install the immutable snapshot before worker updates read rows.
	virtual void set_source_snapshot(const std::shared_ptr<const Terrain3DPagePipeline::Snapshot> &) {}

	// Writes `p_row.x1 - p_row.x0` values for one channel, in ascending `x`. The buffer is the
	// caller's and is sized for a full row; only `[x0, x1)` is read afterwards.
	virtual void fill_row(const Row &p_row, float *r_values) = 0;

	// What this source carries, for the dock and the reports: "height", "material", ...
	virtual String get_source_name() const = 0;

	// Source shape: one array layer per scalar channel.
	virtual int get_channel_count() const = 0;
	virtual Image::Format get_format() const = 0;

	// Optional baked outputs: one array per channel, one layer per level.
	// Zero means the source is consumed directly. Material produces three RGBAH arrays.
	virtual int get_baked_channel_count() const { return 0; }
	virtual Image::Format get_baked_format() const { return Image::FORMAT_RGBAH; }
};

#endif // TERRAIN3D_CLIPMAP_SOURCE_H
