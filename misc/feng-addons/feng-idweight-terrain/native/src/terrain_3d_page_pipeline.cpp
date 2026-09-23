// Source page production: the worker side of the virtual texture.
//
// A page's payload - the three channels a material page carries - is assembled here from an
// immutable `Snapshot` of the region maps, off the main thread, and handed back through `poll()`.
// The workers never touch the scene, the terrain node or the renderer. What they may read is the
// snapshot's own bytes, the far-field bake files on disk (read-only, through FileAccess) and the
// decode caches below, which are shared between workers and therefore guarded by `_cache_mutex`.
//
// The queue's shape is documented on its members in the header - why the entries are a flat array,
// why the claim order is a FIFO, and why the wanted set is an open-addressed table. This file is the
// threading and the assembly around it: `retain` decides what may stay queued, `prime` fills the
// window, `poll` hands a finished page to the demand pass, and `produce` with `load_cells` is the
// assembly of one page.
//
// Indentation note: this pair of files was written with four spaces while every other file in this
// directory uses tabs. It is normalized to tabs, so a multi-file edit keeps one convention; there is
// no other change in that conversion.
#include "terrain_3d_page_pipeline.h"
#include "terrain_3d_vt_visibility.h"
#include "terrain_vt_cell.h"
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <algorithm>
#include <cmath>
#include <cstring>

std::shared_ptr<const Terrain3DPagePipeline::Snapshot> Terrain3DPagePipeline::snapshot(Terrain3DData *data, int region_size, float spacing, int density) {
	auto result = std::make_shared<Snapshot>();
	result->region_size = region_size; result->spacing = spacing; result->source_step = spacing / density;
	for (const Vector2i &location : data->get_region_locations()) {
		const Ref<Terrain3DRegion> region = data->get_region(location);
		if (region.is_null() || region->is_deleted()) { continue; }
		Cell cell;
		const Ref<Image> ids = region->get_surface_map(), heights = region->get_height_map();
		if (ids.is_valid()) { cell.ids = ids->get_data(); cell.id_size = ids->get_width(); }
		if (heights.is_valid() && heights->get_format() == Image::FORMAT_RF) { cell.heights = heights->get_data(); cell.height_size = heights->get_width(); }
		cell.id_data = cell.ids.ptr(); cell.height_data = cell.heights.ptr();
		if (region->get_control_map().is_valid()) { cell.controls = region->get_control_map()->get_data(); }
		cell.density = MAX(1, region->get_surface_density());
		result->cells[{location.x, location.y}] = std::move(cell);
	}
	return result;
}
bool Terrain3DPagePipeline::Snapshot::surface(const Vector2 &world, Vector3 &point, Vector3 &normal) const {
	const Vector2 grid = world / spacing;
	const int ix = int(std::floor(grid.x)), iz = int(std::floor(grid.y));
	auto height = [&](int x, int z, float &value) {
		const int rx = int(std::floor(x / double(region_size))), rz = int(std::floor(z / double(region_size)));
		auto it = cells.find({rx, rz});
		if (it == cells.end() || !it->second.height_data) { return false; }
		const Cell &cell = it->second;
		const int cx = CLAMP(x - rx * region_size, 0, cell.height_size - 1), cz = CLAMP(z - rz * region_size, 0, cell.height_size - 1);
		std::memcpy(&value, cell.height_data + (int64_t(cz) * cell.height_size + cx) * 4, 4);
		return true;
	};
	float a, b, c;
	const Vector2 fraction = grid - Vector2(ix, iz);
	if (!height(ix, iz, a) || !height(ix + 1, iz + 1, c)) { return false; }
	float dx, dz;
	if (fraction.x > fraction.y) {
		if (!height(ix + 1, iz, b)) { return false; }
		dx = b - a; dz = c - b;
	} else {
		if (!height(ix, iz + 1, b)) { return false; }
		dx = c - b; dz = b - a;
	}
	point = Vector3(world.x, a + dx * fraction.x + dz * fraction.y, world.y);
	normal = Vector3(-dx / spacing, 1.f, -dz / spacing);
	return true;
}
bool Terrain3DPagePipeline::Snapshot::project_surface(const Rect2 &rect, const TerrainVT::VisibleView &view, TerrainVT::VisiblePatch &result) const {
	const int x0 = int(std::floor(rect.position.x / spacing)), z0 = int(std::floor(rect.position.y / spacing));
	const int x1 = int(std::ceil(rect.get_end().x / spacing)), z1 = int(std::ceil(rect.get_end().y / spacing));
	auto vertex = [&](int x, int z) {
		const int rx = int(std::floor(x / double(region_size))), rz = int(std::floor(z / double(region_size)));
		auto it = cells.find({rx, rz});
		float h = 0.f;
		if (it != cells.end() && it->second.height_data) {
			const Cell &cell = it->second;
			const int cx = CLAMP(x - rx * region_size, 0, cell.height_size - 1), cz = CLAMP(z - rz * region_size, 0, cell.height_size - 1);
			std::memcpy(&h, cell.height_data + (int64_t(cz) * cell.height_size + cx) * 4, 4);
		}
		return Vector3(x * spacing, h, z * spacing);
	};
	result = TerrainVT::VisiblePatch();
	result.minimum_density = 1e30f;
	bool visible = false;
	for (int z = z0; z < z1; ++z) for (int x = x0; x < x1; ++x) {
		const Vector3 a = vertex(x, z), b = vertex(x + 1, z), c = vertex(x, z + 1), d = vertex(x + 1, z + 1);
		visible |= view.sample_triangle(a, d, c, rect, result);
		visible |= view.sample_triangle(a, b, d, rect, result);
	}
	return visible;
}
// Published once by a source worker; render-thread planning only reads the pyramid.
Vector2 Terrain3DPagePipeline::Snapshot::bounds(const Rect2 &rect, Vector2 fallback) const {
	Vector2 result(1e30f, -1e30f);
	const int x0 = int(std::floor(rect.position.x / spacing)), z0 = int(std::floor(rect.position.y / spacing));
	const int x1 = int(std::ceil(rect.get_end().x / spacing)), z1 = int(std::ceil(rect.get_end().y / spacing));
	for (int rz = int(std::floor(z0 / double(region_size))); rz <= int(std::floor(z1 / double(region_size))); ++rz) {
		for (int rx = int(std::floor(x0 / double(region_size))); rx <= int(std::floor(x1 / double(region_size))); ++rx) {
			auto it = cells.find({rx, rz});
			if (it == cells.end() || it->second.height_bounds.empty()) { continue; }
			const Cell &cell = it->second;
			const int ax = CLAMP(x0 - rx * region_size, 0, cell.height_size - 1), az = CLAMP(z0 - rz * region_size, 0, cell.height_size - 1);
			const int bx = CLAMP(x1 - rx * region_size, 0, cell.height_size - 1), bz = CLAMP(z1 - rz * region_size, 0, cell.height_size - 1);
			int level = 0;
			while (level + 1 < int(cell.height_bounds.size()) && (1 << level) < MAX(bx - ax + 1, bz - az + 1)) { ++level; }
			const int size = MAX(1, cell.height_size >> level);
			for (int z = az >> level; z <= bz >> level; ++z) for (int x = ax >> level; x <= bx >> level; ++x) {
				const Vector2 range = cell.height_bounds[level][z * size + x];
				result.x = MIN(result.x, range.x); result.y = MAX(result.y, range.y);
			}
		}
	}
	return result.x <= result.y ? result : fallback;
}
// Pages are assembled on more than one thread because one thread cannot feed a moving
// view: a page costs a source scan plus an id/height payload, and the demand of a camera
// crossing a sector is an order of magnitude above what a single worker can prepare per
// frame. The default keeps half the machine's threads, capped so the renderer, the planner
// and the game keep their cores. The cap is four: the batch bound (`AVT_PAGE_BATCH_MAX`) is
// what decides how many pages a tick may hand over, and a pool deeper than the batch can feed
// is throughput the batch is supposed to bound rather than a mechanism. Raising it to eight was
// measured as a rate change, not a coverage change.
static int default_page_workers() {
	const unsigned int hardware = std::thread::hardware_concurrency();
	const int threads = hardware > 0 ? int(hardware) : 4;
	return CLAMP(threads / 2, 1, 4);
}

int Terrain3DPagePipeline::default_worker_count() { return default_page_workers(); }

Terrain3DPagePipeline::Terrain3DPagePipeline(const int p_workers) {
	const int workers = p_workers > 0 ? CLAMP(p_workers, 1, 16) : default_page_workers();
	_workers.reserve(size_t(workers));
	for (int i = 0; i < workers; ++i) { _workers.emplace_back(&Terrain3DPagePipeline::run, this); }
}
Terrain3DPagePipeline::~Terrain3DPagePipeline() {
	{ std::lock_guard<std::mutex> lock(_mutex); _stop = true; _entries.clear(); _claim_order.clear(); _claim_head = 0; _claimable_count.store(0, std::memory_order_relaxed); _task = {}; }
	_wake.notify_all(); _task_wake.notify_one();
	for (std::thread &worker : _workers) { if (worker.joinable()) { worker.join(); } }
	if (_planner.joinable()) { _planner.join(); }
}
void Terrain3DPagePipeline::reset() { std::lock_guard<std::mutex> lock(_mutex); _entries.clear(); _claim_order.clear(); _claim_head = 0; _claimable_count.store(0, std::memory_order_relaxed); _task = {}; }
void Terrain3DPagePipeline::submit_task(std::function<void()> task) {
	{
		std::lock_guard<std::mutex> lock(_mutex);
		_task = std::move(task);
		if (!_planner.joinable()) { _planner = std::thread(&Terrain3DPagePipeline::plan, this); }
	}
	_task_wake.notify_one();
}
void Terrain3DPagePipeline::plan() {
	// Refinement must not monopolize the worker that supplies ready page bytes.
	// These stages share immutable snapshots but otherwise progress independently.
	for (;;) {
		std::function<void()> task;
		{
			std::unique_lock<std::mutex> lock(_mutex);
			_task_wake.wait(lock, [&]() { return _stop || bool(_task); });
			if (_stop) { return; }
			task = std::move(_task); _task = {};
		}
		task();
	}
}
int Terrain3DPagePipeline::_index_of(const Key &p_key) const {
	for (size_t i = 0; i < _entries.size(); ++i) {
		if (_entries[i].request.key == p_key) { return int(i); }
	}
	return -1;
}
int Terrain3DPagePipeline::_count_claimable() const {
	int count = 0;
	for (const Entry &entry : _entries) {
		if (!entry.running && !entry.ready) { ++count; }
	}
	return count;
}
void Terrain3DPagePipeline::_erase_at(int p_index) {
	_entries[size_t(p_index)] = std::move(_entries.back());
	_entries.pop_back();
	_claimable_count.store(_count_claimable(), std::memory_order_relaxed);
}
void Terrain3DPagePipeline::cancel(const Key &key) {
	std::lock_guard<std::mutex> lock(_mutex);
	const int index = _index_of(key);
	if (index >= 0) { _erase_at(index); }
}
void Terrain3DPagePipeline::discard(const Key &key) {
	std::lock_guard<std::mutex> lock(_mutex);
	const int index = _index_of(key);
	if (index >= 0 && _entries[size_t(index)].ready) { _erase_at(index); _stat_discarded.fetch_add(1, std::memory_order_relaxed); }
}
void Terrain3DPagePipeline::_lock_queue(std::unique_lock<std::mutex> &r_lock) {
	// Deliberately a plain lock. Spinning for the queue before blocking was tried against the
	// measurement that motivated it - `prime` reading 0.13 ms for a dozen inserts - and it made the
	// reading no better: the spin does not shorten the wait, it *is* the wait, with the same
	// magnitude as the wake latency it was meant to avoid (2000 `try_lock` calls is ~40 us). The
	// queue is taken once per batch and the critical sections are microseconds; blocking on it is
	// what the operating system already does well.
	r_lock.lock();
}
// One queue slot is a prepared payload of a few hundred kilobytes, so the window stays at
// 32 entries - but a slot must never be held by a result nobody is going to poll. Every
// page whose slot the producer is already filling leaves its entry behind, and without
// this the window fills with dead results and the workers run out of work to do.
void Terrain3DPagePipeline::_make_room() {
	if (int(_entries.size()) < _queue_limit.load(std::memory_order_relaxed)) { return; }
	int oldest = -1;
	for (size_t i = 0; i < _entries.size(); ++i) {
		if (!_entries[i].ready) { continue; }
		if (oldest < 0 || _entries[i].token < _entries[size_t(oldest)].token) { oldest = int(i); }
	}
	// Only a finished result is ever evicted, and a finished result is not claimable, so the
	// claimable count does not move here.
	if (oldest >= 0) {
		_entries[size_t(oldest)] = std::move(_entries.back());
		_entries.pop_back();
		_stat_evicted.fetch_add(1, std::memory_order_relaxed);
	}
}
void Terrain3DPagePipeline::retain(const std::vector<Request> &requests) {
	const uint64_t started = Time::get_singleton()->get_ticks_usec();
	std::unique_lock<std::mutex> lock(_mutex, std::defer_lock);
	_lock_queue(lock);
	const uint64_t locked = Time::get_singleton()->get_ticks_usec();
	// Build the wanted set as a flat open-addressed table keyed by the entry's own key, then ask
	// each entry whether it is in it. The table is built in place and keeps its capacity, so a
	// pass allocates nothing; the value is the request's index, which is what the footprint
	// comparison needs on a hit.
	size_t wanted = 16;
	while (wanted < requests.size() * 2) { wanted <<= 1; }
	if (wanted > _retain_capacity) {
		_retain_capacity = wanted;
		_retain_keys.resize(wanted);
		_retain_slots.resize(wanted);
	}
	const size_t mask = _retain_capacity - 1;
	std::fill(_retain_slots.begin(), _retain_slots.begin() + _retain_capacity, RETAIN_EMPTY);
	const KeyHash hash_key;
	for (size_t i = 0; i < requests.size(); ++i) {
		size_t at = hash_key(requests[i].key) & mask;
		while (_retain_slots[at] != RETAIN_EMPTY) { at = (at + 1) & mask; }
		_retain_slots[at] = uint32_t(i);
		_retain_keys[at] = requests[i].key;
	}
	for (Entry &entry : _entries) {
		size_t at = hash_key(entry.request.key) & mask;
		uint32_t index = RETAIN_EMPTY;
		while (_retain_slots[at] != RETAIN_EMPTY) {
			if (_retain_keys[at] == entry.request.key) { index = _retain_slots[at]; break; }
			at = (at + 1) & mask;
		}
		const Request *found = index == RETAIN_EMPTY ? nullptr : &requests[index];
		entry.retained = found && found->rect == entry.request.rect &&
				found->size == entry.request.size && found->border == entry.request.border;
	}
	const uint64_t indexed = Time::get_singleton()->get_ticks_usec();
	// The claimable count is settled once for the whole compaction rather than once per erase:
	// `_erase_at` rescans the queue to recount, which is the same quadratic shape one level down.
	for (int i = int(_entries.size()) - 1; i >= 0; --i) {
		if (_entries[size_t(i)].retained) { continue; }
		const size_t last = _entries.size() - 1;
		// Not `_erase_at`: it moves the last entry onto itself when the entry being dropped is
		// already the last one, and an entry that is being erased is the only place a damaged
		// self-move could hide.
		if (size_t(i) != last) { _entries[size_t(i)] = std::move(_entries[last]); }
		_entries.pop_back();
	}
	_claimable_count.store(_count_claimable(), std::memory_order_relaxed);
	const uint64_t finished = Time::get_singleton()->get_ticks_usec();
	_retain_lock_us.store(locked - started, std::memory_order_relaxed);
	_retain_index_us.store(finished - locked, std::memory_order_relaxed);
}
void Terrain3DPagePipeline::prime(const std::vector<Request> &requests, std::shared_ptr<const Snapshot> source) {
	int inserted = 0;
	int wakes = 0;
	const uint64_t started = Time::get_singleton()->get_ticks_usec();
	{
		std::unique_lock<std::mutex> lock(_mutex, std::defer_lock);
		_lock_queue(lock);
		for (const Request &request : requests) {
			if (_index_of(request.key) >= 0) { continue; }
			// Retain already removed obsolete demand. A full batch contains work
			// the consumer still needs, including completed payloads it will poll
			// immediately after prime. Evicting those here repeatedly prepares the
			// same pages and delays nearby detail. Consumption opens the slots for
			// the bounded refill later in this pass.
			if (int(_entries.size()) >= _queue_limit.load(std::memory_order_relaxed)) { break; }
			const uint64_t token = ++_token;
			_entries.push_back(Entry{request, source, {}, token});
			_claim_order.push_back(request.key);
			++inserted;
		}
		if (inserted > 0) { _claimable_count.store(_count_claimable(), std::memory_order_relaxed); }
		// A wake is a syscall and it is only useful for a worker that is parked. Waking one
		// worker per entry added cost thirty-two of them on every demand pass, and the pass
		// refills the queue on every tick whether or not anybody is asleep.
		wakes = MIN(inserted, _waiters);
	}
	const uint64_t inserted_at = Time::get_singleton()->get_ticks_usec();
	// Owed, not sent: `flush_wakes()` sends them when the pass that submitted this work is over.
	if (wakes > 0) { _pending_wakes.fetch_add(wakes, std::memory_order_relaxed); }
	const uint64_t woken_at = inserted_at;
	_prime_insert_us.store(inserted_at - started, std::memory_order_relaxed);
	_prime_wake_us.store(woken_at - inserted_at, std::memory_order_relaxed);
	_prime_inserted.store(inserted, std::memory_order_relaxed);
	_prime_wakes.store(wakes, std::memory_order_relaxed);
}
Terrain3DPagePipeline::ReadyKeys Terrain3DPagePipeline::ready_keys() {
	ReadyKeys result{};
	{
		std::lock_guard<std::mutex> lock(_mutex);
		for (const Entry &entry : _entries) {
			if (entry.ready) { result.keys[result.count++] = entry.request.key; }
		}
	}
	std::sort(result.keys.begin(), result.keys.begin() + result.count);
	return result;
}

bool Terrain3DPagePipeline::poll(const Request &request, std::shared_ptr<const Snapshot> source, Result &result) {
	std::unique_lock<std::mutex> lock(_mutex, std::defer_lock);
	_lock_queue(lock);
	const int index = _index_of(request.key);
	if (index >= 0) {
		Entry &entry = _entries[size_t(index)];
		if (!entry.ready) { return false; }
		if (entry.request.rect != request.rect) { _stat_rect_mismatch.fetch_add(1, std::memory_order_relaxed); return false; }
		result = std::move(entry.result);
		_erase_at(index);
		_stat_hits.fetch_add(1, std::memory_order_relaxed);
		return true;
	}
	// A poll that finds nothing submits the request, but it never evicts: the caller walks
	// its whole demand list, so evicting here would replace the work in flight with the far
	// end of that list and throw away every result the workers had just finished.
	if (int(_entries.size()) < _queue_limit.load(std::memory_order_relaxed)) {
		const uint64_t token = ++_token;
		_entries.push_back(Entry{request, std::move(source), {}, token});
		_claim_order.push_back(request.key);
		_claimable_count.store(_count_claimable(), std::memory_order_relaxed);
		if (_waiters > 0) { _pending_wakes.fetch_add(1, std::memory_order_relaxed); }
	}
	return false;
}
void Terrain3DPagePipeline::run() {
	for (;;) {
		Entry job;
		bool claimed = false;
		{
			std::unique_lock<std::mutex> lock(_mutex);
			++_waiters;
			_wake.wait(lock, [&]() { return _stop || _claimable_count.load(std::memory_order_relaxed) > 0; });
			--_waiters;
			if (_stop) { return; }
			// Submission priority, independent of virtual address: the tokens ascend with
			// insertion, so the unclaimed keys are in submission order. A key whose entry was
			// erased before it was claimed, or whose entry a worker already has, is skipped. Once
			// the finished prefix is long enough to be worth moving, it is dropped.
			while (_claim_head < _claim_order.size()) {
				const Key key = _claim_order[_claim_head++];
				const int index = _index_of(key);
				if (index < 0 || _entries[size_t(index)].running || _entries[size_t(index)].ready) { continue; }
				_entries[size_t(index)].running = true;
				job = _entries[size_t(index)];
				_claimable_count.fetch_sub(1, std::memory_order_relaxed);
				claimed = true;
				break;
			}
			if (_claim_head >= 64) {
				_claim_order.erase(_claim_order.begin(), _claim_order.begin() + int64_t(_claim_head));
				_claim_head = 0;
			}
			if (!claimed) {
				// Nothing was claimable after all: repair the count from the queue so the wait
				// cannot spin on a number that does not match it.
				_claimable_count.store(_count_claimable(), std::memory_order_relaxed);
				continue;
			}
		}
		if (job.request.svt && (_signature_source != job.source || _signature_materials != job.request.materials || _signature_density != job.request.density)) {
			std::lock_guard<std::mutex> cache_lock(_cache_mutex);
			_signature_source = job.source; _signature_materials = job.request.materials; _signature_density = job.request.density; _signatures.clear();
		}
		std::call_once(job.source->bounds_once, [&]() {
			for (const auto &item : job.source->cells) {
				const Cell &cell = item.second;
				if (!cell.height_size || !cell.height_data) { continue; }
				cell.height_bounds.emplace_back(cell.height_size * cell.height_size);
				for (int i = 0; i < cell.height_size * cell.height_size; ++i) {
					float h; std::memcpy(&h, cell.height_data + int64_t(i) * 4, 4);
					cell.height_bounds[0][i] = Vector2(h, h);
				}
				for (int size = cell.height_size / 2; size > 0; size /= 2) {
					const auto &previous = cell.height_bounds.back();
					std::vector<Vector2> next(size * size);
					for (int z = 0; z < size; ++z) for (int x = 0; x < size; ++x) {
						Vector2 range(1e30f, -1e30f);
						for (int dz = 0; dz < 2; ++dz) for (int dx = 0; dx < 2; ++dx) {
							Vector2 v = previous[(z * 2 + dz) * size * 2 + x * 2 + dx];
							range.x = MIN(range.x, v.x); range.y = MAX(range.y, v.y);
						}
						next[z * size + x] = range;
					}
					cell.height_bounds.push_back(std::move(next));
				}
			}
			job.source->bounds_ready.store(true, std::memory_order_release);
		});
		const uint64_t produce_start = Time::get_singleton()->get_ticks_usec();
		Result result = produce(job.request, *job.source);
		_produced_usec.fetch_add(Time::get_singleton()->get_ticks_usec() - produce_start, std::memory_order_relaxed);
		_produced_pages.fetch_add(1, std::memory_order_relaxed);
		{
			std::lock_guard<std::mutex> lock(_mutex);
			const int index = _index_of(job.request.key);
			if (index >= 0 && _entries[size_t(index)].token == job.token) {
				_entries[size_t(index)].result = std::move(result);
				_entries[size_t(index)].ready = true;
			}
		}
		// Finishing does not add work, so it does not wake anybody. The worker that wakes on
		// a new entry claims it, and the entries a batch added are woken one per entry by the
		// submitter; notifying the whole pool here as well only put every worker back in the
		// queue for a lock the demand pass needed, once per finished page.
	}
}
Terrain3DPagePipeline::Result Terrain3DPagePipeline::produce(const Request &request, const Snapshot &source) {
	const float world = source.region_size * source.spacing;
	// Adjacent output samples overwhelmingly read the same source cell. Keep a
	// tiny local lookup cache so producing a page does not perform hundreds of
	// thousands of ordered-map searches. This cache belongs to this job only.
	struct CachedCell { int x = INT32_MIN, z = INT32_MIN; const Cell *cell = nullptr; };
	std::array<CachedCell, 16> cached_cells;
	auto find_cell = [&](int x, int z) -> const Cell * {
		CachedCell &cached = cached_cells[(uint32_t(x) & 3u) | ((uint32_t(z) & 3u) << 2)];
		if (cached.x != x || cached.z != z) {
			const auto it = source.cells.find({x, z});
			cached = {x, z, it == source.cells.end() ? nullptr : &it->second};
		}
		return cached.cell;
	};
	auto ids_at = [&](float x, float z) -> uint16_t {
		int rx = int(std::floor(x / world)), rz = int(std::floor(z / world));
		const Cell *found = find_cell(rx, rz);
		if (!found || !found->id_size) { return 0; }
		const Cell &cell = *found;
		const float step = source.spacing / cell.density;
		int ix = CLAMP(int(std::floor((x - rx * world) / step)), 0, cell.id_size - 1);
		int iz = CLAMP(int(std::floor((z - rz * world) / step)), 0, cell.id_size - 1);
		uint16_t value; std::memcpy(&value, cell.id_data + (int64_t(iz) * cell.id_size + ix) * 2, 2); return value;
	};
	auto height_at = [&](int x, int z) -> float {
		int rx = int(std::floor(double(x) / source.region_size)), rz = int(std::floor(double(z) / source.region_size));
		const Cell *found = find_cell(rx, rz);
		if (!found || !found->height_size) { return 0; }
		const Cell &cell = *found;
		int ix = CLAMP(x - rx * source.region_size, 0, cell.height_size - 1);
		int iz = CLAMP(z - rz * source.region_size, 0, cell.height_size - 1);
		float value; std::memcpy(&value, cell.height_data + (int64_t(iz) * cell.height_size + ix) * 4, 4); return std::isfinite(value) ? value : 0.f;
	};
	auto sample_height = [&](float x, float z) -> float {
		x /= source.spacing; z /= source.spacing;
		int ix = int(std::floor(x)), iz = int(std::floor(z));
		float fx = x - ix, fz = z - iz;
		float h00 = height_at(ix, iz), h10 = height_at(ix + 1, iz), h01 = height_at(ix, iz + 1), h11 = height_at(ix + 1, iz + 1);
		return fx > fz ? h00 * (1.f - fx) + h10 * (fx - fz) + h11 * fz : h00 * (1.f - fz) + h01 * (fz - fx) + h11 * fx;
	};
	const int stored = request.size + request.border * 2;
	const float pixel = request.rect.size.x / request.size;
	PackedByteArray payload; payload.resize(int64_t(stored) * stored * 2);
	uint8_t *out = payload.ptrw();
	// Fine material pages repeatedly sample the same authored ID row. Preserve
	// the exact raw diagnostic payload, but copy identical rows instead of doing
	// tens of thousands of identical source lookups per page. Compare every
	// crossed region's row index, so mixed paint densities remain exact.
	const float first_x = request.rect.position.x + (.5f - request.border) * pixel;
	const float last_x = request.rect.position.x + (float(stored - 1 - request.border) + .5f) * pixel;
	const int rx0 = int(std::floor(first_x / world)), rx1 = int(std::floor(last_x / world));
	std::vector<std::pair<const Cell *, int>> previous_rows, rows;
	rows.reserve(rx1 - rx0 + 1); previous_rows.reserve(rx1 - rx0 + 1);
	for (int y = 0; y < stored; ++y) {
		const float wz = request.rect.position.y + (float(y - request.border) + .5f) * pixel;
		const int rz = int(std::floor(wz / world));
		rows.clear();
		for (int rx = rx0; rx <= rx1; ++rx) {
			const Cell *cell = find_cell(rx, rz);
			const int row = cell && cell->id_size ? CLAMP(int(std::floor((wz - rz * world) / (source.spacing / cell->density))), 0, cell->id_size - 1) : -1;
			rows.emplace_back(cell, row);
		}
		if (y > 0 && rows == previous_rows) {
			std::memcpy(out + int64_t(y) * stored * 2, out + int64_t(y - 1) * stored * 2, size_t(stored) * 2);
		} else {
			for (int x = 0; x < stored; ++x) {
				uint16_t value = ids_at(request.rect.position.x + (float(x - request.border) + .5f) * pixel, wz);
				std::memcpy(out + (int64_t(y) * stored + x) * 2, &value, 2);
			}
		}
		previous_rows.swap(rows);
	}
	Result result;
	result.payload = Image::create_from_data(stored, stored, false, IDWEIGHT_IMAGE_FORMAT, payload);
	if (request.svt) { load_cells(request, source, result); return result; }
	PackedByteArray ids, heights; heights.resize(int64_t(stored) * stored * 4);
	uint8_t *height_out = heights.ptrw();
	int extent = stored;
	Vector2 origin = request.rect.position - Vector2(pixel, pixel) * (request.border - .5f);
	float step = pixel;
	if (pixel <= source.source_step) {
		origin = ((request.rect.position - Vector2(pixel, pixel) * request.border) / source.source_step).floor() * source.source_step;
		const Vector2 end = request.rect.get_end() + Vector2(pixel, pixel) * request.border;
		extent = MIN(stored, int(Math::ceil(MAX(end.x - origin.x, end.y - origin.y) / source.source_step)) + 2);
		step = source.source_step; result.grid = Vector3(origin.x, origin.y, step);
		ids.resize(int64_t(stored) * stored * 2);
	}
	uint8_t *id_out = ids.is_empty() ? nullptr : ids.ptrw();
	for (int y = 0; y < extent; ++y) {
		for (int x = 0; x < extent; ++x) {
			const float wx = origin.x + x * step, wz = origin.y + y * step;
			const float h = sample_height(wx, wz);
			std::memcpy(height_out + (int64_t(y) * stored + x) * 4, &h, 4);
			if (id_out) { uint16_t id = ids_at(wx, wz); std::memcpy(id_out + (int64_t(y) * stored + x) * 2, &id, 2); }
		}
	}
	result.ids = id_out ? Image::create_from_data(stored, stored, false, IDWEIGHT_IMAGE_FORMAT, ids) : result.payload;
	result.height = Image::create_from_data(stored, stored, false, Image::FORMAT_RF, heights);
	return result;
}

void Terrain3DPagePipeline::load_cells(const Request &request, const Snapshot &source, Result &result) {
	const float world = source.region_size * source.spacing;
	const float pixel = request.rect.size.x / request.size;
	const Rect2 footprint = request.rect.grow(pixel * request.border);
	const int requested_mip = MAX(0, int(Math::floor(Math::log(MAX(1.f, pixel * float(request.density))) / Math::log(2.f))));
	for (const auto &entry : source.cells) {
		const Vector2i location(entry.first.first, entry.first.second);
		const Rect2 rect(Vector2(location) * world, Vector2(world, world));
		if (!rect.intersects(footprint)) { continue; }
		uint32_t hash = 0;
		{
			std::lock_guard<std::mutex> cache_lock(_cache_mutex);
			auto cached_signature = _signatures.find(entry.first);
			if (cached_signature == _signatures.end()) {
				// The same signature the baker wrote; see terrain_vt_cell.h. Computed
				// under the lock: it reads the shared signature map, not source bytes.
				const uint32_t computed = TerrainVTCell::signature(int64_t(request.materials), request.density,
						source.spacing, source.region_size, [&](int x, int y) {
							auto neighbor = source.cells.find({location.x + x, location.y + y});
							if (neighbor == source.cells.end()) { return Array(); }
							const Cell &cell = neighbor->second;
							Array hashes;
							hashes.push_back(cell.controls.is_empty() ? 0 : Variant(cell.controls).hash());
							hashes.push_back(cell.ids.is_empty() ? 0 : Variant(cell.ids).hash());
							hashes.push_back(cell.heights.is_empty() ? 0 : Variant(cell.heights).hash());
							return hashes;
						});
				cached_signature = _signatures.emplace(entry.first, computed).first;
			}
			hash = cached_signature->second;
		}
		const String path = TerrainVTCell::path(request.directory, location, 0);
		const String cache_key = path + String(":") + String::num_int64(hash) + String(":") + String::num_int64(requested_mip);
		Dictionary channels;
		bool cached = false;
		{
			std::lock_guard<std::mutex> cache_lock(_cache_mutex);
			if (_cell_cache.has(cache_key)) { channels = _cell_cache[cache_key]; cached = true; }
		}
		if (!cached) {
			Ref<FileAccess> file;
			if (FileAccess::file_exists(path)) { file = FileAccess::open(path, FileAccess::READ); }
			const Variant header = file.is_valid() ? file->get_var(false) : Variant();
			if (header.get_type() != Variant::DICTIONARY) { result.missing.push_back(location); continue; }
			const Dictionary saved = header;
			const int resolution = saved.get("resolution", 0), levels = saved.get("levels", 0);
			const PackedInt64Array index = saved.get("index", PackedInt64Array());
			if (int(saved.get("version", 0)) != TerrainVTCell::FORMAT_VERSION || uint32_t(int64_t(saved.get("signature", 0))) != hash || resolution < 1 || resolution > 8192 || levels < 1 || levels > 14 || index.size() != levels * 6) { result.missing.push_back(location); continue; }
			const int mip = MIN(requested_mip, levels - 1), size = MAX(1, resolution >> mip);
			const String names[] = {"albedo_height", "normal_roughness", "params"};
			bool valid = true;
			for (int c = 0; c < 3; ++c) {
				const int64_t offset = index[mip * 6 + c * 2], length = index[mip * 6 + c * 2 + 1];
				if (offset < 0 || length <= 0 || uint64_t(offset) > file->get_length() || uint64_t(length) > file->get_length() - uint64_t(offset)) { valid = false; break; }
				file->seek(offset);
				PackedByteArray bytes = file->get_buffer(length).decompress(int64_t(size) * size * 8, FileAccess::COMPRESSION_ZSTD);
				if (bytes.size() != int64_t(size) * size * 8) { valid = false; break; }
				channels[names[c]] = Image::create_from_data(size, size, false, Image::FORMAT_RGBAH, bytes);
			}
			if (!valid) { result.missing.push_back(location); continue; }
			// The decode above deliberately runs outside the lock: it is file I/O and a
			// zstd decompress, which would serialize every worker behind one page.
			const uint64_t bytes = uint64_t(size) * size * 24;
			std::lock_guard<std::mutex> cache_lock(_cache_mutex);
			if (!_cell_cache.has(cache_key)) {
				if (_cache_bytes + bytes > 256 * 1024 * 1024 || _cell_cache.size() >= 64) { _cell_cache.clear(); _cache_bytes = 0; }
				_cell_cache[cache_key] = channels; _cache_bytes += bytes;
			}
		}
		Dictionary piece; piece["cell_rect"] = rect;
		// Texture filtering at the outer terrain boundary needs edge texels in
		// the physical-page border too. Extend only where no source cell exists;
		// an existing cell with a missing/stale bake still blocks publication.
		const float padding = pixel * (request.border + 1);
		auto absent_column = [&](int dx) {
			for (int dz = -1; dz <= 1; ++dz) { if (source.cells.count({location.x + dx, location.y + dz})) { return false; } }
			return true;
		};
		auto absent_row = [&](int dz) {
			for (int dx = -1; dx <= 1; ++dx) { if (source.cells.count({location.x + dx, location.y + dz})) { return false; } }
			return true;
		};
		const float left = absent_column(-1) ? padding : 0.f, right = absent_column(1) ? padding : 0.f;
		const float top = absent_row(-1) ? padding : 0.f, bottom = absent_row(1) ? padding : 0.f;
		piece["coverage_rect"] = Rect2(rect.position - Vector2(left, top), rect.size + Vector2(left + right, top + bottom));
		for (const String &name : {String("albedo_height"), String("normal_roughness"), String("params")}) {
			Ref<Image> full = channels[name];
			const int size = full->get_width(); const float step = world / size;
			const Rect2 area = footprint.intersection(rect);
			Vector2i origin(MAX(0, int(Math::floor((area.position.x - rect.position.x) / step)) - 1), MAX(0, int(Math::floor((area.position.y - rect.position.y) / step)) - 1));
			Vector2i end(MIN(size, int(Math::ceil((area.get_end().x - rect.position.x) / step)) + 1), MIN(size, int(Math::ceil((area.get_end().y - rect.position.y) / step)) + 1));
			piece[name] = full->get_region(Rect2i(origin, end - origin));
			piece["source_rect"] = Rect2(rect.position + Vector2(origin) * step, Vector2(end - origin) * step);
		}
		result.sources.push_back(piece);
	}
}
