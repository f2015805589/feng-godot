// The near field's plan worker: the page selection the demand pass hands to a task.
//
// Everything this file is allowed to read arrives in `TerrainAVT::PlanInput` - the camera, the
// source snapshot and the working set - so it runs against a world that cannot change under it
// while the main thread installs, retains and produces. The demand pass that builds that input,
// the plan key that decides when a new one is submitted, and the address directory the selection
// resolves against are in terrain_3d_sector_avt.cpp; the input itself is declared in
// terrain_3d_avt_plan.h.
#include "terrain_3d.h"
#include "terrain_3d_avt_plan.h"
#include "terrain_3d_surface_baker.h"
#include "terrain_3d_vt_visibility.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <map>
#include <queue>
#include <tuple>
#include <unordered_set>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/time.hpp>

namespace {
using Sector = Terrain3DAVTSector;
// The plan's own spelling of the sector key and of the two world model constants the AVT
// files share; the constants themselves are in terrain_3d_avt.h.
using SectorKey = std::pair<int, int>;
constexpr float SECTOR_WORLD = AVT_SECTOR_WORLD;
constexpr float DEMAND_DENSITY_MARGIN = AVT_DEMAND_DENSITY_MARGIN;
} // namespace

// Selects the page set for one plan key. Runs on the plan worker; the result is
// published through `r_job.ready` for the main thread to install.
void TerrainAVT::plan_pages(Terrain3DAVTRefinement &r_job, const TerrainAVT::PlanInput &p_input) {
	const uint64_t plan_start = Time::get_singleton()->get_ticks_usec();
	const std::vector<Sector> &working = p_input.working;
	const std::shared_ptr<const Terrain3DPagePipeline::Snapshot> &source = p_input.source;
	const TerrainVT::VisibleView &view = p_input.view;
	const bool bounds_ready = p_input.bounds_ready;
	const Vector3 &camera_position = p_input.camera_position;
	const Vector2 &focus = p_input.focus;
	const float reach = p_input.reach;
	const float exact_radius = p_input.exact_radius;
	const float logical_ratio = p_input.logical_ratio;
	const float texels_per_pixel = p_input.texels_per_pixel;
	const int budget = p_input.budget;
	const int root_level = p_input.root_level;
	const int page_size = p_input.page_size;

	std::map<SectorKey, const Sector *> nodes;
	for (const Sector &sector : working) { nodes[{ sector.owner.x, sector.owner.y }] = &sector; }
	auto owner_key = [](const Vector2i &owner) { return SectorKey(owner.x, owner.y); };
	// The other half of the reach test `_avt_scan_sectors()` applies in terrain_3d_sector_avt.cpp:
	// this one rejects a page whose footprint is out of reach, that one never creates the cell in
	// the first place, and the two have to agree or the plan names pages no scan enumerated. The
	// arithmetic below is the scan's because `focus` and the camera's XZ are the same point.
	auto surrounding_sample = [&](const Rect2 &rect, const Vector2 &heights, TerrainVT::VisiblePatch &patch) {
		const Vector2 nearest(CLAMP(focus.x, rect.position.x, rect.get_end().x), CLAMP(focus.y, rect.position.y, rect.get_end().y));
		if (nearest.distance_squared_to(focus) > (reach + SECTOR_WORLD) * (reach + SECTOR_WORLD)) { return false; }
		patch.nearest = Vector3(nearest.x, CLAMP(camera_position.y, heights.x, heights.y), nearest.y);
		patch.distance = patch.nearest.distance_to(camera_position);
		patch.density = view.orthographic ? view.focal : view.focal * 2.f / MAX(0.01f, patch.distance);
		return true;
	};
	struct Page { const Sector *sector; int mip, x, y; Rect2 rect; float priority; float minimum_density; bool required; bool sampled; };
	std::vector<Page> chosen;

	auto make_page = [&](const Sector &sector, int mip, int x, int y, Page &page, bool prefetch = false) {
		const int size = sector.size;
		const float logical = sector.level ? 1.f : size * logical_ratio;
		const float span = SECTOR_WORLD * float(1 << sector.level) * float(1 << mip) / logical;
		const Rect2 sector_rect(Vector2(sector.location) * (SECTOR_WORLD * float(1 << sector.level)), Vector2(1, 1) * (SECTOR_WORLD * float(1 << sector.level)));
		const Rect2 rect(sector_rect.position + Vector2(x, y) * span, Vector2(span, span));
		TerrainVT::VisiblePatch patch;
		if (!rect.intersects(sector_rect)) { return false; }
		const Rect2 footprint = rect.intersection(sector_rect);
		const Vector2 heights = bounds_ready ? source->bounds(footprint, sector.heights) : sector.heights;
		if (prefetch ? !surrounding_sample(footprint, heights, patch) : !view.sample(footprint, heights, patch)) { return false; }
		// Perspective derivatives on a slope need not match a horizontal plane.
		// Sample the actual source triangles as well as the conservative bounds.
		const Vector2 farthest(MAX(Math::abs(footprint.position.x - focus.x), Math::abs(footprint.get_end().x - focus.x)),
				MAX(Math::abs(footprint.position.y - focus.y), Math::abs(footprint.get_end().y - focus.y)));
		if (!prefetch && heights.x != heights.y && footprint.size.x <= 4.f * source->spacing && farthest.length() < exact_radius) {
			// Clip the actual near-field mesh triangles. Height-box projection can
			// request entire hidden/offscreen columns of mip 0 on a steep slope.
			TerrainVT::VisiblePatch projected_surface;
			if (!source->project_surface(footprint.grow(4.f * span / page_size + 0.0001f), view, projected_surface)) { return false; }
			patch.density = projected_surface.density;
			patch.minimum_density = projected_surface.minimum_density;
		} else if (!prefetch && heights.x != heights.y) {
			for (int z = 0; z < 3; ++z) for (int x = 0; x < 3; ++x) {
				const Vector2 at = footprint.position + footprint.size * Vector2((x + 0.001f) / 2.002f, (z + 0.001f) / 2.002f);
				Vector3 point, normal;
				if (source->surface(at, point, normal)) {
					patch.density = MAX(patch.density, view.surface_density(point, normal));
				}
			}
		}
		// Near slopes can expose a finer footprint abruptly as the eye crosses
		// a source triangle. Keep a wider refinement apron there only.
		const float density_margin = heights.x != heights.y && farthest.length() < exact_radius ? 3.f : DEMAND_DENSITY_MARGIN;
		const float density = patch.density * texels_per_pixel * density_margin;
		const float projected = span * density / page_size;
		const float minimum_density = patch.minimum_density / density_margin;
		page = { &sector, mip, x, y, rect, (mip > 0 || sector.level > 0) && projected > 1.f ? MAX(1.f, projected) : 0.f, minimum_density, prefetch || (mip == 0 && sector.level == 0) || minimum_density * span <= page_size * 2.f, page_size <= span * patch.density * texels_per_pixel * 2.01f };
		return true;
	};
	for (const Sector &sector : working) {
		if (sector.level != root_level || !(sector.size > 0)) { continue; }
		Page page;
		// Terminal AVT roots are the feedback guarantee, not view-dependent detail. Select
		// every root inside the CPU reach with the conservative surrounding sample so a yaw
		// change keeps resolving within AVT. Treat it as sampled/required so it is produced
		// before refinement instead of waiting in the idle-prefetch queue.
		if (make_page(sector, 0, 0, 0, page, true)) {
			page.sampled = true;
			page.required = true;
			chosen.push_back(page);
		}
	}
	const int root_count = int(chosen.size());
	// How many addresses the completed plan holds for the retention window, which is appended to
	// the plan *after* the walk. One number for both halves: the walk reserves it and the apron
	// may not spend it.
	static const int RETAIN_RESERVE = 128;
	// Retain the mip interval reached by the visible footprint, including its
	// transition apron. A completed child family supplies tighter parent bounds.
	auto refine_pages = [&](std::vector<Page> &pages, int page_budget) {
		int denied = 0;
		// The plan may not name more pages than the residency it is served from. A demand
		// larger than the pool cannot converge: production is bounded by the page budget, so
		// the pages the plan keeps naming are evicted again before the view samples them, and
		// the visible-miss counters stay pinned at the plan size however long the view is
		// still. A grazing view is exactly where this happens - the mip the footprints select
		// is fine over the whole visible world at once, and a walk eight times the pool
		// selected eight thousand sampled pages for a thousand slots (measured: 8112 sampled,
		// 8090 missing, pool full, 208 evictions, never settling). The walk is priority
		// ordered, so a budget equal to the pool spends on the pages with the largest screen
		// footprint and leaves the rest on their coarse parent, which is resident.
		// The retention window is appended to the plan after this walk and is capped at 128
		// addresses, so the walk leaves that much of the budget for it: a plan that fills the
		// pool and then appends its retained tail cannot hold its own newest requests, which
		// is what leaves a settled view at a few dozen misses instead of none.
		const int walk_budget = MAX(32, page_budget - RETAIN_RESERVE);
		struct Family { int parent; std::array<int, 4> children; int count = 0; };
		std::vector<Family> families;
		std::priority_queue<std::pair<float, int>> candidates;
		for (int i = 0; i < int(pages.size()); ++i) {
			if (pages[i].priority > 0.f) { candidates.emplace(pages[i].priority, -i); }
		}
		while (!candidates.empty()) {
			const int best = -candidates.top().second;
			candidates.pop();
			const Page parent = pages[best];
			pages[best].priority = 0.f;
			std::array<Page, 4> children;
			int child_count = 0;
			bool complete = true;
			for (int y = 0; y < 2; ++y) for (int x = 0; x < 2; ++x) {
				Page child;
				if (parent.sector->level > 0) {
					const int level = parent.sector->level - 1;
					const Vector2i child_owner(parent.sector->location.x * 2 + x, parent.sector->location.y * 2 + y + (level ? 0x40000000 + level * 0x100000 : 0));
					const auto node = nodes.find(owner_key(child_owner));
					if (node == nodes.end() || !(node->second->size > 0)) { complete = false; continue; }
					const int mip = level ? 0 : TerrainVT::log2_power_of_two(node->second->size);
					if (make_page(*node->second, mip, 0, 0, child)) { children[child_count++] = child; }
				} else if (parent.mip > 0 && make_page(*parent.sector, parent.mip - 1, parent.x * 2 + x, parent.y * 2 + y, child)) {
					children[child_count++] = child;
				}
			}
			if (int(pages.size()) + child_count <= walk_budget) {
				Family family{ best, {} };
				for (int i = 0; i < child_count; ++i) {
					const Page &child = children[i];
					family.children[family.count++] = int(pages.size());
					if (child.priority > 0.f) { candidates.emplace(child.priority, -int(pages.size())); }
					pages.push_back(child);
				}
				if (complete && child_count > 0) { families.push_back(family); }
			} else { denied += child_count; }
		}
		for (auto family = families.rbegin(); family != families.rend(); ++family) {
			Page &parent = pages[family->parent];
			float minimum = 1e30f;
			for (int i = 0; i < family->count; ++i) { minimum = MIN(minimum, pages[family->children[i]].minimum_density); }
			parent.minimum_density = MAX(parent.minimum_density, minimum);
			parent.required = parent.minimum_density * parent.rect.size.x <= page_size * 2.f;
		}
		return denied;
	};
	r_job.denied = refine_pages(chosen, budget);

	r_job.pages.clear();
	std::vector<Terrain3DAVTPageRequest> apron;
	for (const Page &page : chosen) {
		if (!page.required) { continue; }
		(page.sampled ? r_job.pages : apron).push_back({ page.sector->owner, page.mip, page.x, page.y, page.rect });
	}
	// Speculative fine mips must never get ahead of pages the current image
	// samples. Limit the apron to spare capacity so it cannot saturate a large
	// world's cache or starve real requests in the 16-page generation budget.
	r_job.denied += MAX(0, int(r_job.pages.size()) - budget);
	// The apron is what is left after the reservation above, not after the walk alone: the
	// retention window is appended to this plan at install time, and an apron sized to the walk's
	// own leftover spent that reservation as well, putting every installed plan a retention
	// window over its budget.
	const int ahead_count = MIN(int(apron.size()),
			MIN(256, MAX(0, budget - RETAIN_RESERVE - int(r_job.pages.size()))));
	r_job.pages.insert(r_job.pages.end(), apron.begin(), apron.begin() + ahead_count);
	// The leading entries are the pages the current image samples; the apron follows.
	r_job.sampled = int(r_job.pages.size()) - ahead_count;
	float finest_requested_texel = FLT_MAX;
	for (const Terrain3DAVTPageRequest &page : r_job.pages) { finest_requested_texel = MIN(finest_requested_texel, page.rect.size.x / page_size); }
	r_job.finest = r_job.pages.empty() ? 0.f : finest_requested_texel;

	// Prepare surrounding detail after the visible plan is fixed. A separate idle
	// queue may use free slots, but never evicts a resident page or steals demand.
	std::vector<Page> warm;
	for (const Sector &sector : working) {
		if (sector.level != root_level || !(sector.size > 0)) { continue; }
		Page page;
		if (make_page(sector, 0, 0, 0, page, true)) { warm.push_back(page); }
	}
	// Idle coverage needs only world roots. Refining a full spare-cache tree
	// on every moving view delays visible planning and immediately becomes stale.
	r_job.warm.clear();
	for (const Page &page : warm) { r_job.warm.push_back({ page.sector->owner, page.mip, page.x, page.y, page.rect }); }

	r_job.roots = root_count;
	// The budget the installer keeps the completed plan inside once the retention window is
	// appended to it.
	r_job.budget = budget;

	r_job.elapsed_us = Time::get_singleton()->get_ticks_usec() - plan_start;
	r_job.ready.store(true, std::memory_order_release);
}
