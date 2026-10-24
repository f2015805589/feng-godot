extends SceneTree
## CPU-only end-to-end test for the regular free-space CLV PRT Bake button path.

const Volume = preload("../feng_magic_gi_volume.gd")
const Chunk = preload("../feng_magic_gi_volume_source_chunk.gd")
const Manifest = preload("../feng_magic_gi_manifest.gd")
const Page = preload("../feng_magic_gi_page.gd")
const VolumeSourceBaker = preload("../feng_magic_gi_volume_source_baker.gd")
const SceneTracker = preload("../feng_magic_gi_scene_tracker.gd")
const Emission = preload("../feng_magic_gi_emission.gd")

var checks := 0
var failures := 0
var cancel_armed := false

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_check(RenderingServer.get_rendering_device() == null,
		"the integration fixture is CPU-only and creates no RenderingDevice")
	var scene_root := Node3D.new()
	scene_root.name = "FreeSpaceBakeFixture"
	root.add_child(scene_root)
	current_scene = scene_root

	var volume := Volume.new()
	volume.name = "MagicGIVolume"
	volume.show_probes = false
	volume.size = Vector3(0.5, 0.5, 0.5)
	volume.bake_samples = 1
	volume.bake_bounces = 1
	volume.bake_distance = 1.0
	volume.use_clv = true
	volume.clv_cell_size = Chunk.CELL_SPACING_M
	volume.clv_cache_backend = 1
	volume.chunked_baking = false # Must still route to free-space source bake.
	var output_root := "res://Temp/free_space_bake_integration_%d" % Time.get_ticks_usec()
	volume.bake_output_directory = output_root
	scene_root.add_child(volume)
	var directional_light := DirectionalLight3D.new()
	directional_light.name = "LiveSun"
	scene_root.add_child(directional_light)
	_add_emissive_wall(scene_root)
	await process_frame

	var baked: bool = await volume.bake()
	_check(baked, "Volume.bake() completes its configured backend-1 free-space route")
	_check(volume.bake_manifest is Manifest and volume.bake_manifest != null,
		"Volume.bake() publishes a source-only page manifest")
	if not volume.bake_manifest is Manifest or volume.bake_manifest == null:
		await _finish(scene_root)
		return
	var manifest: Manifest = volume.bake_manifest
	var manifest_path := manifest.resource_path
	_check(manifest.transport_domain == "prepared_free_space_bricks_v1" \
			and manifest.prepared_bake_algorithm == "legacy_prepared_exact_slice_v1",
		"small ordinary Bake publishes an exact prepared brick generation")
	_check(manifest.get_page_count() == 4 and manifest.prepared_level_count == 4 \
			and not manifest.has_baked_indirect_sh(),
		"small fixture persists four real levels without inventing distant probes or frozen SH")
	_check(volume.bake_data == null,
		"free-space Bake does not create or retain the legacy surface Data payload")
	for entry in manifest.page_entries:
		var brick_page := ResourceLoader.load(String(entry.resource_path), "", ResourceLoader.CACHE_MODE_IGNORE) as Page
		_check(brick_page != null and brick_page.is_valid(manifest.generation, String(entry.page_key)) \
				and brick_page.prepared_transfer_brick != null and brick_page.free_space_volume_source == null,
			"runtime brick page validates and does not eagerly contain the raw source archive")
	var page_path := manifest.prepared_debug_source_path
	var page := ResourceLoader.load(page_path, "", ResourceLoader.CACHE_MODE_IGNORE) as Page
	_check(page != null and page.is_valid() and not page_path.is_empty(),
		"small exact bake keeps an explicitly linked on-demand source debug archive")
	if page == null or page.free_space_volume_source == null:
		await _finish(scene_root)
		return
	var chunk: Chunk = page.free_space_volume_source
	_check(chunk.has_preinterpolated_clv() and chunk.clv_preparation_revision == 1,
		"ordinary Bake persists geometry-conditioned linear transfer for native CLV relighting")
	var invalid_bound: Chunk = chunk.duplicate(true)
	invalid_bound.clv_preparation_stats["maximum_operator_row_l1"] = 0.00000001
	_check(not invalid_bound.is_valid(),
		"deep validation rejects an understated HDR operator bound before half-float upload")
	var invalid_coefficient: Chunk = chunk.duplicate(true)
	invalid_coefficient.clv_prepared_operators[0] = NAN
	_check(not invalid_coefficient.is_valid(),
		"deep validation rejects a non-finite prepared transfer coefficient")
	var fresh_allocation: Chunk = chunk.duplicate(true)
	fresh_allocation.allocate(Vector3i(2, 2, 2), chunk.emitter_ids)
	_check(fresh_allocation.clv_preparation_revision == 0 \
			and fresh_allocation.clv_prepared_operators.is_empty() \
			and fresh_allocation.clv_preparation_stats.is_empty(),
		"reallocation discards all operators and HDR bounds from the previous bake")
	_check(page.data == null and chunk.is_valid(page.geometry_signature,
		chunk.emitter_ids, chunk.emitter_static_signatures),
		"page contains the chunk exclusively; no legacy Data is mixed into it")
	_check(chunk.spacing_m == 0.25 and chunk.dimensions == Vector3i(2, 2, 2)
			and chunk.probe_count == 8,
		"source grid preserves the fixed .25 m pitch and expected fixture dimensions")
	_check(chunk.emitter_count == 1 and chunk.emitter_ids.size() == 1
			and chunk.emitter_static_signatures.size() == 1,
		"bake persists a stable emissive-source identity and static signature")
	_check(chunk.valid_cell_count() > 0 and chunk.receiver_visibility_moments.size()
			== chunk.storage_probe_count() * 128,
		"valid source cells have a complete 8x8 moment payload")
	_check(chunk.transfer.size() == chunk.storage_probe_count() * 243
			and chunk.sky.size() == chunk.storage_probe_count() * 81
			and chunk.emission.size() == chunk.storage_probe_count() * chunk.emitter_count * 54,
		"TransferMatrix, sky, and emitter arrays match the versioned SH9 layout")
	var pack_saves_memory := (chunk.cell_count() - chunk.valid_cell_count()) \
			* (243 + 81 + 54 * chunk.emitter_count + 128) > chunk.cell_count()
	var expected_format := Chunk.FORMAT_VERSION_PACKED if pack_saves_memory else Chunk.FORMAT_VERSION_DENSE
	_check(chunk.format_version == expected_format \
			and chunk.stored_valid_cell_count() == chunk.valid_cell_count(),
		"on-demand source archive packs only when beneficial and preserves all valid sources")

	# Live directional lighting and emissive radiance must be refreshed at runtime,
	# while the persisted geometry/source transport identity remains valid.
	var saved_source_signature := int(manifest.scene_watch_signature)
	var saved_settings_signature := int(manifest.bake_settings_signature)
	var initial_live_values := Emission.new().read_volume_source_values(volume, chunk)
	_check(initial_live_values.size() == chunk.emitter_count * 6
			and _has_nonzero(initial_live_values),
		"source-only page resolves the baked emitter binding to live six-float SH weights")
	directional_light.rotation_degrees = Vector3(-18.0, 32.0, 4.0)
	directional_light.light_color = Color(0.72, 0.86, 1.0)
	directional_light.light_energy = 1.7
	var emitter_node := scene_root.get_node_or_null("BakeEmitterWall") as MeshInstance3D
	var emitter_material := emitter_node.get_active_material(0) as StandardMaterial3D \
			if emitter_node != null else null
	if emitter_material != null:
		emitter_material.emission_enabled = false
		emitter_material.emission = Color(0.85, 0.1, 0.35, 1.0)
		emitter_material.emission_energy_multiplier = 4.0
	var disabled_live_values := Emission.new().read_volume_source_values(volume, chunk)
	_check(emitter_material != null and _all_zero(disabled_live_values),
		"disabling a baked emitter zeros its live source values without changing bindings")
	if emitter_material != null:
		emitter_material.emission_enabled = true
	var refreshed_live_values := Emission.new().read_volume_source_values(volume, chunk)
	_check(_has_nonzero(refreshed_live_values) and refreshed_live_values != initial_live_values,
		"emitter color/energy edits update the live source values without rebaking transport")
	_check(SceneTracker.stable_scene_signature(volume) == saved_source_signature
			and VolumeSourceBaker.settings_signature(volume) == saved_settings_signature
			and bool(volume.call("_saved_bake_matches_current")),
		"live sun direction/color/energy and emitter enabled/color/energy preserve saved source validity")

	# An invalid destination is rejected before assignment; the old generation and
	# manifest file remain available.
	volume.bake_output_directory = "user://free_space_bake_must_not_publish"
	var failed_destination: bool = await volume.bake()
	_check(not failed_destination and volume.bake_manifest == manifest
			and FileAccess.file_exists(manifest_path),
		"failed persistence leaves the previous manifest assigned and on disk")
	volume.bake_output_directory = output_root

	# Cancel from the first source-classification progress notification after the
	# next bake has begun. Worker jobs are joined before Volume.bake() returns.
	volume.bake_samples = 2048
	volume.bake_bounces = 3
	var cancel_callback := Callable(self, "_cancel_on_classification").bind(volume)
	volume.bake_status_changed.connect(cancel_callback)
	var canceled_result: bool = await volume.bake()
	if volume.bake_status_changed.is_connected(cancel_callback):
		volume.bake_status_changed.disconnect(cancel_callback)
	_check(cancel_armed and not canceled_result and volume.bake_manifest == manifest
			and FileAccess.file_exists(manifest_path),
		"cancellation does not publish over or remove the previous valid generation")

	print("FREE_SPACE_VOLUME_BAKE_INTEGRATION checks=%d failures=%d manifest=%s page=%s" % [
		checks, failures, manifest_path, page_path])
	await _finish(scene_root)

func _add_emissive_wall(scene_root: Node3D) -> void:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "BakeEmitterWall"
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.8, 0.8, 0.08)
	mesh_instance.mesh = mesh
	mesh_instance.position = Vector3(0.0, 0.0, -0.55)
	var material := StandardMaterial3D.new()
	material.emission_enabled = true
	material.emission = Color(0.2, 0.8, 0.15, 1.0)
	material.emission_energy_multiplier = 2.0
	mesh_instance.set_surface_override_material(0, material)
	scene_root.add_child(mesh_instance)

func _cancel_on_classification(volume: Volume) -> void:
	if cancel_armed or not is_instance_valid(volume):
		return
	if volume.free_space_bake_stage().begins_with("Classifying free-space cells"):
		cancel_armed = true
		volume.call_deferred("cancel_bake")

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)

func _has_nonzero(values: PackedFloat32Array) -> bool:
	for value in values:
		if absf(value) > 0.000001:
			return true
	return false

func _all_zero(values: PackedFloat32Array) -> bool:
	for value in values:
		if absf(value) > 0.000001:
			return false
	return true

func _finish(scene_root: Node) -> void:
	if is_instance_valid(scene_root):
		scene_root.queue_free()
	await process_frame
	print("FREE_SPACE_VOLUME_BAKE_INTEGRATION_RESULT checks=%d failures=%d" % [checks, failures])
	quit(1 if failures > 0 else 0)
