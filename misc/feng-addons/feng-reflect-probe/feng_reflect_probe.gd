@tool
@icon("res://addons/feng-reflect-probe/icons/FengReflectProbe.svg")
class_name FengReflectProbe
extends Node3D
## Standalone box-projected reflection volume. It owns its capture viewport and does
## not create or configure a Godot ReflectionProbe or use the native reflection atlas.

signal capture_completed(generation: int)
signal capture_failed(message: String)
signal bake_completed(data: FengReflectProbeData)

enum SourceMode { SCENE_CAPTURE, EXTERNAL_CUBEMAP }
enum UpdateMode { ON_READY, REALTIME, MANUAL }

const Runtime = preload("rendering/feng_reflect_probe_runtime.gd")
const DataScript = preload("feng_reflect_probe_data.gd")
const SnapshotWorlds = preload("res://addons/feng-render-pipeline/passes/snapshot_worlds.gd")
const WorldCompositor = preload("res://addons/feng-render-pipeline/world_compositor.gd")
const RendererScript = preload("res://addons/feng-render-pipeline/renderer.gd")
const CompositorScript = preload("res://addons/feng-render-pipeline/compositor.gd")
const PassBase = preload("res://addons/feng-render-pipeline/passes/pass_base.gd")
const BuiltinPass = preload("res://addons/feng-render-pipeline/passes/builtin_pass.gd")
const NativeSpec = preload("res://addons/feng-render-pipeline/pipeline/native_spec.gd")
const CaptureContextPass = preload("passes/reflection_capture_context_pass.gd")
const CapturePass = preload("passes/feng_reflect_probe_capture_pass.gd")
const CUBE_FORWARDS := [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 1, 0),
		Vector3(0, -1, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)]
const CUBE_UPS := [Vector3(0, -1, 0), Vector3(0, -1, 0), Vector3(0, 0, -1),
		Vector3(0, 0, 1), Vector3(0, -1, 0), Vector3(0, -1, 0)]

## Disabled probes are removed from the current render-target snapshots immediately.
@export var enabled := true:
	set(value):
		if enabled == value:
			return
		enabled = value
		_metadata_signature.clear()
		if not enabled:
			_cancel_capture()
			Runtime.remove_external_source(_owner_id)
			_published_external_revision = -1
			if _owner_id > 0:
				Runtime.remove_probe_targets(_registered_targets, _owner_id)
			_registered_targets.clear()
		else:
			if source_mode == SourceMode.EXTERNAL_CUBEMAP:
				_source_revision += 1
				_published_external_revision = -1
			_refresh_probe_routes()
			if source_mode == SourceMode.SCENE_CAPTURE and update_mode != UpdateMode.MANUAL \
					and (not Engine.is_editor_hint() or capture_in_editor):
				request_update()
		_mark_gizmo_dirty()

@export var source_mode: SourceMode = SourceMode.SCENE_CAPTURE:
	set(value):
		if source_mode == value:
			return
		if _capture_active:
			_cancel_capture()
		source_mode = value
		if source_mode != SourceMode.EXTERNAL_CUBEMAP:
			Runtime.remove_external_source(_owner_id)
			_published_external_revision = -1
		_source_revision += 1
		_metadata_signature = {}
		if is_inside_tree():
			_refresh_probe_routes()
			if source_mode == SourceMode.SCENE_CAPTURE:
				_request_automatic_scene_capture()
		_mark_gizmo_dirty()
@export var update_mode: UpdateMode = UpdateMode.ON_READY:
	set(value):
		if update_mode == value:
			return
		update_mode = value
		if value == UpdateMode.REALTIME:
			_next_realtime_capture_msec = 0
		_initial_capture_requested = false
		_mark_gizmo_dirty()
		if value != UpdateMode.MANUAL and is_inside_tree() and source_mode == SourceMode.SCENE_CAPTURE:
			_request_automatic_scene_capture()
@export var probe_data: FengReflectProbeData:
	set(value):
		if probe_data == value:
			return
		_disconnect_data()
		probe_data = value
		_connect_data()
		_source_revision += 1
		_published_external_revision = -1
		_metadata_signature = {}
		if is_inside_tree():
			if source_mode == SourceMode.SCENE_CAPTURE:
				request_update()
			else:
				_refresh_probe_routes()
		_mark_gizmo_dirty()
@export var box_size := Vector3(10.0, 10.0, 10.0):
	set(value):
		var next := Vector3(maxf(absf(value.x), 0.01), maxf(absf(value.y), 0.01), maxf(absf(value.z), 0.01))
		if box_size == next:
			return
		box_size = next
		_mark_metadata_dirty()
@export_range(0.0, 20.0, 0.01, "or_greater", "suffix:m") var blend_distance := 1.0:
	set(value):
		var next := maxf(value, 0.0)
		if blend_distance == next:
			return
		blend_distance = next
		_mark_metadata_dirty()
@export_range(-100000, 100000, 1) var priority := 0:
	set(value):
		if priority == value:
			return
		priority = value
		_mark_metadata_dirty()
@export_range(0.0, 16.0, 0.01, "or_greater") var intensity := 1.0:
	set(value):
		var next := maxf(value, 0.0)
		if intensity == next:
			return
		intensity = next
		_mark_metadata_dirty()
@export_range(16, 2048, 16, "suffix:px") var capture_resolution := 128:
	set(value):
		var next := clampi(value, 16, 2048)
		if capture_resolution == next:
			return
		capture_resolution = next
		if probe_data != null:
			probe_data.capture_resolution = next
		_mark_metadata_dirty()
		if is_inside_tree() and source_mode == SourceMode.SCENE_CAPTURE:
			_request_automatic_scene_capture(true)
@export var capture_position_offset := Vector3.ZERO:
	set(value):
		if capture_position_offset == value:
			return
		capture_position_offset = value
		if is_inside_tree() and source_mode == SourceMode.SCENE_CAPTURE:
			_request_automatic_scene_capture(true)
		_mark_metadata_dirty()
@export_range(1, 8, 1) var prefilter_mips_per_frame := 2:
	set(value):
		var next := clampi(value, 1, 8)
		if prefilter_mips_per_frame == next:
			return
		prefilter_mips_per_frame = next
		_mark_metadata_dirty()
@export_range(0.0, 120.0, 0.05, "or_greater", "suffix:s") var realtime_interval := 1.0:
	set(value):
		var next := maxf(value, 0.0)
		if realtime_interval == next:
			return
		realtime_interval = next
		if update_mode == UpdateMode.REALTIME:
			_next_realtime_capture_msec = 0
		_mark_gizmo_dirty()
@export var capture_in_editor := false

var _owner_id := 0
var _source_revision := 1
var _world_id := 0
var _capture_viewport: SubViewport
var _capture_camera: Camera3D
var _capture_compositor: Compositor
var _capture_renderer: Resource
var _capture_copy_pass: FengReflectProbeCapturePass
var _capture_target := RID()
var _registered_targets: Array[RID] = []
var _capture_active := false
var _task_pending := false
var _capture_batch := 0
var _capture_step := 0
var _task_started_msec := 0
var _capture_phase: StringName = &"face"
var _capture_face := 0
var _capture_mip := 0
var _batch_capture_origin := Vector3.ZERO
var _batch_capture_basis := Basis.IDENTITY
var _batch_probe_snapshot: Dictionary = {}
var _bake_requested := false
var _initial_capture_requested := false
var _next_realtime_capture_msec := 0
var _published_external_revision := -1
var _metadata_signature: Dictionary = {}
var _last_status_error := ""
var _connected_radiance: Cubemap

func _init() -> void:
	if probe_data == null:
		probe_data = DataScript.new()

func _ready() -> void:
	_owner_id = get_instance_id()
	_connect_data()
	if get_viewport() != null:
		SnapshotWorlds.register_viewport(get_viewport(), self)
	_world_id = get_world_3d().get_instance_id() if get_world_3d() != null else 0
	_refresh_probe_routes()
	if not Engine.is_editor_hint() or capture_in_editor:
		if source_mode == SourceMode.SCENE_CAPTURE:
			_ensure_capture_rig()
		if update_mode == UpdateMode.ON_READY:
			request_update()
		elif update_mode == UpdateMode.REALTIME:
			request_update()
	set_process(true)

func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if source_mode == SourceMode.EXTERNAL_CUBEMAP \
			and (probe_data == null or not probe_data.is_valid()):
		warnings.append("External Cubemap mode needs a valid HDR Cubemap in Probe Data.")
	elif source_mode == SourceMode.EXTERNAL_CUBEMAP \
			and probe_data.radiance.get_width() != probe_data.radiance.get_height():
		warnings.append("External Cubemap mode needs square source faces.")
	return warnings

func _exit_tree() -> void:
	_cancel_capture()
	if _owner_id > 0:
		Runtime.remove_probe_targets(_registered_targets, _owner_id)
		Runtime.remove_external_source(_owner_id)
		_published_external_revision = -1
		Runtime.remove_completed_capture(_owner_id)
		Runtime.remove_capture_owner(_owner_id)
	_remove_capture_rig()
	SnapshotWorlds.unregister_owner(self)
	_disconnect_data()
	_capture_active = false
	_task_pending = false

func _process(_delta: float) -> void:
	if not is_inside_tree() or not enabled:
		return
	var world := get_world_3d()
	var next_world_id := world.get_instance_id() if world != null else 0
	if next_world_id != _world_id:
		_world_id = next_world_id
		_metadata_signature = {}
		if _capture_active:
			_cancel_capture()
		if _capture_viewport != null and is_instance_valid(_capture_viewport):
			_capture_viewport.world_3d = world
		_refresh_probe_routes()
		if update_mode != UpdateMode.MANUAL:
			_request_automatic_scene_capture()
	_poll_capture_step()
	_poll_bake_payload()
	_refresh_probe_routes()
	if Engine.is_editor_hint() and not capture_in_editor:
		return
	if _capture_active:
		return
	if update_mode == UpdateMode.REALTIME \
			and Time.get_ticks_msec() >= _next_realtime_capture_msec:
		request_update()

## Captures the scene or requests a fresh external source snapshot. The last
## complete cubemap stays active until its replacement and filtered mips are ready.
func request_update() -> void:
	if not enabled or not is_inside_tree():
		return
	if source_mode == SourceMode.EXTERNAL_CUBEMAP:
		_source_revision += 1
		_published_external_revision = -1
		_metadata_signature.clear()
		_next_realtime_capture_msec = Time.get_ticks_msec() + roundi(realtime_interval * 1000.0)
		_refresh_probe_routes()
		return
	if source_mode != SourceMode.SCENE_CAPTURE:
		return
	if not _ensure_capture_rig():
		capture_failed.emit("FengReflectProbe could not create a private FRP capture schedule.")
		return
	if _capture_active:
		return
	_capture_batch += 1
	_capture_step = 0
	_capture_phase = &"face"
	_capture_face = 0
	_capture_mip = 0
	_batch_probe_snapshot = _make_probe_snapshot()
	_batch_capture_origin = _batch_probe_snapshot.get("capture_position", global_position)
	_batch_capture_basis = _batch_probe_snapshot.get("source_basis", global_transform.basis.orthonormalized())
	_capture_active = true
	_task_pending = false
	_initial_capture_requested = true
	_last_status_error = ""
	Runtime.publish_capture_status(_owner_id, {"batch_id": _capture_batch,
			"completed_step": -1, "complete": false, "error": ""})
	_schedule_capture_step()

## Captures the scene source and also requests async RGBAH readback for a portable
## Cubemap resource. Call save_bake(path) after bake_completed to persist it.
func request_bake() -> void:
	if not enabled:
		push_warning("FengReflectProbe: enable the probe before requesting a bake.")
		return
	if source_mode != SourceMode.SCENE_CAPTURE:
		push_warning("FengReflectProbe: bake is available for scene captures; external Cubemaps are already portable resources.")
		return
	if _capture_active:
		_cancel_capture()
	_bake_requested = true
	request_update()

func save_bake(path: String) -> Error:
	if probe_data == null or probe_data.radiance == null or path.strip_edges().is_empty():
		return ERR_INVALID_PARAMETER
	return ResourceSaver.save(probe_data, path)

func is_capturing() -> bool:
	return _capture_active

func get_capture_status() -> Dictionary:
	return Runtime.capture_status_for_owner(_owner_id)

func _schedule_capture_step() -> void:
	if not enabled or not _capture_active:
		return
	if _capture_viewport == null or not is_instance_valid(_capture_viewport):
		_fail_capture("The private capture viewport is no longer available.")
		return
	_capture_target = RenderingServer.viewport_get_render_target(_capture_viewport.get_viewport_rid())
	if not _capture_target.is_valid():
		_fail_capture("The private capture viewport has no render target.")
		return
	if _capture_phase == &"face":
		_set_capture_camera(_capture_face)
	var targets := _probe_targets()
	if not targets.has(_capture_target):
		targets.append(_capture_target)
	var snapshot := {
		"active": true,
		"owner_id": _owner_id,
		"batch_id": _capture_batch,
		"step": _capture_step,
		"phase": String(_capture_phase),
		"face_index": _capture_face,
		"mip_index": _capture_mip,
		"mips_per_step": prefilter_mips_per_frame,
		"resolution": _effective_resolution(),
		"origin_world": _batch_capture_origin,
		"source_revision": _source_revision + _capture_batch,
		"probe_targets": targets,
		"probe_snapshot": _batch_probe_snapshot.duplicate(true),
		"bake_requested": _bake_requested,
	}
	Runtime.publish_capture_target(_capture_target, snapshot)
	Runtime.publish_capture_status(_owner_id, {"batch_id": _capture_batch,
			"completed_step": _capture_step - 1, "phase": String(_capture_phase),
			"face_index": _capture_face, "mip_index": _capture_mip,
			"complete": false, "error": ""})
	_capture_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_task_pending = true
	_task_started_msec = Time.get_ticks_msec()

func _poll_capture_step() -> void:
	if not _capture_active or not _task_pending:
		return
	if Time.get_ticks_msec() - _task_started_msec > 15000:
		var message := "The private reflection capture pass did not complete its scheduled frame."
		Runtime.complete_capture_step(_owner_id, _capture_batch, _capture_step, {"error": message})
		_last_status_error = message
		_finish_capture(false)
		capture_failed.emit(message)
		return
	var status := Runtime.capture_status_for_owner(_owner_id)
	if int(status.get("batch_id", -1)) != _capture_batch \
			or int(status.get("completed_step", -1)) != _capture_step:
		return
	_task_pending = false
	var error := String(status.get("error", ""))
	if not error.is_empty():
		_last_status_error = error
		_finish_capture(false)
		capture_failed.emit(error)
		return
	if bool(status.get("complete", false)):
		_finish_capture(true)
		capture_completed.emit(_capture_batch)
		return
	if _capture_phase == &"face":
		if _capture_face < 5:
			_capture_face += 1
		else:
			_capture_phase = &"prefilter"
			_capture_mip = int(status.get("next_mip", 0))
	else:
		_capture_mip = int(status.get("next_mip", _capture_mip + prefilter_mips_per_frame))
	_capture_step += 1
	_schedule_capture_step()

func _finish_capture(success: bool) -> void:
	_capture_active = false
	_task_pending = false
	if _capture_target.is_valid():
		Runtime.remove_capture_target(_capture_target, _owner_id)
	if _capture_viewport != null and is_instance_valid(_capture_viewport):
		_capture_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if success:
		_bake_requested = false
		if update_mode == UpdateMode.REALTIME:
			_next_realtime_capture_msec = Time.get_ticks_msec() + int(realtime_interval * 1000.0)

func _fail_capture(message: String) -> void:
	_last_status_error = message
	Runtime.publish_capture_status(_owner_id, {"batch_id": _capture_batch,
			"completed_step": _capture_step, "complete": false, "error": message})
	_finish_capture(false)
	capture_failed.emit(message)

func _poll_bake_payload() -> void:
	if not enabled:
		return
	var payload := Runtime.take_bake_payload(_owner_id)
	if payload.is_empty() or int(payload.get("batch_id", -1)) != _capture_batch:
		return
	var faces_value: Variant = payload.get("faces", [])
	if not faces_value is Array or faces_value.size() != 6:
		return
	var resolution := _effective_resolution()
	var images: Array[Image] = []
	for bytes_value in faces_value:
		if not bytes_value is PackedByteArray or bytes_value.size() != resolution * resolution * 8:
			return
		var image := Image.create_from_data(resolution, resolution, false, Image.FORMAT_RGBAH, bytes_value)
		if image.is_empty():
			return
		images.append(image)
	var cube := Cubemap.new()
	if cube.create_from_images(images) != OK:
		return
	if probe_data == null:
		probe_data = DataScript.new()
	probe_data.radiance = cube
	probe_data.capture_position = _batch_capture_origin
	probe_data.capture_basis = _batch_capture_basis
	probe_data.capture_resolution = resolution
	probe_data.capture_generation += 1
	probe_data.source_description = "FengReflectProbe scene bake"
	_source_revision += 1
	_published_external_revision = -1
	_metadata_signature = {}
	bake_completed.emit(probe_data)

func _ensure_capture_rig() -> bool:
	if _capture_viewport != null and is_instance_valid(_capture_viewport):
		_capture_viewport.size = Vector2i(_effective_resolution(), _effective_resolution())
		return true
	var world := get_world_3d()
	if world == null:
		return false
	var renderer := _clone_source_renderer() as FengRenderer
	if renderer == null:
		return false
	var capture_context = CaptureContextPass.new()
	var capture_pass = CapturePass.new()
	var cloned_passes: Array[FengPass] = []
	cloned_passes.append(capture_context)
	var copy_inserted := false
	var source_passes: Array[FengPass] = renderer.passes
	for entry in source_passes:
		if _skip_in_capture(entry):
			continue
		cloned_passes.append(entry)
		if not copy_inserted and _native_id(entry) == NativeSpec.PASS_TRANSPARENT:
			cloned_passes.append(capture_pass)
			copy_inserted = true
	if not copy_inserted:
		var insert_index := cloned_passes.size()
		for index in cloned_passes.size():
			if _native_id(cloned_passes[index]) == NativeSpec.PASS_POST_PROCESS:
				insert_index = index
				break
		cloned_passes.insert(insert_index, capture_pass)
	if cloned_passes.is_empty() or cloned_passes[0] != capture_context \
			or not cloned_passes.has(capture_pass):
		push_warning("FengReflectProbe: the private capture plan is missing its metadata or HDR copy pass.")
		return false
	renderer.passes = cloned_passes
	if not renderer.has_method("set_reflection_capture_mode"):
		push_warning("FengReflectProbe: the installed FengRenderer lacks set_reflection_capture_mode(); update the render-pipeline addon.")
		return false
	renderer.call("set_reflection_capture_mode", true)
	var compositor = CompositorScript.new()
	compositor.set("renderer", renderer)
	var viewport := SubViewport.new()
	viewport.name = "_FengReflectProbeCapture"
	viewport.size = Vector2i(_effective_resolution(), _effective_resolution())
	viewport.own_world_3d = false
	viewport.world_3d = world
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	viewport.msaa_3d = Viewport.MSAA_DISABLED
	viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	viewport.use_taa = false
	viewport.scaling_3d_scale = 1.0
	viewport.transparent_bg = false
	add_child(viewport, false, Node.INTERNAL_MODE_BACK)
	var camera := Camera3D.new()
	camera.name = "_FengReflectProbeCaptureCamera"
	camera.fov = 90.0
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.near = 0.05
	camera.far = 1000.0
	camera.cull_mask = _source_camera_cull_mask()
	var attributes := CameraAttributesPractical.new()
	attributes.auto_exposure_enabled = false
	attributes.exposure_multiplier = 1.0
	camera.attributes = attributes
	camera.compositor = compositor
	viewport.add_child(camera, false, Node.INTERNAL_MODE_BACK)
	camera.current = true
	_capture_viewport = viewport
	_capture_camera = camera
	_capture_compositor = compositor
	_capture_renderer = renderer
	_capture_copy_pass = capture_pass
	_capture_target = RenderingServer.viewport_get_render_target(viewport.get_viewport_rid())
	SnapshotWorlds.register_viewport(viewport, self)
	return _capture_target.is_valid()

func _clone_source_renderer() -> Resource:
	var main_viewport := get_viewport()
	var source_camera := main_viewport.get_camera_3d() if main_viewport != null else null
	var active := WorldCompositor.active_compositor(main_viewport, source_camera)
	var renderer: Resource
	if active != null and active.get_script() != null \
			and active.get_script().resource_path == "res://addons/feng-render-pipeline/compositor.gd":
		renderer = active.get("renderer")
	if renderer == null:
		var project_pipeline := load("res://addons/feng-render-pipeline/project_pipeline.gd")
		if project_pipeline is Script and project_pipeline.has_method("resolve"):
			var project_compositor = project_pipeline.call("resolve")
			if project_compositor != null and project_compositor.get_script() != null \
					and project_compositor.get_script().resource_path == "res://addons/feng-render-pipeline/compositor.gd":
				renderer = project_compositor.get("renderer")
	if renderer == null:
		renderer = RendererScript.new()
	if renderer.get_script() == null \
			or renderer.get_script().resource_path != "res://addons/feng-render-pipeline/renderer.gd":
		push_warning("FengReflectProbe: active compositor is not a FengRenderer; using FRP's default capture schedule.")
		renderer = RendererScript.new()
	var copy: Resource = renderer.duplicate(true)
	return copy

func _skip_in_capture(entry: Variant) -> bool:
	if entry == null:
		return true
	if _native_id(entry) == NativeSpec.PASS_TEMPORAL_AA:
		return true
	if entry is PassBase and entry.provides_native_ids.has(NativeSpec.PASS_TEMPORAL_AA):
		return true
	var source := _parameter_source(entry)
	for candidate in [entry, source]:
		if candidate == null:
			continue
		var stable_id := StringName(candidate.get("stable_id"))
		if stable_id == &"library:eye_adaptation":
			return true
		if candidate.has_method("get_indirect_gi_kind") \
				and StringName(candidate.call("get_indirect_gi_kind")) == &"rt_gi":
			return true
		if candidate.has_method("get_reflection_source_kind"):
			var kind := StringName(candidate.call("get_reflection_source_kind"))
			if kind != &"":
				return true
		var script := candidate.get_script() as Script
		if script != null and script.resource_path.ends_with("/passes/eye_adaptation_pass.gd"):
			return true
	return false

func _parameter_source(entry: Variant) -> Variant:
	var source: Variant = entry
	var seen := {}
	for _iteration in 8:
		if source == null or not is_instance_valid(source) or not source.has_method("get_parameter_source"):
			break
		var id: int = source.get_instance_id()
		if seen.has(id):
			break
		seen[id] = true
		var next: Variant = source.call("get_parameter_source")
		if next == null or next == source:
			break
		source = next
	return source

func _native_id(entry: Variant) -> int:
	if entry == null:
		return -1
	if entry is BuiltinPass:
		return int(entry.get("native_id"))
	return -1

func _set_capture_camera(face: int) -> void:
	if _capture_camera == null or not is_instance_valid(_capture_camera):
		return
	var local_forward: Vector3 = CUBE_FORWARDS[face]
	var local_up: Vector3 = CUBE_UPS[face]
	var local_right := local_forward.cross(local_up).normalized()
	var face_basis := Basis(local_right, local_up, -local_forward)
	var world_basis := _batch_capture_basis.orthonormalized() * face_basis
	_capture_camera.transform = Transform3D(world_basis, _batch_capture_origin)
	_capture_camera.cull_mask = _source_camera_cull_mask()

func _source_camera_cull_mask() -> int:
	var viewport := get_viewport()
	var camera := viewport.get_camera_3d() if viewport != null else null
	return camera.cull_mask if camera != null else 0xffffffff

func _effective_resolution() -> int:
	var value := clampi(capture_resolution, 16, 2048)
	var exponent := roundi(log(float(value)) / log(2.0))
	return clampi(1 << exponent, 16, 2048)

func _make_probe_snapshot() -> Dictionary:
	var rotation := global_transform.basis.orthonormalized()
	var scale := global_transform.basis.get_scale().abs()
	var local_to_world := Transform3D(rotation, global_transform.origin)
	var size := Vector3(box_size.x * scale.x, box_size.y * scale.y, box_size.z * scale.z)
	var origin := global_transform.origin + rotation * capture_position_offset
	var source_basis := rotation
	if source_mode == SourceMode.EXTERNAL_CUBEMAP and probe_data != null:
		origin = probe_data.capture_position
		source_basis = probe_data.capture_basis.orthonormalized()
	return {
		"owner_id": _owner_id,
		"source_mode": "external_cubemap" if source_mode == SourceMode.EXTERNAL_CUBEMAP else "scene_capture",
		"priority": priority,
		"local_to_world": local_to_world,
		"size": size,
		"blend_distance": blend_distance,
		"intensity": intensity,
		"capture_position": origin,
		"source_basis": source_basis,
		"source_revision": _source_revision,
		"prefilter_mips_per_frame": prefilter_mips_per_frame,
	}

func _refresh_probe_routes() -> void:
	if _owner_id <= 0:
		return
	if not enabled:
		Runtime.remove_probe_targets(_registered_targets, _owner_id)
		Runtime.remove_external_source(_owner_id)
		_published_external_revision = -1
		_registered_targets.clear()
		_metadata_signature.clear()
		return
	var world := get_world_3d()
	if world == null:
		Runtime.remove_probe_targets(_registered_targets, _owner_id)
		Runtime.remove_external_source(_owner_id)
		_published_external_revision = -1
		_registered_targets.clear()
		_metadata_signature.clear()
		return
	var targets := _probe_targets()
	var removed: Array[RID] = []
	for old_target in _registered_targets:
		if not targets.has(old_target):
			removed.append(old_target)
	if not removed.is_empty():
		Runtime.remove_probe_targets(removed, _owner_id)
	_registered_targets = targets
	var metadata := _make_probe_snapshot()
	if source_mode == SourceMode.EXTERNAL_CUBEMAP:
		var source_size := 0
		if _published_external_revision != _source_revision:
			var packet := _make_external_source_packet()
			if not packet.is_empty() and Runtime.publish_external_source(_owner_id, packet):
				source_size = int(packet.get("size", 0))
			else:
				Runtime.remove_external_source(_owner_id)
			_published_external_revision = _source_revision
		else:
			var packet := Runtime.external_source_for_owner(_owner_id)
			source_size = int(packet.get("size", 0))
		metadata["source_size"] = source_size
		metadata["source_revision"] = _source_revision
		metadata["radiance_rid"] = RID()
	else:
		# The source position/orientation belongs to the last complete scene cube.
		# Leave those values and its RID intact while a new capture is in flight.
		metadata.erase("capture_position")
		metadata.erase("source_basis")
		metadata.erase("source_revision")
		metadata.erase("source_faces")
		metadata.erase("source_size")
	if targets != _metadata_signature.get("targets", []) or metadata != _metadata_signature.get("metadata", {}):
		if not targets.is_empty():
			Runtime.update_probe_targets(targets, _owner_id, metadata)
		_metadata_signature = {"targets": targets.duplicate(), "metadata": metadata.duplicate(true)}

func _probe_targets() -> Array[RID]:
	var world := get_world_3d()
	if world == null:
		return []
	return SnapshotWorlds.targets_for(world).duplicate()

func _make_external_source_packet() -> Dictionary:
	if probe_data == null or not probe_data.is_valid():
		return {}
	var source: Cubemap = probe_data.radiance
	var width := source.get_width()
	var height := source.get_height()
	var source_rid := source.get_rid()
	if width <= 0 or width != height or not source_rid.is_valid():
		return {}
	var size := clampi(width, 16, 256)
	var lease := Runtime.create_external_source_lease(source)
	if lease == null:
		return {}
	return {
		"revision": _source_revision,
		"size": size,
		"source_width": width,
		"source_height": height,
		"source_rid": source_rid,
		"capture_position": probe_data.capture_position,
		"source_basis": probe_data.capture_basis.orthonormalized(),
		"source_lease": lease,
	}

func _connect_data() -> void:
	if probe_data == null:
		probe_data = DataScript.new()
	if not probe_data.changed.is_connected(_on_data_changed):
		probe_data.changed.connect(_on_data_changed)
	_bind_radiance_signal()

func _disconnect_data() -> void:
	if probe_data != null and is_instance_valid(probe_data) \
			and probe_data.changed.is_connected(_on_data_changed):
		probe_data.changed.disconnect(_on_data_changed)
	if is_instance_valid(_connected_radiance) \
			and _connected_radiance.changed.is_connected(_on_radiance_changed):
		_connected_radiance.changed.disconnect(_on_radiance_changed)
	_connected_radiance = null

func _on_data_changed() -> void:
	var radiance_changed := _bind_radiance_signal()
	if source_mode == SourceMode.EXTERNAL_CUBEMAP or radiance_changed:
		_source_revision += 1
		_published_external_revision = -1
	_metadata_signature = {}
	if is_inside_tree() and source_mode == SourceMode.EXTERNAL_CUBEMAP:
		_refresh_probe_routes()
	else:
		_mark_gizmo_dirty()

func _bind_radiance_signal() -> bool:
	var next: Cubemap = probe_data.radiance if probe_data != null else null
	if _connected_radiance == next:
		return false
	if is_instance_valid(_connected_radiance) \
			and _connected_radiance.changed.is_connected(_on_radiance_changed):
		_connected_radiance.changed.disconnect(_on_radiance_changed)
	_connected_radiance = next
	if is_instance_valid(_connected_radiance) \
			and not _connected_radiance.changed.is_connected(_on_radiance_changed):
		_connected_radiance.changed.connect(_on_radiance_changed)
	return true

func _on_radiance_changed() -> void:
	_source_revision += 1
	_published_external_revision = -1
	_metadata_signature.clear()
	if is_inside_tree() and source_mode == SourceMode.EXTERNAL_CUBEMAP:
		_refresh_probe_routes()
	else:
		_mark_gizmo_dirty()

func _mark_metadata_dirty() -> void:
	_metadata_signature.clear()
	_mark_gizmo_dirty()
	if is_inside_tree() and enabled:
		_refresh_probe_routes()

func _request_automatic_scene_capture(restart_active: bool = false) -> void:
	if restart_active and _capture_active:
		_cancel_capture()
	if not enabled or not is_inside_tree() or source_mode != SourceMode.SCENE_CAPTURE \
			or update_mode == UpdateMode.MANUAL \
			or (Engine.is_editor_hint() and not capture_in_editor):
		return
	request_update()

func _mark_gizmo_dirty() -> void:
	if Engine.is_editor_hint() and is_inside_tree():
		update_gizmos()
		update_configuration_warnings()

func _cancel_capture() -> void:
	_capture_active = false
	_task_pending = false
	_capture_batch += 1 # Invalidates any already queued RD work or async bake callback.
	_bake_requested = false
	_batch_probe_snapshot.clear()
	if _capture_target.is_valid():
		Runtime.remove_capture_target(_capture_target, _owner_id)
	if _capture_viewport != null and is_instance_valid(_capture_viewport):
		_capture_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if _owner_id > 0:
		Runtime.remove_capture_owner(_owner_id)

func _remove_capture_rig() -> void:
	if _capture_target.is_valid():
		Runtime.remove_capture_target(_capture_target, _owner_id)
	if _capture_viewport != null and is_instance_valid(_capture_viewport):
		_capture_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		SnapshotWorlds.unregister_viewport(_capture_viewport, self)
		if _capture_camera != null and is_instance_valid(_capture_camera):
			_capture_camera.compositor = null
		_capture_viewport.queue_free()
	_capture_viewport = null
	_capture_camera = null
	_capture_compositor = null
	_capture_renderer = null
	_capture_copy_pass = null
	_capture_target = RID()
