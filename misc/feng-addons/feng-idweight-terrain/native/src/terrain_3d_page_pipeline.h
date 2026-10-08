#pragma once
#include "constants.h"
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <array>
#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <thread>
#include <functional>
#include <utility>
#include <vector>

class Terrain3DData;

namespace TerrainVT { struct VisibleView; struct VisiblePatch; }

// Worker owns only immutable source bytes. No scene, terrain, or renderer calls.
class Terrain3DPagePipeline {
public:
	using Key = std::array<int, 5>;
	// 32 prepared pages in steady state; cold-view bursts may raise the bounded
	// window to 256. ReadyKeys can represent either window.
	static constexpr size_t QUEUE_CAPACITY = 32;
	static constexpr size_t MAX_QUEUE_CAPACITY = 256;
	// Bound deferred image destruction when workers are idle.
	static constexpr size_t RELEASE_QUEUE_LIMIT = 256;
	struct ReadyKeys {
		std::array<Key, MAX_QUEUE_CAPACITY> keys;
		size_t count = 0;
		bool contains(const Key &p_key) const {
			return std::binary_search(keys.begin(), keys.begin() + count, p_key);
		}
	};
	struct Cell { PackedByteArray ids, heights, controls; const uint8_t *id_data = nullptr, *height_data = nullptr; int id_size = 0, height_size = 0, density = 1; mutable std::vector<std::vector<Vector2>> height_bounds; };
	struct Snapshot {
		int region_size; float spacing, source_step;
		std::map<std::pair<int, int>, Cell> cells;
		mutable std::once_flag bounds_once;
		mutable std::atomic<bool> bounds_ready{false};
		// The clipmap's immutable row source, shared with page production so its worker can read region
		// maps without touching Terrain3DData or racing an editor write.
		float clipmap_height_texel(const Vector2 &world) const;
		uint32_t clipmap_surface_texel(const Vector2 &world) const;
		Vector2 bounds(const Rect2 &rect, Vector2 fallback) const;
		bool surface(const Vector2 &world, Vector3 &point, Vector3 &normal) const;
		bool project_surface(const Rect2 &rect, const TerrainVT::VisibleView &view, TerrainVT::VisiblePatch &result) const;
	};
	struct Result { Ref<Image> payload, ids, height; Vector3 grid; Array sources; std::vector<Vector2i> missing; };
	struct Request { Key key; Rect2 rect; int size, border; bool svt = false; String directory; uint32_t materials = 0; real_t density = 1; };
	static std::shared_ptr<const Snapshot> snapshot(Terrain3DData *data, int region_size, float spacing, int density);
	// Zero selects the machine default; explicit worker counts are clamped to 1..16.
	explicit Terrain3DPagePipeline(int p_workers = 0);
	~Terrain3DPagePipeline();
	void reset();
	void submit_task(std::function<void()> task);
	// Renderer commands run on the planner thread in FIFO order and are drained on
	// destruction. Unlike replaceable planning work, queued storage leases must finish.
	void submit_render_task(std::function<void()> task);
	void cancel(const Key &key);
	// Drop a ready payload that the producer no longer needs.
	void discard(const Key &key);
	void retain(const std::vector<Request> &requests);
	void prime(const std::vector<Request> &requests, std::shared_ptr<const Snapshot> source);
	bool poll(const Request &request, std::shared_ptr<const Snapshot> source, Result &result);
	// A bounded value snapshot: consumers poll only results ready at the start
	// of their pass. No queue storage or lock escapes the pipeline.
	ReadyKeys ready_keys();
	int get_worker_count() const { return int(_workers.size()); }
	// What `p_workers = 0` resolves to on this machine.
	static int default_worker_count();
	// Worker production and queue diagnostics.
	void get_production_stats(int &r_pages, int64_t &r_usec, int &r_queued) {
		r_pages = _produced_pages.load(std::memory_order_relaxed);
		r_usec = int64_t(_produced_usec.load(std::memory_order_relaxed));
		std::lock_guard<std::mutex> lock(_mutex);
		r_queued = int(_entries.size());
	}
	// Consumption and rejected footprint diagnostics; the legacy eviction count stays zero.
	void get_outcome_stats(int &r_hits, int &r_rect_mismatch, int &r_evicted, int &r_discarded) {
		r_hits = _stat_hits.load(std::memory_order_relaxed);
		r_rect_mismatch = _stat_rect_mismatch.load(std::memory_order_relaxed);
		r_evicted = 0; // Ready results stay queued until consumed, discarded or no longer wanted.
		r_discarded = _stat_discarded.load(std::memory_order_relaxed);
	}
	void reset_production_stats() {
		_produced_pages.store(0, std::memory_order_relaxed);
		_produced_usec.store(0, std::memory_order_relaxed);
		_stat_hits.store(0, std::memory_order_relaxed);
		_stat_rect_mismatch.store(0, std::memory_order_relaxed);
		_stat_discarded.store(0, std::memory_order_relaxed);
	}
	// Last prime insertion time and deferred worker notifications.
	void get_prime_stats(int64_t &r_insert_us, int64_t &r_wake_us) {
		r_insert_us = int64_t(_prime_insert_us.load(std::memory_order_relaxed));
		r_wake_us = 0; // Notifications are deferred to flush_wakes().
	}
	void get_prime_counts(int &r_inserted, int &r_wakes) {
		r_inserted = _prime_inserted.load(std::memory_order_relaxed);
		r_wakes = _prime_wakes.load(std::memory_order_relaxed);
	}
	// Last retain lock wait and index/compaction time.
	void get_retain_stats(int64_t &r_lock_us, int64_t &r_index_us) {
		r_lock_us = int64_t(_retain_lock_us.load(std::memory_order_relaxed));
		r_index_us = int64_t(_retain_index_us.load(std::memory_order_relaxed));
	}
	// How many requests a worker could still claim right now. Lock free.
	int claimable_count() const { return _claimable_count.load(std::memory_order_relaxed); }
	// A cold-view burst can widen the queue without changing its hard bound.
	void set_queue_limit(int p_limit) {
		_queue_limit.store(CLAMP(p_limit, int(QUEUE_CAPACITY), int(MAX_QUEUE_CAPACITY)), std::memory_order_relaxed);
	}
	int get_queue_limit() const { return _queue_limit.load(std::memory_order_relaxed); }
	// Stage image destruction on the demand thread, without taking the release lock.
	// flush_releases() publishes once per tick; workers destroy images between jobs.
	// A full stage returns false so callers release locally instead of growing it.
	bool defer_release(const Ref<godot::Image> &p_payload);
	// Publish the staged payloads once per tick, dropping overflow locally.
	void flush_releases();
	// Send deferred worker notifications after the demand pass has finished.
	void flush_wakes() {
		const int pending = _pending_wakes.exchange(0, std::memory_order_relaxed);
		for (int i = 0; i < pending; ++i) { _wake.notify_one(); }
	}
private:
	struct Entry { Request request; std::shared_ptr<const Snapshot> source; Result result; uint64_t token; bool running = false, ready = false; };
	// Reusable open-addressed index into the current request vector. Entries compare
	// their footprint only after a key hit; no per-request node allocations.
	static constexpr uint32_t RETAIN_EMPTY = 0xFFFFFFFFu;
	struct KeyHash {
		size_t operator()(const Key &p_key) const {
			uint64_t h = 1469598103934665603ull;
			for (const int part : p_key) { h = (h ^ uint32_t(part)) * 1099511628211ull; }
			// Page coordinates are power-of-two aligned. Mix their high bits before the
			// power-of-two table mask, otherwise nearby mip pages form long probe chains.
			h ^= h >> 33;
			h *= 0xff51afd7ed558ccdull;
			h ^= h >> 33;
			h *= 0xc4ceb9fe1a85ec53ull;
			return size_t(h ^ (h >> 33));
		}
	};
	std::vector<uint32_t> _retain_slots;
	// Bounded flat queue; tokens distinguish canceled work from a replacement using
	// the same key. Claim order is submission order, independent of key sorting.
	std::vector<Entry> _entries;
	std::vector<Key> _claim_order;
	// Consumed FIFO prefix; canceled keys are skipped and the prefix is compacted in batches.
	size_t _claim_head = 0;
	std::mutex _mutex;
	std::condition_variable _wake, _task_wake;
	// Only the demand thread writes staging; _release_mutex protects the published
	// queue. Workers destroy drained payloads outside both queue locks.
	std::vector<Ref<godot::Image>> _release_staging;
	std::mutex _release_mutex;
	std::vector<Ref<godot::Image>> _released;
	// Atomic hint avoids locking an empty release queue.
	std::atomic<int> _released_count{ 0 };
	// Drain published payloads between source jobs.
	void _drain_released();
	// Defer up to three images before erasing a prepared queue entry.
	void _defer_result_release(Result &r_result);
	// Number of pending entries, updated under _mutex and read as a lock-free hint.
	std::atomic<int> _claimable_count{ 0 };
	// Notifications deferred until the end of the demand pass.
	std::atomic<int> _pending_wakes{ 0 };
	// Demand-thread setting; relaxed readers may use the previous bound for one tick.
	std::atomic<int> _queue_limit{ int(QUEUE_CAPACITY) };
	// Number of workers waiting under _mutex; avoid notifications for busy workers.
	int _waiters = 0;
	std::function<void()> _task;
	std::deque<std::function<void()>> _render_tasks;
	uint64_t _token = 0;
	bool _stop = false;
	std::vector<std::thread> _workers;
	std::thread _planner;
	void run();
	void plan();
	// Called with `_mutex` held: the index of the entry for a key, or -1.
	int _index_of(const Key &p_key) const;
	// Called under _mutex. Defer payload release, account for unclaimed work and
	// replace the erased entry with the last one. Indices never escape this lock.
	void _erase_at(int p_index);
	// Called with `_mutex` held: how many entries are neither running nor finished.
	int _count_claimable() const;
	// Guards the per-job source caches below: every worker assembles its own page, so
	// the decode caches are shared state now rather than a single thread's locals.
	std::mutex _cache_mutex;
	std::atomic<int> _produced_pages{ 0 };
	std::atomic<uint64_t> _produced_usec{ 0 };
	std::atomic<uint64_t> _prime_insert_us{ 0 };
	std::atomic<int> _prime_inserted{ 0 }, _prime_wakes{ 0 };
	std::atomic<uint64_t> _retain_lock_us{ 0 }, _retain_index_us{ 0 };
	std::atomic<int> _stat_hits{ 0 }, _stat_rect_mismatch{ 0 }, _stat_discarded{ 0 };
	Dictionary _cell_cache;
	std::shared_ptr<const Snapshot> _signature_source;
	uint32_t _signature_materials = 0;
	real_t _signature_density = 0;
	std::map<std::pair<int, int>, uint32_t> _signatures;
	uint64_t _cache_bytes = 0;
	Result produce(const Request &request, const std::shared_ptr<const Snapshot> &p_source);
	void load_cells(const Request &request, const std::shared_ptr<const Snapshot> &p_source, Result &result);
};
