// Hydra-compatible surface data contract. No Godot or Unity dependencies.
#ifndef TERRAIN_SURFACE_IDWEIGHT_H
#define TERRAIN_SURFACE_IDWEIGHT_H

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace TerrainSurfaceIdWeight {
constexpr uint32_t FORMAT_VERSION = 1;
constexpr int MATERIAL_COUNT = 32;
enum class Mode : uint8_t { SET, ADD, SUB, MIX };

struct Pair {
	uint8_t overlay = 0;
	uint8_t background = 0;
	Mode mode = Mode::SET;
	uint8_t level = 1;
	uint8_t uv = 0;
};

inline bool encode(const Pair &p, uint16_t &out) {
	if (p.overlay >= MATERIAL_COUNT || p.background >= MATERIAL_COUNT ||
			uint8_t(p.mode) > 3 || p.level < 1 || p.level > 8 || p.uv != 0) {
		return false;
	}
	out = uint16_t((p.overlay << 11) | (p.background << 6) |
			(uint8_t(p.mode) << 4) | ((p.level - 1) << 1));
	return true;
}

inline Pair decode(uint16_t value) {
	return { uint8_t((value >> 11) & 31), uint8_t((value >> 6) & 31),
		Mode((value >> 4) & 3), uint8_t(((value >> 1) & 7) + 1), uint8_t(value & 1) };
}

inline uint16_t single(uint8_t id) {
	// Callers validate IDs before invoking this convenience function.
	return uint16_t((id << 11) | (id << 6));
}

inline float contribution(uint16_t value) {
	Pair p = decode(value);
	return p.overlay == p.background ? 0.f : float(p.level) / 8.f;
}

inline float saturate(float value) { return std::max(0.f, std::min(1.f, value)); }

// Unity Mathf.RoundToInt uses ties-to-even; std::round would change brush edges.
inline bool quantize(float value, int &level) {
	if (!std::isfinite(value)) {
		return false;
	}
	float scaled = saturate(value) * 8.f;
	int lower = int(std::floor(scaled));
	float fraction = scaled - float(lower);
	level = lower + int(fraction > 0.5f || (fraction == 0.5f && (lower & 1)));
	return true;
}

inline bool paint(uint16_t current, const Pair &target, float influence, uint16_t &out) {
	uint16_t validated;
	if (!encode(target, validated) || !std::isfinite(influence)) {
		return false;
	}
	influence = saturate(influence);
	if (influence == 0.f) {
		out = current;
		return true;
	}
	if (target.overlay == target.background) {
		out = single(target.background);
		return true;
	}
	Pair previous = decode(current);
	float weight = float(target.level) / 8.f;
	float next = previous.overlay == target.overlay && previous.background == target.background
			? contribution(current) + (weight - contribution(current)) * influence
			: weight * influence;
	int level;
	if (!quantize(next, level)) {
		return false;
	}
	Pair result = target;
	result.level = uint8_t(std::max(1, level));
	return encode(result, out);
}

inline float mode_weight(Mode mode, float linear, float slope) {
	switch (mode) {
		case Mode::ADD: return saturate(linear + slope * (1.f - linear));
		case Mode::SUB: return saturate(linear * (1.f - slope));
		case Mode::MIX: return slope;
		default: return linear;
	}
}

inline float slope_tangent(float normal_dot_up, uint8_t level, float raw_sharpness) {
	constexpr float thresholds[8] = { 0.f, .125f, .25f, .375f, .5f, .625f, .75f, .98f };
	float angle = std::acos(saturate(normal_dot_up));
	float square = angle * angle;
	float tangent = saturate(angle + angle * square / 3.f + 2.f * angle * square * square / 15.f);
	float low = thresholds[std::max(1, std::min(8, int(level))) - 1];
	float sharpness = std::max(.1f, std::min(1000.f, raw_sharpness)) * .001f;
	return saturate((tangent - low) / std::max(saturate(low + sharpness) - low, .00001f));
}

inline void barycentric(float x, float y, float (&weights)[3]) {
	weights[0] = 1.f - std::max(x, y);
	weights[1] = std::abs(x - y);
	weights[2] = std::min(x, y);
}

struct LegacyConversion {
	uint16_t packed = 0;
	uint32_t metadata = 0;
	float weight_error = 0.f;
	bool needs_auto_material_bake = false;
};

// Legacy RF control is bit-reinterpreted by the caller, never numerically cast.
inline LegacyConversion convert_legacy(uint32_t control) {
	uint8_t background = uint8_t((control >> 27) & 31);
	uint8_t overlay = uint8_t((control >> 22) & 31);
	float weight = float((control >> 14) & 255) / 255.f;
	int level = 0;
	quantize(weight, level);
	LegacyConversion result;
	// Preserve all non-material bits including UV, holes, navigation and auto flag.
	result.metadata = control & 0x3fffu;
	result.needs_auto_material_bake = (control & 1u) != 0;
	if (background == overlay || level == 0) {
		result.packed = single(background);
	} else {
		Pair p = { overlay, background, Mode::SET, uint8_t(level), 0 };
		encode(p, result.packed);
	}
	result.weight_error = background == overlay ? 0.f : std::abs(contribution(result.packed) - weight);
	return result;
}

inline void write_le(uint16_t value, uint8_t *bytes) {
	bytes[0] = uint8_t(value);
	bytes[1] = uint8_t(value >> 8);
}
inline uint16_t read_le(const uint8_t *bytes) {
	return uint16_t(bytes[0] | (uint16_t(bytes[1]) << 8));
}
} // namespace TerrainSurfaceIdWeight
#endif
