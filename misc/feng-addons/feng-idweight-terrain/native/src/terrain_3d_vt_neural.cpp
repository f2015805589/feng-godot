// Optional, addon-owned neural encoding of evaluated VT pages. No NTC SDK or CUDA
// dependency: an addon can decode missing pages into writable GPU targets, or supply
// a compressed material sampler with its own bounded decoded working set.
#include "terrain_3d.h"
#include "terrain_3d_surface_baker.h"
#include "terrain_3d_vt_service_internal.h"

using namespace godot;
using namespace terrain_surface_vt;

void Terrain3DSurfaceBaker::set_neural_view(const Projection &p_view, const Vector2 &p_size, float p_anisotropy) {
	std::lock_guard<std::mutex> lock(_mutex);
	if (!_neural_direct || (_neural_view == p_view && _neural_view_size == p_size && _neural_anisotropy == p_anisotropy)) { return; }
	_neural_view = p_view;
	_neural_view_size = p_size;
	_neural_anisotropy = p_anisotropy;
	_neural_view_dirty = true;
}

String Terrain3DSurfaceBaker::neural_page_key(const Rect2 &p_rect, int p_size, int p_border, int p_tier) {
	return String::num_int64(p_tier) + "/" + String::num_int64(p_size) + "/" +
			String::num_int64(p_border) + "/" + String::num(p_rect.position.x, 9) + "/" +
			String::num(p_rect.position.y, 9) + "/" + String::num(p_rect.size.x, 9) + "/" + String::num(p_rect.size.y, 9);
}

void Terrain3DSurfaceBaker::set_neural_codec(const Dictionary &p_snapshot) {
	std::lock_guard<std::mutex> lock(_mutex);
	if (_neural_decoder.is_valid()) { _retired_neural_decoders.push_back(_neural_decoder); }
	_neural_decoder = p_snapshot.get("decoder", Ref<RefCounted>());
	_neural_entries = p_snapshot.get("pages", Dictionary());
	_neural_failed_entries.clear();
	_neural_source_signature = p_snapshot.get("source_signature", String());
	_neural_page_budget = CLAMP(int(p_snapshot.get("max_pages_per_frame", 1)), 1, 16);
	_neural_gpu_bytes = 0;
	_neural_runtime_stats.clear();
	_neural_view_dirty = true;
	_neural_cache_mode = CLAMP(int(p_snapshot.get("cache_compression", -1)), -1, 2);
	_neural_direct = bool(p_snapshot.get("direct_sampling", false));
	for (int tier = 0; tier < TIER_COUNT; ++tier) {
		_resolve_tier_compression(tier);
		_resolve_tier_normal_compression(tier);
	}
	++_generation;
	_invalidate_all = true;
	_pending.clear();
	std::fill(_ready.begin(), _ready.end(), uint8_t(0));
}

bool Terrain3DSurfaceBaker::queue_neural_page(int p_slot, const Rect2 &p_rect, int p_tier, const String &p_source_signature) {
	std::lock_guard<std::mutex> lock(_mutex);
	const int tier = CLAMP(p_tier, 0, TIER_COUNT - 1);
	if (!_configured || p_slot < 0 || p_slot >= _page_count || _tiers[tier].requested != SURFACE_PAGE_NTC) { return false; }
	const String key = neural_page_key(p_rect, _page_size, _border, tier);
	if (_neural_decoder.is_null() || _neural_source_signature != p_source_signature ||
			!_neural_entries.has(key) || _neural_failed_entries.has(key)) { ++_neural_misses; return false; }
	const Dictionary entry = _neural_entries[key];
	if (entry.is_empty()) { return false; }
	PendingJob job;
	job.slot = p_slot;
	job.kind = PENDING_NEURAL;
	job.tier = tier;
	job.neural_page = entry.duplicate();
	job.neural_page["key"] = key;
	job.neural_decoder = _neural_decoder;
	job.world_rect = p_rect;
	job.generation = _generation;
	job.sequence = ++_next_sequence;
	_pending[p_slot] = job;
	_slot_sequence[size_t(p_slot)] = job.sequence;
	_slot_tier[size_t(p_slot)] = uint8_t(tier);
	_ready[size_t(p_slot)] = 0;
	_sampled_channel_mask[size_t(p_slot)] = 0;
	return true;
}

bool Terrain3DSurfaceBaker::_decode_neural_page(const PendingJob &p_job) {
	if (p_job.neural_decoder.is_null()) { return false; }
	Array targets;
	targets.push_back(_resources.output_albedo_rd);
	targets.push_back(_resources.output_normal_rd);
	targets.push_back(_resources.output_params_rd);
	const int layer = p_job.staging_layer >= 0 ? p_job.staging_layer : p_job.slot;
	const Variant result = _neural_direct ? p_job.neural_decoder->call("register_page", p_job.neural_page, p_job.slot, _page_count) :
			p_job.neural_decoder->call("decode_page", p_job.neural_page, targets, layer);
	const Dictionary report = result.get_type() == Variant::DICTIONARY ? Dictionary(result) : Dictionary();
	if (!bool(report.get("ok", false))) {
		// A bad package or failed GPU allocation must not strand a page forever:
		// its next retry goes through the normal producer until a new bake is assigned.
		std::lock_guard<std::mutex> lock(_mutex);
		if (p_job.generation == _generation) { _neural_failed_entries[p_job.neural_page.get("key", String())] = true; }
		return false;
	}
	std::lock_guard<std::mutex> lock(_mutex);
	++_neural_decodes;
	_neural_gpu_bytes = int64_t(report.get("gpu_bytes", 0));
	return true;
}

void Terrain3DSurfaceBaker::_dispose_neural_decoders(const Array &p_decoders) {
	for (const Variant &value : p_decoders) {
		Ref<RefCounted> decoder = value;
		if (decoder.is_valid()) { decoder->call("dispose"); }
	}
}

void Terrain3D::set_vt_neural_data(const Ref<Resource> &p_data) {
	if (_vt_neural_data.is_valid() && _vt_neural_data->is_connected("changed", Callable(this, "_vt_neural_data_changed"))) {
		_vt_neural_data->disconnect("changed", Callable(this, "_vt_neural_data_changed"));
	}
	_vt_neural_data = p_data;
	if (p_data.is_valid()) { p_data->connect("changed", Callable(this, "_vt_neural_data_changed")); }
	_vt_neural_bound_baker = 0;
	_vt.vt_materials_dirty = true;
	if (is_inside_tree()) { _sync_vt_neural_data(); }
}

void Terrain3D::_sync_vt_neural_data() {
	Terrain3DSurfaceBaker *producer = baker(_vt.vt_baker);
	if (!producer || _vt_neural_bound_baker == uint64_t(producer->get_instance_id())) { return; }
	Dictionary snapshot;
	if (_vt_neural_data.is_valid() && _vt_neural_data->has_method("create_terrain_decoder")) {
		snapshot = _vt_neural_data->call("create_terrain_decoder");
	}
	Ref<RefCounted> decoder = snapshot.get("decoder", Ref<RefCounted>());
	if (bool(snapshot.get("direct_sampling", false)) && decoder.is_valid() && _material.is_valid()) {
		decoder->call("configure_material", _material->get_material_rid());
	}
	const String code = snapshot.get("shader_code", String());
	const bool shader_changed = code != _vt_neural_shader_code;
	_vt_neural_shader_code = code;
	producer->set_neural_codec(snapshot);
	_vt_neural_bound_baker = uint64_t(producer->get_instance_id());
	if (shader_changed && _material.is_valid()) { _material->update(Terrain3DMaterial::FULL_REBUILD); }
}

void Terrain3D::_vt_neural_data_changed() {
	const Ref<Resource> data = _vt_neural_data;
	set_vt_neural_data(data);
}

String Terrain3D::get_vt_neural_signature() {
	if (!_data || _assets.is_null()) { return String(); }
	if (_vt_neural_signature_revision == _vt.vt_source_revision &&
			_vt_neural_signature_materials == _vt.vt_material_signature && !_vt_neural_signature.is_empty()) {
		return _vt_neural_signature;
	}
	// Recomputed after edits, never per pixel or per steady-state frame. Source bytes,
	// settings and neighboring cells all participate; instance IDs and file paths do not.
	Dictionary signature;
	signature["contract"] = 1;
	signature["materials"] = int64_t(_vt.vt_material_signature);
	signature["spacing"] = _vertex_spacing;
	signature["density"] = _surface_density;
	signature["svt_density"] = get_surface_svt_texels_per_meter();
	signature["region_size"] = int(_region_size);
	std::map<std::pair<int, int>, Vector2i> locations;
	for (const Vector2i &location : _data->get_region_locations()) { locations[{location.x, location.y}] = location; }
	for (const auto &item : locations) {
		const Vector2i location = item.second;
		signature[location] = int64_t(_svt_cell_signature(location));
	}
	_vt_neural_signature_revision = _vt.vt_source_revision;
	_vt_neural_signature_materials = _vt.vt_material_signature;
	_vt_neural_signature = "terrain-vt-1/" + String::num_int64(signature.hash());
	return _vt_neural_signature;
}

Array Terrain3D::export_vt_neural_pages(int p_limit) {
	Array result;
	Terrain3DSurfaceBaker *producer = baker(_vt.vt_baker);
	if (!producer) { return result; }
	for (const auto &item : _vt.vt_page_records) {
		if (result.size() >= CLAMP(p_limit, 1, 4096)) { break; }
		const auto &record = item.second;
		if (!producer->is_page_ready(item.first)) { continue; }
		Dictionary page = producer->export_page(item.first);
		if (!bool(page.get("valid", false))) { continue; }
		const int tier = record.svt ? Terrain3DSurfaceBaker::TIER_SVT : Terrain3DSurfaceBaker::TIER_AVT;
		page["key"] = Terrain3DSurfaceBaker::neural_page_key(record.world_rect, _vt.vt_page_size, _vt.vt_page_border, tier);
		page["world_rect"] = record.world_rect;
		page["tier"] = tier;
		result.push_back(page);
	}
	return result;
}
