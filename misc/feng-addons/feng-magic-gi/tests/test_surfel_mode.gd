extends SceneTree
## CPU contracts for the realtime mode selector and bounded surfel settings.

const Volume = preload("res://addons/feng-magic-gi/feng_magic_gi_volume.gd")
const Settings = preload("res://addons/feng-magic-gi/feng_magic_gi_surfel_settings.gd")
const Runtime = preload("res://addons/feng-magic-gi/feng_magic_gi_runtime.gd")
const Data = preload("res://addons/feng-magic-gi/feng_magic_gi_data.gd")
const Manifest = preload("res://addons/feng-magic-gi/feng_magic_gi_manifest.gd")
const AdaptiveLayout = preload("res://addons/feng-render-pipeline/passes/magic_gi_surfel_adaptive_layout.gd")
const RESTORE_FIXTURE_DIRECTORY := "user://surfel_mode_restore"
const RESTORE_DATA_PATH := RESTORE_FIXTURE_DIRECTORY + "/saved_prt_data.res"
const RESTORE_DATA_SCENE_PATH := RESTORE_FIXTURE_DIRECTORY + "/surfel_with_prt_data.tscn"
const RESTORE_MANIFEST_SCENE_PATH := RESTORE_FIXTURE_DIRECTORY + "/surfel_with_manifest_and_prt_data.tscn"
const SURFEL_CACHE_GLSL_PATH := "res://addons/feng-render-pipeline/library/magic-gi/surfel/gi_surfel_cache.glslinc"
const SURFEL_CACHE_HLSL_PATH := "res://addons/feng-render-pipeline/library/magic-gi/surfel/gi_surfel_cache.hlslinc"
const SURFEL_LOD_SUMMARY_PATH := "res://addons/feng-render-pipeline/library/magic-gi/surfel/magic_gi_surfel_lod_summary.glsl"
const SURFEL_GPU_PATH := "res://addons/feng-render-pipeline/passes/magic_gi_surfel_gpu.gd"

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
	_test_lod_presence_contract()
	_test_adaptive_layout_contracts()
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
		"denoiser": 0,
		"half_resolution": true,
		"probe_fallback_enabled": true,
		"adaptive_distribution_enabled": true,
		"ray_guiding_enabled": true,
		"guide_cosine_floor": 0.5,
		"debug_view": 0,
	}, "the serialized defaults produce the frozen plain-value runtime settings")
	settings.surfel_radius = NAN
	settings.max_surfels = 1
	settings.updates_per_frame = 999999
	settings.rays_per_surfel = 0
	settings.max_ray_distance = INF
	settings.history_weight = NAN
	settings.denoiser = 9
	settings.half_resolution = false
	settings.debug_view = 9
	var bounded := settings.to_runtime_settings()
	require(bounded["surfel_radius"] == 0.15 and bounded["max_surfels"] == 1024 \
			and bounded["updates_per_frame"] == 16384 and bounded["rays_per_surfel"] == 1 \
			and bounded["max_ray_distance"] == 128.0 and bounded["history_weight"] == 0.9 \
			and bounded["denoiser"] == 1 and not bounded["half_resolution"] \
			and bounded["probe_fallback_enabled"] \
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
		require(snapshot.get("surfel_settings", {}).size() == 13 \
				and int(snapshot.get("surfel_settings", {}).get("denoiser", -1)) == 0 \
				and bool(snapshot.get("surfel_settings", {}).get("half_resolution", false)) \
				and snapshot.get("cache_key", "") == "surfel:%d" % volume.get_instance_id() \
				and bool(snapshot.get("replacement_enabled", false)) \
				and snapshot.has("owner_transform") and snapshot.has("owner_size") \
				and snapshot.has("world_id") and snapshot.has("render_targets"),
			"the runtime snapshot carries bounded settings and a volume-scoped cache key")
		require(snapshot.get("version", 0) == hash([volume.global_transform,
				volume.size, snapshot.get("surfel_settings", {})]),
			"cache version tracks the current volume bounds and surfel settings")
		require(snapshot.get("layout_version", 0) == hash(["surfel-layout-v5-lod-presence",
				volume.global_transform, volume.size, 0.15, 65536, true,
				AdaptiveLayout.LOD_TARGET_PIXELS,
				AdaptiveLayout.TILE_REPRESENTATIVE_COUNT]),
			"layout version tracks bounds, allocation, LOD and tile coverage policy")
		var original_version: int = snapshot.get("version", 0)
		var original_layout_version: int = snapshot.get("layout_version", 0)
		volume.surfel_settings.updates_per_frame = 3072
		volume.surfel_settings.history_weight = 0.8
		volume.surfel_settings.denoiser = 1
		volume.surfel_settings.half_resolution = false
		volume.surfel_settings.debug_view = 2
		volume.surfel_settings.ray_guiding_enabled = false
		volume.surfel_settings.guide_cosine_floor = 0.35
		var updated := _snapshot_for_volume(volume.get_instance_id())
		require(not updated.is_empty() and updated.get("version", 0) != original_version,
			"any surfel setting change republishes the settings version")
		require(updated.get("layout_version", 0) == original_layout_version,
				"update-budget, history, denoiser, resolution, debug, and guiding changes do not invalidate layout history")
		volume.surfel_settings.adaptive_distribution_enabled = false
		var adaptive_disabled := _snapshot_for_volume(volume.get_instance_id())
		require(adaptive_disabled.get("layout_version", 0) != original_layout_version,
			"changing the two-level layout mode invalidates geometry history")
		volume.surfel_settings.adaptive_distribution_enabled = true
		var adaptive_restored := _snapshot_for_volume(volume.get_instance_id())
		require(adaptive_restored.get("layout_version", 0) == original_layout_version,
			"restoring the adaptive layout mode restores its structural version")
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

func _test_lod_presence_contract() -> void:
	var cache_glsl := FileAccess.get_file_as_string(SURFEL_CACHE_GLSL_PATH)
	var cache_hlsl := FileAccess.get_file_as_string(SURFEL_CACHE_HLSL_PATH)
	var summary_glsl := FileAccess.get_file_as_string(SURFEL_LOD_SUMMARY_PATH)
	var gpu_source := FileAccess.get_file_as_string(SURFEL_GPU_PATH)
	require(not cache_glsl.is_empty() and not cache_hlsl.is_empty() \
			and not summary_glsl.is_empty() and not gpu_source.is_empty(),
		"the LOD-presence shader and host sources are available")
	if cache_glsl.is_empty() or cache_hlsl.is_empty() \
			or summary_glsl.is_empty() or gpu_source.is_empty():
		return
	require(cache_glsl.contains("layout(set = 1, binding = 17") \
			and cache_glsl.contains("present_levels & (1u << level)"),
		"GLSL cache lookups use the read-only LOD summary at binding 17")
	require(cache_hlsl.contains("gi_surfel_lod_presence : register(t17, space1)") \
			and cache_hlsl.contains("present_levels & (1u << level)"),
		"HLSL cache lookups use the matching read-only LOD summary")
	require(summary_glsl.contains("binding = 17") \
			and summary_glsl.contains("gi_surfel_counters.values[1]") \
			and summary_glsl.contains("record.normal_valid.w >= 0.5") \
			and summary_glsl.contains("record.state.z == 0u") \
			and summary_glsl.contains("atomicOr(group_levels") \
			and summary_glsl.contains("atomicOr(gi_surfel_lod_presence.levels"),
		"the summary scans only bounded active records and publishes group-local LOD bits")
	require(gpu_source.contains("U.storage_buffer(17, state.lod_presence)") \
			and gpu_source.contains("U.storage_buffer(17, lod_presence)") \
			and gpu_source.contains("state.lod_presence_frame = frame_token") \
			and gpu_source.contains("state.lod_presence_dirty = true") \
			and gpu_source.contains("lod_presence_mask = presence_bytes.decode_u32(0)"),
		"the host owns, rebuilds, and binds the summary buffer before trace use")

func _test_adaptive_layout_contracts() -> void:
	require(AdaptiveLayout.level_radius(0.15, 0, true) == 0.15 \
			and AdaptiveLayout.level_radius(0.15, 1, true) == 0.3,
		"adaptive placement keeps its fine radius and uses a bounded 2x coarse level")
	var pixel_footprint_per_meter := 2.0 * tan(deg_to_rad(25.0)) / 480.0
	var old_anchor_pixel_footprint := pixel_footprint_per_meter * 6.0
	var reconstructed_anchor_pixel_footprint := pixel_footprint_per_meter * 13.0
	require(AdaptiveLayout.LOD_TARGET_PIXELS == 8.0 \
			and AdaptiveLayout.level_for_footprint(old_anchor_pixel_footprint, 0.15, true, 0) == 0 \
			and AdaptiveLayout.level_for_footprint(reconstructed_anchor_pixel_footprint, 0.15, true, 0) == 1,
		"maintenance changes LOD from reconstructed triangle depth, not the old anchor depth")
	require(AdaptiveLayout.level_for_footprint(0.023, 0.15, true, 0) == 0 \
			and AdaptiveLayout.level_for_footprint(0.024, 0.15, true, 0) == 1 \
			and AdaptiveLayout.level_for_footprint(0.015, 0.15, true, 1) == 1 \
			and AdaptiveLayout.level_for_footprint(0.014, 0.15, true, 1) == 0,
		"existing anchors use LOD hysteresis to avoid near/far thrashing")
	var local_positions: Array[Dictionary] = [{}, {}, {}, {}]
	for phase in AdaptiveLayout.TILE_REPRESENTATIVE_PHASE_COUNT:
		var quadrants: Dictionary = {}
		for candidate in AdaptiveLayout.TILE_REPRESENTATIVE_COUNT:
			var representative: Vector2i = AdaptiveLayout.tile_representative_offset(candidate, phase)
			var quadrant := Vector2i(representative.x / 8, representative.y / 8)
			quadrants[quadrant] = true
			local_positions[candidate][Vector2i(representative.x % 8,
				representative.y % 8)] = true
			require(representative.x >= 0 and representative.x < AdaptiveLayout.TILE_SIZE \
					and representative.y >= 0 and representative.y < AdaptiveLayout.TILE_SIZE,
				"rotating coverage representatives stay inside their 16x16 tile")
		require(quadrants.size() == AdaptiveLayout.TILE_REPRESENTATIVE_COUNT,
			"each tile pass samples one representative from each 8x8 quadrant")
	for candidate in AdaptiveLayout.TILE_REPRESENTATIVE_COUNT:
		require(local_positions[candidate].size() == AdaptiveLayout.TILE_REPRESENTATIVE_PHASE_COUNT,
			"each quadrant representative reaches all 64 local pixel offsets")
	var visit_tile_count := 7
	var visit_work_count := 3
	var visit_target_tile := 5
	var visit_cursor := 0
	var target_offsets: Dictionary = {}
	var visit_frame_limit := ceili(float(visit_tile_count
			* AdaptiveLayout.TILE_REPRESENTATIVE_PHASE_COUNT) / float(visit_work_count))
	for _frame in visit_frame_limit:
		for sample_index in visit_work_count:
			var absolute_visit := visit_cursor + sample_index
			var tile_index := absolute_visit % visit_tile_count
			if tile_index == visit_target_tile:
				var phase := AdaptiveLayout.tile_representative_phase(
						visit_cursor, sample_index, visit_tile_count)
				var offset := AdaptiveLayout.tile_representative_offset(0, phase)
				target_offsets[Vector2i(offset.x % 8, offset.y % 8)] = true
		visit_cursor = AdaptiveLayout.advance_tile_cursor(
				visit_cursor, visit_work_count, visit_tile_count)
	require(target_offsets.size() == AdaptiveLayout.TILE_REPRESENTATIVE_PHASE_COUNT,
		"a static tile reaches every quadrant pixel within 64 full tile sweeps")
	var parity_tile_count := 8
	var parity_work_count := 4
	var parity_target_tile := 6
	var parity_cursor := 0
	var parity_offsets: Dictionary = {}
	var parity_frame_limit := ceili(float(parity_tile_count
			* AdaptiveLayout.TILE_REPRESENTATIVE_PHASE_COUNT) / float(parity_work_count))
	for _frame in parity_frame_limit:
		for sample_index in parity_work_count:
			var absolute_visit := parity_cursor + sample_index
			if absolute_visit % parity_tile_count == parity_target_tile:
				var phase := AdaptiveLayout.tile_representative_phase(
						parity_cursor, sample_index, parity_tile_count)
				var offset := AdaptiveLayout.tile_representative_offset(0, phase)
				parity_offsets[Vector2i(offset.x % 8, offset.y % 8)] = true
		parity_cursor = AdaptiveLayout.advance_tile_cursor(
				parity_cursor, parity_work_count, parity_tile_count)
	require(parity_offsets.size() == AdaptiveLayout.TILE_REPRESENTATIVE_PHASE_COUNT,
		"a tile revisited every other frame still reaches all 64 offsets")
	require(AdaptiveLayout.least_covered_tile_candidate(
			PackedFloat32Array([1.0, 0.0, 0.5, 1.0]), PackedByteArray([1, 1, 1, 1]), 3) == 1 \
			and AdaptiveLayout.least_covered_tile_candidate(
			PackedFloat32Array([0.0, 0.0, 0.0, 0.0]), PackedByteArray([1, 1, 1, 1]), 2) == 2 \
			and AdaptiveLayout.least_covered_tile_candidate(
			PackedFloat32Array([0.0, 0.25, 0.5, 0.75]), PackedByteArray([0, 1, 1, 1]), 0) == 1 \
			and AdaptiveLayout.least_covered_tile_candidate(
			PackedFloat32Array([2.0, 0.0, 0.5, 1.0]), PackedByteArray([1, 1, 1, 1]), 0) == 1 \
			and AdaptiveLayout.least_covered_tile_candidate(
			PackedFloat32Array([2.0, 2.0, 2.0, 2.0]), PackedByteArray([1, 1, 1, 1]), 0) == -1,
		"tile seeding chooses the lowest supported candidate with a rotating deterministic tie break")
	require(not AdaptiveLayout.surface_tracking_changed(-1, 4) \
			and not AdaptiveLayout.surface_tracking_changed(4, 4) \
			and AdaptiveLayout.surface_tracking_changed(4, 5),
		"only a changed established SurfaceTracking revision forces same-frame relocation")
	require(AdaptiveLayout.maintenance_dispatch_count(65536, 4096, true) == 65536 \
			and AdaptiveLayout.maintenance_dispatch_count(65536, 4096, false) == 2048 \
			and AdaptiveLayout.maintenance_dispatch_count(1000, 100, false) == 100 \
			and AdaptiveLayout.maintenance_dispatch_count(0, 100, true) == 0,
		"motion relocation is a bounded full sweep, while camera-only LOD work is chunked")
	var uniform_guide := PackedByteArray()
	uniform_guide.resize(AdaptiveLayout.GUIDE_BINS)
	for index in uniform_guide.size():
		uniform_guide[index] = 1
	var uniform_probability := AdaptiveLayout.guide_bin_probability(uniform_guide, 0)
	require(absf(uniform_probability - 1.0 / 16.0) < 1e-6 \
			and absf(AdaptiveLayout.mixture_pdf(0.2, uniform_probability, 0.5) - 0.2) < 1e-6,
		"uniform guide mass reduces to the cosine PDF")
	var concentrated_guide := PackedByteArray()
	concentrated_guide.resize(AdaptiveLayout.GUIDE_BINS)
	concentrated_guide[0] = 255
	var integrated_mixture := 0.0
	for bin_index in AdaptiveLayout.GUIDE_BINS:
		var probability := AdaptiveLayout.guide_bin_probability(concentrated_guide, bin_index)
		var mixture_probability := 0.25 / 16.0 + 0.75 * probability
		integrated_mixture += mixture_probability
		var ratio := AdaptiveLayout.mixture_pdf(0.2, probability, 0.25) / 0.2
		require(ratio >= 0.25 - 1e-6,
			"the guided proposal keeps the configured cosine support floor")
	require(absf(integrated_mixture - 1.0) < 1e-6 \
			and absf(AdaptiveLayout.mixture_pdf(0.2, 0.0, 1.0) - 0.2) < 1e-6,
		"the mixed 4x4 guide PDF remains normalized and alpha=1 is cosine sampling")
	require(AdaptiveLayout.ray_strategy_counts(1, true, 2, 1.0) == Vector2i(1, 0) \
			and AdaptiveLayout.ray_strategy_counts(3, true, 2, 1.0) == Vector2i(2, 1) \
			and AdaptiveLayout.ray_strategy_counts(4, true, 2, 1.0) == Vector2i(2, 2) \
			and AdaptiveLayout.ray_strategy_counts(4, true, 0, 1.0) == Vector2i(4, 0),
		"odd and low ray budgets retain matching cosine/NEE strategy counts")

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
