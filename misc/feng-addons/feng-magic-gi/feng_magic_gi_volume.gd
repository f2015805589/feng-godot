@tool
class_name FMagicGIVolume
extends Node3D
## Surface PRT volume. Samples lie on visible geometry; spacing is in world meters.

signal bake_status_changed

const Runtime = preload("feng_magic_gi_runtime.gd")
const Baker = preload("feng_magic_gi_baker.gd")
const Placement = preload("feng_magic_gi_placement.gd")
const Viz = preload("feng_magic_gi_viz.gd")
const Data = preload("feng_magic_gi_data.gd")
const SceneTracker = preload("feng_magic_gi_scene_tracker.gd")
const ZERO_TRANSFER_DIAGNOSTIC := "本次间接传输全为零，Magic GI 不会改变画面。太阳与环境直达光由引擎处理；若需间接光，请检查布点与静态采样，并确保 Volume 和 Bake Distance 覆盖可产生反弹的表面。要烘焙自发光贡献，请启用发光表面并重新烘焙。"
const BAKE_QUALITY_NAMES := ["Draft", "Final", "High"]
const BAKE_QUALITY_SAMPLES := [256, 1024, 2048]

@export var size := Vector3(10.0, 10.0, 10.0):
	set(value):
		size = value if value.is_finite() else Vector3(10.0, 10.0, 10.0)
		size = size.max(Vector3.ONE * 0.01)
		_settings_changed()
@export_range(0.1, 16.0, 0.1, "or_greater", "suffix:m") var probe_spacing := 2.0:
	set(value):
		probe_spacing = clampf(value, 0.1, 4096.0)
		_settings_changed()
@export_range(0.001, 0.2, 0.001, "suffix:m") var surface_offset := 0.03:
	set(value):
		surface_offset = clampf(value, 0.001, 0.2)
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
## Optional explicit distant light/environment; otherwise the matching World3D is scanned.
@export var sun: DirectionalLight3D
@export var lighting_environment: Environment
@export var show_probes := true:
	set(value):
		show_probes = value
		_refresh_viz()
@export var show_sh_probes := false:
	set(value):
		show_sh_probes = value
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
		_settings_changed(false)
		if is_inside_tree() and not _bake_assigning_data:
			_rebuild_probes()

var probe_positions := PackedVector3Array()
var probe_normals := PackedVector3Array()
var _viz: Node3D
var _viz_queued := false
var _layout_queued := false
var _baking := false
var _bake_assigning_data := false
var _bake_generation := 0
var _next_geometry_check := 0
var _quick_scene_signature := 0
var _pending_scene_signature := 0
var _current_scene_signature := 0
var _validity_instance_id := 0
var _validity_bake_version := -1
var _validity_checked := false
var _cached_data_valid := false
var _cached_has_nonzero_indirect_transport := false
var _scene_signature_checked := false
var _last_emission_warning := ""

func _enter_tree() -> void:
	set_notify_transform(true)
	Runtime.register(self)
	_rebuild_probes()

func _exit_tree() -> void:
	_bake_generation += 1
	Runtime.unregister(self)

func _process(_delta: float) -> void:
	Runtime.tick()
	var now := Time.get_ticks_msec()
	if now >= _next_geometry_check and not _baking:
		_next_geometry_check = now + 1000
		var quick_signature := SceneTracker.quick_signature(self)
		if quick_signature == _quick_scene_signature:
			_pending_scene_signature = quick_signature
		elif quick_signature == _pending_scene_signature:
			# Geometry stayed identical for a full interval; resample once. While
			# things keep moving the signature changes every check, and the heavy
			# triangle collect + BVH rebuild is deferred until motion settles.
			refresh_surface_points()
		else:
			_pending_scene_signature = quick_signature
		Runtime.refresh_emission_diagnostics(self)
		var emission_warning := Runtime.emission_warning(self)
		if emission_warning != _last_emission_warning:
			_last_emission_warning = emission_warning
			update_configuration_warnings()

func has_bake() -> bool:
	if not is_inside_tree() or bake_data == null or not _scene_signature_checked:
		return false
	if not has_usable_bake():
		return false
	return bake_data.matches_layout(size, probe_spacing, surface_offset, global_transform,
			bake_samples, bake_bounces, bake_distance, terrain_reflectance, fallback_material_reflectance) \
		and bake_data.scene_signature == Data.signature_for_geometry(_current_scene_signature)

## True when the saved resource is structurally sound and can still be sampled,
## even if the current scene/layout no longer matches the bake.
func has_usable_bake() -> bool:
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
	return bake_data != null and _scene_signature_checked and not has_bake()

func has_legacy_sampler_signature() -> bool:
	return bake_data != null and _scene_signature_checked \
		and bake_data.scene_signature == _current_scene_signature

func bake_staleness_reasons() -> PackedStringArray:
	var reasons := PackedStringArray()
	if bake_data == null:
		return reasons
	if has_legacy_sampler_signature():
		reasons.append("the saved format-2 bake uses the previous random sampler")
	if bake_data.bake_samples != bake_samples:
		reasons.append("it used %d rays per point; the selected quality requests %d" % [
			bake_data.bake_samples, bake_samples])
	if reasons.is_empty():
		reasons.append("geometry, volume layout, material input, or another bake setting changed")
	return reasons

func has_nonzero_indirect_transfer() -> bool:
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

func bake() -> bool:
	if not is_inside_tree() or _baking:
		return false
	_baking = true
	var generation := _bake_generation
	var data := await Baker.new().bake_volume(self, generation)
	if not is_instance_valid(self):
		return false
	_baking = false
	if data == null or generation != _bake_generation:
		return false
	data.bake_version = Time.get_ticks_usec()
	_bake_assigning_data = true
	bake_data = data
	_bake_assigning_data = false
	refresh_surface_points()
	Runtime.publish(self)
	return has_bake()

## Public bake-generation check used by the async Baker after yielding. The
## generation remains private so callers cannot invalidate a bake themselves.
func is_bake_request_current(generation: int) -> bool:
	return is_inside_tree() and generation == _bake_generation

func _rebuild_probes() -> void:
	if not is_inside_tree() or _layout_queued:
		return
	_layout_queued = true
	call_deferred("refresh_surface_points")

func refresh_surface_points() -> void:
	_layout_queued = false
	if not is_inside_tree() or _baking:
		return
	var placement := Placement.new()
	var use_bake_bounds := bake_data != null
	if not placement.collect(self, use_bake_bounds, false):
		push_warning("FMagicGI: " + placement.error_message)
		probe_positions.clear()
		probe_normals.clear()
		_current_scene_signature = 0
		_scene_signature_checked = true
	else:
		probe_positions = placement.positions
		probe_normals = placement.normals
		_current_scene_signature = placement.scene_signature
		_scene_signature_checked = true
	_quick_scene_signature = SceneTracker.quick_signature(self)
	_refresh_viz()
	Runtime.publish(self)
	update_configuration_warnings()
	bake_status_changed.emit()

func _settings_changed(rebuild := true) -> void:
	_bake_generation += 1
	_invalidate_data_cache()
	_scene_signature_checked = false
	if rebuild:
		_rebuild_probes()
	Runtime.publish(self)
	update_configuration_warnings()

func _sample_quality_changed() -> void:
	# Ray count affects the bake but not the surface layout/signature.
	_bake_generation += 1
	_invalidate_data_cache()
	Runtime.publish(self)
	update_configuration_warnings()
	bake_status_changed.emit()

func _invalidate_data_cache() -> void:
	_validity_checked = false
	_cached_data_valid = false
	_cached_has_nonzero_indirect_transport = false

func _on_data_changed() -> void:
	_invalidate_data_cache()
	Runtime.publish(self)
	update_configuration_warnings()
	bake_status_changed.emit()

func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	var dims := grid_dimensions()
	if dims.x > Data.MAX_GRID_AXIS or dims.y > Data.MAX_GRID_AXIS or dims.z > Data.MAX_GRID_AXIS:
		warnings.append("The lookup grid is limited to 64 cells per axis. Reduce the volume or increase Probe Spacing.")
	if bake_data != null and _scene_signature_checked:
		if not has_usable_bake():
			warnings.append("PRT bake data is invalid or incomplete. Re-bake to restore Magic GI.")
		elif needs_rebake():
			warnings.append("当前显示上次烘焙，仅供预览；场景或烘焙设置已变化，请重新 Bake。原因：%s" % "; ".join(bake_staleness_reasons()))
		elif not _cached_has_nonzero_indirect_transport:
			warnings.append(ZERO_TRANSFER_DIAGNOSTIC)
		if has_usable_bake():
			var emission_warning := Runtime.emission_warning(self)
			if not emission_warning.is_empty():
				warnings.append(emission_warning)
	if probe_count() >= Placement.MAX_PROBES:
		warnings.append("Surface sample limit reached. Increase Probe Spacing or reduce the volume.")
	if probe_count() == 0 and _scene_signature_checked:
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
	if _viz == null:
		_viz = Viz.build(self)
		add_child(_viz, false, INTERNAL_MODE_BACK)
	else:
		Viz.rebuild(self, _viz)
