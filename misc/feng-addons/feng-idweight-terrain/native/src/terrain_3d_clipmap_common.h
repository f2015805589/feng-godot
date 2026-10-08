// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_CLIPMAP_COMMON_H
#define TERRAIN3D_CLIPMAP_COMMON_H

// Shared shape, sampling ladder, bake leases and debug schema for LOD and Atlas.
// Storage-specific state belongs to each implementation.

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

// Fixed shader table dimensions shared by both implementations and their material binding.
inline constexpr int MAX_LEVELS = 16;
inline constexpr int MAX_OUTSTANDING_RECTS = 4;

// Persisted property values; keep their numeric identities stable.
enum class Implementation : uint8_t {
	// Toroidal Texture2DArray levels; uploads replace each changed level.
	LOD = 0,
	// Blocks packed into per-channel atlases; uploads replace changed rectangles.
	Atlas = 1,
};

inline constexpr int IMPLEMENTATION_COUNT = 2;

// Default material density spans 1024 to 1 texels/metre over eleven octave units.
// Other channel groups may choose a lower finest density.
inline constexpr real_t LADDER_FINEST_DENSITY = 1024.f; // texels a metre at unit 0
inline constexpr real_t LADDER_COARSEST_DENSITY = 1.f; // texels a metre at the outermost unit
inline constexpr int LADDER_UNITS = 11; // log2(1024 / 1) + 1

// Atlas table capacities shared with material uniforms and shader defines.
// Allow nine cells, one spare per ring, a global block and layout padding.
inline constexpr int ATLAS_MAX_RINGS = 12;
inline constexpr int ATLAS_MAX_CELLS = 9 * ATLAS_MAX_RINGS;
inline constexpr int ATLAS_MAX_SLOTS = ATLAS_MAX_CELLS + ATLAS_MAX_RINGS + 8;

inline bool is_valid_implementation(const int p_implementation) {
	return p_implementation >= 0 && p_implementation < IMPLEMENTATION_COUNT;
}

inline Implementation implementation_from_int(const int p_implementation,
		const Implementation p_fallback = Implementation::LOD) {
	return is_valid_implementation(p_implementation) ? Implementation(p_implementation) : p_fallback;
}

// Names shared by properties, reports and logs.
inline const char *implementation_name(const Implementation p_implementation) {
	return p_implementation == Implementation::Atlas ? "Atlas" : "LOD";
}

// Inspector enum order matches Implementation.
inline const char *implementation_hint() {
	return "LOD,Atlas";
}

// Configuration shared by both storage implementations.
struct Shape {
	// Finest level/block resolution; density is size / base_world.
	int size = 256;
	// LOD levels or atlas rings, clamped to the implementation capacity.
	int units = LADDER_UNITS;
	// Finest unit width in metres; each later unit doubles it.
	real_t base_world = 0.25f;
	// Channel count and formats come from Terrain3DClipmapSource.
	int channels = 1;
	Image::Format format = Image::FORMAT_RF;
	int baked_channels = 0;
	Image::Format baked_format = Image::FORMAT_RGBAH;
	// Atlas-only global block and production pacing settings.
	int global_texels = 64;
	int blocks_per_frame = 1;
	bool spares = true;
};

// Shared world-space sampling ladder, independent of storage layout.
struct Ladder {
	// Neutral values until ladder_of(shape) configures the ladder.
	int size = 1;
	real_t base_world = 1.f;
	// The world side length of one unit: `base_world * 2^unit` metres.
	real_t unit_world_size(const int p_unit) const {
		return base_world * real_t(int64_t(1) << CLAMP(p_unit, 0, 30));
	}
	// World-space texel width at this unit.
	real_t texel_world(const int p_unit) const {
		return unit_world_size(p_unit) / real_t(MAX(1, size));
	}
	// Texels per metre at this unit.
	real_t density_of_unit(const int p_unit) const {
		return 1.f / texel_world(p_unit);
	}
	// Finest density: size / base_world.
	real_t finest_density() const { return density_of_unit(0); }
	// Density at the last of p_units units.
	real_t density_at_unit_count(const int p_units) const {
		return density_of_unit(MAX(1, p_units) - 1);
	}
	// Unit count needed to reach the requested coarsest density.
	int units_for_density(const real_t p_coarsest = LADDER_COARSEST_DENSITY) const {
		int units = 1;
		while (units < 31 && density_of_unit(units - 1) > p_coarsest) {
			units++;
		}
		return units;
	}
	// Compare the default density endpoints with a relative tolerance.
	bool spans_endpoints(const int p_units) const {
		const real_t finest = finest_density();
		const real_t coarsest = density_at_unit_count(p_units);
		return finest >= LADDER_FINEST_DENSITY * 0.999f && finest <= LADDER_FINEST_DENSITY * 1.001f &&
				coarsest >= LADDER_COARSEST_DENSITY * 0.999f && coarsest <= LADDER_COARSEST_DENSITY * 1.001f;
	}
};

inline Ladder ladder_of(const Shape &p_shape) {
	Ladder ladder;
	ladder.size = MAX(1, p_shape.size);
	ladder.base_world = MAX(real_t(0.001), p_shape.base_world);
	return ladder;
}

// A produced rectangle awaiting baking. Unit is a LOD level or Atlas slot;
// lease identifies its content revision. Acknowledge only after dispatch succeeds.
struct BakeRect {
	int unit = 0;
	int x0 = 0;
	int y0 = 0;
	int x1 = 0;
	int y1 = 0;
	uint64_t lease = 0;

	Rect2i rect() const { return Rect2i(x0, y0, x1 - x0, y1 - y0); }
};

// Shared per-unit report. Unsupported fields retain their defaults.
struct UnitReport {
	int index = 0;
	// "level" for the LOD ring's levels, "ring" for the atlas's shells.
	const char *kind = "level";
	int texels = 0;
	real_t world_size = 0.f;
	real_t texel_world = 0.f;
	// Texels per metre from the shared ladder.
	real_t density = 0.f;
	// Readable now: valid LOD level or fully current Atlas shell.
	bool valid = false;
	// Baked content is readable; equals valid for unbaked sources.
	bool baked = false;
	int pending = 0;
	// The world rects still queued for this unit, so a moving focus is drawn rather than claimed.
	std::vector<Rect2> pending_rects;
	// Single-square addressing for LOD; Atlas publishes its grid separately.
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

// Wrap a signed texel index into [0, size).
inline int wrap_texel(const int p_value, const int p_size) {
	if (p_size <= 0) {
		return 0;
	}
	const int reduced = p_value % p_size;
	return reduced < 0 ? reduced + p_size : reduced;
}

// Bytes per stored channel texel, shared by both upload implementations.
inline int bytes_per_texel(const Image::Format p_format) {
	switch (p_format) {
		case Image::FORMAT_R8:
			return 1;
		case Image::FORMAT_RGBA8:
			return 4;
		case Image::FORMAT_RGBAH:
			return 8;
		default:
			return 4;
	}
}

} // namespace TerrainClipmap

#endif // TERRAIN3D_CLIPMAP_COMMON_H
