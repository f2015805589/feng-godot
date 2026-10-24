extends SceneTree
## CPU-only contract for dynamic CLV PRT admission and legacy SH compatibility.

const Data = preload("res://addons/feng-magic-gi/feng_magic_gi_data.gd")
const DirectionalData = preload("res://addons/feng-magic-gi/feng_magic_gi_directional_data.gd")
const Volume = preload("res://addons/feng-magic-gi/feng_magic_gi_volume.gd")
const Runtime = preload("res://addons/feng-magic-gi/feng_magic_gi_runtime.gd")
const Manifest = preload("res://addons/feng-magic-gi/feng_magic_gi_manifest.gd")
const Streamer = preload("res://addons/feng-magic-gi/feng_magic_gi_page_streamer.gd")
const Visibility = preload("res://addons/feng-magic-gi/feng_magic_gi_visibility.gd")

var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var default_volume := Volume.new()
	_check(default_volume.clv_cache_backend == 1,
		"new volumes keep the serialized backend-1 default")
	var backend_property: Dictionary = {}
	for property: Dictionary in default_volume.get_property_list():
		if String(property.get("name", "")) == "clv_cache_backend":
			backend_property = property
			break
	var backend_labels := String(backend_property.get("hint_string", "")).split(",")
	_check(backend_labels.size() == 2
			and backend_labels[0] == "Legacy per-probe/pixel PRT"
			and backend_labels[1] == "MagicDawn CLV Block PRT (dynamic)",
		"Inspector distinguishes legacy backend 0 from dynamic CLV Block PRT backend 1")
	default_volume.free()

	var matrix_only := _make_valid_data(true)
	_check(matrix_only.is_valid(), "matrix-only Data has valid probe geometry and transfer payloads")
	_check(not matrix_only.has_baked_indirect_sh(), "matrix-only Data has no baked radiance SH")
	var matrix_admission := Streamer.dynamic_transfer_admission(matrix_only)
	_check(bool(matrix_admission.get("ready", false))
			and String(matrix_admission.get("status", "")) == "ready",
		"dynamic page admission accepts a valid directional TransferMatrix without baked SH")

	var scene := Node3D.new()
	root.add_child(scene)
	var volume := Volume.new()
	volume.show_probes = false
	volume.use_clv = true
	volume.clv_cache_backend = 1
	volume.bake_data = matrix_only
	scene.add_child(volume)
	await process_frame
	_check(volume.has_valid_directional_transfer()
			and bool(volume.directional_transfer_status().get("ready", false)),
		"local dynamic backend readiness uses a valid matrix and geometry, not revision-2 SH")
	Runtime.publish(volume)
	Runtime._publish()
	var snapshot := _snapshot_for(volume.get_instance_id())
	_check(bool(snapshot.get("directional_transfer_ready", false))
			and bool(snapshot.get("magicdawn_selected", false))
			and bool(snapshot.get("replacement_enabled", false))
			and not bool(snapshot.get("baked_indirect_sh_ready", true)),
		"runtime admits the matrix-only resource for backend 1 while preserving the legacy SH diagnostic")

	var baked_only := _make_valid_data(false)
	_configure_legacy_baked_sh(baked_only)
	_check(baked_only.is_valid() and baked_only.has_baked_indirect_sh(),
		"baked-only fixture contains structurally valid revision-2 legacy SH")
	var baked_admission := Streamer.dynamic_transfer_admission(baked_only)
	_check(not bool(baked_admission.get("ready", true))
			and String(baked_admission.get("status", "")) == "missing_directional_transfer",
		"dynamic page admission rejects valid baked SH when the TransferMatrix is absent")
	volume.bake_data = baked_only
	await process_frame
	Runtime.publish(volume)
	Runtime._publish()
	snapshot = _snapshot_for(volume.get_instance_id())
	_check(not volume.has_valid_directional_transfer()
			and String(snapshot.get("directional_transfer_status", {}).get("status", ""))
			== "missing_directional_transfer"
			and not bool(snapshot.get("magicdawn_selected", true))
			and not bool(snapshot.get("replacement_enabled", true))
			and bool(snapshot.get("baked_indirect_sh_ready", false)),
		"runtime fails closed for baked-only data and reports the missing directional matrix")
	_check("TransferMatrix" in "; ".join(volume.bake_staleness_reasons()),
		"baked-only data reports a full-Bake reason tied to the missing TransferMatrix")
	_check("run a full Bake" in String(volume.directional_transfer_status().get("message", "")),
		"baked-SH-only backend-1 data gives an explicit full-Bake prompt")

	var malformed_matrix := _make_valid_data(true)
	malformed_matrix.directional.transfer.resize(1)
	var malformed_admission := Streamer.dynamic_transfer_admission(malformed_matrix)
	_check(not bool(malformed_admission.get("ready", true))
			and String(malformed_admission.get("status", ""))
			== "invalid_geometry_probe_or_transfer",
		"admission rejects a typed DirectionalData resource with an invalid TransferMatrix shape")
	var reused_streamer := Streamer.new()
	reused_streamer._active_metadata["legacy-loaded-page"] = {"empty": false}
	reused_streamer._resident["legacy-loaded-page"] = {
		"descriptor": {"data": malformed_matrix},
	}
	var reused_status: Dictionary = reused_streamer.directional_transfer_status()
	_check(not bool(reused_status.get("ready", true))
			and int(reused_status.get("resident_transfer_pages", -1)) == 0,
		"resident pages previously loaded by backend 0 cannot make malformed typed data ready for backend 1")

	volume.clv_cache_backend = 0
	Runtime.publish(volume)
	Runtime._publish()
	snapshot = _snapshot_for(volume.get_instance_id())
	_check(not bool(snapshot.get("magicdawn_selected", true))
			and bool(snapshot.get("replacement_enabled", false)),
		"backend 0 retains its legacy baked-resource path without requiring directional TransferMatrix")

	var manifest := _make_manifest()
	_check(manifest.is_valid() and not manifest.has_baked_indirect_sh(),
		"stream manifest without legacy baked SH remains structurally valid")
	var streamed_volume := Volume.new()
	streamed_volume.show_probes = false
	streamed_volume.clv_cache_backend = 1
	streamed_volume.bake_manifest = manifest
	var streamer := Streamer.new()
	streamer.set_manifest(manifest)
	streamer.request_view(42, 0, Vector3(0.5, 0.5, 0.5),
		AABB(Vector3.ZERO, Vector3.ONE), Time.get_ticks_msec())
	streamer._rebuild_active_metadata(streamed_volume)
	_check(streamer.active_page_count() == 1,
		"streamed page metadata is admitted without revision-2 SH or Sky provenance")
	_check(Streamer.dynamic_transfer_admission(matrix_only).get("probe_count", 0) == 1,
		"the streamed-page matrix gate validates the page's geometry and probe payload")

	streamer.deactivate()
	streamed_volume.free()
	volume.queue_free()
	await process_frame
	print("DYNAMIC_PRT_READINESS checks=%d failures=%d" % [checks, failures])
	quit(1 if failures > 0 else 0)

func _snapshot_for(volume_id: int) -> Dictionary:
	for value in Runtime.snapshots():
		if int(value.get("volume_id", -1)) == volume_id:
			return value
	return {}

func _make_valid_data(include_directional: bool) -> Resource:
	var data: Resource = Data.new()
	data.format_version = Data.FORMAT_VERSION
	data.grid_dims = Vector3i.ONE
	data.volume_transform = Transform3D.IDENTITY
	data.world_to_grid = Transform3D.IDENTITY
	data.volume_size = Vector3.ONE
	data.spacing = 1.0
	data.adaptive_placement = false
	data.minimum_probe_spacing = 0.25
	data.surface_offset = 0.03
	data.bake_samples = 1
	data.bake_bounces = 1
	data.bake_distance = 1.0
	data.terrain_reflectance = 0.5
	data.material_reflectance = 0.5
	data.bake_version = 1
	data.positions = PackedVector3Array([Vector3(0.5, 0.53, 0.5)])
	data.surface_positions = PackedVector3Array([Vector3(0.5, 0.5, 0.5)])
	data.normals = PackedVector3Array([Vector3.UP])
	data.transfer.resize(27)
	data.transfer.fill(0.1)
	data.primary_sky_visibility.resize(9)
	data.primary_sky_visibility.fill(0.5)
	data.visibility_moments.resize(Data.VISIBILITY_TEXELS_PER_PROBE * Data.VISIBILITY_MOMENT_CHANNELS)
	data.visibility_moments.fill(0.0)
	if include_directional:
		data.directional = DirectionalData.new()
		data.directional.allocate(1, 0)
		data.directional.transfer.fill(0.1)
		data.directional.sky.fill(0.1)
	var geometry := Visibility.build(PackedVector3Array([
		Vector3(-1, 0, -1), Vector3(1, 0, -1), Vector3(0, 0, 1)]))
	data.visibility_nodes = geometry.nodes
	data.visibility_triangles = geometry.triangles
	data.build_cell_indices()
	return data

func _configure_legacy_baked_sh(data: Resource) -> void:
	var radiance := PackedFloat32Array()
	radiance.resize(27)
	radiance.fill(0.0)
	data.baked_indirect_sh_revision = Data.BAKED_INDIRECT_SH_REVISION
	data.baked_indirect_sh.resize(27)
	data.baked_indirect_sh.fill(0.25)
	data.baked_indirect_sh_algorithm = Data.BAKED_INDIRECT_SH_ALGORITHM_LEGACY
	data.baked_indirect_sky_provenance = {
		"schema_version": 1,
		"status": "explicit_no_sky",
		"radiance_unit": "scene_linear_radiance",
		"radiance_sh": radiance,
		"radiance_energy": 0.0,
		"input_signature": Data.baked_sky_input_signature(radiance, 0.0),
		"source": "none",
		"source_mode": -1,
	}
	data._invalidate_baked_indirect_sh_validation_cache()

func _make_manifest() -> Resource:
	var manifest: Resource = Manifest.new()
	manifest.manifest_key = "dynamic-prt-admission-test"
	manifest.generation = "matrix-only-generation"
	manifest.world_bounds = AABB(Vector3.ZERO, Vector3.ONE)
	manifest.management_block_size = 1.0
	manifest.page_core_size = 1.0
	var entries: Array[Dictionary] = [{
		"page_key": "0,0/0,0,0",
		"core_bounds": AABB(Vector3.ZERO, Vector3.ONE),
		"support_bounds": AABB(Vector3(-0.5, -0.5, -0.5), Vector3(2.0, 2.0, 2.0)),
		"influence_bounds": AABB(Vector3(-1.0, -1.0, -1.0), Vector3(3.0, 3.0, 3.0)),
		"probe_count": 1,
		"cpu_bytes": 1024,
		"gpu_bytes": 1024,
		"version": 1,
		"resource_path": "res://unused_matrix_only_page.res",
		"content_hash": "test-hash",
		"empty": false,
	}]
	manifest.configure(entries)
	return manifest

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)
