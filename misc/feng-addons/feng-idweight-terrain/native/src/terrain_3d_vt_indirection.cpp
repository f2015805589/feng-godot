#include "terrain_3d_vt_indirection.h"
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/classes/rd_texture_format.hpp>
#include <godot_cpp/classes/rd_texture_view.hpp>
#include <godot_cpp/variant/callable_method_pointer.hpp>

void Terrain3DVTIndirection::_free(RID p_rd, RID p_rs) {
	RenderingServer *server = RenderingServer::get_singleton();
	if (!server) { return; }
	if (p_rs.is_valid()) { server->free_rid(p_rs); }
	RenderingDevice *rd = server->get_rendering_device();
	if (rd && p_rd.is_valid()) { rd->free_rid(p_rd); }
}
Terrain3DVTIndirection::~Terrain3DVTIndirection() {
	RenderingServer *server = RenderingServer::get_singleton();
	if (!server || (!_texture_rd.is_valid() && !_texture_rs.is_valid())) { return; }
	if (server->is_on_render_thread()) { _free(_texture_rd, _texture_rs); }
	else { server->call_on_render_thread(callable_mp_static(&Terrain3DVTIndirection::_free).bind(_texture_rd, _texture_rs)); }
}
RID Terrain3DVTIndirection::get_rid() const {
	std::lock_guard<std::mutex> lock(_mutex);
	return _texture_rs;
}
void Terrain3DVTIndirection::initialize(int p_size, int p_levels, const PackedByteArray &p_bytes) {
	_size = p_size; _levels = p_levels; _initial = p_bytes;
	submit({});
}
void Terrain3DVTIndirection::submit(std::vector<Patch> p_patches) {
	{
		std::lock_guard<std::mutex> lock(_mutex);
		for (Patch &patch : p_patches) {
			const PatchKey key(patch.mip, patch.x, patch.y);
			_pending.insert_or_assign(key, std::move(patch));
		}
		if (_queued) { return; }
		_queued = true;
		_retry_needed.store(false, std::memory_order_relaxed);
	}
	RenderingServer::get_singleton()->call_on_render_thread(callable_mp(this, &Terrain3DVTIndirection::_upload).bind(Ref<Terrain3DVTIndirection>(this)));
}
void Terrain3DVTIndirection::_restore(std::map<PatchKey, Patch> p_patches, const PackedByteArray &p_initial) {
	std::lock_guard<std::mutex> lock(_mutex);
	if (!p_initial.is_empty()) { _initial = p_initial; }
	for (auto &entry : p_patches) {
		// A newer CPU commit wins over a failed older upload of the same tile.
		_pending.try_emplace(entry.first, std::move(entry.second));
	}
	// Retry on a later commit, not recursively on the render thread.
	_retry_needed.store(true, std::memory_order_relaxed);
}
void Terrain3DVTIndirection::_upload(const Ref<Terrain3DVTIndirection> &p_keep_alive) {
	RenderingServer *server = RenderingServer::get_singleton();
	RenderingDevice *rd = server->get_rendering_device();
	std::map<PatchKey, Patch> patches;
	PackedByteArray initial;
	{
		std::lock_guard<std::mutex> lock(_mutex);
		patches.swap(_pending); initial = _initial; _initial.clear(); _queued = false;
	}
	if (!rd) {
		_restore(std::move(patches), initial);
		return;
	}
	Ref<RDTextureView> view; view.instantiate();
	if (!_texture_rd.is_valid()) {
		Ref<RDTextureFormat> format; format.instantiate();
		format->set_texture_type(RenderingDevice::TEXTURE_TYPE_2D);
		format->set_format(RenderingDevice::DATA_FORMAT_R32_SFLOAT);
		format->set_width(_size); format->set_height(_size); format->set_mipmaps(_levels);
		format->set_usage_bits(RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice::TEXTURE_USAGE_CAN_COPY_TO_BIT | RenderingDevice::TEXTURE_USAGE_CAN_COPY_FROM_BIT);
		TypedArray<PackedByteArray> data; data.push_back(initial);
		_texture_rd = rd->texture_create(format, view, data);
		if (!_texture_rd.is_valid()) {
			_restore(std::move(patches), initial);
			return;
		}
		RID texture_rs = server->texture_rd_create(_texture_rd);
		if (!texture_rs.is_valid()) {
			rd->free_rid(_texture_rd);
			_texture_rd = RID();
			_restore(std::move(patches), initial);
			return;
		}
		std::lock_guard<std::mutex> lock(_mutex);
		_texture_rs = texture_rs;
	}
	std::map<PatchKey, Patch> failed;
	for (auto &entry : patches) {
		const Patch &patch = entry.second;
		Ref<RDTextureFormat> format; format.instantiate();
		format->set_texture_type(RenderingDevice::TEXTURE_TYPE_2D);
		format->set_format(RenderingDevice::DATA_FORMAT_R32_SFLOAT);
		format->set_width(patch.width); format->set_height(patch.height);
		format->set_usage_bits(RenderingDevice::TEXTURE_USAGE_CAN_COPY_FROM_BIT);
		TypedArray<PackedByteArray> data; data.push_back(patch.bytes);
		RID source = rd->texture_create(format, view, data);
		if (!source.is_valid()) {
			failed.emplace(entry.first, std::move(entry.second));
			continue;
		}
		const Error error = rd->texture_copy(source, _texture_rd, Vector3(), Vector3(patch.x, patch.y, 0), Vector3(patch.width, patch.height, 1), 0, patch.mip, 0, 0);
		rd->free_rid(source); // RD defers destruction until in-flight copies complete.
		if (error != OK) { failed.emplace(entry.first, std::move(entry.second)); }
	}
	if (!failed.empty()) { _restore(std::move(failed)); }
}
