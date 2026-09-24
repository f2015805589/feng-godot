#include "terrain_3d_vt_indirection.h"
#include "terrain_vt.h"
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/classes/rd_texture_format.hpp>
#include <godot_cpp/classes/rd_texture_view.hpp>
#include <godot_cpp/classes/rd_shader_source.hpp>
#include <godot_cpp/classes/rd_shader_spirv.hpp>
#include <godot_cpp/classes/rd_uniform.hpp>
#include <cstring>
#include <godot_cpp/variant/callable_method_pointer.hpp>

void Terrain3DVTIndirection::_free(RID p_rd, RID p_rs, const Array &p_resources) {
	RenderingServer *server = RenderingServer::get_singleton();
	if (!server) { return; }
	if (p_rs.is_valid()) { server->free_rid(p_rs); }
	RenderingDevice *rd = server->get_rendering_device();
	if (rd) {
		for (const RID &resource : p_resources) { if (resource.is_valid()) { rd->free_rid(resource); } }
		if (p_rd.is_valid()) { rd->free_rid(p_rd); }
	}
}
Terrain3DVTIndirection::~Terrain3DVTIndirection() {
	RenderingServer *server = RenderingServer::get_singleton();
	if (!server || (!_texture_rd.is_valid() && !_texture_rs.is_valid())) { return; }
	Array resources;
	for (RID rid : {_scatter_set, _scatter_pipeline, _scatter_shader, _scatter_buffer}) { resources.push_back(rid); }
	for (RID rid : _mip_views) { resources.push_back(rid); }
	if (server->is_on_render_thread()) { _free(_texture_rd, _texture_rs, resources); }
	else { server->call_on_render_thread(callable_mp_static(&Terrain3DVTIndirection::_free).bind(_texture_rd, _texture_rs, resources)); }
}
RID Terrain3DVTIndirection::get_rid() const {
	std::lock_guard<std::mutex> lock(_mutex);
	return _texture_rs;
}
void Terrain3DVTIndirection::initialize(int p_size, int p_levels, const PackedByteArray &p_bytes) {
	_size = p_size; _levels = p_levels; _initial = p_bytes;
	submit({});
}
void Terrain3DVTIndirection::queue_layer(RID p_atlas, int p_slot, const Ref<Image> &p_image) {
	std::lock_guard<std::mutex> lock(_mutex);
	_atlas = p_atlas;
	_layers.insert_or_assign(p_slot, p_image);
	_layers_pending.store(true, std::memory_order_relaxed);
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
bool Terrain3DVTIndirection::_prepare_scatter(uint32_t p_bytes) {
	RenderingDevice *rd = RenderingServer::get_singleton()->get_rendering_device();
	if (!_scatter_shader.is_valid()) {
		Ref<RDShaderSource> source; source.instantiate();
		source->set_stage_source(RenderingDevice::SHADER_STAGE_COMPUTE, String("#version 450\n#define MIPS ") + String::num_int64(_levels) + R"(
layout(local_size_x=16,local_size_y=16,local_size_z=1) in;
layout(set=0,binding=0,r32f) uniform writeonly image2D destination[MIPS];
layout(set=0,binding=1,std430) readonly buffer Updates { uint words[]; } updates;
void main() {
 uint base=gl_WorkGroupID.z*260u;
 uint mip=updates.words[base];
 uvec2 size=uvec2(updates.words[base+3u]&65535u,updates.words[base+3u]>>16u);
 uvec2 local=gl_LocalInvocationID.xy;
 if(any(greaterThanEqual(local,size))) return;
 ivec2 origin=ivec2(updates.words[base+1u],updates.words[base+2u]);
 float slot=uintBitsToFloat(updates.words[base+4u+local.y*size.x+local.x]);
 imageStore(destination[mip],origin+ivec2(local),vec4(slot));
}
)");
		Ref<RDShaderSPIRV> spirv = rd->shader_compile_spirv_from_source(source);
		if (spirv.is_null()) { ERR_PRINT_ONCE("Terrain VT page-table shader compilation returned no SPIR-V."); return false; }
		const String error = spirv->get_stage_compile_error(RenderingDevice::SHADER_STAGE_COMPUTE);
		if (!error.is_empty()) { ERR_PRINT_ONCE(error); return false; }
		_scatter_shader = rd->shader_create_from_spirv(spirv, "terrain_vt_page_table_scatter");
		if (!_scatter_shader.is_valid()) { return false; }
		_scatter_pipeline = rd->compute_pipeline_create(_scatter_shader);
		Ref<RDTextureView> view; view.instantiate();
		for (int mip = 0; mip < _levels; ++mip) { _mip_views.push_back(rd->texture_create_shared_from_slice(view, _texture_rd, 0, mip)); }
	}
	if (!_scatter_pipeline.is_valid()) { return false; }
	if (p_bytes > _scatter_capacity) {
		if (_scatter_set.is_valid()) { rd->free_rid(_scatter_set); _scatter_set = RID(); }
		if (_scatter_buffer.is_valid()) { rd->free_rid(_scatter_buffer); }
		_scatter_capacity = 65536;
		while (_scatter_capacity < p_bytes) { _scatter_capacity *= 2; }
		_scatter_buffer = rd->storage_buffer_create(_scatter_capacity);
	}
	if (!_scatter_buffer.is_valid()) { return false; }
	if (!_scatter_set.is_valid()) {
		TypedArray<RDUniform> uniforms;
		Ref<RDUniform> images; images.instantiate();
		images->set_uniform_type(RenderingDevice::UNIFORM_TYPE_IMAGE); images->set_binding(0);
		for (RID mip : _mip_views) { if (!mip.is_valid()) { return false; } images->add_id(mip); }
		uniforms.push_back(images);
		Ref<RDUniform> buffer; buffer.instantiate();
		buffer->set_uniform_type(RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER); buffer->set_binding(1); buffer->add_id(_scatter_buffer);
		uniforms.push_back(buffer);
		_scatter_set = rd->uniform_set_create(uniforms, _scatter_shader, 0);
	}
	return _scatter_set.is_valid();
}
void Terrain3DVTIndirection::_upload(const Ref<Terrain3DVTIndirection> &p_keep_alive) {
	RenderingServer *server = RenderingServer::get_singleton();
	RenderingDevice *rd = server->get_rendering_device();
	std::map<PatchKey, Patch> patches;
	std::map<int, Ref<Image>> layers;
	RID atlas;
	PackedByteArray initial;
	{
		std::lock_guard<std::mutex> lock(_mutex);
		patches.swap(_pending); layers.swap(_layers); atlas = _atlas;
		_layers_pending.store(false, std::memory_order_relaxed); initial = _initial; _initial.clear(); _queued = false;
	}
	if (!rd) {
		for (const auto &layer : layers) { queue_layer(atlas, layer.first, layer.second); }
		_restore(std::move(patches), initial);
		return;
	}
	// Upload layer data on the render thread, before publishing its page-table patches.
	for (const auto &layer : layers) { server->texture_2d_update(atlas, layer.second, layer.first); }
	Ref<RDTextureView> view; view.instantiate();
	if (!_texture_rd.is_valid()) {
		// A view that was cleared before it was configured has no page table to publish.
		// Creating one for zero levels is what produced an empty initial slice, an invalid
		// texture RID, and a permanently broken page table that every later commit retried.
		if (_size <= 0 || _levels <= 0) {
			_restore(std::move(patches), initial);
			return;
		}
		// The RD binding rejects an empty data slice and returns an invalid RID, so a
		// texture created before its first CPU commit gets an explicitly cleared page
		// table: every slot invalid, which is the state a table with no published page
		// is in anyway. Passing no data at all would leave the format uninitialized and
		// let the sampler read garbage slot indices.
		PackedByteArray cleared;
		if (initial.is_empty()) {
			// The same chain shape the page table's owner builds (TerrainVT::indirection_*): the
			// cleared table has to have exactly the texels and levels that one does, or the device
			// would be handed a slice the CPU table later disagrees with.
			const int64_t texels = TerrainVT::indirection_total_texels(_size, _levels);
			cleared.resize(texels * 4);
			TerrainVT::fill_indirection_cleared(cleared.ptrw(), texels);
		}
		Ref<RDTextureFormat> format; format.instantiate();
		format->set_texture_type(RenderingDevice::TEXTURE_TYPE_2D);
		format->set_format(RenderingDevice::DATA_FORMAT_R32_SFLOAT);
		format->set_width(_size); format->set_height(_size); format->set_mipmaps(_levels);
		format->set_usage_bits(RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice::TEXTURE_USAGE_STORAGE_BIT | RenderingDevice::TEXTURE_USAGE_CAN_COPY_TO_BIT | RenderingDevice::TEXTURE_USAGE_CAN_COPY_FROM_BIT);
		TypedArray<PackedByteArray> data; data.push_back(initial.is_empty() ? cleared : initial);
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
	// One persistent buffer and one scatter dispatch replace one staging texture,
	// copy command and resource destruction for every dirty tile.
	const uint32_t bytes = uint32_t(patches.size()) * 260 * 4;
	if (!_prepare_scatter(MAX(1u, bytes))) { _restore(std::move(patches)); return; }
	if (patches.empty()) { return; }
	PackedByteArray updates; updates.resize(bytes); updates.fill(0);
	uint8_t *output = updates.ptrw();
	for (const auto &entry : patches) {
		const Patch &patch = entry.second;
		const uint32_t header[] = {uint32_t(patch.mip), uint32_t(patch.x), uint32_t(patch.y), uint32_t(patch.width | (patch.height << 16))};
		std::memcpy(output, header, sizeof(header));
		std::memcpy(output + 16, patch.bytes.ptr(), patch.bytes.size());
		output += 260 * 4;
	}
	if (rd->buffer_update(_scatter_buffer, 0, bytes, updates) != OK) { _restore(std::move(patches)); return; }
	const int64_t list = rd->compute_list_begin();
	rd->compute_list_bind_compute_pipeline(list, _scatter_pipeline);
	rd->compute_list_bind_uniform_set(list, _scatter_set, 0);
	rd->compute_list_dispatch(list, 1, 1, uint32_t(patches.size()));
	rd->compute_list_end();
}
