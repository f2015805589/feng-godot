// Sparse, render-thread uploads for a CPU-authored VT page table.
#pragma once
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <mutex>
#include <atomic>
#include <map>
#include <tuple>
#include <vector>

using namespace godot;
class Terrain3DVTIndirection : public RefCounted {
	GDCLASS(Terrain3DVTIndirection, RefCounted);
public:
	struct Patch { int mip, x, y, width, height; PackedByteArray bytes; };
private:
	mutable std::mutex _mutex;
	RID _texture_rd, _texture_rs;
	RID _scatter_shader, _scatter_pipeline, _scatter_buffer, _scatter_set;
	std::vector<RID> _mip_views;
	uint32_t _scatter_capacity = 0;
	bool _prepare_scatter(uint32_t p_bytes);
	int _size = 0, _levels = 0;
	PackedByteArray _initial;
	// Patches are complete, disjoint tiles. Only the latest contents of a tile
	// matter if several CPU commits arrive before the render thread consumes them.
	using PatchKey = std::tuple<int, int, int>;
	std::map<PatchKey, Patch> _pending;
	RID _atlas;
	std::map<int, Ref<Image>> _layers;
	std::atomic<bool> _layers_pending{false};
	bool _queued = false;
	std::atomic<bool> _retry_needed{false};
	void _restore(std::map<PatchKey, Patch> p_patches, const PackedByteArray &p_initial = PackedByteArray());
	void _upload(const Ref<Terrain3DVTIndirection> &p_keep_alive);
	static void _free(RID p_rd, RID p_rs, const Array &p_resources);
protected:
	static void _bind_methods() {}
public:
	~Terrain3DVTIndirection();
	void initialize(int p_size, int p_levels, const PackedByteArray &p_bytes);
	void submit(std::vector<Patch> p_patches);
	void queue_layer(RID p_atlas, int p_slot, const Ref<Image> &p_image);
	bool has_pending_layers() const { return _layers_pending.load(std::memory_order_relaxed); }
	bool needs_retry() const { return _retry_needed.load(std::memory_order_relaxed); }
	RID get_rid() const;
};
