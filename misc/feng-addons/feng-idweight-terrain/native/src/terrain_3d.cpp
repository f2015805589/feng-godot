// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3D, part 1 of 3: the node, its lifecycle and its frame schedule.

// One of three files that define the node. This one owns `_initialize()`, the physics tick
// (`__physics_process()`, which `_notification()` calls in place of `_process()` - see the issue
// linked on the definition), the render-geometry invalidation the VT service and the mesher ask
// for, and `_notification()` / `_validate_property()` under the protected banner.
//
// The rest of the class is defined in the file that owns that concern:
//   terrain_3d_wiring.cpp            the subsystem nodes and GPU objects this node creates and releases
//   terrain_3d_monitors.cpp          this node's custom Performance monitors
//   terrain_3d_vt_service*.cpp       the virtual texture service: settings, lifetime, pages, bake
//   terrain_3d_surface_views*.cpp    the two surface views and their demand passes
//   terrain_3d_geometry.cpp          region-grid triangle generation
//   terrain_3d_properties.cpp        configuration setters
//   terrain_3d_queries.cpp           raycasts, baked meshes, nav source geometry, warnings
//   terrain_3d_bindings.cpp          ClassDB bindings and property registration
//   terrain_3d_profile.h             the `terrain/...` profiler zone and plot helper

#include "terrain_3d.h"

#include "logger.h"
#include "terrain_3d_profile.h"
#include "terrain_3d_surface_baker.h"
#include "terrain_3d_util.h"

#include <godot_cpp/classes/compositor.hpp>
#include <godot_cpp/classes/directional_light3d.hpp>
#include <godot_cpp/classes/editor_interface.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/shader_material.hpp>
#include <godot_cpp/classes/time.hpp>

// Initialize static member variable
Terrain3D::DebugLevel Terrain3D::debug_level{ ERROR };

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
	// The services are assembled from the delivery matrix, not created unconditionally: a
	// configuration whose four cells are all `Direct` owns no view, no page table, no array family
	// and no VT shader arm. See docs/vt_delivery_assembly.md.
	_resolve_vt_delivery(false);
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

void Terrain3D::_invalidate_render_geometry() {
	_vt.vt_source_snapshot.reset();
	_vt.avt_refinement.reset();
	invalidate_avt_plan_key(_vt.avt_plan.key);
	if (_vt.vt_page_pipeline) { _vt.vt_page_pipeline->reset(); }
	if (_vt.svt_page_pipeline) { _vt.svt_page_pipeline->reset(); }
	if (_terrain_mesher) { _terrain_mesher->invalidate_region_geometry(); }
}

void Terrain3D::_update_render_geometry() {
	if (_initialized && _is_inside_world && is_inside_tree() && _camera.is_valid() && _terrain_mesher) {
		_terrain_mesher->snap();
	}
}

/**
 * This is a proxy for _process(delta) called by _notification() due to
 * https://github.com/godotengine/godot-cpp/issues/1022
 */

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
		if (_vt.bake.busy()) {
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
	// The page budget follows the same sample: a snap turn, a displacement cut or a fast run raises
	// the near field's rate for the ticks it lasts and the governor decays it back to the stable tier
	// afterwards. It runs before the service check and the demand passes, which is what lets the
	// producer's frame budget, the source queue window and the pass's own clamp all read one tier.
	_vt_update_avt_page_budget();
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
	// The rings run first, and only when a cell selects the method. They are the only production that
	// does not go through the shared pool, so they are outside the demand block below, and running
	// them before the service phase means the service publishes a ring's texture in the same tick the
	// ring produced into it. **A configuration with no cell on `Clipmap` does not enter this at all**:
	// no focus read, no group scan, no phase - the same rule the two demand passes follow, so a
	// method nobody selected costs nothing rather than costing a check. A ring is entered only while
	// a cell still selects it: the object staying (a deselection stops a service rather than freeing
	// it) is not a reason to spend its budget.
	if (has_clipmap_delivery()) {
		traced("vt_clipmap", [&] {
			_vt.clipmap_produced_texels = 0;
			const Vector2 focus = v3v2(get_clipmap_target_position());
			for (int group = 0; group < TerrainVT::GROUP_COUNT; group++) {
				Terrain3DClipmap *ring = _vt.clipmap[group].get();
				if (ring == nullptr || !_vt.delivery.group_uses(TerrainVT::ChannelGroup(group), TerrainVT::Delivery::Clipmap)) {
					continue;
				}
				_vt.clipmap_produced_texels += ring->update(focus, _vt.clipmap_budget_texels);
				// And whatever a producer bakes out of what the ring produced - the *rects* it produced,
				// offered under the same budget they were produced under. The ring carries the layers, the
				// bake belongs to the shader's owner, and this is where the two meet: a ring whose channel
				// declares no baked layers answers without touching the device, and one that does has its
				// rects dispatched by the next render callback, reported back a call later
				// (see `Terrain3DSurfaceBaker::queue_clipmap_ring()`).
				if (Terrain3DSurfaceBaker *baker = Object::cast_to<Terrain3DSurfaceBaker>(_vt.vt_baker.ptr())) {
					baker->queue_clipmap_ring(ring, _vt.clipmap_budget_texels);
				}
			}
			// The material group's detail layer is the ring's own finer half and it runs in this
			// phase rather than beside it: the phase is the only production pass a cell that selects
			// `Clipmap` is guaranteed, the layer exists while the material group is delivered by the
			// ring, and a tick that runs nowhere else is what keeps the editor drawing for a tile
			// whose source or bake is still in flight (`_vt_has_streaming_work()` is the other half).
			// It early-returns when the layer was never created, so a height-only ring pays a null
			// check and a group whose detail switch is off owns nothing.
			_update_vt_material_detail();
		});
		vt_phase(_vt.vt_clipmap_ms);
		// A ring that moved a level, turned its ring or changed which levels are current is a uniform
		// rebind: the shader's copy of the ring's addressing is stale from that moment, and serving it
		// would read the texel a *previous* centre put under a world position. The stamp is the ring's
		// own, so this is one comparison per ring on a tick that changed nothing.
		_update_vt_clipmap_arm();
	} else {
		_vt.clipmap_produced_texels = 0;
		_vt.vt_clipmap_ms = 0.0;
		// No group selects the ring, so the material detail layer - which is gated on exactly that -
		// cannot be ticked here. Its phase reading is reset so a panel never shows the last tick's
		// cost as this one's.
		_vt.vt_detail_ms = 0.0;
	}
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
	const bool svt_baking = _vt.bake.busy();
	// The pool belongs to the shared service, not to the near view: a configuration that selects
	// only the far field still has one, and it is the far view that holds it.
	const auto demand_pool = !_vt.vt_debug_direct_material
			? (_vt.surface_vt ? _vt.surface_vt->get_page_pool()
							  : (_vt.surface_svt ? _vt.surface_svt->get_page_pool() : nullptr))
			: nullptr;
	if (demand_pool) { demand_pool->begin_demand(); }
	// How much of this tick's page budget the near field may take, and what the far field gets
	// of it: the near field's share, then whatever the near field did not spend. The near field's
	// own report is what moves the remainder, and it is bounded by the share it was given, so
	// the remainder is a real budget rather than a count of re-queues.
	//
	// The far field cannot be treated as a small consumer on the strength of its page count
	// alone: a far page with no baked cell assembles its source on this thread, so a far page
	// that is not given a slot this tick is re-requested - and re-assembled - on the next one.
	// Too small a share is therefore more total work, not less, and it also changes when the
	// far field's startup grace ends - the frames in which a scene renders from the source
	// array instead of the missing-page diagnostic. The split also stays even for a measured
	// reason, not an inherited one; `_avt_tick_allowance()` records the run that says so.
	// With no far field to share with, the near field takes the whole budget: it is then the only
	// consumer of it, and halving it halves how many pages a view fills in per tick. That case is
	// the whole of `vt_sectors`, `vt_metric_density`, `vt_region_ownership` and `vt_filtering`, and
	// four recorded-good scenarios failed when this line lost the conditional.
	//
	// The rule now has one home (`_avt_tick_allowance()`), because the near field's plan is sized
	// against the same number: its unsampled tail is capped at what one refresh window can produce
	// with this allowance. Two spellings of the split would let the plan outrun the pass it is
	// served from, which is the defect `docs/vt_reference_avt_alignment.md` section 7.7 records.
	const int avt_share = _avt_tick_allowance();
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
		if (has_avt_delivery()) { avt_produced = update_surface_vt(avt_share); }
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
		if (has_svt_delivery() && svt_share > 0) { update_surface_svt(svt_share); }
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
	// The turn's own reading, beside the speed it is the counterpart of: a view that streams while
	// turning shows as a rate with no lead to match it.
	TerrainProfileZone::plot("motion_turn_deg_s", Math::rad_to_deg(double(_vt.avt_motion_turn.length())));
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
