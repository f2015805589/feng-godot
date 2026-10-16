extends SceneTree
## Run once with -- --write, then in a fresh process with -- --verify.

const Data = preload("res://addons/feng-magic-gi/feng_magic_gi_data.gd")
const Placement = preload("res://addons/feng-magic-gi/feng_magic_gi_placement.gd")
const Volume = preload("res://addons/feng-magic-gi/feng_magic_gi_volume.gd")
const Runtime = preload("res://addons/feng-magic-gi/feng_magic_gi_runtime.gd")
const Manifest = preload("res://addons/feng-magic-gi/feng_magic_gi_manifest.gd")
const Baker = preload("res://addons/feng-magic-gi/feng_magic_gi_baker.gd")
const Binding = preload("res://addons/feng-magic-gi/feng_magic_gi_emitter_binding.gd")
const SceneTracker = preload("res://addons/feng-magic-gi/feng_magic_gi_scene_tracker.gd")
const ProbeLayout = preload("res://addons/feng-magic-gi/feng_magic_gi_probe_layout.gd")
const FIXTURE_DIRECTORY := "user://magic_gi_persistence_roundtrip"
const DATA_PATH := FIXTURE_DIRECTORY + "/watchless_legacy_data.res"
const SCENE_PATH := FIXTURE_DIRECTORY + "/unchanged_scene.tscn"
const CURRENT_DATA_PATH := FIXTURE_DIRECTORY + "/root_relative_data.res"
const CURRENT_SCENE_PATH := FIXTURE_DIRECTORY + "/root_relative_scene.tscn"
const RETAINED_LEGACY_DATA_PATH := FIXTURE_DIRECTORY + "/retained_legacy_data.res"
const CURRENT_MANIFEST_PATH := FIXTURE_DIRECTORY + "/current_manifest.res"
const LEGACY_MANIFEST_PATH := FIXTURE_DIRECTORY + "/legacy_manifest.res"
const CURRENT_MANIFEST_SCENE_PATH := FIXTURE_DIRECTORY + "/current_manifest_with_legacy_data.tscn"
const LEGACY_MANIFEST_SCENE_PATH := FIXTURE_DIRECTORY + "/legacy_manifest_with_legacy_data.tscn"

signal refresh_test_task_completed

var failures := 0
var checks := 0
var _refresh_test_results: Dictionary = {}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var arguments := OS.get_cmdline_user_args()
	if arguments.size() != 1:
		push_error("Expected exactly one mode: --write or --verify")
		quit(2)
		return
	if arguments[0] == "--write":
		_write_fixture()
	elif arguments[0] == "--verify":
		_verify_fixture()
	else:
		push_error("Unknown mode: " + arguments[0])
		quit(2)

func _create_scene() -> Dictionary:
	var scene := Node3D.new()
	scene.name = "MagicGIPersistenceScene"
	var volume := Volume.new()
	volume.name = "MagicGI"
	volume.show_probes = false
	volume.adaptive_placement = false
	volume.size = Vector3(4.0, 2.0, 4.0)
	volume.probe_spacing = 2.0
	volume.bake_samples = 64
	volume.bake_bounces = 1
	volume.bake_distance = 8.0
	volume.chunked_baking = false
	var ground := MeshInstance3D.new()
	ground.name = "Ground"
	var plane := PlaneMesh.new()
	plane.size = Vector2(4.0, 4.0)
	ground.mesh = plane
	scene.add_child(volume)
	scene.add_child(ground)
	volume.owner = scene
	ground.owner = scene
	root.add_child(scene)
	return {"scene": scene, "volume": volume, "ground": ground}

func _make_data(volume: Volume) -> Data:
	var placement := Placement.new()
	if not placement.collect(volume, true, true, true):
		push_error("placement collection failed: " + placement.error_message)
		return null
	if placement.positions.is_empty():
		push_error("persistence fixture unexpectedly has no probes")
		return null
	var data := Data.new()
	data.format_version = Data.FORMAT_VERSION
	data.grid_dims = volume.grid_dimensions()
	data.volume_size = volume.size
	data.spacing = volume.probe_spacing
	data.adaptive_placement = false
	data.minimum_probe_spacing = volume.minimum_probe_spacing
	data.surface_offset = volume.surface_offset
	data.volume_transform = volume.global_transform
	data.world_to_grid = volume.world_to_grid_transform()
	data.bake_samples = volume.bake_samples
	data.bake_bounces = volume.bake_bounces
	data.bake_distance = volume.bake_distance
	data.terrain_reflectance = volume.terrain_reflectance
	data.material_reflectance = volume.fallback_material_reflectance
	data.scene_signature = (Data.SAMPLER_REVISION << 32) \
			| (placement.scene_signature & 0xffffffff)
	data.placement_layout_revision = ProbeLayout.PLACEMENT_LAYOUT_REVISION
	data.scene_watch_signature = 0
	data.positions = placement.positions.duplicate()
	data.surface_positions = placement.surface_positions.duplicate()
	data.normals = placement.normals.duplicate()
	data.transfer.resize(data.probe_count() * 27)
	data.primary_sky_visibility.resize(data.probe_count() * 9)
	data.visibility_moments.resize(data.probe_count() * Data.VISIBILITY_TEXELS_PER_PROBE \
			* Data.VISIBILITY_MOMENT_CHANNELS)
	var blockers: Dictionary = Data.Visibility.build(placement.faces)
	if blockers.is_empty():
		push_error("could not build persistence fixture blockers")
		return null
	data.visibility_nodes = blockers.nodes
	data.visibility_triangles = blockers.triangles
	data.emitter_keys = placement.emitters.keys
	data.emitter_static_signatures = placement.emitters.static_signatures
	data.emitter_transport.resize(data.probe_count() * data.emitter_count() * 6)
	data.bake_version = 1
	if not data.build_cell_indices() or not data.is_valid():
		push_error("generated persistence fixture Data is invalid")
		return null
	return data

func _write_fixture() -> void:
	var absolute_directory := ProjectSettings.globalize_path(FIXTURE_DIRECTORY)
	if DirAccess.make_dir_recursive_absolute(absolute_directory) != OK:
		push_error("could not create persistence fixture directory")
		quit(1)
		return
	var nodes := _create_scene()
	var volume := nodes.volume as Volume
	var data := _make_data(volume)
	if data == null:
		quit(1)
		return
	var data_error := ResourceSaver.save(data, DATA_PATH, ResourceSaver.FLAG_COMPRESS)
	if data_error != OK:
		push_error("could not save .res fixture: " + error_string(data_error))
		quit(1)
		return
	volume.bake_data = ResourceLoader.load(DATA_PATH, "", ResourceLoader.CACHE_MODE_IGNORE) as Data
	var packed := PackedScene.new()
	var pack_error := packed.pack(nodes.scene)
	if pack_error != OK:
		push_error("could not pack persistence scene: " + error_string(pack_error))
		quit(1)
		return
	var scene_error := ResourceSaver.save(packed, SCENE_PATH)
	if scene_error != OK:
		push_error("could not save persistence scene: " + error_string(scene_error))
		quit(1)
		return
	var current_data := _make_data(volume)
	current_data.scene_watch_signature = SceneTracker.stable_scene_signature(volume)
	current_data.scene_watch_signature_schema_version = SceneTracker.SIGNATURE_SCHEMA_CURRENT
	var current_data_error := ResourceSaver.save(current_data, CURRENT_DATA_PATH,
			ResourceSaver.FLAG_COMPRESS)
	if current_data_error != OK:
		push_error("could not save current-schema .res fixture: " + error_string(current_data_error))
		quit(1)
		return
	volume.bake_data = ResourceLoader.load(CURRENT_DATA_PATH, "",
			ResourceLoader.CACHE_MODE_IGNORE) as Data
	var current_packed := PackedScene.new()
	var current_pack_error := current_packed.pack(nodes.scene)
	if current_pack_error != OK:
		push_error("could not pack current-schema persistence scene")
		quit(1)
		return
	var current_scene_error := ResourceSaver.save(current_packed, CURRENT_SCENE_PATH)
	if current_scene_error != OK:
		push_error("could not save current-schema scene: " + error_string(current_scene_error))
		quit(1)
		return
	if not _write_manifest_coexistence_fixtures(nodes.scene, volume):
		quit(1)
		return
	print("MAGIC_GI_PERSISTENCE_WRITE probes=", data.probe_count(),
		" data=", ProjectSettings.globalize_path(DATA_PATH),
		" scene=", ProjectSettings.globalize_path(SCENE_PATH),
		" current_data=", ProjectSettings.globalize_path(CURRENT_DATA_PATH),
		" current_scene=", ProjectSettings.globalize_path(CURRENT_SCENE_PATH),
		" current_manifest_scene=", ProjectSettings.globalize_path(CURRENT_MANIFEST_SCENE_PATH),
		" legacy_manifest_scene=", ProjectSettings.globalize_path(LEGACY_MANIFEST_SCENE_PATH))
	quit(0)

func _write_manifest_coexistence_fixtures(scene: Node3D, volume: Volume) -> bool:
	var saved_legacy_volume_identity := "/root/@EditorNode@5912/@SubViewport@391/%s/%s" % [
		scene.name, volume.name]
	var legacy_state := SceneTracker.legacy_manifest_source_signature(volume,
			saved_legacy_volume_identity)
	if not bool(legacy_state.get("valid", false)):
		push_error("could not build a legacy editor-path signature fixture")
		return false
	var retained_data := _make_data(volume)
	if retained_data == null:
		return false
	retained_data.scene_watch_signature = int(legacy_state.get("signature", 0))
	retained_data.scene_watch_signature_schema_version = SceneTracker.SIGNATURE_SCHEMA_LEGACY
	if ResourceSaver.save(retained_data, RETAINED_LEGACY_DATA_PATH,
			ResourceSaver.FLAG_COMPRESS) != OK:
		push_error("could not save retained legacy Data fixture")
		return false
	volume._bake_assigning_data = true
	volume.bake_data = retained_data
	volume._bake_assigning_data = false
	var settings_signature := Baker.new()._streamed_settings_signature(volume)
	var current_manifest := Manifest.new()
	current_manifest.generation = "current-with-retained-legacy-data"
	current_manifest.scene_identity = "res://tests/current_manifest_with_legacy_data.tscn"
	current_manifest.volume_identity = SceneTracker.scene_relative_path(volume)
	current_manifest.bake_settings_signature = settings_signature
	current_manifest.scene_watch_signature = SceneTracker.stable_scene_signature(volume)
	current_manifest.scene_watch_signature_schema_version = SceneTracker.SIGNATURE_SCHEMA_CURRENT
	current_manifest.configure([])
	if not _save_manifest_scene(scene, volume, current_manifest, CURRENT_MANIFEST_PATH,
			CURRENT_MANIFEST_SCENE_PATH):
		return false
	var legacy_manifest := Manifest.new()
	legacy_manifest.generation = "legacy-with-retained-legacy-data"
	legacy_manifest.scene_identity = "res://tests/legacy_manifest_with_legacy_data.tscn"
	legacy_manifest.volume_identity = saved_legacy_volume_identity
	legacy_manifest.bake_settings_signature = settings_signature
	legacy_manifest.scene_watch_signature = int(legacy_state.get("signature", 0))
	legacy_manifest.scene_watch_signature_schema_version = SceneTracker.SIGNATURE_SCHEMA_LEGACY
	legacy_manifest.configure([])
	return _save_manifest_scene(scene, volume, legacy_manifest, LEGACY_MANIFEST_PATH,
			LEGACY_MANIFEST_SCENE_PATH)

func _save_manifest_scene(scene: Node3D, volume: Volume, manifest: Manifest,
		manifest_path: String, scene_path: String) -> bool:
	if ResourceSaver.save(manifest, manifest_path, ResourceSaver.FLAG_COMPRESS) != OK:
		push_error("could not save Manifest fixture: " + manifest_path)
		return false
	volume._bake_assigning_manifest = true
	volume.bake_manifest = manifest
	volume._bake_assigning_manifest = false
	var packed := PackedScene.new()
	if packed.pack(scene) != OK:
		push_error("could not pack Manifest coexistence fixture: " + scene_path)
		return false
	if ResourceSaver.save(packed, scene_path) != OK:
		push_error("could not save Manifest coexistence scene: " + scene_path)
		return false
	return true

func _verify_fixture() -> void:
	var packed := ResourceLoader.load(SCENE_PATH, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	if packed == null:
		push_error("saved persistence scene could not be loaded in a fresh process")
		quit(1)
		return
	var scene := packed.instantiate()
	root.add_child(scene)
	await process_frame
	var volume := scene.get_node_or_null("MagicGI") as Volume
	var ground := scene.get_node_or_null("Ground") as MeshInstance3D
	_check(volume != null, "the saved scene must restore its Magic GI Volume")
	if volume == null:
		quit(1)
		return
	_check(volume.bake_data != null and volume.bake_data.scene_watch_signature == 0,
		"the .res fixture must exercise a pre-watch legacy bake")
	_check(volume.has_usable_bake(), "the reloaded legacy .res must remain structurally valid")
	_check(not volume._source_watch_stale and not volume._layout_stale and not volume._layout_dirty,
		"an unchanged loaded scene must finish initialization without marking its saved bake stale")
	_check(Data.geometry_signature_matches(volume.bake_data.scene_signature,
		volume._current_scene_signature),
		"the pre-watch .res geometry fingerprint must match after a process restart")
	_check(Data.sampler_revision_for_signature(volume.bake_data.scene_signature) == Data.SAMPLER_REVISION,
		"the persisted bake must identify the current sampler revision separately from geometry")
	_check(volume.bake_data.matches_layout(volume.size, volume.probe_spacing,
		volume.surface_offset, volume.global_transform, volume.bake_samples,
		volume.bake_bounces, volume.bake_distance, volume.terrain_reflectance,
		volume.fallback_material_reflectance),
		"the serialized bake settings and transform must remain unchanged")
	_check(volume.has_bake() and not volume.needs_rebake(),
		"an unchanged saved scene must retain its bake across a process restart")
	var current_packed := ResourceLoader.load(CURRENT_SCENE_PATH, "",
			ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	_check(current_packed != null,
		"the current-schema saved scene must load in a fresh process")
	if current_packed != null:
		var current_scene := current_packed.instantiate()
		root.add_child(current_scene)
		await process_frame
		var current_volume := current_scene.get_node_or_null("MagicGI") as Volume
		_check(current_volume != null and current_volume.bake_data != null,
			"the current-schema scene must restore its Data resource")
		if current_volume != null and current_volume.bake_data != null:
			await current_volume._settle_layout_change()
			_check(current_volume.bake_data.scene_watch_signature_schema_version
					== SceneTracker.SIGNATURE_SCHEMA_CURRENT,
				"the persisted current-schema marker must survive Data and scene serialization")
			_check(current_volume.bake_data.placement_layout_revision
					== ProbeLayout.PLACEMENT_LAYOUT_REVISION,
				"the placement revision must survive direct Data and scene serialization")
			_check(current_volume.has_bake() and not current_volume.needs_rebake(),
				"a current root-relative Data bake must validate in a fresh process")
			await _verify_layout_revision_stales_watched_data(current_volume)
	await _verify_manifest_coexistence_fixture(CURRENT_MANIFEST_SCENE_PATH,
			SceneTracker.SIGNATURE_SCHEMA_CURRENT)
	await _verify_manifest_coexistence_fixture(LEGACY_MANIFEST_SCENE_PATH,
			SceneTracker.SIGNATURE_SCHEMA_LEGACY)
	await _verify_layout_revision_stales_legacy_data(volume)
	var emissive_surface := MeshInstance3D.new()
	emissive_surface.name = "LateEmissive"
	emissive_surface.mesh = BoxMesh.new()
	var emissive_material := StandardMaterial3D.new()
	emissive_material.emission_enabled = true
	emissive_material.emission = Color.RED
	emissive_surface.material_override = emissive_material
	scene.add_child(emissive_surface)
	var ground_material := StandardMaterial3D.new()
	ground.material_override = ground_material
	var late_data := _make_data(volume)
	late_data.scene_watch_signature = SceneTracker.stable_scene_signature(volume)
	late_data.scene_watch_signature_schema_version = SceneTracker.SIGNATURE_SCHEMA_CURRENT
	_check(late_data.scene_watch_signature > 0,
		"the late Data fixture must carry a watch signature rather than use legacy geometry fallback")
	volume.bake_data = late_data
	await process_frame
	_check(volume._current_stable_source_signature == late_data.scene_watch_signature,
		"late Data assignment must validate after the deferred scene-load boundary")
	await volume._settle_layout_change()
	_check(volume.has_bake() and not volume.needs_rebake(),
		"a watch-bearing Data assigned after tree entry must validate at the settled scene boundary")
	var data_revision_before_runtime := volume.data_revision()
	var initial_bake_version := late_data.bake_version
	Runtime.publish(volume)
	var initial_runtime_snapshot := _published_snapshot_for(volume)
	_check(not initial_runtime_snapshot.is_empty(),
		"a valid legacy Data resource must publish a runtime snapshot")
	var initial_cache_key := str(initial_runtime_snapshot.get("cache_key", ""))
	var initial_runtime_version := int(initial_runtime_snapshot.get("version", -1))
	var initial_emission_payload: PackedFloat32Array = initial_runtime_snapshot.get(
		"emission_payload", PackedFloat32Array())
	initial_emission_payload = initial_emission_payload.duplicate()
	var saved_strength := volume.gi_strength
	var saved_size := volume.size
	volume.gi_strength = saved_strength + 0.25
	volume.size = saved_size + Vector3(0.25, 0.0, 0.0)
	_check(volume.data_revision() == data_revision_before_runtime,
		"strength and layout edits must leave the Data revision unchanged")
	Runtime.publish(volume)
	var layout_runtime_snapshot := _published_snapshot_for(volume)
	_check(str(layout_runtime_snapshot.get("cache_key", "")) == initial_cache_key
			and int(layout_runtime_snapshot.get("version", -1)) == initial_runtime_version,
		"strength and layout edits must keep warm bake-resource cache identities")
	volume.gi_strength = saved_strength
	volume.size = saved_size
	await volume._settle_layout_change()
	var saved_transfer_value := late_data.transfer[0]
	late_data.transfer[0] = saved_transfer_value + 0.125
	late_data.emitter_transport[0] = 0.125
	late_data.emit_changed()
	_check(volume.data_revision() == data_revision_before_runtime + 1,
		"Data.changed must increment the public Data revision once")
	_check(late_data.bake_version == initial_bake_version and late_data.is_valid()
			and volume.has_usable_bake(),
		"same-version changed Data must remain structurally valid and renderable")
	_check(not late_data.make_render_upload().is_empty(),
		"same-version changed Data must still produce a runtime upload bundle")
	Runtime.publish(volume)
	var changed_runtime_snapshot := _published_snapshot_for(volume)
	_check(str(changed_runtime_snapshot.get("cache_key", "")) != initial_cache_key
			and int(changed_runtime_snapshot.get("version", -1)) != initial_runtime_version,
		"same-resource changed Data must publish new version and GPU cache identities")
	_check(changed_runtime_snapshot.get("emission_payload", PackedFloat32Array())
			!= initial_emission_payload,
		"same-version emitter transport changes must refresh the live composed emission payload")
	Runtime.publish(volume)
	Runtime.tick()
	var unchanged_runtime_snapshot := _published_snapshot_for(volume)
	_check(str(unchanged_runtime_snapshot.get("cache_key", ""))
			== str(changed_runtime_snapshot.get("cache_key", ""))
			and int(unchanged_runtime_snapshot.get("version", -1))
			== int(changed_runtime_snapshot.get("version", -1)),
		"repeated publishes without Data changes must keep the cache identity stable")
	await volume._settle_layout_change()
	var quick_before_live_edits := SceneTracker.quick_source_signature_uncached(volume)
	var stable_before_live_edits := SceneTracker.stable_scene_signature(volume)
	var strict_before_live_edits := SceneTracker.bake_content_signature(volume)
	var emitter_static_before_live_edits := Binding.static_signature(
		emissive_surface, 0, emissive_material)
	emissive_material.emission_enabled = false
	_check(SceneTracker.quick_source_signature_uncached(volume) == quick_before_live_edits,
		"ordinary source polling must ignore an already baked emitter toggle")
	_check(SceneTracker.stable_scene_signature(volume) == stable_before_live_edits,
		"persisted source validation must ignore an already baked emitter toggle")
	_check(SceneTracker.bake_content_signature(volume) != strict_before_live_edits,
		"in-flight bake content checks must still see an emitter toggle")
	volume._schedule_saved_source_validation()
	volume._run_saved_source_validation()
	_check(volume.has_bake() and not volume.needs_rebake(),
		"disabling an already baked emitter must not mark its source stale")
	emissive_material.emission_enabled = true
	emissive_material.emission = Color.BLUE
	emissive_material.emission_energy_multiplier = 3.0
	emissive_material.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY
	emissive_material.roughness = 0.05
	emissive_material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	var strict_after_live_edits := SceneTracker.bake_content_signature(volume)
	_check(SceneTracker.quick_source_signature_uncached(volume) == quick_before_live_edits,
		"ordinary source polling must ignore live emission and roughness/specular edits")
	_check(SceneTracker.stable_scene_signature(volume) == stable_before_live_edits,
		"persisted source validation must ignore live emission and roughness/specular edits")
	_check(Binding.static_signature(emissive_surface, 0, emissive_material)
			== emitter_static_before_live_edits,
		"emitter bindings must retain their static mapping when only live radiance changes")
	_check(strict_after_live_edits != strict_before_live_edits,
		"in-flight bake content checks must still see live material/resource edits")
	volume._schedule_saved_source_validation()
	volume._run_saved_source_validation()
	_check(volume.has_bake() and not volume.needs_rebake(),
		"valid live emission and roughness edits must not mark a saved bake stale")
	_check(volume.has_usable_bake(), "the saved Data cache must be populated before changed()")
	var saved_bake_version := late_data.bake_version
	late_data.bake_version = 0
	late_data.emit_changed()
	_check(not volume.has_usable_bake(),
		"Data.changed must discard cached structural validity when the payload becomes invalid")
	late_data.bake_version = saved_bake_version
	late_data.emit_changed()
	_check(volume.has_usable_bake(),
		"Data.changed must revalidate restored structural payload after invalidation")
	late_data.scene_watch_signature += 1
	late_data.emit_changed()
	volume._schedule_saved_source_validation()
	volume._run_saved_source_validation()
	_check(volume._source_watch_stale and volume.needs_rebake(),
		"Data.changed must compare its saved source signature with the current scene")
	late_data.scene_watch_signature = stable_before_live_edits
	late_data.emit_changed()
	volume._schedule_saved_source_validation()
	volume._run_saved_source_validation()
	await volume._settle_layout_change()
	_check(volume.has_bake() and not volume.needs_rebake(),
		"restoring a matching source signature must clear the changed-resource stale state")
	var static_signature := SceneTracker.stable_scene_signature(volume)
	ground_material.albedo_color = Color(0.35, 0.55, 0.75, 1.0)
	_check(SceneTracker.stable_scene_signature(volume) != static_signature,
		"stable source signatures must include transport-relevant albedo changes")
	volume._schedule_saved_source_validation()
	volume._run_saved_source_validation()
	_check(volume._source_watch_stale and volume.needs_rebake(),
		"a real static material edit must keep the saved bake stale")
	ground_material.albedo_color = Color.WHITE
	var saved_preview_positions := volume.probe_positions.duplicate()
	var refresh_succeeded := await volume.refresh_surface_points()
	_check(volume.has_bake() and not volume.needs_rebake(),
		"explicit refresh must revalidate restored static source content")
	_check(refresh_succeeded and volume.candidate_probe_count() == late_data.probe_count()
			and volume.is_candidate_layout_current(),
		"explicit Refresh must collect the current candidate surface layout")
	_check(volume.probe_positions == saved_preview_positions,
		"candidate Refresh must keep saved world anchors paired with their old bake")
	var late_manifest_volume := Volume.new()
	late_manifest_volume.name = "LateManifestVolume"
	late_manifest_volume.show_probes = false
	scene.add_child(late_manifest_volume)
	await process_frame
	var late_manifest := Manifest.new()
	late_manifest.generation = "late-assignment"
	late_manifest.scene_watch_signature = SceneTracker.stable_scene_signature(late_manifest_volume)
	late_manifest.scene_watch_signature_schema_version = SceneTracker.SIGNATURE_SCHEMA_CURRENT
	_check(late_manifest.scene_watch_signature > 0,
		"the late Manifest fixture must carry a persisted source signature")
	late_manifest.bake_settings_signature = Baker.new()._streamed_settings_signature(late_manifest_volume)
	late_manifest.configure([])
	late_manifest_volume.bake_manifest = late_manifest
	await process_frame
	_check(late_manifest_volume._current_stable_source_signature == late_manifest.scene_watch_signature,
		"late Manifest assignment must validate after the deferred scene-load boundary")
	await late_manifest_volume._settle_layout_change()
	_check(late_manifest_volume.has_bake() and not late_manifest_volume.needs_rebake(),
		"a watch-bearing Manifest assigned after tree entry must validate at the settled scene boundary")
	var saved_manifest := late_manifest_volume.bake_manifest
	var copied_manifest := saved_manifest.duplicate(true) as Manifest
	_check(copied_manifest.scene_watch_signature_schema_version
			== SceneTracker.SIGNATURE_SCHEMA_CURRENT,
		"deep Manifest copies must preserve the source-signature schema marker")
	var manifest_refresh_succeeded := await late_manifest_volume.refresh_surface_points()
	_check(manifest_refresh_succeeded and late_manifest_volume.candidate_probe_count() > 0
			and late_manifest_volume.bake_manifest == saved_manifest
			and late_manifest_volume.has_bake(),
		"streamed Refresh must produce candidate points while retaining the active manifest")
	_refresh_test_results.clear()
	_request_refresh_for_test(late_manifest_volume, "superseded")
	_request_refresh_for_test(late_manifest_volume, "latest")
	while _refresh_test_results.size() < 2:
		await refresh_test_task_completed
	_check(not bool(_refresh_test_results.get("superseded", true))
			and bool(_refresh_test_results.get("latest", false)),
		"repeated Refresh requests must keep one active job and complete only the latest token")
	var retained_candidates := late_manifest_volume.candidate_probe_count()
	_refresh_test_results.clear()
	_request_refresh_for_test(late_manifest_volume, "canceled")
	late_manifest_volume.cancel_bake()
	while _refresh_test_results.size() < 1:
		await refresh_test_task_completed
	_check(not bool(_refresh_test_results.get("canceled", true))
			and late_manifest_volume.candidate_probe_count() == retained_candidates
			and late_manifest_volume.bake_manifest == saved_manifest,
		"canceling a pending Refresh must not write a partial candidate or replace the bake")
	# Force one active worker with private captured geometry, then supersede it.
	# The next request is processed serially after cancellation and must be the
	# only request that commits a candidate revision.
	late_manifest_volume.set_process(false)
	var dense_mesh := _make_refresh_cancellation_mesh()
	var dense_instance := MeshInstance3D.new()
	dense_instance.name = "RefreshCancellationGeometry"
	dense_instance.mesh = dense_mesh
	scene.add_child(dense_instance)
	var candidate_revision_before_cancel := late_manifest_volume._candidate_layout_revision
	_refresh_test_results.clear()
	_request_refresh_for_test(late_manifest_volume, "worker-canceled")
	var worker_started := false
	for frame in 600:
		if late_manifest_volume.surface_refresh_progress().contains(
				"Building geometry and placing probes"):
			worker_started = true
			break
		await process_frame
	_check(worker_started,
		"the cancellation regression must observe the refresh worker after geometry capture")
	if worker_started:
		_request_refresh_for_test(late_manifest_volume, "latest-after-cancel")
		scene.remove_child(dense_instance)
		dense_instance.free()
	while _refresh_test_results.size() < 2:
		await refresh_test_task_completed
	_check(not bool(_refresh_test_results.get("worker-canceled", true))
			and bool(_refresh_test_results.get("latest-after-cancel", false)),
		"a superseded active worker must cancel and let the latest Refresh finish")
	_check(late_manifest_volume._candidate_layout_revision
			== candidate_revision_before_cancel + 1,
		"a canceled worker must not publish a partial candidate layout")
	_check(late_manifest_volume.bake_manifest == saved_manifest
			and late_manifest_volume.has_bake(),
		"worker cancellation and replacement must preserve the active streamed bake")
	late_manifest_volume.set_process(true)
	var saved_world_positions := volume.probe_positions.duplicate()
	_check(not saved_world_positions.is_empty(), "the reloaded bake must restore its world-space probe anchors")
	var old_sampler_data := volume.bake_data.duplicate(true) as Data
	_check(old_sampler_data.scene_watch_signature_schema_version
			== SceneTracker.SIGNATURE_SCHEMA_CURRENT,
		"deep Data copies must preserve the source-signature schema marker")
	var matching_geometry := volume._current_scene_signature
	old_sampler_data.scene_signature = ((Data.SAMPLER_REVISION - 1) << 32) \
			| (volume.bake_data.scene_signature & 0xffffffff)
	volume.bake_data = old_sampler_data
	volume._scene_signature_checked = true
	volume._exact_scene_signature_available = true
	volume._current_scene_signature = matching_geometry
	volume._source_watch_stale = false
	volume._layout_dirty = false
	volume._layout_stale = false
	_check(volume.has_usable_bake(), "a structurally valid older-sampler bake must remain readable")
	_check(volume.has_legacy_sampler_signature(), "an older sampler revision must remain independently detectable")
	_check(not volume.has_bake() and volume.needs_rebake(),
		"an older sampler revision must request rebaking without invalidating its usable data")
	_check("sampler revision" in "; ".join(volume.bake_staleness_reasons()),
		"the inspector staleness reason must preserve the sampler-version explanation")
	volume.position += Vector3(1.0, 0.0, 0.0)
	volume.force_update_transform()
	await process_frame
	_check(volume.probe_positions == saved_world_positions and volume.is_layout_stale(),
		"moving the Volume must leave old baked world anchors visible and mark them stale")
	await _verify_signature_schema_contract()
	var direct_bake_succeeded := await volume.bake()
	_check(direct_bake_succeeded and volume.bake_data != null
			and volume.bake_data.placement_layout_revision
			== ProbeLayout.PLACEMENT_LAYOUT_REVISION,
			"a real direct CPU bake must stamp the current probe placement revision")
	print("MAGIC_GI_PERSISTENCE_VERIFY checks=", checks, " failures=", failures,
		" probes=", saved_world_positions.size())
	quit(1 if failures else 0)

func _verify_manifest_coexistence_fixture(scene_path: String,
		expected_schema: int) -> void:
	var packed := ResourceLoader.load(scene_path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	_check(packed != null, "a saved Manifest-plus-legacy-Data scene must reload in a fresh process")
	if packed == null:
		return
	var scene := packed.instantiate()
	root.add_child(scene)
	await process_frame
	var volume := scene.get_node_or_null("MagicGI") as Volume
	_check(volume != null and volume.bake_manifest != null and volume.bake_data != null,
		"a streamed Manifest must reload alongside its retained legacy Data resource")
	if volume == null or volume.bake_manifest == null or volume.bake_data == null:
		return
	_check(volume.bake_data.scene_watch_signature_schema_version
			== SceneTracker.SIGNATURE_SCHEMA_LEGACY,
		"the coexistence fixture must retain pre-schema Data")
	_check(volume.bake_manifest.scene_watch_signature_schema_version == expected_schema,
		"the reloaded Manifest must preserve its explicit signature schema")
	await volume._settle_layout_change()
	_check(volume._current_stable_source_signature == volume.bake_manifest.scene_watch_signature
			and not volume._source_watch_stale,
		"the active Manifest signature must validate independently of retained legacy Data")
	_check(volume.has_bake() and not volume.needs_rebake(),
		"the public bake state must accept an active Manifest with retained legacy Data")
	var current_manifest := volume.bake_manifest
	var old_layout_manifest := current_manifest.duplicate(true) as Manifest
	old_layout_manifest.bake_settings_signature = _legacy_streamed_settings_signature(volume)
	volume._bake_assigning_manifest = true
	volume.bake_manifest = old_layout_manifest
	volume._bake_assigning_manifest = false
	volume._schedule_saved_source_validation(true)
	await process_frame
	await volume._settle_layout_change()
	_check(old_layout_manifest.is_valid() and volume.has_usable_bake(),
			"a pre-layout-revision Manifest must remain structurally usable")
	_check(not volume.has_bake() and volume.needs_rebake(),
			"a pre-layout-revision Manifest must request a new placement bake")
	volume._bake_assigning_manifest = true
	volume.bake_manifest = current_manifest
	volume._bake_assigning_manifest = false
	volume._schedule_saved_source_validation(true)
	await process_frame
	await volume._settle_layout_change()
	_check(volume.has_bake() and not volume.needs_rebake(),
			"restoring the current layout signature must validate the Manifest again")
	var fallback_data := _make_data(volume)
	if fallback_data == null:
		return
	fallback_data.scene_watch_signature = SceneTracker.stable_scene_signature(volume)
	fallback_data.scene_watch_signature_schema_version = SceneTracker.SIGNATURE_SCHEMA_CURRENT
	volume._bake_assigning_data = true
	volume.bake_data = fallback_data
	volume._bake_assigning_data = false
	volume._bake_assigning_manifest = true
	volume.bake_manifest = null
	volume._bake_assigning_manifest = false
	volume._schedule_saved_source_validation(true)
	await process_frame
	await volume._settle_layout_change()
	_check(volume.has_bake() and not volume.needs_rebake(),
		"clearing the active Manifest must correctly fall back to a matching Data bake")

func _verify_layout_revision_stales_legacy_data(volume: Volume) -> void:
	var placement := Placement.new()
	_check(placement.collect(volume, true, true, true),
			"the layout-version fixture must collect the current geometry")
	if placement.positions.is_empty():
		return
	var current_data := volume.bake_data
	_check(current_data.scene_watch_signature == 0,
			"the layout-version fixture must explicitly cover the watchless legacy Data path")
	_check(Data.geometry_signature_matches(current_data.scene_signature,
			placement.scene_signature),
			"the watchless fixture geometry must match before changing only its layout revision")
	var original_scene_signature := current_data.scene_signature
	var original_watch_signature := current_data.scene_watch_signature
	current_data.placement_layout_revision = 0
	current_data.emit_changed()
	_check(current_data.is_valid(),
			"a structurally valid old-layout Data resource must remain readable")
	await process_frame
	await volume._settle_layout_change()
	_check(volume.has_usable_bake() and not volume.has_bake() and volume.needs_rebake(),
			"a pre-layout-revision Data resource must stay usable and request rebaking")
	_check(current_data.scene_signature == original_scene_signature
			and current_data.scene_watch_signature == original_watch_signature,
			"the watchless staleness case must preserve both saved source signatures")
	current_data.placement_layout_revision = ProbeLayout.PLACEMENT_LAYOUT_REVISION
	current_data.emit_changed()
	await process_frame
	await volume._settle_layout_change()
	_check(volume.has_bake() and not volume.needs_rebake(),
			"restoring the current placement fingerprint must validate direct Data again")

func _verify_layout_revision_stales_watched_data(volume: Volume) -> void:
	var current_data := volume.bake_data
	_check(current_data.scene_watch_signature > 0
			and current_data.placement_layout_revision == ProbeLayout.PLACEMENT_LAYOUT_REVISION,
			"the watched regression must change only placement_layout_revision")
	var original_scene_signature := current_data.scene_signature
	var original_watch_signature := current_data.scene_watch_signature
	current_data.placement_layout_revision = 0
	current_data.emit_changed()
	_check(current_data.is_valid(),
			"an old-layout watched Data resource must remain structurally valid")
	await process_frame
	await volume._settle_layout_change()
	_check(volume.has_usable_bake() and not volume.has_bake() and volume.needs_rebake(),
			"a source-watched old-layout Data resource must remain usable and request rebaking")
	_check("placement layout revision" in "; ".join(volume.bake_staleness_reasons()),
			"the inspector must explain the placement-layout staleness")
	_check(current_data.scene_signature == original_scene_signature
			and current_data.scene_watch_signature == original_watch_signature,
			"the watched staleness case must preserve both saved source signatures")
	current_data.placement_layout_revision = ProbeLayout.PLACEMENT_LAYOUT_REVISION
	current_data.emit_changed()
	await process_frame
	await volume._settle_layout_change()
	_check(volume.has_bake() and not volume.needs_rebake(),
			"restoring a current layout marker must validate source-watched Data again")

func _legacy_streamed_settings_signature(volume: Volume) -> int:
	return hash([volume.global_transform, volume.size, volume.probe_spacing,
		volume.minimum_probe_spacing, volume.surface_offset, volume.adaptive_placement,
		volume.bake_samples, volume.bake_bounces, volume.bake_distance,
		volume.terrain_reflectance, volume.fallback_material_reflectance,
		volume.management_block_size, volume.core_page_size, volume.clv_cell_size])

func _verify_signature_schema_contract() -> void:
	var editor_fixture := _make_signature_fixture("EditorLikeSceneRoot")
	var runtime_fixture := _make_signature_fixture("RuntimeSceneRoot")
	await process_frame
	var editor_volume := editor_fixture.volume as Volume
	var runtime_volume := runtime_fixture.volume as Volume
	var editor_ground := editor_fixture.ground as MeshInstance3D
	var runtime_ground := runtime_fixture.ground as MeshInstance3D
	var current_signature := SceneTracker.stable_scene_signature(editor_volume)
	_check(current_signature > 0
			and current_signature == SceneTracker.stable_scene_signature(runtime_volume),
		"root-relative signatures must survive different editor/runtime Viewport prefixes")
	var current_state := SceneTracker.data_source_signature(runtime_volume,
			SceneTracker.SIGNATURE_SCHEMA_CURRENT)
	_check(bool(current_state.get("valid", false))
			and int(current_state.get("signature", 0)) == current_signature,
		"current Data validation must use the same root-relative content fingerprint")
	var old_volume_identity := String(editor_volume.get_path())
	var old_signature := SceneTracker.legacy_absolute_scene_signature(editor_volume)
	var legacy_manifest_state := SceneTracker.manifest_source_signature(runtime_volume,
			SceneTracker.SIGNATURE_SCHEMA_LEGACY, old_volume_identity)
	_check(bool(legacy_manifest_state.get("valid", false))
			and int(legacy_manifest_state.get("signature", 0)) == old_signature,
		"legacy Manifest validation must reconstruct its original absolute scene-root prefix")
	var legacy_data_state := SceneTracker.data_source_signature(runtime_volume,
			SceneTracker.SIGNATURE_SCHEMA_LEGACY)
	_check(bool(legacy_data_state.get("valid", false))
			and int(legacy_data_state.get("signature", 0)) != old_signature,
		"legacy direct Data must retain current absolute-path validation without migration")
	var unknown_state := SceneTracker.manifest_source_signature(runtime_volume, 999,
			old_volume_identity)
	_check(not bool(unknown_state.get("valid", false)),
		"unknown future signature schemas must fail closed")
	var baseline := SceneTracker.stable_scene_signature(runtime_volume)
	runtime_ground.name = "RenamedGround"
	_check(SceneTracker.stable_scene_signature(runtime_volume) != baseline,
		"changing a source node's scene-relative path must invalidate the fingerprint")
	runtime_ground.name = "Ground"
	var box := runtime_ground.mesh as BoxMesh
	box.size.x += 0.25
	_check(SceneTracker.stable_scene_signature(runtime_volume) != baseline,
		"changing source mesh geometry must invalidate the fingerprint")
	box.size.x -= 0.25
	var material := runtime_ground.material_override as StandardMaterial3D
	material.albedo_color = Color(0.35, 0.55, 0.75, 1.0)
	_check(SceneTracker.stable_scene_signature(runtime_volume) != baseline,
		"changing static source material content must invalidate the fingerprint")
	material.albedo_color = Color.WHITE
	_check(SceneTracker.stable_scene_signature(runtime_volume) == baseline,
		"restoring source path, mesh and material content must restore the fingerprint")
	editor_fixture.scene.queue_free()
	runtime_fixture.scene.queue_free()
	await process_frame

func _make_signature_fixture(root_name: String) -> Dictionary:
	var scene := Node3D.new()
	scene.name = root_name
	var volume := Volume.new()
	volume.name = "Volume"
	volume.show_probes = false
	volume.size = Vector3(4.0, 4.0, 4.0)
	volume.bake_distance = 2.0
	var ground := MeshInstance3D.new()
	ground.name = "Ground"
	ground.mesh = BoxMesh.new()
	var material := StandardMaterial3D.new()
	ground.material_override = material
	scene.add_child(volume)
	scene.add_child(ground)
	root.add_child(scene)
	return {"scene": scene, "volume": volume, "ground": ground}

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)

func _request_refresh_for_test(volume: Volume, result_key: String) -> void:
	var succeeded: bool = await volume.refresh_surface_points()
	_refresh_test_results[result_key] = succeeded
	refresh_test_task_completed.emit()

func _make_refresh_cancellation_mesh() -> ArrayMesh:
	var vertices := PackedVector3Array()
	const CELLS := 32
	const EXTENT := 3.8
	var step := EXTENT / float(CELLS)
	for z in CELLS:
		for x in CELLS:
			var left := -EXTENT * 0.5 + float(x) * step
			var near := -EXTENT * 0.5 + float(z) * step
			var a := Vector3(left, 0.25, near)
			var b := Vector3(left + step, 0.25, near)
			var c := Vector3(left, 0.25, near + step)
			var d := Vector3(left + step, 0.25, near + step)
			vertices.append_array([a, c, b, b, c, d])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

func _published_snapshot_for(volume: Volume) -> Dictionary:
	for snapshot in Runtime.snapshots():
		if int(snapshot.get("volume_id", -1)) == volume.get_instance_id():
			return snapshot
	return {}
