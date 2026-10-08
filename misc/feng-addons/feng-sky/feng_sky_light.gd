@tool
class_name FengSkyLight
extends Node3D
## Publishes one World3D-wide radiance source to FRP and MagicGI. CapturedScene
## records scene geometry around the chosen position; capture_sky supplies only
## the infinitely distant capture background.

const AtmosphereRuntime = preload("res://addons/feng-sky/feng_sky_runtime.gd")
const Runtime = preload("res://addons/feng-sky/feng_sky_light_runtime.gd")
const NativeAdapter = preload("res://addons/feng-sky/feng_sky_light_native_adapter.gd")
const CubemapAdapter = preload("res://addons/feng-sky/feng_sky_light_cubemap_adapter.gd")
const SnapshotWorldsPath := "res://addons/feng-render-pipeline/passes/snapshot_worlds.gd"
const FogRuntimePath := "res://addons/feng-fog/feng_fog_runtime.gd"
const CloudRuntimePath := "res://addons/feng-cloud/feng_cloud_runtime.gd"
const CaptureEffectPath := "res://addons/feng-sky/feng_sky_light_capture_effect.gd"
const PANORAMA_SIZE := Vector2i(64, 32)
const NATIVE_POLL_MSEC := 100
const ENVIRONMENT_CHECK_MSEC := 250

enum SourceMode { CAPTURED_SCENE, SPECIFIED_CUBEMAP, SPECIFIED_SKY }

@export_group("Sky Light")
@export var enabled := true:
	set(value):
		if enabled == value:
			return
		enabled = value
		_refresh_provider()
@export var priority := 0:
	set(value):
		if priority == value:
			return
		priority = value
		_refresh_provider()
@export_enum("Captured Scene", "Specified Cubemap", "Specified Sky") var source_mode: int = SourceMode.CAPTURED_SCENE:
	set(value):
		value = clampi(value, SourceMode.CAPTURED_SCENE, SourceMode.SPECIFIED_SKY)
		if source_mode == value:
			return
		_unbind_source_signals()
		source_mode = value
		_bind_source_signals()
		if source_mode == SourceMode.SPECIFIED_CUBEMAP:
			_cubemap_dirty = true
		elif source_mode == SourceMode.SPECIFIED_SKY:
			_capture_environment_dirty = true
		_mark_capture_dirty(true, true, true)
@export_range(0.0, 64.0, 0.01, "or_greater") var radiance_energy := 1.0:
	set(value):
		radiance_energy = maxf(value if is_finite(value) else 0.0, 0.0)
		_project_cached_panorama()
		_refresh_provider()
@export var realtime_capture := true:
	set(value):
		if realtime_capture == value:
			return
		realtime_capture = value
		if value:
			_bake_loaded = false
			_next_capture_msec = Time.get_ticks_msec()
		elif _bake_resource_is_valid():
			_try_load_baked_radiance(true)
@export_range(0.05, 3600.0, 0.05, "or_greater", "suffix:s") var capture_interval := 1.0:
	set(value):
		capture_interval = clampf(value if is_finite(value) else 1.0, 0.05, 3600.0)
		if realtime_capture:
			_next_capture_msec = Time.get_ticks_msec() + int(capture_interval * 1000.0)
@export_range(32, 2048, 32, "or_greater", "suffix:px") var capture_resolution := 128:
	set(value):
		capture_resolution = _normalize_capture_resolution(value)
		if _can_apply_capture_configuration():
			_configure_output_sky_radiance_size()
		_mark_capture_dirty(true, true)
@export_range(0.1, 262144.0, 0.1, "or_greater", "suffix:m") var capture_distance := 4000.0:
	set(value):
		capture_distance = clampf(value if is_finite(value) else 4000.0, 0.1, 262144.0)
		_mark_capture_dirty(true, true)
@export_flags_3d_render var cull_mask := 0xFFFFF:
	set(value):
		cull_mask = value & 0xFFFFF
		_mark_capture_dirty(true, true)
@export var capture_shadows := true:
	set(value):
		if capture_shadows == value:
			return
		capture_shadows = value
		_mark_capture_dirty(true, true)

@export_group("Source")
@export var capture_sky: Sky:
	set(value):
		if capture_sky == value:
			return
		_unbind_source_signals()
		capture_sky = value
		_bind_source_signals()
		_mark_capture_dirty(source_mode == SourceMode.CAPTURED_SCENE,
				source_mode == SourceMode.CAPTURED_SCENE, true)
@export var source_sky: Sky:
	set(value):
		if source_sky == value:
			return
		_unbind_source_signals()
		source_sky = value
		_bind_source_signals()
		if source_mode == SourceMode.SPECIFIED_SKY:
			_capture_environment_dirty = true
			_mark_capture_dirty(true, true, true)
@export var cubemap: Cubemap:
	set(value):
		if cubemap == value:
			return
		_unbind_source_signals()
		cubemap = value
		_bind_source_signals()
		if source_mode == SourceMode.SPECIFIED_CUBEMAP:
			_cubemap_dirty = true
			if _can_apply_capture_configuration():
				_configure_output_sky_radiance_size()
			_refresh_provider()
## Optional position anchor. Offset is added in world metres, independent of the
## anchor's rotation. Empty uses this component's global position.
@export var capture_anchor: Node3D:
	set(value):
		if capture_anchor == value:
			return
		capture_anchor = value
		_mark_capture_dirty(true, false)
@export var capture_offset := Vector3(0.0, 100.0, 0.0):
	set(value):
		capture_offset = value if value.is_finite() else Vector3(0.0, 100.0, 0.0)
		_mark_capture_dirty(true, false)

@export_group("Baked Radiance")
@export var bake_data: FengSkyLightBakeData:
	set(value):
		if bake_data == value:
			return
		bake_data = value
		if is_inside_tree() and not _writing_bake_data and not realtime_capture:
			_try_load_baked_radiance(true)
@export_file("*.res", "*.tres") var bake_path := ""

@export_tool_button("Capture Now") var capture_now_button = recapture
@export_tool_button("Bake Now") var bake_now_button = bake_capture

var _output_sky: Sky
var _output_source_mode: SourceMode = SourceMode.CAPTURED_SCENE
var _capture_probe: ReflectionProbe
var _capture_environment: Environment
var _capture_environment_id := 0
var _bound_capture_sky: Sky
var _bound_resources: Array[Resource] = []
var _snapshot_worlds: Script
var _registered_targets: Array[RID] = []
var _last_registration_signature: Array = []
var _current_world_id := 0
var _last_radiance_basis := Basis.IDENTITY
var _last_environment_identity: Array = []
var _connected_tree: SceneTree
var _capture_environment_dirty := true
var _capture_environment_snapshot_pending := true
var _capture_native_config_dirty := true
var _capture_request_pending := true
var _capture_in_flight := false
var _capture_submitted_revision := -1
var _capture_snapshot_after_inflight := false
var _capture_native_signature: Array = []
var _capture_fog_effect: CompositorEffect
var _capture_fog_effect_prepared := false
var _capture_fog_effect_active := false
var _provider_active := false
var _external_radiance_enabled := false
var _native_radiance_ready := false
var _native_radiance_revision := -1
var _native_radiance_exposure := 1.0
var _next_capture_msec := 0
var _next_environment_check_msec := 0
var _next_radiance_poll_msec := 0
var _last_projected_revision := -1
var _last_projected_signature: Array = []
var _projected_exposure := 1.0
var _radiance_sh := PackedFloat32Array()
var _cached_panorama: Image
var _cubemap_dirty := true
var _explicit_capture_authorized := false
var _bake_requested := false
var _bake_loaded := false
var _bake_capture_metadata: Dictionary = {}
var _bake_capture_submitted := false
var _bake_capture_revision_before := -1
var _writing_bake_data := false


func _enter_tree() -> void:
	set_process(true)
	if _output_sky == null or not is_instance_valid(_output_sky):
		_output_sky = Sky.new()
		_output_source_mode = source_mode
	_configure_output_sky_radiance_size()
	if _snapshot_worlds == null and ResourceLoader.exists(SnapshotWorldsPath):
		_snapshot_worlds = load(SnapshotWorldsPath) as Script
	_bind_source_signals()
	_current_world_id = _world_id()
	if not realtime_capture and _bake_resource_is_valid():
		_capture_request_pending = false
		_try_load_baked_radiance()
	_refresh_provider()


func _ready() -> void:
	_refresh_provider()


func _exit_tree() -> void:
	_disconnect_tree_signals()
	_unbind_source_signals()
	Runtime.unregister_provider(self)
	if _provider_active:
		_deactivate_provider()
	_clear_render_target_routes()
	if _snapshot_worlds != null:
		_snapshot_worlds.call("unregister_owner", self)
	if _capture_probe != null and is_instance_valid(_capture_probe):
		_remove_capture_probe()
	if _output_sky != null and _external_radiance_enabled:
		NativeAdapter.enable_external_radiance(_output_sky, false)
	_external_radiance_enabled = false
	_provider_active = false


func _process(_delta: float) -> void:
	if not is_inside_tree():
		return
	var now := Time.get_ticks_msec()
	var current_world_id := _world_id()
	if current_world_id != _current_world_id:
		_current_world_id = current_world_id
		_reset_capture_in_flight()
		_capture_environment_dirty = true
		_capture_native_config_dirty = true
		_capture_request_pending = _uses_probe_capture() \
				and (realtime_capture or (not _native_radiance_ready and not _bake_loaded))
		_capture_environment_snapshot_pending = _capture_request_pending
		if source_mode == SourceMode.CAPTURED_SCENE:
			_last_environment_identity = _environment_identity()
		_bind_source_signals()
		Runtime.refresh_provider(self)
	if source_mode == SourceMode.CAPTURED_SCENE and now >= _next_environment_check_msec:
		_next_environment_check_msec = now + ENVIRONMENT_CHECK_MSEC
		var environment_identity := _environment_identity()
		if environment_identity != _last_environment_identity:
			_last_environment_identity = environment_identity
			_capture_environment_dirty = true
			_bind_source_signals()
			if source_mode == SourceMode.CAPTURED_SCENE:
				_mark_capture_dirty(true, true, true)
	if not _provider_active:
		return
	if _uses_probe_capture() and realtime_capture \
			and now >= _next_capture_msec:
		if not _capture_in_flight or not _capture_snapshot_after_inflight:
			_queue_scene_capture()
			_sync_active_source()
	if now >= _next_radiance_poll_msec:
		_next_radiance_poll_msec = now + NATIVE_POLL_MSEC
		_poll_external_radiance()
		_sync_frp_sources()
	if _bake_requested and _bake_capture_submitted and not _capture_in_flight \
			and _native_radiance_ready \
			and _native_radiance_revision > _bake_capture_revision_before:
		_finish_requested_bake()
	var basis := _radiance_rotation()
	if basis != _last_radiance_basis:
		_last_radiance_basis = basis
		_project_cached_panorama()
		_sync_frp_sources()
	_sync_active_source()


func recapture() -> void:
	_explicit_capture_authorized = true
	if source_mode == SourceMode.SPECIFIED_CUBEMAP:
		_force_cubemap_refresh()
	else:
		_queue_scene_capture()
		if _provider_active:
			_sync_active_source()


func bake_capture() -> void:
	_bake_requested = true
	_bake_capture_submitted = false
	_bake_capture_revision_before = -1
	_bake_capture_metadata.clear()
	recapture()
	if _bake_capture_submitted and not _capture_in_flight and _native_radiance_ready \
			and _native_radiance_revision > _bake_capture_revision_before:
		_finish_requested_bake()


func _record_bake_capture_submission(position: Vector3, resolution: int,
		revision_before: int, source_to_world: Basis = Basis.IDENTITY) -> void:
	if not _bake_requested:
		return
	_bake_capture_metadata = {
		"capture_position": position,
		"capture_resolution": _normalize_capture_resolution(resolution),
		"source_description": _source_description(),
		"source_to_world_basis": source_to_world.orthonormalized(),
	}
	_bake_capture_revision_before = revision_before
	_bake_capture_submitted = true


func _uses_probe_capture() -> bool:
	return source_mode == SourceMode.CAPTURED_SCENE or source_mode == SourceMode.SPECIFIED_SKY


func _can_apply_capture_configuration() -> bool:
	return realtime_capture or _explicit_capture_authorized \
			or (not _native_radiance_ready and not _bake_loaded)


func _bake_resource_is_valid() -> bool:
	return bake_data != null and is_instance_valid(bake_data) and bake_data.is_valid()


func _try_load_baked_radiance(force: bool = false) -> void:
	if (realtime_capture and not force) or not _bake_resource_is_valid() or _output_sky == null:
		return
	if _capture_probe != null:
		_remove_capture_probe()
	if not _external_radiance_enabled:
		if not NativeAdapter.enable_external_radiance(_output_sky, true):
			return
		_external_radiance_enabled = true
	if NativeAdapter.set_cubemap_radiance(_output_sky, bake_data.radiance):
		_output_source_mode = source_mode
		_bake_loaded = true
		_native_radiance_ready = false
		_native_radiance_revision = -1
		_last_projected_revision = -1
		_last_projected_signature.clear()
		_capture_request_pending = false
		_capture_native_config_dirty = false
		_configure_output_sky_radiance_size()
		_next_radiance_poll_msec = 0
		_refresh_provider()


func _finish_requested_bake() -> void:
	_bake_requested = false
	if not _native_radiance_ready or _output_sky == null:
		return
	var face_size := int(_bake_capture_metadata.get("capture_resolution", _normalize_capture_resolution(capture_resolution)))
	var panorama_size := Vector2i(face_size * 4, face_size * 2)
	var panorama := NativeAdapter.bake_world_linear_panorama(_output_sky, panorama_size)
	if panorama == null or panorama.is_empty():
		push_warning("FengSkyLight bake failed: the completed radiance panorama is unavailable.")
		return
	var source_to_world: Basis = _bake_capture_metadata.get("source_to_world_basis", Basis.IDENTITY)
	var cubemap := _panorama_to_cubemap(panorama, face_size, source_to_world)
	if cubemap == null:
		push_warning("FengSkyLight bake failed: could not build an HDR cubemap from the radiance panorama.")
		return
	var data := bake_data if bake_data != null and is_instance_valid(bake_data) else FengSkyLightBakeData.new()
	data.radiance = cubemap
	data.capture_position = _bake_capture_metadata.get("capture_position", _effective_capture_position())
	data.capture_resolution = int(_bake_capture_metadata.get("capture_resolution", face_size))
	data.source_description = String(_bake_capture_metadata.get("source_description", _source_description()))
	_writing_bake_data = true
	bake_data = data
	_writing_bake_data = false
	var save_path := bake_path.strip_edges()
	if save_path.is_empty():
		save_path = data.resource_path
	if save_path.is_empty():
		push_warning("FengSkyLight bake data is ready in memory. Set Bake Path or assign a saved .res resource to persist it.")
		return
	var save_error := ResourceSaver.save(data, save_path)
	if save_error != OK:
		push_warning("FengSkyLight could not save bake data at '%s' (error %d)." % [save_path, save_error])
	else:
		bake_path = save_path


func _source_description() -> String:
	match source_mode:
		SourceMode.CAPTURED_SCENE:
			return "Captured Scene"
		SourceMode.SPECIFIED_CUBEMAP:
			return cubemap.resource_path if cubemap != null else "Specified Cubemap"
		SourceMode.SPECIFIED_SKY:
			return source_sky.resource_path if source_sky != null else "Specified Sky"
	return "FengSkyLight"


func _panorama_to_cubemap(panorama: Image, face_size: int,
		source_to_world: Basis = Basis.IDENTITY) -> Cubemap:
	if panorama == null or panorama.is_empty() or face_size <= 0:
		return null
	var world_to_source := source_to_world.orthonormalized().inverse()
	var face_images: Array[Image] = []
	for face in 6:
		var image := Image.create(face_size, face_size, false, Image.FORMAT_RGBAF)
		if image == null or image.is_empty():
			return null
		for y in face_size:
			var tc := 2.0 * (float(y) + 0.5) / float(face_size) - 1.0
			for x in face_size:
				var sc := 2.0 * (float(x) + 0.5) / float(face_size) - 1.0
				var world_direction := _cubemap_face_direction(face, sc, tc).normalized()
				var source_direction := (world_to_source * world_direction).normalized()
				image.set_pixel(x, y, _sample_world_linear_panorama(panorama, source_direction))
		face_images.append(image)
	var result := Cubemap.new()
	if result.create_from_images(face_images) != OK:
		return null
	return result


func _cubemap_face_direction(face: int, sc: float, tc: float) -> Vector3:
	match face:
		0: # +X
			return Vector3(1.0, -tc, -sc)
		1: # -X
			return Vector3(-1.0, -tc, sc)
		2: # +Y
			return Vector3(sc, 1.0, tc)
		3: # -Y
			return Vector3(sc, -1.0, -tc)
		4: # +Z
			return Vector3(sc, -tc, 1.0)
		5: # -Z
			return Vector3(-sc, -tc, -1.0)
	return Vector3.FORWARD


func _sample_world_linear_panorama(panorama: Image, direction: Vector3) -> Color:
	var normalized := direction.normalized()
	var phi := fposmod(atan2(-normalized.x, -normalized.z), TAU)
	var theta := acos(clampf(normalized.y, -1.0, 1.0))
	var width := panorama.get_width()
	var height := panorama.get_height()
	var pixel_x := phi / TAU * float(width) - 0.5
	var pixel_y := theta / PI * float(height) - 0.5
	var x0 := floori(pixel_x)
	var y0 := clampi(floori(pixel_y), 0, height - 1)
	var x1 := posmod(x0 + 1, width)
	var y1 := mini(y0 + 1, height - 1)
	var blend_x := pixel_x - floorf(pixel_x)
	var blend_y := 0.0 if pixel_y < 0.0 else clampf(pixel_y - floorf(pixel_y), 0.0, 1.0)
	x0 = posmod(x0, width)
	var top := panorama.get_pixel(x0, y0).lerp(panorama.get_pixel(x1, y0), blend_x)
	var bottom := panorama.get_pixel(x0, y1).lerp(panorama.get_pixel(x1, y1), blend_x)
	return top.lerp(bottom, blend_y)


func _normalize_capture_resolution(value: int) -> int:
	var clamped_value := clampi(value, 32, 2048)
	var lower := 32
	while lower * 2 <= clamped_value:
		lower *= 2
	var upper := mini(lower * 2, 2048)
	return lower if clamped_value - lower <= upper - clamped_value else upper


func _configure_output_sky_radiance_size() -> void:
	if _output_sky == null or not is_instance_valid(_output_sky):
		return
	var source_pixels := capture_resolution
	if source_mode == SourceMode.SPECIFIED_CUBEMAP and cubemap != null \
			and is_instance_valid(cubemap) and cubemap.get_width() > 0:
		source_pixels = cubemap.get_width()
	elif _bake_resource_is_valid():
		source_pixels = bake_data.capture_resolution
	var requested_size := _sky_radiance_size_enum(source_pixels)
	if _output_sky.radiance_size != requested_size:
		_output_sky.radiance_size = requested_size


func _sky_radiance_size_enum(source_pixels: int) -> int:
	match _normalize_capture_resolution(source_pixels):
		32:
			return Sky.RADIANCE_SIZE_32
		64:
			return Sky.RADIANCE_SIZE_64
		128:
			return Sky.RADIANCE_SIZE_128
		256:
			return Sky.RADIANCE_SIZE_256
		512:
			return Sky.RADIANCE_SIZE_512
		1024:
			return Sky.RADIANCE_SIZE_1024
		2048:
			return Sky.RADIANCE_SIZE_2048
	return Sky.RADIANCE_SIZE_256


func _refresh_provider() -> void:
	if is_inside_tree():
		Runtime.refresh_provider(self)


func _mark_capture_dirty(request_capture: bool = true,
		native_configuration: bool = true, environment_changed: bool = false) -> void:
	if _capture_in_flight and request_capture and (realtime_capture or _explicit_capture_authorized):
		_capture_snapshot_after_inflight = true
	elif not _capture_in_flight:
		_capture_fog_effect_prepared = false
	if environment_changed:
		_capture_environment_dirty = true
	if native_configuration:
		_capture_native_config_dirty = true
	if request_capture and _uses_probe_capture() \
			and (realtime_capture or _explicit_capture_authorized \
			or (not _native_radiance_ready and not _bake_loaded)):
		_capture_request_pending = true
		_capture_environment_snapshot_pending = true
	if is_inside_tree():
		_refresh_provider()


func _feng_sky_light_is_candidate(world_id: int) -> bool:
	if not enabled or not is_inside_tree() or _world_id() != world_id:
		return false
	if _native_radiance_ready or _bake_loaded:
		return true
	return source_mode == SourceMode.CAPTURED_SCENE \
			or (source_mode == SourceMode.SPECIFIED_CUBEMAP and cubemap != null) \
			or (source_mode == SourceMode.SPECIFIED_SKY and source_sky != null)


func _feng_sky_light_set_active(active: bool) -> void:
	if _provider_active == active:
		if active:
			_feng_sky_light_refresh_active()
		return
	_provider_active = active
	if active:
		_reset_capture_in_flight()
		_capture_environment_dirty = true
		_capture_native_config_dirty = true
		_capture_request_pending = _uses_probe_capture() \
				and (realtime_capture or (not _native_radiance_ready and not _bake_loaded))
		_capture_environment_snapshot_pending = _capture_request_pending
		_cubemap_dirty = source_mode == SourceMode.SPECIFIED_CUBEMAP
		_next_capture_msec = 0
		_connect_tree_signals()
		if _snapshot_worlds != null:
			_snapshot_worlds.call("scan", get_tree().root, self)
		_sync_active_source()
		_poll_external_radiance()
		_sync_frp_sources()
	else:
		_deactivate_provider()


func _deactivate_provider() -> void:
	_provider_active = false
	_disconnect_tree_signals()
	_clear_render_target_routes()
	if _snapshot_worlds != null:
		_snapshot_worlds.call("unregister_owner", self)
	_last_registration_signature.clear()
	_remove_capture_probe()
	if _output_sky != null and _external_radiance_enabled:
		NativeAdapter.enable_external_radiance(_output_sky, false)
	_external_radiance_enabled = false
	if _uses_probe_capture() and (realtime_capture or (not _native_radiance_ready and not _bake_loaded)):
		_capture_request_pending = true
		_capture_environment_snapshot_pending = true


func _feng_sky_light_refresh_active() -> void:
	if not _provider_active:
		return
	_sync_active_source()
	_poll_external_radiance()
	_sync_frp_sources()


func _feng_sky_light_runtime_snapshot() -> Dictionary:
	if not _provider_active or not _ensure_radiance_sh():
		return {}
	return {
		"ready": true,
		"source_mode": source_mode,
		"source_revision": _last_projected_revision,
		"captured_exposure": _projected_exposure,
		"energy": radiance_energy,
		"rotation": _radiance_rotation(),
		"radiance_sh": _radiance_sh,
	}


func _sync_active_source() -> void:
	if not _provider_active or _output_sky == null:
		return
	if not NativeAdapter.supports_external_radiance():
		return
	# In manual mode the completed radiance is immutable. Authored changes are
	# pending until Capture Now/Bake Now explicitly authorizes a replacement.
	if not _external_radiance_enabled:
		if not NativeAdapter.enable_external_radiance(_output_sky, true):
			return
		_external_radiance_enabled = true
	if not _can_apply_capture_configuration() and not _capture_in_flight:
		return
	if source_mode == SourceMode.SPECIFIED_CUBEMAP and cubemap == null:
		_explicit_capture_authorized = false
		return
	if source_mode == SourceMode.SPECIFIED_SKY and source_sky == null:
		_explicit_capture_authorized = false
		return
	if _output_source_mode != source_mode:
		_replace_output_sky_for_source_change()
	if source_mode == SourceMode.SPECIFIED_CUBEMAP:
		if _capture_probe != null:
			_remove_capture_probe()
		if cubemap == null:
			return
		if _cubemap_dirty:
			var revision_before_cubemap := NativeAdapter.external_radiance_revision(_output_sky)
			if NativeAdapter.set_cubemap_radiance(_output_sky, cubemap):
				_cubemap_dirty = false
				_capture_request_pending = false
				_capture_native_config_dirty = true
				_bake_loaded = false
				_native_radiance_ready = false
				_native_radiance_revision = -1
				_native_radiance_exposure = 1.0
				_last_projected_revision = -1
				_last_projected_signature.clear()
				_radiance_sh = PackedFloat32Array()
				_cached_panorama = null
				_explicit_capture_authorized = false
				_record_bake_capture_submission(_effective_capture_position(),
						cubemap.get_width(), revision_before_cubemap,
						global_basis.orthonormalized())
		return
	if not NativeAdapter.supports_scene_capture():
		return
	# A submitted capture owns its Environment snapshot and output Sky until the
	# renderer publishes a newer complete radiance revision. Requests arriving
	# meanwhile are merged into one follow-up request.
	if _capture_in_flight:
		return
	if _capture_request_pending:
		var refresh_environment := _capture_environment_snapshot_pending \
				or _capture_environment_dirty or _capture_environment == null
		if not _ensure_capture_environment(refresh_environment):
			return
	elif _capture_native_config_dirty and not _ensure_capture_environment(false):
		return
	_ensure_capture_probe()
	if _capture_probe == null or _capture_environment == null:
		return
	if _capture_request_pending and not _capture_fog_effect_prepared:
		_prepare_capture_fog_effect()
	var effective_cull_mask := 0 if source_mode == SourceMode.SPECIFIED_SKY else cull_mask
	var desired_signature: Array = [
		_capture_environment.get_instance_id(), _output_sky.get_instance_id(),
		capture_resolution, capture_distance, effective_cull_mask, capture_shadows,
		_capture_fog_effect.get_instance_id() if _capture_fog_effect_active \
				and _capture_fog_effect != null else 0]
	if _capture_native_config_dirty or desired_signature != _capture_native_signature:
		if _capture_native_signature.size() > 0:
			NativeAdapter.detach_capture_output(_capture_probe)
		var configured := NativeAdapter.set_capture_probe(_capture_probe,
				_capture_environment, _output_sky, capture_resolution,
				capture_distance, effective_cull_mask, capture_shadows,
				_capture_fog_effect if _capture_fog_effect_active \
						and source_mode == SourceMode.CAPTURED_SCENE else null)
		if not configured:
			return
		_capture_native_signature = desired_signature
		_capture_native_config_dirty = false
	if _capture_request_pending:
		_update_probe_position()
		var revision_before_capture := NativeAdapter.external_radiance_revision(_output_sky)
		if revision_before_capture < 0:
			return
		if NativeAdapter.request_capture(_capture_probe):
			_capture_request_pending = false
			_capture_in_flight = true
			_capture_fog_effect_prepared = false
			_capture_submitted_revision = revision_before_capture
			_capture_snapshot_after_inflight = false
			_explicit_capture_authorized = false
			_bake_loaded = false
			_record_bake_capture_submission(_capture_probe.global_position,
						capture_resolution, revision_before_capture)
			_next_capture_msec = Time.get_ticks_msec() + int(capture_interval * 1000.0)


func _replace_output_sky_for_source_change() -> void:
	# Remove native consumers and queued capture work before releasing the prior
	# external Sky. RenderingServer command ordering keeps these operations safe.
	_clear_render_target_routes()
	if _capture_probe != null:
		_remove_capture_probe()
	var old_output := _output_sky
	if old_output != null and _external_radiance_enabled:
		NativeAdapter.enable_external_radiance(old_output, false)
	_output_sky = Sky.new()
	_output_source_mode = source_mode
	_configure_output_sky_radiance_size()
	_external_radiance_enabled = false
	_native_radiance_ready = false
	_bake_loaded = false
	_native_radiance_revision = -1
	_native_radiance_exposure = 1.0
	_last_projected_revision = -1
	_last_projected_signature.clear()
	_projected_exposure = 1.0
	_radiance_sh = PackedFloat32Array()
	_cached_panorama = null
	_last_registration_signature.clear()
	_capture_native_signature.clear()
	_capture_native_config_dirty = true
	_capture_request_pending = _uses_probe_capture()
	_capture_environment_snapshot_pending = _capture_request_pending
	_cubemap_dirty = true


func _ensure_capture_environment(force_snapshot: bool = false) -> bool:
	var world := get_world_3d()
	var source_environment: Environment
	if source_mode == SourceMode.CAPTURED_SCENE and world != null:
		source_environment = world.environment
		if source_environment == null:
			source_environment = world.get_fallback_environment()
	var environment_id := source_environment.get_instance_id() if source_environment != null else 0
	var sky := _effective_capture_sky(world, source_environment)
	if not force_snapshot and not _capture_environment_dirty and _capture_environment != null \
			and environment_id == _capture_environment_id and sky == _bound_capture_sky:
		return true
	if _capture_environment != null and _capture_native_signature.size() > 0 \
			and _capture_probe != null and is_instance_valid(_capture_probe):
		NativeAdapter.detach_capture_output(_capture_probe)
	_capture_environment = source_environment.duplicate(false) as Environment \
			if source_mode == SourceMode.CAPTURED_SCENE and source_environment != null else Environment.new()
	if _capture_environment == null:
		_capture_environment = Environment.new()
	_capture_environment.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	_capture_environment.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	_capture_environment.sky = _snapshot_capture_sky(sky)
	if sky != null:
		_capture_environment.background_mode = Environment.BG_SKY
	if source_mode == SourceMode.SPECIFIED_SKY:
		_capture_environment.background_energy_multiplier = 1.0
		_capture_environment.background_intensity = 1.0
		_capture_environment.sky_rotation = Vector3.ZERO
		_capture_environment.fog_enabled = false
		_capture_environment.volumetric_fog_enabled = false
	_capture_environment_id = environment_id
	_bound_capture_sky = sky
	_capture_environment_dirty = false
	_capture_environment_snapshot_pending = false
	_capture_native_config_dirty = true
	_capture_native_signature.clear()
	_last_environment_identity = _environment_identity()
	return true


func _effective_capture_sky(world: World3D, source_environment: Environment) -> Sky:
	if source_mode == SourceMode.SPECIFIED_SKY:
		return source_sky
	if capture_sky != null:
		return capture_sky
	if source_environment != null:
		return source_environment.sky
	if world != null:
		var fallback := world.get_fallback_environment()
		return fallback.sky if fallback != null else null
	return null


func _snapshot_capture_sky(source: Sky) -> Sky:
	if source == null or not is_instance_valid(source):
		return null
	var snapshot := source.duplicate(false) as Sky
	if snapshot == null:
		return source
	var material := source.sky_material
	if material != null and is_instance_valid(material):
		snapshot.sky_material = material.duplicate(false) as Material
	return snapshot


func _prepare_capture_fog_effect() -> void:
	_capture_fog_effect_prepared = true
	_capture_fog_effect_active = false
	var world := get_world_3d()
	if source_mode != SourceMode.CAPTURED_SCENE or world == null:
		_clear_cached_capture_fog_snapshots()
		return
	var world_id := world.get_instance_id()
	var fog_snapshot := _fog_snapshot_for_world(world_id)
	var atmosphere_snapshot := AtmosphereRuntime.rendering_snapshot_for_world(world_id)
	var cloud_snapshot := _cloud_snapshot_for_world(world_id)
	if fog_snapshot.is_empty() and atmosphere_snapshot.is_empty() and cloud_snapshot.is_empty():
		_clear_cached_capture_fog_snapshots()
		return
	if _capture_fog_effect == null or not is_instance_valid(_capture_fog_effect):
		if not ResourceLoader.exists(CaptureEffectPath):
			return
		var capture_script: Variant = load(CaptureEffectPath)
		if not capture_script is Script:
			return
		var instance: Variant = capture_script.new()
		_capture_fog_effect = instance if instance is CompositorEffect else null
	if _capture_fog_effect != null and _capture_fog_effect.has_method("set_capture_snapshots"):
		_capture_fog_effect.call("set_capture_snapshots", fog_snapshot, atmosphere_snapshot, cloud_snapshot)
		_capture_fog_effect_active = true


func _cloud_snapshot_for_world(world_id: int) -> Dictionary:
	if not ResourceLoader.exists(CloudRuntimePath):
		return {}
	var runtime: Variant = load(CloudRuntimePath)
	if not runtime is Script or not runtime.has_method("snapshot_for_world"):
		return {}
	var snapshot: Variant = runtime.call("snapshot_for_world", world_id)
	if not snapshot is Dictionary or snapshot.is_empty() \
			or not bool(snapshot.get("visible_in_realtime_sky_captures", true)):
		return {}
	return snapshot.duplicate(true)


func _clear_cached_capture_fog_snapshots() -> void:
	if _capture_fog_effect != null and is_instance_valid(_capture_fog_effect) \
			and _capture_fog_effect.has_method("clear_capture_snapshots"):
		_capture_fog_effect.call("clear_capture_snapshots")


func _fog_snapshot_for_world(world_id: int) -> Dictionary:
	if not ResourceLoader.exists(FogRuntimePath):
		return {}
	var runtime: Variant = load(FogRuntimePath)
	if not runtime is Script or not runtime.has_method("snapshots"):
		return {}
	var snapshots: Variant = runtime.call("snapshots")
	if not snapshots is Array:
		return {}
	for snapshot in snapshots:
		if snapshot is Dictionary and int(snapshot.get("world_id", 0)) == world_id:
			return snapshot.duplicate(true)
	return {}


func _ensure_capture_probe() -> void:
	if _capture_probe != null and is_instance_valid(_capture_probe):
		return
	_capture_probe = ReflectionProbe.new()
	_capture_probe.name = "_FengSkyLightCapture"
	_capture_probe.update_mode = ReflectionProbe.UPDATE_ONCE
	_capture_probe.visible = true
	_capture_probe.max_distance = capture_distance
	_capture_probe.size = Vector3.ONE * (capture_distance * 2.0)
	_capture_probe.cull_mask = cull_mask
	_capture_probe.enable_shadows = capture_shadows
	add_child(_capture_probe, false, Node.INTERNAL_MODE_BACK)
	_capture_native_config_dirty = true


func _remove_capture_probe() -> void:
	_reset_capture_in_flight()
	if _capture_probe == null:
		_retire_capture_fog_effects()
		return
	if is_instance_valid(_capture_probe):
		NativeAdapter.detach_capture_output(_capture_probe)
		if _capture_probe.get_parent() != null:
			_capture_probe.get_parent().remove_child(_capture_probe)
		_capture_probe.queue_free()
	_capture_probe = null
	_retire_capture_fog_effects()
	_capture_native_signature.clear()
	_capture_native_config_dirty = true


func _retire_capture_fog_effects() -> void:
	var effects: Array[CompositorEffect] = []
	if _capture_fog_effect != null and is_instance_valid(_capture_fog_effect):
		effects.append(_capture_fog_effect)
	_capture_fog_effect = null
	_capture_fog_effect_prepared = false
	_capture_fog_effect_active = false
	Runtime.retain_capture_effects_until_rendered(effects)


func _update_probe_position() -> void:
	if _capture_probe != null and is_instance_valid(_capture_probe):
		_capture_probe.global_transform = Transform3D(Basis.IDENTITY, _effective_capture_position())


func _force_cubemap_refresh() -> void:
	_cubemap_dirty = true
	if _provider_active:
		_sync_active_source()
		_poll_external_radiance()
		_sync_frp_sources()


func _queue_scene_capture() -> void:
	_capture_request_pending = true
	if _capture_in_flight:
		_capture_snapshot_after_inflight = true
	else:
		_capture_environment_snapshot_pending = true


func _reset_capture_in_flight() -> void:
	_capture_in_flight = false
	_capture_submitted_revision = -1
	_capture_snapshot_after_inflight = false


func _complete_inflight_capture(now_msec: int) -> void:
	if not _capture_in_flight:
		return
	_capture_in_flight = false
	_capture_submitted_revision = -1
	_next_capture_msec = now_msec + int(capture_interval * 1000.0)
	if _capture_request_pending and _capture_snapshot_after_inflight:
		_capture_environment_snapshot_pending = true
	_capture_snapshot_after_inflight = false


func _poll_external_radiance() -> void:
	if not _provider_active or _output_sky == null:
		return
	var is_ready := NativeAdapter.external_radiance_ready(_output_sky)
	if not is_ready:
		_native_radiance_ready = false
		return
	var revision := NativeAdapter.external_radiance_revision(_output_sky)
	if revision < 0:
		return
	if _capture_in_flight and revision > _capture_submitted_revision:
		_complete_inflight_capture(Time.get_ticks_msec())
	var exposure := NativeAdapter.external_radiance_exposure(_output_sky)
	_native_radiance_ready = true
	_native_radiance_revision = revision
	_native_radiance_exposure = exposure


func _ensure_radiance_sh() -> bool:
	# MagicGI is the only consumer of this CPU SH snapshot. Keep the synchronous
	# panorama readback out of the capture/poll path and pay for it only when a
	# consumer requests the current completed radiance.
	var revision := _native_radiance_revision if _native_radiance_ready else _last_projected_revision
	if revision < 0:
		return false
	var rotation := _radiance_rotation()
	var signature: Array = [revision, radiance_energy, rotation]
	if signature == _last_projected_signature and _radiance_sh.size() == 27:
		return true
	if revision != _last_projected_revision or _cached_panorama == null \
			or _cached_panorama.is_empty():
		if not _native_radiance_ready or _output_sky == null:
			return false
		var panorama := NativeAdapter.bake_world_linear_panorama(_output_sky, PANORAMA_SIZE)
		if panorama == null or panorama.is_empty():
			return false
		_cached_panorama = panorama
		_last_projected_revision = revision
		_projected_exposure = _native_radiance_exposure
	_radiance_sh = CubemapAdapter.project_world_linear_panorama(
			_cached_panorama, rotation, radiance_energy)
	_last_projected_signature = signature
	return _radiance_sh.size() == 27


func _project_cached_panorama() -> void:
	# Invalidate the projected value without doing CPU work here. If MagicGI is
	# active, its next snapshot request will reproject the cached panorama.
	_last_projected_signature.clear()


func _connect_tree_signals() -> void:
	var tree := get_tree()
	if tree == null or _connected_tree == tree:
		return
	_disconnect_tree_signals()
	_connected_tree = tree
	if not tree.node_added.is_connected(_on_scene_node_added):
		tree.node_added.connect(_on_scene_node_added)
	if not tree.node_removed.is_connected(_on_scene_node_removed):
		tree.node_removed.connect(_on_scene_node_removed)


func _disconnect_tree_signals() -> void:
	if _connected_tree != null and is_instance_valid(_connected_tree):
		if _connected_tree.node_added.is_connected(_on_scene_node_added):
			_connected_tree.node_added.disconnect(_on_scene_node_added)
		if _connected_tree.node_removed.is_connected(_on_scene_node_removed):
			_connected_tree.node_removed.disconnect(_on_scene_node_removed)
	_connected_tree = null


func _on_scene_node_added(node: Node) -> void:
	if not _provider_active or _snapshot_worlds == null or not node is Viewport:
		return
	_snapshot_worlds.call("register_viewport", node, self)
	_next_radiance_poll_msec = 0


func _on_scene_node_removed(node: Node) -> void:
	if not _provider_active or _snapshot_worlds == null or not node is Viewport:
		return
	var viewport := node as Viewport
	var target := RenderingServer.viewport_get_render_target(viewport.get_viewport_rid())
	if target.is_valid() and _registered_targets.has(target):
		NativeAdapter.clear_frp_source(target, get_instance_id())
		_registered_targets.erase(target)
	_snapshot_worlds.call("unregister_viewport", viewport, self)
	_next_radiance_poll_msec = 0


func _sync_frp_sources() -> void:
	if not _provider_active:
		return
	var world := get_world_3d()
	var targets: Array[RID] = _snapshot_worlds.call("targets_for", world) \
			if _snapshot_worlds != null and world != null else []
	for target in _registered_targets.duplicate():
		if not targets.has(target):
			NativeAdapter.clear_frp_source(target, get_instance_id())
			_registered_targets.erase(target)
	if not _native_radiance_ready or _native_radiance_revision < 0 \
			or not NativeAdapter.supports_frp_registration():
		return
	var signature: Array = [
		_native_radiance_revision, _native_radiance_exposure,
		radiance_energy, _radiance_rotation()]
	var needs_all_targets := signature != _last_registration_signature
	var all_registered := true
	for target in targets:
		if not needs_all_targets and _registered_targets.has(target):
			continue
		if NativeAdapter.register_frp_source(target, get_instance_id(), _output_sky,
				radiance_energy, _radiance_rotation(), _native_radiance_exposure,
				_native_radiance_revision):
			if not _registered_targets.has(target):
				_registered_targets.append(target)
		else:
			all_registered = false
	if all_registered:
		_last_registration_signature = signature


func _clear_render_target_routes() -> void:
	for target in _registered_targets:
		NativeAdapter.clear_frp_source(target, get_instance_id())
	_registered_targets.clear()
	_last_registration_signature.clear()


func _effective_capture_position() -> Vector3:
	var world := get_world_3d() if is_inside_tree() else null
	if capture_anchor != null and is_instance_valid(capture_anchor) \
			and capture_anchor.is_inside_tree() and capture_anchor.get_world_3d() == world:
		return capture_anchor.global_position + capture_offset
	return global_position + capture_offset


func _radiance_rotation() -> Basis:
	# Probe captures and baked radiance are already in world axes. Only a live
	# supplied Cubemap follows this node's orientation. Use the source that owns
	# the current output, not a pending manual-mode selection.
	if _bake_loaded or _output_source_mode != SourceMode.SPECIFIED_CUBEMAP:
		return Basis.IDENTITY
	return global_basis.orthonormalized()


func _world_id() -> int:
	var world := get_world_3d() if is_inside_tree() else null
	return world.get_instance_id() if world != null else 0


func _environment_identity() -> Array:
	var world := get_world_3d() if is_inside_tree() else null
	var environment: Environment
	if world != null:
		environment = world.environment
		if environment == null:
			environment = world.get_fallback_environment()
	var sky := _effective_capture_sky(world, environment)
	return [environment.get_instance_id() if environment != null else 0,
		sky.get_instance_id() if sky != null else 0]


func _bind_source_signals() -> void:
	_unbind_source_signals()
	var resources: Array[Resource] = []
	var selected_resource: Resource
	match source_mode:
		SourceMode.CAPTURED_SCENE:
			selected_resource = capture_sky
		SourceMode.SPECIFIED_CUBEMAP:
			selected_resource = cubemap
		SourceMode.SPECIFIED_SKY:
			selected_resource = source_sky
	if selected_resource != null and is_instance_valid(selected_resource):
		resources.append(selected_resource)
	if source_mode == SourceMode.CAPTURED_SCENE:
		var world := get_world_3d() if is_inside_tree() else null
		if world != null:
			var source_environment := world.environment
			if source_environment == null:
				source_environment = world.get_fallback_environment()
			if source_environment != null and not resources.has(source_environment):
				resources.append(source_environment)
	for resource in resources:
		if not resource.changed.is_connected(_on_source_changed):
			resource.changed.connect(_on_source_changed)
	_bound_resources = resources


func _unbind_source_signals() -> void:
	for resource in _bound_resources:
		if resource != null and is_instance_valid(resource) \
				and resource.changed.is_connected(_on_source_changed):
			resource.changed.disconnect(_on_source_changed)
	_bound_resources.clear()


func _on_source_changed() -> void:
	if source_mode == SourceMode.CAPTURED_SCENE or source_mode == SourceMode.SPECIFIED_SKY:
		_capture_environment_dirty = true
		_mark_capture_dirty(true, true, true)
	else:
		_cubemap_dirty = true
		if source_mode == SourceMode.SPECIFIED_CUBEMAP:
			_configure_output_sky_radiance_size()
		_refresh_provider()
