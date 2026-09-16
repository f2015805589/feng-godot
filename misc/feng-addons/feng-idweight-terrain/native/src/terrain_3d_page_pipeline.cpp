#include "terrain_3d_page_pipeline.h"
#include "terrain_3d_vt_visibility.h"
#include "terrain_vt_cell.h"
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
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
// frame. The default keeps half the machine's threads (at least one, at most four) so the
// renderer, the planner and the game keep their cores.
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
    { std::lock_guard<std::mutex> lock(_mutex); _stop = true; _entries.clear(); _task = {}; }
    _wake.notify_all(); _task_wake.notify_one();
    for (std::thread &worker : _workers) { if (worker.joinable()) { worker.join(); } }
    if (_planner.joinable()) { _planner.join(); }
}
void Terrain3DPagePipeline::reset() { std::lock_guard<std::mutex> lock(_mutex); _entries.clear(); _task = {}; }
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
void Terrain3DPagePipeline::cancel(const Key &key) { std::lock_guard<std::mutex> lock(_mutex); _entries.erase(key); }
void Terrain3DPagePipeline::discard(const Key &key) {
    std::lock_guard<std::mutex> lock(_mutex);
    auto it = _entries.find(key);
    if (it != _entries.end() && it->second.ready) { _entries.erase(it); _stat_discarded.fetch_add(1, std::memory_order_relaxed); }
}
// One queue slot is a prepared payload of a few hundred kilobytes, so the window stays at
// 32 entries - but a slot must never be held by a result nobody is going to poll. Every
// page whose slot the producer is already filling leaves its entry behind, and without
// this the window fills with dead results and the workers run out of work to do.
void Terrain3DPagePipeline::_make_room() {
    if (_entries.size() < 32) { return; }
    auto oldest = _entries.end();
    for (auto it = _entries.begin(); it != _entries.end(); ++it) {
        if (!it->second.ready) { continue; }
        if (oldest == _entries.end() || it->second.token < oldest->second.token) { oldest = it; }
    }
    if (oldest != _entries.end()) { _entries.erase(oldest); _stat_evicted.fetch_add(1, std::memory_order_relaxed); }
}
void Terrain3DPagePipeline::retain(const std::vector<Request> &requests) {
    std::lock_guard<std::mutex> lock(_mutex);
    for (auto &entry : _entries) { entry.second.retained = false; }
    for (const Request &request : requests) {
        auto it = _entries.find(request.key);
        if (it != _entries.end() && request.rect == it->second.request.rect && request.size == it->second.request.size && request.border == it->second.request.border) { it->second.retained = true; }
    }
    for (auto it = _entries.begin(); it != _entries.end();) {
        if (!it->second.retained) { it = _entries.erase(it); } else { ++it; }
    }
}
void Terrain3DPagePipeline::prime(const std::vector<Request> &requests, std::shared_ptr<const Snapshot> source) {
    {
        std::lock_guard<std::mutex> lock(_mutex);
        for (const Request &request : requests) {
            if (_entries.find(request.key) != _entries.end()) { continue; }
            _make_room();
            if (_entries.size() >= 32) { break; }
            _entries.emplace(request.key, Entry{request, source, {}, ++_token});
        }
    }
    // Every worker has to be woken: one notify leaves the others asleep while entries
    // that only they can pick up sit in the queue.
    _wake.notify_all();
}
bool Terrain3DPagePipeline::poll(const Request &request, std::shared_ptr<const Snapshot> source, Result &result) {
    std::lock_guard<std::mutex> lock(_mutex);
    auto it = _entries.find(request.key);
    if (it != _entries.end()) {
        if (!it->second.ready) { return false; }
        if (it->second.request.rect != request.rect) { _stat_rect_mismatch.fetch_add(1, std::memory_order_relaxed); return false; }
        result = std::move(it->second.result); _entries.erase(it);
        _stat_hits.fetch_add(1, std::memory_order_relaxed);
        return true;
    }
    // A poll that finds nothing submits the request, but it never evicts: the caller walks
    // its whole demand list, so evicting here would replace the work in flight with the far
    // end of that list and throw away every result the workers had just finished.
    if (_entries.size() < 32) {
        _entries.emplace(request.key, Entry{request, std::move(source), {}, ++_token});
        _wake.notify_all();
    }
    return false;
}
void Terrain3DPagePipeline::run() {
    for (;;) {
        Entry job;
        {
            std::unique_lock<std::mutex> lock(_mutex);
            _wake.wait(lock, [&]() {
                if (_stop) { return true; }
                for (const auto &entry : _entries) { if (!entry.second.running && !entry.second.ready) { return true; } }
                return false;
            });
            if (_stop) { return; }
            // Submission token preserves demand priority, independent of virtual address.
            Entry *next = nullptr;
            for (auto &entry : _entries) {
                if (!entry.second.running && !entry.second.ready && (!next || entry.second.token < next->token)) { next = &entry.second; }
            }
            next->running = true; job = *next;
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
            auto it = _entries.find(job.request.key);
            if (it != _entries.end() && it->second.token == job.token) { it->second.result = std::move(result); it->second.ready = true; }
        }
        // Waking the other workers here is what keeps them busy: the notify below is
        // cheap, and without it a page that finished while another worker slept would
        // wait for the next demand pass to be picked up.
        _wake.notify_all();
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
    result.payload = Image::create_from_data(stored, stored, false, Image::Format(39), payload);
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
    result.ids = id_out ? Image::create_from_data(stored, stored, false, Image::Format(39), ids) : result.payload;
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
