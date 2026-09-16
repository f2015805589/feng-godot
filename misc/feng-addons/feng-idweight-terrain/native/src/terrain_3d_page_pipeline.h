#pragma once
#include "terrain_3d_data.h"
#include <array>
#include <atomic>
#include <condition_variable>
#include <map>
#include <memory>
#include <mutex>
#include <thread>
#include <functional>

namespace TerrainVT { struct VisibleView; struct VisiblePatch; }

// Worker owns only immutable source bytes. No scene, terrain, or renderer calls.
class Terrain3DPagePipeline {
public:
    using Key = std::array<int, 5>;
    struct Cell { PackedByteArray ids, heights, controls; const uint8_t *id_data = nullptr, *height_data = nullptr; int id_size = 0, height_size = 0, density = 1; mutable std::vector<std::vector<Vector2>> height_bounds; };
    struct Snapshot {
        int region_size; float spacing, source_step;
        std::map<std::pair<int, int>, Cell> cells;
        mutable std::once_flag bounds_once;
        mutable std::atomic<bool> bounds_ready{false};
        Vector2 bounds(const Rect2 &rect, Vector2 fallback) const;
        bool surface(const Vector2 &world, Vector3 &point, Vector3 &normal) const;
        bool project_surface(const Rect2 &rect, const TerrainVT::VisibleView &view, TerrainVT::VisiblePatch &result) const;
    };
    struct Result { Ref<Image> payload, ids, height; Vector3 grid; Array sources; std::vector<Vector2i> missing; };
    struct Request { Key key; Rect2 rect; int size, border; bool svt = false; String directory; uint32_t materials = 0; real_t density = 1; };
    static std::shared_ptr<const Snapshot> snapshot(Terrain3DData *data, int region_size, float spacing, int density);
    // `p_workers` is the number of source threads; 0 selects a default from the
    // machine. Assembling one page is a few hundred microseconds to a couple of
    // milliseconds of pure CPU, so one thread caps production far below what a
    // moving view demands and every page then arrives one at a time.
    explicit Terrain3DPagePipeline(int p_workers = 0);
    ~Terrain3DPagePipeline();
    void reset();
    void submit_task(std::function<void()> task);
    void cancel(const Key &key);
    // Drop a request whose prepared source will never be consumed: a page whose slot the
    // producer is already filling no longer needs the pipeline's copy, and a ready result
    // left in a queue slot starves the pages behind it.
    void discard(const Key &key);
    void retain(const std::vector<Request> &requests);
    void prime(const std::vector<Request> &requests, std::shared_ptr<const Snapshot> source);
    bool poll(const Request &request, std::shared_ptr<const Snapshot> source, Result &result);
    int get_worker_count() const { return int(_workers.size()); }
    // What `p_workers = 0` resolves to on this machine.
    static int default_worker_count();
    // Production diagnostics: how many pages the workers assembled and how much worker
    // time that took, plus how many requests are queued. A page rate below the demand is
    // either workers that cannot keep up or requests that were never submitted.
    void get_production_stats(int &r_pages, int64_t &r_usec, int &r_queued) {
        r_pages = _produced_pages.load(std::memory_order_relaxed);
        r_usec = int64_t(_produced_usec.load(std::memory_order_relaxed));
        std::lock_guard<std::mutex> lock(_mutex);
        r_queued = int(_entries.size());
    }
    // Where prepared pages go: hits are consumed by a poll, a rect mismatch refuses a
    // result whose footprint moved, and the rest are evicted to keep the window open.
    void get_outcome_stats(int &r_hits, int &r_rect_mismatch, int &r_evicted, int &r_discarded) {
        r_hits = _stat_hits.load(std::memory_order_relaxed);
        r_rect_mismatch = _stat_rect_mismatch.load(std::memory_order_relaxed);
        r_evicted = _stat_evicted.load(std::memory_order_relaxed);
        r_discarded = _stat_discarded.load(std::memory_order_relaxed);
    }
    void reset_production_stats() {
        _produced_pages.store(0, std::memory_order_relaxed);
        _produced_usec.store(0, std::memory_order_relaxed);
        _stat_hits.store(0, std::memory_order_relaxed);
        _stat_rect_mismatch.store(0, std::memory_order_relaxed);
        _stat_evicted.store(0, std::memory_order_relaxed);
        _stat_discarded.store(0, std::memory_order_relaxed);
    }
private:
    struct Entry { Request request; std::shared_ptr<const Snapshot> source; Result result; uint64_t token; bool running = false, ready = false, retained = false; };
    std::mutex _mutex;
    std::condition_variable _wake, _task_wake;
    std::map<Key, Entry> _entries;
    std::function<void()> _task;
    uint64_t _token = 0;
    bool _stop = false;
    std::vector<std::thread> _workers;
    std::thread _planner;
    void run();
    void plan();
    // Called with `_mutex` held: frees one queue slot when the window is full, preferring
    // a result nobody polled over work that is still in progress.
    void _make_room();
    // Guards the per-job source caches below: every worker assembles its own page, so
    // the decode caches are shared state now rather than a single thread's locals.
    std::mutex _cache_mutex;
    std::atomic<int> _produced_pages{ 0 };
    std::atomic<uint64_t> _produced_usec{ 0 };
    std::atomic<int> _stat_hits{ 0 }, _stat_rect_mismatch{ 0 }, _stat_evicted{ 0 }, _stat_discarded{ 0 };
    Dictionary _cell_cache;
    std::shared_ptr<const Snapshot> _signature_source;
    uint32_t _signature_materials = 0;
    real_t _signature_density = 0;
    std::map<std::pair<int, int>, uint32_t> _signatures;
    uint64_t _cache_bytes = 0;
    Result produce(const Request &request, const Snapshot &source);
    void load_cells(const Request &request, const Snapshot &source, Result &result);
};
