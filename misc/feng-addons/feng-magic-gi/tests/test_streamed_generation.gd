extends SceneTree
## CPU-only end-to-end check for immutable streamed bake publication.

const Volume = preload("res://addons/feng-magic-gi/feng_magic_gi_volume.gd")
const Page = preload("res://addons/feng-magic-gi/feng_magic_gi_page.gd")
const Manifest = preload("res://addons/feng-magic-gi/feng_magic_gi_manifest.gd")
const ProbeLayout = preload("res://addons/feng-magic-gi/feng_magic_gi_probe_layout.gd")

var _checks := 0
var _failures := 0
var _mutation_callback := Callable()

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var scene := Node3D.new()
	scene.name = "StreamedBakeSmokeScene"
	root.add_child(scene)
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "BakeBox"
	var box := BoxMesh.new()
	box.size = Vector3.ONE * 2.0
	mesh_instance.mesh = box
	mesh_instance.position = Vector3(4.0, 0.0, 4.0)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.5, 0.5, 0.5)
	mesh_instance.material_override = material
	scene.add_child(mesh_instance)
	var volume: FMagicGIVolume = Volume.new()
	volume.name = "StreamedBakeVolume"
	volume.position = Vector3(4.0, 0.0, 4.0)
	volume.size = Vector3.ONE * 4.0
	volume.probe_spacing = 1.0
	volume.minimum_probe_spacing = 0.5
	volume.adaptive_placement = false
	volume.surface_offset = 0.03
	volume.bake_samples = 1
	volume.bake_bounces = 1
	volume.bake_distance = 1.0
	volume.core_page_size = 32.0
	volume.management_block_size = 512.0
	volume.bake_output_directory = "res://bake/magicgi/streamed_generation_smoke"
	volume.show_probes = false
	scene.add_child(volume)
	await process_frame
	var started := Time.get_ticks_msec()
	print("STAGE: streamed bake start")
	var baked := await volume.bake()
	print("STAGE: streamed bake return=%s elapsed_ms=%d" % [baked, Time.get_ticks_msec() - started])
	_check(baked, "small CPU streamed bake completes and atomically assigns its manifest")
	_check(volume.bake_data == null and volume.bake_manifest is Manifest
			and volume.bake_manifest.is_valid(), "new bake uses the manifest path and leaves legacy bake_data untouched")
	if volume.bake_manifest is Manifest and volume.bake_manifest.is_valid():
		var manifest: Manifest = volume.bake_manifest
		_check(not manifest.partial_generation and manifest.get_page_count() > 0,
			"full bake publishes a complete sparse page manifest")
		var manifest_path := String(manifest.resource_path)
		_check(not manifest_path.is_empty() and FileAccess.file_exists(manifest_path),
			"manifest resource is saved before it becomes active")
		var reloaded := ResourceLoader.load(manifest_path, "", ResourceLoader.CACHE_MODE_IGNORE) as Manifest
		_check(reloaded != null and reloaded.is_valid()
			and reloaded.generation == manifest.generation,
			"saved manifest reopens with a valid generation and spatial index")
		var nonempty := 0
		var page_files_valid := true
		var page_layout_revisions_match := true
		for entry in manifest.page_entries:
			if bool(entry.get("empty", false)):
				continue
			nonempty += 1
			var path := String(entry.get("resource_path", ""))
			var page := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as Page
			if page == null:
				page_files_valid = false
				page_layout_revisions_match = false
				continue
			page_files_valid = page_files_valid \
					and page.is_valid(String(entry.get("page_generation", "")),
						String(entry.get("page_key", ""))) \
					and not String(entry.get("content_hash", "")).is_empty()
			page_layout_revisions_match = page_layout_revisions_match \
					and page.data.placement_layout_revision == ProbeLayout.PLACEMENT_LAYOUT_REVISION
		_check(nonempty > 0 and page_files_valid,
			"saved page payloads reload and validate without embedding them in the manifest")
		_check(nonempty > 0 and page_layout_revisions_match,
			"new streamed page Data resources must stamp the current placement revision")
		_check(volume.has_bake(), "newly published full generation matches current scene and bake settings")
		var old_generation := manifest.generation
		var old_manifest_key := manifest.manifest_key
		var old_path := manifest_path
		var original_mesh_position := mesh_instance.position
		_mutation_callback = Callable(self, "_mutate_mesh_after_page").bind(volume, mesh_instance)
		volume.bake_status_changed.connect(_mutation_callback)
		var changed_scene_bake := await volume.bake_chunk(0, 0)
		_check(not changed_scene_bake and volume.bake_manifest == manifest
			and manifest.is_valid() and FileAccess.file_exists(old_path),
			"partial bake rejects a scene change during work and keeps the prior manifest")
		mesh_instance.position = original_mesh_position
		var chunk_baked := await volume.bake_chunk(0, 0)
		_check(chunk_baked and volume.bake_manifest is Manifest
			and volume.bake_manifest.generation != old_generation
			and volume.bake_manifest.manifest_key == old_manifest_key
			and volume.bake_manifest.partial_generation,
			"selected management chunk publishes a new generation under its stable Volume identity")
		_check(FileAccess.file_exists(old_path) and manifest.is_valid(),
			"partial publication retains the prior immutable generation")
		var partial_manifest := volume.bake_manifest
		var partial_manifest_path := String(partial_manifest.resource_path)
		volume.bake_output_directory = "user://rejected_output"
		var failed_bake := await volume.bake()
		_check(not failed_bake and volume.bake_manifest == partial_manifest
			and String(volume.bake_manifest.resource_path) == partial_manifest_path
			and FileAccess.file_exists(partial_manifest_path),
			"failed generation leaves the previously published manifest and files active")
	else:
		push_error("STREAMED_BAKE_MANIFEST_MISSING")
		_failures += 1
	print("MAGIC_GI_STREAMED_GENERATION checks=%d failures=%d" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)

func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: " + message)
	else:
		_failures += 1
		push_error("FAIL: " + message)

func _mutate_mesh_after_page(volume: FMagicGIVolume, mesh_instance: MeshInstance3D) -> void:
	if not is_instance_valid(volume) or not is_instance_valid(mesh_instance):
		return
	if volume.streamed_bake_progress().x <= 0:
		return
	mesh_instance.position.x += 0.1
	if volume.bake_status_changed.is_connected(_mutation_callback):
		volume.bake_status_changed.disconnect(_mutation_callback)
