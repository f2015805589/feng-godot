extends SceneTree
const Volume = preload("../feng_magic_gi_volume.gd")
const PagedBaker = preload("../feng_magic_gi_paged_source_baker.gd")
const SourceBaker = preload("../feng_magic_gi_volume_source_baker.gd")
const Page = preload("../feng_magic_gi_page.gd")
var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("run")

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(message)

func run() -> void:
	check(Volume.BAKE_QUALITY_SAMPLES == [128, 256, 512, 1024, 2048],
		"bake preset menu spans preview through reference samples")
	var default_volume := Volume.new()
	check(default_volume.bake_samples == 256,
		"the existing 256-sample default remains unchanged")
	default_volume.free()
	var sampling_cache := SourceBaker.make_sampling_cache(32, 3, 256)
	check(bool(sampling_cache.get("ok", false))
			and sampling_cache.coordinates.size() == 8
			and sampling_cache.minimum_moment_coordinates[0].size() == 256
			and sampling_cache.extra_moment_coordinates[0].is_empty(),
		"batch-local sampling cache preserves requested dimensions and moment counts")
	check(SourceBaker._sampling_cache_matches(sampling_cache, 32, 3, 256),
		"matching sample settings reuse the immutable base sequence")
	check(not SourceBaker._sampling_cache_matches(sampling_cache, 64, 3, 256),
		"a different sample count cannot reuse an incompatible sequence")
	check(not SourceBaker._sampling_cache_matches(sampling_cache, 32, 2, 256),
		"a different bounce count cannot reuse a different-dimensional sequence")
	check(not SourceBaker._sampling_cache_matches(sampling_cache, 32, 3, 512),
		"a different moment ray count cannot reuse an incomplete sequence")
	var large := Vector3i(4096, 4096, 4096)
	for level in 10:
		var dims := Vector3i((Vector3(large) / float(1 << level)).ceil())
		var tile := PagedBaker.tile_layout(large, level, Vector3i.ZERO, 16)
		check(not tile.is_empty() and tile.level_dimensions == dims, "large-world level grid is metadata only")
		check(tile.source_dimensions.x <= 28 and tile.source_dimensions.y <= 28 and tile.source_dimensions.z <= 28,
			"working set remains bounded independently of global domain")
	check(PagedBaker.tile_layout(large, 10, Vector3i.ZERO).is_empty(), "unsupported level rejected")
	var scene := Node3D.new()
	root.add_child(scene)
	current_scene = scene
	var volume := Volume.new()
	volume.name = "PagedTestVolume"
	volume.show_probes = false
	volume.size = Vector3(4, 0.5, 0.5)
	volume.bake_samples = 1
	volume.bake_bounces = 1
	volume.bake_distance = 1.0
	scene.add_child(volume)
	var wall := MeshInstance3D.new()
	wall.name = "Emitter"
	var box := BoxMesh.new()
	box.size = Vector3(4, 0.1, 0.5)
	wall.mesh = box
	wall.position.y = -0.4
	var material := StandardMaterial3D.new()
	material.emission_enabled = true
	material.emission = Color(0.4, 0.8, 0.2)
	material.emission_energy_multiplier = 1.0
	wall.material_override = material
	scene.add_child(wall)
	await process_frame
	var options := {"prepared_levels": 10, "core_axis": 8}
	var result: Dictionary = await PagedBaker.new().bake_async(volume,
		"multires_" + str(Time.get_ticks_usec()), "res://Temp/paged_bake_test", options)
	check(bool(result.get("ok", false)), "independent multi-resolution bake completes: " + str(result.get("error", "")))
	if bool(result.get("ok", false)):
		var manifest: Resource = result.manifest
		check(manifest.is_valid() and manifest.prepared_level_count == 10, "all ten real traced levels persist")
		check(manifest.prepared_bake_algorithm == "multires_independent_transport_sh2_v3",
			"paged bake records the direct surface target algorithm revision")
		check(manifest.bake_settings_signature == PagedBaker.settings_signature(volume, options), "new bake signature is reproducible")
		check(manifest.bake_samples == volume.bake_samples and manifest.bake_bounces == volume.bake_bounces
				and manifest.bake_moment_rays == 256,
			"reloaded manifest records exact transport sampling provenance")
		check(int(result.peak_working_source_cells) <= 28 * 28 * 28, "bake reports bounded peak source allocation")
		var level_counts := PackedInt32Array()
		level_counts.resize(10)
		var samples: Dictionary = {}
		for entry in manifest.page_entries:
			var page := load(String(entry.resource_path)) as Page
			check(page != null and page.is_valid() and page.free_space_volume_source == null, "page reload has no dense raw source resource")
			var brick: Resource = page.prepared_transfer_brick
			level_counts[brick.level] += 1
			check(brick.emitter_ids == manifest.prepared_emitter_ids, "every level/page shares emitter binding")
			for z in brick.dimensions.z:
				for y in brick.dimensions.y:
					for x in brick.dimensions.x:
						var cell: Vector3i = brick.cell_origin + Vector3i(x, y, z)
						var index: int = brick.cell_index(cell)
						var stride: int = brick.operator_stride()
						var key := str(brick.level) + ":" + str(cell)
						var bytes: PackedByteArray = brick.operators.slice(index * stride, (index + 1) * stride).to_byte_array()
						if samples.has(key):
							check(samples[key] == bytes, "overlapping halos match despite different local source origins")
						else: samples[key] = bytes
		for level in 10: check(level_counts[level] > 0, "level %d contains traced transport" % level)
		check(level_counts[0] > 1, "fixture crosses a real source page boundary")
	scene.queue_free()
	await process_frame
	print("MAGIC_GI_PAGED_SOURCE_BAKE checks=", checks, " failures=", failures)
	quit(1 if failures else 0)
