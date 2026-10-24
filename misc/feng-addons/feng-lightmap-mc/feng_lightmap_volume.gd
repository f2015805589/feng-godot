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
	var collection := _collect_scene(receiver_root, scene_root)
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
	var proof_builder: Resource = DATA_SCRIPT.new()
	var display_chart_proofs: Array[Dictionary] = []
	for receiver: MeshInstance3D in collection.mesh_nodes:
		display_chart_proofs.append(proof_builder.call("create_display_chart_proof",receiver.mesh))
	var options := {"mesh_count": collection.mesh_nodes.size(), "resolution": atlas_resolution,
		"samples_per_texel": samples_per_texel, "seed": seed, "worker_count": worker_count}
	return {"ok": true, "estimator": estimator, "inputs": inputs, "options": options,
		"collection": collection, "environment_result": environment_result,
		"backend_contract_version": backend_contract_version,
		"output_resource_path": output_resource_path, "bounds": bounds, "display_gutter_pixels": display_gutter_pixels,
		"scene_root": scene_root, "receiver_root": receiver_root,
		"scene_signature": _collection_signature(collection), "display_chart_proofs":display_chart_proofs,
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
	var current_collection := _collect_scene(context.receiver_root, context.scene_root)
	if not current_collection.ok or _collection_signature(current_collection) != context.scene_signature or bounds != context.bounds:
		return _fail("Scene geometry, materials, lights, receiver bounds, or paths changed during baking. The previous lightmap was kept; bake again for the edited scene.")
	var variance_layers: Array[PackedFloat32Array] = []
	var radiance_layers: Array[PackedFloat32Array] = []
	for layer_variant in traced.layers:
		var layer: Dictionary = layer_variant
		radiance_layers.append(layer.rgba)
		variance_layers.append(layer.variance)

	var result_data: Resource = DATA_SCRIPT.new() as Resource
	result_data.set("atlas_resolution", options.resolution)
	result_data.set("samples_per_texel", options.samples_per_texel)
	result_data.set("seed", options.seed)
	result_data.set("surface_model", "incoming irradiance/pi; interpolated shading normals; Lambert/Burley + isotropic Smith GGX/Schlick transport; linear HDR; no denoising or clamp")
	result_data.set("physical_light_units_enabled", context.physical_light_units_enabled)
	result_data.set("backend_contract_version", backend_contract_version)
	result_data.set("scene_transport_signature", context.scene_signature)
	result_data.set("environment_override", environment_result.description)
	result_data.set("directional_light_count", collection.directional_lights.size())
	result_data.set("area_light_count", collection.area_lights.size())
	result_data.set("bake_worker_count", options.worker_count)
	result_data.set("display_gutter_pixels", context.display_gutter_pixels)
	result_data.set("display_chart_proofs", context.display_chart_proofs)
	result_data.set("excluded_lights", collection.excluded_lights)
	var mesh_relative_paths: Array[NodePath] = []
	for mesh_instance in collection.mesh_nodes:
		mesh_relative_paths.append(get_path_to(mesh_instance))
	result_data.set("mesh_relative_paths", mesh_relative_paths)
	result_data.set("radiance_layers", radiance_layers)
	result_data.set("sampled_mesh_count", collection.mesh_nodes.size())
	result_data.set("sampled_triangle_count", traced.triangle_count)
	result_data.set("receiver_triangle_count", collection.receiver_triangle_count)
	result_data.set("transport_only_mesh_count", collection.transport_only_mesh_count)
	result_data.set("transport_only_triangle_count", collection.transport_only_triangle_count)
	result_data.set("transport_only_reasons", collection.transport_only_reasons)
	result_data.set("receiver_bounds_local", context.bounds)
	result_data.set("receiver_boundary_rule", "A complete MeshInstance3D AABB must lie in the volume-local bounds and under source_root_path. Other complete scene geometry stays transport-only.")
	result_data.set("skipped_zero_area_triangle_count", collection.skipped_zero_area_triangle_count)
	result_data.set("emitter_triangle_count", traced.emitter_triangle_count)
	result_data.set("covered_texel_count", traced.covered_texels)
	result_data.set("path_count", traced.path_count)
	result_data.set("average_path_bounces", traced.average_path_bounces)
	result_data.set("rr_survivals", traced.rr_survivals)
	result_data.set("luminance_variance_layers", variance_layers)

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
	last_bake_report["surface_model"] = result_data.get("surface_model")
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


func _collection_signature(collection: Dictionary) -> String:
	var snapshot: Array = []
	for key in ["vertices", "normals", "uv2", "albedo", "emission", "material_flags", "mesh_ids", "roughness", "metallic", "specular", "diffuse_modes"]:
		snapshot.append(collection.get(key))
	for key in ["directional_lights", "area_lights"]:
		var sources: Array[Dictionary] = []
		for light: Dictionary in collection.get(key, []):
			var source := light.duplicate()
			# Absolute tree paths differ between editor and game instances; the
			# actual transport fields must determine persistent bake validity.
			source.erase("source_path")
			sources.append(source)
		snapshot.append(sources)
	for receiver: Node in collection.get("mesh_nodes", []):
		snapshot.append(get_path_to(receiver))
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(var_to_bytes(snapshot))
	return hash.finish().hex_encode()


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
				var collected := _collect_scene(receiver, scene)
				if not collected.ok:
					result.error = collected.error
				elif _collection_signature(collected) != signature or bounds != baked_data.get("receiver_bounds_local") or bool(baked_data.get("physical_light_units_enabled")) != bool(ProjectSettings.get_setting("rendering/lights_and_shadows/use_physical_light_units", false)):
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
		if not _color_is_nonnegative_finite(environment_radiance):
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
			if not _color_is_nonnegative_finite(pixel):
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


func _color_is_nonnegative_finite(color: Color) -> bool:
	return is_finite(color.r) and is_finite(color.g) and is_finite(color.b) and color.r >= 0.0 and color.g >= 0.0 and color.b >= 0.0


func _read_directional_light(light: DirectionalLight3D) -> Dictionary:
	var source := String(light.get_path())
	if light.light_negative:
		return {"ok": false, "error": "%s is a negative light; nonnegative physical transport is required." % source}
	if not is_finite(light.light_angular_distance) or light.light_angular_distance < 0.0 or light.light_angular_distance >= 180.0:
		return {"ok": false, "error": "%s requires a finite angular diameter in [0,180) degrees." % source}
	if (light.light_cull_mask & 0xFFFFF) != 0xFFFFF:
		return {"ok": false, "error": "%s has a restricted light_cull_mask; per-object light linking is not represented by this surface estimator." % source}
	if not is_finite(light.light_energy) or light.light_energy < 0.0 or not is_finite(light.light_indirect_energy) or light.light_indirect_energy < 0.0:
		return {"ok": false, "error": "%s has non-finite or negative light energy." % source}
	var radiance := light.light_color.srgb_to_linear()
	var energy := light.light_energy
	if bool(ProjectSettings.get_setting("rendering/lights_and_shadows/use_physical_light_units", false)):
		energy *= light.light_intensity_lux
		radiance *= light.get_correlated_color().srgb_to_linear()
	else:
		# The nonphysical realtime Lambert path omits 1/pi; express the same
		# source in this integrator's radiometric convention.
		energy *= PI
	radiance *= energy
	var direction := light.global_basis.z.normalized()
	if not _color_is_nonnegative_finite(radiance) or not direction.is_finite() or direction.length_squared() < 0.99:
		return {"ok": false, "error": "%s has an invalid direction or linear radiance." % source}
	return {"ok": true, "input": {"direction_to_light": direction, "radiance": radiance,
		"direct_enabled": light.light_bake_mode == Light3D.BAKE_STATIC,
		"indirect_energy": light.light_indirect_energy, "angular_distance": light.light_angular_distance,
		"source_path": source}}


func _read_area_light(light: AreaLight3D) -> Dictionary:
	var source := String(light.get_path())
	if light.area_texture != null:
		return {"ok": false, "error": "%s uses an area-light texture; only constant rectangular emission is represented." % source}
	if light.light_negative or (light.light_cull_mask & 0xFFFFF) != 0xFFFFF:
		return {"ok": false, "error": "%s uses negative illumination or restricted light linking, unsupported by physical surface transport." % source}
	var shape := light.area_size
	if not shape.is_finite() or shape.x <= 0.0 or shape.y <= 0.0 or not is_finite(light.area_range) or light.area_range <= 0.0:
		return {"ok": false, "error": "%s requires finite positive rectangular size and range." % source}
	if not is_finite(light.light_energy) or light.light_energy < 0.0 or not is_finite(light.light_indirect_energy) or light.light_indirect_energy < 0.0 or not is_finite(light.area_attenuation):
		return {"ok": false, "error": "%s has invalid energy or attenuation." % source}
	var energy := light.light_energy
	var radiance := light.light_color.srgb_to_linear()
	var attenuation := light.area_attenuation
	if bool(ProjectSettings.get_setting("rendering/lights_and_shadows/use_physical_light_units", false)):
		energy *= light.light_intensity_lumens / PI
		radiance *= light.get_correlated_color().srgb_to_linear()
		attenuation = 2.0
	else:
		energy *= PI
	if light.area_normalize_energy:
		energy /= shape.x * shape.y
	radiance *= energy
	# Match the renderer's authored rectangle size: node scale does not alter
	# AreaLight3D's explicit area_size; basis axes define its orientation only.
	var axis_u := light.global_basis.x.normalized() * shape.x
	var axis_v := light.global_basis.y.normalized() * shape.y
	var normal := -light.global_basis.z.normalized()
	if not light.global_position.is_finite() or axis_u.length_squared() <= 0.0 or axis_v.length_squared() <= 0.0 or normal.length_squared() < 0.99 or not _color_is_nonnegative_finite(radiance) or not axis_u.is_finite() or not axis_v.is_finite() or not normal.is_finite() or absf(axis_u.normalized().dot(axis_v.normalized())) > 0.0001 or absf(normal.dot(axis_u.normalized())) > 0.0001 or absf(normal.dot(axis_v.normalized())) > 0.0001:
		return {"ok": false, "error": "%s has invalid rectangular axes/radiance; shear is unsupported." % source}
	return {"ok": true, "input": {"center": light.global_position, "axis_u": axis_u, "axis_v": axis_v,
		"normal": normal, "radiance": radiance, "range": light.area_range, "attenuation": attenuation,
		"direct_enabled": light.light_bake_mode == Light3D.BAKE_STATIC,
		"indirect_energy": light.light_indirect_energy, "source_path": source}}


func _environment_uses_unmodeled_lighting(environment: Environment) -> bool:
	var has_sky := environment.sky != null or environment.background_mode == Environment.BG_SKY
	var has_color_background := environment.background_mode == Environment.BG_COLOR or environment.background_mode == Environment.BG_CLEAR_COLOR
	var has_non_color_background := not has_color_background
	var has_background_color := has_color_background and not environment.background_color.is_equal_approx(Color.BLACK) and environment.background_energy_multiplier > 0.0
	var has_ambient_color := environment.ambient_light_source == Environment.AMBIENT_SOURCE_COLOR and environment.ambient_light_energy > 0.0 and not environment.ambient_light_color.is_equal_approx(Color.BLACK)
	var has_ambient_sky := environment.ambient_light_source == Environment.AMBIENT_SOURCE_SKY and environment.ambient_light_energy > 0.0
	return has_sky or has_non_color_background or has_background_color or has_ambient_color or has_ambient_sky


func _collect_scene(receiver_root: Node, scene_root: Node) -> Dictionary:
	var vertices := PackedVector3Array()
	var uv2 := PackedVector2Array()
	var albedo := PackedColorArray()
	var emission := PackedColorArray()
	var material_flags := PackedByteArray()
	var normals := PackedVector3Array()
	var roughness := PackedFloat32Array()
	var metallic := PackedFloat32Array()
	var specular := PackedFloat32Array()
	var diffuse_modes := PackedByteArray()
	var directional_lights: Array[Dictionary] = []
	var area_lights: Array[Dictionary] = []
	var triangle_sources: Array[Dictionary] = []
	var mesh_ids := PackedInt32Array()
	var mesh_nodes: Array[Node] = []
	var excluded_lights := PackedStringArray()
	var transport_only_reasons := PackedStringArray()
	var transport_only_mesh_count := 0
	var receiver_triangle_count := 0
	var transport_only_triangle_count := 0
	var skipped_zero_area_triangle_count := 0
	var errors := PackedStringArray()
	var scene_to_volume := global_transform.affine_inverse()
	var stack: Array[Node] = [scene_root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if node is MeshInstance3D:
			var mesh_instance := node as MeshInstance3D
			if not mesh_instance.is_visible_in_tree():
				errors.append("%s is not visible in the current scene tree; visibility-dependent geometry is unsupported." % mesh_instance.get_path())
				continue
			if mesh_instance.gi_mode != GeometryInstance3D.GI_MODE_STATIC:
				errors.append("%s is not marked GI_MODE_STATIC; mutable geometry cannot be used as a fixed transport scene." % mesh_instance.get_path())
				continue
			if mesh_instance.skin != null or mesh_instance.get_skin_reference() != null:
				errors.append("%s is skinned; deformed geometry is unsupported." % mesh_instance.get_path())
				continue
			var has_active_blend_shape := false
			for blend_shape_index in mesh_instance.get_blend_shape_count():
				if not is_zero_approx(mesh_instance.get_blend_shape_value(blend_shape_index)):
					has_active_blend_shape = true
					break
			if has_active_blend_shape:
				errors.append("%s has an active blend shape; deformed geometry is unsupported." % mesh_instance.get_path())
				continue
			if mesh_instance.mesh == null:
				errors.append("%s has no Mesh resource." % mesh_instance.get_path())
				continue
			if mesh_instance.mesh.get_surface_count() == 0:
				errors.append("%s has no mesh surfaces." % mesh_instance.get_path())
				continue

			var selected_for_receiving := mesh_instance == receiver_root or receiver_root.is_ancestor_of(mesh_instance)
			var inside_receiver_bounds := _mesh_aabb_inside_volume(mesh_instance, scene_to_volume)
			var is_receiver := selected_for_receiving and inside_receiver_bounds
			var mesh_id := -1
			if is_receiver:
				mesh_id = mesh_nodes.size()
				mesh_nodes.append(mesh_instance)
			else:
				transport_only_mesh_count += 1
				var reason := "outside source_root_path receiver subtree" if not selected_for_receiving else "whole MeshInstance3D AABB is not inside the volume-local bounds"
				transport_only_reasons.append("%s: %s; full geometry retained for transport." % [mesh_instance.get_path(), reason])

			var transform := mesh_instance.global_transform
			var flips_winding := transform.basis.determinant() < 0.0
			for surface_index in mesh_instance.mesh.get_surface_count():
				var surface_is_triangle_list := false
				if mesh_instance.mesh is ArrayMesh:
					surface_is_triangle_list = (mesh_instance.mesh as ArrayMesh).surface_get_primitive_type(surface_index) == Mesh.PRIMITIVE_TRIANGLES
				elif mesh_instance.mesh is PrimitiveMesh:
					# Godot's built-in PrimitiveMesh surfaces are expanded as triangle lists.
					surface_is_triangle_list = true
				else:
					errors.append("%s uses mesh class %s whose surface primitive type is not exposed to this extractor." % [mesh_instance.get_path(), mesh_instance.mesh.get_class()])
					continue
				if not surface_is_triangle_list:
					errors.append("%s surface %d is not a triangle list." % [mesh_instance.get_path(), surface_index])
					continue
				var arrays: Array = mesh_instance.mesh.surface_get_arrays(surface_index)
				var positions := PackedVector3Array()
				var surface_uv2 := PackedVector2Array()
				if arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array:
					positions = arrays[Mesh.ARRAY_VERTEX]
				if is_receiver and arrays[Mesh.ARRAY_TEX_UV2] is PackedVector2Array:
					surface_uv2 = arrays[Mesh.ARRAY_TEX_UV2]
				if positions.is_empty():
					errors.append("%s surface %d has no vertex positions." % [mesh_instance.get_path(), surface_index])
					continue
				if is_receiver and surface_uv2.size() != positions.size():
					errors.append("%s surface %d must have one UV2 per vertex because it receives a lightmap." % [mesh_instance.get_path(), surface_index])
					continue
				var indices := PackedInt32Array()
				if arrays[Mesh.ARRAY_INDEX] is PackedInt32Array:
					indices = arrays[Mesh.ARRAY_INDEX]
				var triangle_index_count := indices.size() if not indices.is_empty() else positions.size()
				if triangle_index_count % 3 != 0:
					errors.append("%s surface %d has an incomplete triangle." % [mesh_instance.get_path(), surface_index])
					continue
				var has_invalid_indices := false
				for index_offset in range(0, triangle_index_count, 3):
					for corner in 3:
						var vertex_index := indices[index_offset + corner] if not indices.is_empty() else index_offset + corner
						if vertex_index < 0 or vertex_index >= positions.size():
							has_invalid_indices = true
							break
					if has_invalid_indices:
						break
				if has_invalid_indices:
					errors.append("%s surface %d contains an invalid vertex index." % [mesh_instance.get_path(), surface_index])
					continue
				var material := _surface_material(mesh_instance, surface_index)
				var material_result := _read_material(material, mesh_instance, surface_index)
				if not material_result.ok:
					errors.append(material_result.error)
					continue
				var diffuse: Color = material_result.albedo
				var radiance: Color = material_result.emission
				var flags: int = material_result.flags
				var vertex_normals := PackedVector3Array()
				if arrays[Mesh.ARRAY_NORMAL] is PackedVector3Array:
					vertex_normals = arrays[Mesh.ARRAY_NORMAL]
				if not vertex_normals.is_empty() and vertex_normals.size() != positions.size():
					errors.append("%s surface %d has an incomplete vertex-normal array." % [mesh_instance.get_path(), surface_index])
					continue
				var normal_transform := transform.basis.inverse().transposed()
				var first_source_triangle := mesh_ids.size()
				for index_offset in range(0, triangle_index_count, 3):
					var i0 := indices[index_offset] if not indices.is_empty() else index_offset
					var i1 := indices[index_offset + 1] if not indices.is_empty() else index_offset + 1
					var i2 := indices[index_offset + 2] if not indices.is_empty() else index_offset + 2
					# Godot front faces are clockwise. The CPU integrator uses the
					# mathematical cross(b-a,c-a) convention, so reverse once;
					# a negative determinant already reverses the world winding.
					var local_indices := [i0, i2, i1] if not flips_winding else [i0, i1, i2]
					var triangle_positions: Array[Vector3] = []
					var triangle_uv2: Array[Vector2] = []
					for local_index in local_indices:
						var world_position: Vector3 = transform * positions[local_index]
						triangle_positions.append(world_position)
						triangle_uv2.append(surface_uv2[local_index] if is_receiver else Vector2.ZERO)
					var area_vector := (triangle_positions[1] - triangle_positions[0]).cross(triangle_positions[2] - triangle_positions[0])
					if area_vector.length_squared() == 0.0:
						# Zero-area faces have exactly zero measure in the surface integral.
						skipped_zero_area_triangle_count += 1
						continue
					for vertex in 3:
						vertices.append(triangle_positions[vertex])
						uv2.append(triangle_uv2[vertex])
						var shading_normal := (normal_transform * vertex_normals[local_indices[vertex]]).normalized() if not vertex_normals.is_empty() else area_vector.normalized()
						normals.append(shading_normal)
					albedo.append(diffuse)
					emission.append(radiance)
					material_flags.append(flags)
					roughness.append(material_result.roughness)
					metallic.append(material_result.metallic)
					specular.append(material_result.specular)
					diffuse_modes.append(material_result.diffuse_mode)
					mesh_ids.append(mesh_id)
					if is_receiver:
						receiver_triangle_count += 1
					else:
						transport_only_triangle_count += 1
				if mesh_ids.size() > first_source_triangle:
					triangle_sources.append({"first_triangle":first_source_triangle,"end_triangle":mesh_ids.size(),
						"path":str(mesh_instance.get_path()),"surface":surface_index})
		elif node is GeometryInstance3D:
			errors.append("Unsupported geometry node %s (%s)." % [node.get_path(), node.get_class()])

	var light_stack: Array[Node] = [scene_root]
	while not light_stack.is_empty():
		var node: Node = light_stack.pop_back()
		if node is Light3D:
			var light := node as Light3D
			if light.editor_only or not light.is_visible_in_tree() or light.light_bake_mode == Light3D.BAKE_DISABLED:
				excluded_lights.append("%s (editor-only, hidden, or BAKE_DISABLED; excluded from GI baking)" % light.get_path())
			elif light is DirectionalLight3D and (light as DirectionalLight3D).sky_mode == DirectionalLight3D.SKY_MODE_SKY_ONLY:
				excluded_lights.append("%s (SKY_MODE_SKY_ONLY; only present through the captured environment)" % light.get_path())
			elif light is DirectionalLight3D:
				var result := _read_directional_light(light as DirectionalLight3D)
				if result.ok:
					directional_lights.append(result.input)
				else:
					errors.append(result.error)
			elif light is AreaLight3D:
				var result := _read_area_light(light as AreaLight3D)
				if result.ok:
					area_lights.append(result.input)
				else:
					errors.append(result.error)
			else:
				errors.append("Analytic light %s (%s) is unsupported; use directional/rectangular area lights or emissive triangle surfaces. No light was silently discarded." % [light.get_path(), light.get_class()])
		for child in node.get_children():
			light_stack.append(child)

	if mesh_nodes.is_empty():
		errors.append("No fully-contained receiver MeshInstance3D was found under source_root_path and inside the volume-local bounds.")
	if receiver_triangle_count == 0:
		errors.append("No non-zero-area receiver triangles were found; transport-only meshes do not receive atlas layers.")
	if not errors.is_empty():
		return {"ok": false, "error": "\n".join(errors)}
	return {
		"ok": true,
		"vertices": vertices,
		"normals": normals,
		"roughness": roughness,
		"metallic": metallic,
		"specular": specular,
		"diffuse_modes": diffuse_modes,
		"directional_lights": directional_lights,
		"area_lights": area_lights,
		"triangle_sources": triangle_sources,
		"uv2": uv2,
		"albedo": albedo,
		"emission": emission,
		"material_flags": material_flags,
		"mesh_ids": mesh_ids,
		"mesh_nodes": mesh_nodes,
		"excluded_lights": excluded_lights,
		"transport_only_reasons": transport_only_reasons,
		"transport_only_mesh_count": transport_only_mesh_count,
		"receiver_triangle_count": receiver_triangle_count,
		"transport_only_triangle_count": transport_only_triangle_count,
		"skipped_zero_area_triangle_count": skipped_zero_area_triangle_count,
	}


func _mesh_aabb_inside_volume(mesh_instance: MeshInstance3D, scene_to_volume: Transform3D) -> bool:
	var mesh_bounds := mesh_instance.get_aabb()
	if mesh_bounds.size.x < 0.0 or mesh_bounds.size.y < 0.0 or mesh_bounds.size.z < 0.0:
		return false
	var padded_volume_bounds := bounds.grow(0.00001)
	var mesh_to_volume: Transform3D = scene_to_volume * mesh_instance.global_transform
	var mesh_end: Vector3 = mesh_bounds.position + mesh_bounds.size
	for x in 2:
		for y in 2:
			for z in 2:
				var corner := Vector3(
					mesh_end.x if x == 1 else mesh_bounds.position.x,
					mesh_end.y if y == 1 else mesh_bounds.position.y,
					mesh_end.z if z == 1 else mesh_bounds.position.z
				)
				if not padded_volume_bounds.has_point(mesh_to_volume * corner):
					return false
	return true


func _surface_material(mesh_instance: MeshInstance3D, surface_index: int) -> Material:
	if mesh_instance.material_override != null:
		return mesh_instance.material_override
	var surface_override := mesh_instance.get_surface_override_material(surface_index)
	if surface_override != null:
		return surface_override
	return mesh_instance.mesh.surface_get_material(surface_index)


func _read_material(material: Material, mesh_instance: MeshInstance3D, surface_index: int) -> Dictionary:
	var source_name := "%s surface %d" % [mesh_instance.get_path(), surface_index]
	if material == null:
		return {"ok": false, "error": "%s has no material; implicit/default materials are rejected." % source_name}
	if not material is StandardMaterial3D:
		return {"ok": false, "error": "%s uses unsupported material type %s; only constant StandardMaterial3D is supported." % [source_name, material.get_class()]}
	var standard := material as StandardMaterial3D
	if standard.next_pass != null or mesh_instance.material_overlay != null:
		return {"ok": false, "error": "%s uses material overlay/next_pass; layered drawing is not represented by one surface BSDF." % source_name}
	if standard.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
		return {"ok": false, "error": "%s is transparent; transparent transport is unsupported." % source_name}
	if standard.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED:
		return {"ok": false, "error": "%s is unshaded; unshaded surface transport is unsupported." % source_name}
	if standard.get_flag(BaseMaterial3D.FLAG_ALBEDO_FROM_VERTEX_COLOR):
		return {"ok": false, "error": "%s uses vertex colors as albedo; vertex-color materials are unsupported." % source_name}
	if standard.get_flag(BaseMaterial3D.FLAG_DISABLE_AMBIENT_LIGHT):
		return {"ok": false, "error": "%s disables ambient light and cannot consume a LightmapGI result." % source_name}
	if standard.diffuse_mode not in [BaseMaterial3D.DIFFUSE_LAMBERT, BaseMaterial3D.DIFFUSE_BURLEY]:
		return {"ok": false, "error": "%s uses diffuse mode %s; this estimator supports DIFFUSE_LAMBERT and DIFFUSE_BURLEY." % [source_name, _diffuse_mode_name(standard.diffuse_mode)]}
	if standard.specular_mode not in [BaseMaterial3D.SPECULAR_DISABLED, BaseMaterial3D.SPECULAR_SCHLICK_GGX]:
		return {"ok": false, "error": "%s uses an unsupported specular mode; only disabled and Schlick GGX are represented." % source_name}
	if standard.emission_enabled and standard.emission_operator != BaseMaterial3D.EMISSION_OP_ADD:
		return {"ok": false, "error": "%s uses a multiplicative emission operator." % source_name}
	var texture_properties := PackedStringArray([
		"albedo_texture", "orm_texture", "metallic_texture", "roughness_texture",
		"normal_texture", "bent_normal_texture", "ao_texture", "emission_texture",
		"rim_texture", "clearcoat_texture", "anisotropy_flowmap", "heightmap_texture",
		"subsurf_scatter_texture", "subsurf_scatter_transmittance_texture", "backlight_texture",
		"refraction_texture", "detail_mask", "detail_albedo", "detail_normal",
	])
	for property_name in texture_properties:
		if standard.get(property_name) != null:
			return {"ok": false, "error": "%s uses texture %s; textured materials are unsupported." % [source_name, property_name]}
	if standard.clearcoat_enabled or standard.anisotropy_enabled or standard.refraction_enabled or standard.rim_enabled or standard.subsurf_scatter_enabled or standard.subsurf_scatter_transmittance_enabled or standard.backlight_enabled or standard.bent_normal_enabled or standard.ao_enabled:
		return {"ok": false, "error": "%s enables a non-diffuse lobe; this volume only estimates diffuse lightmaps." % source_name}
	if standard.cull_mode == BaseMaterial3D.CULL_FRONT:
		return {"ok": false, "error": "%s uses front-face culling; only back-face-culling and two-sided materials are supported." % source_name}
	# BaseMaterial3D color properties use the source-color convention. Godot's
	# voxel bake decodes these same values before using them as linear transport.
	var diffuse := standard.albedo_color.srgb_to_linear()

	if diffuse.a < 0.99999 or diffuse.r < 0.0 or diffuse.g < 0.0 or diffuse.b < 0.0 or diffuse.r > 1.0 or diffuse.g > 1.0 or diffuse.b > 1.0:
		return {"ok": false, "error": "%s has diffuse reflectance outside [0,1]." % source_name}
	var emitted := Color.BLACK
	if standard.emission_enabled:
		var emission_scale := standard.emission_energy_multiplier
		if ProjectSettings.get_setting("rendering/lights_and_shadows/use_physical_light_units", false):
			emission_scale *= standard.emission_intensity
		emitted = standard.emission.srgb_to_linear() * emission_scale
	if emitted.r < 0.0 or emitted.g < 0.0 or emitted.b < 0.0:
		return {"ok": false, "error": "%s has negative emission." % source_name}
	var flags := 0
	if standard.cull_mode == BaseMaterial3D.CULL_DISABLED:
		flags |= 1
		if standard.emission_enabled:
			flags |= 2
	var material_specular := standard.metallic_specular if standard.specular_mode != BaseMaterial3D.SPECULAR_DISABLED else 0.0
	if standard.metallic < 0.0 or standard.metallic > 1.0 or standard.roughness < 0.0 or standard.roughness > 1.0 or material_specular < 0.0 or material_specular > 1.0:
		return {"ok": false, "error": "%s has invalid roughness, metallic, or specular values." % source_name}
	if standard.roughness == 0.0 and (material_specular > 0.0 or standard.metallic > 0.0):
		return {"ok": false, "error": "%s has a zero-roughness delta specular lobe; the current GGX integrator requires positive roughness." % source_name}
	if standard.specular_mode == BaseMaterial3D.SPECULAR_DISABLED and standard.metallic > 0.0:
		return {"ok": false, "error": "%s combines metallic > 0 with SPECULAR_DISABLED; this nonphysical material model is unsupported." % source_name}
	return {"ok": true, "albedo": diffuse, "emission": emitted, "flags": flags,
		"roughness": standard.roughness, "metallic": standard.metallic, "specular": material_specular,
		"diffuse_mode": 1 if standard.diffuse_mode == BaseMaterial3D.DIFFUSE_BURLEY else 0}


func _diffuse_mode_name(mode: int) -> String:
	match mode:
		BaseMaterial3D.DIFFUSE_BURLEY:
			return "DIFFUSE_BURLEY"
		BaseMaterial3D.DIFFUSE_LAMBERT:
			return "DIFFUSE_LAMBERT"
		BaseMaterial3D.DIFFUSE_LAMBERT_WRAP:
			return "DIFFUSE_LAMBERT_WRAP"
		BaseMaterial3D.DIFFUSE_TOON:
			return "DIFFUSE_TOON"
		_:
			return "unknown (%d)" % mode
