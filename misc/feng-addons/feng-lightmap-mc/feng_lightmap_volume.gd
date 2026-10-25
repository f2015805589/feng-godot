@tool
class_name FengLightmapVolume
extends Node3D
## Independent surface lightmap baker. `bake()` traces actual UV2 surface points.
## This volume never reads MagicGI probes, atlases, or stencil data.

enum EnvironmentMode {
	REJECT_SCENE_ENVIRONMENT,
	BLACK_OVERRIDE,
	UNIFORM_OVERRIDE,
	CAPTURE_SCENE_SKY,
}

const SceneInputs = preload("feng_lightmap_scene_inputs.gd")
const DATA_SCRIPT = preload("res://addons/feng-lightmap-mc/feng_lightmap_data.gd")
const DISPLAY_NODE_NAME := "FengLightmapDisplay"
const EXTENSION_PATH := "res://addons/feng-lightmap-mc/feng-lightmap-mc.gdextension"
const DEFAULT_OUTPUT := "res://bake/lightmap/box_white_lightmap.res"
const REQUIRED_BACKEND_CONTRACT_VERSION := 4

@export var enabled: bool = false:
	set(value):
		enabled = value
		_refresh_display()

## Optional subtree whose fully-contained MeshInstance3D nodes receive atlases.
## Empty selects every scene node. The full scene is still traced for transport.
@export var source_root_path: NodePath
## Volume-local receiver bounds. A whole MeshInstance3D AABB must fit inside;
## partial/outside objects remain complete transport-only geometry (never clipped).
@export var bounds: AABB = AABB(Vector3(-2.35, -0.2, -2.6), Vector3(4.7, 3.4, 5.2)):
	set(value):
		bounds = value
		update_gizmos()
@export_tool_button("Bake CPU Lightmap") var bake_button: Callable = request_inspector_bake
@export_tool_button("Cancel Bake") var cancel_button: Callable = cancel_bake
@export_tool_button("Check Saved Bake Inputs") var validate_button: Callable = validate_saved_bake_inputs
@export_multiline var bake_status: String = "Not baked."
@export_multiline var bake_report_text: String = "Bounds are volume-local. A whole MeshInstance3D AABB must fit inside to receive an atlas; partial or outside objects remain complete transport-only geometry. Select this node to see the green bounds gizmo."
## Optional display-only gutter reconstruction. Zero is the raw unbiased atlas;
## positive values extend uncovered texels only and do not alter saved samples.
@export_range(0,4,1) var display_gutter_pixels: int = 1:
	set(value):
		display_gutter_pixels = clampi(value,0,4)
		if baked_data != null and baked_data.get_script() == DATA_SCRIPT:
			baked_data.set("display_gutter_pixels", display_gutter_pixels)
@export_group("Bake Settings")
@export_range(4, 2048, 1) var atlas_resolution: int = 128
## Finite spp only controls variance; no denoiser or clamp is applied.
@export_range(1, 1048576, 1) var samples_per_texel: int = 256
@export var seed: int = 1
@export_file("*.res", "*.tres") var output_resource_path: String = DEFAULT_OUTPUT
@export_range(1, 64, 1) var worker_count: int = 4
## Freeze the current rendered sky as a finite directional radiance function.
@export var environment_mode: EnvironmentMode = EnvironmentMode.CAPTURE_SCENE_SKY
@export_range(16, 4096, 1) var sky_capture_width: int = 512
@export var environment_radiance: Color = Color(0.0, 0.0, 0.0, 1.0)
## Unsupported scene inputs are rejected; environment_mode explicitly selects
## a captured sky boundary or a constant replacement.
@export var baked_data: Resource:
	set(value):
		if baked_data == value:
			return
		if baked_data != null and baked_data.changed.is_connected(_on_baked_data_changed):
			baked_data.changed.disconnect(_on_baked_data_changed)
		baked_data = value
		if baked_data != null:
			baked_data.changed.connect(_on_baked_data_changed)
		_cached_display_data = null
		if is_inside_tree():
			call_deferred("_refresh_display")

var last_bake_report: Dictionary = {}
var _inspector_bake_pending := false
var _bake_thread: Thread
var _active_estimator: RefCounted
var _pending_context: Dictionary = {}
var _progress_tick := 0
var _cached_display_data: LightmapGIData
var _cancel_requested := false
var _prepared_environment_capture: Dictionary = {}
var _capture_viewport: SubViewport


func _exit_tree() -> void:
	# The native worker never touches the scene. Cancel and join before releasing
	# its immutable snapshots when the editor closes this scene.
	if _bake_thread != null and _bake_thread.is_started():
		cancel_bake()
		_bake_thread.wait_to_finish()
	_bake_thread = null
	_active_estimator = null
	_prepared_environment_capture.clear()
	if is_instance_valid(_capture_viewport):
		_capture_viewport.queue_free()
	_capture_viewport = null


func _process(_delta: float) -> void:
	if _bake_thread == null:
		set_process(false)
		return
	if not _bake_thread.is_alive():
		var traced: Dictionary = _bake_thread.wait_to_finish()
		_bake_thread = null
		_active_estimator = null
		_inspector_bake_pending = false
		set_process(false)
		if bool(traced.get("cancelled", false)) or _cancel_requested:
			bake_status = "Cancelled: the previous saved lightmap was kept."
			bake_report_text = "No partial atlas was saved."
			last_bake_report = {"ok": false, "cancelled": true}
		else:
			_finish_bake(traced, _pending_context)
		_pending_context.clear()
		notify_property_list_changed()
	elif Time.get_ticks_msec() - _progress_tick >= 250:
		_progress_tick = Time.get_ticks_msec()
		var progress: Variant = _active_estimator.call("get_progress")
		bake_status = "Cancelling: waiting for CPU paths to stop." if _cancel_requested else "Baking: CPU paths %s" % str(progress)
		notify_property_list_changed()


func cancel_bake() -> void:
	_cancel_requested = true
	if _active_estimator != null:
		_active_estimator.call("request_cancel")


func _on_baked_data_changed() -> void:
	_cached_display_data = null
	if is_inside_tree():
		call_deferred("_refresh_display")


func _ready() -> void:
	_refresh_display()


func _refresh_display() -> void:
	if not is_inside_tree():
		return
	var display := get_node_or_null(DISPLAY_NODE_NAME) as LightmapGI
	if not enabled:
		if display != null:
			display.light_data = null
		return
	if display == null:
		display = LightmapGI.new()
		display.name = DISPLAY_NODE_NAME
		add_child(display)
	if baked_data == null and not output_resource_path.is_empty() and ResourceLoader.exists(output_resource_path):
		var loaded_data := load(output_resource_path)
		if loaded_data is Resource and loaded_data.get_script() == DATA_SCRIPT:
			baked_data = loaded_data
	if baked_data != null and baked_data.get_script() == DATA_SCRIPT:
		if int(baked_data.get("display_gutter_pixels")) != display_gutter_pixels:
			baked_data.set("display_gutter_pixels", display_gutter_pixels)
		if _cached_display_data == null:
			_cached_display_data = baked_data.call("build_lightmap_gi_data", self, display) as LightmapGIData
		if _cached_display_data == null:
			push_error("FengLightmapVolume: could not create the runtime LightmapGI display from baked_data.")
		elif display.light_data != _cached_display_data:
			display.light_data = _cached_display_data


func request_inspector_bake() -> void:
	if _inspector_bake_pending:
		return
	_inspector_bake_pending = true
	_cancel_requested = false
	bake_status = "Queued: collecting a snapshot before background CPU tracing."
	bake_report_text = "The editor remains responsive while the native estimator traces paths. Cancel Bake keeps the previous saved result."
	notify_property_list_changed()
	call_deferred("_run_inspector_bake")


func _run_inspector_bake() -> void:
	if get_tree() != null:
		await get_tree().process_frame
	if not is_inside_tree() or _cancel_requested:
		_inspector_bake_pending = false
		return
	var capture_result := await prepare_environment_capture()
	if not capture_result.get("ok", false):
		_inspector_bake_pending = false
		if capture_result.get("cancelled", false):
			bake_status = "Cancelled: the previous saved lightmap was kept."
			bake_report_text = "No partial sky snapshot or atlas was saved."
			last_bake_report = {"ok": false, "cancelled": true}
		else:
			_fail(String(capture_result.get("error", "Sky capture failed.")))
		return
	var context := _prepare_bake()
	if not context.get("ok", false):
		_inspector_bake_pending = false
		return
	bake_status = "Baking: tracing CPU paths in the background."
	notify_property_list_changed()
	await get_tree().process_frame
	if not is_inside_tree() or _cancel_requested:
		_inspector_bake_pending = false
		bake_status = "Cancelled: the previous saved lightmap was kept."
		return
	_pending_context = context
	_active_estimator = context.estimator
	_bake_thread = Thread.new()
	var start_error := _bake_thread.start(Callable(_active_estimator, "bake_scene_atlases").bind(context.inputs, context.options))
	if start_error != OK:
		_bake_thread = null
		_active_estimator = null
		_pending_context.clear()
		_inspector_bake_pending = false
		_fail("Could not start the CPU bake thread (Error %d)." % start_error)
		return
	set_process(true)


func bake() -> Dictionary:
	# CLI callers retain a synchronous API. The Inspector snapshots here on the
	# main thread, then runs only the native computation on its own worker.
	if _inspector_bake_pending or _bake_thread != null:
		return {"ok": false, "error": "A bake is already queued or running."}
	var context := _prepare_bake()
	if not context.get("ok", false):
		return context
	var traced: Dictionary = context.estimator.call("bake_scene_atlases", context.inputs, context.options)
	return _finish_bake(traced, context)


func _prepare_bake() -> Dictionary:
	# Snapshot scene data on the main thread. Only native tracing is off-thread;
	# direct script calls receive this validation state before synchronous work.
	if not _inspector_bake_pending:
		bake_status = "Validating the current scene and lightmap inputs."
		notify_property_list_changed()
	if atlas_resolution < 4 or atlas_resolution > 2048:
		return _fail("atlas_resolution must be between 4 and 2048.")
	if samples_per_texel < 1:
		return _fail("samples_per_texel must be positive.")
	if worker_count < 1 or worker_count > 64:
		return _fail("worker_count must be in [1,64].")
	if bounds.size.x <= 0.0 or bounds.size.y <= 0.0 or bounds.size.z <= 0.0:
		return _fail("bounds must have positive size on all three axes.")
	var scene_root: Node = null
	var scene_tree := get_tree()
	if scene_tree != null:
		scene_root = scene_tree.edited_scene_root if Engine.is_editor_hint() else scene_tree.current_scene
		if scene_root == null:
			scene_root = scene_tree.current_scene
	if scene_root == null:
		return _fail("The volume must belong to an open scene before Bake CPU Lightmap can run.")
	var receiver_root: Node = scene_root
	if not source_root_path.is_empty():
		receiver_root = get_node_or_null(source_root_path)
		if receiver_root == null:
			return _fail("source_root_path does not resolve from this volume: %s" % source_root_path)

	# Collect both result sets before failing so one Inspector report can list
	# environment, geometry/material, and analytic-light limitations together.
	var environment_result := _resolve_environment(scene_root)
	_prepared_environment_capture.clear()
	var collection := SceneInputs.collect(self, bounds, receiver_root, scene_root)
	var input_errors := PackedStringArray()
	if not environment_result.ok:
		input_errors.append(environment_result.error)
	if not collection.ok:
		input_errors.append(collection.error)
	if not input_errors.is_empty():
		return _fail("\n".join(input_errors))
	var vertices: PackedVector3Array = collection.vertices
	if vertices.is_empty():
		return _fail("No supported receiver triangles were found inside this FengLightmapVolume.")

	if not GDExtensionManager.is_extension_loaded(EXTENSION_PATH):
		var extension_status := GDExtensionManager.load_extension(EXTENSION_PATH)
		if extension_status != GDExtensionManager.LOAD_STATUS_OK:
			return _fail("Could not load feng-lightmap-mc GDExtension (status %d). Check the platform library and build it from native/." % extension_status)
	var estimator: Object = ClassDB.instantiate("FengLightmapMCIntegrator")
	if estimator == null:
		return _fail("FengLightmapMCIntegrator did not register after the GDExtension loaded.")
	if not estimator.has_method("get_backend_contract_version") or not estimator.has_method("bake_scene_atlases"):
		return _fail("The loaded feng-lightmap-mc DLL predates the scene transport backend. Rebuild the extension from addons/feng-lightmap-mc/native/ and restart the editor; no bake was run.")
	var backend_contract_version := int(estimator.call("get_backend_contract_version"))
	if backend_contract_version < REQUIRED_BACKEND_CONTRACT_VERSION:
		return _fail("Loaded feng-lightmap-mc backend contract v%d; contract v%d is required. Rebuild the extension and restart the editor; no bake was run." % [backend_contract_version, REQUIRED_BACKEND_CONTRACT_VERSION])
	var inputs := collection.duplicate()
	inputs.erase("mesh_nodes")
	inputs.merge(environment_result.get("inputs", {}), true)
	inputs["environment_radiance"] = environment_result.radiance
	# Persist a versioned display certificate while these exact mesh inputs are
	# frozen. Runtime checks the cheap array signature and skips topology work.
	var proof_builder := DATA_SCRIPT.new()
	var display_chart_proofs: Array[Dictionary] = []
	for receiver: MeshInstance3D in collection.mesh_nodes:
		display_chart_proofs.append(proof_builder.create_display_chart_proof(receiver.mesh))
	var options := {"mesh_count": collection.mesh_nodes.size(), "resolution": atlas_resolution,
		"samples_per_texel": samples_per_texel, "seed": seed, "worker_count": worker_count}
	return {"ok": true, "estimator": estimator, "inputs": inputs, "options": options,
		"collection": collection, "environment_result": environment_result,
		"backend_contract_version": backend_contract_version,
		"output_resource_path": output_resource_path, "bounds": bounds, "display_gutter_pixels": display_gutter_pixels,
		"scene_root": scene_root, "receiver_root": receiver_root,
		"scene_signature": SceneInputs.signature(collection, self), "display_chart_proofs":display_chart_proofs,
		"physical_light_units_enabled": bool(ProjectSettings.get_setting("rendering/lights_and_shadows/use_physical_light_units", false))}


func _finish_bake(traced: Dictionary, context: Dictionary) -> Dictionary:
	var collection: Dictionary = context.collection
	if not traced.get("ok", false):
		return _fail(_native_failure_message(traced,collection))
	var environment_result: Dictionary = context.environment_result
	var backend_contract_version: int = context.backend_contract_version
	var options: Dictionary = context.options
	var saved_output: String = context.output_resource_path
	# Snapshot relative paths on the main thread only. Deleted receivers abort
	# publication instead of attaching a valid atlas to the wrong scene nodes.
	for mesh_instance in collection.mesh_nodes:
		if not is_instance_valid(mesh_instance) or not mesh_instance.is_inside_tree():
			return _fail("A receiver was deleted or left the scene during baking; no atlas was saved.")

	if not is_instance_valid(context.scene_root) or not is_instance_valid(context.receiver_root):
		return _fail("The source scene was closed during baking; no lightmap was saved.")
	var current_collection := SceneInputs.collect(self, bounds, context.receiver_root, context.scene_root)
	if not current_collection.ok or SceneInputs.signature(current_collection, self) != context.scene_signature or bounds != context.bounds:
		return _fail("Scene geometry, materials, lights, receiver bounds, or paths changed during baking. The previous lightmap was kept; bake again for the edited scene.")
	var variance_layers: Array[PackedFloat32Array] = []
	var radiance_layers: Array[PackedFloat32Array] = []
	for layer_variant in traced.layers:
		var layer: Dictionary = layer_variant
		radiance_layers.append(layer.rgba)
		variance_layers.append(layer.variance)

	var result_data := DATA_SCRIPT.new()
	result_data.atlas_resolution = options.resolution
	result_data.samples_per_texel = options.samples_per_texel
	result_data.seed = options.seed
	result_data.surface_model = "incoming irradiance/pi; interpolated shading normals; Lambert/Burley + isotropic Smith GGX/Schlick transport; linear HDR; no denoising or clamp"
	result_data.physical_light_units_enabled = context.physical_light_units_enabled
	result_data.backend_contract_version = backend_contract_version
	result_data.scene_transport_signature = context.scene_signature
	result_data.environment_override = environment_result.description
	result_data.directional_light_count = collection.directional_lights.size()
	result_data.area_light_count = collection.area_lights.size()
	result_data.bake_worker_count = options.worker_count
	result_data.display_gutter_pixels = context.display_gutter_pixels
	result_data.display_chart_proofs = context.display_chart_proofs
	result_data.excluded_lights = collection.excluded_lights
	var mesh_relative_paths: Array[NodePath] = []
	for mesh_instance in collection.mesh_nodes:
		mesh_relative_paths.append(get_path_to(mesh_instance))
	result_data.mesh_relative_paths = mesh_relative_paths
	result_data.radiance_layers = radiance_layers
	result_data.sampled_mesh_count = collection.mesh_nodes.size()
	result_data.sampled_triangle_count = traced.triangle_count
	result_data.receiver_triangle_count = collection.receiver_triangle_count
	result_data.transport_only_mesh_count = collection.transport_only_mesh_count
	result_data.transport_only_triangle_count = collection.transport_only_triangle_count
	result_data.transport_only_reasons = collection.transport_only_reasons
	result_data.receiver_bounds_local = context.bounds
	result_data.receiver_boundary_rule = "A complete MeshInstance3D AABB must lie in the volume-local bounds and under source_root_path. Other complete scene geometry stays transport-only."
	result_data.skipped_zero_area_triangle_count = collection.skipped_zero_area_triangle_count
	result_data.emitter_triangle_count = traced.emitter_triangle_count
	result_data.covered_texel_count = traced.covered_texels
	result_data.path_count = traced.path_count
	result_data.average_path_bounces = traced.average_path_bounces
	result_data.rr_survivals = traced.rr_survivals
	result_data.luminance_variance_layers = variance_layers

	var output_directory := saved_output.get_base_dir()
	var absolute_directory := ProjectSettings.globalize_path(output_directory)
	var directory_error := DirAccess.make_dir_recursive_absolute(absolute_directory)
	if directory_error != OK and directory_error != ERR_ALREADY_EXISTS:
		return _fail("Could not create output directory %s (Error %d)." % [output_directory, directory_error])
	var save_flags := ResourceSaver.FLAG_COMPRESS if saved_output.get_extension().to_lower() == "res" else 0
	var save_error := ResourceSaver.save(result_data, saved_output, save_flags)
	if save_error != OK:
		return _fail("Could not save output resource %s (Error %d)." % [saved_output, save_error])
	baked_data = result_data
	if enabled:
		_refresh_display()
	last_bake_report = traced.duplicate(true)
	last_bake_report["ok"] = true
	last_bake_report["output_resource_path"] = saved_output
	last_bake_report["environment_override"] = environment_result.description
	last_bake_report["directional_light_count"] = collection.directional_lights.size()
	last_bake_report["area_light_count"] = collection.area_lights.size()
	last_bake_report["display_gutter_pixels"] = context.display_gutter_pixels
	last_bake_report["excluded_lights"] = collection.excluded_lights
	last_bake_report["mesh_count"] = collection.mesh_nodes.size()
	last_bake_report["receiver_triangle_count"] = collection.receiver_triangle_count
	last_bake_report["transport_only_mesh_count"] = collection.transport_only_mesh_count
	last_bake_report["transport_only_triangle_count"] = collection.transport_only_triangle_count
	last_bake_report["transport_only_reasons"] = collection.transport_only_reasons
	last_bake_report["total_triangle_count"] = traced.triangle_count
	last_bake_report["bounds_local"] = context.bounds
	last_bake_report["boundary_rule"] = "A complete MeshInstance3D AABB must lie inside bounds and under source_root_path; all other scene geometry remains transport-only."
	last_bake_report["surface_model"] = result_data.surface_model
	last_bake_report["backend_contract_version"] = backend_contract_version
	bake_status = "Succeeded: saved %s" % saved_output
	bake_report_text = _format_bake_report(last_bake_report)
	notify_property_list_changed()
	return last_bake_report


func _native_failure_message(traced: Dictionary, collection: Dictionary) -> String:
	var message := String(traced.get("error", "Native estimator failed without a diagnostic."))
	var mesh_id := int(traced.get("mesh_id",traced.get("error_mesh_id",-1)))
	var receivers: Array = collection.get("mesh_nodes",[])
	if mesh_id >= 0 and mesh_id < receivers.size() and is_instance_valid(receivers[mesh_id]):
		message += " Receiver: %s (mesh %d)." % [receivers[mesh_id].get_path(),mesh_id]
	for key in ["triangle_id","other_triangle_id","error_triangle_id","error_other_triangle_id"]:
		if not traced.has(key):
			continue
		var triangle_id := int(traced[key])
		var source := ""
		for entry: Dictionary in collection.get("triangle_sources",[]):
			if triangle_id >= int(entry.first_triangle) and triangle_id < int(entry.end_triangle):
				source = " %s surface %d" % [entry.path,int(entry.surface)]
				break
		message += " %s=%d%s." % [key,triangle_id,source]
	if traced.has("pixel"):
		message += " Atlas texel: %s." % str(traced.pixel)
	elif traced.has("texel_x") and traced.has("texel_y"):
		message += " Atlas texel: (%d,%d)." % [int(traced.texel_x),int(traced.texel_y)]
	return message


func _fail(message: String) -> Dictionary:
	last_bake_report = {"ok": false, "error": message}
	bake_status = "Failed: no new lightmap was saved."
	bake_report_text = message
	if baked_data != null:
		bake_status += " Previous bake retained."
		bake_report_text += "\nThe assigned lightmap is still the previous bake (%s); it does not represent this failed attempt." % baked_data.resource_path
	notify_property_list_changed()
	push_error("FengLightmapVolume: " + message)
	return last_bake_report


func validate_saved_bake_inputs() -> Dictionary:
	# Explicit editor action: never scan/hash scene geometry every frame or on
	# ordinary resource loading. Old bakes cannot silently certify new lighting.
	var result := {"ok": false, "error": "No saved FengLightmapData is assigned."}
	if baked_data != null and baked_data.get_script() == DATA_SCRIPT:
		var signature := String(baked_data.get("scene_transport_signature"))
		var tree := get_tree()
		var scene: Node = (tree.edited_scene_root if Engine.is_editor_hint() else tree.current_scene) if tree != null else null
		if scene == null:
			result.error = "Open the source scene before checking its bake inputs."
		elif signature.is_empty():
			result.error = "This legacy bake has no source signature; rebake to verify current geometry, materials and lighting."
		else:
			var receiver: Node = scene if source_root_path.is_empty() else get_node_or_null(source_root_path)
			if receiver == null:
				result.error = "source_root_path no longer resolves."
			else:
				var collected := SceneInputs.collect(self, bounds, receiver, scene)
				if not collected.ok:
					result.error = collected.error
				elif SceneInputs.signature(collected, self) != signature or bounds != baked_data.get("receiver_bounds_local") or bool(baked_data.get("physical_light_units_enabled")) != bool(ProjectSettings.get_setting("rendering/lights_and_shadows/use_physical_light_units", false)):
					result.error = "Saved bake is stale: scene geometry, materials, emission, lights or receiver bounds changed. Bake again to update indirect light."
				else:
					result = {"ok": true, "message": "Saved geometry/material/light inputs match. The sky remains the frozen bake-time capture; rebake after changing the sky or time of day."}
	bake_report_text = String(result.get("message", result.get("error", "")))
	bake_status = "Saved bake inputs match." if result.ok else "Saved bake needs attention."
	notify_property_list_changed()
	return result


func _format_bake_report(report: Dictionary) -> String:
	var lines := PackedStringArray()
	lines.append(String(report.get("environment_override", "")))
	lines.append("Display gutter: %d px (reconstruction only; raw estimates/variance untouched; use 0 for raw reference)." % int(report.get("display_gutter_pixels",0)))
	lines.append("Directional sources: %d; rectangular area sources: %d; full-scene occlusion retained." % [int(report.get("directional_light_count", 0)),int(report.get("area_light_count",0))])
	lines.append("Output: %s" % report.get("output_resource_path", output_resource_path))
	lines.append("Receivers: %d meshes / %d triangles; transport-only: %d meshes / %d triangles." % [
		int(report.get("mesh_count", 0)),
		int(report.get("receiver_triangle_count", 0)),
		int(report.get("transport_only_mesh_count", 0)),
		int(report.get("transport_only_triangle_count", 0)),
	])
	lines.append("Total traced triangles: %d; emitters: %d; covered texels: %d." % [
		int(report.get("total_triangle_count", report.get("triangle_count", 0))),
		int(report.get("emitter_triangle_count", 0)),
		int(report.get("covered_texels", 0)),
	])
	lines.append("Paths: %d; average bounces: %.3f; RR survivals: %d." % [
		int(report.get("path_count", 0)),
		float(report.get("average_path_bounces", 0.0)),
		int(report.get("rr_survivals", 0)),
	])
	lines.append(String(report.get("boundary_rule", "Receiver boundary: complete mesh AABBs contained by the volume; all other scene geometry remains transport-only.")))
	var reasons: PackedStringArray = report.get("transport_only_reasons", PackedStringArray())
	if not reasons.is_empty():
		lines.append("Transport-only mesh classification:")
		lines.append_array(reasons)
	return "\n".join(lines)


func _resolve_environment(scene_root: Node) -> Dictionary:
	var environments: Array[Environment] = []
	var environment_paths := PackedStringArray()
	var stack: Array[Node] = [scene_root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		var environment: Environment = null
		if node is WorldEnvironment:
			environment = (node as WorldEnvironment).environment
		elif node is Camera3D:
			environment = (node as Camera3D).environment
		if environment != null and not environments.has(environment):
			environments.append(environment)
			environment_paths.append(String(node.get_path()))
		for child in node.get_children():
			stack.append(child)
	if environment_mode == EnvironmentMode.UNIFORM_OVERRIDE:
		if not SceneInputs.color_is_nonnegative_finite(environment_radiance):
			return {"ok": false, "error": "environment_radiance must be finite and nonnegative."}
		return {"ok": true, "radiance": environment_radiance,
			"description": "Explicit uniform linear radiance %s; replaces the scene sky." % environment_radiance}
	if environment_mode == EnvironmentMode.BLACK_OVERRIDE:
		return {"ok": true, "radiance": Color.BLACK,
			"description": "Explicit black environment; replaces the scene sky."}
	if environment_mode == EnvironmentMode.REJECT_SCENE_ENVIRONMENT:
		for environment in environments:
			if _environment_uses_unmodeled_lighting(environment):
				return {"ok": false, "error": "A non-black WorldEnvironment source is present (%s). Choose CAPTURE_SCENE_SKY to freeze a linear HDR panorama, or an explicit environment override." % ", ".join(environment_paths)}
		return {"ok": true, "radiance": Color.BLACK, "description": "No scene lighting environment; black radiance."}
	if environments.is_empty():
		return {"ok": true, "radiance": Color.BLACK, "description": "No scene lighting environment; black radiance."}
	if environments.size() != 1:
		return {"ok": false, "error": "Multiple distinct WorldEnvironment/Camera3D environments exist (%s). A static lightmap cannot choose a camera-dependent sky implicitly." % ", ".join(environment_paths)}
	if sky_capture_width < 16 or sky_capture_width > 4096:
		return {"ok": false, "error": "sky_capture_width must be in [16,4096]."}
	var environment: Environment = environments[0]
	var disk_parameters := _represented_sun_disk_parameters(scene_root, environment)
	if not disk_parameters.is_empty():
		var signature := _sky_capture_signature(environment, disk_parameters)
		if _prepared_environment_capture.get("signature", "") == signature:
			return _prepared_environment_capture.result
		return {"ok": false, "requires_prepared_capture": true, "environment": environment,
			"signature": signature, "disk_parameters": disk_parameters, "source": environment_paths[0],
			"error": "The FengSky solar disk is already represented by an analytic directional source. Use the Inspector asynchronous bake, or await prepare_environment_capture() before synchronous bake(), to prepare a private disk-free sky. No disk-containing fallback was used."}
	# This API returns scene-linear radiance (bake_irradiance=false), including
	# the engine's environment energy/ambient blend and external-sky exposure
	# conversion. A tonemapped screen capture or filtered irradiance would not
	# be the same transport source.
	var width := sky_capture_width
	var height := maxi(8, width / 2)
	var image := RenderingServer.environment_bake_panorama(environment.get_rid(), false, Vector2i(width, height))
	return _panorama_result(image, environment, environment_paths[0], "Unmodified sky source; custom sky solar disks are not automatically identified or removed.")


func _panorama_result(image: Image, environment: Environment, source: String, capture_model: String) -> Dictionary:
	if image == null or image.is_empty():
		return {"ok": false, "error": "The scene sky has no ready radiance panorama. Render the scene until its sky is ready and retry; headless/dummy rendering cannot capture a shader sky. No black fallback was substituted."}
	var width := image.get_width()
	var height := image.get_height()
	var pixels := PackedColorArray()
	pixels.resize(width * height)
	for y in height:
		for x in width:
			var pixel := image.get_pixel(x, y)
			if not SceneInputs.color_is_nonnegative_finite(pixel):
				return {"ok": false, "error": "Sky capture contains negative or non-finite linear radiance at (%d,%d)." % [x,y]}
			pixels[y * width + x] = pixel
	return {"ok": true, "radiance": Color.BLACK,
		"inputs": {"environment_width": width, "environment_height": height,
			"environment_pixels": pixels,
			"environment_transform": Basis.from_euler(environment.sky_rotation).inverse()},
		"description": "Frozen %dx%d scene-linear Godot sky panorama from %s; nearest angular-cell radiance, sky rotation retained, no camera exposure. %s Static surface transport only: the source sky's radiance limits and finite capture resolution remain; analytic sunlight uses authored illuminance without spatial atmospheric attenuation or cloud shadows. Local fog and external volumetric-cloud passes are not part of this surface estimator." % [width,height,source,capture_model]}


func _represented_sun_disk_parameters(scene_root: Node, environment: Environment) -> PackedStringArray:
	var result := PackedStringArray()
	# Rely on FengSky's exact canonical shader identity check and its actual
	# bound lights. Matching merely by direction could erase an unrelated sun.
	var environments := scene_root.find_children("*", "WorldEnvironment", true, false)
	if scene_root is WorldEnvironment:
		environments.append(scene_root)
	for node: Node in environments:
		if node.get("environment") != environment or not node.has_method("_has_selected_atmosphere_sky") or not node.has_method("_resolve_sun"):
			continue
		if not bool(node.call("_has_selected_atmosphere_sky")):
			continue
		var lights: Array = [node.call("_resolve_sun", node.get_viewport().find_world_3d()), node.get("secondary_sun_light")]
		for slot in 2:
			var light := lights[slot] as DirectionalLight3D
			if light == null or light.editor_only or not light.is_visible_in_tree() or light.light_bake_mode == Light3D.BAKE_DISABLED or light.sky_mode == DirectionalLight3D.SKY_MODE_SKY_ONLY:
				continue
			var parameter := "sun_disk_color_scale" if slot == 0 else "secondary_sun_disk_color_scale"
			if not result.has(parameter):
				result.append(parameter)
	return result


func _sky_capture_signature(environment: Environment, disk_parameters: PackedStringArray) -> String:
	var snapshot: Array = [environment.get_instance_id(), sky_capture_width, disk_parameters]
	for name in ["sky_rotation", "background_energy_multiplier", "ambient_light_source", "ambient_light_color", "ambient_light_energy", "ambient_light_sky_contribution"]:
		snapshot.append(environment.get(name))
	var material := environment.sky.sky_material as ShaderMaterial
	snapshot.append(material.get_instance_id())
	snapshot.append(material.shader.get_instance_id())
	for parameter: Dictionary in material.shader.get_shader_uniform_list():
		snapshot.append(material.get_shader_parameter(parameter.name))
	return str(hash(snapshot))


func _private_capture_environment(source: Environment, disk_parameters: PackedStringArray) -> Environment:
	var copy := source.duplicate() as Environment
	var private_sky := source.sky.duplicate() as Sky
	var material := source.sky.sky_material.duplicate() as ShaderMaterial
	for parameter in disk_parameters:
		material.set_shader_parameter(parameter, Vector3.ZERO)
	private_sky.sky_material = material
	# QUALITY finishes the radiance generation in one update instead of relying
	# on an incremental sky's multi-frame filter state. Only mip 0 is captured.
	private_sky.process_mode = Sky.PROCESS_MODE_QUALITY
	copy.sky = private_sky
	return copy


func prepare_environment_capture() -> Dictionary:
	if _bake_thread != null or is_instance_valid(_capture_viewport):
		return {"ok": false, "error": "A sky capture or CPU bake is already in progress."}
	_prepared_environment_capture.clear()
	if not _inspector_bake_pending and _bake_thread == null:
		_cancel_requested = false
	if not is_inside_tree():
		return {"ok": false, "error": "The volume must be in its source scene to prepare the sky capture."}
	var tree := get_tree()
	var scene := tree.edited_scene_root if Engine.is_editor_hint() else tree.current_scene
	if scene == null:
		return {"ok": false, "error": "Open the source scene before preparing the sky capture."}
	var plan := _resolve_environment(scene)
	if not plan.get("requires_prepared_capture", false):
		return plan
	if DisplayServer.get_name() == "headless":
		return {"ok": false, "error": "A GPU renderer is required for the private disk-free sky snapshot; headless mode cannot prepare it."}
	bake_status = "Preparing: private sky capture without duplicated analytic sun disks."
	notify_property_list_changed()
	var private_environment := _private_capture_environment(plan.environment, plan.disk_parameters)
	var viewport := SubViewport.new()
	_capture_viewport = viewport
	viewport.size = Vector2i(16, 16)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	var world := WorldEnvironment.new()
	world.environment = private_environment
	viewport.add_child(world)
	var camera := Camera3D.new()
	viewport.add_child(camera)
	var source_camera := get_viewport().get_camera_3d()
	camera.global_position = source_camera.global_position if source_camera != null else global_position
	camera.current = true
	var image: Image
	for frame in 8:
		await tree.process_frame
		if not is_inside_tree() or _cancel_requested or not is_instance_valid(viewport):
			break
		await RenderingServer.frame_post_draw
		# The first post-draw can correspond to a frame queued before creation.
		if frame < 2:
			continue
		image = RenderingServer.environment_bake_panorama(private_environment.get_rid(), false, Vector2i(sky_capture_width, maxi(8, sky_capture_width / 2)))
		if image != null and not image.is_empty():
			break
	if is_instance_valid(viewport):
		if viewport.get_parent() == self:
			remove_child(viewport)
		viewport.queue_free()
	_capture_viewport = null
	if not is_inside_tree() or _cancel_requested:
		return {"ok": false, "cancelled": true, "error": "Private sky capture cancelled; the previous bake was retained."}
	if _sky_capture_signature(plan.environment, plan.disk_parameters) != plan.signature:
		return {"ok": false, "error": "The sky changed while preparing its private snapshot. Retry for a consistent frozen source."}
	var result := _panorama_result(image, private_environment, plan.source, "Private FengSky capture: removed only analytic-source disk terms (%s), preserving atmospheric scattering and all unrepresented disks; authored scene resources were not changed." % ", ".join(plan.disk_parameters))
	if result.ok:
		_prepared_environment_capture = {"signature": plan.signature, "result": result}
	return result


func _environment_uses_unmodeled_lighting(environment: Environment) -> bool:
	var has_sky := environment.sky != null or environment.background_mode == Environment.BG_SKY
	var has_color_background := environment.background_mode == Environment.BG_COLOR or environment.background_mode == Environment.BG_CLEAR_COLOR
	var has_non_color_background := not has_color_background
	var has_background_color := has_color_background and not environment.background_color.is_equal_approx(Color.BLACK) and environment.background_energy_multiplier > 0.0
	var has_ambient_color := environment.ambient_light_source == Environment.AMBIENT_SOURCE_COLOR and environment.ambient_light_energy > 0.0 and not environment.ambient_light_color.is_equal_approx(Color.BLACK)
	var has_ambient_sky := environment.ambient_light_source == Environment.AMBIENT_SOURCE_SKY and environment.ambient_light_energy > 0.0
	return has_sky or has_non_color_background or has_background_color or has_ambient_color or has_ambient_sky
