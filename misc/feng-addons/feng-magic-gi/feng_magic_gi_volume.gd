@tool
class_name FMagicGIVolume
extends Node3D
## Selects one indirect-light provider for this volume: baked surface PRT or realtime Surfels.

enum GIMode {
	PRT_MAGIC_GI,
	SURFEL_MAGIC_GI,
}

signal bake_status_changed
signal surface_refresh_completed(generation: int, success: bool)

const Runtime = preload("feng_magic_gi_runtime.gd")
const Baker = preload("feng_magic_gi_baker.gd")
const VolumeSourceBaker = preload("feng_magic_gi_volume_source_baker.gd")
const VolumeSourceChunk = preload("feng_magic_gi_volume_source_chunk.gd")
const PreparedArchive = preload("feng_magic_gi_prepared_brick_archive.gd")
const PagedSourceBaker = preload("feng_magic_gi_paged_source_baker.gd")
const Placement = preload("feng_magic_gi_placement.gd")
const Viz = preload("feng_magic_gi_viz.gd")
const Data = preload("feng_magic_gi_data.gd")
const Manifest = preload("feng_magic_gi_manifest.gd")
const SceneTracker = preload("feng_magic_gi_scene_tracker.gd")
const Preview = preload("feng_magic_gi_preview.gd")
const ProbeLayout = preload("feng_magic_gi_probe_layout.gd")
const SurfelSettings = preload("feng_magic_gi_surfel_settings.gd")
const ZERO_TRANSFER_DIAGNOSTIC := "本次几何间接传输与天空可见性均为零。请检查布点与静态采样，并确保 Volume 和 Bake Distance 覆盖可产生反弹的表面。要烘焙自发光贡献，请启用发光表面并重新 Bake。"
const BAKE_QUALITY_NAMES := ["Draft", "Final", "High"]
const BAKE_QUALITY_SAMPLES := [256, 1024, 2048]
const LAYOUT_IDLE_DEBOUNCE_MSEC := 280
const PRT_ONLY_PROPERTIES := [
	"probe_spacing", "surface_offset", "adaptive_placement", "minimum_probe_spacing",
	"bake_samples", "bake_bounces", "bake_distance", "terrain_reflectance",
	"fallback_material_reflectance", "use_clv", "clv_cell_size", "clv_cells_per_frame",
	"clv_cache_backend",
	"chunked_baking", "management_block_size", "core_page_size", "bake_output_directory",
	"stream_distance", "stream_hysteresis", "gi_radius_m", "cpu_resident_budget_mib",
	"gpu_resident_budget_mib", "upload_budget_mib_per_frame", "max_inflight_page_loads",
	"sun", "lighting_environment", "show_probes", "show_sh_probes", "display_probes_by_clv",
	"probe_clv_level", "probe_clv_view", "bake_data",
	"bake_manifest",
]
const PRT_ONLY_GROUPS := ["Runtime Cache", "Paged Baking", "Page Streaming"]

@export_enum("PRT MagicGI", "Surfel MagicGI") var gi_mode: int = GIMode.PRT_MAGIC_GI:
	set(value):
		var next_mode := clampi(int(value), GIMode.PRT_MAGIC_GI, GIMode.SURFEL_MAGIC_GI)
		if gi_mode == next_mode:
			return
		gi_mode = next_mode
		_on_gi_mode_changed()

@export var surfel_settings: FMagicGISurfelSettings:
	set(value):
		var next_settings: FMagicGISurfelSettings = value if value != null else SurfelSettings.new()
		if surfel_settings == next_settings:
			return
		if surfel_settings != null and surfel_settings.changed.is_connected(_on_surfel_settings_changed):
			surfel_settings.changed.disconnect(_on_surfel_settings_changed)
		surfel_settings = next_settings
		if not surfel_settings.changed.is_connected(_on_surfel_settings_changed):
			surfel_settings.changed.connect(_on_surfel_settings_changed)
		_on_surfel_settings_changed()

func _init() -> void:
	# Give each Volume independent editable settings; a class default Resource could
	# otherwise be shared by several instances in the same scene.
	surfel_settings = SurfelSettings.new()

func is_surfel_mode() -> bool:
	return gi_mode == GIMode.SURFEL_MAGIC_GI

func _on_gi_mode_changed() -> void:
	notify_property_list_changed()
	_preview_revision += 1
	if is_surfel_mode():
		cancel_bake()
		_source_validation_pending = false
		_source_validation_reset_legacy_baseline = false
		_source_validation_queued = false
		_layout_queued = false
		_layout_refresh_deadline_msec = 0
		Runtime.set_preview_requested(self, false)
		if _viz != null and is_instance_valid(_viz):
			_viz.visible = false
	elif is_inside_tree():
		_restore_prt_probe_layout()
		if _viz != null and is_instance_valid(_viz):
			_viz.visible = true
		_current_quick_source_signature = -1
		if _has_saved_bake():
			_schedule_saved_source_validation()
		else:
			_mark_layout_stale()
		_sync_preview_exposure_request()
		_refresh_viz()
	if is_inside_tree():
		Runtime.publish(self)
	update_configuration_warnings()
	bake_status_changed.emit()

func _on_surfel_settings_changed() -> void:
	if not is_inside_tree():
		return
	if is_surfel_mode():
		Runtime.publish(self)
		bake_status_changed.emit()

func _validate_property(property: Dictionary) -> void:
	var property_name := String(property.get("name", ""))
	if is_surfel_mode() and (property_name in PRT_ONLY_PROPERTIES \
			or property_name in PRT_ONLY_GROUPS):
		# Hide PRT controls without removing their serialized values, so switching
		# modes never discards an existing bake or its settings.
		property["usage"] = PROPERTY_USAGE_STORAGE
	elif uses_free_space_clv_bake() and property_name in [
			"chunked_baking", "management_block_size", "core_page_size",
			"probe_spacing", "surface_offset", "adaptive_placement", "minimum_probe_spacing",
			"stream_distance", "stream_hysteresis"]:
		# Prepared CLV uses per-level bricks and a strict spherical radius.
		# They do not configure this baker's .25 m source/prepared lattice.
		property["usage"] = PROPERTY_USAGE_STORAGE
	elif not is_surfel_mode() and property_name == "surfel_settings":
		property["usage"] = PROPERTY_USAGE_STORAGE
	elif property_name in ["probe_clv_level", "probe_clv_view"] and not display_probes_by_clv:
		property["usage"] = PROPERTY_USAGE_STORAGE

class SurfaceRefreshRequest:
	extends RefCounted
	signal completed
	var finished := false
	var succeeded := false
	var collection_finished := false

	func mark_collection_finished(success: bool) -> void:
		collection_finished = true
		if not success:
			resolve(false)

	func resolve(success: bool) -> void:
		if finished:
			return
		finished = true
		succeeded = success
		completed.emit()

@export var size := Vector3(10.0, 10.0, 10.0):
	set(value):
		var next_size := (value if value.is_finite() else Vector3(10.0, 10.0, 10.0)).max(Vector3.ONE * 0.01)
		if size == next_size:
			return
		size = next_size
		_settings_changed()
		if _viz != null:
			Viz.update_box(self, _viz)
@export_range(0.1, 16.0, 0.1, "or_greater", "suffix:m") var probe_spacing := 0.25:
	set(value):
		probe_spacing = clampf(value, 0.1, 4096.0)
		_settings_changed()
@export_range(0.001, 0.2, 0.001, "suffix:m") var surface_offset := 0.03:
	set(value):
		surface_offset = clampf(value, 0.001, 0.2)
		_settings_changed()
## Keep the requested probe spacing uniform; adaptive refinement can be enabled explicitly.
@export var adaptive_placement := false:
	set(value):
		adaptive_placement = value
		_settings_changed()
@export_range(0.1, 1.0, 0.025, "suffix:m") var minimum_probe_spacing := 0.25:
	set(value):
		minimum_probe_spacing = clampf(value, 0.1, 1.0) if is_finite(value) else 0.25
		_settings_changed()
@export_range(1, 4096, 1, "or_greater") var bake_samples := 256:
	set(value):
		var clamped := clampi(value, 1, 65536)
		if bake_samples == clamped:
			return
		bake_samples = clamped
		_sample_quality_changed()
@export_range(1, 4, 1) var bake_bounces := 2:
	set(value):
		bake_bounces = clampi(value, 1, 8)
		_settings_changed()
@export_range(1.0, 128.0, 1.0, "suffix:m") var bake_distance := 32.0:
	set(value):
		bake_distance = clampf(value, 1.0, 4096.0)
		_settings_changed()
## Terrain3D has no general CPU material evaluation; this scalar supplies its diffuse albedo.
@export_range(0.0, 1.0, 0.01) var terrain_reflectance := 0.5:
	set(value):
		terrain_reflectance = clampf(value, 0.0, 1.0)
		_settings_changed()
## Used for missing or CPU-unsupported materials, including ShaderMaterial.
@export_range(0.0, 1.0, 0.01) var fallback_material_reflectance := 0.5:
	set(value):
		fallback_material_reflectance = clampf(value, 0.0, 1.0)
		_settings_changed()
@export_range(0.0, 8.0, 0.01) var gi_strength := 1.0
@export_group("Runtime Cache")
@export var use_clv := true:
	set(value):
		if use_clv == value:
			return
		use_clv = value
		notify_property_list_changed()
		_settings_changed(false)
## Backend 1 relights resident CLV blocks from the baked directional TransferMatrix.
## Baked total-indirect SH is not a dynamic relighting input.
@export_enum("Legacy per-probe/pixel PRT", "MagicDawn CLV Block PRT (dynamic)") var clv_cache_backend := 1:
	set(value):
		var next := clampi(int(value), 0, 1)
		if clv_cache_backend == next:
			return
		clv_cache_backend = next
		notify_property_list_changed()
		if is_inside_tree():
			Runtime.publish(self)
## CLV cell spacing is independent of the PRT probe spacing.
@export_range(0.1, 2.0, 0.025, "suffix:m") var clv_cell_size := 0.25:
	set(value):
		var next := clampf(value, 0.1, 2.0) if is_finite(value) else 0.25
		if is_equal_approx(clv_cell_size, next):
			return
		clv_cell_size = next
		_settings_changed(false)
@export_range(32, 512, 32) var clv_cells_per_frame := 256:
	set(value):
		clv_cells_per_frame = clampi(value, 32, 512)
@export_group("")
@export_group("Paged Baking")
## New bakes use immutable sparse pages. Existing bake_data remains readable until Bake is requested.
@export var chunked_baking := true:
	set(value):
		if chunked_baking == value:
			return
		chunked_baking = value
		_settings_changed()
@export_range(128.0, 1024.0, 128.0, "suffix:m") var management_block_size := 512.0:
	set(value):
		management_block_size = clampf(value, 128.0, 1024.0)
		_settings_changed()
@export_range(8.0, 64.0, 8.0, "suffix:m") var core_page_size := 32.0:
	set(value):
		core_page_size = clampf(value, 8.0, 64.0)
		_settings_changed()
@export_dir var bake_output_directory := "":
	set(value):
		bake_output_directory = value.strip_edges().trim_suffix("/")
		_settings_changed(false)
@export_group("Page Streaming")
## Camera-centered spherical loading and shading cutoff for paged CLV PRT.
## The intersecting boundary brick retains its one-cell interpolation halo.
@export_range(32.0, 512.0, 16.0, "suffix:m") var gi_radius_m := 512.0:
	set(value):
		gi_radius_m = clampf(value, 32.0, 512.0) if is_finite(value) else 512.0
@export_range(32.0, 512.0, 16.0, "suffix:m") var stream_distance := 128.0:
	set(value):
		stream_distance = clampf(value, 32.0, 512.0)
@export_range(0.0, 128.0, 4.0, "suffix:m") var stream_hysteresis := 32.0:
	set(value):
		stream_hysteresis = clampf(value, 0.0, 128.0)
@export_range(32, 4096, 32, "suffix:MiB") var cpu_resident_budget_mib := 1024:
	set(value):
		cpu_resident_budget_mib = clampi(value, 32, 4096)
@export_range(64, 512, 32, "suffix:MiB") var gpu_resident_budget_mib := 128:
	set(value):
		gpu_resident_budget_mib = clampi(value, 64, 512)
## Legacy page-upload budget. Prepared CLV reports this as a telemetry threshold;
## new spatial operators are uploaded atomically, not deferred across frames.
@export_range(4, 64, 4, "suffix:MiB") var upload_budget_mib_per_frame := 16:
	set(value):
		upload_budget_mib_per_frame = clampi(value, 4, 64)
@export_range(1, 2, 1) var max_inflight_page_loads := 2:
	set(value):
		max_inflight_page_loads = clampi(value, 1, 2)
@export_group("")
## Optional explicit distant light/environment; otherwise the matching World3D is scanned.
@export var sun: DirectionalLight3D
## Legacy scene compatibility. Sky diffuse is supplied by FengSkyLight; this
## Environment is no longer projected implicitly into Magic GI lighting.
@export var lighting_environment: Environment
@export var show_probes := true:
	set(value):
		show_probes = value
		_sync_preview_exposure_request()
		_refresh_viz()
@export var show_sh_probes := false:
	set(value):
		show_sh_probes = value
		_sync_preview_exposure_request()
		_refresh_viz()
## Display the active view's resident CLV cells instead of the baked source probes.
## Both marker colors and SH spheres use the current relit lighting. Editor only.
@export var display_probes_by_clv := false:
	set(value):
		display_probes_by_clv = value
		_preview_revision += 1
		notify_property_list_changed()
		_sync_preview_exposure_request()
		_refresh_viz()
## All levels shows cascade shells; select a level to inspect its complete grid.
@export_enum("All Levels:-1", "L0:0", "L1:1", "L2:2", "L3:3", "L4:4", "L5:5", "L6:6", "L7:7", "L8:8", "L9:9") var probe_clv_level := -1:
	set(value):
		probe_clv_level = clampi(value, -1, 9)
		_preview_revision += 1
		_refresh_viz()
## Select which editor 3D viewport supplies the resident CLV layout in split views.
@export_enum("Viewport 1:0", "Viewport 2:1", "Viewport 3:2", "Viewport 4:3") var probe_clv_view := 0:
	set(value):
		probe_clv_view = clampi(value, 0, 3)
		_preview_revision += 1
		_refresh_viz()
@export var enabled := true:
	set(value):
		enabled = value
		Runtime.publish(self)
@export var bake_data: Data:
	set(value):
		if bake_data == value:
			return
		if bake_data != null and bake_data.changed.is_connected(_on_data_changed):
			bake_data.changed.disconnect(_on_data_changed)
		bake_data = value
		if bake_data != null and not bake_data.changed.is_connected(_on_data_changed):
			bake_data.changed.connect(_on_data_changed)
		if bake_data != null:
			bake_data._invalidate_baked_indirect_sh_validation_cache()
			bake_data.has_baked_indirect_sh() # One-time payload/provenance validation at assignment.
		_invalidate_data_cache()
		_data_change_revision += 1
		_preview_revision += 1
		_preview_layout_match_key = ""
		if not is_surfel_mode():
			_restore_prt_probe_layout()
		_clear_candidate_layout()
		if is_inside_tree() and not _bake_assigning_data:
			_bake_generation += 1
			if not is_surfel_mode():
				_mark_layout_stale()
				_schedule_saved_source_validation(true)
			Runtime.publish(self)
@export var bake_manifest: Manifest:
	set(value):
		if bake_manifest == value:
			return
		if bake_manifest != null and bake_manifest.changed.is_connected(_on_manifest_changed):
			bake_manifest.changed.disconnect(_on_manifest_changed)
		bake_manifest = value
		if bake_manifest != null:
			if not bake_manifest.changed.is_connected(_on_manifest_changed):
				bake_manifest.changed.connect(_on_manifest_changed)
			bake_manifest.has_baked_indirect_sh() # Prime strict backend-1 validation once on load/publish.
		if not is_surfel_mode():
			_restore_prt_probe_layout()
		if is_inside_tree() and not _bake_assigning_manifest:
			_settings_changed()
			_schedule_saved_source_validation(true)

var cpu_resident_budget_bytes: int:
	get:
		return cpu_resident_budget_mib * 1024 * 1024
var gpu_resident_budget_bytes: int:
	get:
		return gpu_resident_budget_mib * 1024 * 1024
var upload_budget_bytes_per_frame: int:
	get:
		return upload_budget_mib_per_frame * 1024 * 1024

var probe_positions := PackedVector3Array()
var probe_surface_positions := PackedVector3Array()
var probe_normals := PackedVector3Array()
var probe_spacings := PackedFloat32Array()
var _candidate_probe_positions := PackedVector3Array()
var _candidate_probe_surface_positions := PackedVector3Array()
var _candidate_probe_normals := PackedVector3Array()
var _candidate_probe_spacings := PackedFloat32Array()
var _candidate_layout_ready := false
var _candidate_layout_current := false
var _candidate_layout_revision := 0
var _viz: Node3D
var _viz_queued := false
var _viz_preview_revision := -1
var _viz_view_revision := -1
var _layout_queued := false
var _layout_dirty := false
var _layout_stale := false
var _layout_refresh_deadline_msec := 0
var _layout_epoch := 0
var _probe_layout_revision := 0
var _preview_revision := 0
var _data_change_revision := 0
var _preview_layout_match_key := ""
var _preview_layout_match_value := false
var _baking := false
var _bake_start_pending := false
var _bake_cancel_requested := false
var _refresh_active := false
var _refresh_pending := false
var _refresh_cancel_requested := false
var _refresh_request_generation := 0
var _refresh_requests: Dictionary = {}
var _active_refresh_coordinator: Node
var _active_refresh_generation := -1
var _refresh_completed_generation := 0
var _refresh_last_success := false
var _refresh_phase := ""
var _refresh_progress_completed := 0
var _refresh_progress_total := -1
var _next_refresh_status_msec := 0
var _candidate_viz_generation := 0
var _bake_assigning_data := false
var _bake_assigning_manifest := false
var _streamed_bake_completed_pages := 0
var _streamed_bake_total_pages := 0
var _free_space_bake_stage := ""
var _bake_generation := 0
var _next_geometry_check := 0
var _quick_scene_signature := 0
var _pending_scene_signature := 0
var _current_scene_signature := 0
var _current_watch_signature := 0
var _current_quick_source_signature := 0
var _current_stable_source_signature := 0
var _legacy_watch_baseline_signature := 0
var _source_watch_stale := false
var _legacy_manifest_unverified := false
var _exact_scene_signature_available := false
var _source_validation_pending := false
var _source_validation_queued := false
var _source_validation_reset_legacy_baseline := false
var _validity_instance_id := 0
var _validity_bake_version := -1
var _validity_checked := false
var _cached_data_valid := false
var _cached_has_nonzero_indirect_transport := false
var _scene_signature_checked := false
var _last_emission_warning := ""
var _placement_warning_message := ""
var _visibility_upgrade_attempt := 0

func _enter_tree() -> void:
	set_notify_transform(true)
	set_process(true)
	if bake_data != null:
		bake_data.has_baked_indirect_sh()
	if bake_manifest != null:
		bake_manifest.has_baked_indirect_sh()
		bake_manifest.total_probe_count()
	Runtime.register(self)
	_sync_preview_exposure_request()

func _ready() -> void:
	if is_surfel_mode():
		_source_validation_pending = false
		_source_validation_queued = false
		_layout_queued = false
		Runtime.set_preview_requested(self, false)
		Runtime.publish(self)
		_refresh_viz()
		return
	_restore_prt_probe_layout()
	_current_watch_signature = SceneTracker.quick_signature_uncached(self)
	_current_quick_source_signature = SceneTracker.quick_source_signature_uncached(self)
	_quick_scene_signature = _current_watch_signature
	_pending_scene_signature = _current_watch_signature
	_current_scene_signature = 0
	_current_stable_source_signature = 0
	_scene_signature_checked = false
	_legacy_watch_baseline_signature = _current_watch_signature
	_source_watch_stale = false
	_legacy_manifest_unverified = false
	_exact_scene_signature_available = false
	if _has_saved_bake():
		_schedule_saved_source_validation(true)
	_layout_stale = false
	if _has_saved_bake():
		# Preserve saved world-space anchors while the one deferred source check
		# waits for every node and world in the loaded scene to finish entering.
		_layout_dirty = false
		_layout_queued = false
		_layout_refresh_deadline_msec = 0
		Viz.set_layout_stale(_viz, _layout_stale)
		_refresh_viz()
	else:
		_rebuild_probes()

func _exit_tree() -> void:
	_bake_generation += 1
	var active_refresh_generation := _active_refresh_generation
	var active_refresh_request: SurfaceRefreshRequest = \
			_refresh_requests.get(active_refresh_generation)
	var worker_will_resolve_request := _active_refresh_coordinator != null \
			and active_refresh_request != null \
			and not active_refresh_request.collection_finished
	_refresh_request_generation += 1
	_refresh_pending = false
	_cancel_active_surface_refresh()
	_active_refresh_coordinator = null
	_active_refresh_generation = -1
	if not worker_will_resolve_request:
		_resolve_all_surface_refresh_requests(false)
	else:
		_resolve_surface_refresh_requests_except(active_refresh_generation)
	_candidate_viz_generation += 1
	Runtime.set_preview_requested(self, false)
	Runtime.unregister(self)

func _process(_delta: float) -> void:
	Runtime.tick()
	if is_surfel_mode():
		return
	if Engine.is_editor_hint() and (show_probes or show_sh_probes):
		_update_preview_if_changed()
	var now := Time.get_ticks_msec()
	if _source_validation_pending and not _source_validation_queued and not is_baking():
		_schedule_saved_source_validation()
	if _layout_dirty and now >= _layout_refresh_deadline_msec and not is_baking():
		_settle_layout_change()
	if now >= _next_geometry_check and not is_baking():
		_next_geometry_check = now + 1000
		var quick_source_signature := SceneTracker.quick_source_signature(self)
		if quick_source_signature != _current_quick_source_signature:
			_current_quick_source_signature = quick_source_signature
			_current_watch_signature = SceneTracker.quick_signature(self)
			_quick_scene_signature = _current_watch_signature
			_pending_scene_signature = _current_watch_signature
			if _has_saved_bake():
				_source_watch_stale = true
				_layout_stale = true
				Viz.set_layout_stale(_viz, true)
				_schedule_saved_source_validation()
				_schedule_layout_settle()
			else:
				_mark_layout_stale(false)
		Runtime.refresh_emission_diagnostics(self)
		var emission_warning := Runtime.emission_warning(self)
		if emission_warning != _last_emission_warning:
			_last_emission_warning = emission_warning
			update_configuration_warnings()

func has_bake() -> bool:
	if not is_inside_tree() or not _scene_signature_checked or _layout_dirty or _layout_stale:
		return false
	return _saved_bake_matches_current()

## True when the saved resource is structurally sound and can still be sampled,
## even if the current scene/layout no longer matches the bake.
func has_usable_bake() -> bool:
	if bake_manifest != null:
		return bake_manifest.is_valid()
	if bake_data == null:
		return false
	var identity := bake_data.get_instance_id()
	if not _validity_checked or identity != _validity_instance_id or bake_data.bake_version != _validity_bake_version:
		_validity_instance_id = identity
		_validity_bake_version = bake_data.bake_version
		_cached_data_valid = bake_data.is_valid()
		_cached_has_nonzero_indirect_transport = _cached_data_valid and bake_data.has_nonzero_transfer()
		_validity_checked = true
	return _cached_data_valid

## Backend 1 readiness comes from valid geometry/probe data plus a directional
## TransferMatrix. Revision-2 baked radiance SH is only a legacy diagnostic.
func has_valid_directional_transfer() -> bool:
	if bake_manifest != null or bake_data == null or not has_usable_bake():
		return false
	return bake_data.directional is Data.DirectionalData

func directional_transfer_status() -> Dictionary:
	var result := {
		"ready": false,
		"status": "missing_bake_data",
		"message": "Bake valid probe geometry and directional TransferMatrix to use dynamic CLV PRT.",
		"probe_count": 0,
		"source_count": 0,
		"transfer_bytes": 0,
		"storage": "none",
	}
	if bake_manifest != null:
		if not bake_manifest.is_valid():
			result["status"] = "invalid_manifest"
			result["message"] = "The streamed page manifest is invalid. Rebuild the page generation."
		else:
			result["status"] = "awaiting_streamed_page_transfer"
			result["storage"] = "streamed_pages"
			result["message"] = "Dynamic CLV PRT becomes ready as pages with valid directional TransferMatrix data are admitted. Older baked-SH-only pages are rejected; rebuild those pages."
		return result
	if bake_data == null:
		return result
	result["storage"] = "scene_bake_data_resource"
	result["probe_count"] = bake_data.probe_count()
	result["source_count"] = bake_data.emitter_count()
	if not has_usable_bake():
		result["status"] = "invalid_geometry_or_probe_data"
		result["message"] = "The saved geometry/probe bake is invalid. Run a full Bake before using dynamic CLV PRT."
		return result
	var directional: Variant = bake_data.directional
	if directional == null:
		result["status"] = "missing_directional_transfer"
		result["message"] = "This bake has no directional TransferMatrix. Baked-only SH cannot drive dynamic CLV PRT; run a full Bake."
		return result
	if not directional is Data.DirectionalData:
		result["status"] = "invalid_directional_transfer"
		result["message"] = "This bake has an unsupported directional TransferMatrix resource. Run a full Bake."
		return result
	# Data.is_valid() validates matrix revision, dimensions, source count, and
	# finite values before has_usable_bake() returns true.
	result["ready"] = true
	result["status"] = "ready"
	result["transfer_revision"] = directional.revision
	result["transfer_bytes"] = (directional.transfer.size() + directional.sky.size()
			+ directional.emission.size()) * 4
	result["message"] = "Dynamic CLV PRT has valid geometry/probe and directional TransferMatrix data."
	return result

## True when a legacy revision-2 baked SH field is available for diagnostics.
## Dynamic backend-1 readiness is reported by has_valid_directional_transfer().
func has_baked_indirect_sh() -> bool:
	if bake_manifest != null:
		return bake_manifest.has_baked_indirect_sh()
	return bake_data != null and has_usable_bake() and bake_data.has_baked_indirect_sh()

## Compact bake provenance for runtime diagnostics and external verification.
func baked_indirect_status() -> Dictionary:
	var status := {
		"ready": has_baked_indirect_sh(),
		"semantics": "legacy_revision_2_sh_diagnostic_only",
		"baking": is_baking(),
		"revision": 0,
		"probe_count": 0,
		"float_count": 0,
		"bytes": 0,
		"storage": "none",
		"path": "",
		"radiance_unit": "linear_hdr_radiance",
		"includes_primary_sky": false,
		"includes_direct_light": false,
		"field_semantics": "unavailable",
		"requires_native_sky_ownership": true,
		"sky_snapshot_status": "unverified_legacy_or_unavailable",
		"sky_source": "",
		"sky_input_signature": "",
		"rebake_reason": "",
		"probe_spacing": probe_spacing,
		"clv_cell_size": clv_cell_size,
	}
	if bake_manifest != null:
		status["storage"] = "immutable_page_resources"
		status["path"] = bake_manifest.resource_path
		status["revision"] = bake_manifest.baked_indirect_sh_revision
		status["probe_count"] = bake_manifest.total_probe_count()
		status["float_count"] = int(status["probe_count"]) * 27
		status["bytes"] = int(status["float_count"]) * 4
		status["page_count"] = bake_manifest.get_page_count()
		var manifest_provenance: Dictionary = bake_manifest.baked_indirect_sky_provenance
		status["sky_snapshot_status"] = String(manifest_provenance.get("status", "unverified_legacy_or_unavailable"))
		status["sky_source"] = String(manifest_provenance.get("source", ""))
		status["sky_input_signature"] = String(manifest_provenance.get("input_signature", ""))
		status["includes_primary_sky"] = bake_manifest.has_baked_indirect_sh()
		status["field_semantics"] = "secondary_plus_visibility_filtered_primary_sky" \
				if bool(status["includes_primary_sky"]) else "legacy_geometry_transport_baked_sh_unverified"
		if bake_manifest.baked_indirect_sh_revision == Data.BAKED_INDIRECT_SH_REVISION \
				and not bool(status["includes_primary_sky"]):
			status["rebake_reason"] = "This legacy SH field predates Sky provenance validation; it does not affect dynamic CLV PRT readiness."
	elif bake_data != null:
		status["storage"] = "scene_bake_data_resource"
		status["path"] = bake_data.resource_path
		if String(status["path"]).is_empty():
			var tree := get_tree() if is_inside_tree() else null
			var scene: Node = tree.edited_scene_root if tree != null else null
			status["path"] = scene.scene_file_path if scene != null else ""
		status["revision"] = bake_data.baked_indirect_sh_revision
		status["probe_count"] = bake_data.probe_count()
		status["float_count"] = bake_data.baked_indirect_sh.size()
		status["bytes"] = bake_data.baked_indirect_sh.size() * 4
		var data_provenance: Dictionary = bake_data.baked_indirect_sky_provenance
		status["sky_snapshot_status"] = String(data_provenance.get("status", "unverified_legacy_or_unavailable"))
		status["sky_source"] = String(data_provenance.get("source", ""))
		status["sky_input_signature"] = String(data_provenance.get("input_signature", ""))
		status["includes_primary_sky"] = bake_data.has_baked_indirect_sh()
		status["field_semantics"] = "secondary_plus_visibility_filtered_primary_sky" \
				if bool(status["includes_primary_sky"]) else "legacy_geometry_transport_baked_sh_unverified"
		if bake_data.baked_indirect_sh_revision == Data.BAKED_INDIRECT_SH_REVISION \
				and not bool(status["includes_primary_sky"]):
			status["rebake_reason"] = "This legacy SH field predates Sky provenance validation; it does not affect dynamic CLV PRT readiness."
	return status

## Indicates that this volume has saved bake data but it no longer matches the
## checked scene/layout. The valid old bake remains available for preview.
func needs_rebake() -> bool:
	return (bake_manifest != null or bake_data != null) \
			and (_layout_stale or _layout_dirty \
			or (_scene_signature_checked and not has_bake()) \
			or (clv_cache_backend == 1 and bake_manifest == null \
					and bake_data != null and not has_valid_directional_transfer()))

func has_legacy_sampler_signature() -> bool:
	return bake_data != null and _scene_signature_checked \
		and Data.sampler_revision_for_signature(bake_data.scene_signature) != Data.SAMPLER_REVISION

func bake_staleness_reasons() -> PackedStringArray:
	var reasons := PackedStringArray()
	if bake_manifest != null:
		if not bake_manifest.is_valid():
			reasons.append("the streamed page manifest is invalid")
		elif bake_manifest.bake_settings_signature != _settings_signature_for_manifest(bake_manifest):
			reasons.append("volume bake settings changed")
		elif _source_watch_stale:
			reasons.append("scene sources changed since the bake")
		elif bake_manifest.scene_watch_signature > 0 \
				and not _saved_source_signature_matches_current():
			reasons.append("scene source geometry or material changed")
		return reasons
	if bake_data == null:
		return reasons
	if clv_cache_backend == 1 and not has_valid_directional_transfer():
		reasons.append(String(directional_transfer_status().get("message",
			"this bake lacks a valid directional TransferMatrix; run a full Bake")))
	if bake_data.format_version < Data.FORMAT_VERSION:
		reasons.append("format %d lacks static segment blockers; upgrade a matching v5 bake or rebake to v6" % bake_data.format_version)
	if has_legacy_sampler_signature():
		reasons.append("it uses sampler revision %d; the current sampler is revision %d" % [
			Data.sampler_revision_for_signature(bake_data.scene_signature), Data.SAMPLER_REVISION])
	if bake_data.placement_layout_revision != ProbeLayout.PLACEMENT_LAYOUT_REVISION:
		reasons.append("probe placement layout revision changed; rebake to refresh points")
	if bake_data.bake_samples != bake_samples:
		reasons.append("it used %d rays per point; the selected quality requests %d" % [
			bake_data.bake_samples, bake_samples])
	if reasons.is_empty():
		reasons.append("geometry, volume layout, material input, or another bake setting changed")
	return reasons

func has_nonzero_indirect_transfer() -> bool:
	if bake_manifest != null:
		return has_usable_bake() and bake_manifest.get_page_count() > 0
	return has_usable_bake() and _cached_has_nonzero_indirect_transport

func probe_count() -> int:
	return probe_positions.size()

func grid_dimensions() -> Vector3i:
	var extent := size * global_transform.basis.get_scale().abs()
	var dimensions := Vector3i((extent / probe_spacing).ceil()).max(Vector3i.ONE)
	return dimensions

func cell_size() -> Vector3:
	var dimensions := grid_dimensions().max(Vector3i.ONE)
	return size / Vector3(dimensions)

func world_to_grid_transform() -> Transform3D:
	var dimensions := Vector3(grid_dimensions().max(Vector3i.ONE))
	var scale := dimensions / size
	return Transform3D(Basis.from_scale(scale), scale * size * 0.5) * global_transform.affine_inverse()

func resolved_bake_directory() -> String:
	if not bake_output_directory.is_empty():
		return bake_output_directory if bake_output_directory.begins_with("res://") else ""
	var tree := get_tree() if is_inside_tree() else null
	var scene: Node = tree.edited_scene_root if tree != null else null
	if scene == null and tree != null:
		scene = tree.current_scene
	var scene_path := String(scene.scene_file_path) if scene != null else ""
	var scene_label := scene_path.get_file().get_basename() if not scene_path.is_empty() else "unsaved"
	if scene_label.is_empty():
		scene_label = "unsaved"
	var stable_path := String(get_path()) if is_inside_tree() else name
	var stable_identity := "%08x" % (hash([scene_path, stable_path]) & 0xffffffff)
	return "res://bake/magicgi/%s_%s" % [scene_label.validate_filename(), stable_identity]

func set_streamed_bake_progress(completed: int, total: int) -> void:
	_streamed_bake_completed_pages = maxi(completed, 0)
	_streamed_bake_total_pages = maxi(total, 0)
	bake_status_changed.emit()

func streamed_bake_progress() -> Vector2i:
	return Vector2i(_streamed_bake_completed_pages, _streamed_bake_total_pages)

func free_space_bake_stage() -> String:
	return _free_space_bake_stage

func uses_free_space_clv_bake() -> bool:
	return not is_surfel_mode() and use_clv and clv_cache_backend == 1

func has_free_space_source_generation() -> bool:
	return bake_manifest != null and is_instance_valid(bake_manifest) \
			and bake_manifest.transport_domain in [VolumeSourceBaker.TRANSPORT_DOMAIN, PreparedArchive.DOMAIN]

func is_baking() -> bool:
	return _baking or _bake_start_pending

func is_bake_cancel_requested() -> bool:
	return _bake_cancel_requested or _refresh_cancel_requested

func cancel_bake() -> void:
	var changed := false
	if _baking and not _bake_cancel_requested:
		_bake_cancel_requested = true
		_bake_generation += 1
		changed = true
	if _bake_start_pending and not _bake_cancel_requested:
		_bake_cancel_requested = true
		_bake_generation += 1
		changed = true
	if _refresh_active and not _refresh_cancel_requested:
		_refresh_cancel_requested = true
		_refresh_pending = false
		_refresh_request_generation += 1
		_cancel_active_surface_refresh()
		_resolve_all_surface_refresh_requests(false)
		_refresh_phase = "Canceling surface refresh"
		changed = true
	if changed:
		bake_status_changed.emit()

func is_refreshing() -> bool:
	return _refresh_active

func is_refresh_cancel_requested() -> bool:
	return _refresh_cancel_requested

func surface_refresh_progress() -> String:
	if not _refresh_active:
		return ""
	if _refresh_progress_total > 0:
		return "%s: %d / %d" % [_refresh_phase, _refresh_progress_completed,
				_refresh_progress_total]
	return _refresh_phase

func candidate_probe_count() -> int:
	return _candidate_probe_positions.size() if _candidate_layout_ready else 0

func is_candidate_layout_current() -> bool:
	return _candidate_layout_ready and _candidate_layout_current

func saved_probe_count() -> int:
	if bake_manifest != null and is_instance_valid(bake_manifest):
		return bake_manifest.total_probe_count()
	return bake_data.probe_count() if bake_data != null else 0

func _clear_candidate_layout() -> void:
	_candidate_viz_generation += 1
	_candidate_probe_positions.clear()
	_candidate_probe_surface_positions.clear()
	_candidate_probe_normals.clear()
	_candidate_probe_spacings.clear()
	_candidate_layout_ready = false
	_candidate_layout_current = false
	_candidate_layout_revision += 1
	Viz.clear_candidate_layout(_viz)

func bake() -> bool:
	if is_surfel_mode() or not is_inside_tree() or is_baking():
		return false
	_bake_start_pending = true
	var start_generation := _bake_generation
	await _cancel_and_wait_for_surface_refresh()
	if not is_inside_tree() or start_generation != _bake_generation:
		_bake_start_pending = false
		_bake_cancel_requested = false
		return false
	_bake_start_pending = false
	_layout_dirty = false
	_layout_refresh_deadline_msec = 0
	if uses_free_space_clv_bake():
		return await _bake_free_space_source_generation()
	if chunked_baking:
		return await _bake_streamed_generation(Vector2i(2147483647, 2147483647))
	_baking = true
	_bake_cancel_requested = false
	bake_status_changed.emit()
	var generation := _bake_generation
	var data := await Baker.new().bake_volume(self, generation)
	if not is_instance_valid(self):
		return false
	_baking = false
	_bake_cancel_requested = false
	if data == null or generation != _bake_generation:
		bake_status_changed.emit()
		return false
	data.bake_version = Time.get_ticks_usec()
	_bake_assigning_data = true
	bake_data = data
	_bake_assigning_data = false
	_current_watch_signature = int(data.get("scene_watch_signature"))
	_current_stable_source_signature = _current_watch_signature
	_current_quick_source_signature = SceneTracker.quick_source_signature_uncached(self)
	_current_watch_signature = SceneTracker.quick_signature_uncached(self)
	_quick_scene_signature = _current_watch_signature
	_legacy_watch_baseline_signature = _current_watch_signature
	_source_watch_stale = false
	_scene_signature_checked = true
	_exact_scene_signature_available = false
	_layout_stale = false
	_restore_prt_probe_layout()
	_clear_candidate_layout()
	_layout_dirty = false
	_layout_epoch += 1
	_preview_revision += 1
	_refresh_viz()
	Runtime.publish(self)
	update_configuration_warnings()
	return has_bake()

func bake_chunk(chunk_x: int, chunk_z: int) -> bool:
	if is_surfel_mode() or uses_free_space_clv_bake() or not chunked_baking \
			or not is_inside_tree() or is_baking():
		return false
	_bake_start_pending = true
	var start_generation := _bake_generation
	await _cancel_and_wait_for_surface_refresh()
	if not is_inside_tree() or start_generation != _bake_generation:
		_bake_start_pending = false
		_bake_cancel_requested = false
		return false
	_bake_start_pending = false
	return await _bake_streamed_generation(Vector2i(chunk_x, chunk_z))

func _bake_free_space_source_generation() -> bool:
	if absf(clv_cell_size - VolumeSourceChunk.CELL_SPACING_M) > 0.000001:
		push_warning("FMagicGI: free-space CLV PRT currently requires CLV Cell Size to be 0.25 m; no new generation was published.")
		bake_status_changed.emit()
		return false
	var output_root := resolved_bake_directory()
	if output_root.is_empty() or not output_root.begins_with("res://"):
		push_warning("FMagicGI: free-space CLV PRT Bake requires a writable res:// output directory; the previous bake remains active.")
		bake_status_changed.emit()
		return false
	_baking = true
	_bake_cancel_requested = false
	_free_space_bake_stage = "Preparing free-space CLV PRT source"
	_streamed_bake_completed_pages = 0
	_streamed_bake_total_pages = 0
	bake_status_changed.emit()
	var generation := _bake_generation
	var scene_watch_signature := SceneTracker.stable_scene_signature(self)
	var input_signature := SceneTracker.bake_content_signature(self)
	var world_bounds := global_transform * AABB(-size * 0.5, size)
	var source_dims := Vector3i((world_bounds.size / 0.25).ceil())
	var bounded_multires := source_dims.x > 256 or source_dims.y > 256 or source_dims.z > 256 \
		or float(source_dims.x) * source_dims.y * source_dims.z > 32768.0
	var settings_signature := PagedSourceBaker.settings_signature(self) if bounded_multires \
		else VolumeSourceBaker.settings_signature(self)
	var progress := Callable(self, "_on_free_space_bake_progress")
	var cancelled := Callable(self, "_free_space_bake_cancelled").bind(generation)
	var source_baker := VolumeSourceBaker.new()
	var generation_id := "prepared_%d_%d" % [Time.get_ticks_usec(), get_instance_id()]
	var result: Dictionary
	if bounded_multires:
		result = await source_baker.bake_paged_async(self, generation_id, output_root,
			{"scene_watch_signature": scene_watch_signature}, progress, cancelled)
	else:
		result = await source_baker.bake_async(self, {}, progress, cancelled)
	if not is_instance_valid(self):
		return false
	if generation != _bake_generation or _bake_cancel_requested:
		_finish_free_space_bake(false)
		return false
	if not bool(result.get("ok", false)):
		_finish_free_space_bake(false, String(result.get("error", "Free-space CLV PRT source bake failed.")))
		return false
	var chunk := result.get("chunk") as VolumeSourceChunk
	if not bounded_multires and (chunk == null or not chunk.is_valid(chunk.geometry_signature,
			chunk.emitter_ids, chunk.emitter_static_signatures)):
		_finish_free_space_bake(false, "Free-space CLV PRT source failed final geometry/TransferMatrix validation.")
		return false
	_free_space_bake_stage = "Validating captured scene before publication"
	bake_status_changed.emit()
	if generation != _bake_generation \
			or input_signature != SceneTracker.bake_content_signature(self) \
			or scene_watch_signature != SceneTracker.stable_scene_signature(self) \
			or settings_signature != (PagedSourceBaker.settings_signature(self) if bounded_multires \
				else VolumeSourceBaker.settings_signature(self)):
		_finish_free_space_bake(false, "Scene, lighting-source identity, or Volume settings changed during the free-space bake; the previous generation remains active.")
		return false
	_free_space_bake_stage = "Saving and validating paged prepared transfer"
	bake_status_changed.emit()
	var saved: Dictionary = result
	if not bounded_multires:
		# Preserve the exact small-room bake and an on-demand source-debug archive.
		var source_saved: Dictionary = VolumeSourceBaker.save_generation(self, chunk,
			generation_id + "_source", output_root, settings_signature, scene_watch_signature, cancelled)
		if source_saved.has("error"):
			_finish_free_space_bake(false, String(source_saved.error))
			return false
		saved = PreparedArchive.save_source(chunk, source_saved.manifest, generation_id,
			output_root, 16, cancelled)
	if not is_instance_valid(self):
		return false
	if generation != _bake_generation or _bake_cancel_requested:
		_finish_free_space_bake(false)
		return false
	if saved.has("error"):
		_finish_free_space_bake(false, String(saved.error))
		return false
	var manifest := saved.get("manifest") as Manifest
	if manifest == null or not manifest.is_valid() \
			or manifest.transport_domain != PreparedArchive.DOMAIN:
		_finish_free_space_bake(false, "The saved free-space CLV PRT manifest failed final validation; the previous generation remains active.")
		return false
	# Publish only after the immutable page and manifest have both survived reload.
	_bake_assigning_manifest = true
	bake_manifest = manifest
	_bake_assigning_manifest = false
	_bake_assigning_data = true
	bake_data = null
	_bake_assigning_data = false
	_current_stable_source_signature = scene_watch_signature
	_current_scene_signature = scene_watch_signature
	_exact_scene_signature_available = false
	_scene_signature_checked = true
	_source_watch_stale = false
	_legacy_manifest_unverified = false
	_current_quick_source_signature = SceneTracker.quick_source_signature_uncached(self)
	_current_watch_signature = SceneTracker.quick_signature_uncached(self)
	_quick_scene_signature = _current_watch_signature
	_pending_scene_signature = _current_watch_signature
	_legacy_watch_baseline_signature = _current_watch_signature
	_layout_stale = false
	_layout_dirty = false
	_layout_refresh_deadline_msec = 0
	_clear_candidate_layout()
	_layout_epoch += 1
	_preview_revision += 1
	_preview_layout_match_key = ""
	_free_space_bake_stage = "Complete"
	_baking = false
	_bake_cancel_requested = false
	Runtime.publish(self)
	update_configuration_warnings()
	bake_status_changed.emit()
	return has_bake()

func _on_free_space_bake_progress(stage: String, completed: int, total: int,
		_batch: int, _batch_count: int) -> void:
	if not _baking:
		return
	_free_space_bake_stage = stage
	_streamed_bake_completed_pages = maxi(completed, 0)
	_streamed_bake_total_pages = maxi(total, 0)
	bake_status_changed.emit()

func _free_space_bake_cancelled(generation: int) -> bool:
	return not is_instance_valid(self) or not is_inside_tree() or is_surfel_mode() \
			or generation != _bake_generation or _bake_cancel_requested

func _finish_free_space_bake(success: bool, error_message := "") -> void:
	_baking = false
	_bake_cancel_requested = false
	_free_space_bake_stage = "Complete" if success else ""
	if not error_message.is_empty():
		push_warning("FMagicGI: " + error_message)
		update_configuration_warnings()
	bake_status_changed.emit()

func _cancel_and_wait_for_surface_refresh() -> void:
	if not _refresh_active:
		return
	_refresh_cancel_requested = true
	_refresh_pending = false
	_refresh_request_generation += 1
	_cancel_active_surface_refresh()
	_resolve_all_surface_refresh_requests(false)
	_refresh_phase = "Canceling surface refresh"
	bake_status_changed.emit()
	while _refresh_active and is_inside_tree():
		await surface_refresh_completed

func _bake_streamed_generation(selected_chunk: Vector2i) -> bool:
	_layout_dirty = false
	_layout_refresh_deadline_msec = 0
	_baking = true
	_bake_cancel_requested = false
	_streamed_bake_completed_pages = 0
	_streamed_bake_total_pages = 0
	bake_status_changed.emit()
	var generation := _bake_generation
	var result: Dictionary = await Baker.new().bake_streamed_generation(self, generation, selected_chunk)
	if not is_instance_valid(self):
		return false
	_baking = false
	_bake_cancel_requested = false
	if generation != _bake_generation:
		bake_status_changed.emit()
		return false
	var error := String(result.get("error", ""))
	if not error.is_empty():
		push_warning("FMagicGI: " + error)
		update_configuration_warnings()
		bake_status_changed.emit()
		return false
	var manifest := result.get("manifest") as Manifest
	if manifest == null or not manifest.is_valid():
		push_warning("FMagicGI: streamed bake returned an invalid manifest; the previous bake remains active.")
		update_configuration_warnings()
		bake_status_changed.emit()
		return false
	_bake_assigning_manifest = true
	bake_manifest = manifest
	_bake_assigning_manifest = false
	_current_stable_source_signature = int(result.get("scene_watch_signature",
			result.get("geometry_signature", 0)))
	_current_scene_signature = _current_stable_source_signature
	_exact_scene_signature_available = false
	_scene_signature_checked = true
	_source_watch_stale = false
	_legacy_manifest_unverified = false
	_current_quick_source_signature = SceneTracker.quick_source_signature_uncached(self)
	_current_watch_signature = SceneTracker.quick_signature_uncached(self)
	_quick_scene_signature = _current_watch_signature
	_pending_scene_signature = _quick_scene_signature
	_layout_stale = false
	probe_positions.clear()
	probe_surface_positions.clear()
	probe_normals.clear()
	probe_spacings.clear()
	_clear_candidate_layout()
	_probe_layout_revision += 1
	_preview_revision += 1
	_preview_layout_match_key = ""
	_refresh_viz()
	Runtime.publish(self)
	update_configuration_warnings()
	bake_status_changed.emit()
	return has_bake()

## Public bake-generation check used by the async Baker after yielding. The
## generation remains private so callers cannot invalidate a bake themselves.
func is_bake_request_current(generation: int) -> bool:
	return not is_surfel_mode() and is_inside_tree() and generation == _bake_generation

func _rebuild_probes() -> void:
	if is_surfel_mode() or not is_inside_tree():
		return
	_layout_queued = true
	_schedule_layout_settle()

func _schedule_layout_settle() -> void:
	if is_surfel_mode() or not is_inside_tree():
		return
	_layout_dirty = true
	_layout_refresh_deadline_msec = Time.get_ticks_msec() + LAYOUT_IDLE_DEBOUNCE_MSEC
	_layout_queued = true

func _mark_layout_stale(schedule_settle := true) -> void:
	_layout_epoch += 1
	_candidate_layout_current = false
	_candidate_viz_generation += 1
	if _candidate_layout_ready:
		Viz.set_candidate_layout_current(_viz, false)
	if _refresh_active:
		_refresh_request_generation += 1
		_refresh_pending = false
		_refresh_cancel_requested = false
		_cancel_active_surface_refresh()
		_resolve_all_surface_refresh_requests(false)
	_layout_stale = _has_saved_bake()
	_layout_dirty = true
	_layout_refresh_deadline_msec = Time.get_ticks_msec() + LAYOUT_IDLE_DEBOUNCE_MSEC
	_layout_queued = true
	Viz.set_layout_stale(_viz, _layout_stale)
	if schedule_settle:
		_schedule_layout_settle()

func _settle_layout_change() -> void:
	if is_surfel_mode() or not is_inside_tree() or is_baking():
		return
	if _source_validation_pending:
		_run_saved_source_validation()
	_layout_queued = false
	_layout_dirty = false
	_layout_refresh_deadline_msec = 0
	var watch_signature := SceneTracker.quick_signature_uncached(self)
	_current_watch_signature = watch_signature
	_current_quick_source_signature = SceneTracker.quick_source_signature_uncached(self)
	_quick_scene_signature = watch_signature
	_pending_scene_signature = watch_signature
	_scene_signature_checked = _has_saved_bake()
	if _has_saved_bake():
		_layout_stale = not _saved_bake_matches_current()
		Viz.set_layout_stale(_viz, _layout_stale)
		Runtime.publish(self)
		update_configuration_warnings()
		bake_status_changed.emit()
		return
	if uses_free_space_clv_bake():
		# No surface-probe layout is consumed by the free-space TransferMatrix bake.
		_scene_signature_checked = false
		_layout_stale = false
		Viz.set_layout_stale(_viz, false)
		Runtime.publish(self)
		update_configuration_warnings()
		bake_status_changed.emit()
		return
	if chunked_baking:
		_scene_signature_checked = true
		_layout_stale = false
		Viz.set_layout_stale(_viz, false)
		if not _has_saved_bake():
			await refresh_surface_points()
		else:
			_refresh_viz()
			Runtime.publish(self)
			update_configuration_warnings()
			bake_status_changed.emit()
		return
	await refresh_surface_points()

func _schedule_saved_source_validation(reset_legacy_baseline := false) -> void:
	if is_surfel_mode():
		return
	_source_validation_pending = true
	_source_validation_reset_legacy_baseline = _source_validation_reset_legacy_baseline \
			or reset_legacy_baseline
	if not is_inside_tree() or _source_validation_queued:
		return
	_source_validation_queued = true
	call_deferred("_run_saved_source_validation")

func _run_saved_source_validation() -> void:
	_source_validation_queued = false
	if is_surfel_mode() or not _source_validation_pending or not is_inside_tree() or _baking:
		return
	_source_validation_pending = false
	var reset_legacy_baseline := _source_validation_reset_legacy_baseline
	_source_validation_reset_legacy_baseline = false
	_capture_saved_source_watch_state(reset_legacy_baseline)
	_layout_stale = _has_saved_bake() and not _saved_bake_matches_current()
	if not _layout_dirty:
		Viz.set_layout_stale(_viz, _layout_stale)
	Runtime.publish(self)
	update_configuration_warnings()
	bake_status_changed.emit()

func _capture_saved_source_watch_state(reset_legacy_baseline := false,
		placement: Placement = null, placement_valid := false) -> void:
	_current_watch_signature = SceneTracker.quick_signature_uncached(self)
	_current_quick_source_signature = SceneTracker.quick_source_signature_uncached(self)
	_quick_scene_signature = _current_watch_signature
	_pending_scene_signature = _current_watch_signature
	if reset_legacy_baseline:
		_legacy_watch_baseline_signature = _current_watch_signature
	_scene_signature_checked = _has_saved_bake()
	_exact_scene_signature_available = false
	_legacy_manifest_unverified = bake_manifest != null \
			and bake_manifest.scene_watch_signature <= 0
	var stored_source_signature := 0
	var stored_source_state: Dictionary = {}
	if bake_manifest != null:
		stored_source_signature = int(bake_manifest.scene_watch_signature)
		var manifest_schema_version := int(bake_manifest.scene_watch_signature_schema_version)
		if not SceneTracker.is_signature_schema_supported(manifest_schema_version) \
				or (manifest_schema_version == SceneTracker.SIGNATURE_SCHEMA_CURRENT \
				and stored_source_signature <= 0):
			_current_stable_source_signature = 0
			_current_scene_signature = 0
			_source_watch_stale = true
			return
		if stored_source_signature > 0:
			stored_source_state = SceneTracker.manifest_source_signature(self,
				manifest_schema_version, bake_manifest.volume_identity)
	elif bake_data != null:
		stored_source_signature = int(bake_data.scene_watch_signature)
		var data_schema_version := int(bake_data.scene_watch_signature_schema_version)
		if not SceneTracker.is_signature_schema_supported(data_schema_version) \
				or (data_schema_version == SceneTracker.SIGNATURE_SCHEMA_CURRENT \
				and stored_source_signature <= 0):
			_current_stable_source_signature = 0
			_current_scene_signature = 0
			_source_watch_stale = true
			return
		if stored_source_signature > 0:
			stored_source_state = SceneTracker.data_source_signature(self, data_schema_version)
	if stored_source_signature > 0:
		_current_stable_source_signature = int(stored_source_state.get("signature", 0))
		_current_scene_signature = _current_stable_source_signature
		_source_watch_stale = not bool(stored_source_state.get("valid", false)) \
				or stored_source_signature != _current_stable_source_signature
		return
	_current_stable_source_signature = SceneTracker.stable_scene_signature(self)
	_current_scene_signature = _current_stable_source_signature
	if bake_manifest != null:
		# A pre-fingerprint manifest can only be watched against this session's
		# quick baseline; this is deliberately not persisted validation.
		_source_watch_stale = _legacy_watch_baseline_signature > 0 \
				and _legacy_watch_baseline_signature != _current_watch_signature
	elif bake_data != null:
		if placement_valid and placement != null:
			_current_scene_signature = placement.scene_signature
			_exact_scene_signature_available = true
			_source_watch_stale = not Data.geometry_signature_matches(
					bake_data.scene_signature, placement.scene_signature)
		else:
			# Watchless resources keep their one-time exact placement check. A later
			# static-source change requests another check only at that change boundary.
			_source_watch_stale = not _validate_legacy_bake_geometry_once()
	else:
		_source_watch_stale = false
		if placement_valid and placement != null:
			_current_scene_signature = placement.scene_signature
			_exact_scene_signature_available = true

func refresh_surface_points() -> bool:
	if is_surfel_mode() or not is_inside_tree() or is_baking():
		return false
	_layout_queued = false
	_layout_dirty = false
	_layout_refresh_deadline_msec = 0
	_refresh_request_generation += 1
	var requested_generation := _refresh_request_generation
	_resolve_surface_refresh_requests_except(requested_generation)
	var request := SurfaceRefreshRequest.new()
	_refresh_requests[requested_generation] = request
	if _refresh_active:
		_cancel_active_surface_refresh()
	_refresh_pending = true
	_refresh_cancel_requested = false
	if not _refresh_active:
		_refresh_active = true
		call_deferred("_run_surface_refresh_queue")
	bake_status_changed.emit()
	if not request.finished:
		await request.completed
	return request.succeeded

func _run_surface_refresh_queue() -> void:
	while is_instance_valid(self) and _refresh_pending and is_inside_tree() \
			and not is_surfel_mode() and not is_baking():
		var generation := _refresh_request_generation
		var completion_request: SurfaceRefreshRequest = _refresh_requests.get(generation)
		_refresh_pending = false
		_refresh_cancel_requested = false
		_refresh_phase = "Preparing surface refresh"
		_refresh_progress_completed = 0
		_refresh_progress_total = -1
		_next_refresh_status_msec = Time.get_ticks_msec()
		bake_status_changed.emit()
		if not is_instance_valid(self) or not is_inside_tree():
			return
		var placement := Placement.new()
		var coordinator = Placement.AsyncRefreshCoordinator.new()
		_active_refresh_coordinator = coordinator
		_active_refresh_generation = generation
		var source_is_current := Callable(self, "_surface_refresh_is_current").bind(generation)
		var progress_callback := Callable(self, "_set_surface_refresh_progress")
		var finished_callback := Callable(completion_request, "mark_collection_finished") \
				if completion_request != null else Callable()
		var use_bake_bounds := bake_data != null
		get_tree().root.add_child(coordinator)
		coordinator.begin(placement, self, use_bake_bounds, false, source_is_current,
				progress_callback, AABB(), finished_callback, completion_request)
		var success: bool = await coordinator.completed
		if not is_instance_valid(self):
			if completion_request != null:
				completion_request.resolve(false)
			return
		if _active_refresh_coordinator == coordinator:
			_active_refresh_coordinator = null
		if _active_refresh_generation == generation:
			_active_refresh_generation = -1
		if success and source_is_current.is_valid() and source_is_current.call() \
				and placement.async_capture_is_current(self, source_is_current):
			success = await _commit_candidate_layout(placement, generation)
		if not is_instance_valid(self):
			return
		if generation == _refresh_request_generation:
			_refresh_completed_generation = generation
			_refresh_last_success = success
			if not success and not placement.error_message.is_empty() \
					and placement.error_message != "Surface refresh was superseded.":
				push_warning("FMagicGI: " + placement.error_message)
			bake_status_changed.emit()
		_resolve_surface_refresh_request(generation, success)
		surface_refresh_completed.emit(generation, success)
		if not is_instance_valid(self):
			return
		if generation != _refresh_request_generation and not _refresh_pending:
			break
	if not is_instance_valid(self):
		return
	_refresh_active = false
	_refresh_cancel_requested = false
	_refresh_phase = ""
	_refresh_progress_completed = 0
	_refresh_progress_total = -1
	bake_status_changed.emit()
	surface_refresh_completed.emit(_refresh_request_generation, false)

func _cancel_active_surface_refresh() -> void:
	if _active_refresh_coordinator != null and is_instance_valid(_active_refresh_coordinator):
		_active_refresh_coordinator.call("cancel")

func _resolve_surface_refresh_request(generation: int, success: bool) -> void:
	if not _refresh_requests.has(generation):
		return
	var request: SurfaceRefreshRequest = _refresh_requests[generation]
	_refresh_requests.erase(generation)
	request.resolve(success)

func _resolve_surface_refresh_requests_except(kept_generation: int) -> void:
	var old_generations := _refresh_requests.keys()
	for generation_variant in old_generations:
		var generation := int(generation_variant)
		if generation == kept_generation:
			continue
		var request: SurfaceRefreshRequest = _refresh_requests[generation]
		_refresh_requests.erase(generation)
		request.resolve(false)

func _resolve_all_surface_refresh_requests(success: bool) -> void:
	var requests := _refresh_requests.values()
	_refresh_requests.clear()
	for request_variant in requests:
		var request: SurfaceRefreshRequest = request_variant
		request.resolve(success)

func _surface_refresh_is_current(generation: int) -> bool:
	return not is_surfel_mode() and is_inside_tree() and _refresh_active and not is_baking() \
			and generation == _refresh_request_generation

func _set_surface_refresh_progress(phase: String, completed: int, total: int) -> void:
	_refresh_phase = phase
	_refresh_progress_completed = completed
	_refresh_progress_total = total
	var now := Time.get_ticks_msec()
	if now >= _next_refresh_status_msec:
		_next_refresh_status_msec = now + 100
		bake_status_changed.emit()

func _commit_candidate_layout(placement: Placement, generation: int) -> bool:
	if not _surface_refresh_is_current(generation):
		return false
	_candidate_probe_positions = placement.positions.duplicate()
	_candidate_probe_surface_positions = placement.surface_positions.duplicate()
	_candidate_probe_normals = placement.normals.duplicate()
	_candidate_probe_spacings = placement.probe_spacings.duplicate()
	_candidate_layout_ready = true
	_candidate_layout_current = true
	_candidate_layout_revision += 1
	_placement_warning_message = placement.warning_message
	_current_scene_signature = placement.scene_signature
	_scene_signature_checked = true
	_exact_scene_signature_available = true
	_upgrade_matching_visibility_bake(placement)
	_capture_saved_source_watch_state(true, placement, true)
	if not _has_saved_bake():
		probe_positions = _candidate_probe_positions.duplicate()
		probe_surface_positions = _candidate_probe_surface_positions.duplicate()
		probe_normals = _candidate_probe_normals.duplicate()
		probe_spacings = _candidate_probe_spacings.duplicate()
		_scene_signature_checked = true
		_source_watch_stale = false
		_probe_layout_revision += 1
	_preview_layout_match_key = ""
	_preview_revision += 1
	_layout_stale = _has_saved_bake() and not _saved_bake_matches_current()
	Viz.set_layout_stale(_viz, _layout_stale)
	Runtime.publish(self)
	update_configuration_warnings()
	if Engine.is_editor_hint():
		if not is_instance_valid(_viz):
			_refresh_viz()
			var tree := get_tree()
			await tree.process_frame
			if not is_instance_valid(self):
				return false
		if is_instance_valid(_viz):
			await _rebuild_candidate_viz(generation)
	return _surface_refresh_is_current(generation)

func _rebuild_candidate_viz(generation := -1) -> void:
	if not Engine.is_editor_hint() or not _candidate_layout_ready \
			or not is_instance_valid(_viz):
		return
	_candidate_viz_generation += 1
	var viz_generation := _candidate_viz_generation
	var candidate := await Viz.build_candidate_layout_node(self,
			_candidate_probe_positions, _candidate_probe_spacings,
			_candidate_layout_current, _candidate_layout_revision)
	if not is_instance_valid(self) or not is_instance_valid(_viz) \
			or viz_generation != _candidate_viz_generation \
			or generation >= 0 and not _surface_refresh_is_current(generation):
		if is_instance_valid(candidate):
			candidate.free()
		return
	Viz.install_candidate_layout(_viz, candidate, _candidate_layout_revision)

func _upgrade_matching_visibility_bake(placement: Placement) -> void:
	if bake_data == null or bake_data.format_version != Data.MOMENT_FORMAT_VERSION:
		return
	var attempt := hash([bake_data.get_instance_id(), bake_data.bake_version,
			placement.scene_signature, size, probe_spacing, surface_offset, global_transform,
			bake_samples, bake_bounces, bake_distance, terrain_reflectance, fallback_material_reflectance])
	if attempt == _visibility_upgrade_attempt:
		return
	_visibility_upgrade_attempt = attempt
	# Reuse the geometry already collected for the scene signature. This runs on
	# the main thread once per matching old resource; no lighting rays or disk writes.
	var upgraded := Baker.new().upgrade_visibility_bake(self, placement)
	if upgraded == null:
		return
	_bake_assigning_data = true
	bake_data = upgraded
	_bake_assigning_data = false
	_scene_signature_checked = true # The setter invalidates this cached check.

func _settings_changed(rebuild := true) -> void:
	_bake_generation += 1
	_scene_signature_checked = false
	if is_surfel_mode():
		_mark_layout_stale(false)
		Runtime.publish(self)
		return
	if rebuild:
		_mark_layout_stale()
	else:
		_schedule_layout_settle()

func _sample_quality_changed() -> void:
	# Ray count affects the bake but not the surface layout/signature.
	_bake_generation += 1
	_mark_layout_stale()

func _invalidate_data_cache() -> void:
	_validity_checked = false
	_cached_data_valid = false
	_cached_has_nonzero_indirect_transport = false

func _has_saved_bake() -> bool:
	return bake_manifest != null or bake_data != null

func _validate_legacy_bake_geometry_once() -> bool:
	if bake_data == null or not bake_data.is_valid():
		return false
	var placement := Placement.new()
	if not placement.collect(self, true, false, false):
		return false
	_current_scene_signature = placement.scene_signature
	_exact_scene_signature_available = true
	return Data.geometry_signature_matches(bake_data.scene_signature, placement.scene_signature)

func _saved_source_signature_matches_current() -> bool:
	if bake_manifest != null and bake_manifest.scene_watch_signature > 0:
		var manifest_schema_version := int(bake_manifest.scene_watch_signature_schema_version)
		return (manifest_schema_version == SceneTracker.SIGNATURE_SCHEMA_CURRENT \
				or manifest_schema_version == SceneTracker.SIGNATURE_SCHEMA_LEGACY) \
				and bake_manifest.scene_watch_signature == _current_stable_source_signature
	if bake_data != null and bake_data.scene_watch_signature > 0:
		var data_schema_version := int(bake_data.scene_watch_signature_schema_version)
		return (data_schema_version == SceneTracker.SIGNATURE_SCHEMA_CURRENT \
				or data_schema_version == SceneTracker.SIGNATURE_SCHEMA_LEGACY) \
				and bake_data.scene_watch_signature == _current_stable_source_signature
	return false

func _saved_bake_matches_current() -> bool:
	if _source_watch_stale:
		return false
	if bake_manifest != null:
		if not SceneTracker.is_signature_schema_supported(
				int(bake_manifest.scene_watch_signature_schema_version)):
			return false
		if bake_manifest.scene_watch_signature_schema_version == SceneTracker.SIGNATURE_SCHEMA_CURRENT \
				and bake_manifest.scene_watch_signature <= 0:
			return false
		if not has_usable_bake() \
				or _settings_signature_for_manifest(bake_manifest) != bake_manifest.bake_settings_signature:
			return false
		if bake_manifest.scene_watch_signature > 0:
			return _saved_source_signature_matches_current()
		# Earlier streamed manifests persisted a process-local scene hash. It
		# cannot be compared across editor launches; establish a runtime watcher
		# and keep the readable generation until an actual source edit is observed.
		return _legacy_manifest_unverified
	if bake_data == null or not has_usable_bake():
		return false
	if bake_data.placement_layout_revision != ProbeLayout.PLACEMENT_LAYOUT_REVISION:
		return false
	if not SceneTracker.is_signature_schema_supported(
			int(bake_data.scene_watch_signature_schema_version)):
		return false
	if bake_data.scene_watch_signature_schema_version == SceneTracker.SIGNATURE_SCHEMA_CURRENT \
			and bake_data.scene_watch_signature <= 0:
		return false
	if has_legacy_sampler_signature():
		return false
	if not bake_data.matches_layout(size, probe_spacing, surface_offset, global_transform,
			bake_samples, bake_bounces, bake_distance, terrain_reflectance, fallback_material_reflectance):
		return false
	if bake_data.adaptive_placement != adaptive_placement \
			or adaptive_placement and not is_equal_approx(
				bake_data.minimum_probe_spacing, minf(minimum_probe_spacing, probe_spacing)):
		return false
	if bake_data.scene_watch_signature > 0:
		return _saved_source_signature_matches_current()
	if _exact_scene_signature_available:
		return Data.geometry_signature_matches(bake_data.scene_signature, _current_scene_signature)
	return _legacy_watch_baseline_signature > 0 \
			and _legacy_watch_baseline_signature == _current_watch_signature

func _settings_signature_for_manifest(manifest: Manifest) -> int:
	if manifest != null and manifest.transport_domain == PreparedArchive.DOMAIN \
			and manifest.prepared_bake_algorithm == "multires_independent_transport_v1":
		return PagedSourceBaker.settings_signature(self, {"prepared_levels": manifest.prepared_level_count,
			"core_axis": manifest.prepared_core_axis})
	if manifest != null and manifest.transport_domain in [VolumeSourceBaker.TRANSPORT_DOMAIN, PreparedArchive.DOMAIN]:
		return VolumeSourceBaker.settings_signature(self)
	return Baker.new()._streamed_settings_signature(self)

func _set_probe_layout_from_data(data: Data) -> void:
	if data == null:
		_invalidate_data_cache()
		probe_positions = PackedVector3Array()
		probe_surface_positions = PackedVector3Array()
		probe_normals = PackedVector3Array()
		probe_spacings = PackedFloat32Array()
		_probe_layout_revision += 1
		_preview_layout_match_key = ""
		return
	_cached_data_valid = data.is_valid()
	_validity_instance_id = data.get_instance_id()
	_validity_bake_version = data.bake_version
	_cached_has_nonzero_indirect_transport = _cached_data_valid and data.has_nonzero_transfer()
	_validity_checked = true
	if _cached_data_valid:
		probe_positions = data.positions.duplicate()
		probe_surface_positions = data.surface_positions.duplicate()
		probe_normals = data.normals.duplicate()
		probe_spacings = data.probe_spacings.duplicate()
	else:
		probe_positions = PackedVector3Array()
		probe_surface_positions = PackedVector3Array()
		probe_normals = PackedVector3Array()
		probe_spacings = PackedFloat32Array()
	_probe_layout_revision += 1
	_preview_layout_match_key = ""

func _restore_prt_probe_layout() -> void:
	# A streamed Manifest owns the active PRT provider when both resources are
	# present. Never repopulate the legacy preview arrays from its inactive Data.
	var active_data: Data = null if bake_manifest != null and is_instance_valid(bake_manifest) \
			else bake_data
	_set_probe_layout_from_data(active_data)

func preview_layout_matches(data: Data) -> bool:
	if data == null:
		return false
	var key := "%d:%d:%d:%d" % [data.get_instance_id(), data.bake_version,
			_data_change_revision, _probe_layout_revision]
	if key == _preview_layout_match_key:
		return _preview_layout_match_value
	_preview_layout_match_key = key
	_preview_layout_match_value = Preview.layout_matches(data, probe_positions)
	return _preview_layout_match_value

func layout_revision() -> int:
	return _layout_epoch

func probe_layout_revision() -> int:
	return _probe_layout_revision

func data_revision() -> int:
	return _data_change_revision

func preview_revision() -> int:
	return _preview_revision

func is_layout_stale() -> bool:
	return _layout_stale or _layout_dirty

func _on_data_changed() -> void:
	if bake_data != null:
		bake_data._invalidate_baked_indirect_sh_validation_cache()
	_invalidate_data_cache()
	_data_change_revision += 1
	_preview_revision += 1
	_preview_layout_match_key = ""
	if not is_surfel_mode():
		_restore_prt_probe_layout()
	if is_inside_tree() and not is_surfel_mode():
		_mark_layout_stale()
		_schedule_saved_source_validation()
	Runtime.publish(self)

func _on_manifest_changed() -> void:
	if bake_manifest != null:
		bake_manifest._invalidate_validation_cache()
		bake_manifest.has_baked_indirect_sh()
	if is_inside_tree():
		Runtime.publish(self)

func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if is_surfel_mode():
		return warnings
	var dims := grid_dimensions()
	if uses_free_space_clv_bake() and absf(clv_cell_size - VolumeSourceChunk.CELL_SPACING_M) > 0.000001:
		warnings.append("Free-space CLV PRT source cells are fixed at 0.25 m. Set CLV Cell Size to 0.25 m or use another backend.")
	if clv_cache_backend == 1 and bake_manifest != null \
			and bake_manifest.transport_domain.is_empty() \
			and bake_manifest.has_baked_indirect_sh():
		warnings.append("This manifest contains legacy baked indirect SH, not a free-space TransferMatrix. Run a full free-space CLV PRT Bake; the old field is not converted.")
	if not uses_free_space_clv_bake() and not chunked_baking and (dims.x > Data.MAX_GRID_AXIS \
			or dims.y > Data.MAX_GRID_AXIS or dims.z > Data.MAX_GRID_AXIS):
		warnings.append("The lookup grid is limited to 64 cells per axis. Reduce the volume or increase Probe Spacing.")
	if not uses_free_space_clv_bake() and not _placement_warning_message.is_empty():
		warnings.append(_placement_warning_message)
	if bake_manifest != null and _scene_signature_checked:
		if not has_usable_bake():
			warnings.append("The streamed page manifest is invalid or incomplete. Re-bake to restore Magic GI.")
		elif needs_rebake():
			warnings.append("The saved page generation is stale; re-bake the changed scene or settings.")
		else:
			var emission_warning := Runtime.emission_warning(self)
			if not emission_warning.is_empty():
				warnings.append(emission_warning)
	elif bake_data != null and _scene_signature_checked:
		if not has_usable_bake():
			warnings.append("PRT bake data is invalid or incomplete. Re-bake to restore Magic GI.")
		elif needs_rebake():
			warnings.append("当前显示上次烘焙，仅供预览；场景或烘焙设置已变化，请重新 Bake。原因：%s" % "; ".join(bake_staleness_reasons()))
		if has_usable_bake():
			if not _cached_has_nonzero_indirect_transport:
				warnings.append(ZERO_TRANSFER_DIAGNOSTIC)
			var emission_warning := Runtime.emission_warning(self)
			if not emission_warning.is_empty():
				warnings.append(emission_warning)
	elif clv_cache_backend == 1 and bake_manifest == null and bake_data != null \
			and not bool(directional_transfer_status().get("ready", false)):
		warnings.append(String(directional_transfer_status().get("message", "Dynamic CLV PRT needs a valid directional TransferMatrix.")))
	var current_layout_count := candidate_probe_count() if _candidate_layout_ready else probe_count()
	if not uses_free_space_clv_bake() and not chunked_baking \
			and current_layout_count >= Placement.MAX_PROBES:
		warnings.append("Surface sample limit reached. Increase Probe Spacing or reduce the volume.")
	if not uses_free_space_clv_bake() and not chunked_baking \
			and current_layout_count == 0 and _scene_signature_checked:
		warnings.append("No supported surface geometry intersects this volume; the baker will not create air samples.")
	return warnings

func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED:
		_settings_changed()

func _refresh_viz() -> void:
	if _viz_queued or not is_inside_tree() or not Engine.is_editor_hint():
		return
	_viz_queued = true
	call_deferred("_apply_viz")

func _apply_viz() -> void:
	_viz_queued = false
	if not is_inside_tree() or not Engine.is_editor_hint() or _baking:
		return
	if is_surfel_mode():
		if _viz != null and is_instance_valid(_viz):
			_viz.visible = false
		return
	var preview_snapshot := Runtime.preview_snapshot(self) if show_probes or show_sh_probes else {}
	if _viz == null:
		_viz = Viz.build(self, preview_snapshot)
		add_child(_viz, false, INTERNAL_MODE_BACK)
	else:
		Viz.rebuild(self, _viz, preview_snapshot)
	_viz_preview_revision = int(preview_snapshot.get("revision", -1))
	_viz_view_revision = int(preview_snapshot.get("view_revision", -1))
	if _candidate_layout_ready:
		call_deferred("_rebuild_candidate_viz")

func _update_preview_if_changed() -> void:
	if is_surfel_mode() or not is_inside_tree() or not Engine.is_editor_hint() \
			or _baking or _viz == null:
		return
	var preview_snapshot := Runtime.preview_snapshot(self)
	if preview_snapshot.is_empty():
		return
	var revision := int(preview_snapshot.get("revision", -1))
	if revision != _viz_preview_revision:
		_viz_preview_revision = revision
		Viz.update_preview(self, _viz, preview_snapshot)
	var view_revision := int(preview_snapshot.get("view_revision", -1))
	if view_revision != _viz_view_revision:
		_viz_view_revision = view_revision
		Viz.update_preview_exposure(self, _viz, preview_snapshot)

func _sync_preview_exposure_request() -> void:
	if is_inside_tree() and Engine.is_editor_hint():
		Runtime.set_preview_requested(self,
				not is_surfel_mode() and (show_probes or show_sh_probes))
