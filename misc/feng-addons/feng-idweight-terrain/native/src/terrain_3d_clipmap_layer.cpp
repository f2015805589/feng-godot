// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Clipmap ownership, async handoff and shared debug report assembly.

#include "terrain_3d_clipmap_layer.h"

#include <chrono>
#include <thread>

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>

#include "logger.h"
#include "terrain_3d_clipmap.h"
#include "terrain_3d_clipmap_atlas.h"

Terrain3DClipmapLayer::Terrain3DClipmapLayer(SourceFactory p_factory) :
		_source_factory(std::move(p_factory)) {}

Terrain3DClipmapLayer::~Terrain3DClipmapLayer() {
	_destroy();
}

void Terrain3DClipmapLayer::_destroy() {
	wait_for_async_update();
	_impl.reset();
}

void Terrain3DClipmapLayer::wait_for_async_update() const {
	const std::shared_ptr<AsyncUpdate> update = _async_update;
	while (update != nullptr && !update->complete.load(std::memory_order_acquire)) {
		std::this_thread::yield();
	}
}

bool Terrain3DClipmapLayer::async_update_in_progress() const {
	return _async_update != nullptr && !_async_update->complete.load(std::memory_order_acquire);
}

bool Terrain3DClipmapLayer::consume_async_update(int &r_produced, uint64_t &r_worker_usec,
		PackedVector4Array &r_addresses, PackedVector4Array &r_outstanding,
		PackedInt32Array &r_outstanding_counts) {
	if (_async_update == nullptr || !_async_update->complete.load(std::memory_order_acquire)) {
		return false;
	}
	if (_impl != nullptr) {
		_impl->publish_pending_uploads();
	}
	r_produced = _async_update->produced;
	r_worker_usec = _async_update->worker_usec;
	r_addresses = _async_update->addresses;
	r_outstanding = _async_update->outstanding;
	r_outstanding_counts = _async_update->outstanding_counts;
	_async_update.reset();
	return true;
}

void Terrain3DClipmapLayer::set_source_snapshot(
		const std::shared_ptr<const Terrain3DPagePipeline::Snapshot> &p_snapshot) {
	wait_for_async_update();
	if (_impl != nullptr) {
		_impl->set_source_snapshot(p_snapshot);
	}
}

bool Terrain3DClipmapLayer::schedule_async_update(const Vector2 &p_focus, const int p_budget_texels,
		const std::shared_ptr<const Terrain3DPagePipeline::Snapshot> &p_snapshot,
		Terrain3DPagePipeline *p_pipeline) {
	if (_impl == nullptr || p_pipeline == nullptr || async_update_in_progress()) {
		return false;
	}
	if (!_impl->needs_update_at(p_focus)) {
		return true;
	}
	set_source_snapshot(p_snapshot);
	const std::shared_ptr<AsyncUpdate> update = std::make_shared<AsyncUpdate>();
	_async_update = update;
	p_pipeline->submit_render_task([this, update, focus = p_focus, budget = p_budget_texels]() {
		const auto started = std::chrono::steady_clock::now();
		update->produced = _impl != nullptr ? _impl->update(focus, budget) : 0;
		if (_impl != nullptr) {
			_impl->get_address_uniforms(update->addresses, update->outstanding,
					update->outstanding_counts);
		}
		update->worker_usec = uint64_t(std::chrono::duration_cast<std::chrono::microseconds>(
				std::chrono::steady_clock::now() - started).count());
		update->complete.store(true, std::memory_order_release);
	});
	return true;
}

bool Terrain3DClipmapLayer::_build() {
	// Each rebuilt implementation owns a fresh source.
	const TerrainClipmap::Implementation implementation = _settings.implementation;
	std::unique_ptr<Terrain3DClipmapSource> source = _source_factory != nullptr ? _source_factory() : nullptr;
	if (source == nullptr) {
		// The registry has no source for this channel.
		_impl.reset();
		return false;
	}
	LOG(DEBUG, "Creating ", source->get_source_name(), " clipmap layer (",
			TerrainClipmap::implementation_name(implementation), ")");
	if (implementation == TerrainClipmap::Implementation::Atlas) {
		_impl = std::make_unique<Terrain3DClipmapAtlas>(std::move(source));
	} else {
		_impl = std::make_unique<Terrain3DClipmap>(std::move(source));
	}
	return true;
}

bool Terrain3DClipmapLayer::configure(const Settings &p_settings) {
	wait_for_async_update();
	const bool switched = _impl != nullptr && _impl->get_implementation() != p_settings.implementation;
	_settings = p_settings;
	if (switched) {
		// Release the previous storage before switching implementations.
		_destroy();
	}
	if (_impl == nullptr && !_build()) {
		return false;
	}
	const TerrainClipmap::Shape &shape = _settings.shape;
	if (_settings.implementation == TerrainClipmap::Implementation::Atlas) {
		Terrain3DClipmapAtlas::Config config;
		// Both implementations use the shared finest density.
		config.block_size = shape.size;
		config.rings = shape.units;
		config.base_world = shape.base_world;
		config.channels = shape.channels;
		config.format = shape.format;
		config.global_texels = shape.global_texels;
		config.blocks_per_frame = shape.blocks_per_frame;
		config.spares = shape.spares;
		static_cast<Terrain3DClipmapAtlas *>(_impl.get())->configure(config);
	} else {
		Terrain3DClipmap::Config config;
		config.size = shape.size;
		config.levels = shape.units;
		config.base_world = shape.base_world;
		config.channels = shape.channels;
		config.format = shape.format;
		config.baked_channels = shape.baked_channels;
		config.baked_format = shape.baked_format;
		static_cast<Terrain3DClipmap *>(_impl.get())->configure(config);
	}
	return _impl->is_configured();
}

void Terrain3DClipmapLayer::clear() {
	wait_for_async_update();
	if (_impl != nullptr) {
		_impl->clear();
	}
}

// Probe channel metadata before an implementation exists.
std::unique_ptr<Terrain3DClipmapSource> Terrain3DClipmapLayer::_probe_source() const {
	return _source_factory != nullptr ? _source_factory() : nullptr;
}

int Terrain3DClipmapLayer::get_source_channel_count() const {
	wait_for_async_update();
	if (_impl != nullptr) {
		return _impl->get_channel_count();
	}
	const std::unique_ptr<Terrain3DClipmapSource> probe = _probe_source();
	return probe != nullptr ? probe->get_channel_count() : MAX(1, _settings.shape.channels);
}

Image::Format Terrain3DClipmapLayer::get_source_format() const {
	wait_for_async_update();
	if (_impl != nullptr) {
		return _impl->get_format();
	}
	const std::unique_ptr<Terrain3DClipmapSource> probe = _probe_source();
	return probe != nullptr ? probe->get_format() : _settings.shape.format;
}

int Terrain3DClipmapLayer::get_source_baked_channel_count() const {
	wait_for_async_update();
	if (_impl != nullptr) {
		return _impl->get_baked_channel_count();
	}
	const std::unique_ptr<Terrain3DClipmapSource> probe = _probe_source();
	return probe != nullptr ? probe->get_baked_channel_count() : _settings.shape.baked_channels;
}

Image::Format Terrain3DClipmapLayer::get_source_baked_format() const {
	wait_for_async_update();
	if (_impl != nullptr) {
		return _impl->get_baked_format();
	}
	const std::unique_ptr<Terrain3DClipmapSource> probe = _probe_source();
	return probe != nullptr ? probe->get_baked_format() : _settings.shape.baked_format;
}

const TerrainClipmap::BakeRect &Terrain3DClipmapLayer::get_pending_bake(const int p_index) const {
	wait_for_async_update();
	static const TerrainClipmap::BakeRect empty;
	return _impl != nullptr ? _impl->get_pending_bake(p_index) : empty;
}

Terrain3DClipmap *Terrain3DClipmapLayer::lod_impl() {
	return _impl != nullptr && _impl->get_implementation() == TerrainClipmap::Implementation::LOD
			? static_cast<Terrain3DClipmap *>(_impl.get())
			: nullptr;
}

const Terrain3DClipmap *Terrain3DClipmapLayer::lod_impl() const {
	return _impl != nullptr && _impl->get_implementation() == TerrainClipmap::Implementation::LOD
			? static_cast<const Terrain3DClipmap *>(_impl.get())
			: nullptr;
}

Terrain3DClipmapAtlas *Terrain3DClipmapLayer::atlas_impl() {
	return _impl != nullptr && _impl->get_implementation() == TerrainClipmap::Implementation::Atlas
			? static_cast<Terrain3DClipmapAtlas *>(_impl.get())
			: nullptr;
}

const Terrain3DClipmapAtlas *Terrain3DClipmapLayer::atlas_impl() const {
	return _impl != nullptr && _impl->get_implementation() == TerrainClipmap::Implementation::Atlas
			? static_cast<const Terrain3DClipmapAtlas *>(_impl.get())
			: nullptr;
}

// Common report fields plus the selected storage's "impl" payload.
Dictionary Terrain3DClipmapLayer::get_debug_layout(const String &p_group) const {
	wait_for_async_update();
	Dictionary result;
	if (_impl == nullptr) {
		return result;
	}
	const TerrainClipmap::Implementation implementation = _impl->get_implementation();
	const TerrainClipmap::Ladder ladder = _impl->get_ladder();
	const int units = _impl->get_unit_count();
	result["implementation"] = String(TerrainClipmap::implementation_name(implementation));
	result["implementations"] = String(TerrainClipmap::implementation_hint());
	result["group"] = p_group;
	result["source"] = _impl->get_source_name();
	result["units"] = units;
	result["size"] = _impl->get_size();
	result["base_world"] = ladder.base_world;
	result["channels"] = _impl->get_channel_count();
	result["texture"] = _impl->get_texture_rid();
	result["produced_texels"] = int64_t(_impl->get_produced_texels());
	result["upload_bytes"] = int64_t(_impl->get_upload_bytes());
	result["pending_jobs"] = _impl->get_pending_jobs();
	result["pending_bake_rects"] = _impl->get_pending_bake_count();
	result["state_stamp"] = int64_t(_impl->get_state_stamp());
	Array entries;
	PackedFloat32Array density;
	PackedFloat32Array reach;
	PackedFloat32Array radius;
	PackedFloat32Array texel_world;
	for (int unit = 0; unit < units; unit++) {
		TerrainClipmap::UnitReport report;
		_impl->get_unit_report(unit, report);
		entries.push_back(TerrainClipmap::unit_report_to_dictionary(report));
		density.push_back(report.density);
		reach.push_back(_impl->get_unit_world_size(unit));
		// Coverage radius is half the unit's world width.
		radius.push_back(_impl->get_unit_world_size(unit) * 0.5f);
		texel_world.push_back(report.texel_world);
	}
	result["unit_reports"] = entries;
	// Publish ladder density against each unit's coverage radius.
	PackedFloat32Array density_curve;
	PackedFloat32Array density_distance;
	for (int unit = 0; unit < units; unit++) {
		density_curve.push_back(ladder.density_of_unit(unit));
		density_distance.push_back(_impl->get_unit_world_size(unit) * 0.5f);
	}
	result["unit_density"] = density;
	result["unit_reach"] = reach;
	result["unit_radius"] = radius;
	result["unit_texel_world"] = texel_world;
	// Expose configured density endpoints and the units needed to span them.
	result["ladder_finest_density"] = ladder.finest_density();
	result["ladder_coarsest_density"] = ladder.density_at_unit_count(units);
	result["ladder_units_required"] = ladder.units_for_density();
	result["ladder_spans_endpoints"] = ladder.spans_endpoints(units);
	result["density_curve"] = density_curve;
	result["density_distance"] = density_distance;
	result["impl"] = _impl->get_impl_payload();
	return result;
}
