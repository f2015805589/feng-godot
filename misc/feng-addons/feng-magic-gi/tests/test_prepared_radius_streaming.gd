extends SceneTree
const Manifest = preload("../feng_magic_gi_manifest.gd")
const Header = preload("../feng_magic_gi_prepared_source_header.gd")
const Layout = preload("../feng_magic_gi_prepared_clip_layout.gd")
const Streamer = preload("../feng_magic_gi_page_streamer.gd")
const Volume = preload("../feng_magic_gi_volume.gd")
var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("run")

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(message)

func fixture() -> Resource:
	var manifest := Manifest.new()
	manifest.generation = "radius"
	manifest.transport_domain = "prepared_free_space_bricks_v1"
	manifest.prepared_operator_schema_version = 2
	manifest.prepared_level_count = 10
	manifest.prepared_source_origin_world = Vector3.ONE * 0.125
	manifest.prepared_source_size_m = Vector3.ONE * 4096.0
	manifest.prepared_source_transform_world.origin = Vector3.ONE * 2048.0
	manifest.world_bounds = AABB(Vector3.ZERO, Vector3.ONE * 4096.0)
	manifest.prepared_source_signature = "radius-fixture"
	var entries: Array[Dictionary] = []
	# Sparse fixture spans 4 km; no global .25 m array is allocated.
	for level in 10:
		var step := 0.25 * float(1 << level)
		var origins: Dictionary = {}
		for camera in [Vector3.ONE * 1024.0, Vector3.ONE * 3072.0]:
			var center := Vector3i((camera / (step * 16.0)).floor())
			for z in range(-2, 3):
				for y in range(-2, 3):
					for x in range(-2, 3):
						var origin := (center + Vector3i(x, y, z)) * 16
						if origin.x < 0 or origin.y < 0 or origin.z < 0: continue
						origins[origin] = true
		for origin in origins:
			var core := AABB(manifest.prepared_source_origin_world + Vector3(origin) * step - Vector3.ONE * step * 0.5,
				Vector3.ONE * 16 * step)
			entries.append({"page_key": "%d:%s" % [level, origin], "prepared_level": level,
				"prepared_source_signature": manifest.prepared_source_signature,
				"prepared_operator_schema_version": 2,
				"core_cell_origin": origin, "core_dimensions": Vector3i.ONE * 16,
				"core_bounds": core, "support_bounds": core.grow(step), "influence_bounds": core.grow(step),
				"resource_path": "res://unused-selection-fixture.res", "probe_count": 1,
				"cpu_bytes": 16, "gpu_bytes": 16})
	manifest.configure(entries)
	return manifest

func run() -> void:
	var manifest := fixture()
	check(manifest.is_valid(), "sparse multi-kilometer index validates: " + manifest.get_index_error())
	var header: Resource = Header.from_manifest(manifest)
	check(header != null and header.is_header_valid(), "header supports >256 cells without dense data")
	var legacy: Resource = manifest.duplicate(true)
	legacy.prepared_operator_schema_version = 1
	var legacy_entries: Array[Dictionary] = legacy.page_entries.duplicate(true)
	for entry in legacy_entries: entry["prepared_operator_schema_version"] = 1
	legacy.configure(legacy_entries)
	check(not legacy.is_valid() and Header.from_manifest(legacy) == null,
		"legacy SH9 prepared manifest is refused instead of misdecoded")
	var legacy_streamer := Streamer.new()
	legacy_streamer.set_manifest(legacy)
	check(legacy_streamer.warning.contains("legacy SH9") and legacy_streamer.warning.contains("Rebake"),
		"legacy prepared cache reports the SH2 rebake requirement")
	var legacy_volume := Volume.new()
	legacy_volume.bake_manifest = legacy
	check(legacy_volume.needs_rebake() \
			and legacy_volume.directional_transfer_status().status == "prepared_clv_sh2_rebake_required",
		"volume readiness flags old prepared schema as requiring rebake")
	for resolution in [16, 24, 32]:
		var layout := Layout.build(header, Vector3.ONE * 1024.0, resolution, 512.0)
		check(layout.valid and layout.level_count == (10 if resolution == 16 else 9), "radius coverage chooses sufficient levels")
		check(resolution * int(layout.level_count) * 7 <= 2048, "packed texture stays within guaranteed depth")
	check(Layout.intersects_sphere(AABB(Vector3(511, 0, 0), Vector3.ONE), Vector3.ZERO, 512), "511m intersects")
	check(Layout.intersects_sphere(AABB(Vector3(512, 0, 0), Vector3.ONE), Vector3.ZERO, 512), "512m boundary intersects")
	check(not Layout.intersects_sphere(AABB(Vector3(513, 0, 0), Vector3.ONE), Vector3.ZERO, 512), "513m fully outside rejected")
	check(not Layout.intersects_sphere(AABB(Vector3(400, 400, 0), Vector3.ONE), Vector3.ZERO, 512), "sphere rejects cube corners")
	var volume := Volume.new()
	volume.show_probes = false
	volume.bake_manifest = manifest
	volume.gi_radius_m = 512
	volume.stream_hysteresis = 128 # Must have no effect on prepared radius.
	var streamer := Streamer.new()
	streamer.set_manifest(manifest)
	var camera := Vector3.ONE * 1024.0
	streamer.request_view(1, 0, camera, AABB(Vector3.ZERO, Vector3.ONE * 10000), 100, 16)
	streamer._rebuild_active_metadata(volume)
	check(streamer.active_page_count() > 0 and streamer.active_page_count() < 100, "bounded per-LOD windows select only nearby bricks")
	for metadata in streamer._active_metadata.values():
		check(Layout.intersects_sphere(metadata.core_bounds, camera, 512), "no requested core completely outside sphere")
	var old_keys: Array = streamer._active_metadata.keys()
	streamer._rebuild_active_metadata(volume)
	check(old_keys == streamer._active_metadata.keys(), "identical camera is deterministic independent of orientation/frustum")
	var old_key: String = old_keys[0]
	streamer._resident[old_key] = {"cpu_bytes": 64, "gpu_bytes": 64}
	streamer._loads[old_key] = {"stage": "resource", "reserved_cpu_bytes": 32, "reserved_gpu_bytes": 32}
	streamer.request_view(1, 0, Vector3.ONE * 3072.0, AABB(), 101, 16)
	streamer._rebuild_active_metadata(volume)
	streamer._evict_inactive_pages()
	check(not streamer._resident.has(old_key), "teleport immediately evicts departed resident brick")
	check(streamer._loads[old_key].discard, "in-flight departed request is discard-only")
	check(streamer.inflight_cpu_bytes() == 32, "uncancellable I/O keeps its reservation until drained")
	streamer._loads.clear() # Selection fixture never issued real I/O.
	streamer._loads[old_key] = {"stage": "prepared", "discard": true,
		"job": preload("../feng_magic_gi_page_prepare_job.gd").new()}
	streamer._advance_page_loads(volume)
	check(streamer._loads.is_empty() and streamer._failure_warning.is_empty(), "failed retired worker cannot poison new generation warning")
	streamer._prune_views(1000)
	streamer._rebuild_active_metadata(volume)
	check(streamer.active_page_count() == 0, "inactive camera cannot retain pages")
	volume.free()
	print("PREPARED_RADIUS_STREAMING checks=", checks, " failures=", failures)
	quit(1 if failures else 0)
