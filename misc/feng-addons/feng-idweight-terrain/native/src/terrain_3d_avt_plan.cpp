// Independent dense fallback and demand-driven high-resolution local mip chains.
#include "terrain_3d.h"
#include "terrain_3d_avt_plan.h"
#include <godot_cpp/classes/time.hpp>
#include <algorithm>
#include <queue>
#include <cmath>

namespace TerrainAVT {
void plan_pages(Terrain3DAVTRefinement &r_job, const PlanInput &p_input) {
	const uint64_t started = Time::get_singleton()->get_ticks_usec();
	r_job.pages = p_input.coarse.pages;
	r_job.roots = int(r_job.pages.size());
	r_job.budget = p_input.budget;
	r_job.warm.clear();
	r_job.retain_cap = r_job.tail_cap = r_job.mip_bias = r_job.denied = 0;
	struct Node {
		const Terrain3DAVTSector *cell;
		int mip, x, y;
		Rect2 rect;
		float distance, density;
	};
	auto farther = [](const Node &a, const Node &b) {
		if (a.cell->produce != b.cell->produce) { return !a.cell->produce; }
		if (a.distance != b.distance) { return a.distance > b.distance; }
		return a.mip > b.mip;
	};
	std::priority_queue<Node, std::vector<Node>, decltype(farther)> pending(farther);
	auto enqueue = [&](const Terrain3DAVTSector &cell, int mip, int x, int y, bool root = false) {
		const float span = p_input.section_world * float(1 << mip) / cell.logical_pages;
		const Rect2 rect(Vector2(cell.location) * p_input.section_world + Vector2(x, y) * span, Vector2(span, span));
		const Rect2 footprint = rect.intersection(Rect2(Vector2(cell.location) * p_input.section_world, Vector2(p_input.section_world, p_input.section_world)));
		if (!footprint.has_area()) { return; }
		const Vector2 nearest(CLAMP(p_input.focus.x, footprint.position.x, footprint.get_end().x), CLAMP(p_input.focus.y, footprint.position.y, footprint.get_end().y));
		if (nearest.distance_squared_to(p_input.focus) > p_input.reach * p_input.reach) { return; }
		const Vector2 heights = p_input.bounds_ready ? p_input.source->bounds(footprint, cell.heights) : cell.heights;
		TerrainVT::VisiblePatch patch;
		if (!p_input.view.sample(footprint, heights, patch)) {
			if (!root) { return; }
			patch.distance = cell.distance; patch.density = 0.f;
		}
		const float density = patch.density * p_input.texels_per_pixel * AVT_DEMAND_DENSITY_MARGIN;
		// No local allocation/physical demand when the independent baseline suffices.
		if (!root && p_input.coarse.page_world * density <= p_input.page_size) { return; }
		pending.push({ &cell, mip, x, y, rect, patch.distance, density });
	};
	for (const auto &cell : p_input.working) {
		if (cell.size > 0) { enqueue(cell, TerrainVT::log2_power_of_two(cell.size), 0, 0, true); }
	}
	const int coarse_count = r_job.roots;
	const int available = MAX(0, p_input.budget - coarse_count);
	const int root_limit = MAX(0, available / 3);
	std::vector<Node> roots;
	while (!pending.empty() && int(roots.size()) < root_limit) { roots.push_back(pending.top()); pending.pop(); }
	while (!pending.empty()) { pending.pop(); }
	for (const Node &node : roots) {
		r_job.pages.push_back({ node.cell->owner, node.mip, node.x, node.y, node.rect,
			TerrainVT::make_page_request_priority(TerrainVT::PageRequestKind::ROOT, node.distance, node.rect.size.x) });
		if (node.mip > 0 && node.cell->produce && node.rect.size.x * node.density > p_input.page_size) {
			for (int y = 0; y < 2; ++y) for (int x = 0; x < 2; ++x) { enqueue(*node.cell, node.mip - 1, x, y); }
		}
	}
	r_job.roots = int(r_job.pages.size());
	// Keep a small recently-visible window while making room for the new view.
	// Every local image has a complete parent chain; the sector tier count never
	// truncates this traversal or the shader's ready-parent search.
	const int retain_reserve = MIN(16, available / 8);
	const int visit_limit = MAX(64, p_input.budget * 64);
	int visited = 0;
	while (!pending.empty() && int(r_job.pages.size()) < p_input.budget - retain_reserve && visited++ < visit_limit) {
		const Node node = pending.top(); pending.pop();
		r_job.pages.push_back({ node.cell->owner, node.mip, node.x, node.y, node.rect,
			TerrainVT::make_page_request_priority(TerrainVT::PageRequestKind::CURRENT, node.distance, node.rect.size.x) });
		if (node.mip > 0 && node.rect.size.x * node.density > p_input.page_size) {
			for (int y = 0; y < 2; ++y) for (int x = 0; x < 2; ++x) { enqueue(*node.cell, node.mip - 1, node.x * 2 + x, node.y * 2 + y); }
		}
	}
	r_job.retain_cap = MIN(retain_reserve, MAX(0, p_input.budget - int(r_job.pages.size())));
	r_job.tail_cap = r_job.retain_cap;
	r_job.denied = int(pending.size());
	std::stable_sort(r_job.pages.begin() + r_job.roots, r_job.pages.end(), [](const auto &a, const auto &b) {
		return TerrainVT::page_request_priority_before(a.priority, b.priority);
	});
	r_job.sampled = int(r_job.pages.size());
	r_job.finest = 0.f;
	r_job.level_mips.resize(17); r_job.level_mips.fill(0);
	for (const auto &page : r_job.pages) {
		const float texel = page.rect.size.x / p_input.page_size;
		r_job.finest = r_job.finest > 0.f ? MIN(r_job.finest, texel) : texel;
		if (page.owner != avt_coarse_owner()) { r_job.level_mips.set(page.mip, r_job.level_mips[page.mip] + 1); }
	}
	r_job.world_pages = coarse_count;
	r_job.elapsed_us = Time::get_singleton()->get_ticks_usec() - started;
	r_job.ready.store(true, std::memory_order_release);
}
} // namespace TerrainAVT
