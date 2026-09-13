// Shared camera-visible terrain footprint queries for AVT and SVT demand.
#pragma once
#include <godot_cpp/classes/camera3d.hpp>
#include <godot_cpp/classes/viewport.hpp>
#include <vector>
#include <array>
#include <algorithm>
#include <limits>

namespace TerrainVT {
using namespace godot;
struct VisiblePatch {
	Vector3 nearest;
	float distance = 1e30f;
	// Distance to the farthest visible point of the same footprint. The far-field
	// demand needs both ends of the span: a page carries every level its visible
	// footprint reaches into, from the level of its nearest point to the level of its
	// farthest one.
	float farthest = 0.f;
	float density = 0.f;
	float minimum_density = 0.f;

};
struct VisibleView {
	std::vector<Plane> planes;
	Vector3 eye;
	Vector3 forward, right, up;
	float focal = 1.f;
	bool orthographic = false;
	explicit VisibleView(Camera3D *camera, float guard_pixels = 0.f) {
		const Transform3D camera_transform = camera->get_camera_transform();
		const auto frustum = camera->get_camera_projection().get_projection_planes(camera_transform);
		for (int i = 0; i < frustum.size(); ++i) { planes.push_back(frustum[i]); }
		eye = camera_transform.origin;
		forward = -camera_transform.basis.get_column(2).normalized();
		right = camera_transform.basis.get_column(0).normalized();
		up = camera_transform.basis.get_column(1).normalized();
		orthographic = camera->get_projection() == Camera3D::PROJECTION_ORTHOGONAL;
		const float height = camera->get_viewport() ? camera->get_viewport()->get_visible_rect().size.y : 720.f;
		focal = MAX(1.f, height) * Math::abs(camera->get_camera_projection()[1].y) * 0.5f;
		// Request just outside the rendered frustum so a moving edge does not
		// expose pages before asynchronous production can complete.
		if (guard_pixels > 0.f) {
			for (Plane &plane : planes) {
				if (Math::abs(plane.normal.dot(forward)) > 0.999f) { continue; }
				if (orthographic) { plane.d += guard_pixels / focal; }
				else {
					plane.normal = (plane.normal - forward * (guard_pixels / focal)).normalized();
					plane.d = plane.normal.dot(eye);
				}
			}
		}
	}
	float surface_density(const Vector3 &point, const Vector3 &normal) const {
		const float depth = (point - eye).dot(forward);
		if (depth <= 0.f) { return 0.f; }
		const Vector3 ray = orthographic ? forward : (point - eye) / depth;
		const float denominator = normal.dot(ray);
		if (Math::abs(denominator) < 0.000001f) { return 0.f; }
		const Vector3 dx = right - ray * (normal.dot(right) / denominator);
		const Vector3 dy = up - ray * (normal.dot(up) / denominator);
		const float footprint = MAX(Vector2(dx.x, dx.z).length(), Vector2(dy.x, dy.z).length());
		return focal / MAX(0.000001f, footprint * (orthographic ? 1.f : depth));
	}
	// A conservative lower density bound for a horizontal source patch. The
	// derivative numerator is affine in world XZ; its norm is maximal at a
	// convex polygon vertex. Bound depth separately to keep their product safe.
	Vector2 surface_density_range(const Vector3 *points, int count, const Vector3 &normal = Vector3(0, 1, 0)) const {
		if (count == 0) { return Vector2(0, 1e30f); }
		float max_depth = 0.f, min_depth = 1e30f, max_gradient = 0.f, max_world = 1.f;
		Vector2 dx_min(1e30f, 1e30f), dx_max(-1e30f, -1e30f), dy_min = dx_min, dy_max = dx_max;
		for (int i = 0; i < count; ++i) {
			const Vector3 delta = points[i] - eye;
			max_world = MAX(max_world, MAX(Math::abs(points[i].x), Math::abs(points[i].z)));
			const float divisor = normal.dot(orthographic ? forward : delta);
			if (Math::abs(divisor) < 0.000001f) { return Vector2(0, 1e30f); }
			const Vector3 direction = orthographic ? forward : delta;
			const Vector3 dx = right - direction * (normal.dot(right) / divisor);
			const Vector3 dy = up - direction * (normal.dot(up) / divisor);
			max_gradient = MAX(max_gradient, MAX(Vector2(dx.x, dx.z).length(), Vector2(dy.x, dy.z).length()));
			const Vector2 gx(dx.x, dx.z), gy(dy.x, dy.z);
			dx_min = dx_min.min(gx); dx_max = dx_max.max(gx);
			dy_min = dy_min.min(gy); dy_max = dy_max.max(gy);
			max_depth = MAX(max_depth, delta.dot(forward));
			min_depth = MIN(min_depth, delta.dot(forward));
		}
		// Each gradient is affine over the clipped polygon. Its bounding box
		// supplies a lower norm bound, independent of the positive depth bound.
		// This accounts for grazing views instead of requesting focus/depth mips
		// which the fragment's XZ derivatives can never select.
		const Vector2 near_dx(CLAMP(0.f, dx_min.x, dx_max.x), CLAMP(0.f, dx_min.y, dx_max.y));
		const Vector2 near_dy(CLAMP(0.f, dy_min.x, dy_max.x), CLAMP(0.f, dy_min.y, dy_max.y));
		const float min_gradient = MAX(near_dx.length(), near_dy.length());
		// Shader derivatives subtract interpolated float world positions. Include
		// their representational error so isolated pixels at a mip boundary cannot
		// select a neighbouring mip which exact CPU arithmetic omitted.
		const float roundoff = max_world * std::numeric_limits<float>::epsilon() * 4.f;
		const float largest = max_gradient * (orthographic ? 1.f : max_depth) / focal;
		const float smallest = min_gradient * (orthographic ? 1.f : min_depth) / focal;
		return Vector2(1.f / MAX(0.000001f, largest * 1.01f + roundoff),
				1.f / MAX(0.000001f, smallest * 0.99f - roundoff));
	}
	bool sample_triangle(const Vector3 &a, const Vector3 &b, const Vector3 &c, const Rect2 &rect, VisiblePatch &result) const {
		std::array<Vector3, 16> polygon = {a, b, c}, clipped;
		int count = 3;
		const Plane edges[] = {Plane(Vector3(-1, 0, 0), -rect.position.x), Plane(Vector3(1, 0, 0), rect.get_end().x),
			Plane(Vector3(0, 0, -1), -rect.position.y), Plane(Vector3(0, 0, 1), rect.get_end().y)};
		for (int plane_index = 0; plane_index < int(planes.size()) + 4 && count; ++plane_index) {
			const Plane &plane = plane_index < int(planes.size()) ? planes[plane_index] : edges[plane_index - planes.size()];
			int output = 0;
			Vector3 previous = polygon[count - 1];
			float before = plane.distance_to(previous);
			for (int i = 0; i < count; ++i) {
				const Vector3 point = polygon[i];
				const float after = plane.distance_to(point);
				if ((before <= 0.f) != (after <= 0.f)) { clipped[output++] = previous.lerp(point, before / (before - after)); }
				if (after <= 0.f) { clipped[output++] = point; }
				previous = point; before = after;
			}
			count = output; polygon.swap(clipped);
		}
		if (count < 3) { return false; }
		const Vector2 density = surface_density_range(polygon.data(), count, (b - a).cross(c - a).normalized());
		result.density = MAX(result.density, density.y);
		result.minimum_density = MIN(result.minimum_density, density.x);
		return true;
	}
	bool sample(const Rect2 &rect, const Vector2 &heights, VisiblePatch &result) const {
		result = VisiblePatch();
		// Most distant sectors lie entirely inside the frustum. Classify their
		// height bounds without constructing/clipping three heap polygons.
		const Vector3 center(rect.get_center().x, (heights.x + heights.y) * 0.5f, rect.get_center().y);
		const Vector3 extent(rect.size.x * 0.5f, (heights.y - heights.x) * 0.5f, rect.size.y * 0.5f);
		bool inside = true;
		for (const Plane &plane : planes) {
			const float radius = plane.normal.abs().dot(extent);
			const float distance = plane.distance_to(center);
			if (distance > radius) { return false; }
			if (distance > -radius) { inside = false; }
		}
		if (inside && heights.x == heights.y) {
			result.nearest = Vector3(CLAMP(eye.x, rect.position.x, rect.get_end().x), heights.x, CLAMP(eye.z, rect.position.y, rect.get_end().y));
			result.distance = result.nearest.distance_to(eye);
			for (const Vector3 &corner : {Vector3(rect.position.x, heights.x, rect.position.y), Vector3(rect.position.x, heights.x, rect.get_end().y), Vector3(rect.get_end().x, heights.x, rect.position.y), Vector3(rect.get_end().x, heights.x, rect.get_end().y)}) {
				result.farthest = MAX(result.farthest, corner.distance_to(eye));
			}
			result.density = orthographic ? focal : focal / MAX(0.01f, (result.nearest - eye).dot(forward));
			const Vector3 corners[] = { Vector3(rect.position.x, heights.x, rect.position.y), Vector3(rect.get_end().x, heights.x, rect.position.y), Vector3(rect.get_end().x, heights.x, rect.get_end().y), Vector3(rect.position.x, heights.x, rect.get_end().y) };
			const Vector2 density = surface_density_range(corners, 4);
			result.minimum_density = density.x; result.density = density.y;
			return true;
		}
		// Clip terrain footprint planes, not just the region centre. This keeps a
		// visible edge eligible when the centre or the point below the eye is off-screen.
		const int height_count = heights.x == heights.y ? 1 : 3;
		for (int height_index = 0; height_index < height_count; ++height_index) {
			const float height = heights.x + (heights.y - heights.x) * (height_index * 0.5f);
			std::array<Vector3, 16> polygon = {
				Vector3(rect.position.x, height, rect.position.y),
				Vector3(rect.get_end().x, height, rect.position.y),
				Vector3(rect.get_end().x, height, rect.get_end().y),
				Vector3(rect.position.x, height, rect.get_end().y) };
			// A convex polygon gains at most one vertex per clipping plane.
			// Six frustum planes need at most ten vertices; keep both buffers on the stack.
			int polygon_count = 4;
			std::array<Vector3, 16> clipped;
			for (int i = 0; i < planes.size() && polygon_count > 0; ++i) {
				const Plane plane = planes[i];
				int clipped_count = 0;
				Vector3 previous = polygon[polygon_count - 1];
				float previous_distance = plane.distance_to(previous);
				for (int vertex = 0; vertex < polygon_count; ++vertex) {
					const Vector3 &point = polygon[vertex];
					const float distance = plane.distance_to(point);
					if ((distance <= 0.f) != (previous_distance <= 0.f)) {
						clipped[clipped_count++] = previous.lerp(point, previous_distance / (previous_distance - distance));
					}
					if (distance <= 0.f) { clipped[clipped_count++] = point; }
					previous = point;
					previous_distance = distance;
				}
				polygon.swap(clipped);
				polygon_count = clipped_count;
			}
			if (polygon_count < 3) { continue; }
			if (height_count == 1) { const Vector2 density = surface_density_range(polygon.data(), polygon_count); result.minimum_density = density.x; result.density = density.y; }
			const Vector3 ground(eye.x, height, eye.z);
			bool positive = false, negative = false;
			Vector3 nearest;
			float best = 1e30f;
			float worst = 0.f;
			float nearest_depth = 1e30f;
			for (size_t i = 0; i < size_t(polygon_count); ++i) {
				const Vector3 a = polygon[i], b = polygon[(i + 1) % polygon_count];
				const Vector3 edge = b - a;
				const float side = edge.cross(ground - a).y;
				positive |= side > 0.0001f;
				negative |= side < -0.0001f;
				const Vector3 point = a + edge * CLAMP((ground - a).dot(edge) / MAX(0.000001f, edge.length_squared()), 0.f, 1.f);
				const float distance = point.distance_squared_to(eye);
				if (distance < best) { best = distance; nearest = point; }
				worst = MAX(worst, a.distance_squared_to(eye));
				nearest_depth = MIN(nearest_depth, (a - eye).dot(forward));
			}
			if (!(positive && negative)) { nearest = ground; best = ground.distance_squared_to(eye); }
			// Every clipped height plane contributes to the far distance, even
			// when another plane owns the nearest point. SVT needs both ends.
			result.farthest = MAX(result.farthest, Math::sqrt(worst));
			if (height_count > 1) { result.density = MAX(result.density, orthographic ? focal : focal / MAX(0.01f, nearest_depth)); }
			if (best < result.distance * result.distance) {
				result.nearest = nearest;
				result.distance = Math::sqrt(best);
				// Distance is convex over a convex polygon, so the vertices carry the
				// farthest point; the frustum polygon is convex by construction.
			}
		}
		if (result.distance >= 1e29f) {
			// A frustum can intersect a sloped patch between all three horizontal
			// slices. The AABB passed the separating-plane test: keep that demand.
			result.nearest = Vector3(CLAMP(eye.x, rect.position.x, rect.get_end().x), CLAMP(eye.y, heights.x, heights.y), CLAMP(eye.z, rect.position.y, rect.get_end().y));
			result.distance = result.nearest.distance_to(eye);
			result.farthest = ((center - eye).abs() + extent).length();
			result.density = orthographic ? focal : focal / MAX(0.01f, (center - eye).dot(forward) - extent.dot(forward.abs()));
		}
		return true;
	}
};
} // namespace TerrainVT
