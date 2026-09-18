// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3DSurfaceBaker, part 5 of 6: the caller-facing queue.
//
// What a caller hands the producer - a page to bake, a cached channel set, the pieces of a
// baked cell - the uploads that put that content into the staging arrays, and the capacity,
// budget and material state those jobs are prepared against. The frame that drains the queue
// is terrain_3d_surface_baker_frame.cpp; none of this runs on the render thread.
//
// The other halves: terrain_3d_surface_baker.cpp (the device and its objects),
// terrain_3d_surface_baker_bundle.cpp (the ResourceBundle's lifetime),
// terrain_3d_surface_baker_pipelines.cpp (the two GPU programs),
// terrain_3d_surface_baker_storage.cpp and terrain_3d_surface_baker_frame.cpp.

#include "terrain_3d_surface_baker.h"
#include "terrain_3d_surface_baker_internal.h"

#include "logger.h"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/rd_shader_source.hpp>
#include <godot_cpp/classes/rd_shader_spirv.hpp>
#include <godot_cpp/classes/rd_texture_format.hpp>
#include <godot_cpp/classes/rd_texture_view.hpp>
#include <godot_cpp/classes/rd_uniform.hpp>
#include <godot_cpp/variant/rect2i.hpp>

#include <algorithm>
#include <utility>

// The codec vocabulary, the shared constants and the small helpers of the four halves; see
// terrain_3d_surface_baker_internal.h for what it holds and why it is a header.
using namespace terrain_surface_baker;

void Terrain3DSurfaceBaker::set_page_budget(const int p_pages) {
	_page_budget.store(CLAMP(p_pages, 1, 16));
	// A budget change moves the depth the ring has to hold for that budget to be the rate
	// that decides page production. It never exceeds what the bundle allocated, so this only
	// ever re-admits positions the allocation already has.
	_refresh_encode_ring_capacity();
}

void Terrain3DSurfaceBaker::request_capacity(int p_count) {
	std::lock_guard<std::mutex> lock(_mutex);
	_requested_capacity = std::max(_requested_capacity, p_count);
}
int Terrain3DSurfaceBaker::get_capacity() const {
	std::lock_guard<std::mutex> lock(_mutex);
	return _page_count;
}

bool Terrain3DSurfaceBaker::has_pending_capacity() const {
	std::lock_guard<std::mutex> lock(_mutex);
	return _configured && _requested_capacity > _page_count;
}

bool Terrain3DSurfaceBaker::materials_stale() const {
	std::lock_guard<std::mutex> lock(_mutex);
	return _materials_stale;
}

void Terrain3DSurfaceBaker::acknowledge_output(const RID &p_albedo) {
	std::lock_guard<std::mutex> lock(_mutex);
	if (!p_albedo.is_valid()) {
		return;
	}
	// Which bundle the material bound, not which bundle exists now. The render thread can
	// rebuild between the caller reading the RID and this call, and acknowledging the newer
	// generation would let the release below free the arrays the material is actually
	// sampling - the renderer then reports a missing material uniform set for one frame.
	// Both RIDs a bundle can publish are matched, because a bundle built before a format
	// change carries no compressed pair while the current setting says there is one.
	auto bundle_generation = [](const ResourceBundle &p_bundle, const RID &p_rid) -> bool {
		if (p_bundle.output_albedo_rs == p_rid) {
			return true;
		}
		for (int tier = 0; tier < TIER_COUNT; ++tier) {
			if (p_bundle.sampled[tier].albedo_rs == p_rid) {
				return true;
			}
		}
		return false;
	};
	uint64_t generation = 0;
	if (bundle_generation(_resources, p_albedo)) {
		generation = _resource_generation;
	} else {
		for (const std::pair<uint64_t, ResourceBundle> &entry : _retired) {
			if (bundle_generation(entry.second, p_albedo)) {
				generation = entry.first;
				break;
			}
		}
	}
	if (generation == 0) {
		return;
	}
	_acknowledged_generation = MAX(_acknowledged_generation, generation);
	_acknowledged_frame = Engine::get_singleton()->get_frames_drawn();
	_retire_ready = true;
}

void Terrain3DSurfaceBaker::set_materials(const RID &p_albedo_array_rid, const RID &p_normal_array_rid,
		const PackedColorArray &p_colors, const PackedFloat32Array &p_normal_depths,
		const PackedFloat32Array &p_ao_strengths, const PackedFloat32Array &p_ao_affects,
		const PackedFloat32Array &p_roughness_mods, const PackedFloat32Array &p_uv_scales,
		const PackedVector2Array &p_detiles, const PackedVector3Array &p_slope_params) {
	PackedByteArray bytes;
	bytes.resize(MATERIAL_COUNT * MATERIAL_STRIDE);
	for (int i = 0; i < MATERIAL_COUNT; i++) {
		Color color(1.0f, 1.0f, 1.0f, 1.0f);
		if (i < p_colors.size()) {
			color = p_colors[i];
		}
		float normal_depth = i < p_normal_depths.size() ? p_normal_depths[i] : 1.0f;
		float ao_strength = i < p_ao_strengths.size() ? p_ao_strengths[i] : 0.5f;
		float ao_affect = i < p_ao_affects.size() ? p_ao_affects[i] : 0.0f;
		float roughness_mod = i < p_roughness_mods.size() ? p_roughness_mods[i] : 0.0f;
		float uv_scale = i < p_uv_scales.size() ? p_uv_scales[i] : 0.1f;
		Vector2 detile;
		if (i < p_detiles.size()) {
			detile = p_detiles[i];
		}
		Vector3 slope(1000.0f, 0.0f, 0.0f);
		if (i < p_slope_params.size()) {
			slope = p_slope_params[i];
		}
		const int64_t offset = int64_t(i) * MATERIAL_STRIDE;
		encode_vec4(bytes, offset, color.r, color.g, color.b, color.a);
		encode_vec4(bytes, offset + 16, normal_depth, ao_strength, ao_affect, roughness_mod);
		encode_vec4(bytes, offset + 32, uv_scale, detile.x, detile.y, 0.0f);
		encode_vec4(bytes, offset + 48, slope.x, slope.y, slope.z, 0.0f);
	}
	std::lock_guard<std::mutex> lock(_mutex);
	_material_albedo_rs = p_albedo_array_rid;
	_material_normal_rs = p_normal_array_rid;
	_material_bytes = bytes;
	_material_count = std::min(MATERIAL_COUNT, std::max<int>({ int(p_colors.size()), int(p_normal_depths.size()), int(p_ao_strengths.size()), int(p_ao_affects.size()), int(p_roughness_mods.size()), int(p_uv_scales.size()), int(p_detiles.size()), int(p_slope_params.size()) }));
	_material_version++;
	_materials_dirty = true;
	// A fresh snapshot replaces whatever the render thread could not bind.
	_materials_stale = false;
	_invalidate_all = true;
	std::fill(_ready.begin(), _ready.end(), uint8_t(0));
	std::fill(_sampled_channel_mask.begin(), _sampled_channel_mask.end(), uint8_t(0));
}

void Terrain3DSurfaceBaker::queue_page(int p_slot, const Ref<Image> &p_idweights,
		const Ref<Image> &p_height, const Rect2 &p_world_rect, float p_slope_factor, Vector3 p_source_grid,
		int p_tier) {
	std::lock_guard<std::mutex> lock(_mutex);
	if (!_configured || p_slot < 0 || p_slot >= _page_count || p_idweights.is_null() || p_height.is_null()) {
		return;
	}
	const int tier = CLAMP(p_tier, 0, TIER_COUNT - 1);
	PendingJob job;
	job.slot = p_slot;
	job.kind = PENDING_BAKE;
	job.tier = tier;
	job.idweights = p_idweights;
	job.height = p_height;
	job.world_rect = p_world_rect;
	job.source_grid = p_source_grid;
	job.slope_factor = std::clamp(p_slope_factor, 0.0f, 1.0f);
	job.generation = _generation;
	job.sequence = ++_next_sequence;
	_pending[p_slot] = job;
	_slot_sequence[size_t(p_slot)] = job.sequence;
	_slot_tier[size_t(p_slot)] = uint8_t(tier);
	_ready[size_t(p_slot)] = 0;
	_sampled_channel_mask[size_t(p_slot)] = 0;
}

void Terrain3DSurfaceBaker::queue_cached_page(int p_slot, const Dictionary &p_channels, int p_tier) {
	Ref<Image> albedo = p_channels.get("albedo_height", Variant());
	Ref<Image> normal = p_channels.get("normal_roughness", Variant());
	Ref<Image> params = p_channels.get("params", Variant());
	std::lock_guard<std::mutex> lock(_mutex);
	if (!_configured || p_slot < 0 || p_slot >= _page_count || albedo.is_null() || normal.is_null() || params.is_null()) {
		return;
	}
	const int tier = CLAMP(p_tier, 0, TIER_COUNT - 1);
	PendingJob job;
	job.slot = p_slot;
	job.kind = PENDING_CACHED;
	job.tier = tier;
	job.albedo_height = albedo;
	job.normal_roughness = normal;
	job.params = params;
	job.generation = _generation;
	job.sequence = ++_next_sequence;
	_pending[p_slot] = job;
	_slot_sequence[size_t(p_slot)] = job.sequence;
	_slot_tier[size_t(p_slot)] = uint8_t(tier);
	_ready[size_t(p_slot)] = 0;
	_sampled_channel_mask[size_t(p_slot)] = 0;
}

void Terrain3DSurfaceBaker::queue_cell_page(int p_slot, const Array &p_cells, const Rect2 &p_rect, int p_tier) {
	std::lock_guard<std::mutex> lock(_mutex);
	if (!_configured || p_slot < 0 || p_slot >= _page_count) {
		return;
	}
	const int tier = CLAMP(p_tier, 0, TIER_COUNT - 1);
	PendingJob job;
	job.slot = p_slot;
	job.kind = PENDING_CELL;
	job.tier = tier;
	job.cells = p_cells;
	job.world_rect = p_rect;
	job.generation = _generation;
	job.sequence = ++_next_sequence;
	_pending[p_slot] = job;
	_slot_sequence[size_t(p_slot)] = job.sequence;
	_slot_tier[size_t(p_slot)] = uint8_t(tier);
	_ready[size_t(p_slot)] = 0;
	_sampled_channel_mask[size_t(p_slot)] = 0;
}

void Terrain3DSurfaceBaker::invalidate_slot(int p_slot) {
	std::lock_guard<std::mutex> lock(_mutex);
	if (!_configured || p_slot < 0 || p_slot >= _page_count) {
		return;
	}
	PendingJob job;
	job.slot = p_slot;
	job.kind = PENDING_INVALIDATE;
	// An invalidation clears a slot's content, it does not hand the slot to the other view:
	// the tier stays whatever last filled it until the next queue call names a producer.
	job.tier = p_slot < int(_slot_tier.size()) ? int(_slot_tier[size_t(p_slot)]) : int(TIER_AVT);
	job.generation = _generation;
	job.sequence = ++_next_sequence;
	_pending[p_slot] = job;
	_slot_sequence[size_t(p_slot)] = job.sequence;
	_ready[size_t(p_slot)] = 0;
	_sampled_channel_mask[size_t(p_slot)] = 0;
}

PackedByteArray Terrain3DSurfaceBaker::_image_bytes(const Ref<Image> &p_image,
		Image::Format p_expected_format, int p_bytes_per_pixel) const {
	if (p_image.is_null() || p_image->is_empty() || p_image->get_width() != _stored_size ||
			p_image->get_height() != _stored_size || p_image->has_mipmaps()) {
		return PackedByteArray();
	}
	PackedByteArray bytes = p_image->get_data();
	const int64_t expected_size = int64_t(_stored_size) * _stored_size * p_bytes_per_pixel;
	if (p_image->get_format() == p_expected_format && bytes.size() == expected_size) {
		return bytes;
	}
	// Main-RD outputs are RGBA16F.  Cached files may use RGBAF for portability; a
	// temporary Image conversion keeps texture_update's byte layout exact without
	// mutating the caller's cache resource.
	if (p_expected_format == Image::FORMAT_RGBAH &&
			(p_image->get_format() == Image::FORMAT_RGBAF || p_image->get_format() == Image::FORMAT_RGBA8 ||
					p_image->get_format() == Image::FORMAT_RGBAH)) {
		Ref<Image> converted = Image::create_from_data(_stored_size, _stored_size, false,
				p_image->get_format(), bytes);
		if (converted.is_valid() && converted->get_format() != p_expected_format) {
			converted->convert(p_expected_format);
		}
		if (converted.is_valid()) {
			bytes = converted->get_data();
			if (bytes.size() == expected_size) {
				return bytes;
			}
		}
	}
	return PackedByteArray();
}

bool Terrain3DSurfaceBaker::_upload_source_page(const PendingJob &p_job, int p_layer) {
	if (!_rd || !_resources.source_id_rd.is_valid() || !_resources.source_height_rd.is_valid()) {
		return false;
	}
	SurfaceVTLabel label(_rd, "VT Source Upload - slot " + String::num_int64(p_job.slot));
	PackedByteArray id_bytes = _image_bytes(p_job.idweights, IDWEIGHT_IMAGE_FORMAT, 2);
	PackedByteArray height_bytes = _image_bytes(p_job.height, Image::FORMAT_RF, 4);
	if (id_bytes.is_empty() || height_bytes.is_empty()) {
		LOG(WARN, "Skipping invalid surface bake source page ", p_job.slot,
				"; expected ", _stored_size, "x", _stored_size, " R16/RF images");
		return false;
	}
	if (_rd->texture_update(_resources.source_id_rd, uint32_t(p_layer), id_bytes) != OK ||
			_rd->texture_update(_resources.source_height_rd, uint32_t(p_layer), height_bytes) != OK) {
		LOG(WARN, "Could not upload surface bake source page ", p_job.slot);
		return false;
	}
	{
		std::lock_guard<std::mutex> lock(_mutex);
		_source_uploads++;
	}
	return true;
}

bool Terrain3DSurfaceBaker::_upload_cached_page(const PendingJob &p_job) {
	if (!_rd || !_resources.output_albedo_rd.is_valid() || !_resources.output_normal_rd.is_valid() ||
			!_resources.output_params_rd.is_valid()) {
		return false;
	}
	PackedByteArray albedo = _image_bytes(p_job.albedo_height, Image::FORMAT_RGBAH, 8);
	PackedByteArray normal = _image_bytes(p_job.normal_roughness, Image::FORMAT_RGBAH, 8);
	PackedByteArray params = _image_bytes(p_job.params, Image::FORMAT_RGBAH, 8);
	if (albedo.is_empty() || normal.is_empty() || params.is_empty()) {
		LOG(WARN, "Skipping invalid cached surface page ", p_job.slot);
		return false;
	}
	SurfaceVTLabel label(_rd, "SVT Cached Page Upload - slot " + String::num_int64(p_job.slot));
	const int layer = p_job.staging_layer >= 0 ? p_job.staging_layer : p_job.slot;
	if (_rd->texture_update(_resources.output_albedo_rd, uint32_t(layer), albedo) != OK ||
			_rd->texture_update(_resources.output_normal_rd, uint32_t(layer), normal) != OK ||
			_rd->texture_update(_resources.output_params_rd, uint32_t(layer), params) != OK) {
		LOG(WARN, "Could not upload cached surface page ", p_job.slot);
		return false;
	}
	return true;
}

// Copy cropped cell sources into runtime pages, area-weighting cells when a coarse pixel
// spans several source cells. A piece that names a resident cell is copied straight from
// the GPU cell store; a piece that carries images is uploaded first, which is the path an
// offline bake that has not been published into the store still uses. No material rebake
// happens either way.
bool Terrain3DSurfaceBaker::_copy_cell_page(const PendingJob &p_job, Terrain3DCellStore *p_store) {
	if (!_resources.cell_pipeline.is_valid()) {
		Ref<RDShaderSource> source;
		source.instantiate();
		source->set_language(RenderingDevice::SHADER_LANGUAGE_GLSL);
		source->set_stage_source(RenderingDevice::SHADER_STAGE_COMPUTE, R"(#version 450
layout(local_size_x=8, local_size_y=8) in;
layout(set=0,binding=0) uniform sampler2D src_a;
layout(set=0,binding=1) uniform sampler2D src_n;
layout(set=0,binding=2) uniform sampler2D src_p;
layout(rgba16f,set=0,binding=3) uniform image2DArray dst_a;
layout(rgba16f,set=0,binding=4) uniform image2DArray dst_n;
layout(rgba16f,set=0,binding=5) uniform image2DArray dst_p;
layout(push_constant,std430) uniform Push { vec4 page; vec4 cell; vec4 source; ivec4 config; } pc;
void main() {
 ivec2 pixel=ivec2(gl_GlobalInvocationID.xy);
 int size=pc.config.x+2*pc.config.y;
 if(any(greaterThanEqual(pixel,ivec2(size)))) return;
 if(pc.config.w==1) {
  ivec3 dst=ivec3(pixel,pc.config.z);
  vec4 params=imageLoad(dst_p,dst);
  if(params.a>0.000001) {
   imageStore(dst_a,dst,imageLoad(dst_a,dst)/params.a);
   imageStore(dst_n,dst,imageLoad(dst_n,dst)/params.a);
   imageStore(dst_p,dst,vec4(params.rgb/params.a,1));
  }
  return;
 }
 float step=pc.page.z/float(pc.config.x);
 vec2 lo=pc.page.xy+(vec2(pixel)-float(pc.config.y))*step;
 vec2 first=max(lo,pc.cell.xy), last=min(lo+step,pc.cell.xy+pc.cell.zw);
 vec2 extent=max(vec2(0),last-first);
 float weight=extent.x*extent.y/(step*step);
 if(weight<=0.0) return;
 vec2 uv=((first+last)*0.5-pc.source.xy)/pc.source.zw;
 vec2 inset=vec2(0.5)/vec2(textureSize(src_a,0));
 uv=clamp(uv,inset,vec2(1)-inset);
 ivec3 dst=ivec3(pixel,pc.config.z);
 imageStore(dst_a,dst,imageLoad(dst_a,dst)+textureLod(src_a,uv,0)*weight);
 imageStore(dst_n,dst,imageLoad(dst_n,dst)+textureLod(src_n,uv,0)*weight);
 imageStore(dst_p,dst,imageLoad(dst_p,dst)+textureLod(src_p,uv,0)*weight);
}
)");
		Ref<RDShaderSPIRV> spirv = _rd->shader_compile_spirv_from_source(source);
		if (spirv.is_null() || !spirv->get_stage_compile_error(RenderingDevice::SHADER_STAGE_COMPUTE).is_empty()) {
			return false;
		}
		_resources.cell_shader = _rd->shader_create_from_spirv(spirv, "svt_cell_copy");
		_resources.cell_pipeline = _rd->compute_pipeline_create(_resources.cell_shader);
		if (!_resources.cell_pipeline.is_valid()) {
			return false;
		}
	}
	for (RID target : { _resources.output_albedo_rd, _resources.output_normal_rd, _resources.output_params_rd }) {
		_rd->texture_clear(target, Color(0, 0, 0, 0), 0, 1, p_job.staging_layer >= 0 ? p_job.staging_layer : p_job.slot, 1);
	}
	int piece_index = 0;
	for (const Dictionary &piece : p_job.cells) {
		std::vector<RID> textures;
		// Views into the cell store belong to this call and are freed with it; uploaded
		// textures are ours as well, so one list of owned RIDs covers both.
		std::vector<RID> owned;
		const int layer = int(piece.get("layer", -1));
		const int level = int(piece.get("level", 0));
		for (int channel = 0; channel < 3; ++channel) {
			if (layer >= 0 && p_store) {
				const RID view = p_store->create_sample_view(channel, layer, level);
				textures.push_back(view);
				if (view.is_valid()) { owned.push_back(view); }
				continue;
			}
			Ref<Image> image = piece[String(channel == 0 ? "albedo_height" : (channel == 1 ? "normal_roughness" : "params"))];
			if (image.is_null()) {
				textures.push_back(RID());
				continue;
			}
			Ref<RDTextureFormat> format;
			format.instantiate();
			format->set_format(RenderingDevice::DATA_FORMAT_R16G16B16A16_SFLOAT);
			format->set_width(image->get_width());
			format->set_height(image->get_height());
			format->set_texture_type(RenderingDevice::TEXTURE_TYPE_2D);
			format->set_usage_bits(RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT);
			Ref<RDTextureView> view;
			view.instantiate();
			TypedArray<PackedByteArray> data;
			data.push_back(image->get_data());
			const RID texture = _rd->texture_create(format, view, data);
			textures.push_back(texture);
			if (texture.is_valid()) { owned.push_back(texture); }
		}
		bool sources_valid = true;
		for (const RID &texture : textures) {
			if (!texture.is_valid()) { sources_valid = false; }
		}
		if (!sources_valid) {
			for (const RID &rid : owned) { _rd->free_rid(rid); }
			continue;
		}
		TypedArray<Ref<RDUniform>> uniforms;
		for (int i = 0; i < 3; ++i) {
			append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, i, _resources.sampler_linear, textures[i]);
		}
		append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_IMAGE, 3, _resources.output_albedo_rd);
		append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_IMAGE, 4, _resources.output_normal_rd);
		append_uniform(uniforms, RenderingDevice::UNIFORM_TYPE_IMAGE, 5, _resources.output_params_rd);
		RID uniform = _rd->uniform_set_create(uniforms, _resources.cell_shader, 0);
		PackedByteArray push;
		push.resize(64);
		Rect2 rects[] = { p_job.world_rect, piece.get("coverage_rect", piece["cell_rect"]), piece["source_rect"] };
		for (int i = 0; i < 3; ++i) {
			push.encode_float(i * 16, rects[i].position.x);
			push.encode_float(i * 16 + 4, rects[i].position.y);
			push.encode_float(i * 16 + 8, rects[i].size.x);
			push.encode_float(i * 16 + 12, rects[i].size.y);
		}
		push.encode_s32(48, _page_size);
		push.encode_s32(52, _border);
		push.encode_s32(56, p_job.staging_layer >= 0 ? p_job.staging_layer : p_job.slot);
		push.encode_s32(60, 0);
		int64_t list = _rd->compute_list_begin();
		_rd->compute_list_bind_compute_pipeline(list, _resources.cell_pipeline);
		_rd->compute_list_bind_uniform_set(list, uniform, 0);
		_rd->compute_list_set_push_constant(list, push, 64);
		_rd->compute_list_dispatch(list, (_stored_size + 7) / 8, (_stored_size + 7) / 8, 1);
		_rd->compute_list_end();
		if (++piece_index == p_job.cells.size()) {
			push.encode_s32(60, 1);
			list = _rd->compute_list_begin();
			_rd->compute_list_bind_compute_pipeline(list, _resources.cell_pipeline);
			_rd->compute_list_bind_uniform_set(list, uniform, 0);
			_rd->compute_list_set_push_constant(list, push, 64);
			_rd->compute_list_dispatch(list, (_stored_size + 7) / 8, (_stored_size + 7) / 8, 1);
			_rd->compute_list_end();
		}
		_rd->free_rid(uniform);
		for (RID texture : owned) {
			_rd->free_rid(texture);
		}
	}
	return true;
}

void Terrain3DSurfaceBaker::set_cell_store(const Ref<Terrain3DCellStore> &p_store) {
	std::lock_guard<std::mutex> lock(_mutex);
	_cell_store = p_store;
}

