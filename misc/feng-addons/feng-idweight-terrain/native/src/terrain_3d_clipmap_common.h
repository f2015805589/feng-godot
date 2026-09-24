// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_CLIPMAP_COMMON_H
#define TERRAIN3D_CLIPMAP_COMMON_H

// The clipmap layer's **shared vocabulary**: everything the two implementations (`LOD` and `Atlas`) and
// the facade above them (`terrain_3d_clipmap_layer.h`) must agree on, in one header with no
// implementation-specific state and no engine dependency beyond the variant types.
//
// There is one clipmap *delivery*. What a user chooses inside it is an *implementation*: the toroidal
// level ring (`Terrain3DClipmap`) or the block atlas (`Terrain3DClipmapAtlas`). The two differ in
// storage, upload unit, rolling and layout - and in nothing else. That "nothing else" is this file:
//
//   * `Implementation` - the selector, its names and its validation, so the property, the dock, the
//     reports and the debug view spell the two the same way.
//   * `Shape` - the numbers a layer is built from. Both implementations are configured from this one
//     struct, so a setting cannot exist for one of them and not the other.
//   * `Ladder` - the *sampling contract*: the density ladder `texel_world(unit) = base_world * 2^unit
//     / size`, and the world size of a unit. Both implementations address by exactly this ladder; the
//     atlas merely stores its units as shells of blocks instead of whole squares. Writing it once is
//     what makes the density a fragment is served a property of the layer rather than of the storage.
//     The ladder's two **endpoints** are part of the contract and are stated once below
//     (`LADDER_FINEST_DENSITY` / `LADDER_COARSEST_DENSITY` / `LADDER_UNITS`): the finest unit serves
//     1024 texels a metre, the coarsest 1, each unit halves the one inside it, and a shape that cannot
//     express that span is a truncation rather than a smaller clipmap.
//   * `BakeRect` - the producer's queue entry. The ring queued a rect of a level, the atlas a rect of
//     a slot; a producer only ever needs "which unit, which rect of it, and the lease that says the
//     content still matches", so that is the shape both publish.
//   * `UnitReport` - the debug/report schema, one entry per unit, filled by each implementation and
//     assembled by the facade. A debug view or a test reads one schema whichever implementation is
//     selected; only what is genuinely private to an implementation travels beside it.
//
// `docs/vt_delivery_assembly.md` section 6 is the long form of the layer; this header is the part of
// it that is shared code rather than prose.

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/rect2i.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <cstdint>
#include <vector>

#include "constants.h"

namespace TerrainClipmap {

// How a clipmap layer stores and uploads what it holds. The int values are the property values the
// dock and scripts write, so they are part of the API and must not be renumbered; `LOD` is 0 because
// it is the shipped behaviour and therefore the default of an unset property.
enum class Implementation : uint8_t {
	// One toroidal square per level in a `Texture2DArray`, addressed by arithmetic. Level `l` covers
	// `base_world * 2^l` metres in `size` texels. The update unit is a level: a movement re-publishes
	// the whole square of every level it moved.
	LOD = 0,
	// The same ladder stored as discrete blocks packed into one texture per channel. Ring `r` is a
	// shell of blocks, each `base_world` metres of `size >> r` texels. The update unit is a block: a
	// movement re-publishes the rects that changed.
	Atlas = 1,
};

inline constexpr int IMPLEMENTATION_COUNT = 2;

// ---- The shipping ladder's two endpoints ----------------------------------------------------------
//
// The layer's job is one density ladder, and it has two hard endpoints: the **finest** unit serves
// **1024 texels a metre** and the **coarsest** serves **1 texel a metre**, with every unit between
// them half the density of the one inside it (`1024 -> 512 -> ... -> 1`). The two numbers are stated
// here once because the defaults, the dock's hint, the tests and *both* implementations have to name
// the same pair; a shape that reached only part of the span would be a truncated ladder wearing a
// clipmap's name.
//
// `1024 / 2^10 == 1`, so the span is eleven units. Every ceiling an implementation clamps `units` to
// is at least this, and a clamp that would shorten the ladder is reported rather than applied in
// silence (see `truncates_ladder()` and the two `configure()`s).
inline constexpr real_t LADDER_FINEST_DENSITY = 1024.f; // texels a metre at unit 0
inline constexpr real_t LADDER_COARSEST_DENSITY = 1.f; // texels a metre at the outermost unit
inline constexpr int LADDER_UNITS = 11; // log2(1024 / 1) + 1

inline bool is_valid_implementation(const int p_implementation) {
	return p_implementation >= 0 && p_implementation < IMPLEMENTATION_COUNT;
}

inline Implementation implementation_from_int(const int p_implementation,
		const Implementation p_fallback = Implementation::LOD) {
	return is_valid_implementation(p_implementation) ? Implementation(p_implementation) : p_fallback;
}

// The token a property, a report and a log line use. "LOD" and "Atlas" are the two the dock offers.
inline const char *implementation_name(const Implementation p_implementation) {
	return p_implementation == Implementation::Atlas ? "Atlas" : "LOD";
}

// The same value as the *setting* the dock's enum hint spells: one list, so the property hint and the
// panel cannot disagree about the order.
inline const char *implementation_hint() {
	return "LOD,Atlas";
}

// The shape. One struct configures either implementation, which is the whole reason a new clipmap
// setting is one field here rather than one field per implementation.
struct Shape {
	// Ring 0's resolution in texels an axis. The LOD ring's level size and the atlas's block size are
	// the same number, so a user who tuned one has tuned the other: it is the layer's finest density
	// together with `base_world` (`size / base_world` texels a metre).
	int size = 256;
	// How many units the layer holds: LOD levels, or atlas rings. Clamped by each implementation to
	// its own ceiling, because the shader's per-unit arrays are sized from it - and the ceilings are
	// all at least `LADDER_UNITS`, so the shipped 1024 -> 1 span is never clamped short.
	int units = LADDER_UNITS;
	// The world size of the finest unit, and therefore the ladder's octave: unit `l` is twice as
	// coarse as unit `l - 1`. Together with `size` it is the finest endpoint: the defaults
	// (256 texels over 0.25 m) are 1024 texels a metre, and eleven units of it reach 1.
	real_t base_world = 0.25f;
	// Values a texel holds, one texture array layer each, and one value's format. The channel's own
	// declaration (`Terrain3DClipmapSource`), carried here so `configure()` is one call.
	int channels = 1;
	Image::Format format = Image::FORMAT_RF;
	int baked_channels = 0;
	Image::Format baked_format = Image::FORMAT_RGBAH;
	// The atlas's out-of-grid resource and its per-frame production bound. They are part of the shared
	// shape because they are *settings of the layer*; the LOD implementation declares they do not
	// apply to it (`uses_global_block()` / `uses_block_pacing()`), rather than the facade hiding them.
	int global_texels = 64;
	int blocks_per_frame = 1;
	bool spares = true;
};

// The sampling contract, derived from the shape and nothing else. Both implementations address by this
// ladder; the atlas stores a unit as a shell of blocks rather than as one square, which changes where a
// texel *lives* and not which texel a world position gets.
struct Ladder {
	// The finest unit's texels an axis, and the metres it covers.
	int size = 256;
	real_t base_world = 256.f;
	// The world size of one texel of a unit: `base_world * 2^unit / size` metres. The density a
	// fragment is served at a distance is the reciprocal, which is why the "density - distance" curve
	// is this function sampled by `unit_for_distance()`.
	real_t texel_world(const int p_unit) const {
		return base_world * real_t(int64_t(1) << CLAMP(p_unit, 0, 30)) / real_t(MAX(1, size));
	}
	// The world size one unit covers: the square the LOD level stores, i.e. `base_world * 2^unit`.
	// The atlas's unit is a shell of blocks of the same world size, so its *reach* is this times the
	// grid's half extent; that difference is the implementation's and lives there.
	real_t unit_world(const int p_unit) const {
		return base_world * real_t(int64_t(1) << CLAMP(p_unit, 0, 30));
	}
	// The density a fragment is served by one unit, in texels a metre. It is the reciprocal of the
	// texel size, and it is the number the acceptance's "density - distance" curve is made of: a curve
	// that reads it per unit and measures the distance in the unit's own reach is a property of the
	// *layer*, which is why every implementation answers it identically.
	real_t density_of_unit(const int p_unit) const {
		return 1.f / texel_world(p_unit);
	}
	// The density the ladder's innermost unit serves: the shape's `size / base_world`, i.e. the finest
	// endpoint a shape with this ladder presents.
	real_t finest_density() const { return density_of_unit(0); }
	// The density the ladder reaches when it holds `p_units` units: the outermost endpoint a layer of
	// that many units presents. `density_at_unit_count(1)` is the finest unit's own density.
	real_t density_at_unit_count(const int p_units) const {
		return density_of_unit(MAX(1, p_units) - 1);
	}
	// How many units *this* ladder needs to fall from its own finest density to `p_coarsest`. A shape
	// whose settings ask for fewer units than this presents a truncated ladder, which is what
	// `truncates_ladder()` reports rather than hiding behind the clamp.
	int units_for_density(const real_t p_coarsest = LADDER_COARSEST_DENSITY) const {
		int units = 1;
		while (units < 31 && density_of_unit(units - 1) > p_coarsest) {
			units++;
		}
		return units;
	}
	// Whether `p_units` units of this ladder present both shipping endpoints. The comparison is a
	// relative one because a shape's fields are floats and `size / base_world` is a division.
	bool spans_endpoints(const int p_units) const {
		const real_t finest = finest_density();
		const real_t coarsest = density_at_unit_count(p_units);
		return finest >= LADDER_FINEST_DENSITY * 0.999f && finest <= LADDER_FINEST_DENSITY * 1.001f &&
				coarsest >= LADDER_COARSEST_DENSITY * 0.999f && coarsest <= LADDER_COARSEST_DENSITY * 1.001f;
	}
	// Whether a layer of `p_units` units is shorter than this ladder's own 1024 -> 1 span, which is the
	// state a clamp must never reach silently.
	bool truncates_ladder(const int p_units) const { return p_units < units_for_density(); }
};

inline Ladder ladder_of(const Shape &p_shape) {
	Ladder ladder;
	ladder.size = MAX(1, p_shape.size);
	ladder.base_world = MAX(real_t(0.001), p_shape.base_world);
	return ladder;
}

// One entry of a producer's bake queue, in the one shape both implementations publish. `unit` is what
// the implementation calls the storage - a level for the LOD ring, an atlas slot for the atlas - and
// `lease` is whatever makes the entry still describe current content (the ring's content serial, the
// atlas's slot serial). A producer copies the entry, dispatches a bake over `rect`, and hands the copy
// back: the implementation is the one that decides whether it still counts.
struct BakeRect {
	int unit = 0;
	int x0 = 0;
	int y0 = 0;
	int x1 = 0;
	int y1 = 0;
	uint64_t lease = 0;

	Rect2i rect() const { return Rect2i(x0, y0, x1 - x0, y1 - y0); }
};

// One unit's debug/report entry, in the one schema the facade assembles and the debug view and the
// tests read. Every field is answerable by either implementation: the LOD ring's level and the atlas's
// ring both have a texel size, a world size, a "is it readable now" bit, a queued rect list and a
// density. What an implementation cannot answer it leaves at its default.
struct UnitReport {
	int index = 0;
	// "level" for the LOD ring's levels, "ring" for the atlas's shells.
	const char *kind = "level";
	int texels = 0;
	real_t world_size = 0.f;
	real_t texel_world = 0.f;
	// The density a fragment is served by this unit, in texels a metre. The same number on both sides,
	// because both address by the shared ladder.
	real_t density = 0.f;
	// Whether the unit is readable *right now*: the LOD ring's `valid`, the atlas's "every cell of the
	// shell current". A unit that is not readable falls back, which is what the debug view colours.
	bool valid = false;
	// Whether the unit's *baked* content is readable too (the material arm's gate). Equal to `valid`
	// for a channel with no bake.
	bool baked = false;
	int pending = 0;
	// The world rects still queued for this unit, so a moving focus is drawn rather than claimed.
	std::vector<Rect2> pending_rects;
	// Where the unit stands, when the implementation has one square per unit. The atlas's shell has no
	// single centre, so it publishes its own grid instead.
	Vector2 center;
	Vector2i offset;
	// How many resident pieces of content the unit holds (atlas: slots; LOD: 1 when valid, else 0).
	int resident = 0;
	// How many cells/blocks the unit is made of, when the implementation is block-organised.
	int blocks = 0;
};

inline Dictionary unit_report_to_dictionary(const UnitReport &p_report) {
	Dictionary entry;
	entry["index"] = p_report.index;
	entry["kind"] = String(p_report.kind);
	entry["texels"] = p_report.texels;
	entry["world_size"] = p_report.world_size;
	entry["texel_world"] = p_report.texel_world;
	entry["density"] = p_report.density;
	entry["valid"] = p_report.valid;
	entry["baked"] = p_report.baked;
	entry["pending"] = p_report.pending;
	entry["center"] = p_report.center;
	entry["offset"] = Vector2(real_t(p_report.offset.x), real_t(p_report.offset.y));
	entry["resident"] = p_report.resident;
	entry["blocks"] = p_report.blocks;
	Array rects;
	rects.resize(int(p_report.pending_rects.size()));
	for (size_t index = 0; index < p_report.pending_rects.size(); index++) {
		rects[int(index)] = p_report.pending_rects[index];
	}
	entry["pending_rects"] = rects;
	return entry;
}

// ---- Shared rect arithmetic ----------------------------------------------------------------------
//
// Both implementations queue rects, and both have to merge what they queue (a focus that turned twice
// before its first strip was baked is one rect, not two) and to keep a rect half-open and inside one
// unit. One spelling, so the two cannot disagree about whether a rect is inclusive.

inline Rect2i merge_rect(const Rect2i &p_a, const Rect2i &p_b) {
	if (!p_a.has_area()) {
		return p_b;
	}
	if (!p_b.has_area()) {
		return p_a;
	}
	const int x0 = MIN(p_a.position.x, p_b.position.x);
	const int y0 = MIN(p_a.position.y, p_b.position.y);
	const int x1 = MAX(p_a.position.x + p_a.size.x, p_b.position.x + p_b.size.x);
	const int y1 = MAX(p_a.position.y + p_a.size.y, p_b.position.y + p_b.size.y);
	return Rect2i(x0, y0, x1 - x0, y1 - y0);
}

inline Rect2i clamp_rect(const Rect2i &p_rect, const int p_size) {
	const int x0 = CLAMP(p_rect.position.x, 0, p_size);
	const int y0 = CLAMP(p_rect.position.y, 0, p_size);
	const int x1 = CLAMP(p_rect.position.x + p_rect.size.x, 0, p_size);
	const int y1 = CLAMP(p_rect.position.y + p_rect.size.y, 0, p_size);
	return Rect2i(x0, y0, MAX(0, x1 - x0), MAX(0, y1 - y0));
}

// Reduces a signed texel index into `[0, size)`. The ring's `physical = (logical + ring) mod size` and
// the atlas's per-block offset both go through this one function.
inline int wrap_texel(const int p_value, const int p_size) {
	if (p_size <= 0) {
		return 0;
	}
	const int reduced = p_value % p_size;
	return reduced < 0 ? reduced + p_size : reduced;
}

} // namespace TerrainClipmap

#endif // TERRAIN3D_CLIPMAP_COMMON_H
