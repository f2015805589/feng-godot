@tool
class_name FengSkyLight
extends Node3D
## Publishes one World3D-wide radiance source to FRP and MagicGI. CapturedScene
## records scene geometry around the chosen position; capture_sky supplies only
## the infinitely distant capture background.

const Runtime = preload("res://addons/feng-sky/feng_sky_light_runtime.gd")
const NativeAdapter = preload("res://addons/feng-sky/feng_sky_light_native_adapter.gd")
const CubemapAdapter = preload("res://addons/feng-sky/feng_sky_light_cubemap_adapter.gd")
const SnapshotWorldsPath := "res://addons/feng-render-pipeline/passes/snapshot_worlds.gd"
const PANORAMA_SIZE := Vector2i(64, 32)
const ROUTE_REFRESH_MSEC := 500
const NATIVE_POLL_MSEC := 100
const ENVIRONMENT_CHECK_MSEC := 250

enum SourceMode { CAPTURED_SCENE, SPECIFIED_CUBEMAP }

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
@export_enum("Captured Scene", "Specified Cubemap") var source_mode: int = SourceMode.CAPTURED_SCENE:
	set(value):
		value = clampi(value, SourceMode.CAPTURED_SCENE, SourceMode.SPECIFIED_CUBEMAP)
		if source_mode == value:
			return
		_unbind_source_signals()
		source_mode = value
		_bind_source_signals()
		if source_mode == SourceMode.SPECIFIED_CUBEMAP:
			_cubemap_dirty = true
		_configure_output_sky_radiance_size()
		_mark_capture_dirty(true, true, source_mode == SourceMode.CAPTURED_SCENE)
@export_range(0.0, 64.0, 0.01, "or_greater") var radiance_energy := 1.0:
	set(value):
		radiance_energy = maxf(value if is_finite(value) else 0.0, 0.0)
		_project_cached_panorama()
		_refresh_provider()
@export var realtime_capture := false:
	set(value):
		if realtime_capture == value:
			return
		realtime_capture = value
		if value:
			_next_capture_msec = Time.get_ticks_msec()
@export_range(0.05, 3600.0, 0.05, "or_greater", "suffix:s") var capture_interval := 1.0:
	set(value):
		capture_interval = clampf(value if is_finite(value) else 1.0, 0.05, 3600.0)
		if realtime_capture:
			_next_capture_msec = Time.get_ticks_msec() + int(capture_interval * 1000.0)
@export_range(32, 2048, 32, "or_greater", "suffix:px") var capture_resolution := 128:
	set(value):
		capture_resolution = _normalize_capture_resolution(value)
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
@export var cubemap: Cubemap:
	set(value):
		if cubemap == value:
			return
		_unbind_source_signals()
		cubemap = value
		_bind_source_signals()
		if source_mode == SourceMode.SPECIFIED_CUBEMAP:
			_cubemap_dirty = true
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

@export_tool_button("Capture Now") var capture_now_button = recapture

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
var _provider_active := false
var _external_radiance_enabled := false
var _native_radiance_ready := false
var _native_radiance_revision := -1
var _native_radiance_exposure := 1.0
var _next_capture_msec := 0
var _next_route_scan_msec := 0
var _next_environment_check_msec := 0
var _next_radiance_poll_msec := 0
var _last_projected_revision := -1
var _last_projected_signature: Array = []
var _projected_exposure := 1.0
var _radiance_sh := PackedFloat32Array()
var _cached_panorama: Image
var _cubemap_dirty := true


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
		_capture_request_pending = source_mode == SourceMode.CAPTURED_SCENE
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
	if now >= _next_route_scan_msec:
		_next_route_scan_msec = now + ROUTE_REFRESH_MSEC
		_sync_viewport_routes()
		_sync_frp_sources()
	if source_mode == SourceMode.CAPTURED_SCENE and realtime_capture \
			and now >= _next_capture_msec:
		if not _capture_in_flight or not _capture_snapshot_after_inflight:
			_queue_scene_capture()
			_sync_active_source()
	if now >= _next_radiance_poll_msec:
		_next_radiance_poll_msec = now + NATIVE_POLL_MSEC
		_poll_external_radiance()
		_sync_frp_sources()
	var basis := _radiance_rotation()
	if basis != _last_radiance_basis:
		_last_radiance_basis = basis
		_project_cached_panorama()
		_sync_frp_sources()
	_sync_active_source()


func recapture() -> void:
	if source_mode == SourceMode.CAPTURED_SCENE:
		_queue_scene_capture()
		if _provider_active:
			_sync_active_source()
	elif source_mode == SourceMode.SPECIFIED_CUBEMAP:
		_force_cubemap_refresh()


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
	if native_configuration or environment_changed \
			or (request_capture and source_mode == SourceMode.CAPTURED_SCENE):
		_reset_capture_in_flight()
	if environment_changed:
		_capture_environment_dirty = true
	if native_configuration:
		_capture_native_config_dirty = true
	if request_capture and source_mode == SourceMode.CAPTURED_SCENE:
		_capture_request_pending = true
		_capture_environment_snapshot_pending = true
	if is_inside_tree():
		_refresh_provider()


func _feng_sky_light_is_candidate(world_id: int) -> bool:
	return enabled and is_inside_tree() and _world_id() == world_id \
			and (source_mode == SourceMode.CAPTURED_SCENE or cubemap != null)


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
		_capture_request_pending = source_mode == SourceMode.CAPTURED_SCENE
		_capture_environment_snapshot_pending = _capture_request_pending
		_cubemap_dirty = true
		_next_capture_msec = 0
		_next_route_scan_msec = 0
		_connect_tree_signals()
		_sync_viewport_routes(true)
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
	if source_mode == SourceMode.CAPTURED_SCENE:
		_capture_request_pending = true
		_capture_environment_snapshot_pending = true


func _feng_sky_light_refresh_active() -> void:
	if not _provider_active:
		return
	_sync_active_source()
	_sync_viewport_routes()
	_poll_external_radiance()
	_sync_frp_sources()


func _feng_sky_light_runtime_snapshot() -> Dictionary:
	if not _provider_active or _radiance_sh.size() != 27 or _last_projected_revision < 0:
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
	if _output_source_mode != source_mode:
		_replace_output_sky_for_source_change()
	if not _external_radiance_enabled:
		if not NativeAdapter.enable_external_radiance(_output_sky, true):
			return
		_external_radiance_enabled = true
	if source_mode == SourceMode.SPECIFIED_CUBEMAP:
		if _capture_probe != null:
			_remove_capture_probe()
		if cubemap == null:
			return
		if _cubemap_dirty:
			if NativeAdapter.set_cubemap_radiance(_output_sky, cubemap):
				_cubemap_dirty = false
				_capture_request_pending = false
				_capture_native_config_dirty = true
				_native_radiance_ready = false
				_native_radiance_revision = -1
				_native_radiance_exposure = 1.0
				_last_projected_revision = -1
				_last_projected_signature.clear()
				_radiance_sh = PackedFloat32Array()
				_cached_panorama = null
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
	var desired_signature: Array = [
		_capture_environment.get_instance_id(), _output_sky.get_instance_id(),
		capture_resolution, capture_distance, cull_mask, capture_shadows]
	if _capture_native_config_dirty or desired_signature != _capture_native_signature:
		if _capture_native_signature.size() > 0:
			NativeAdapter.detach_capture_output(_capture_probe)
		var configured := NativeAdapter.set_capture_probe(_capture_probe,
				_capture_environment, _output_sky, capture_resolution,
				capture_distance, cull_mask, capture_shadows)
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
			_capture_submitted_revision = revision_before_capture
			_capture_snapshot_after_inflight = false
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
	_capture_request_pending = source_mode == SourceMode.CAPTURED_SCENE
	_capture_environment_snapshot_pending = _capture_request_pending
	_cubemap_dirty = true


func _ensure_capture_environment(force_snapshot: bool = false) -> bool:
	var world := get_world_3d()
	var source_environment: Environment
	if world != null:
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
			if source_environment != null else Environment.new()
	if _capture_environment == null:
		_capture_environment = Environment.new()
	_capture_environment.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	_capture_environment.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	_capture_environment.sky = sky
	if sky != null:
		_capture_environment.background_mode = Environment.BG_SKY
	_capture_environment_id = environment_id
	_bound_capture_sky = sky
	_capture_environment_dirty = false
	_capture_environment_snapshot_pending = false
	_capture_native_config_dirty = true
	_capture_native_signature.clear()
	_last_environment_identity = _environment_identity()
	return true


func _effective_capture_sky(world: World3D, source_environment: Environment) -> Sky:
	if capture_sky != null:
		return capture_sky
	if source_environment != null:
		return source_environment.sky
	if world != null:
		var fallback := world.get_fallback_environment()
		return fallback.sky if fallback != null else null
	return null


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
		return
	if is_instance_valid(_capture_probe):
		NativeAdapter.detach_capture_output(_capture_probe)
		if _capture_probe.get_parent() != null:
			_capture_probe.get_parent().remove_child(_capture_probe)
		_capture_probe.queue_free()
	_capture_probe = null
	_capture_native_signature.clear()
	_capture_native_config_dirty = true


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
	var signature: Array = [revision, radiance_energy, _radiance_rotation()]
	if signature == _last_projected_signature:
		return
	if revision != _last_projected_revision:
		_cached_panorama = NativeAdapter.bake_world_linear_panorama(_output_sky, PANORAMA_SIZE)
		if _cached_panorama == null or _cached_panorama.is_empty():
			return
		_last_projected_revision = revision
		_projected_exposure = exposure
	_radiance_sh = CubemapAdapter.project_world_linear_panorama(
			_cached_panorama, _radiance_rotation(), radiance_energy)
	_last_projected_signature = signature


func _project_cached_panorama() -> void:
	if _cached_panorama == null or _cached_panorama.is_empty():
		_last_projected_signature.clear()
		return
	_radiance_sh = CubemapAdapter.project_world_linear_panorama(
			_cached_panorama, _radiance_rotation(), radiance_energy)
	_last_projected_signature = [
		_last_projected_revision, radiance_energy, _radiance_rotation()]


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
	_next_route_scan_msec = 0


func _on_scene_node_removed(node: Node) -> void:
	if not _provider_active or _snapshot_worlds == null or not node is Viewport:
		return
	var viewport := node as Viewport
	var target := RenderingServer.viewport_get_render_target(viewport.get_viewport_rid())
	if target.is_valid() and _registered_targets.has(target):
		NativeAdapter.clear_frp_source(target, get_instance_id())
		_registered_targets.erase(target)
	_snapshot_worlds.call("unregister_viewport", viewport, self)
	_next_route_scan_msec = 0


func _sync_viewport_routes(force_scan: bool = false) -> void:
	if not _provider_active or _snapshot_worlds == null:
		return
	var tree := get_tree()
	if tree == null:
		return
	if force_scan:
		_snapshot_worlds.call("scan", tree.root, self)
	_snapshot_worlds.call("prune")
	var world := get_world_3d()
	if world == null:
		return
	var targets: Variant = _snapshot_worlds.call("targets_for", world)
	var desired: Array[RID] = []
	if targets is Array:
		for target in targets:
			if target is RID and target.is_valid() and not desired.has(target):
				desired.append(target)
	for target in _registered_targets.duplicate():
		if not desired.has(target):
			NativeAdapter.clear_frp_source(target, get_instance_id())
			_registered_targets.erase(target)
			_last_registration_signature.clear()


func _sync_frp_sources() -> void:
	if not _provider_active or not _native_radiance_ready \
			or _native_radiance_revision < 0 or not NativeAdapter.supports_frp_registration():
		return
	var world := get_world_3d()
	if world == null:
		_clear_render_target_routes()
		return
	var targets: Variant = _snapshot_worlds.call("targets_for", world) \
			if _snapshot_worlds != null else []
	if not targets is Array:
		return
	var signature: Array = [
		_native_radiance_revision, _native_radiance_exposure,
		radiance_energy, _radiance_rotation()]
	var needs_all_targets := signature != _last_registration_signature
	var all_registered := true
	for target in targets:
		if not target is RID or not target.is_valid():
			continue
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
	# CapturedScene faces are rendered along world axes. Applying component
	# rotation again would rotate the captured scene twice; only a supplied
	# cubemap follows this node's orientation.
	if source_mode == SourceMode.CAPTURED_SCENE:
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
	var selected_resource: Resource = capture_sky \
			if source_mode == SourceMode.CAPTURED_SCENE else cubemap
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
	if source_mode == SourceMode.CAPTURED_SCENE:
		_capture_environment_dirty = true
		_mark_capture_dirty(true, true, true)
	else:
		_cubemap_dirty = true
		if source_mode == SourceMode.SPECIFIED_CUBEMAP:
			_configure_output_sky_radiance_size()
		_refresh_provider()
