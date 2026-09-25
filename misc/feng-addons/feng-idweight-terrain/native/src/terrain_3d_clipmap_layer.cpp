// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// The clipmap layer's facade. Read terrain_3d_clipmap_layer.h first: it states why there is one
// clipmap delivery with two implementations, what the facade owns and what it deliberately does not,
// and how the one debug schema is assembled. This file is the forwarding and the assembly, and it has
// no addressing arithmetic of its own beyond the shared ladder.

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
	if (_impl == nullptr || p_pipeline == nullptr || async_update_in_progress() ||
			_impl->get_implementation() != TerrainClipmap::Implementation::LOD) {
		return false;
	}
	Terrain3DClipmap *ring = static_cast<Terrain3DClipmap *>(_impl.get());
	if (!ring->needs_update_at(p_focus)) {
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
	// The channel's source is asked for *now*, not kept from a previous build: a source is a thin
	// reading of the channel (`Terrain3DClipmapSource`), the implementation takes ownership of it, and
	// asking again is what lets the implementation be replaced without moving ownership back out.
	const TerrainClipmap::Implementation implementation = _settings.implementation;
	std::unique_ptr<Terrain3DClipmapSource> source = _source_factory != nullptr ? _source_factory() : nullptr;
	if (source == nullptr) {
		// The registry's own answer: this build has no source for the channel. The caller refuses the
		// cell with a sentence rather than handing back a layer nothing could produce.
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
		// A different implementation is different storage: there is no state to carry across, and a
		// layer that kept the old arrays alive would hold two memories for one delivery.
		_destroy();
	}
	if (_impl == nullptr && !_build()) {
		return false;
	}
	const TerrainClipmap::Shape &shape = _settings.shape;
	if (_settings.implementation == TerrainClipmap::Implementation::Atlas) {
		Terrain3DClipmapAtlas::Config config;
		// The block is the shared `size` texels of the shared `base_world` metres, so the atlas's
		// finest ring has exactly the density the LOD ring's finest level has: the settings that shape
		// one shape the other, and a user who tuned one has tuned the other.
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

// The channel's own declaration, asked of a *temporary* source when no implementation exists yet.
// This is the "the shape travels with the channel" rule the ring followed, one level up: the layer is
// configured from what the channel says a texel is, so the facade must be able to answer before it has
// built anything. A source is a thin reading of the channel (it holds the reader and the shape and no
// storage), so asking for one and letting it go is cheaper than the shape living in two places - and it
// is what keeps the channel registry the single answer to "what does this group carry".
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

// The one debug schema. Everything above `"impl"` is the shared contract's answer and is the same on
// both sides; `"impl"` is what only the selected implementation can say. The density and coverage
// arrays are the *layer's* - one function of the shared ladder - so a view that plots
// "density against distance" reads the same keys whichever implementation is selected, and a view that
// draws the storage draws the implementation's own picture.
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
		// The **coverage outer radius**: the distance from the focus at which the unit stops serving,
		// half the square it spans. It is the x the acceptance's "density - distance" curve is read at,
		// and it is half on both sides because a unit is centred on the focus in both storages.
		radius.push_back(_impl->get_unit_world_size(unit) * 0.5f);
		texel_world.push_back(report.texel_world);
	}
	result["unit_reports"] = entries;
	// The layer's own curve, in the unit the acceptance reads it in: the density a fragment is served
	// at a distance, from the shared ladder rather than from either storage. `density_distance` is the
	// **coverage outer radius** of each entry - the distance at which that unit's density is the one a
	// fragment gets - so a reader can plot one against the other.
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
	// The shared ladder's own reading, published beside the numbers it is derived from: the endpoints
	// this shape presents and the unit count its own finest density needs to reach the coarsest one. A
	// reader - the acceptance, or the dock - compares `units` with `ladder_units_required` instead of
	// re-deriving the halving rule, so "is this the shipping 1024 -> 1 span" is one key and a clamp that
	// shortened it is visible rather than implied.
	result["ladder_finest_density"] = ladder.finest_density();
	result["ladder_coarsest_density"] = ladder.density_at_unit_count(units);
	result["ladder_units_required"] = ladder.units_for_density();
	result["ladder_spans_endpoints"] = ladder.spans_endpoints(units);
	result["density_curve"] = density_curve;
	result["density_distance"] = density_distance;
	result["impl"] = _impl->get_impl_payload();
	return result;
}
