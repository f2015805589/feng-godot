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
#include <utility>
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

// Builds one bounded page set for a fixed quality bias. The public wrapper below may
// call this a small, fixed number of times; keeping the trial local means a rejected
// detail walk never leaks a partial request set to the main thread.
static void plan_pages_for_bias(Terrain3DAVTRefinement &r_job, const TerrainAVT::PlanInput &p_input,
		const int p_mip_bias) {
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
	// A positive bias is the explicit LOD contract used while the physical pool is
	// oversubscribed. The shader receives the same scale and therefore resolves the
	// coarser parent this plan keeps instead of diagnosing the omitted fine child.
	const float texels_per_pixel = MAX(0.000001f,
			p_input.texels_per_pixel * std::ldexp(1.f, -p_mip_bias));
	const int budget = p_input.budget;
	const int root_level = p_input.root_level;
	const int page_size = p_input.page_size;
	r_job.mip_bias = p_mip_bias;

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
	struct Page {
		const Sector *sector;
		int mip, x, y;
		Rect2 rect;
		float distance;
		float priority;
		float minimum_density;
		bool required;
		bool sampled;
	};
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
		// The material applies the same quality/budget scale to its world
		// derivative. Keep the lower bound in that scaled density space too;
		// otherwise a parent selected after a positive mip bias can be marked
		// optional even though it is the shader's first valid fallback.
		const float minimum_density = patch.minimum_density * texels_per_pixel / density_margin;
		// Predict demand, not urgency. At high speed the predicted eye can be tens
		// of metres ahead; ordering by that eye delays the detail under the real
		// camera. The immutable actual-eye snapshot adds no per-tick main-thread work.
		const Vector3 &priority_eye = p_input.priority_camera_position;
		const Vector3 closest(CLAMP(priority_eye.x, footprint.position.x, footprint.get_end().x),
				CLAMP(priority_eye.y, heights.x, heights.y),
				CLAMP(priority_eye.z, footprint.position.y, footprint.get_end().y));
		const float priority_distance = closest.distance_to(priority_eye);
		page = { &sector, mip, x, y, rect, priority_distance,
				(mip > 0 || sector.level > 0) && projected > 1.f ? MAX(1.f, projected) : 0.f,
				minimum_density,
				prefetch || (mip == 0 && sector.level == 0) || minimum_density * span <= page_size * 2.f,
				page_size <= span * patch.density * texels_per_pixel * 2.01f };
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
		// `pages` is the refinement walk, not the residency set: a complete family can
		// leave its intermediate parent optional after all four children are accepted.
		// Keep those two resources separate. The raster budget is checked after family
		// requirements are finalized; this limit only bounds worker memory and CPU.
		int sampled_required_count = 0;
		for (const Page &page : pages) {
			sampled_required_count += page.required && page.sampled ? 1 : 0;
		}
		const int visited_limit = MAX(root_count, MAX(32, page_budget * 8));
		auto set_required = [&sampled_required_count](Page &page, const bool p_required) {
			if (page.required == p_required) { return; }
			if (page.sampled) { sampled_required_count += p_required ? 1 : -1; }
			page.required = p_required;
		};
		auto set_sampled = [&sampled_required_count](Page &page, const bool p_sampled) {
			if (page.sampled == p_sampled) { return; }
			if (page.required) { sampled_required_count += p_sampled ? 1 : -1; }
			page.sampled = p_sampled;
		};
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
			if (int(pages.size()) + child_count <= visited_limit) {
				Family family{ best, {} };
				for (int i = 0; i < child_count; ++i) {
					const Page &child = children[i];
					family.children[family.count++] = int(pages.size());
					if (child.priority > 0.f) { candidates.emplace(child.priority, -int(pages.size())); }
					sampled_required_count += child.required && child.sampled ? 1 : 0;
					pages.push_back(child);
				}
				if (complete && child_count > 0) { families.push_back(family); }
			} else {
				// A visited-limit denial must leave its parent as the page the shader can
				// resolve. It is a traversal bound, not a physical residency decision;
				// the final required count below drives any quality bias.
				set_required(pages[best], true);
				set_sampled(pages[best], true);
				denied += child_count;
			}
			if (!complete || child_count == 0) {
				// A hierarchy child can be absent from the visible working set (or all
				// children can be clipped). Preserve the covering node rather than
				// allowing an incomplete family to erase its only fallback.
				set_required(pages[best], true);
				set_sampled(pages[best], true);
			}
		}
		for (auto family = families.rbegin(); family != families.rend(); ++family) {
			Page &parent = pages[family->parent];
			float minimum = 1e30f;
			for (int i = 0; i < family->count; ++i) { minimum = MIN(minimum, pages[family->children[i]].minimum_density); }
			parent.minimum_density = MAX(parent.minimum_density, minimum);
			if (parent.sector->level == root_level) {
				// World roots are the terminal strict-mode coverage guarantee. A
				// complete child family must never erase the root that serves a
				// still-arriving child or a view that turns into this world cell.
				set_required(parent, true);
				set_sampled(parent, true);
			} else {
				set_required(parent, parent.minimum_density * parent.rect.size.x <= page_size * 2.f);
			}
		}
		// Optional traversal nodes and unsampled apron pages are free here; only
		// required pages in the sampled prefix consume the raster budget. This is
		// the signal for the bounded mip-bias retry in the outer wrapper.
		denied += MAX(0, sampled_required_count - page_budget);
		return denied;
	};
	r_job.denied = refine_pages(chosen, budget);

	r_job.pages.clear();
	std::vector<Terrain3DAVTPageRequest> apron;
	auto request_from_page = [&](const Page &page, const bool p_optional) {
		TerrainVT::PageRequestKind kind = TerrainVT::PageRequestKind::CURRENT;
		if (p_optional) {
			kind = TerrainVT::PageRequestKind::OPTIONAL;
		} else if (page.sector->level == root_level) {
			kind = TerrainVT::PageRequestKind::ROOT;
		}
		return Terrain3DAVTPageRequest{ page.sector->owner, page.mip, page.x, page.y, page.rect,
				TerrainVT::make_page_request_priority(kind, page.distance, page.rect.size.x) };
	};
	for (const Page &page : chosen) {
		if (!page.required) { continue; }
		(page.sampled ? r_job.pages : apron).push_back(request_from_page(page, !page.sampled));
	}
	// Keep the plan handed to the main thread in the same order the producer and
	// source queue will consume. The sampled prefix remains a prefix; only its
	// roots/current bands are ordered, followed by the optional apron.
	auto request_before = [](const Terrain3DAVTPageRequest &p_left, const Terrain3DAVTPageRequest &p_right) {
		return TerrainVT::page_request_priority_before(p_left.priority, p_right.priority);
	};
	std::stable_sort(r_job.pages.begin(), r_job.pages.end(), request_before);
	std::stable_sort(apron.begin(), apron.end(), request_before);
	// Speculative fine mips must never get ahead of pages the current image
	// samples. Limit the apron to spare capacity so it cannot saturate a large
	// world's cache or starve real requests in the 16-page generation budget.
	// The apron is what is left after the reservation above, not after the walk alone: the
	// retention window is appended to this plan at install time, and an apron sized to the walk's
	// own leftover spent that reservation as well, putting every installed plan a retention
	// window over its budget.
	const int retain_reserve = MIN(RETAIN_RESERVE, MAX(0, budget / 4));
	const int ahead_count = MIN(int(apron.size()),
			MIN(256, MAX(0, budget - retain_reserve - int(r_job.pages.size()))));
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
	for (const Page &page : warm) { r_job.warm.push_back(request_from_page(page, true)); }
	std::stable_sort(r_job.warm.begin(), r_job.warm.end(), request_before);

	r_job.roots = root_count;
	// The budget the installer keeps the completed plan inside once the retention window is
	// appended to it.
	r_job.budget = budget;

	r_job.elapsed_us = Time::get_singleton()->get_ticks_usec() - plan_start;
}

// Selects the page set for one plan key. Runs on the plan worker; the result is
// published through `r_job.ready` only after a bounded bias search has produced a
// self-consistent page set.
void TerrainAVT::plan_pages(Terrain3DAVTRefinement &r_job, const TerrainAVT::PlanInput &p_input) {
	static constexpr int MAX_MIP_BIAS = 32; // also clamps extreme root spans and high quality scales
	const uint64_t started = Time::get_singleton()->get_ticks_usec();
	// The installer reads only after ready is published. Reuse the unpublished
	// payload across trials, avoiding copies and preserving vector capacity.
	for (int bias = 0; bias <= MAX_MIP_BIAS; ++bias) {
		plan_pages_for_bias(r_job, p_input, bias);
		if (r_job.denied == 0) {
			break;
		}
	}
	r_job.elapsed_us = Time::get_singleton()->get_ticks_usec() - started;
	r_job.ready.store(true, std::memory_order_release);
}
