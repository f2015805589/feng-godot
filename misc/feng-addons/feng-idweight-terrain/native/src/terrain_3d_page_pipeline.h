#pragma once
#include "terrain_3d_data.h"
#include <array>
#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <thread>
#include <functional>
#include <utility>

namespace TerrainVT { struct VisibleView; struct VisiblePatch; }

// Worker owns only immutable source bytes. No scene, terrain, or renderer calls.
class Terrain3DPagePipeline {
public:
	using Key = std::array<int, 5>;
	// The steady window: one queue slot holds a prepared payload of a few hundred kilobytes, so
	// the queue is kept shallow while a view is streaming normally. `MAX_QUEUE_CAPACITY` is the
	// window a cold-view burst may raise it to - the same payload, admitted at the rate the burst
	// asks for - and it is what `ReadyKeys` is sized for, because a snapshot taken while the burst
	// runs has to describe the window the burst filled.
	static constexpr size_t QUEUE_CAPACITY = 32;
	static constexpr size_t MAX_QUEUE_CAPACITY = 256;
	// Payloads a worker may still have to release. Every deferred page holds one page-sized image
	// (a couple of hundred kilobytes), so the bound is what keeps a queue nobody drains - every
	// worker parked on a settled view - from being a leak.
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
	// A bounded value snapshot: consumers poll only results ready at the start
	// of their pass. No queue storage or lock escapes the pipeline.
	ReadyKeys ready_keys();
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
	// How long the last `prime` spent building its entries and how long it spent waking workers.
	// The demand pass calls prime twice on every tick, and it is one of the largest stages of a
	// peak pass; these two are what says whether the cost is the queue's own work or the syscalls
	// that start the workers.
	void get_prime_stats(int64_t &r_insert_us, int64_t &r_wake_us) {
		r_insert_us = int64_t(_prime_insert_us.load(std::memory_order_relaxed));
		r_wake_us = int64_t(_prime_wake_us.load(std::memory_order_relaxed));
	}
	void get_prime_counts(int &r_inserted, int &r_wakes) {
		r_inserted = _prime_inserted.load(std::memory_order_relaxed);
		r_wakes = _prime_wakes.load(std::memory_order_relaxed);
	}
	// How the last `retain` split between waiting for the queue and comparing its entries. The
	// stage is the largest one a plan install pays, and the two halves have nothing in common:
	// waiting is worker contention on the queue's mutex, comparing is this thread's own work.
	void get_retain_stats(int64_t &r_lock_us, int64_t &r_index_us) {
		r_lock_us = int64_t(_retain_lock_us.load(std::memory_order_relaxed));
		r_index_us = int64_t(_retain_index_us.load(std::memory_order_relaxed));
	}
	// How many requests a worker could still claim right now. Lock free.
	int claimable_count() const { return _claimable_count.load(std::memory_order_relaxed); }
	// The depth of the queue window. A cold-view burst raises it so the workers may hold a burst's
	// worth of prepared pages instead of the steady window's, which is what lets one pass consume
	// more than `QUEUE_CAPACITY` prepared pages; a settled or moving view leaves it at the steady
	// window and pays the shallow queue's scan cost. Bounded by `MAX_QUEUE_CAPACITY`, which is what
	// `ReadyKeys` holds.
	void set_queue_limit(int p_limit) {
		_queue_limit.store(CLAMP(p_limit, int(QUEUE_CAPACITY), int(MAX_QUEUE_CAPACITY)), std::memory_order_relaxed);
	}
	int get_queue_limit() const { return _queue_limit.load(std::memory_order_relaxed); }
	// Hands a payload the demand thread has finished with to the source workers, which destroy it
	// between jobs. A produced page replaces the payload it held, and releasing that one is not a
	// refcount any more: it destroys an `Image`, which takes the object database's lock - the same
	// lock every source worker takes to *create* the payloads it assembles - and on the demanding
	// thread that measured as an 11 us stall per produced page, at the page's own handoff, against
	// 4 us for the whole publish once it was moved. It is deferred rather than avoided: the payload
	// is dead either way, and the worker that releases it is a thread with slack while the demand
	// thread is the one the frame is waiting on.
	//
	// The demand thread only *stages* here. `flush_releases()` publishes the stage once, at the end
	// of the tick, because a lock per page is the contention this exists to remove: with every
	// worker draining, the mutex measured 2.2 us a page on the demanding thread - a smaller copy of
	// the stall it was introduced to remove. Nothing else touches the stage, so it needs no lock.
	//
	// Returns false when the stage is full, which means no worker has drained the published queue
	// for a while (every one parked on a settled view); the caller's own release is then the
	// answer, so a queue no one drains cannot grow without bound.
	bool defer_release(const Ref<godot::Image> &p_payload);
	// Publishes whatever the demand thread staged, once per tick. Called from the tick's own
	// "wakes owed" flush, so it runs whichever view is active.
	void flush_releases();
	// Wakes the workers for the work submitted since the last call. The demand pass calls this when
	// it is finished rather than in the middle of itself: a worker woken inside a measured phase
	// starts competing for this thread's cores, so the phase reads as its own cost when what it
	// actually contains is a partially descheduled main thread. Nothing is lost by waiting - the
	// work submitted this pass cannot be assembled within it in any case - and the pages the
	// previous pass submitted have had a whole frame to be assembled in.
	void flush_wakes() {
		const int pending = _pending_wakes.exchange(0, std::memory_order_relaxed);
		for (int i = 0; i < pending; ++i) { _wake.notify_one(); }
	}
private:
	struct Entry { Request request; std::shared_ptr<const Snapshot> source; Result result; uint64_t token; bool running = false, ready = false, retained = false; };
	// `retain` asks one question per queue entry - is this entry in the wanted set - so the
	// wanted set is indexed by the same key the entry carries. Three forms have been measured
	// here. The first asked `_index_of()` once per *request*, a linear scan of the queue:
	// retaining a 250 page plan against the queue compared tens of thousands of keys. A sorted
	// vector halves the comparisons but pays a sort of the whole plan on every install, which
	// measured larger than the scan it replaced. A `std::unordered_map` is worse again: one node
	// allocation per wanted page. A flat open-addressed table is built in place, keeps its
	// capacity, and answers in one probe: only the entry's footprint is compared afterwards.
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
	std::vector<Key> _retain_keys;
	std::vector<uint32_t> _retain_slots;
	size_t _retain_capacity = 0;
	// The queue is a flat array, not a `std::map`, and the claim order is a flat FIFO, not a
	// `std::set`. The window is 32 entries, so a linear search of it is a few hundred nanoseconds;
	// what a node-based container costs instead is an allocation per insert, and `prime` inserts
	// the whole refill under the queue mutex on every tick - measured at 8-18 us per insert with
	// two allocations in the path, against a few hundred nanoseconds of actual comparison. The
	// tokens ascend with insertion, so the FIFO is exactly the claim order: submission priority
	// without a second container to keep it in.
	std::vector<Entry> _entries;
	std::vector<Key> _claim_order;
	// Index into `_claim_order` of the first key not yet considered. Keys of entries that were
	// erased before being claimed are skipped where they are found rather than removed from the
	// middle of the vector, and the prefix is dropped once it is long enough to be worth the move.
	size_t _claim_head = 0;
	std::mutex _mutex;
	std::condition_variable _wake, _task_wake;
	// Payloads the demand thread handed over. The stage is written only by the demanding thread and
	// needs no lock; the queue beside it is published by `flush_releases()` and drained by the
	// workers, which is why it has one. Destroying a payload happens outside both, on the draining
	// worker, because that is exactly the work this exists to keep off the demanding thread's path.
	std::vector<Ref<godot::Image>> _release_staging;
	std::mutex _release_mutex;
	std::vector<Ref<godot::Image>> _released;
	// How many payloads are published and not yet drained. Read without the lock, so a worker with
	// nothing to drain does not take it at all.
	std::atomic<int> _released_count{ 0 };
	// Releases whatever is published on this thread. Called at the top of a worker's loop, so the
	// cost lands between two pages rather than on the frame.
	void _drain_released();
	// Stages one payload. Called only by the demanding thread, from inside the queue's own critical
	// sections, so it must not take a lock of its own.
	bool _stage_release(const Ref<godot::Image> &p_payload);
	// Hands a queue entry's prepared images to the workers before the entry is dropped. Every path
	// that erases an entry - `retain` dropping the demand a plan no longer names, `_make_room`, a
	// cancel - would otherwise destroy three page-sized `Image`s on the demanding thread inside the
	// queue's own critical section, which is what made one `retain` call measure 0.67 ms.
	void _defer_result_release(Result &r_result);
	// How many entries are neither in progress nor finished, i.e. the work a sleeping worker could
	// still claim, readable without the lock so the demand pass can decide whether a refill is
	// worth taking the queue mutex for.
	std::atomic<int> _claimable_count{ 0 };
	// Wakes owed to the workers, released by flush_wakes() at the end of the producing pass.
	std::atomic<int> _pending_wakes{ 0 };
	// The live queue window. It has one writer, the demand pass that arms or ends a cold-view
	// burst, and every reader takes it relaxed: a pass that saw the previous window for one tick
	// is still correct, it just has one tick of the old depth.
	std::atomic<int> _queue_limit{ int(QUEUE_CAPACITY) };
	// How many workers are parked in `wait`. A batch only wakes a worker that is asleep, and
	// a wake is a syscall: waking one worker per entry added was thirty-two of them on a
	// demand pass whose workers were all busy anyway.
	int _waiters = 0;
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
	// Called with `_mutex` held: the index of the entry for a key, or -1.
	int _index_of(const Key &p_key) const;
	// Called with `_mutex` held: removes the entry at an index. The last entry takes its place,
	// and an entry that was still claimable is accounted for. Nothing holds an index across this.
	void _erase_at(int p_index);
	// Called with `_mutex` held: how many entries are neither running nor finished.
	int _count_claimable() const;
	// Locks the queue from the demanding thread, so the acquisition has one place to be changed if
	// it is ever worth changing. See the definition.
	void _lock_queue(std::unique_lock<std::mutex> &r_lock);
	// Guards the per-job source caches below: every worker assembles its own page, so
	// the decode caches are shared state now rather than a single thread's locals.
	std::mutex _cache_mutex;
	std::atomic<int> _produced_pages{ 0 };
	std::atomic<uint64_t> _produced_usec{ 0 };
	std::atomic<uint64_t> _prime_insert_us{ 0 }, _prime_wake_us{ 0 };
	std::atomic<int> _prime_inserted{ 0 }, _prime_wakes{ 0 };
	std::atomic<uint64_t> _retain_lock_us{ 0 }, _retain_index_us{ 0 };
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
