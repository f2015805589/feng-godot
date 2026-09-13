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
    Terrain3DPagePipeline();
    ~Terrain3DPagePipeline();
    void reset();
    void submit_task(std::function<void()> task);
    void cancel(const Key &key);
    void retain(const std::vector<Request> &requests);
    void prime(const std::vector<Request> &requests, std::shared_ptr<const Snapshot> source);
    bool poll(const Request &request, std::shared_ptr<const Snapshot> source, Result &result);
private:
    struct Entry { Request request; std::shared_ptr<const Snapshot> source; Result result; uint64_t token; bool running = false, ready = false, retained = false; };
    std::mutex _mutex;
    std::condition_variable _wake, _task_wake;
    std::map<Key, Entry> _entries;
    std::function<void()> _task;
    uint64_t _token = 0;
    bool _stop = false;
    std::thread _worker, _planner;
    void run();
    void plan();
    Dictionary _cell_cache;
    std::shared_ptr<const Snapshot> _signature_source;
    uint32_t _signature_materials = 0;
    real_t _signature_density = 0;
    std::map<std::pair<int, int>, uint32_t> _signatures;
    uint64_t _cache_bytes = 0;
    Result produce(const Request &request, const Snapshot &source);
    void load_cells(const Request &request, const Snapshot &source, Result &result);
};
