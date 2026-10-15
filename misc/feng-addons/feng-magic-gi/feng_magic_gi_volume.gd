@tool
class_name FMagicGIVolume
extends Node3D
## Surface PRT volume. Samples lie on visible geometry; spacing is in world meters.

signal bake_status_changed
signal surface_refresh_completed(generation: int, success: bool)

const Runtime = preload("feng_magic_gi_runtime.gd")
const Baker = preload("feng_magic_gi_baker.gd")
const Placement = preload("feng_magic_gi_placement.gd")
const Viz = preload("feng_magic_gi_viz.gd")
const Data = preload("feng_magic_gi_data.gd")
const Manifest = preload("feng_magic_gi_manifest.gd")
const SceneTracker = preload("feng_magic_gi_scene_tracker.gd")
const Preview = preload("feng_magic_gi_preview.gd")
const ZERO_TRANSFER_DIAGNOSTIC := "本次几何间接传输与天空可见性均为零。请检查布点与静态采样，并确保 Volume 和 Bake Distance 覆盖可产生反弹的表面。要烘焙自发光贡献，请启用发光表面并重新 Bake。"
const BAKE_QUALITY_NAMES := ["Draft", "Final", "High"]
const BAKE_QUALITY_SAMPLES := [256, 1024, 2048]
const LAYOUT_IDLE_DEBOUNCE_MSEC := 280

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
@export_range(0.1, 16.0, 0.1, "or_greater", "suffix:m") var probe_spacing := 1.0:
	set(value):
		probe_spacing = clampf(value, 0.1, 4096.0)
		_settings_changed()
@export_range(0.001, 0.2, 0.001, "suffix:m") var surface_offset := 0.03:
	set(value):
		surface_offset = clampf(value, 0.001, 0.2)
		_settings_changed()
## Refine near nearby surfaces, corners and thin walls; smooth areas retain Probe Spacing.
@export var adaptive_placement := true:
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
@export var use_clv := true
@export_range(0.1, 2.0, 0.025, "suffix:m") var clv_cell_size := 0.5:
	set(value):
		clv_cell_size = clampf(value, 0.1, 2.0) if is_finite(value) else 0.5
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
@export_range(32.0, 512.0, 16.0, "suffix:m") var stream_distance := 128.0:
	set(value):
		stream_distance = clampf(value, 32.0, 512.0)
@export_range(0.0, 128.0, 4.0, "suffix:m") var stream_hysteresis := 32.0:
	set(value):
		stream_hysteresis = clampf(value, 0.0, 128.0)
@export_range(32, 1024, 32, "suffix:MiB") var cpu_resident_budget_mib := 256:
	set(value):
		cpu_resident_budget_mib = clampi(value, 32, 1024)
@export_range(64, 512, 32, "suffix:MiB") var gpu_resident_budget_mib := 128:
	set(value):
		gpu_resident_budget_mib = clampi(value, 64, 512)
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
		_invalidate_data_cache()
		_data_change_revision += 1
		_preview_revision += 1
		_preview_layout_match_key = ""
		_set_probe_layout_from_data(bake_data)
		_clear_candidate_layout()
		if is_inside_tree() and not _bake_assigning_data:
			_bake_generation += 1
			_mark_layout_stale()
			_schedule_saved_source_validation(true)
			Runtime.publish(self)
@export var bake_manifest: Manifest:
	set(value):
		if bake_manifest == value:
			return
		bake_manifest = value
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
	Runtime.register(self)
	_sync_preview_exposure_request()

func _ready() -> void:
	_set_probe_layout_from_data(bake_data)
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

## Indicates that this volume has saved bake data but it no longer matches the
## checked scene/layout. The valid old bake remains available for preview.
func needs_rebake() -> bool:
	return (bake_manifest != null or bake_data != null) \
			and (_layout_stale or _layout_dirty or _scene_signature_checked and not has_bake())

func has_legacy_sampler_signature() -> bool:
	return bake_data != null and _scene_signature_checked \
		and Data.sampler_revision_for_signature(bake_data.scene_signature) != Data.SAMPLER_REVISION

func bake_staleness_reasons() -> PackedStringArray:
	var reasons := PackedStringArray()
	if bake_manifest != null:
		if not bake_manifest.is_valid():
			reasons.append("the streamed page manifest is invalid")
		elif bake_manifest.bake_settings_signature != Baker.new()._streamed_settings_signature(self):
			reasons.append("volume bake settings changed")
		elif _source_watch_stale:
			reasons.append("scene sources changed since the bake")
		elif bake_manifest.scene_watch_signature > 0 \
				and not _saved_source_signature_matches_current():
			reasons.append("scene source geometry or material changed")
		return reasons
	if bake_data == null:
		return reasons
	if bake_data.format_version < Data.FORMAT_VERSION:
		reasons.append("format %d lacks static segment blockers; upgrade a matching v5 bake or rebake to v6" % bake_data.format_version)
	if has_legacy_sampler_signature():
		reasons.append("it uses sampler revision %d; the current sampler is revision %d" % [
			Data.sampler_revision_for_signature(bake_data.scene_signature), Data.SAMPLER_REVISION])
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
	if not is_inside_tree() or is_baking():
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
	_set_probe_layout_from_data(data)
	_clear_candidate_layout()
	_layout_dirty = false
	_layout_epoch += 1
	_preview_revision += 1
	_refresh_viz()
	Runtime.publish(self)
	update_configuration_warnings()
	return has_bake()

func bake_chunk(chunk_x: int, chunk_z: int) -> bool:
	if not chunked_baking or not is_inside_tree() or is_baking():
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
	return is_inside_tree() and generation == _bake_generation

func _rebuild_probes() -> void:
	if not is_inside_tree():
		return
	_layout_queued = true
	_schedule_layout_settle()

func _schedule_layout_settle() -> void:
	if not is_inside_tree():
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
	if not is_inside_tree() or is_baking():
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
	_source_validation_pending = true
	_source_validation_reset_legacy_baseline = _source_validation_reset_legacy_baseline \
			or reset_legacy_baseline
	if not is_inside_tree() or _source_validation_queued:
		return
	_source_validation_queued = true
	call_deferred("_run_saved_source_validation")

func _run_saved_source_validation() -> void:
	_source_validation_queued = false
	if not _source_validation_pending or not is_inside_tree() or _baking:
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
	if not is_inside_tree() or is_baking():
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
	while is_instance_valid(self) and _refresh_pending and is_inside_tree() and not is_baking():
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
	return is_inside_tree() and _refresh_active and not is_baking() \
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
				or Baker.new()._streamed_settings_signature(self) != bake_manifest.bake_settings_signature:
			return false
		if bake_manifest.scene_watch_signature > 0:
			return _saved_source_signature_matches_current()
		# Earlier streamed manifests persisted a process-local scene hash. It
		# cannot be compared across editor launches; establish a runtime watcher
		# and keep the readable generation until an actual source edit is observed.
		return _legacy_manifest_unverified
	if bake_data == null or not has_usable_bake():
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
	_invalidate_data_cache()
	_data_change_revision += 1
	_preview_revision += 1
	_preview_layout_match_key = ""
	_set_probe_layout_from_data(bake_data)
	if is_inside_tree():
		_mark_layout_stale()
		_schedule_saved_source_validation()
	Runtime.publish(self)

func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	var dims := grid_dimensions()
	if not chunked_baking and (dims.x > Data.MAX_GRID_AXIS \
			or dims.y > Data.MAX_GRID_AXIS or dims.z > Data.MAX_GRID_AXIS):
		warnings.append("The lookup grid is limited to 64 cells per axis. Reduce the volume or increase Probe Spacing.")
	if not _placement_warning_message.is_empty():
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
	var current_layout_count := candidate_probe_count() if _candidate_layout_ready else probe_count()
	if not chunked_baking and current_layout_count >= Placement.MAX_PROBES:
		warnings.append("Surface sample limit reached. Increase Probe Spacing or reduce the volume.")
	if not chunked_baking and current_layout_count == 0 and _scene_signature_checked:
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
	if not is_inside_tree() or not Engine.is_editor_hint() or _baking or _viz == null:
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
		Runtime.set_preview_requested(self, show_probes or show_sh_probes)
