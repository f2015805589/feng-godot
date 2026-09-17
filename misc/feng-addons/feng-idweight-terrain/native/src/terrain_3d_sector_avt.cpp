// World-aligned procedural AVT. Geometry regions are deliberately not sectors.
#include "terrain_3d.h"
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
#include <godot_cpp/classes/time.hpp>

namespace {
constexpr float SECTOR_WORLD = 64.f;
// Demand leads footprint changes so asynchronous production completes before
// a normal mip transition. This does not alter the shader's mip selection.
constexpr float DEMAND_DENSITY_MARGIN = 1.25f;
// Motion look-ahead shaping. The velocity is smoothed because a single frame of
// jitter must not aim the plan; both rates are clamped because a teleport or a snap
// turn is not a prediction the page pipeline can serve.
constexpr float MOTION_SMOOTHING = 0.25f;
constexpr float MOTION_MAX_SPEED = 400.f;
constexpr float MOTION_LEAD_REACH_FRACTION = 0.5f;
// How fast the lead itself may move, in metres per second of lead change. The lead is a
// position derived from a velocity estimate, and a frame time that varies makes that
// estimate vary: without a slew limit a noisy frame time swings the plan by metres, which
// re-selects the whole working set and throws away the source jobs in flight for it.
constexpr float MOTION_LEAD_SLEW_RATE = 40.f;
// Two ticks closer together than this carry no new motion information: a displacement over
// almost no elapsed time is a velocity spike, and the demand plans with its result.
constexpr uint64_t MOTION_MIN_INTERVAL_US = 1000;
// The predicted transform is snapped to this grid (metres, and radians for yaw) so the
// plan key is stable while the camera moves inside one cell. A plan key that changes every
// frame re-derives the whole working set every frame: every page address is re-selected,
// every source job in flight for the previous selection is thrown away, and the worker
// time spent on it is wasted three times over.
constexpr float MOTION_PLAN_QUANTUM = 4.f;
// The eye height is quantized less coarsely: it is what the near field's screen density is
// measured from, and it follows the terrain continuously while the camera moves. A metre of
// error would move a mip boundary; the height is snapped only far enough to stop the plan
// key from changing on every frame of a smooth slope.
constexpr float MOTION_HEIGHT_QUANTUM = 2.f;
// The orientation is snapped for exactly the reason the position is, and it is the one that
// matters for a camera that turns: an exact basis changes the key on every frame of a pan,
// so every tick submits a plan and the next tick replaces it before the worker has finished
// - which throws the worker's time away, keeps the working set churning instead of
// converging, and is what makes a turn refine in visible blocks. Two degrees of yaw is
// under a third of a frame at a fast 6 degrees per frame, and the pages are still selected
// from the exact predicted transform: the key only decides when a selection is re-derived.
constexpr float MOTION_YAW_QUANTUM = 0.034906585f; // 2 degrees
constexpr float MOTION_PITCH_QUANTUM = 0.026179939f; // 1.5 degrees
constexpr float MOTION_ROLL_QUANTUM = 0.052359878f; // 3 degrees
// The source queue's window is 32 entries. A prime leaves the queue alone while this many are still
// claimable, because those are requests the workers have not reached yet: adding to a half-full
// queue re-scans it and inserts nothing, at the cost of the queue mutex, behind the workers that
// are holding it. `_avt_retain_visible()` has already dropped everything the current plan does not
// name, so a queue this deep is current-plan work either way.
constexpr int SOURCE_QUEUE_REFILL_ABOVE = 16;
using SectorKey = std::pair<int, int>;
uint32_t sector_hash(int x, int y, int level) {
	return uint32_t(x) * 73856093u ^ uint32_t(y) * 19349663u ^ uint32_t(level) * 83492791u;
}
int floor_div(int value, int scale) { return int(std::floor(double(value) / scale)); }
// Owner keys are the 64-bit (x, y) pair the address directory and the page
// requests are both indexed by.
uint64_t avt_owner_key(const Vector2i &owner) { return (uint64_t(uint32_t(owner.x)) << 32) | uint32_t(owner.y); }
// FNV-1a over one page address. The demand-age map is keyed by this, so a collision
// would only mis-age a diagnostic counter, never a page.
uint64_t avt_page_age_key(const Terrain3DAVTPageRequest &p_page) {
	uint64_t key = 1469598103934665603ull;
	for (const uint32_t word : { uint32_t(p_page.owner.x), uint32_t(p_page.owner.y),
			uint32_t(p_page.mip), uint32_t(p_page.x), uint32_t(p_page.y) }) {
		key = (key ^ word) * 1099511628211ull;
	}
	return key;
}
}

void Terrain3D::set_surface_vt_texels_per_meter(real_t p_value) {
	if (!std::isfinite(p_value)) { return; }
	p_value = CLAMP(p_value, 1.f, 8192.f);
	if (_vt.surface_vt_texels_per_meter == p_value) { return; }
	_vt.surface_vt_texels_per_meter = p_value;
	_reset_vt_configuration(); // A changed density changes every page footprint.
}
void Terrain3D::set_surface_svt_texels_per_meter(real_t p_value) {
	if (!std::isfinite(p_value)) { return; }
	set_surface_svt_page_world(_vt.vt_page_size / CLAMP(p_value, 0.01f, 8192.f));
}
int Terrain3D::get_avt_base_block_size() const {
	int size = 1;
	while (size < 64.f * _vt.surface_vt_texels_per_meter / _vt.vt_page_size) { size <<= 1; }
	return size;
}
// The number of texels a level 0 sector block carries per page, as a multiple of its page
// count: `size * logical_ratio` is the block's virtual resolution for `SECTOR_WORLD`
// metres. Derived here rather than read from the plan, because the chain that re-configures a
// view publishes its directory before it submits the plan: the first publish of a configuration
// would otherwise read the previous configuration's ratio.
float Terrain3D::_avt_logical_ratio() const {
	return SECTOR_WORLD * _vt.surface_vt_texels_per_meter / (_vt.vt_page_size * get_avt_base_block_size());
}
// Motion look-ahead. A page costs several frames to assemble and a compressed page
// several more to encode and read back, so demand issued at the moment a page becomes
// visible can only ever be late: the view streams in. The plan therefore describes the
// camera's position one lead ahead, which turns the production latency into latency that
// the camera has not reached yet. The velocity is exponentially smoothed, so a stop
// decays the lead instead of leaving the plan aimed at a position the camera left, and
// an edit or a teleport is bounded by the clamps below.
void Terrain3D::_vt_update_motion_lead() {
	Camera3D *camera = get_camera();
	if (!camera || !camera->is_inside_tree() || _vt.vt_motion_lead_ms <= 0.f) {
		_vt.avt_motion_lead = Vector2();
		_vt.avt_motion_valid = false;
		_vt.avt_motion_velocity = Vector2();
		_vt.avt_retain_epochs = 8;
		return;
	}
	const Transform3D transform = camera->get_camera_transform();
	const Vector2 focus(transform.origin.x, transform.origin.z);
	const uint64_t now = Time::get_singleton()->get_ticks_usec();
	if (_vt.avt_motion_valid && now <= _vt.avt_motion_stamp_us + MOTION_MIN_INTERVAL_US) {
		return;
	}
	float delta = 0.f;
	if (_vt.avt_motion_valid && now > _vt.avt_motion_stamp_us) {
		delta = float(double(now - _vt.avt_motion_stamp_us) / 1000000.0);
		if (delta > 0.0005f) {
			Vector2 velocity = (focus - _vt.avt_motion_last_focus) / delta;
			if (velocity.length() > MOTION_MAX_SPEED) { velocity = velocity.normalized() * MOTION_MAX_SPEED; }
			_vt.avt_motion_velocity = _vt.avt_motion_velocity.lerp(velocity, MOTION_SMOOTHING);
		}
	}
	_vt.avt_motion_last_focus = focus;
	_vt.avt_motion_stamp_us = now;
	_vt.avt_motion_valid = true;
	const float lead_seconds = float(_vt.vt_motion_lead_ms) / 1000.f;
	// A plan pointing further than half the near field's reach would spend production on
	// terrain the camera may never approach, so the lead is clamped by the reach.
	const float max_lead = MAX(64.f, float(_vt.surface_vt_distance)) * MOTION_LEAD_REACH_FRACTION;
	Vector2 target = _vt.avt_motion_velocity * lead_seconds;
	if (target.length() > max_lead) { target = target.normalized() * max_lead; }
	// Slew limit: a real acceleration is followed within a few frames, a noisy frame time
	// is not followed at all.
	const float max_step = MOTION_LEAD_SLEW_RATE * MAX(delta, 0.001f);
	const Vector2 change = target - _vt.avt_motion_lead;
	_vt.avt_motion_lead = change.length() > max_step ? _vt.avt_motion_lead + change.normalized() * max_step : target;
	// Retention is measured in plan epochs, which are one install apart. The window is at least
	// one lead wide: the plan describes the view *ahead* of the camera, so the view being
	// rendered is covered by requests retained from the plans that preceded it.
	_vt.avt_retain_epochs = CLAMP(int(float(_vt.vt_motion_lead_ms) / 16.7f) + 8, 8, 96);
}

Transform3D Terrain3D::_vt_lead_camera_transform(const Transform3D &p_camera_transform) const {
	if (_vt.avt_motion_lead == Vector2()) {
		return p_camera_transform;
	}
	Transform3D lead = p_camera_transform;
	lead.origin += Vector3(_vt.avt_motion_lead.x, 0.f, _vt.avt_motion_lead.y);
	return lead;
}

// The transform the plan key is derived from: the predicted transform snapped to a grid, so the
// key is unchanged while the camera moves inside one cell. A key that changes every frame
// re-plans the whole working set every frame, and every source job already in flight for the
// previous selection is thrown away with it. The demand itself still uses the exact predicted
// transform - snapping the geometry pages are selected from would move the mip boundaries the
// shader selects against, trading a key-identity problem for a paint one.
Transform3D Terrain3D::_vt_plan_key_transform(const Transform3D &p_camera_transform) const {
	Transform3D keyed = _vt_lead_camera_transform(p_camera_transform);
	keyed.origin.x = Math::round(keyed.origin.x / MOTION_PLAN_QUANTUM) * MOTION_PLAN_QUANTUM;
	keyed.origin.z = Math::round(keyed.origin.z / MOTION_PLAN_QUANTUM) * MOTION_PLAN_QUANTUM;
	keyed.origin.y = Math::round(keyed.origin.y / MOTION_HEIGHT_QUANTUM) * MOTION_HEIGHT_QUANTUM;
	// The orientation is snapped on the same grid idea. Yaw gets the finest step because it
	// is what a camera turn changes; pitch and roll get coarser ones, since a degree of
	// either moves the plan's frustum far less than a degree of yaw.
	const Vector3 euler = keyed.basis.get_euler();
	keyed.basis = Basis::from_euler(Vector3(
			Math::round(euler.x / MOTION_PITCH_QUANTUM) * MOTION_PITCH_QUANTUM,
			Math::round(euler.y / MOTION_YAW_QUANTUM) * MOTION_YAW_QUANTUM,
			Math::round(euler.z / MOTION_ROLL_QUANTUM) * MOTION_ROLL_QUANTUM));
	return keyed;
}

void Terrain3D::set_surface_vt_mip_distances(const PackedFloat32Array &p_distances) {
	PackedFloat32Array normalized;
	for (int i = 0; i < MIN(16, int(p_distances.size())); ++i) {
		const float previous = i ? normalized[i - 1] : 0.f;
		normalized.push_back(std::isfinite(p_distances[i]) ? MAX(previous + 0.01f, p_distances[i]) : previous + 1.f);
	}
	_vt.surface_vt_mip_distances = normalized;
	if (_initialized && _material.is_valid()) { _material->update(Terrain3DMaterial::UNIFORMS_ONLY); }
}
int Terrain3D::get_surface_vt_mip_for_distance(real_t p_distance) const {
	const int top = TerrainVT::log2_power_of_two(is_sector_avt() ? get_avt_base_block_size() : _vt.surface_vt_pages_per_axis);
	int mip = 0;
	float edge = 8.f;
	while (mip < top) {
		if (mip < _vt.surface_vt_mip_distances.size()) { edge = _vt.surface_vt_mip_distances[mip]; }
		if (p_distance <= edge) { break; }
		++mip; edge *= 2.f;
	}
	return mip;
}

void Terrain3D::set_surface_vt_selection_mode(int p_mode) {
	p_mode = CLAMP(p_mode, 0, 2);
	if (_vt.surface_vt_selection_mode == p_mode) { return; }
	_vt.surface_vt_selection_mode = p_mode;
	_vt.vt_view_focus_valid = false;
	// A legacy region coordinate and a 64 m sector coordinate describe different
	// footprints. They cannot share cached address ownership across a mode switch.
	_reset_vt_configuration();
	notify_property_list_changed();
}

namespace {
using Sector = Terrain3DAVTSector;

// Immutable input of one plan. The camera and the source snapshot are copied in
// when the plan is submitted, so the worker never reads terrain state while the
// main thread changes it.
struct AVTPlanInput {
	std::vector<Sector> working;
	std::shared_ptr<const Terrain3DPagePipeline::Snapshot> source;
	TerrainVT::VisibleView view;
	bool bounds_ready = false;
	Vector3 camera_position;
	Vector2 focus;
	float reach = 0.f;
	float exact_radius = 0.f;
	float logical_ratio = 0.f;
	float texels_per_pixel = 1.f;
	int budget = 0;
	int root_level = 0;
	int page_size = 0;
};

// Selects the page set for one plan key. Runs on the plan worker; the result is
// published through `r_job.ready` for the main thread to install.
static void avt_plan_pages(Terrain3DAVTRefinement &r_job, const AVTPlanInput &p_input) {
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
		const int walk_budget = MAX(32, page_budget - 128);
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
	const int ahead_count = MIN(int(apron.size()), MIN(256, MAX(0, budget - int(r_job.pages.size()))));
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

	r_job.elapsed_us = Time::get_singleton()->get_ticks_usec() - plan_start;
	r_job.ready.store(true, std::memory_order_release);
}
} // namespace

// One AVT demand pass per physics tick, in four phases: decide whether this tick
// plans at all, scan the resident regions into demand cells, turn that scan into
// a sorted working set with an address directory, and submit the page selection
// to a worker. Page production happens on every tick, planned or not.
int Terrain3D::_update_sector_avt(int p_max_pages) {
	if (!_vt.surface_vt || !_data || !_vt.vt_shared_ready || !get_camera()) { return 0; }
	const uint64_t started = Time::get_singleton()->get_ticks_usec();
	// Demand is planned for the predicted camera, which is where the view will be when
	// the pages being produced now are needed. The transform is the only difference: the
	// shader still selects mips from the real frustum.
	const Transform3D camera_transform = get_camera()->get_camera_transform();
	const Transform3D lead_transform = _vt_lead_camera_transform(camera_transform);
	const Vector3 camera_position = lead_transform.origin;
	const Vector2 focus(camera_position.x, camera_position.z);
	const float reach = MAX(64.f, float(_vt.surface_vt_distance));
	// Published before the plan is installed or reused, so the readings describe this tick
	// and not the last one that ran the whole planning chain.
	_vt.avt_sector_stats["motion_lead_m"] = _vt.avt_motion_lead.length();
	_vt.avt_sector_stats["motion_speed"] = _vt.avt_motion_velocity.length();
	_vt.avt_sector_stats["plan_origin"] = Vector2(lead_transform.origin.x, lead_transform.origin.z);
	_vt.avt_sector_stats["camera_origin"] = Vector2(camera_transform.origin.x, camera_transform.origin.z);
	if (!_vt.vt_source_snapshot) { _vt.vt_source_snapshot = Terrain3DPagePipeline::snapshot(_data, _region_size, _vertex_spacing, _surface_density); }
	const bool bounds_ready = _vt.vt_source_snapshot->bounds_ready.load(std::memory_order_acquire);

	const PackedByteArray plan_key = _avt_plan_state(bounds_ready);
	// Diagnostic: a plan key that changes every frame re-plans the whole working set, so
	// which component moved is the question worth answering. Component indices follow
	// `_avt_plan_state` (9 basis, 3 origin, 16 projection, 4 viewport, then the scalars).
	{
		int first = -1;
		if (!_vt.avt_plan_key.is_empty() && _vt.avt_plan_key.size() == plan_key.size()) {
			for (int i = 0; i < plan_key.size(); ++i) {
				if (plan_key[i] != _vt.avt_plan_key[i]) { first = i; break; }
			}
		}
		_vt.avt_sector_stats["plan_key_dirty_component"] = first < 0 ? -1 : first / int(sizeof(double));
		_vt.avt_sector_stats["plan_key_unchanged"] = first < 0;
	}
	const int finished = _avt_install_or_reuse_plan(started, p_max_pages, _vt.avt_plan_key == plan_key);
	if (finished >= 0) { return finished; }

	_vt.avt_sector_stats["plan_reused"] = false;
	_vt.avt_sector_stats["coverage_center"] = focus;
	_vt.avt_sector_stats["coverage_radius"] = _vt.surface_svt_enabled ? reach : -1.f;
	// Phase timings for the uncached path, which is the one a moving camera takes on
	// every tick: the visible scan, the sector hierarchy, the address directory, the
	// hand-off to the refinement worker, the directory upload and the page production.
	// The predicted frustum, not the rendered one. `camera_transform` is the real one the
	// engine is using; only the plan moves ahead of it.
	TerrainVT::VisibleView view(lead_transform, get_camera()->get_camera_projection(),
			get_camera()->get_viewport() ? get_camera()->get_viewport()->get_visible_rect().size.y : 720.f,
			get_camera()->get_projection() == Camera3D::PROJECTION_ORTHOGONAL, 192.f);
	// The chain runs in one pass. Staging it across ticks was tried and reverted: the
	// install/reuse path above resets the stage cursor, so a chain that was interrupted
	// between phases could be discarded before it published, which left the directory
	// stale and the view rendering the missing-page diagnostic for whole sectors.
	//
	// The scratch members the phases hand each other are reused rather than rebuilt, so a
	// plan tick does not reallocate the scan and the hierarchy it is about to discard.
	uint64_t phase_start = Time::get_singleton()->get_ticks_usec();
	auto mark_phase = [this, &phase_start](const char *p_key) {
		const uint64_t now = Time::get_singleton()->get_ticks_usec();
		_vt.avt_sector_stats[p_key] = double(now - phase_start) / 1000.0;
		phase_start = now;
	};
	_vt.avt_pending_scan = _avt_scan_sectors(view, camera_position, bounds_ready, focus, reach);
	mark_phase("scan_ms");
	_vt.avt_pending_hierarchy = _avt_build_hierarchy(_vt.avt_pending_scan);
	_vt.avt_pending_scan = Terrain3DAVTSectorScan();
	mark_phase("hierarchy_ms");
	_avt_sync_address_directory(_vt.avt_pending_hierarchy, focus, reach);
	mark_phase("sync_ms");
	_publish_avt_directory(_vt.avt_pending_hierarchy);
	mark_phase("publish_ms");
	_avt_submit_plan(_vt.avt_pending_hierarchy, plan_key, view, camera_position, bounds_ready, focus, reach);
	mark_phase("submit_ms");
	_vt.avt_plan_key = plan_key;
	_vt.avt_pending_hierarchy = Terrain3DAVTHierarchy();

	_vt.avt_sector_stats["height_bounds_ready"] = bounds_ready;
	_vt.avt_sector_stats["retained_hierarchy"] = true;
	_vt.avt_sector_stats["planning_pending"] = true;
	_vt.avt_sector_stats["base_virtual_resolution"] = SECTOR_WORLD * _vt.surface_vt_texels_per_meter;
	_vt.avt_sector_stats["base_page_entries"] = SECTOR_WORLD * _vt.surface_vt_texels_per_meter / _vt.vt_page_size;
	_vt.avt_sector_stats["indirection_size"] = 2048;
	const int produced = _produce_sector_avt_pages(p_max_pages);
	mark_phase("produce_ms");
	_vt.avt_sector_stats["cpu_update_ms"] = double(Time::get_singleton()->get_ticks_usec() - started) / 1000.0;
	return produced;
}

// Publishes the address directory of a finished hierarchy. The material is republished
// only when a uniform it reads changed: the directory texture is updated in place, so its
// new content is already visible to the shader, and republishing every uniform costs more
// than the whole tick budget.
void Terrain3D::_publish_avt_directory(const Terrain3DAVTHierarchy &p_hierarchy) {
	_vt.avt_sector_stats["directory_rebuilt"] = p_hierarchy.directory_dirty || p_hierarchy.root_level != _vt.avt_root_level;
	const bool rebind = _avt_publish_directory(p_hierarchy, p_hierarchy.directory_dirty);
	_vt.avt_sector_stats["visible_sectors"] = int(std::count_if(p_hierarchy.leaves.begin(), p_hierarchy.leaves.end(), [](const Sector &sector) { return sector.produce; }));
	_vt.avt_sector_stats["coarse_pages"] = p_hierarchy.coarse_roots;
	_vt.avt_sector_stats["coarse_world_size"] = SECTOR_WORLD * float(1 << p_hierarchy.root_level);
	_vt.avt_sector_stats["material_ms"] = 0.0;
	if (rebind && _material.is_valid()) {
		const uint64_t material_start = Time::get_singleton()->get_ticks_usec();
		_material->update(Terrain3DMaterial::REGION_ARRAYS);
		_vt.avt_sector_stats["material_ms"] = double(Time::get_singleton()->get_ticks_usec() - material_start) / 1000.0;
	}
}

// Fixed camera/configuration key: no per-frame Variant arrays or region scan.
// All source edits invalidate this key together with the source snapshot.
PackedByteArray Terrain3D::_avt_plan_state(const bool p_bounds_ready) const {
	const Camera3D *camera = get_camera();
	std::array<double, 64> state{};
	int component = 0;
	auto append = [&](double value) { state[component++] = value; };
	// The key describes what the plan is a function of, which is the predicted transform the
	// page set was derived from - not the rendered one, or a moving camera would re-plan every
	// frame while the predicted view had not changed at all.
	const Transform3D transform = _vt_plan_key_transform(camera->get_camera_transform());
	for (int row = 0; row < 3; ++row) for (int col = 0; col < 3; ++col) { append(transform.basis[row][col]); }
	for (int axis = 0; axis < 3; ++axis) { append(transform.origin[axis]); }
	const Projection projection = camera->get_camera_projection();
	for (int col = 0; col < 4; ++col) for (int row = 0; row < 4; ++row) { append(projection[col][row]); }
	const Rect2 viewport = camera->get_viewport()->get_visible_rect();
	append(viewport.position.x); append(viewport.position.y); append(viewport.size.x); append(viewport.size.y);
	append(p_bounds_ready); append(_region_size); append(_vertex_spacing);
	append(_vt.surface_vt_texels_per_meter); append(_vt.surface_vt_texels_per_pixel); append(_vt.vt_adaptive_enabled);
	// The far field's visible count is what reserves part of the pool, but it moves by a page
	// or two on every frame of a moving view. Bucketing it keeps the near field's plan
	// installable while its own footprint is unchanged; an exact count in the key re-planned
	// the whole working set whenever the far field gained or lost a single page.
	append((_vt.vt_svt_visible_pages / 16) * 16); append(_vt.surface_svt_enabled); append(_vt.surface_vt_distance);
	append(!_vt.vt_svt_bake_queue.is_empty() || !_vt.vt_svt_bake_waiting.is_empty());
	append(_vt.vt_page_count); append(_vt.vt_page_size);
	PackedByteArray plan_key;
	plan_key.resize(sizeof(state));
	std::memcpy(plan_key.ptrw(), state.data(), sizeof(state));
	return plan_key;
}

// Only planning is cached. Page requests still touch residency and repair
// invalidated/evicted pages on every demand epoch, within the normal budget.
int Terrain3D::_avt_install_or_reuse_plan(const uint64_t p_started, const int p_max_pages, const bool p_same_plan) {
	bool installed = false;
	if (_vt.avt_refinement && _vt.avt_refinement->ready.load(std::memory_order_acquire)) {
		if (_vt.avt_refinement->key == _vt.avt_plan_key) {
			// Sizing the pool for the pages the image actually samples, not for everything the
			// plan names. The speculative apron is a function of the leftover budget, so
			// counting it here closes a loop - a larger pool allows a larger apron, which asks
			// for a larger pool - and the pair grows until the capacity cap: measured at 1024
			// slots holding 53 near-field pages. The apron and the retained tail live in the
			// slack of that capacity instead.
			// No floor of one here: a request of zero pages must not grow the pool, which is what
			// a minimum of eight slots per request would do on every empty plan.
			if (_ensure_vt_capacity(int(_vt.avt_refinement->pages.size()) + _vt.vt_svt_visible_pages)) { return 0; }
			// A grazing mip can disappear for one plan and reappear immediately.
			// Let recently requested jobs finish instead of repeatedly cancelling
			// their prepared source bytes. Current visibility always comes first.
			const uint64_t epoch = ++_vt.avt_plan_epoch;
			// The retained scan compares every address in the plan against every address
			// still requested. A tree node per address costs more than one tick's whole
			// budget, so the current set is a sorted array searched in place.
			std::vector<std::array<int, 5>> current;
			current.reserve(_vt.avt_refinement->pages.size());
			for (Terrain3DAVTPageRequest &page : _vt.avt_refinement->pages) {
				page.last_visible_plan = epoch;
				current.push_back({ page.owner.x, page.owner.y, page.mip, page.x, page.y });
			}
			std::sort(current.begin(), current.end());
			// The window is at least one lead wide: a page the plan moved ahead of is still
			// in the image being rendered, and dropping its request would let the pool evict
			// it out from under the view that has not caught up yet. The count is capped so a
			// look-ahead plan cannot reserve the whole pool with pages the camera has left.
			const int retain_cap = 128;
			int retained = 0;
			for (const Terrain3DAVTPageRequest &page : _vt.avt_page_plan) {
				if (retained == retain_cap) { break; }
				if (page.last_visible_plan + uint64_t(_vt.avt_retain_epochs) < epoch ||
						std::binary_search(current.begin(), current.end(),
								std::array<int, 5>{ page.owner.x, page.owner.y, page.mip, page.x, page.y })) {
					continue;
				}
				_vt.avt_refinement->pages.push_back(page);
				++retained;
			}
			_vt.avt_retained_pages = retained;
			_vt.avt_sector_stats["retained_requests"] = retained;
			_vt.avt_sector_stats["retain_epochs"] = _vt.avt_retain_epochs;
			_vt.avt_page_plan = std::move(_vt.avt_refinement->pages);
			_vt.avt_sampled_pages = _vt.avt_refinement->sampled;
			_vt.avt_prefetch_plan = std::move(_vt.avt_refinement->warm);
			_vt.avt_prefetch_cursor = 0;
			_vt.avt_prefetch_cycle_pending = false;
			// A new plan is a new wanted set, so the source queue has to be retained again.
			_vt.avt_retain_applied = false;
			_vt.avt_sector_stats["refinement_requests_denied"] = _vt.avt_refinement->denied;
			_vt.avt_sector_stats["finest_requested_texel_world"] = _vt.avt_refinement->finest;
			_vt.avt_sector_stats["visible_root_pages"] = _vt.avt_refinement->roots;
			_vt.avt_sector_stats["requested_physical_pages"] = int(_vt.avt_page_plan.size());
			_vt.avt_sector_stats["prefetch_requests"] = int(_vt.avt_prefetch_plan.size());
			_vt.avt_sector_stats["planning_ms"] = double(_vt.avt_refinement->elapsed_us) / 1000.;
			_vt.avt_sector_stats["plan_age_ms"] = double(p_started - _vt.avt_refinement->submitted_us) / 1000.;
			installed = true;
		}
		_vt.avt_refinement.reset();
	}
	_vt.avt_sector_stats["planning_pending"] = bool(_vt.avt_refinement);
	// Finish an in-flight plan instead of replacing it on every camera tick.
	// Installing a completed plan must not insert an idle planning frame. Its
	// requests remain active while the next camera view is submitted below.
	if (p_same_plan || _vt.avt_refinement) {
		_vt.avt_plan_reused = !installed;
		_vt.avt_sector_stats["plan_reused"] = _vt.avt_plan_reused;
		_vt.avt_sector_stats["directory_rebuilt"] = false;
		const int produced = _produce_sector_avt_pages(p_max_pages);
		_vt.avt_sector_stats["cpu_update_ms"] = double(Time::get_singleton()->get_ticks_usec() - p_started) / 1000.0;
		return produced;
	}
	// A plan that is not being reused leaves the settled verdict false: the caller goes on to run
	// this tick's production pass, and it must not read the absence of an install as an idle plan
	// and skip the work the new view needs.
	_vt.avt_plan_reused = false;
	return -1;
}

// Enumerates the resident regions into 64 m demand cells, each sized to the mip
// its on-screen footprint needs.
Terrain3DAVTSectorScan Terrain3D::_avt_scan_sectors(const TerrainVT::VisibleView &p_view,
		const Vector3 &p_camera_position, const bool p_bounds_ready,
		const Vector2 &p_focus, const float p_reach) const {
	Terrain3DAVTSectorScan scan;
	auto in_reach = [&](const Rect2 &rect) {
		const Vector2 nearest(CLAMP(p_focus.x, rect.position.x, rect.get_end().x), CLAMP(p_focus.y, rect.position.y, rect.get_end().y));
		return nearest.distance_squared_to(p_focus) <= (p_reach + SECTOR_WORLD) * (p_reach + SECTOR_WORLD);
	};
	auto surrounding_sample = [&](const Rect2 &rect, const Vector2 &heights, TerrainVT::VisiblePatch &patch) {
		if (!in_reach(rect)) { return false; }
		patch.nearest = Vector3(CLAMP(p_camera_position.x, rect.position.x, rect.get_end().x),
				CLAMP(p_camera_position.y, heights.x, heights.y), CLAMP(p_camera_position.z, rect.position.y, rect.get_end().y));
		patch.distance = patch.nearest.distance_to(p_camera_position);
		// Conservative demand for a future camera yaw. This only spends idle/free
		// capacity and never changes the visible view's resolution or page budget.
		patch.density = p_view.orthographic ? p_view.focal : p_view.focal * 2.f / MAX(0.01f, patch.distance);
		return true;
	};
	scan.visible.reserve(_data->get_region_locations().size() * 64);
	std::map<SectorKey, size_t> overlapping;

	const float region_world = _region_size * _vertex_spacing;
	const bool aligned_regions = region_world >= SECTOR_WORLD && Math::is_equal_approx(region_world / SECTOR_WORLD, Math::round(region_world / SECTOR_WORLD));
	for (const Vector2i &location : _data->get_region_locations()) {
		Ref<Terrain3DRegion> region = _data->get_region(location);
		if (region.is_null() || region->is_deleted()) { continue; }
		Rect2 rect(Vector2(location) * region_world, Vector2(region_world, region_world));
		if (_vt.surface_svt_enabled && !in_reach(rect)) { continue; }
		int x0 = int(std::floor(rect.position.x / SECTOR_WORLD));
		int y0 = int(std::floor(rect.position.y / SECTOR_WORLD));
		int x1 = int(std::ceil(rect.get_end().x / SECTOR_WORLD)) - 1;
		int y1 = int(std::ceil(rect.get_end().y / SECTOR_WORLD)) - 1;
		if (!scan.has_world) { scan.world_x0 = x0; scan.world_y0 = y0; scan.world_x1 = x1; scan.world_y1 = y1; scan.has_world = true; }
		scan.world_x0 = MIN(scan.world_x0, x0); scan.world_y0 = MIN(scan.world_y0, y0);
		scan.world_x1 = MAX(scan.world_x1, x1); scan.world_y1 = MAX(scan.world_y1, y1);
		TerrainVT::VisiblePatch patch;
		if (!p_view.sample(rect, region->get_height_range(), patch) && !in_reach(rect)) { continue; }
		for (int y = y0; y <= y1; ++y) {
			for (int x = x0; x <= x1; ++x) {
				Rect2 sector_rect(Vector2(x, y) * SECTOR_WORLD, Vector2(SECTOR_WORLD, SECTOR_WORLD));
				if (_vt.surface_svt_enabled && !in_reach(sector_rect)) { continue; }
				// Clip against actual resident data, including regions smaller than a
				// sector and non-unit vertex spacing. Deduplicate overlapping regions.
				const Vector2 sector_heights = p_bounds_ready ? _vt.vt_source_snapshot->bounds(sector_rect.intersection(rect), region->get_height_range()) : region->get_height_range();
				const bool on_screen = p_view.sample(sector_rect.intersection(rect), sector_heights, patch);
				if (!on_screen && !surrounding_sample(sector_rect.intersection(rect), sector_heights, patch)) { continue; }
				const int base = get_avt_base_block_size();
				// Screen density predicts the derivative-selected mip used by the shader.
				const float required_density = MAX(0.001f, patch.density * _vt.surface_vt_texels_per_pixel * DEMAND_DENSITY_MARGIN);
				const int screen_mip = MAX(0, int(std::floor(std::log2(MAX(1.f, float(_vt.surface_vt_texels_per_meter) / required_density)))));
				int wanted = MAX(1, base >> MIN(15, screen_mip));
				if (!_vt.vt_adaptive_enabled) { wanted = base; }
				wanted = MIN(2048, wanted);
				Vector2i key(x, y);
				Sector sector = { key, key, 0, wanted, 1, on_screen, patch.distance, sector_heights };
				if (aligned_regions) { scan.visible.push_back(sector); }
				else {
					auto found = overlapping.find({ x, y });
					if (found == overlapping.end()) { overlapping[{ x, y }] = scan.visible.size(); scan.visible.push_back(sector); }
					else {
						Sector &previous = scan.visible[found->second];
						previous.produce |= on_screen; previous.wanted = MAX(previous.wanted, wanted); previous.distance = MIN(previous.distance, patch.distance);
						previous.heights.x = MIN(previous.heights.x, sector.heights.x); previous.heights.y = MAX(previous.heights.y, sector.heights.y);
					}
				}
			}
		}
	}
	return scan;
}

// Turns the scan into the working set: the 64 m cells sorted near to far, the
// hierarchy of coarse nodes above them, and the address budget they have to fit.
Terrain3DAVTHierarchy Terrain3D::_avt_build_hierarchy(const Terrain3DAVTSectorScan &p_scan) {
	Terrain3DAVTHierarchy hierarchy;
	hierarchy.directory_dirty = _vt.avt_directory_bytes.is_empty();
	// The world hierarchy supplies the footprint-selected coarse mips. Its
	// addresses remain stable during local refinement; residency is determined
	// below by the actual visible mip range, not by reserving every ancestor.
	const int pool_size = _vt.surface_vt->get_page_count();
	const bool offline_bake = !_vt.vt_svt_bake_queue.is_empty() || !_vt.vt_svt_bake_waiting.is_empty();
	const int reserved = offline_bake ? pool_size / 2 : (_vt.surface_svt_enabled ? MIN(pool_size / 2, _vt.vt_svt_visible_pages) : 0);
	const int budget = MAX(4, pool_size - reserved);
	const int root_budget = MAX(4, budget / 4);
	int root_level = 1;
	while (root_level < 24) {
		int scale = 1 << root_level;
		int64_t count = int64_t(floor_div(p_scan.world_x1, scale) - floor_div(p_scan.world_x0, scale) + 1) *
				(floor_div(p_scan.world_y1, scale) - floor_div(p_scan.world_y0, scale) + 1);
		if (count <= root_budget) { break; }
		++root_level;
	}
	// More physical capacity must not remove the old coarsest virtual level.
	// That would change the shader's terminal mip and orphan ready root pages.
	root_level = MAX(root_level, _vt.avt_root_level);
	std::map<SectorKey, Sector> roots;
	for (const Sector &item : p_scan.visible) {
		hierarchy.leaves.push_back(item);
		int x = floor_div(item.location.x, 1 << root_level);
		int y = floor_div(item.location.y, 1 << root_level);
		// Reserved CPU owner namespace; the GPU hashes the unmodified world key.
		Vector2i owner(x, y + 0x40000000 + root_level * 0x100000);
		roots[{ x, y }] = { Vector2i(x, y), owner, root_level, 1, 1, true, 0.f };
	}
	std::vector<Sector> &sectors = hierarchy.leaves;
	std::sort(sectors.begin(), sectors.end(), [](const Sector &a, const Sector &b) {
		if (a.distance != b.distance) { return a.distance < b.distance; }
		return a.location.y == b.location.y ? a.location.x < b.location.x : a.location.y < b.location.y;
	});
	// Address-space budgeting is independent of physical residency. Leave atlas
	// headroom for coarse roots and for buddy allocator fragmentation.
	const int64_t virtual_budget = int64_t(2048) * 2048 * 3 / 4 - roots.size() - sectors.size();
	int virtual_bias = 0;
	for (;;) {
		int64_t area = 0;
		for (const Sector &sector : sectors) { if (!sector.produce) { continue; } int size = MAX(1, sector.wanted >> virtual_bias); area += int64_t(size) * size; }
		if (area <= virtual_budget || virtual_bias >= 11) { break; }
		++virtual_bias;
	}
	for (Sector &sector : sectors) { sector.size = MAX(1, sector.wanted >> virtual_bias); }
	_vt.avt_sector_stats["virtual_budget_bias"] = virtual_bias;
	// Keep a world hierarchy between the coarse roots and the 64 m sectors.
	// This prevents a sector without fine pages from jumping straight to a huge root.
	using NodeKey = std::tuple<int, int, int>;
	std::map<NodeKey, Sector> coarse;
	auto add_parent = [&](const Sector &sector) {
		const int level = sector.level + 1;
		Vector2i key(floor_div(sector.location.x, 2), floor_div(sector.location.y, 2));
		NodeKey node(level, key.x, key.y);
		auto found = coarse.find(node);
		if (found == coarse.end()) {
			coarse[node] = { key, Vector2i(key.x, key.y + 0x40000000 + level * 0x100000), level, 1, 1, sector.produce, sector.distance, sector.heights };
		} else {
			found->second.produce |= sector.produce;
			found->second.heights.x = MIN(found->second.heights.x, sector.heights.x);
			found->second.heights.y = MAX(found->second.heights.y, sector.heights.y);
		}
	};
	for (const Sector &sector : sectors) { add_parent(sector); }
	// Build each parent once from the previous level, rather than revisiting
	// the entire ancestor chain for every leaf in a large visible world.
	for (int level = 1; level < root_level; ++level) {
		auto item = coarse.lower_bound({ level, INT32_MIN, INT32_MIN });
		while (item != coarse.end() && std::get<0>(item->first) == level) { add_parent((item++)->second); }
	}
	for (auto item = coarse.rbegin(); item != coarse.rend(); ++item) { hierarchy.working.push_back(item->second); }
	hierarchy.working.insert(hierarchy.working.end(), sectors.begin(), sectors.end());
	std::stable_sort(hierarchy.working.begin(), hierarchy.working.end(), [](const Sector &a, const Sector &b) { return a.produce > b.produce; });
	hierarchy.owners.reserve(hierarchy.working.size());
	for (const Sector &sector : hierarchy.working) { if (sector.produce) { hierarchy.owners.insert(avt_owner_key(sector.owner)); } }
	hierarchy.root_level = root_level;
	hierarchy.coarse_roots = int(roots.size());
	hierarchy.budget = budget;
	return hierarchy;
}

// Keeps the virtual block directory in step with the working set: releases the
// addresses of views the camera has left, allocates or resizes the rest, and
// reclaims address space when a visible block cannot be allocated otherwise.
void Terrain3D::_avt_sync_address_directory(Terrain3DAVTHierarchy &r_hierarchy, const Vector2 &p_focus, const float p_reach) {
	auto in_reach = [&](const Rect2 &rect) {
		const Vector2 nearest(CLAMP(p_focus.x, rect.position.x, rect.get_end().x), CLAMP(p_focus.y, rect.position.y, rect.get_end().y));
		return nearest.distance_squared_to(p_focus) <= (p_reach + SECTOR_WORLD) * (p_reach + SECTOR_WORLD);
	};
	bool &directory_dirty = r_hierarchy.directory_dirty;
	auto release_address = [&](const Terrain3DAVTCachedAddress &address) {
		_vt.surface_vt->unregister_sector(address.owner);
		_vt.vt_registered_sectors.erase(address.owner);
		_vt.avt_allocated_sizes.erase(avt_owner_key(address.owner));
		directory_dirty = true;
	};
	// Looking away does not invalidate material content. Keep addresses and cached
	// pages near the camera; physical pages remain evictable under actual demand.
	for (auto item = _vt.avt_cached_addresses.begin(); item != _vt.avt_cached_addresses.end();) {
		const Terrain3DAVTCachedAddress &address = item->second;
		const float span = SECTOR_WORLD * float(1 << address.level);
		Rect2 rect(Vector2(address.location) * span, Vector2(span, span));
		if (!r_hierarchy.owners.count(item->first) && _vt.surface_svt_enabled && !in_reach(rect)) {
			release_address(address);
			item = _vt.avt_cached_addresses.erase(item);
		} else { ++item; }
	}
	auto reclaim_addresses = [&]() {
		// Visible demand wins. Old views never force a lower virtual resolution.
		for (auto item = _vt.avt_cached_addresses.begin(); item != _vt.avt_cached_addresses.end();) {
			if (!r_hierarchy.owners.count(item->first)) { release_address(item->second); item = _vt.avt_cached_addresses.erase(item); }
			else { ++item; }
		}
		for (const Sector &sector : r_hierarchy.working) {
			auto allocated = _vt.avt_allocated_sizes.find(avt_owner_key(sector.owner));
			if (allocated != _vt.avt_allocated_sizes.end() && allocated->second > sector.size && _vt.surface_vt->resize_sector(sector.owner, sector.size)) {
				allocated->second = sector.size; directory_dirty = true;
			}
		}
	};
	for (const Sector &sector : r_hierarchy.working) {
		auto allocated = _vt.avt_allocated_sizes.find(avt_owner_key(sector.owner));
		int previous_size = allocated != _vt.avt_allocated_sizes.end() ? allocated->second : 0;
		if (previous_size == 0) {
			bool registered = _vt.surface_vt->register_sector(sector.owner, sector.size);
			if (!registered && sector.produce) { reclaim_addresses(); registered = _vt.surface_vt->register_sector(sector.owner, sector.size); }
			if (registered) {
				_vt.vt_registered_sectors[sector.owner] = true; _vt.avt_allocated_sizes[avt_owner_key(sector.owner)] = sector.size; directory_dirty = true;
			}
		} else if (previous_size < sector.size) {
			bool resized = _vt.surface_vt->resize_sector(sector.owner, sector.size);
			if (!resized && sector.produce) { reclaim_addresses(); resized = _vt.surface_vt->resize_sector(sector.owner, sector.size); }
			directory_dirty |= resized;
			if (resized) { _vt.avt_allocated_sizes[avt_owner_key(sector.owner)] = sector.size; }
		}
		if (_vt.surface_vt->has_sector(sector.owner)) { _vt.avt_cached_addresses[avt_owner_key(sector.owner)] = { sector.location, sector.owner, sector.level }; }
	}
	_vt.avt_registered_owners.clear();
	for (const auto &entry : _vt.avt_cached_addresses) { _vt.avt_registered_owners.push_back(entry.second.owner); }
	_vt.avt_sector_stats["retained_sector_addresses"] = int(_vt.avt_cached_addresses.size());
}

// Submits this key's page selection to the plan pipeline. The selection is the
// expensive half (it walks the visible mip interval per cell), so it runs on the
// plan worker and arrives through _avt_install_or_reuse_plan on a later tick.
void Terrain3D::_avt_submit_plan(Terrain3DAVTHierarchy &r_hierarchy, const PackedByteArray &p_plan_key,
		const TerrainVT::VisibleView &p_view,
		const Vector3 &p_camera_position, const bool p_bounds_ready, const Vector2 &p_focus, const float p_reach) {
	// Refine only visible page footprints. The refinement walk never enumerates a
	// virtual image's full mip pyramid (256 squared entries need zero resident
	// pages until requested). Budget exhaustion must remain visible in diagnostics.
	for (Sector &sector : r_hierarchy.working) { sector.size = _vt.surface_vt->has_sector(sector.owner) ? _vt.surface_vt->get_sector_block_size(sector.owner) : 0; }
	const float logical_ratio = _avt_logical_ratio();
	auto job = std::make_shared<Terrain3DAVTRefinement>();
	// The plan carries the key it was planned for, which is the key this tick
	// publishes at its end. The install step compares it against the member, so it
	// must be the new key and not the one being replaced.
	job->key = p_plan_key;
	job->submitted_us = Time::get_singleton()->get_ticks_usec();
	_vt.avt_refinement = job;
	// Keep producing the last completed view while its successor is being planned.
	// A virtual block can grow without changing a physical page's world footprint.
	auto remap_plan = [&](std::vector<Terrain3DAVTPageRequest> &plan) {
		for (auto it = plan.begin(); it != plan.end();) {
			auto address = _vt.avt_cached_addresses.find(avt_owner_key(it->owner));
			if (address == _vt.avt_cached_addresses.end() || !_vt.surface_vt->has_sector(it->owner)) { it = plan.erase(it); continue; }
			const auto &node = address->second;
			const int size = _vt.surface_vt->get_sector_block_size(it->owner);
			const float world = SECTOR_WORLD * float(1 << node.level);
			const float logical = node.level ? 1.f : size * logical_ratio;
			const int mip = int(std::round(std::log2(it->rect.size.x * logical / world)));
			if (mip < 0 || mip > TerrainVT::log2_power_of_two(size)) { it = plan.erase(it); continue; }
			it->mip = mip;
			++it;
		}
	};
	// Camera motion changes demand, not existing virtual addresses. Avoid
	// re-deriving every page mip when the address directory and scale agree.
	if (r_hierarchy.directory_dirty || logical_ratio != _vt.avt_plan_logical_ratio) {
		remap_plan(_vt.avt_page_plan);
		remap_plan(_vt.avt_prefetch_plan);
		_vt.avt_plan_logical_ratio = logical_ratio;
		// The addresses the source queue is retained against just changed.
		_vt.avt_retain_applied = false;
	}
	_vt.avt_prefetch_cursor = 0;
	_vt.avt_prefetch_cycle_pending = false;
	_vt.avt_idle_revision = 0;
	if (!_vt.vt_page_pipeline) { _vt.vt_page_pipeline = std::make_unique<Terrain3DPagePipeline>(_vt.vt_page_workers); }
	AVTPlanInput input;
	input.working = r_hierarchy.working;
	input.source = _vt.vt_source_snapshot;
	input.view = p_view;
	input.bounds_ready = p_bounds_ready;
	input.camera_position = p_camera_position;
	input.focus = p_focus;
	input.reach = p_reach;
	input.exact_radius = float(_cdlod_enabled && _tessellation_level == 0 ? _cdlod_patch_size * _vertex_spacing * _cdlod_lod_scale * 0.7 / (1 << _tessellation_level) : 0);
	input.logical_ratio = logical_ratio;
	input.texels_per_pixel = _vt.surface_vt_texels_per_pixel;
	input.budget = r_hierarchy.budget;
	input.root_level = r_hierarchy.root_level;
	input.page_size = _vt.vt_page_size;
	_vt.vt_page_pipeline->submit_task([job, input]() mutable { avt_plan_pages(*job, input); });
}

// Publishes the sector directory the shader reads. A sparse hash directory
// decouples GPU sector lookup from region layer IDs: two RGBA32F texels hold an
// exact world key/level and block origin/size. Returns whether it changed.
bool Terrain3D::_avt_publish_directory(const Terrain3DAVTHierarchy &p_hierarchy, const bool p_directory_dirty) {
	bool directory_changed = false;
	if (!p_directory_dirty && p_hierarchy.root_level == _vt.avt_root_level) { return false; }
	int entries = 1;
	while (entries < int(_vt.avt_cached_addresses.size()) * 2) { entries <<= 1; }
	int width = MIN(1024, entries * 2);
	int height = MAX(1, entries * 2 / width);
	PackedByteArray bytes;
	bytes.resize(int64_t(width) * height * 4 * sizeof(float));
	bytes.fill(0);
	uint8_t *output = bytes.ptrw();
	std::vector<bool> occupied(entries, false);
	int detailed = 0, max_size = 0;
	// The block size the shader reads is this ratio, and the planner only records it in the
	// plan it submits after publishing, so derive the live value instead of reading
	// `_vt.avt_plan_logical_ratio`: on the first publish of a configuration that member is
	// still its default of zero, and a zero block size collapses every fragment of the
	// sector onto the block's first page.
	const float logical_ratio = _avt_logical_ratio();
	for (const auto &cached : _vt.avt_cached_addresses) {
		const Terrain3DAVTCachedAddress &sector = cached.second;
		if (!_vt.surface_vt->has_sector(sector.owner)) { continue; }
		uint32_t index = sector_hash(sector.location.x, sector.location.y, sector.level) & (entries - 1);
		while (occupied[index]) { index = (index + 1) & (entries - 1); }
		occupied[index] = true;
		int size = _vt.surface_vt->get_sector_block_size(sector.owner);
		float entry[8] = { float(sector.location.x), float(sector.location.y), float(sector.level), 1.f,
				float(_vt.surface_vt->get_sector_block_origin_x(sector.owner)), float(_vt.surface_vt->get_sector_block_origin_y(sector.owner)), float(size), sector.level ? 1.f : float(size) * logical_ratio };
		std::memcpy(output + int64_t(index) * sizeof(entry), entry, sizeof(entry));
		if (sector.level == 0 && p_hierarchy.owners.count(cached.first)) { ++detailed; max_size = MAX(max_size, size); }
	}
	directory_changed = bytes != _vt.avt_directory_bytes || p_hierarchy.root_level != _vt.avt_root_level;
	bool uniform_changed = false;
	if (directory_changed) {
		const bool recreated = !(_vt.avt_sector_directory.is_valid() &&
				_vt.avt_sector_directory->get_width() == width && _vt.avt_sector_directory->get_height() == height);
		Ref<Image> image = Image::create_from_data(width, height, false, Image::FORMAT_RGBAF, bytes);
		if (_vt.avt_sector_directory.is_valid() && _vt.avt_sector_directory->get_width() == width && _vt.avt_sector_directory->get_height() == height) { _vt.avt_sector_directory->update(image); }
		else { _vt.avt_sector_directory = ImageTexture::create_from_image(image); }
		// Only a uniform the shader reads needs a material republish: the texture update
		// in place is already visible to it, and the republish is not free.
		uniform_changed = recreated || (entries - 1) != _vt.avt_directory_mask || p_hierarchy.root_level != _vt.avt_root_level;
		_vt.avt_directory_bytes = bytes;
		_vt.avt_directory_mask = entries - 1;
		_vt.avt_root_level = p_hierarchy.root_level;
	}
	_vt.avt_sector_stats["independent_sectors"] = detailed;
	_vt.avt_sector_stats["max_allocated_resolution"] = max_size * _vt.vt_page_size;
	return uniform_changed;
}

// The near field's one production pass per tick: verify the standing plan, classify it into
// resident and missing pages, retain the source queue, prime the workers, publish what fits
// the budget, and commit. The tick calls it exactly once, so every stage above is paid once
// per tick rather than once per caller.
int Terrain3D::_produce_sector_avt_pages(int p_max_pages) {
	if (p_max_pages == 0) { return 0; }
	p_max_pages = p_max_pages < 0 ? 16 : MIN(p_max_pages, 16);
	const auto pool = _vt.surface_vt->get_page_pool();
	// A repeated plan with nothing left to upload still has to re-mark its resident
	// pages as demanded, or the pool evicts them while the camera is stationary.
	//
	// The cached state is only idle while every page it holds still has content. A page
	// whose production was lost after this state was reached - an encode that failed, a job
	// dropped by the bundle rebuild that changed the producer's generation - keeps its
	// indirection entry and its demand record, so the shader samples an empty layer and no
	// other part of the pipeline would ever look at it again: the plan is reused and the
	// pool's residency did not move, which is exactly the condition this shortcut tests.
	// Readiness is therefore verified here and not assumed. The cost is one lookup per
	// resident slot, on the loop that already touches every one of them.
	const Terrain3DSurfaceBaker *idle_producer = Object::cast_to<Terrain3DSurfaceBaker>(_vt.vt_baker.ptr());
	int idle_lost = 0;
	if (idle_producer) {
		// One lock for the whole resident set: the per-slot query is the same read, and this
		// loop is the one a settled view runs on every tick.
		idle_lost = idle_producer->count_unready_pages(_vt.avt_resident_slots);
	}
	if (_vt.avt_plan_reused && _vt.avt_idle_revision == pool->residency_revision &&
			idle_lost == 0) {
		for (int slot : _vt.avt_resident_slots) { pool->mark_demanded(slot); }
		// Only the first tick of an idle run publishes: every value below is a constant of
		// the settled state, and rewriting the same numbers into a String-keyed dictionary
		// every frame is the largest cost a settled view has left.
		if (!_vt.avt_idle_stats_current) {
			_vt.avt_idle_stats_current = true;
			_vt.avt_sector_stats["produced"] = 0;
			_vt.avt_sector_stats["prefetched"] = 0;
			// An idle pass is only reached once the previous one produced nothing, the residency
			// did not change, and every page above was verified to still have its content.
			_vt.avt_sector_stats["visible_plan_pages"] = _vt.avt_sampled_pages;
			_vt.avt_sector_stats["visible_missing_pages"] = 0;
			_vt.avt_sector_stats["visible_pending_pages"] = 0;
			_vt.avt_sector_stats["visible_late_pages"] = 0;
			_vt.avt_sector_stats["idle_ready_lost"] = 0;
		}
		_vt.avt_late_pages = 0;
		_vt.avt_missing_pages = 0;
		_vt.avt_pending_pages = 0;
		_vt.avt_demand_age.clear();
		return 0;
	}
	// A page the cached state would have called resident is not ready, so this pass runs the
	// real classification and reports what it finds instead of claiming a complete plan. The
	// reading is what tells a lost page under a still camera from a settled view.
	_vt.avt_idle_stats_current = false;
	_vt.avt_sector_stats["idle_ready_lost"] = idle_lost;
	_vt.avt_idle_revision = 0;
	_vt.avt_resident_slots.clear();
	_vt.surface_vt->set_allocation_budget(p_max_pages > 0 ? p_max_pages : -1);
	if (!_vt.vt_page_pipeline) { _vt.vt_page_pipeline = std::make_unique<Terrain3DPagePipeline>(_vt.vt_page_workers); }
	if (!_vt.vt_source_snapshot) { _vt.vt_source_snapshot = Terrain3DPagePipeline::snapshot(_data, _region_size, _vertex_spacing, _surface_density); }

	Terrain3DAVTProducePass pass;
	// One place to record a stage's cost, so the pass reads as the stages it runs instead of as a
	// sequence of timestamp reassignments. Each stage is named by the key its cost lands under.
	uint64_t stage_started = Time::get_singleton()->get_ticks_usec();
	auto mark = [this, &stage_started](const char *p_key) {
		const uint64_t now = Time::get_singleton()->get_ticks_usec();
		_vt.avt_sector_stats[p_key] = double(now - stage_started) / 1000.0;
		stage_started = now;
	};
	_avt_classify_plan(pass);
	mark("classify_ms");
	_avt_retain_visible(pass);
	mark("retain_ms");
	_avt_prime_sources(pass, SOURCE_QUEUE_REFILL_ABOVE);
	mark("prime_ms");
	_avt_produce_visible(pass, p_max_pages);
	mark("upload_ms");
	// Refill after consuming ready results even when the render budget is spent, so the workers
	// are not left idle between ticks - but only when the queue is actually running low. A queue
	// that is still half full is work the workers have not reached yet, and re-scanning and
	// re-inserting into it buys nothing.
	_avt_prime_sources(pass, SOURCE_QUEUE_REFILL_ABOVE, true);
	mark("refill_ms");
	_avt_produce_prefetch(pass, p_max_pages);
	_avt_finish_produce(pass);
	mark("finish_ms");
	return pass.produced;
}

// Sorts the published plan into pages that already have a physical slot - which are
// pinned and marked demanded - and pages that still have to be produced.
void Terrain3D::_avt_classify_plan(Terrain3DAVTProducePass &r_pass) {
	const auto pool = _vt.surface_vt->get_page_pool();
	r_pass.protected_slots.reserve(_vt.avt_page_plan.size() + 16);
	r_pass.missing.reserve(_vt.avt_page_plan.size());
	Terrain3DSurfaceBaker *producer = Object::cast_to<Terrain3DSurfaceBaker>(_vt.vt_baker.ptr());
	const int sampled = MIN(_vt.avt_sampled_pages, int(_vt.avt_page_plan.size()));
	const uint64_t now_us = Time::get_singleton()->get_ticks_usec();
	const uint64_t lead_us = uint64_t(double(MAX(0.f, float(_vt.vt_motion_lead_ms))) * 1000.0);
	int index = 0;
	for (const Terrain3DAVTPageRequest &page : _vt.avt_page_plan) {
		int slot = _vt.surface_vt->lookup_page_exact(page.owner, page.mip, page.x, page.y);
		if (slot >= 0 && !_vt.surface_vt->is_page_protected(slot)) { _vt.surface_vt->protect_page(slot, true); r_pass.protected_slots.push_back(slot); }
		const bool sampled_ready = slot >= 0 && (!producer || producer->is_page_ready(slot));
		// A page whose content landed since the last pass is the one a fade starts on.
		if (slot >= 0) { _vt_note_page_readiness(slot, sampled_ready); }
		const bool stale = slot >= 0 && !sampled_ready && _vt_page_production_stale(slot);
		if (index++ < sampled) {
			// A page the image samples without content is shaded as the missing-page
			// material; one whose production is still inside its retry window is a
			// pending miss that the next frames resolve.
			r_pass.sampled_plan++;
			if (slot < 0) { r_pass.sampled_missing++; } else if (!sampled_ready) { stale ? r_pass.sampled_missing++ : r_pass.sampled_pending++; }
			// Age the miss from the frame the page was first demanded without content.
			// A page younger than one lead is not late: the plan is ahead of the camera,
			// so the frames it holds in flight are its production window, not a stall.
			const uint64_t age_key = avt_page_age_key(page);
			if (sampled_ready) {
				_vt.avt_demand_age.erase(age_key);
			} else {
				auto found = _vt.avt_demand_age.find(age_key);
				const uint64_t since = found == _vt.avt_demand_age.end() ? now_us : found->second;
				if (found == _vt.avt_demand_age.end()) { _vt.avt_demand_age.emplace(age_key, since); }
				const uint64_t age = now_us - since;
				r_pass.late_worst_us = MAX(r_pass.late_worst_us, int(MIN(age, uint64_t(INT32_MAX))));
				if (age >= lead_us) { r_pass.sampled_late++; }
			}
		}
		if (slot < 0 || stale) { r_pass.missing.push_back(&page); }
		if (slot >= 0) { pool->mark_demanded(slot); _vt.avt_resident_slots.push_back(slot); }
	}
	// A page that left the plan is never checked again, so the map is bounded by a clear
	// whenever the view settles, and by a hard cap if a pathological plan keeps churning.
	if (r_pass.sampled_missing == 0 && r_pass.sampled_pending == 0) { _vt.avt_demand_age.clear(); }
	else if (_vt.avt_demand_age.size() > 8192) { _vt.avt_demand_age.clear(); }
	// Coarse pages first, which is what makes a moving view refine instead of jump. A page's
	// level is what the fragment falls back to while its finer replacement is produced, so
	// producing the coarsest missing page of a region before the pages that refine it turns a
	// view's appearance into a progression: the budget buys the levels in order, and the last
	// thing to arrive is the detail, not a sharp patch beside a blurred one. Within a level the
	// plan's own order (nearer first) is kept, and a pass that produces nothing new is not
	// affected at all.
	std::stable_sort(r_pass.missing.begin(), r_pass.missing.end(),
			[](const Terrain3DAVTPageRequest *p_left, const Terrain3DAVTPageRequest *p_right) {
				return p_left->mip > p_right->mip;
			});
}

// Queued idle work must not occupy every source-worker slot while visible requests
// wait for a free entry. Retain only visible jobs until they settle.
void Terrain3D::_avt_retain_visible(const Terrain3DAVTProducePass &p_pass) {
	// What the source queue should keep is the plan, plus the prefetch plan once nothing
	// visible is missing. That set only changes when a plan is installed or the prefetch
	// switch flips, and a retention is only ever undone by a later one, so repeating it is
	// 250 map lookups that reach the state the last retention already reached.
	const bool with_prefetch = p_pass.missing.empty();
	if (_vt.avt_retain_applied && _vt.avt_retain_with_prefetch == with_prefetch) { return; }
	std::vector<Terrain3DPagePipeline::Request> wanted;
	wanted.reserve(_vt.avt_page_plan.size() + (with_prefetch ? _vt.avt_prefetch_plan.size() : 0));
	for (const auto &page : _vt.avt_page_plan) { wanted.push_back(_avt_page_request(page)); }
	if (with_prefetch) {
		for (const auto &page : _vt.avt_prefetch_plan) { wanted.push_back(_avt_page_request(page)); }
	}
	_vt.vt_page_pipeline->retain(wanted);
	_vt.avt_retain_applied = true;
	_vt.avt_retain_with_prefetch = with_prefetch;
}

Terrain3DPagePipeline::Request Terrain3D::_avt_page_request(const Terrain3DAVTPageRequest &p_page) const {
	return Terrain3DPagePipeline::Request{{ p_page.owner.x, p_page.owner.y, p_page.mip, p_page.x, p_page.y }, p_page.rect, _vt.vt_page_size, _vt.vt_page_border };
}

// Gives the source workers the first pages of the missing list that the pass has not attempted, so
// results are ready when the next stage polls them. `p_refill_above` is the point at which the
// queue is already deep enough that there is nothing to do: the second call of a tick passes it, so
// a queue the workers are still working through is not re-scanned and re-inserted into - which
// measured as ~0.15 ms of a peak tick, almost all of it waiting for the queue's mutex.
void Terrain3D::_avt_prime_sources(const Terrain3DAVTProducePass &p_pass, const int p_refill_above, const bool p_refill) {
	if (p_refill_above > 0 && _vt.vt_page_pipeline->claimable_count() >= p_refill_above) { return; }
	std::vector<Terrain3DPagePipeline::Request> requests;
	requests.reserve(32);
	for (size_t i = p_pass.missing_next; i < p_pass.missing.size(); ++i) {
		requests.push_back(_avt_page_request(*p_pass.missing[i]));
		if (requests.size() == 32) { break; }
	}
	if (requests.empty()) { return; }
	_vt.vt_page_pipeline->prime(requests, _vt.vt_source_snapshot);
	int64_t insert_us = 0;
	int64_t wake_us = 0;
	int inserted = 0;
	int wakes = 0;
	_vt.vt_page_pipeline->get_prime_stats(insert_us, wake_us);
	_vt.vt_page_pipeline->get_prime_counts(inserted, wakes);
	_vt.avt_sector_stats[p_refill ? "refill_insert_ms" : "prime_insert_ms"] = double(insert_us) / 1000.0;
	_vt.avt_sector_stats[p_refill ? "refill_wake_ms" : "prime_wake_ms"] = double(wake_us) / 1000.0;
	_vt.avt_sector_stats[p_refill ? "refill_inserted" : "prime_inserted"] = inserted;
	_vt.avt_sector_stats[p_refill ? "refill_wakes" : "prime_wakes"] = wakes;
}

// Publishes one prepared page: allocates the slot, writes the payload, queues the
// material copy and pins the slot for the rest of the pass. Returns whether a page
// was produced.
bool Terrain3D::_avt_produce_page(Terrain3DAVTProducePass &r_pass, const Terrain3DAVTPageRequest &p_page, bool p_prefetch) {
	int slot = _vt.surface_vt->lookup_page_exact(p_page.owner, p_page.mip, p_page.x, p_page.y);
	Terrain3DSurfaceBaker *producer = Object::cast_to<Terrain3DSurfaceBaker>(_vt.vt_baker.ptr());
	if (slot >= 0 && (!producer || producer->is_page_ready(slot))) { return false; }
	// A recent exact entry is production already in flight. Re-queueing it would advance the
	// slot sequence every frame and make every async encode completion stale before arrival.
	// Its prepared source is not going to be consumed, though - the producer is filling the
	// slot from the GPU - so the entry is dropped here. Leaving it in the queue is what
	// starved the pages behind it: 32 slots filled with results nobody would ever poll.
	if (slot >= 0 && !_vt_page_production_stale(slot)) {
		_vt.vt_page_pipeline->discard(_avt_page_request(p_page).key);
		return false;
	}
	if (p_prefetch) { r_pass.prefetch_pending = true; }
	Terrain3DPagePipeline::Result prepared;
	if (!_vt.vt_page_pipeline->poll(_avt_page_request(p_page), _vt.vt_source_snapshot, prepared)) {
		r_pass.source_wait++;
		return false;
	}
	const uint64_t allocation_start = Time::get_singleton()->get_ticks_usec();
	if (slot < 0) {
		bool miss = false;
		slot = _vt.surface_vt->request_page_internal(p_page.owner, p_page.mip, p_page.x, p_page.y, &miss);
		if (slot < 0 || !miss) {
			r_pass.slot_wait++;
			return false;
		}
	}
	const uint64_t request_done = Time::get_singleton()->get_ticks_usec();
	_invalidate_vt_slot(slot);
	const uint64_t payload_start = Time::get_singleton()->get_ticks_usec();
	r_pass.allocation_us += payload_start - allocation_start;
	r_pass.request_us += request_done - allocation_start;
	r_pass.invalidate_us += payload_start - request_done;
	Ref<Image> payload = prepared.payload;
	if (payload.is_null() || !_vt.surface_vt->write_page(slot, payload)) {
		_vt.surface_vt->release_page(p_page.owner, p_page.mip, p_page.x, p_page.y);
		return false;
	}
	const uint64_t queue_start = Time::get_singleton()->get_ticks_usec();
	r_pass.payload_us += queue_start - payload_start;
	_queue_vt_material_page(slot, payload, p_page.rect, false, p_page.mip, Vector2i(p_page.x, p_page.y), &prepared);
	r_pass.queue_us += Time::get_singleton()->get_ticks_usec() - queue_start;
	_vt.surface_vt->protect_page(slot, true);
	r_pass.protected_slots.push_back(slot);
	return true;
}

void Terrain3D::_avt_produce_visible(Terrain3DAVTProducePass &r_pass, int p_max_pages) {
	// The tick deadline bounds what this pass adds, but a pass that produces nothing because
	// the planning already spent the budget stalls the pipeline for the whole session: pages
	// whose demand was recorded are never produced, and a settled view keeps showing the
	// missing-page material. One page of progress per pass is the floor that keeps every view
	// converging while a strict budget still decides the rate above it - and it stays below the
	// residency a pooled view is allowed to hold, so sharing pressure still evicts down to the
	// last page.
	const int floor = MIN(1, p_max_pages);
	// The walk resumes where the last one stopped rather than restarting: a page already
	// attempted is already in the source queue or already resident, so re-attempting it only
	// re-polls the answer it gave, and the pages behind it are the ones still owed.
	for (; r_pass.missing_next < r_pass.missing.size(); ++r_pass.missing_next) {
		// Throughput is bounded by the real page budget, not a CPU timer that can
		// collapse this pipeline to one page per frame while the camera is moving.
		if (r_pass.produced >= p_max_pages) { break; }
		// ... but an automatic tick also stops on its own deadline once it has made progress:
		// the remaining pages are produced by the ticks that follow, and the view they are
		// missing from is shaded from the source in the meantime.
		if (r_pass.produced >= floor && _vt_tick_expired()) { break; }
		r_pass.produced += _avt_produce_page(r_pass, *r_pass.missing[r_pass.missing_next]) ? 1 : 0;
	}
}

// Fills the pool with off-screen pages, but only once the visible plan is complete,
// and never twice over the same page in one cycle.
void Terrain3D::_avt_produce_prefetch(Terrain3DAVTProducePass &r_pass, int p_max_pages) {
	if (!r_pass.missing.empty() || _vt.avt_prefetch_plan.empty()) { return; }
	const auto pool = _vt.surface_vt->get_page_pool();
	bool complete = pool->free_slots.empty();
	for (size_t checked = 0; checked < _vt.avt_prefetch_plan.size() && !complete; ++checked) {
		if (r_pass.prefetched >= p_max_pages || _vt_tick_expired()) { break; }
		r_pass.prefetch_pending = false;
		r_pass.prefetched += _avt_produce_page(r_pass, _vt.avt_prefetch_plan[_vt.avt_prefetch_cursor], true) ? 1 : 0;
		_vt.avt_prefetch_cycle_pending |= r_pass.prefetch_pending;
		if (++_vt.avt_prefetch_cursor == _vt.avt_prefetch_plan.size()) {
			_vt.avt_prefetch_cursor = 0;
			complete = !_vt.avt_prefetch_cycle_pending;
			_vt.avt_prefetch_cycle_pending = false;
			break;
		}
		complete = pool->free_slots.empty();
	}
	r_pass.prefetch_pending = !complete;
}

// Releases the pins and publishes the pass to the render thread in one commit, then
// reports what it cost. A pass that produced nothing and owes no prefetch is idle,
// so the next plan with the same residency can be reused.
void Terrain3D::_avt_finish_produce(Terrain3DAVTProducePass &r_pass) {
	const auto pool = _vt.surface_vt->get_page_pool();
	const uint64_t finish_start = Time::get_singleton()->get_ticks_usec();
	_vt.avt_sector_stats["prefetched"] = r_pass.prefetched;
	// Visible-miss diagnostics: pages the current image samples, of which how many are
	// waiting on production and how many have already been retried past their window.
	_vt.avt_sector_stats["visible_plan_pages"] = r_pass.sampled_plan;
	_vt.avt_sector_stats["visible_missing_pages"] = r_pass.sampled_missing;
	_vt.avt_sector_stats["visible_pending_pages"] = r_pass.sampled_pending;
	_vt.avt_sector_stats["visible_late_pages"] = r_pass.sampled_late;
	_vt.avt_sector_stats["visible_late_worst_ms"] = double(r_pass.late_worst_us) / 1000.0;
	_vt.avt_sector_stats["demand_age_entries"] = int(_vt.avt_demand_age.size());
	_vt.avt_late_pages = r_pass.sampled_late;
	_vt.avt_late_worst_us = r_pass.late_worst_us;
	_vt.avt_missing_pages = r_pass.sampled_missing;
	_vt.avt_pending_pages = r_pass.sampled_pending;
	_vt.avt_sector_stats["sampled_pages"] = _vt.avt_sampled_pages;
	_vt.avt_sector_stats["produce_source_wait"] = r_pass.source_wait;
	_vt.avt_sector_stats["produce_slot_wait"] = r_pass.slot_wait;
	// This function is the largest stage of a peak pass, and it is all bookkeeping. The three
	// timings below are what tells which half of it - the String-keyed writes of the statistics,
	// the producer queries under their lock, or releasing the pass's pins.
	auto since = [](const uint64_t p_from) { return double(Time::get_singleton()->get_ticks_usec() - p_from) / 1000.0; };
	_vt.avt_sector_stats["stats_ms"] = since(finish_start);
	const uint64_t worker_start = Time::get_singleton()->get_ticks_usec();
	{
		// Worker throughput: pages the source threads assembled and the worker time they
		// spent, which is what separates "the workers cannot keep up" from "the pool will
		// not hand out a slot for the pages they did assemble".
		int pages = 0, queued = 0;
		int64_t usec = 0;
		if (_vt.vt_page_pipeline) {
			_vt.vt_page_pipeline->get_production_stats(pages, usec, queued);
			int hits = 0, mismatch = 0, evicted = 0, discarded = 0;
			_vt.vt_page_pipeline->get_outcome_stats(hits, mismatch, evicted, discarded);
			_vt.avt_sector_stats["worker_hits"] = hits;
			_vt.avt_sector_stats["worker_rect_mismatch"] = mismatch;
			_vt.avt_sector_stats["worker_evicted"] = evicted;
			_vt.avt_sector_stats["worker_discarded"] = discarded;
			_vt.vt_page_pipeline->reset_production_stats();
		}
		_vt.avt_sector_stats["worker_pages"] = pages;
		_vt.avt_sector_stats["worker_ms"] = double(usec) / 1000.0;
		_vt.avt_sector_stats["worker_queue"] = queued;
	}
	_vt.avt_sector_stats["worker_stats_ms"] = since(worker_start);
	r_pass.produced += r_pass.prefetched;
	const uint64_t protect_start = Time::get_singleton()->get_ticks_usec();
	for (int slot : r_pass.protected_slots) { _vt.surface_vt->protect_page(slot, false); }
	_vt.avt_sector_stats["protect_ms"] = since(protect_start);
	_vt.avt_sector_stats["pins_released"] = int(r_pass.protected_slots.size());
	const uint64_t commit_start = Time::get_singleton()->get_ticks_usec();
	_vt.surface_vt->commit();
	_vt.avt_sector_stats["commit_ms"] = since(commit_start);
	_vt.avt_sector_stats["allocation_ms"] = double(r_pass.allocation_us) / 1000.;
	_vt.avt_sector_stats["request_ms"] = double(r_pass.request_us) / 1000.;
	_vt.avt_sector_stats["invalidate_ms"] = double(r_pass.invalidate_us) / 1000.;
	_vt.avt_sector_stats["payload_ms"] = double(r_pass.payload_us) / 1000.;
	_vt.avt_sector_stats["queue_ms"] = double(r_pass.queue_us) / 1000.;
	_vt.surface_vt->set_allocation_budget(-1);
	_vt.avt_sector_stats["produced"] = r_pass.produced;
	if (r_pass.missing.empty() && r_pass.produced == 0 && !r_pass.prefetch_pending) { _vt.avt_idle_revision = pool->residency_revision; }
}
