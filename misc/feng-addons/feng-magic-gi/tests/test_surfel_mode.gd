extends SceneTree
## CPU contracts for the realtime mode selector and bounded surfel settings.

const Volume = preload("res://addons/feng-magic-gi/feng_magic_gi_volume.gd")
const Settings = preload("res://addons/feng-magic-gi/feng_magic_gi_surfel_settings.gd")
const Runtime = preload("res://addons/feng-magic-gi/feng_magic_gi_runtime.gd")
const Data = preload("res://addons/feng-magic-gi/feng_magic_gi_data.gd")
const Manifest = preload("res://addons/feng-magic-gi/feng_magic_gi_manifest.gd")
const RESTORE_FIXTURE_DIRECTORY := "user://surfel_mode_restore"
const RESTORE_DATA_PATH := RESTORE_FIXTURE_DIRECTORY + "/saved_prt_data.res"
const RESTORE_DATA_SCENE_PATH := RESTORE_FIXTURE_DIRECTORY + "/surfel_with_prt_data.tscn"
const RESTORE_MANIFEST_SCENE_PATH := RESTORE_FIXTURE_DIRECTORY + "/surfel_with_manifest_and_prt_data.tscn"

class RefreshCanceler:
	extends Node
	var canceled := false
	func cancel() -> void:
		canceled = true

var failures := 0
var checks := 0

func require(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var first := Volume.new()
	var second := Volume.new()
	require(first.gi_mode == Volume.GIMode.PRT_MAGIC_GI,
		"old Volume resources default to the PRT mode")
	require(first.surfel_settings != null and first.surfel_settings != second.surfel_settings,
		"each Volume receives an independent default surfel settings resource")
	require(_property_has_usage(first, "surfel_settings", PROPERTY_USAGE_STORAGE) \
			and not _property_has_usage(first, "surfel_settings", PROPERTY_USAGE_EDITOR),
		"PRT mode keeps surfel settings stored without exposing them in its inspector")
	first.gi_mode = Volume.GIMode.SURFEL_MAGIC_GI
	require(_property_has_usage(first, "surfel_settings", PROPERTY_USAGE_EDITOR) \
			and not _property_has_usage(first, "probe_spacing", PROPERTY_USAGE_EDITOR) \
			and _property_has_usage(first, "probe_spacing", PROPERTY_USAGE_STORAGE),
		"Surfel mode exposes its settings and hides PRT settings without discarding them")
	require(not _property_has_usage(first, "Runtime Cache", PROPERTY_USAGE_GROUP) \
			and not _property_has_usage(first, "Paged Baking", PROPERTY_USAGE_GROUP) \
			and not _property_has_usage(first, "Page Streaming", PROPERTY_USAGE_GROUP),
		"Surfel mode hides empty PRT-only Inspector group headers")
	first.gi_mode = Volume.GIMode.PRT_MAGIC_GI
	var settings: Settings = first.surfel_settings
	require(settings.to_runtime_settings() == {
		"surfel_radius": 0.15,
		"max_surfels": 65536,
		"updates_per_frame": 2048,
		"rays_per_surfel": 4,
		"max_ray_distance": 128.0,
		"history_weight": 0.9,
		"debug_view": 0,
	}, "the serialized defaults produce the frozen plain-value runtime settings")
	settings.surfel_radius = NAN
	settings.max_surfels = 1
	settings.updates_per_frame = 999999
	settings.rays_per_surfel = 0
	settings.max_ray_distance = INF
	settings.history_weight = NAN
	settings.debug_view = 9
	var bounded := settings.to_runtime_settings()
	require(bounded["surfel_radius"] == 0.15 and bounded["max_surfels"] == 1024 \
			and bounded["updates_per_frame"] == 16384 and bounded["rays_per_surfel"] == 1 \
			and bounded["max_ray_distance"] == 128.0 and bounded["history_weight"] == 0.9 \
			and bounded["debug_view"] == 3,
		"non-finite and out-of-range values are clamped to finite hard limits")

	var scene := Node3D.new()
	root.add_child(scene)
	var volume := Volume.new()
	var saved_data := Data.new()
	var saved_manifest := Manifest.new()
	volume.bake_data = saved_data
	volume.bake_manifest = saved_manifest
	volume.show_probes = false
	volume.gi_mode = Volume.GIMode.SURFEL_MAGIC_GI
	scene.add_child(volume)
	await process_frame
	require(volume.candidate_probe_count() == 0 and volume.probe_count() == 0 \
			and not volume._scene_signature_checked and volume._viz == null,
		"Surfel mode does not start PRT placement, source validation, or probe preview work")
	require(volume._get_configuration_warnings().is_empty() \
			and Runtime.preview_snapshot(volume).is_empty() \
			and Runtime.emission_warning(volume).is_empty(),
		"Surfel mode suppresses PRT stale warnings, preview data, and emission diagnostics")
	require(not await volume.refresh_surface_points(),
		"surface refresh is unavailable in Surfel mode")
	require(not await volume.bake(), "offline PRT bake is unavailable in Surfel mode")

	Runtime.publish(volume)
	var snapshot := _snapshot_for_volume(volume.get_instance_id())
	require(not snapshot.is_empty(), "Surfel mode publishes without a PRT bake resource")
	if not snapshot.is_empty():
		require(int(snapshot.get("mode", -1)) == Volume.GIMode.SURFEL_MAGIC_GI \
				and bool(snapshot.get("surfel", false)) and snapshot.get("data") == null,
			"the snapshot identifies the surfel path and carries no bake data")
		require(snapshot.get("surfel_settings", {}).size() == 7 \
				and snapshot.get("cache_key", "") == "surfel:%d" % volume.get_instance_id() \
				and bool(snapshot.get("replacement_enabled", false)) \
				and snapshot.has("owner_transform") and snapshot.has("owner_size") \
				and snapshot.has("world_id") and snapshot.has("render_targets"),
			"the runtime snapshot carries bounded settings and a volume-scoped cache key")
		require(snapshot.get("version", 0) == hash([volume.global_transform,
				volume.size, snapshot.get("surfel_settings", {})]),
			"cache version tracks the current volume bounds and surfel settings")
		require(snapshot.get("layout_version", 0) == hash([volume.global_transform,
				volume.size, 0.15, 65536]),
			"layout version tracks only bounds and surfel allocation settings")
		var original_version: int = snapshot.get("version", 0)
		var original_layout_version: int = snapshot.get("layout_version", 0)
		volume.surfel_settings.updates_per_frame = 3072
		volume.surfel_settings.history_weight = 0.8
		volume.surfel_settings.debug_view = 2
		var updated := _snapshot_for_volume(volume.get_instance_id())
		require(not updated.is_empty() and updated.get("version", 0) != original_version,
			"any surfel setting change republishes the settings version")
		require(updated.get("layout_version", 0) == original_layout_version,
			"update-budget, history, and debug changes do not invalidate layout history")
		volume.surfel_settings.max_surfels = 131072
		var resized_capacity := _snapshot_for_volume(volume.get_instance_id())
		require(resized_capacity.get("layout_version", 0) != original_layout_version,
			"maximum surfel count changes invalidate the layout allocation")
		volume.surfel_settings.surfel_radius = 0.2
		var relaid := _snapshot_for_volume(volume.get_instance_id())
		require(relaid.get("version", 0) != resized_capacity.get("version", 0) \
				and relaid.get("layout_version", 0) != original_layout_version,
			"surfel radius changes invalidate both settings and layout versions")
		var settings_version: int = relaid.get("version", 0)
		var layout_version: int = relaid.get("layout_version", 0)
		volume.size.x += 1.0
		var resized := _snapshot_for_volume(volume.get_instance_id())
		require(not resized.is_empty() and resized.get("version", 0) != settings_version \
				and resized.get("layout_version", 0) != layout_version,
			"changing the volume bounds updates both surfel versions")

	volume.gi_mode = Volume.GIMode.PRT_MAGIC_GI
	Runtime.publish(volume)
	require(_snapshot_for_volume(volume.get_instance_id()).is_empty(),
		"switching back to PRT does not publish a Volume without a valid PRT bake")
	require(volume.bake_data == saved_data and volume.bake_manifest == saved_manifest,
		"switching modes retains the Volume's previous Data and Manifest resources")
	var canceler := RefreshCanceler.new()
	scene.add_child(canceler)
	volume._bake_generation = 7
	volume._baking = true
	volume._refresh_active = true
	volume._active_refresh_coordinator = canceler
	var refresh_request := Volume.SurfaceRefreshRequest.new()
	volume._refresh_requests[7] = refresh_request
	volume._active_refresh_generation = 7
	volume.gi_mode = Volume.GIMode.SURFEL_MAGIC_GI
	require(volume._bake_generation == 8 and volume._bake_cancel_requested \
			and canceler.canceled and refresh_request.finished and not refresh_request.succeeded,
		"entering Surfel mode invalidates the bake generation and cancels pending PRT work")
	volume._baking = false
	volume._bake_cancel_requested = false
	volume._refresh_active = false
	volume._active_refresh_coordinator = null
	volume._active_refresh_generation = -1
	canceler.free()
	Runtime.publish(volume)
	require(not _snapshot_for_volume(volume.get_instance_id()).is_empty(),
		"switching modes republishes the selected provider without discarding the Volume")
	await _test_saved_prt_layout_restore()
	settings = null
	first.free()
	second.free()
	scene.queue_free()
	await process_frame
	print("Surfel mode checks: %d, failures: %d" % [checks, failures])
	quit(1 if failures > 0 else 0)

func _snapshot_for_volume(volume_id: int) -> Dictionary:
	for snapshot in Runtime.snapshots():
		if int(snapshot.get("volume_id", -1)) == volume_id:
			return snapshot
	return {}

func _property_has_usage(object: Object, property_name: String, flag: int) -> bool:
	for property in object.get_property_list():
		if String(property.get("name", "")) == property_name:
			return (int(property.get("usage", 0)) & flag) != 0
	return false

func _test_saved_prt_layout_restore() -> void:
	var absolute_directory := ProjectSettings.globalize_path(RESTORE_FIXTURE_DIRECTORY)
	if not DirAccess.dir_exists_absolute(absolute_directory) \
			and DirAccess.make_dir_recursive_absolute(absolute_directory) != OK:
		require(false, "could not create the saved-resource restore fixture directory")
		return
	var source_volume := Volume.new()
	root.add_child(source_volume)
	source_volume.set_process(false)
	var source_data := _make_valid_data(source_volume)
	require(source_data != null and source_data.is_valid(),
		"the saved-layout fixture is structurally valid PRT data")
	if source_data == null or not source_data.is_valid():
		source_volume.free()
		return
	var data_saved := ResourceSaver.save(source_data, RESTORE_DATA_PATH,
			ResourceSaver.FLAG_COMPRESS) == OK
	require(data_saved,
		"the PRT layout fixture can be serialized")
	if not data_saved:
		source_volume.free()
		return
	var loaded_data := ResourceLoader.load(RESTORE_DATA_PATH, "", \
			ResourceLoader.CACHE_MODE_IGNORE) as Data
	require(loaded_data != null and loaded_data.is_valid(),
		"the saved PRT layout fixture reloads as valid resource data")
	if loaded_data == null or not loaded_data.is_valid():
		source_volume.free()
		return
	await _verify_saved_surfel_scene(loaded_data, false, RESTORE_DATA_SCENE_PATH)
	await _verify_saved_surfel_scene(loaded_data, true, RESTORE_MANIFEST_SCENE_PATH)
	source_volume.free()

func _make_valid_data(volume: FMagicGIVolume) -> FMagicGIData:
	var data := Data.new()
	data.format_version = Data.MOMENT_FORMAT_VERSION
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
	data.positions = PackedVector3Array([Vector3.UP * volume.surface_offset])
	data.surface_positions = PackedVector3Array([Vector3.ZERO])
	data.normals = PackedVector3Array([Vector3.UP])
	data.transfer.resize(27)
	data.primary_sky_visibility.resize(9)
	data.visibility_moments.resize(Data.VISIBILITY_TEXELS_PER_PROBE \
			* Data.VISIBILITY_MOMENT_CHANNELS)
	data.bake_version = 1
	if not data.build_cell_indices() or not data.is_valid():
		return null
	return data

func _verify_saved_surfel_scene(data: FMagicGIData, with_manifest: bool,
		scene_path: String) -> void:
	var saved_scene := Node3D.new()
	saved_scene.name = "SavedSurfelModeScene"
	var saved_volume := Volume.new()
	saved_volume.name = "MagicGI"
	saved_volume.show_probes = false
	saved_volume.gi_mode = Volume.GIMode.SURFEL_MAGIC_GI
	saved_volume.bake_data = data
	if with_manifest:
		var manifest := Manifest.new()
		manifest.generation = "surfel-mode-fixture"
		manifest.configure([])
		saved_volume.bake_manifest = manifest
	saved_scene.add_child(saved_volume)
	saved_volume.owner = saved_scene
	var packed_scene := PackedScene.new()
	var packed := packed_scene.pack(saved_scene) == OK
	var saved := packed and ResourceSaver.save(packed_scene, scene_path) == OK
	require(saved,
		"the scene can be saved with Surfel mode and its old PRT resources")
	saved_scene.free()
	if not saved:
		return
	var loaded_scene_resource := ResourceLoader.load(scene_path, "", \
			ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var loaded_scene := loaded_scene_resource.instantiate() if loaded_scene_resource != null else null
	require(loaded_scene != null, "the saved Surfel scene reloads")
	if loaded_scene == null:
		return
	root.add_child(loaded_scene)
	await process_frame
	var loaded_volume := loaded_scene.get_node_or_null("MagicGI") as FMagicGIVolume
	require(loaded_volume != null and loaded_volume.gi_mode == Volume.GIMode.SURFEL_MAGIC_GI \
			and loaded_volume.probe_count() == 0 and loaded_volume.bake_data != null \
			and loaded_volume.bake_data.is_valid(),
		"a loaded Surfel scene preserves saved PRT data without constructing its preview")
	if loaded_volume != null:
		loaded_volume.gi_mode = Volume.GIMode.PRT_MAGIC_GI
		if with_manifest:
			require(loaded_volume.probe_count() == 0,
				"an active Manifest retains priority over a coexisting legacy Data resource")
		else:
			require(loaded_volume.probe_positions == data.positions \
					and loaded_volume.probe_surface_positions == data.surface_positions \
					and loaded_volume.probe_normals == data.normals,
				"switching back to PRT restores arrays from the saved Data resource")
	loaded_scene.queue_free()
	await process_frame
