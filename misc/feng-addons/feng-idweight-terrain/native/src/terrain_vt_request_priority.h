// Ordering shared by AVT page generation and page production.
//
// This header intentionally has no Godot or terrain dependencies. A page's
// priority is metadata produced with the request, so the worker and the
// producer cannot silently grow different notions of what is urgent.
#ifndef TERRAIN_VT_REQUEST_PRIORITY_H
#define TERRAIN_VT_REQUEST_PRIORITY_H

#include <cmath>
#include <cstdint>
#include <limits>

namespace TerrainVT {

enum class PageRequestKind : uint8_t {
	ROOT = 0,
	CURRENT = 1,
	OPTIONAL = 2,
};

struct PageRequestPriority {
	PageRequestKind kind = PageRequestKind::OPTIONAL;
	int distance_band = 127;
	float span = 0.f;
	float distance = std::numeric_limits<float>::max();
};

// Keep malformed visibility input at the cold end of the queue. The returned
// value is finite, so sorting remains a strict weak ordering even if a caller
// hands the helper NaN, infinity, or a negative distance.
inline float page_priority_distance(const float p_distance) noexcept {
	if (!std::isfinite(p_distance) || p_distance < 0.f) {
		return std::numeric_limits<float>::max();
	}
	return p_distance;
}

inline float page_priority_span(const float p_span) noexcept {
	return std::isfinite(p_span) && p_span > 0.f ? p_span : 0.f;
}

inline int page_priority_distance_band(const float p_distance) noexcept {
	const float distance = page_priority_distance(p_distance);
	if (distance <= 1.f) {
		return 0;
	}
	// `float` has a bounded exponent, so this conversion is safe after the
	// finite sanitization above and remains stable for the largest input.
	return static_cast<int>(std::floor(std::log2(distance)));
}

inline PageRequestPriority make_page_request_priority(const PageRequestKind p_kind,
		const float p_distance, const float p_span) noexcept {
	const float distance = page_priority_distance(p_distance);
	return { p_kind, page_priority_distance_band(distance), page_priority_span(p_span), distance };
}

// Return true when p_left must be submitted/consumed before p_right. Equal
// keys deliberately return false both ways; callers use stable_sort so page
// generation order remains the deterministic final tie breaker.
inline bool page_request_priority_before(const PageRequestPriority &p_left,
		const PageRequestPriority &p_right) noexcept {
	if (p_left.kind != p_right.kind) {
		return static_cast<uint8_t>(p_left.kind) < static_cast<uint8_t>(p_right.kind);
	}
	if (p_left.distance_band != p_right.distance_band) {
		return p_left.distance_band < p_right.distance_band;
	}
	if (p_left.span != p_right.span) {
		return p_left.span > p_right.span;
	}
	if (p_left.distance != p_right.distance) {
		return p_left.distance < p_right.distance;
	}
	return false;
}

} // namespace TerrainVT

#endif // TERRAIN_VT_REQUEST_PRIORITY_H
