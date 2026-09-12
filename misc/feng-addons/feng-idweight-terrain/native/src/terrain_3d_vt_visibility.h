// Shared camera-visible terrain footprint queries for AVT and SVT demand.
#pragma once
#include <godot_cpp/classes/camera3d.hpp>
#include <godot_cpp/classes/viewport.hpp>
#include <vector>
#include <algorithm>

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
};
struct VisibleView {
	std::vector<Plane> planes;
	Vector3 eye;
	Vector3 forward;
	float focal = 1.f;
	bool orthographic = false;
	explicit VisibleView(Camera3D *camera) {
		const TypedArray<Plane> frustum = camera->get_frustum();
		for (int i = 0; i < frustum.size(); ++i) { planes.push_back(frustum[i]); }
		eye = camera->get_global_position();
		forward = -camera->get_global_basis().get_column(2).normalized();
		orthographic = camera->get_projection() == Camera3D::PROJECTION_ORTHOGONAL;
		const float height = camera->get_viewport() ? camera->get_viewport()->get_visible_rect().size.y : 720.f;
		focal = MAX(1.f, height) * Math::abs(camera->get_camera_projection()[1].y) * 0.5f;
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
			return true;
		}
		// Clip terrain footprint planes, not just the region centre. This keeps a
		// visible edge eligible when the centre or the point below the eye is off-screen.
		const int height_count = heights.x == heights.y ? 1 : 3;
		for (int height_index = 0; height_index < height_count; ++height_index) {
			const float height = heights.x + (heights.y - heights.x) * (height_index * 0.5f);
			std::vector<Vector3> polygon = {
				Vector3(rect.position.x, height, rect.position.y),
				Vector3(rect.get_end().x, height, rect.position.y),
				Vector3(rect.get_end().x, height, rect.get_end().y),
				Vector3(rect.position.x, height, rect.get_end().y) };
			for (int i = 0; i < planes.size() && !polygon.empty(); ++i) {
				const Plane plane = planes[i];
				std::vector<Vector3> clipped;
				Vector3 previous = polygon.back();
				float previous_distance = plane.distance_to(previous);
				for (const Vector3 &point : polygon) {
					const float distance = plane.distance_to(point);
					if ((distance <= 0.f) != (previous_distance <= 0.f)) {
						clipped.push_back(previous.lerp(point, previous_distance / (previous_distance - distance)));
					}
					if (distance <= 0.f) { clipped.push_back(point); }
					previous = point;
					previous_distance = distance;
				}
				polygon.swap(clipped);
			}
			if (polygon.size() < 3) { continue; }
			const Vector3 ground(eye.x, height, eye.z);
			bool positive = false, negative = false;
			Vector3 nearest;
			float best = 1e30f;
			float worst = 0.f;
			for (size_t i = 0; i < polygon.size(); ++i) {
				const Vector3 a = polygon[i], b = polygon[(i + 1) % polygon.size()];
				const Vector3 edge = b - a;
				const float side = edge.cross(ground - a).y;
				positive |= side > 0.0001f;
				negative |= side < -0.0001f;
				const Vector3 point = a + edge * CLAMP((ground - a).dot(edge) / MAX(0.000001f, edge.length_squared()), 0.f, 1.f);
				const float distance = point.distance_squared_to(eye);
				if (distance < best) { best = distance; nearest = point; }
				worst = MAX(worst, distance);
			}
			if (!(positive && negative)) { nearest = ground; best = ground.distance_squared_to(eye); }
			if (best < result.distance * result.distance) {
				result.nearest = nearest;
				result.distance = Math::sqrt(best);
				// Distance is convex over a convex polygon, so the vertices carry the
				// farthest point; the frustum polygon is convex by construction.
				result.farthest = Math::sqrt(worst);
				result.density = orthographic ? focal : focal / MAX(0.01f, (nearest - eye).dot(forward));
			}
		}
		return result.distance < 1e29f;
	}
};
} // namespace TerrainVT
