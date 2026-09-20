// Pure CPU helpers for the virtual-texture screen-footprint contract.
//
// The shader resolves a virtual mip from the two world-space derivatives of a
// pixel.  This header keeps the corresponding Jacobian math independent of
// Godot types so the demand planner and a standalone contract test can share
// exactly the same calculation.

#ifndef TERRAIN_VT_SAMPLING_H
#define TERRAIN_VT_SAMPLING_H

#include <algorithm>
#include <cmath>

namespace TerrainVT {
namespace Sampling {

struct Vec2 {
	float x = 0.f;
	float y = 0.f;
};

struct Jacobian {
	Vec2 dx;
	Vec2 dy;
};

struct Footprint {
	float major = 0.f;
	float minor = 0.f;
	float effective = 0.f;
};

struct FootprintBounds {
	float major_min = 0.f;
	float major_max = 0.f;
	float minor_min = 0.f;
	float minor_max = 0.f;
	float effective_min = 0.f;
	float effective_max = 0.f;
};

inline float length(const Vec2 &p_value) {
	return std::sqrt(p_value.x * p_value.x + p_value.y * p_value.y);
}

inline float max_abs(float p_min, float p_max) {
	return std::max(std::fabs(p_min), std::fabs(p_max));
}

inline Footprint singular_footprint(const Jacobian &p_jacobian, float p_anisotropy) {
	const float a = p_jacobian.dx.x * p_jacobian.dx.x + p_jacobian.dx.y * p_jacobian.dx.y;
	const float b = p_jacobian.dx.x * p_jacobian.dy.x + p_jacobian.dx.y * p_jacobian.dy.y;
	const float c = p_jacobian.dy.x * p_jacobian.dy.x + p_jacobian.dy.y * p_jacobian.dy.y;
	const float discriminant = std::sqrt(std::max(0.f, (a - c) * (a - c) + 4.f * b * b));
	const float major = std::sqrt(std::max(0.f, 0.5f * (a + c + discriminant)));
	const float minor = major > 0.f ? std::fabs(p_jacobian.dx.x * p_jacobian.dy.y -
			p_jacobian.dx.y * p_jacobian.dy.x) / major : 0.f;
	const float anisotropy = std::max(1.f, p_anisotropy);
	return { major, minor, std::max(minor, major / anisotropy) };
}

// Bounds for all matrices whose four components lie in the supplied intervals.
// Weyl's singular-value inequality bounds each singular value by the Frobenius
// radius around the interval midpoint. `p_major_lower_hint` is an optional
// independent lower bound, useful when a caller already has a tighter row-norm
// bound over the clipped polygon.
inline FootprintBounds singular_footprint_bounds(const Vec2 &p_dx_min, const Vec2 &p_dx_max,
		const Vec2 &p_dy_min, const Vec2 &p_dy_max, float p_anisotropy,
		float p_major_lower_hint = 0.f) {
	const Jacobian center = {
		{ (p_dx_min.x + p_dx_max.x) * 0.5f, (p_dx_min.y + p_dx_max.y) * 0.5f },
		{ (p_dy_min.x + p_dy_max.x) * 0.5f, (p_dy_min.y + p_dy_max.y) * 0.5f },
	};
	const Vec2 dx_half = { (p_dx_max.x - p_dx_min.x) * 0.5f, (p_dx_max.y - p_dx_min.y) * 0.5f };
	const Vec2 dy_half = { (p_dy_max.x - p_dy_min.x) * 0.5f, (p_dy_max.y - p_dy_min.y) * 0.5f };
	const float error = std::sqrt(dx_half.x * dx_half.x + dx_half.y * dx_half.y +
			dy_half.x * dy_half.x + dy_half.y * dy_half.y);
	const Footprint midpoint = singular_footprint(center, 1.f);
	const float row_max_frobenius = std::sqrt(
			max_abs(p_dx_min.x, p_dx_max.x) * max_abs(p_dx_min.x, p_dx_max.x) +
			max_abs(p_dx_min.y, p_dx_max.y) * max_abs(p_dx_min.y, p_dx_max.y) +
			max_abs(p_dy_min.x, p_dy_max.x) * max_abs(p_dy_min.x, p_dy_max.x) +
			max_abs(p_dy_min.y, p_dy_max.y) * max_abs(p_dy_min.y, p_dy_max.y));
	const float anisotropy = std::max(1.f, p_anisotropy);
	FootprintBounds result;
	result.major_min = std::max({ 0.f, midpoint.major - error, p_major_lower_hint });
	result.major_max = std::min(midpoint.major + error, row_max_frobenius);
	result.major_max = std::max(result.major_max, result.major_min);
	result.minor_min = std::max(0.f, midpoint.minor - error);
	result.minor_max = std::min(result.major_max, midpoint.minor + error);
	result.minor_max = std::max(result.minor_max, result.minor_min);
	result.effective_min = std::max(result.minor_min, result.major_min / anisotropy);
	result.effective_max = std::max(result.minor_max, result.major_max / anisotropy);
	return result;
}

} // namespace Sampling
} // namespace TerrainVT

#endif // TERRAIN_VT_SAMPLING_H
