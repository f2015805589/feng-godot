extends SceneTree
## Builds a tiny, declared Lambertian scene and round-trips its independent atlas.
## This fixture is not a bake of the white-box demo.

const VOLUME_SCRIPT := preload("res://addons/feng-lightmap-mc/feng_lightmap_volume.gd")
const DATA_SCRIPT := preload("res://addons/feng-lightmap-mc/feng_lightmap_data.gd")
const EXTENSION_PATH := "res://addons/feng-lightmap-mc/feng-lightmap-mc.gdextension"
const OUTPUT_DIRECTORY := "user://feng_lightmap_mc_test"
const ATLAS_RESOLUTION := 16
const SAMPLES_PER_TEXEL := 64
const BAKE_SEED := 739_391


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var output_path := _unique_output_path()
	if not GDExtensionManager.is_extension_loaded(EXTENSION_PATH):
		var extension_status := GDExtensionManager.load_extension(EXTENSION_PATH)
		if extension_status != GDExtensionManager.LOAD_STATUS_OK:
			_abort("Could not load the CPU extension (status %d)." % extension_status)
			return
	var fixture_root := Node3D.new()
	fixture_root.name = "AnalyticLightmapFixture"
	var receiver_material := _diffuse_material(Color(0.65, 0.65, 0.65), Color.BLACK)
	var emitter_material := _diffuse_material(Color.BLACK, Color(3.0, 2.2, 1.4))
	emitter_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	var receiver := _quad(
		"Receiver",
		PackedVector3Array([
			Vector3(-1.0, 0.0, -1.0), Vector3(-1.0, 0.0, 1.0),
			Vector3(1.0, 0.0, 1.0), Vector3(1.0, 0.0, -1.0),
		]),
		receiver_material
	)
	var emitter := _quad(
		"Emitter",
		PackedVector3Array([
			Vector3(-0.4, 0.45, -0.4), Vector3(0.4, 0.45, 0.4),
			Vector3(0.4, 0.45, -0.4), Vector3(-0.4, 0.45, 0.4),
		]),
		emitter_material,
		false # Source-only emitter intentionally has no UV2.
	)
	fixture_root.add_child(receiver)
	fixture_root.add_child(emitter)
	get_root().add_child(fixture_root)
	current_scene = fixture_root

	var volume := VOLUME_SCRIPT.new() as Node3D
	volume.name = "IndependentLightmapVolume"
	fixture_root.add_child(volume)
	volume.set("source_root_path", NodePath(".."))
	volume.set("bounds", AABB(Vector3(-1.01, -0.05, -1.01), Vector3(2.02, 0.1, 2.02)))
	volume.set("atlas_resolution", ATLAS_RESOLUTION)
	volume.set("samples_per_texel", SAMPLES_PER_TEXEL)
	volume.set("seed", BAKE_SEED)
	volume.set("output_resource_path", output_path)
	volume.set("environment_mode", 1) # Explicit black environment for this analytic scene.
	volume.set("enabled", true)
	var bake_button: Callable = volume.get("bake_button")
	if not bake_button.is_valid():
		_abort("The Inspector Bake CPU Lightmap button has no handler.")
		fixture_root.free()
		return
	bake_button.call()
	var saw_running_status := false
	var completed := false
	var report: Dictionary = {}
	var deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		var status_text := String(volume.get("bake_status"))
		if status_text.begins_with("Baking:"):
			saw_running_status = true
		if status_text.begins_with("Succeeded:") or status_text.begins_with("Failed:"):
			completed = true
			report = volume.get("last_bake_report")
			break
	if not completed or not saw_running_status:
		_abort("The connected Inspector bake handler did not expose running and terminal status.")
		fixture_root.free()
		return
	if not report.get("ok", false):
		_abort("Analytic fixture was rejected: %s" % report.get("error", "unknown error"))
		fixture_root.free()
		return
	if not FileAccess.file_exists(ProjectSettings.globalize_path(output_path)):
		_abort("The bake returned success but did not write %s." % output_path)
		fixture_root.free()
		return
	var original_data: Resource = volume.get("baked_data")
	var original_samples := var_to_bytes([original_data.get("radiance_layers"), original_data.get("luminance_variance_layers")])
	var reloaded := ResourceLoader.load(output_path, "", ResourceLoader.CACHE_MODE_REPLACE) as Resource
	if reloaded == null or reloaded.get_script() != DATA_SCRIPT:
		_abort("Saved FengLightmapData could not be reloaded from %s." % output_path)
		fixture_root.free()
		return
	if var_to_bytes([reloaded.get("radiance_layers"), reloaded.get("luminance_variance_layers")]) != original_samples:
		_abort("Compressed binary roundtrip changed raw radiance or variance bits.")
		fixture_root.free()
		return
	var chart_proofs: Array = reloaded.get("display_chart_proofs")
	if chart_proofs.size() != 1 or int(chart_proofs[0].get("version",-1)) != 1 or not bool(chart_proofs[0].get("single_connected_chart",false)):
		_abort("Saved resource lacks its explicit versioned receiver chart proof.")
		fixture_root.free()
		return
	if bool(reloaded.get("physical_light_units_enabled")) != bool(ProjectSettings.get_setting("rendering/lights_and_shadows/use_physical_light_units", false)):
		_abort("The resource did not preserve the project's physical light units setting.")
		fixture_root.free()
		return
	volume.set("baked_data", reloaded)
	volume.call("_refresh_display")
	var mesh_paths: Array = reloaded.get("mesh_relative_paths")
	var radiance_layers: Array = reloaded.get("radiance_layers")
	if mesh_paths.size() != 1 or radiance_layers.size() != 1:
		_abort("Only the in-bounds receiver may own an atlas; the out-of-bounds emitter is transport-only.")
		fixture_root.free()
		return
	var receiver_layer_index := -1
	for mesh_index in mesh_paths.size():
		if String(mesh_paths[mesh_index]).contains("Receiver"):
			receiver_layer_index = mesh_index
	if receiver_layer_index < 0:
		_abort("The saved mesh paths do not identify the receiver atlas layer.")
		fixture_root.free()
		return
	var receiver_rgba: PackedFloat32Array = radiance_layers[receiver_layer_index]
	if receiver_rgba.size() != ATLAS_RESOLUTION * ATLAS_RESOLUTION * 4:
		_abort("The saved receiver atlas has the wrong number of linear RGBAF samples.")
		fixture_root.free()
		return
	var receiver_radiance_sum := 0.0
	for pixel in ATLAS_RESOLUTION * ATLAS_RESOLUTION:
		var offset := pixel * 4
		receiver_radiance_sum += Color(receiver_rgba[offset], receiver_rgba[offset + 1], receiver_rgba[offset + 2]).get_luminance()
	var display := volume.get_node_or_null("FengLightmapDisplay") as LightmapGI
	var gi_data := display.light_data if display != null else null
	var texture_layers: Array = gi_data.get_lightmap_textures() if gi_data != null else []
	var atlas_array := texture_layers[0] as Texture2DArray if not texture_layers.is_empty() else null
	if gi_data == null or gi_data.get_user_count() != 1 or atlas_array == null or atlas_array.get_layers() != 1:
		_abort("The enabled volume could not build a one-user runtime LightmapGIData from the receiver-only CPU resource.")
		fixture_root.free()
		return
	var original_gi_id := gi_data.get_instance_id()
	var original_texture_id := atlas_array.get_instance_id()
	volume.set("enabled", false)
	volume.set("enabled", true)
	var cached_gi := (volume.get_node_or_null("FengLightmapDisplay") as LightmapGI).light_data
	if cached_gi.get_instance_id() != original_gi_id or cached_gi.get_lightmap_textures()[0].get_instance_id() != original_texture_id:
		_abort("Enable/disable rebuilt the runtime atlas instead of using its cache.")
		fixture_root.free()
		return
	if receiver_radiance_sum <= 0.0 or report.get("emitter_triangle_count", 0) != 2 or report.get("path_count", 0) <= 0:
		_abort("The serialized fixture lacks area-emitter transport or path samples.")
		fixture_root.free()
		return
	if report.get("mesh_count", 0) != 1 or report.get("receiver_triangle_count", 0) != 2:
		_abort("Only the complete in-bounds receiver should receive lightmap texels.")
		fixture_root.free()
		return
	if report.get("transport_only_mesh_count", 0) != 1 or report.get("transport_only_triangle_count", 0) != 2:
		_abort("The out-of-bounds emitter must remain complete transport-only geometry.")
		fixture_root.free()
		return
	var saved_transport_only_reasons: PackedStringArray = reloaded.get("transport_only_reasons")
	if saved_transport_only_reasons.is_empty():
		_abort("The saved resource must record why the emitter has no receiver atlas.")
		fixture_root.free()
		return
	print(JSON.stringify({
		"ok": true,
		"fixture": "two-triangle Lambert receiver plus two-triangle diffuse emitter",
		"output": output_path,
		"atlas_resolution": ATLAS_RESOLUTION,
		"samples_per_texel": SAMPLES_PER_TEXEL,
		"receiver_mesh_count": report.get("mesh_count"),
		"receiver_triangle_count": report.get("receiver_triangle_count"),
		"transport_only_mesh_count": report.get("transport_only_mesh_count"),
		"transport_only_triangle_count": report.get("transport_only_triangle_count"),
		"total_triangle_count": report.get("total_triangle_count"),
		"emitter_triangle_count": report.get("emitter_triangle_count"),
		"covered_texels": report.get("covered_texels"),
		"path_count": report.get("path_count"),
		"average_path_bounces": report.get("average_path_bounces"),
		"rr_survivals": report.get("rr_survivals"),
		"receiver_radiance_sum": receiver_radiance_sum,
		"physical_light_units_enabled": reloaded.get("physical_light_units_enabled"),
		"resource_bytes": FileAccess.get_file_as_bytes(ProjectSettings.globalize_path(output_path)).size(),
	}))
	fixture_root.free()
	quit(0)


func _unique_output_path() -> String:
	var base := "%s/analytic_lightmap_fixture_%d" % [OUTPUT_DIRECTORY, int(Time.get_unix_time_from_system())]
	var candidate := base + ".res"
	var suffix := 1
	while FileAccess.file_exists(ProjectSettings.globalize_path(candidate)):
		candidate = base + "_%d.res" % suffix
		suffix += 1
	return candidate


func _diffuse_material(albedo: Color, emitted: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = albedo
	material.metallic = 0.0
	material.diffuse_mode = BaseMaterial3D.DIFFUSE_LAMBERT
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	material.emission_enabled = emitted.r > 0.0 or emitted.g > 0.0 or emitted.b > 0.0
	material.emission = emitted
	material.emission_energy_multiplier = 1.0
	return material


func _quad(node_name: String, vertices: PackedVector3Array, material: StandardMaterial3D, include_uv2: bool = true) -> MeshInstance3D:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	if include_uv2:
		arrays[Mesh.ARRAY_TEX_UV2] = PackedVector2Array([
			Vector2(0.0, 0.0), Vector2(0.0, 1.0), Vector2(1.0, 1.0), Vector2(1.0, 0.0),
		])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 2, 1, 0, 3, 2]) # Godot clockwise front face
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material)
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = node_name
	mesh_instance.mesh = mesh
	mesh_instance.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	return mesh_instance


func _abort(message: String) -> void:
	push_error("FengLightmapMC analytic fixture: " + message)
	quit(1)
