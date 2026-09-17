// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "terrain_3d.h"

#include "logger.h"
#include "terrain_3d_profile.h"
#include "terrain_3d_surface_baker.h"
#include "terrain_3d_util.h"
#include "terrain_3d_vt_visibility.h"

#include <godot_cpp/classes/compositor.hpp>
#include <godot_cpp/classes/directional_light3d.hpp>
#include <godot_cpp/classes/editor_interface.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/environment.hpp>
#include <godot_cpp/classes/label3d.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/classes/performance.hpp>
#include <godot_cpp/classes/physics_direct_space_state3d.hpp>
#include <godot_cpp/classes/physics_ray_query_parameters3d.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/quad_mesh.hpp>
#include <godot_cpp/classes/shader_material.hpp>
#include <godot_cpp/classes/surface_tool.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/classes/viewport_texture.hpp>
#include <godot_cpp/classes/world3d.hpp>

// Initialize static member variable
Terrain3D::DebugLevel Terrain3D::debug_level{ ERROR };

// This file owns the node itself: lifecycle, notifications, the container nodes it
// creates, mesh/collision/instancer wiring, and the physics-tick scheduler. The
// rest of the class is defined in the file that owns that concern:
//   terrain_3d_vt_service.cpp  surface virtual texture service and demand
//   terrain_3d_geometry.cpp    region-grid triangle generation
//   terrain_3d_properties.cpp  configuration setters
//   terrain_3d_queries.cpp     raycasts, baked meshes, nav source geometry, warnings
//   terrain_3d_bindings.cpp    ClassDB bindings and property registration
//   terrain_3d_profile.h       the `terrain/...` profiler zone and plot helper

///////////////////////////
// Private Functions
///////////////////////////

void Terrain3D::_initialize() {
	LOG(INFO, "Instantiating main subsystems");
	// Make blank objects if needed
	if (!_data) {
		LOG(DEBUG, "Creating blank data object");
		_data = memnew(Terrain3DData);
	}
	if (_material.is_null()) {
		LOG(DEBUG, "Creating blank material");
		_material.instantiate();
	}
	if (_assets.is_null()) {
		LOG(DEBUG, "Creating blank texture list");
		_assets.instantiate();
	}
	if (_assets->get_terrain() && _assets->get_terrain() != this) {
		_assets = _assets->duplicate(true);
	}
	if (!_collision) {
		LOG(DEBUG, "Creating collision manager");
		_collision = memnew(Terrain3DCollision);
	}
	if (!_instancer) {
		LOG(DEBUG, "Creating instancer");
		_instancer = memnew(Terrain3DInstancer);
	}
	if (!_streamer) {
		LOG(DEBUG, "Creating region streamer");
		_streamer = memnew(Terrain3DStreamer);
	}
	_setup_surface_vt();
	_setup_surface_svt();
	// Connect signals
	// Any region was changed, update region labels
	if (!_data->is_connected("region_map_changed", callable_mp(this, &Terrain3D::update_region_labels))) {
		LOG(DEBUG, "Connecting _data::region_map_changed signal to set_show_region_locations()");
		_data->connect("region_map_changed", callable_mp(this, &Terrain3D::update_region_labels));
	}
	// Any region was changed, regenerate collision if enabled
	if (!_data->is_connected("region_map_changed", callable_mp(_collision, &Terrain3DCollision::build))) {
		LOG(DEBUG, "Connecting _data::region_map_changed signal to build()");
		_data->connect("region_map_changed", callable_mp(_collision, &Terrain3DCollision::build));
	}
	// Any map was regenerated or regions changed, update material uniforms without rebuilding shaders
	if (!_data->is_connected("maps_changed", callable_mp(_material.ptr(), &Terrain3DMaterial::update).bind(Terrain3DMaterial::REGION_ARRAYS))) {
		LOG(DEBUG, "Connecting _data::maps_changed signal to _material->_update()");
		_data->connect("maps_changed", callable_mp(_material.ptr(), &Terrain3DMaterial::update).bind(Terrain3DMaterial::REGION_ARRAYS));
	}
	if (!_data->is_connected("maps_changed", callable_mp(this, &Terrain3D::_invalidate_render_geometry))) {
		_data->connect("maps_changed", callable_mp(this, &Terrain3D::_invalidate_render_geometry));
	}
	// Height map was regenerated, update aabbs
	if (!_data->is_connected("height_maps_changed", callable_mp(this, &Terrain3D::_update_mesher_aabbs))) {
		LOG(DEBUG, "Connecting _data::height_maps_changed signal to update_aabbs()");
		_data->connect("height_maps_changed", callable_mp(this, &Terrain3D::_update_mesher_aabbs));
	}
	// Texture assets changed, update material uniforms without rebuilding shaders
	if (!_assets->is_connected("textures_changed", callable_mp(_material.ptr(), &Terrain3DMaterial::update).bind(Terrain3DMaterial::TEXTURE_ARRAYS))) {
		LOG(DEBUG, "Connecting _assets.textures_changed to _material->update()");
		_assets->connect("textures_changed", callable_mp(_material.ptr(), &Terrain3DMaterial::update).bind(Terrain3DMaterial::TEXTURE_ARRAYS));
	}
	// Initialize the system
	if (!_initialized && _is_inside_world && is_inside_tree()) {
		LOG(INFO, "Initializing main subsystems");
		_data->initialize(this);
		_material->initialize(this);
		_assets->initialize(this);
		_collision->initialize(this);
		_instancer->initialize(this);
		_streamer->initialize(this);
		_streamer->set_enabled(_streaming_enabled);
		_setup_terrain_mesher();
		_setup_ocean_mesher();
		_update_displacement_buffer();
		_initialized = true;
		snap();
	}
	update_configuration_warnings();
}

/**
 * This is a proxy for _process(delta) called by _notification() due to
 * https://github.com/godotengine/godot-cpp/issues/1022
 */
// Publishes this node's cost as custom monitors. Every id starts with `terrain/`, which the
// editor's monitor graph uses as the group name, so a graph can show the terrain's own CPU
// and memory beside the engine's numbers instead of an unattributed spike. Units are the ones
// the editor formats: seconds for MONITOR_TYPE_TIME, bytes for MONITOR_TYPE_MEMORY.
void Terrain3D::_register_debug_monitors() {
	if (_monitors_registered) {
		return;
	}
	Performance *performance = Performance::get_singleton();
	if (!performance) {
		return;
	}
	// A second terrain in the same scene would collide on the plain names, so everything after
	// the first publishes under its instance id - still inside the `terrain` group.
	_monitor_prefix = performance->has_custom_monitor(StringName("terrain/vt_cpu"))
			? "terrain/" + String::num_int64(get_instance_id()) + "/"
			: "terrain/";
	// `Performance::MONITOR_TYPE_*` is not in the generated binding, so the ids the engine
	// binds are spelled out here; they decide how the editor formats a value.
	constexpr int MONITOR_TYPE_QUANTITY = 0;
	constexpr int MONITOR_TYPE_MEMORY = 1;
	constexpr int MONITOR_TYPE_TIME = 2;
	struct MonitorEntry {
		const char *name;
		Callable callable;
		int type;
	};
	const MonitorEntry entries[] = {
		{ "vt_cpu", callable_mp(this, &Terrain3D::_monitor_vt_cpu_ms), MONITOR_TYPE_TIME },
		{ "vt_cpu_peak", callable_mp(this, &Terrain3D::_monitor_vt_peak_ms), MONITOR_TYPE_TIME },
		{ "avt_cpu", callable_mp(this, &Terrain3D::_monitor_avt_cpu_ms), MONITOR_TYPE_TIME },
		{ "svt_cpu", callable_mp(this, &Terrain3D::_monitor_svt_cpu_ms), MONITOR_TYPE_TIME },
		{ "cdlod_cpu", callable_mp(this, &Terrain3D::_monitor_cdlod_cpu_ms), MONITOR_TYPE_TIME },
		{ "material_bytes", callable_mp(this, &Terrain3D::_monitor_material_bytes), MONITOR_TYPE_MEMORY },
		{ "pages_ready", callable_mp(this, &Terrain3D::_monitor_pages_ready), MONITOR_TYPE_QUANTITY },
		{ "pages_pending", callable_mp(this, &Terrain3D::_monitor_pages_pending), MONITOR_TYPE_QUANTITY },
		{ "pages_late", callable_mp(this, &Terrain3D::_monitor_pages_late), MONITOR_TYPE_QUANTITY },
	};
	for (const MonitorEntry &entry : entries) {
		// The generated binding exposes three arguments, so the monitor type is passed through
		// a dynamic call; without it the editor shows every value as a bare number.
		const StringName id(_monitor_prefix + entry.name);
		if (performance->has_custom_monitor(id)) {
			continue;
		}
		const Variant arguments[4] = { id, entry.callable, Array(), entry.type };
		const Variant *argv[4] = { &arguments[0], &arguments[1], &arguments[2], &arguments[3] };
		Variant target(performance);
		Variant result;
		GDExtensionCallError error;
		target.callp("add_custom_monitor", argv, 4, result, error);
		if (error.error != GDEXTENSION_CALL_OK) {
			LOG(WARN, "Could not publish the ", String(entry.name), " terrain monitor");
		}
	}
	_monitors_registered = true;
}

void Terrain3D::_unregister_debug_monitors() {
	if (!_monitors_registered) {
		return;
	}
	_monitors_registered = false;
	Performance *performance = Performance::get_singleton();
	if (!performance) {
		return;
	}
	// The monitors call back into this node, so they have to be gone before it is freed.
	for (const char *name : { "vt_cpu", "vt_cpu_peak", "avt_cpu", "svt_cpu", "cdlod_cpu",
				 "material_bytes", "pages_ready", "pages_pending", "pages_late" }) {
		const StringName id(_monitor_prefix + name);
		if (performance->has_custom_monitor(id)) {
			performance->remove_custom_monitor(id);
		}
	}
}

double Terrain3D::_monitor_cdlod_cpu_ms() const {
	return _terrain_mesher ? _terrain_mesher->get_cdlod_cpu_ms() : 0.0;
}

int64_t Terrain3D::_monitor_material_bytes() const {
	Terrain3DSurfaceBaker *producer = Object::cast_to<Terrain3DSurfaceBaker>(_vt.vt_baker.ptr());
	return producer ? producer->get_material_bytes() : 0;
}

int64_t Terrain3D::_monitor_pages_ready() const {
	Terrain3DSurfaceBaker *producer = Object::cast_to<Terrain3DSurfaceBaker>(_vt.vt_baker.ptr());
	return producer ? producer->get_ready_page_count() : 0;
}

int64_t Terrain3D::_monitor_pages_pending() const {
	Terrain3DSurfaceBaker *producer = Object::cast_to<Terrain3DSurfaceBaker>(_vt.vt_baker.ptr());
	return producer ? producer->get_pending_page_count() : 0;
}

void Terrain3D::_invalidate_render_geometry() {
	_vt.vt_source_snapshot.reset();
	_vt.avt_refinement.reset();
	_vt.avt_plan_key.clear();
	if (_vt.vt_page_pipeline) { _vt.vt_page_pipeline->reset(); }
	if (_vt.svt_page_pipeline) { _vt.svt_page_pipeline->reset(); }
	if (_terrain_mesher) { _terrain_mesher->invalidate_region_geometry(); }
}

void Terrain3D::_update_render_geometry() {
	if (_initialized && _is_inside_world && is_inside_tree() && _camera.is_valid() && _terrain_mesher) {
		_terrain_mesher->snap();
	}
}

void Terrain3D::__physics_process(const double p_delta) {
	if (!_initialized) {
		return;
	}
	if (!_camera.is_valid()) {
		LOG(DEBUG, "Camera is null, getting the current one");
		_grab_camera();
	}
	if (_tessellation_level > 0) {
		if (_terrain_mesher && _d_buffer_vp && _material.is_valid()) {
			// If clipmap target has moved enough, re-center buffer on the target.
			Vector2 target_pos_2d = v3v2(get_clipmap_target_position());
			real_t tessellation_density = 1.f / pow(2.f, _tessellation_level);
			real_t vertex_spacing = _vertex_spacing * tessellation_density;
			if (!(MAX(std::abs(_last_buffer_position.x - target_pos_2d.x), std::abs(_last_buffer_position.y - target_pos_2d.y)) < vertex_spacing)) {
				_last_buffer_position = target_pos_2d;
				RS->material_set_param(_material->get_buffer_material_rid(), "_target_pos", get_clipmap_target_position());
				_d_buffer_vp->set_update_mode(SubViewport::UPDATE_ONCE);
			}
		}
	}
	if (_ocean_enabled && _ocean_mesher) {
		_ocean_mesher->snap();
	}
	if (_light_target.is_valid()) {
		DirectionalLight3D *light = cast_to<DirectionalLight3D>(_light_target.ptr());
		if (light) {
			Color color = light->get_color() * light->get_param(DirectionalLight3D::PARAM_ENERGY);
			Vector3 direction = light->get_global_basis().get_column(2);
			if (_material.is_valid()) {
				_material->set_shader_param("_light_color", color);
				_material->set_shader_param("_light_direction", direction);
			}
			if (_ocean_material.is_valid()) {
				ShaderMaterial *ocean_shader_mat = Object::cast_to<ShaderMaterial>(_ocean_material.ptr());
				if (ocean_shader_mat) {
					ocean_shader_mat->set_shader_parameter("_light_color", color);
					ocean_shader_mat->set_shader_parameter("_light_direction", direction);
				}
			}
		}
	}
	if (_collision && _collision->is_dynamic_mode()) {
		_collision->update();
	}
	// Stream regions around the clipmap target, one budgeted step per tick.
	if (_streaming_enabled && _streamer && _streamer->is_enabled()) {
		_streamer->update(get_clipmap_target_position());
	}
	if (is_vt_editor_preview_active()) {
		// Explicit offline baking remains available; navigation and painting do not stream VT.
		if (!_vt.vt_svt_bake_queue.is_empty() || !_vt.vt_svt_bake_waiting.is_empty()) {
			_update_vt_service();
			_process_svt_bake(1);
		}
		return;
	}
	// VT streaming cost: everything the near field and the far field do on the main
	// thread for this tick, from reconfiguring the shared service to the baker budget.
	// Region streaming, collision and the mesher are outside this window.
	const uint64_t vt_started = Time::get_singleton()->get_ticks_usec();
	// The whole VT section as one zone, with one zone per phase inside it. A profiler
	// timeline then shows the terrain's cost under `terrain/...` instead of an unattributed
	// block between two engine frames.
	TerrainProfileZone vt_total_zone("vt");
	_register_debug_monitors();
	// The camera's motion is sampled once per tick, before anything plans from it: the
	// lead is what both views plan for, and a value updated per demand pass would differ
	// between them.
	_vt_update_motion_lead();
	// The budget a phase that can stop between two units of work reads before continuing.
	//
	// It is re-armed at the start of every phase, so `vt_frame_budget_ms` bounds what one
	// phase may spend rather than what the whole section may spend. A deadline shared by the
	// section was consumed by the service check and the far field before the near field ran,
	// so the near field found it already expired on every tick of a moving view, produced its
	// one-page floor and stopped - which is the shape that leaves a turning view refining in
	// visible blocks and a page arriving every other tick. Per phase, each of the three passes
	// is bounded by the number a profiler attributes the peak to.
	auto arm_phase_deadline = [&]() {
		_vt.vt_tick_deadline_us = _vt.vt_frame_budget_ms > 0.f
				? Time::get_singleton()->get_ticks_usec() + uint64_t(double(_vt.vt_frame_budget_ms) * 1000.0)
				: 0;
	};
	// Phase attribution for the tick: the service check, the near field's demand pass, the far
	// field's demand pass, the page-arrival fade, and the far-field bake. Without it a peak can
	// only be read as "VT was slow".
	uint64_t vt_mark = vt_started;
	auto vt_phase = [&vt_mark](double &r_phase) {
		const uint64_t now = Time::get_singleton()->get_ticks_usec();
		r_phase = double(now - vt_mark) / 1000.0;
		vt_mark = now;
	};
	auto traced = [](const char *p_name, auto &&p_body) {
		TerrainProfileZone zone(p_name);
		p_body();
	};
	traced("vt_service", [&] { _update_vt_service(); });
	vt_phase(_vt.vt_service_ms);
	// The demand passes below do not release the source workers they prime; the tick does, once every
	// phase has been measured. A worker woken inside a phase starts assembling on this thread's cores,
	// and a phase is wall time on this thread, so it would read as its own cost. See
	// Terrain3DPagePipeline::flush_wakes().
	_vt.vt_tick_active = true;
	// VT Setting supplies one production budget for both addressing views. The near field runs
	// first with its share and the far field runs second with the rest.
	//
	// The near field used to run first with half the budget and again in a "top-up" phase with
	// the remainder. The second call re-derived the same classification, re-retained the same
	// source queue, re-primed the same workers and republished the same statistics - about half
	// a millisecond of bookkeeping on a moving view - to buy at most one more page. One pass
	// buys the same pages for the cost of one; what the top-up gave the near field, its share
	// reserves instead.
	int vt_remaining = _vt.vt_debug_direct_material ? 4 : _vt.vt_pages_per_update;
	const bool svt_baking = !_vt.vt_svt_bake_queue.is_empty() || !_vt.vt_svt_bake_waiting.is_empty();
	const auto demand_pool = !_vt.vt_debug_direct_material && _vt.surface_vt ? _vt.surface_vt->get_page_pool() : nullptr;
	if (demand_pool) { demand_pool->begin_demand(); }
	// How much of this tick's page budget the near field may take, and what the far field gets
	// of it: the near field's half, then whatever the near field did not spend. The near field's
	// own report is what moves the remainder, and it is bounded by the share it was given, so
	// the remainder is a real budget rather than a count of re-queues.
	//
	// The far field cannot be treated as a small consumer on the strength of its page count
	// alone: a far page with no baked cell assembles its source on this thread, so a far page
	// that is not given a slot this tick is re-requested - and re-assembled - on the next one.
	// Too small a share is therefore more total work, not less, and it also changes when the
	// far field's startup grace ends - the frames in which a scene renders from the source
	// array instead of the missing-page diagnostic.
	// With no far field to share with, the near field takes the whole budget: it is then the only
	// consumer of it, and halving it halves how many pages a view fills in per tick. That case is
	// the whole of `vt_sectors`, `vt_metric_density`, `vt_region_ownership` and `vt_filtering`, and
	// four recorded-good scenarios failed when this line lost the conditional.
	const int avt_share = _vt.surface_svt_enabled ? MAX(1, vt_remaining / 2) : vt_remaining;
	int avt_produced = 0;
	// The tiers run in the order they are built in: the near field's pass publishes the
	// near-field addressing state the material reads and the far field's publishes the
	// far-field one, and a scene that only uses the near field must not have its first frame
	// decided by the far field's.
	//
	// The near field always gets a pass: even with nothing left to produce it re-marks its
	// resident pages as demanded, and a tick skipped here would let the pool evict the view.
	arm_phase_deadline();
	traced("vt_avt", [&] {
		if (_vt.surface_vt_enabled) { avt_produced = update_surface_vt(avt_share); }
	});
	vt_phase(_vt.vt_avt_ms);
	if (_vt.vt_avt_ms > _vt.vt_avt_peak_ms) {
		_vt.vt_avt_peak_ms = _vt.vt_avt_ms;
		// The stages of the pass that produced the peak, kept in their own dictionary. The live
		// one is overwritten by every pass, so a peak read from it describes whatever ran last -
		// which is never the peak, because the peak is by definition the pass that took longest.
		_vt.avt_peak_stats = _vt.avt_sector_stats.duplicate();
		_vt.avt_peak_stamp_us = Time::get_singleton()->get_ticks_usec();
	}
	// Refresh the far field: a world-space page grid that spans regions.
	const int svt_share = MAX(0, vt_remaining - MIN(vt_remaining, avt_produced));
	arm_phase_deadline();
	traced("vt_svt", [&] {
		if (_vt.surface_svt_enabled && svt_share > 0) { update_surface_svt(svt_share); }
	});
	vt_phase(_vt.vt_svt_ms);
	if (_vt.vt_svt_ms > _vt.vt_svt_peak_ms) { _vt.vt_svt_peak_ms = _vt.vt_svt_ms; }
	// Nothing runs between the near field and the far-field bake any more. The phase is still
	// reported so a profiler timeline keeps its shape and the tests keep their key.
	vt_phase(_vt.vt_topup_ms);
	// Page-arrival fades are published after both demand passes, because it is their readiness
	// checks that say a page arrived. The work is a per-slot countdown and, only while a page
	// is arriving, a one-texel-per-slot upload.
	traced("vt_fade", [&] { _update_vt_page_fade(); });
	vt_phase(_vt.vt_fade_ms);
	arm_phase_deadline();
	traced("vt_bake", [&] {
		if (svt_baking) {
			_vt.surface_svt->set_allocation_budget(MAX(0, vt_remaining));
			_process_svt_bake(MAX(0, vt_remaining));
			// The bake pass borrows the shared pool budget for this tick only. The pool is
			// shared by both views, and a finite budget left behind blocks the next tick's
			// acquisition - including its free-slot path - whenever the demand passes
			// early-return before resetting it.
			_vt.surface_svt->set_allocation_budget(-1);
		}
	});
	if (demand_pool) { demand_pool->end_demand(); }
	vt_phase(_vt.vt_bake_ms);
	_vt.vt_tick_active = false;
	_vt.vt_tick_deadline_us = 0;
	_vt.vt_cpu_ms = double(Time::get_singleton()->get_ticks_usec() - vt_started) / 1000.0;
	if (_vt.vt_cpu_ms > _vt.vt_cpu_peak_ms) { _vt.vt_cpu_peak_ms = _vt.vt_cpu_ms; }
	// The same numbers as plots, so a profiler graph shows the terrain's cost over time with
	// the same `terrain/` keyword the zones and the editor monitors use.
	const Terrain3DSurfaceBaker *producer = Object::cast_to<Terrain3DSurfaceBaker>(_vt.vt_baker.ptr());
	TerrainProfileZone::plot("vt_cpu_ms", _vt.vt_cpu_ms);
	TerrainProfileZone::plot("avt_cpu_ms", _vt.vt_avt_ms);
	TerrainProfileZone::plot("svt_cpu_ms", _vt.vt_svt_ms);
	TerrainProfileZone::plot("vt_peak_ms", _vt.vt_cpu_peak_ms);
	if (producer) {
		TerrainProfileZone::plot("material_mb", double(producer->get_material_bytes()) / (1024.0 * 1024.0));
		TerrainProfileZone::plot("pages_ready", double(producer->get_ready_page_count()));
		TerrainProfileZone::plot("pages_pending", double(producer->get_pending_page_count()));
	}
	TerrainProfileZone::plot("pages_late", double(_vt.avt_late_pages));
	TerrainProfileZone::plot("motion_speed", double(_vt.avt_motion_velocity.length()));
	// Last, and outside both the phases and the section: the source workers for everything the
	// phases just submitted start here, against the render rather than against the tick that
	// submitted their work. A worker started inside a phase competes for this thread's cores and
	// makes that phase read as its own cost; the section is this thread's own work, and starting
	// workers is not. Nothing is lost by waiting: work submitted by a phase cannot be assembled
	// within it, and the previous tick's work has had a whole frame to be assembled in.
	_flush_source_wakes();
}

bool Terrain3D::_vt_tick_expired() const {
	return _vt.vt_tick_deadline_us != 0 && Time::get_singleton()->get_ticks_usec() >= _vt.vt_tick_deadline_us;
}

/**
 * If running in the editor, grab the first editor viewport camera.
 * The edited_scene_root is excluded in case the user already has a Camera3D in their scene.
 */
void Terrain3D::_grab_camera() {
	if (IS_EDITOR) {
		_camera.set_target(EditorInterface::get_singleton()->get_editor_viewport_3d(0)->get_camera_3d());
		LOG(DEBUG, "Grabbing the first editor viewport camera: ", _camera.get_target());
	} else {
		_camera.set_target(get_viewport()->get_camera_3d());
		LOG(DEBUG, "Grabbing the in-game viewport camera: ", _camera.get_target());
	}
	if (!_camera.is_valid() && !_clipmap_target.is_valid()) {
		set_physics_process(false); // No target to follow, disable snapping until one set
		LOG(ERROR, "Cannot find clipmap target or active camera. LODs won't be updated. Set manually with set_clipmap_target() or set_camera()");
	}
}

void Terrain3D::_destroy_collision(const bool p_final) {
	LOG(INFO, "Destroying Collision");
	if (_collision) {
		_collision->destroy();
	}
	if (p_final) {
		memdelete_safely(_collision);
	}
}

void Terrain3D::_setup_terrain_mesher() {
	if (!_terrain_mesher) {
		LOG(DEBUG, "Creating mesher");
		_terrain_mesher = new Terrain3DMesher();
	}
	_terrain_mesher->initialize(this, _mesh_size, _mesh_lods, _tessellation_level, _vertex_spacing, _material->get_material_rid(), _render_layers, true);
}

void Terrain3D::_destroy_terrain_mesher(const bool p_final) {
	LOG(INFO, "Destroying terrain mesher");
	if (_terrain_mesher) {
		_terrain_mesher->destroy();
		if (p_final) {
			delete _terrain_mesher;
			_terrain_mesher = nullptr;
		}
	}
}

void Terrain3D::_setup_ocean_mesher() {
	if (_ocean_enabled) {
		if (!_ocean_mesher) {
			LOG(DEBUG, "Creating mesher");
			_ocean_mesher = new Terrain3DMesher();
		}
		_ocean_mesher->initialize(this, _ocean_mesh_size, _ocean_mesh_lods, _ocean_tessellation_level, _ocean_vertex_spacing, _ocean_material.is_valid() ? _ocean_material->get_rid() : RID(), _ocean_render_layers);
		_ocean_mesher->update_aabbs(_ocean_cull_margin, V2_ZERO);
		if (_ocean_material.is_valid()) {
			ShaderMaterial *ocean_shader_mat = Object::cast_to<ShaderMaterial>(_ocean_material.ptr());
			if (ocean_shader_mat) {
				ocean_shader_mat->set_shader_parameter("_mesh_size", _ocean_mesh_size);
				ocean_shader_mat->set_shader_parameter("_vertex_spacing", _ocean_vertex_spacing);
				ocean_shader_mat->set_shader_parameter("_vertex_density", 1.0f / _ocean_vertex_spacing);
				ocean_shader_mat->set_shader_parameter("_subdiv", pow(2.f, real_t(_ocean_tessellation_level)));
			}
		}
	}
}

void Terrain3D::_destroy_ocean_mesher(const bool p_final) {
	LOG(INFO, "Destroying ocean mesher");
	if (_ocean_mesher) {
		_ocean_mesher->destroy();
		if (p_final) {
			delete _ocean_mesher;
			_ocean_mesher = nullptr;
		}
	}
}

void Terrain3D::_setup_displacement_buffer() {
	if (!is_inside_tree()) {
		LOG(ERROR, "Not inside the tree, skipping displacement buffer setup");
		return;
	}
	_destroy_displacement_buffer();
	LOG(INFO, "Setting up displacement buffer");
	_d_buffer_vp = memnew(SubViewport);
	_d_buffer_vp->set_name("DBufferViewport");
	add_child(_d_buffer_vp, true);
	_d_buffer_vp->set_size(Vector2i(2, 2));
	_d_buffer_vp->set_disable_3d(true);
	_d_buffer_vp->set_update_mode(SubViewport::UPDATE_ONCE);
	_d_buffer_vp->set_disable_input(true);
	_d_buffer_vp->set_default_canvas_item_texture_filter(Viewport::DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST);

	_d_buffer_rect = memnew(ColorRect);
	_d_buffer_rect->set_name("DBufferRect");
	_d_buffer_vp->add_child(_d_buffer_rect, true);
	_d_buffer_rect->set_anchors_preset(Control::PRESET_FULL_RECT);
}

void Terrain3D::_update_displacement_buffer() {
	if (!_d_buffer_vp) {
		return;
	}
	if (_tessellation_level == 0) {
		_d_buffer_vp->set_size(V2I_ZERO);
		_d_buffer_rect->set_size(V2I_ZERO);
	} else {
		_d_buffer_vp->set_size(Vector2i(_mesh_size * 4 * _tessellation_level, _mesh_size * 4));
		_d_buffer_rect->set_size(Vector2i(_mesh_size * 4 * _tessellation_level, _mesh_size * 4));
		LOG(INFO, "Updating displacement buffer to Size: ", _d_buffer_vp->get_size());
		if (_material.is_valid() && _material->get_material_rid().is_valid()) {
			RS->canvas_item_set_material(_d_buffer_rect->get_canvas_item(), _material->get_buffer_material_rid());
			RS->material_set_param(_material->get_material_rid(), "_displacement_buffer", _d_buffer_vp->get_texture()->get_rid());
		}
	}
}

void Terrain3D::_build_containers() {
	_label_parent = memnew(Node3D);
	_label_parent->set_name("Labels");
	add_child(_label_parent, true);
}

void Terrain3D::_destroy_containers() {
	memdelete_safely(_label_parent);
}

void Terrain3D::_destroy_labels() {
	Array labels = _label_parent->get_children();
	LOG(DEBUG, "Destroying ", labels.size(), " region labels");
	for (const Variant &var : labels) {
		Node *label = cast_to<Node>(var);
		memdelete_safely(label);
	}
}

void Terrain3D::_destroy_displacement_buffer() {
	LOG(DEBUG, "Freeing d_buffer_rect");
	memdelete_safely(_d_buffer_rect);
	LOG(DEBUG, "Freeing d_buffer_vp");
	memdelete_safely(_d_buffer_vp);
}

void Terrain3D::_setup_mouse_picking() {
	if (!is_inside_tree()) {
		LOG(ERROR, "Not inside the tree, skipping mouse setup");
		return;
	}
	LOG(INFO, "Setting up mouse picker and get_intersection viewport, camera & screen quad");
	_mouse_vp = memnew(SubViewport);
	_mouse_vp->set_name("MouseViewport");
	add_child(_mouse_vp, true);
	_mouse_vp->set_size(V2I(2));
	_mouse_vp->set_scaling_3d_mode(Viewport::SCALING_3D_MODE_BILINEAR);
	_mouse_vp->set_update_mode(SubViewport::UPDATE_ONCE);
	_mouse_vp->set_disable_input(true);
	_mouse_vp->set_canvas_cull_mask(0);
	_mouse_vp->set_use_hdr_2d(true);
	_mouse_vp->set_anisotropic_filtering_level(Viewport::ANISOTROPY_DISABLED);
	_mouse_vp->set_default_canvas_item_texture_filter(Viewport::DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST);
	_mouse_vp->set_positional_shadow_atlas_size(0);
	_mouse_vp->set_positional_shadow_atlas_quadrant_subdiv(0, Viewport::SHADOW_ATLAS_QUADRANT_SUBDIV_DISABLED);
	_mouse_vp->set_positional_shadow_atlas_quadrant_subdiv(1, Viewport::SHADOW_ATLAS_QUADRANT_SUBDIV_DISABLED);
	_mouse_vp->set_positional_shadow_atlas_quadrant_subdiv(2, Viewport::SHADOW_ATLAS_QUADRANT_SUBDIV_DISABLED);
	_mouse_vp->set_positional_shadow_atlas_quadrant_subdiv(3, Viewport::SHADOW_ATLAS_QUADRANT_SUBDIV_DISABLED);

	_mouse_cam = memnew(Camera3D);
	_mouse_cam->set_name("MouseCamera");
	_mouse_vp->add_child(_mouse_cam, true);
	Ref<Environment> env;
	env.instantiate();
	env->set_tonemapper(Environment::TONE_MAPPER_LINEAR);
	_mouse_cam->set_environment(env);
	Ref<Compositor> comp;
	comp.instantiate();
	_mouse_cam->set_compositor(comp);
	_mouse_cam->set_projection(Camera3D::PROJECTION_ORTHOGONAL);
	_mouse_cam->set_size(0.1f);
	_mouse_cam->set_far(100000.f);

	_mouse_quad = memnew(MeshInstance3D);
	_mouse_quad->set_name("MouseQuad");
	_mouse_cam->add_child(_mouse_quad, true);
	Ref<QuadMesh> quad;
	quad.instantiate();
	quad->set_size(V2(0.1f));
	_mouse_quad->set_mesh(quad);
	String shader_code = String(
#include "shaders/gpu_depth.glsl"
	);
	Ref<Shader> shader;
	shader.instantiate();
	shader->set_code(shader_code);
	Ref<ShaderMaterial> shader_material;
	shader_material.instantiate();
	shader_material->set_shader(shader);
	_mouse_quad->set_surface_override_material(0, shader_material);
	_mouse_quad->set_position(Vector3(0.f, 0.f, -0.5f));

	// Set terrain, terrain shader, mouse camera, and screen quad to mouse layer
	uint32_t force_update_layer = _mouse_layer;
	_mouse_layer = 0u;
	set_mouse_layer(force_update_layer);
}

void Terrain3D::_destroy_mouse_picking() {
	LOG(DEBUG, "Freeing mouse_quad");
	memdelete_safely(_mouse_quad);
	LOG(DEBUG, "Freeing mouse_cam");
	memdelete_safely(_mouse_cam);
	LOG(DEBUG, "Freeing mouse_vp");
	memdelete_safely(_mouse_vp);
}

void Terrain3D::_destroy_instancer() {
	LOG(INFO, "Destroying Instancer");
	memdelete_safely(_instancer);
}

void Terrain3D::_destroy_streamer() {
	LOG(INFO, "Destroying Streamer");
	memdelete_safely(_streamer);
	_streaming_enabled = false;
}

void Terrain3D::set_streaming_enabled(const bool p_enabled) {
	_streaming_enabled = p_enabled;
	if (_streamer) {
		_streamer->set_enabled(p_enabled);
	}
	LOG(INFO, "Region streaming ", p_enabled ? "enabled" : "disabled");
}

///////////////////////////
// Protected Functions
///////////////////////////

// Notifications are defined in individual classes: Object, Node, Node3D
// Listed below in order of operation
void Terrain3D::_notification(const int p_what) {
	switch (p_what) {
			/// Startup notifications

		case NOTIFICATION_POSTINITIALIZE: {
			// Object initialized, before script is attached
			LOG(INFO, "NOTIFICATION_POSTINITIALIZE");
			_build_containers();
			break;
		}

		case NOTIFICATION_ENTER_WORLD: {
			// Node3D registered to new World3D resource
			// Sent on scene changes
			LOG(INFO, "NOTIFICATION_ENTER_WORLD");
			_is_inside_world = true;
			if (_terrain_mesher) {
				_terrain_mesher->update();
			}
			break;
		}

		case NOTIFICATION_ENTER_TREE: {
			// Node entered a SceneTree
			// Sent on scene changes
			LOG(INFO, "NOTIFICATION_ENTER_TREE");
			set_as_top_level(true); // Don't inherit transforms from parent. Global only.
			set_notify_transform(true);
			set_meta("_edit_lock_", true);
			_setup_mouse_picking();
			_setup_displacement_buffer();
			// Reload editor textures - Also see READY
			if (_free_editor_textures && !IS_EDITOR && _assets.is_valid() && !_assets->get_path().is_empty() && !_assets->get_path().contains("Terrain3DAssets")) {
				LOG(INFO, "free_editor_textures enabled, reloading Assets path: ", _assets->get_path());
				_assets = ResourceLoader::get_singleton()->load(_assets->get_path(), "", ResourceLoader::CACHE_MODE_IGNORE);
			}
			if (!RS->is_connected("frame_pre_draw", callable_mp(this, &Terrain3D::_update_render_geometry))) {
				RS->connect("frame_pre_draw", callable_mp(this, &Terrain3D::_update_render_geometry));
			}
			_initialize(); // Rebuild anything freed: meshes, collision, instancer
			set_physics_process(true);
			break;
		}

		case NOTIFICATION_READY: {
			// Node is ready
			LOG(INFO, "NOTIFICATION_READY");
			// Clear editor textures - also see ENTER_TREE
			if (_free_editor_textures && !IS_EDITOR && _assets.is_valid()) {
				if (_assets->get_path().contains("Terrain3DAssets")) {
					LOG(WARN, "free_editor_textures requires `Assets` be saved to a file. Do so, or disable the former to turn off this warning");
				} else {
					LOG(INFO, "free_editor_textures enabled, clearing texture assets");
					_assets->clear_textures();
				}
			}
			break;
		}

			/// Game Loop notifications

		case NOTIFICATION_PHYSICS_PROCESS: {
			// Node is processing one physics frame
			__physics_process(get_physics_process_delta_time());
			break;
		}

		case NOTIFICATION_TRANSFORM_CHANGED: {
			// Node3D or parent transform changed
			if (get_transform() != Transform3D()) {
				set_transform(Transform3D());
			}
			break;
		}

		case NOTIFICATION_VISIBILITY_CHANGED: {
			// Node3D visibility changed
			LOG(INFO, "NOTIFICATION_VISIBILITY_CHANGED");
			if (_terrain_mesher) {
				_terrain_mesher->update();
			}
			if (_ocean_mesher) {
				_ocean_mesher->update();
			}
			if (_instancer) {
				if (!is_visible_in_tree()) {
					_instancer->destroy();
				} else {
					_instancer->update_mmis(-1, V2I_MAX, true);
				}
			}
			break;
		}

		case NOTIFICATION_EXTENSION_RELOADED: {
			// Object finished hot reloading
			LOG(INFO, "NOTIFICATION_EXTENSION_RELOADED");
			break;
		}

		case NOTIFICATION_EDITOR_PRE_SAVE: {
			// Editor Node is about to save the current scene
			LOG(INFO, "NOTIFICATION_EDITOR_PRE_SAVE");
			if (_data_directory.is_empty()) {
				LOG(ERROR, "Data directory is empty. Set it to save regions to disk.");
			} else if (!_data) {
				LOG(DEBUG, "Save requested, but no valid data object. Skipping");
			} else {
				_data->save_directory(_data_directory);
			}
			if (!_material.is_valid()) {
				LOG(DEBUG, "Save requested, but no valid material. Skipping");
			} else {
				_material->save();
			}
			if (!_assets.is_valid()) {
				LOG(DEBUG, "Save requested, but no valid texture list. Skipping");
			} else {
				_assets->save();
			}
			break;
		}

		case NOTIFICATION_EDITOR_POST_SAVE: {
			// Editor Node finished saving current scene
			break;
		}

		case NOTIFICATION_CRASH: {
			// Godot's crash handler reports engine is about to crash
			// Only works on desktop if the crash handler is enabled
			LOG(INFO, "NOTIFICATION_CRASH");
			break;
		}

			/// Shut down notifications

		case NOTIFICATION_EXIT_TREE: {
			if (RS->is_connected("frame_pre_draw", callable_mp(this, &Terrain3D::_update_render_geometry))) {
				RS->disconnect("frame_pre_draw", callable_mp(this, &Terrain3D::_update_render_geometry));
			}
			// A tree that is gone is not being watched: the next tick that runs publishes them
			// again, and a node that never re-enters does not leave a callable into itself.
			_unregister_debug_monitors();
			_destroy_vt_service();
			// Node is about to exit a SceneTree
			// Sent on scene changes
			LOG(INFO, "NOTIFICATION_EXIT_TREE");
			set_physics_process(false);
			_destroy_terrain_mesher();
			_destroy_ocean_mesher();
			_destroy_instancer();
			_destroy_streamer();
			_destroy_surface_vt();
			_destroy_surface_svt();
			_destroy_mouse_picking();
			_destroy_displacement_buffer();
			if (_assets.is_valid()) {
				_assets->uninitialize();
			}
			if (_material.is_valid()) {
				_material->uninitialize();
			}
			_initialized = false;
			break;
		}

		case NOTIFICATION_EXIT_WORLD: {
			// Node3D unregistered from current World3D
			// Sent on scene changes
			LOG(INFO, "NOTIFICATION_EXIT_WORLD");
			_is_inside_world = false;
			break;
		}

		case NOTIFICATION_PREDELETE: {
			// The monitors call back into this node, so they go before anything else does.
			_unregister_debug_monitors();
			_destroy_vt_service();
			// Object is about to be deleted
			LOG(INFO, "NOTIFICATION_PREDELETE");
			_destroy_terrain_mesher(true);
			_destroy_ocean_mesher(true);
			_destroy_instancer();
			_destroy_streamer();
			_destroy_surface_vt();
			_destroy_surface_svt();
			_destroy_collision(true);
			_assets.unref();
			_material.unref();
			memdelete_safely(_data);
			_destroy_labels();
			_destroy_containers();
			break;
		}

		default:
			break;
	}
}

void Terrain3D::_validate_property(PropertyInfo &p_property) const {
	if (_tessellation_level == 0) {
		// Hide all displacement properties
		if (p_property.name == StringName("displacement_scale") ||
				p_property.name == StringName("displacement_sharpness") ||
				p_property.name == StringName("buffer_shader_override_enabled") ||
				p_property.name == StringName("buffer_shader_override")) {
			p_property.usage = PROPERTY_USAGE_NO_EDITOR;
		}
	}
	// Hide all ocean properties if not enabled
	if (!_ocean_enabled && p_property.name != StringName("ocean_enabled") &&
			p_property.name.begins_with("ocean_")) {
		p_property.usage = PROPERTY_USAGE_NO_EDITOR;
	}
}

