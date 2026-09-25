// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_CLIPMAP_SOURCE_H
#define TERRAIN3D_CLIPMAP_SOURCE_H

// What a clipmap level *holds*, asked one row at a time. The ring itself
// (`terrain_3d_clipmap.h`) owns the levels, the addressing, the budget and the texture; it does not
// know whether the values it moves are heights, control ids or albedo, and it never reads the
// terrain. Everything that differs between channels lives behind this interface, one implementation
// per channel group - which is why adding a channel to the ring is a new *source*, not a second
// clipmap, and why the ring's own tests never need a terrain to exist.
//
// Row granularity, not texel: a source's per-texel cost is dominated by its own lookup (region
// resolution, page or cell fetch), so handing it a whole row gives it the locality it needs without
// putting a virtual call in the innermost loop. The clipmap still decides where every value lands,
// because only it knows the ring - the source never sees a physical index.

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector2.hpp>

#include <memory>

// For `using namespace godot` (this is a GDExtension build) and `real_t`.
#include "constants.h"
#include "terrain_3d_page_pipeline.h"

class Terrain3DClipmapSource {
public:
	// One row of one channel of one level, named in *logical* indices. `origin` is the world XZ of
	// the centre of logical texel (0, 0) on this level, so `world_of(x)` names the centre of logical
	// texel x of this row without the source knowing anything about the level's coverage or the ring.
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
	// Refreshes the immutable map snapshot a background update reads. Test sources and other small
	// producers may ignore it; terrain sources override it so worker rows never touch scene-owned data.
	virtual void set_source_snapshot(const std::shared_ptr<const Terrain3DPagePipeline::Snapshot> &) {}

	// Writes `p_row.x1 - p_row.x0` values for one channel, in ascending `x`. The buffer is the
	// caller's and is sized for a full row; only `[x0, x1)` is read afterwards.
	virtual void fill_row(const Row &p_row, float *r_values) = 0;

	// What this source carries, for the dock and the reports: "height", "material", ...
	virtual String get_source_name() const = 0;

	// The shape of one value: how many scalars a texel holds (one texture array layer each) and
	// one value's format. It is the whole of what the *mechanism* has to be told about a channel:
	// the ring publishes `levels * channels` layers of `format`, and nothing else in it depends on
	// what the values mean. Declaring the shape here rather than writing it into the owner is what
	// makes a second channel group a source and a line in the owner's factory instead of a shape
	// the assembly rule has to know.
	virtual int get_channel_count() const = 0;
	virtual Image::Format get_format() const = 0;

	// And what a *producer* bakes out of the channel's texels, if anything: this many arrays of
	// `get_baked_format()`, one layer per level, written by a pass rather than by a row filler. Zero
	// - the height channel's answer - means the ring is only what `fill_row()` produces. A value that
	// needs several components of its own is not a wider ring: it is a baked channel, and this is
	// where a channel says it has one. The material channel's three arrays (diffuse and height, an
	// octahedral normal and roughness, the parameters) are what the bake shader writes.
	virtual int get_baked_channel_count() const { return 0; }
	virtual Image::Format get_baked_format() const { return Image::FORMAT_RGBAH; }
};

#endif // TERRAIN3D_CLIPMAP_SOURCE_H
