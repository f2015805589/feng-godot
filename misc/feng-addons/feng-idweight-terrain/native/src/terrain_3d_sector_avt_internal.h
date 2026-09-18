// The prologue the three halves of the near field's planning share.

// terrain_3d_sector_avt.cpp, terrain_3d_sector_avt_motion.cpp and
// terrain_3d_sector_avt_hierarchy.cpp each read part of the world model, and three names are read by
// two of them: the sector's world size, the short alias for the demand cell, and the 64-bit owner key
// the address directory and the page requests are both indexed by. A copy of any of them in each half
// would be a second vocabulary for the same arithmetic, which is what rule 4 of the architecture
// review exists to prevent - so they live here, once, in a named namespace each half opens with
// `using namespace TerrainAVT;`.
//
// `avt_owner_key()` is `inline` rather than file-scope `static`: a header definition that two
// translation units include is a definition each of them needs to be allowed to have.
#ifndef TERRAIN_3D_SECTOR_AVT_INTERNAL_H
#define TERRAIN_3D_SECTOR_AVT_INTERNAL_H

// terrain_3d_avt.h writes `Vector2i` and `Rect2` unqualified and in the godot namespace, which
// constants.h establishes; in the original file that happened because terrain_3d.h was included
// first. This header includes what it uses, in that order.
#include "constants.h"

#include <godot_cpp/variant/rect2.hpp>

#include "terrain_3d_avt.h"

#include <cstdint>

namespace TerrainAVT {

// Local short names for the two world model constants the AVT files share; the values and the
// reasoning behind them are in terrain_3d_avt.h. They are used a few dozen times across these files,
// and the qualified spelling would bury the arithmetic that reads them.
inline constexpr float SECTOR_WORLD = AVT_SECTOR_WORLD;

// The demand cell's short name. The worker file spells the same alias for its own half; the record
// itself is `Terrain3DAVTSector` in terrain_3d_avt.h.
using Sector = Terrain3DAVTSector;

// Owner keys are the 64-bit (x, y) pair the address directory and the page
// requests are both indexed by.
inline uint64_t avt_owner_key(const Vector2i &owner) { return (uint64_t(uint32_t(owner.x)) << 32) | uint32_t(owner.y); }

} // namespace TerrainAVT
#endif // TERRAIN_3D_SECTOR_AVT_INTERNAL_H
