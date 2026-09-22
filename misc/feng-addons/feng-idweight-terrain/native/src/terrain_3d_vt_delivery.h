// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN_VT_DELIVERY_H
#define TERRAIN_VT_DELIVERY_H

// The delivery matrix: which method carries which channel group, in which tier, and the
// three questions the rest of the addon is allowed to ask of it.
//
// This is the one input to what the VT layer builds. A service exists because a cell
// selected it, an array family is published because a group samples it, the shader variant
// carries an arm because a cell asked for it, and the tick enters a pass because a service
// exists. Nothing here decides *how* a method works - that belongs to the method - so this
// header has no engine dependency and no runtime state beyond the four values themselves,
// and its arithmetic is pinned by `native/tests/vt/terrain_vt_contract_test.cpp`.
//
// Read `docs/vt_delivery_assembly.md` before changing a default or adding a method: the
// document carries the channel inventory, the assembly rule and what each default
// preserves.

#include <cstdint>

namespace TerrainVT {

// One of the shader's two output channel groups. The split is the user-facing one:
// `Material` is the baked diffuse + normal + AO/roughness set (and the control payload it
// is baked from, because they are one page pool and one indirection), `Height` is the
// terrain height the vertex and fragment stages displace and shade with.
enum class ChannelGroup : uint8_t {
	Material = 0,
	Height = 1,
	GROUP_COUNT = 2,
};

// A distance band around the clipmap target. Near is the AVT band
// (`surface_vt_distance`), far is the SVT band (`surface_svt_distance`); the matrix adds a
// choice to the two bands that exist rather than a third distance.
enum class Tier : uint8_t {
	Near = 0,
	Far = 1,
	TIER_COUNT = 2,
};

// How a cell's payload reaches a fragment.
//
// The int values are the property values the dock and scripts write, so they are part of
// the API and must not be renumbered.
enum class Delivery : uint8_t {
	// Sample the source directly: the region texture arrays. No indirection, no service,
	// no state. This is the "pure RVT" choice in the panel and the only method that is
	// always correct, which is why it is the fallback for anything that cannot resolve.
	Direct = 0,
	// The sectored adaptive virtual texture: region-local addressing, a per-sector virtual
	// image, a mip-carrying page table and a coarse owner.
	AVT = 1,
	// A toroidal ring of power-of-two levels in one Texture2DArray. No indirection, no
	// allocator, no LRU: an address is arithmetic.
	Clipmap = 2,
	// The world-space sparse virtual texture: one global page grid, a distance level rule
	// and a pinned root pyramid.
	SVT = 3,
};

inline constexpr int DELIVERY_COUNT = 4;
inline constexpr int TIER_COUNT = 2;
inline constexpr int GROUP_COUNT = 2;

// The stored form is the API; a value outside the range is refused rather than clamped, so
// a caller that hands over a stale number is told instead of silently given `Direct`.
inline bool is_valid_delivery(const int p_delivery) {
	return p_delivery >= 0 && p_delivery < DELIVERY_COUNT;
}

inline Delivery delivery_from_int(const int p_delivery, const Delivery p_fallback = Delivery::Direct) {
	return is_valid_delivery(p_delivery) ? Delivery(p_delivery) : p_fallback;
}

inline const char *delivery_name(const Delivery p_delivery) {
	switch (p_delivery) {
		case Delivery::AVT:
			return "AVT";
		case Delivery::Clipmap:
			return "Clipmap";
		case Delivery::SVT:
			return "SVT";
		default:
			return "Direct";
	}
}

// The whole setting. The default is the shipped architecture expressed in the new
// vocabulary - near material on AVT, far material on SVT, height direct in both bands - so
// loading a scene with no delivery settings written reproduces the previous behaviour.
struct DeliveryMatrix {
	Delivery cell[TIER_COUNT][GROUP_COUNT] = {
		{ Delivery::AVT, Delivery::Direct },
		{ Delivery::SVT, Delivery::Direct },
	};

	Delivery get(const Tier p_tier, const ChannelGroup p_group) const {
		return cell[int(p_tier)][int(p_group)];
	}

	// Writes one cell. Returns true when the value changed, so a setter can skip a service
	// rebuild it would otherwise repeat: a dock that re-applies its controls on every
	// refresh must not rebuild the pool.
	bool set(const Tier p_tier, const ChannelGroup p_group, const Delivery p_delivery) {
		if (!is_valid_delivery(int(p_delivery))) {
			return false;
		}
		Delivery &target = cell[int(p_tier)][int(p_group)];
		if (target == p_delivery) {
			return false;
		}
		target = p_delivery;
		return true;
	}

	// Whether any cell selected this method. The three service questions below are the only
	// way the assembly rule is read, so a new service is one function and not a scan at
	// every call site.
	bool uses(const Delivery p_delivery) const {
		for (int tier = 0; tier < TIER_COUNT; tier++) {
			for (int group = 0; group < GROUP_COUNT; group++) {
				if (cell[tier][group] == p_delivery) {
					return true;
				}
			}
		}
		return false;
	}

	// Whether any *service* was selected at all: false is the all-direct configuration,
	// which is the one that must build no service, no array, no uniform and no shader arm.
	bool any_service() const { return uses(Delivery::AVT) || uses(Delivery::Clipmap) || uses(Delivery::SVT); }

	// Whether a group is delivered by a method in a tier, which is what a family's
	// publication is decided from: the material arrays are not produced for a tier whose
	// only user is the height group.
	bool group_uses(const ChannelGroup p_group, const Delivery p_delivery) const {
		for (int tier = 0; tier < TIER_COUNT; tier++) {
			if (cell[tier][int(p_group)] == p_delivery) {
				return true;
			}
		}
		return false;
	}

	bool tier_uses(const Tier p_tier, const Delivery p_delivery) const {
		for (int group = 0; group < GROUP_COUNT; group++) {
			if (cell[int(p_tier)][group] == p_delivery) {
				return true;
			}
		}
		return false;
	}

	// The tier a group is delivered in by this method, or the tier that is nearer when
	// neither is. Diagnostics only: the shader and the CPU both walk the two tiers
	// themselves, so nothing depends on this being a choice.
	bool near_material() const { return get(Tier::Near, ChannelGroup::Material) != Delivery::Direct; }
	bool near_height() const { return get(Tier::Near, ChannelGroup::Height) != Delivery::Direct; }
	bool far_material() const { return get(Tier::Far, ChannelGroup::Material) != Delivery::Direct; }
	bool far_height() const { return get(Tier::Far, ChannelGroup::Height) != Delivery::Direct; }
};

} // namespace TerrainVT

#endif // TERRAIN_VT_DELIVERY_H
