// Engine-boundary doubles only; production headers and complete bodies are included below.
#include <algorithm>
#include <array>
#include <atomic>
#include <cassert>
#include <condition_variable>
#include <deque>
#include <functional>
#include <iostream>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <tuple>
#include <vector>
#include "terrain_vt.h"
#define MAX(a, b) std::max(a, b)
#define MIN(a, b) std::min(a, b)
#define CLAMP(v, lo, hi) std::clamp(v, lo, hi)
#define WARN_PRINT(...)
using real_t = float;
namespace godot {
struct RID { int id = 0; bool is_valid() const { return id != 0; } };
struct Vector2 { float x = 0, y = 0; };
struct Vector3 {};
struct Vector2i { int x, y; Vector2i(int a, int b) : x(a), y(b) {} };
struct Rect2 {
	int identity = 0;
	bool operator==(Rect2 other) const { return identity == other.identity; }
	bool operator!=(Rect2 other) const { return !(*this == other); }
};
struct String : std::string { using std::string::string; };
struct Dictionary {
	struct Value { template <class T> void operator=(const T &) {} };
	Value operator[](const char *) { return {}; }
};
using Array = std::vector<Dictionary>;
using PackedByteArray = std::vector<uint8_t>;
template <class T> struct Ref {
	std::shared_ptr<T> value;
	Ref() = default;
	Ref(const Ref &) = default; // Like Godot Ref, rvalue assignment also copies.
	Ref &operator=(const Ref &) = default;
	T *operator->() const { return value.get(); }
	bool is_null() const { return !value; }
	bool is_valid() const { return bool(value); }
	void unref() { value.reset(); }
};
struct Image {
	enum Format { FORMAT_R8, FORMAT_RH, FORMAT_RF, FORMAT_RGBA8, FORMAT_R16 = 39, FORMAT_MAX = 40 };
	int width = 0, height = 0;
	Format format = FORMAT_MAX;
	int get_width() const { return width; }
	int get_height() const { return height; }
	Format get_format() const { return format; }
	static Ref<Image> create_from_data(int w, int h, bool, Format f, const PackedByteArray &) {
		Ref<Image> image; image.value = std::make_shared<Image>(Image{w, h, f}); return image;
	}
};
struct Time {
	static Time *get_singleton() { static Time time; return &time; }
	uint64_t get_ticks_usec() { return 0; }
};
} // namespace godot
using namespace godot;
constexpr Image::Format IDWEIGHT_IMAGE_FORMAT = Image::Format(39);
struct GeneratedTexture {
	int layers = 0, writes = 0;
	RID get_rid() const { return {layers}; }
	int get_layer_count() const { return layers; }
	bool ensure_layers(const Ref<Image> &, int count) { layers = count; return true; }
	void clear() { layers = 0; }
	void update(const Ref<Image> &, int) { ++writes; }
};
struct Server { Ref<Image> texture_2d_layer_get(RID, int) { return {}; } } server;
#define RS (&server)
class Terrain3DData;
#define private public
#include "terrain_3d_vt_page_pool.h.inc"
#include "terrain_3d_page_pipeline.h.inc"
#undef private
class Terrain3DVirtualTexture {
public:
	std::shared_ptr<Terrain3DVTPagePool> _page_pool;
	std::map<std::tuple<int, int, int>, uint32_t> table;
	int _hit_count = 0, _miss_count = 0;
	static constexpr uint32_t INVALID_SLOT = TerrainVT::INVALID_PHYSICAL_PAGE_SLOT;
	explicit Terrain3DVirtualTexture(std::shared_ptr<Terrain3DVTPagePool> pool) : _page_pool(pool) {}
	int get_level_size(int mip) const { return 32 >> mip; }
	uint32_t _read_level(int x, int y, int mip) const {
		auto found = table.find({x, y, mip}); return found == table.end() ? INVALID_SLOT : found->second;
	}
	void _write_level(int x, int y, int mip, uint32_t slot) { table[{x, y, mip}] = slot; }
	void _invalidate_pool_owner(uint32_t, const Terrain3DVTPageOwner &);
	int _request_virtual(int, int, int, int, const Terrain3DVTPageOwner &, bool *);
	void protect_page(int, bool);
	bool is_page_protected(int) const;
#ifdef HAS_POOL_TRANSACTIONS
	void _touch_slot(uint32_t slot) { _page_pool->touch_slot(slot); }
	int _acquire_slot() { return _page_pool->acquire_slot(this); }
#endif
	int request(int x, bool reserved = false) {
		Terrain3DVTPageOwner owner; owner.reserved = reserved;
		return _request_virtual(x, 0, 0, 3, owner, nullptr);
	}
};
#include "terrain_3d_vt_page_pool.cpp.inc"
#include "methods.inc"
// No source threads: tests drive pending/running/ready transitions under a deterministic schedule.
Terrain3DPagePipeline::Terrain3DPagePipeline(int) {}
Terrain3DPagePipeline::~Terrain3DPagePipeline() = default;

static void pool_lifecycle() {
	auto pool = std::make_shared<Terrain3DVTPagePool>();
	assert(pool->initialize(2, 0, 2, Image::FORMAT_RF));
	Terrain3DVirtualTexture near(pool), far(pool);
	pool->set_allocation_budget(0);
	assert(near.request(0) == -1 && pool->free_slots.size() == 2);
	pool->set_allocation_budget(1);
	assert(near.request(-1) == -1 && pool->allocation_budget == 1); // Rejection precedes allocation.
	assert(near.request(0) == 0 && pool->allocation_budget == 0);
	assert(near.request(0) == 0 && near._hit_count == 1); // Hits do not spend the budget.
	assert(far.request(1) == -1);
	pool->set_allocation_budget(-1);
	assert(far.request(1) == 1);
	Terrain3DVTPageOwner alias; alias.texture = &far; alias.virtual_x = 7;
	far._write_level(7, 0, 0, 0); pool->publish_owner(0, alias); pool->publish_owner(0, alias);
	assert(pool->slot_owners[0].size() == 2); // Duplicate publication is idempotent.
	near.protect_page(0, true); far.protect_page(0, true); near.protect_page(0, false);
	assert(near.is_page_protected(0));
	assert(near.request(2) == 1 && far._read_level(1, 0, 0) == TerrainVT::INVALID_PHYSICAL_PAGE_SLOT);
	far.protect_page(0, false); far.protect_page(0, false);
	assert(!near.is_page_protected(0));
	assert(near.request(3) == 0);
	assert(near._read_level(0, 0, 0) == TerrainVT::INVALID_PHYSICAL_PAGE_SLOT);
	assert(far._read_level(7, 0, 0) == TerrainVT::INVALID_PHYSICAL_PAGE_SLOT);
	pool->begin_demand(); pool->touch_slot(1); pool->touch_slot(0);
	assert(near.request(4) == -1); pool->end_demand(); pool->begin_demand();
	assert(near.request(4) == -1); pool->end_demand(); pool->begin_demand();
	assert(near.request(4, true) == 1); pool->end_demand();
	assert(pool->count_reserved_slots() == 1 && near.request(5) == 0);
	pool->detach_texture(&far); // A sibling leaving cannot free near's pages.
	assert(pool->free_slots.empty());
	pool->authored_pages[0] = Image::create_from_data(2, 2, false, Image::FORMAT_RF, {});
	assert(pool->write_page(0, pool->authored_pages[0]));
	assert(pool->remove_owner(0, &near, 5, 0, 0));
	assert(pool->authored_pages[0].is_null() && pool->free_slots.size() == 1);
	pool->detach_texture(&near); pool->detach_texture(&near);
	assert(pool->free_slots.size() == 2 && pool->count_reserved_slots() == 0);
	assert(!pool->write_page(0, Image::create_from_data(2, 2, false, Image::FORMAT_RF, {})));
	assert(near.request(6) == 1);
	assert(pool->grow(4) && pool->free_slots.size() == 4);
	assert(near._read_level(6, 0, 0) == TerrainVT::INVALID_PHYSICAL_PAGE_SLOT);
	pool->clear(); pool->clear(); assert(!pool->is_initialized());
}

static void queue_lifecycle() {
	using Pipeline = Terrain3DPagePipeline;
	Pipeline queue;
	std::vector<Pipeline::Request> requests(64);
	for (int i = 0; i < 64; ++i) { requests[i].key = {i, i * 1024, 0, 0, 0}; requests[i].size = 8; requests[i].border = 1; }
	for (int cycle = 0; cycle < 20; ++cycle) {
		queue.prime(requests, {});
		assert(queue.claimable_count() == 32 && queue._entries.size() == 32);
		queue.prime(requests, {}); assert(queue.claimable_count() == 32);
		// Stand in for two worker claims and one completion; production erasure must
		// account only for pending work and preserve completed payloads across moves.
		queue._entries[0].running = true; queue._entries[0].ready = true;
		queue._entries[1].running = true; queue._claimable_count.fetch_sub(2);
		queue._entries[0].result.payload = Image::create_from_data(2, 2, false, Image::FORMAT_RF, {});
		std::weak_ptr<Image> payload = queue._entries[0].result.payload.value;
		auto changed = requests[0]; changed.rect.identity = 10;
		Pipeline::Result result;
		assert(!queue.poll(changed, {}, result)); // A moved footprint cannot consume a ready result.
		assert(queue.ready_keys().contains(requests[0].key));
		queue.discard(requests[1].key); assert(queue._entries.size() == 32); // Running work stays.
		queue.cancel(requests[1].key); assert(queue.claimable_count() == 30);
		queue.cancel(requests[31].key); assert(queue.claimable_count() == 29);
		assert(queue.poll(requests[0], {}, result) && result.payload.is_valid());
		assert(!payload.expired() && queue._release_staging.empty());
		result = {}; assert(payload.expired());
		std::vector<Pipeline::Request> retained(requests.begin() + 2, requests.begin() + 10);
		retained[0].size++; retained[1].border++; retained.push_back(retained.back());
		queue.retain(retained);
		assert(queue._entries.size() == 6 && queue.claimable_count() == 6);
		assert(queue.claimable_count() == queue._count_claimable());
		queue.retain({}); assert(queue._entries.empty() && queue.claimable_count() == 0);
		assert(!queue.poll(requests[0], {}, result) && queue.claimable_count() == 1);
		queue.cancel(requests[0].key); assert(queue._entries.empty() && queue.claimable_count() == 0);
		queue.reset();
	}
	queue.set_queue_limit(1000); queue.prime(requests, {});
	assert(queue.get_queue_limit() == 256 && queue.claimable_count() == 64);
	queue._entries[0].running = queue._entries[0].ready = true; queue._claimable_count.fetch_sub(1);
	queue._entries[0].result.payload = Image::create_from_data(2, 2, false, Image::FORMAT_RF, {});
	std::weak_ptr<Image> dropped = queue._entries[0].result.payload.value;
	queue.discard(requests[0].key); assert(!dropped.expired());
	queue.flush_releases(); assert(!dropped.expired()); queue._drain_released(); assert(dropped.expired());
	queue.reset(); assert(queue.claimable_count() == 0);
	Ref<Image> image = Image::create_from_data(2, 2, false, Image::FORMAT_RF, {});
	for (size_t i = 0; i < Pipeline::RELEASE_QUEUE_LIMIT; ++i) { assert(queue.defer_release(image)); }
	assert(!queue.defer_release(image)); queue.flush_releases();
	assert(queue._released.size() == Pipeline::RELEASE_QUEUE_LIMIT);
	assert(queue.defer_release(image)); queue.flush_releases(); // Overflow drops locally.
	assert(queue._released.size() == Pipeline::RELEASE_QUEUE_LIMIT && queue._release_staging.empty());
	queue._drain_released(); assert(queue._released.empty());
}

int main() {
	pool_lifecycle(); queue_lifecycle();
	std::cout << "PASS native pool ownership, allocation and queue lifecycle (20 churn cycles)\n";
}
