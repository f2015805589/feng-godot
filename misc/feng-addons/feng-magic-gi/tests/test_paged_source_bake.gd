extends SceneTree
const Volume = preload("../feng_magic_gi_volume.gd")
const PagedBaker = preload("../feng_magic_gi_paged_source_baker.gd")
const SourceBaker = preload("../feng_magic_gi_volume_source_baker.gd")
const Page = preload("../feng_magic_gi_page.gd")
const ProbeLayout = preload("../feng_magic_gi_source_probe_layout.gd")
const Inference = preload("../feng_magic_gi_olv_inference_runner.gd")
const Domain = preload("../feng_magic_gi_olv_domain.gd")
const Header = preload("../feng_magic_gi_prepared_source_header.gd")
const RenderPass = preload("../../feng-render-pipeline/passes/magic_gi_pass.gd")
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
	var bounded_layout := ProbeLayout.new()
	check(not bounded_layout.allocate(large, 10) and bounded_layout.validity.is_empty(),
		"offline probe layout rejects oversized allocations without allocating a world-sized array")
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
	var cell_spacing := 0.25
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--cell-size="): cell_spacing = argument.get_slice("=", 1).to_float()
	volume.clv_cell_size = cell_spacing
	volume.name = "PagedTestVolume"
	volume.show_probes = false
	volume.size = Vector3(16, 2, 2) * cell_spacing
	volume.bake_samples = 1
	volume.bake_bounces = 1
	volume.bake_distance = cell_spacing * 4.0
	scene.add_child(volume)
	var wall := MeshInstance3D.new()
	wall.name = "Emitter"
	var box := BoxMesh.new()
	box.size = Vector3(16, 0.4, 2) * cell_spacing
	wall.mesh = box
	wall.position.y = -1.6 * cell_spacing
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
		check(is_equal_approx(manifest.prepared_source_spacing_m, cell_spacing), "paged manifest persists base spacing")
		check(manifest.is_valid() and manifest.prepared_level_count == 10, "all ten real traced levels persist")
		check(manifest.prepared_bake_algorithm == "multires_independent_transport_sh2_v3",
			"paged bake records the direct surface target algorithm revision")
		check(manifest.bake_settings_signature == PagedBaker.settings_signature(volume, options), "new bake signature is reproducible")
		check(manifest.bake_samples == volume.bake_samples and manifest.bake_bounces == volume.bake_bounces
				and manifest.bake_moment_rays == 256,
			"reloaded manifest records exact transport sampling provenance")
		check(int(result.peak_working_source_cells) <= 28 * 28 * 28, "bake reports bounded peak source allocation")
		var layout := load(manifest.prepared_probe_layout_path) as ProbeLayout
		check(layout != null and layout.is_source_data_valid() and layout.matches_manifest(manifest),
			"paged bake retains exact offline probe layout without dense transport")
		if layout != null:
			volume.bake_manifest = manifest
			var retained: Dictionary = volume._load_active_source_page()
			check(retained.get("source") == layout, "independent OLV can load a multiresolution bake")
			var geometry := SourceBaker.Placement.new()
			check(geometry.collect(volume, true, true, true, false,
				layout.source_bounds_world.grow(layout.trace_distance_m * (layout.bake_bounces + 1))),
				"capture the same geometry for an independent probe check")
			for level in layout.prepared_level_count:
				var working := SourceBaker.Chunk.new()
				working.dimensions = layout.level_dimensions(level)
				working.probe_count = working.cell_count()
				working.spacing_m = cell_spacing * float(1 << level)
				working.origin_world = layout.origin_world
				working.validity.resize(working.probe_count)
				working.relocation_offset_m.resize(working.probe_count)
				working.maximum_relocation_m = minf(SourceBaker.DEFAULT_MAX_RELOCATION_M, working.spacing_m * 0.2)
				check(SourceBaker.new()._classify_cells(working, volume, geometry, Callable(), Callable()),
					"independent classification succeeds at LOD %d" % level)
				check(working.validity == layout.validity.slice(layout.level_offsets[level], layout.level_offsets[level + 1]),
					"saved page core classifications match actual geometry at LOD %d" % level)
				check(working.relocation_offset_m == layout.relocation_offset_m.slice(layout.level_offsets[level], layout.level_offsets[level + 1]),
					"saved page core relocations match actual geometry at LOD %d" % level)
			var context := SourceBaker.make_olv_layout_context(volume, layout.geometry_signature,
				layout.origin_world, layout.dimensions, layout.prepared_level_count)
			var positions := PackedVector3Array()
			var labels := PackedByteArray()
			for index in layout.probe_count:
				positions.append(layout.cell_position(index))
				# Alternate domains by LOD so accidental fine-label replication is detected.
				labels.append(1 + layout.olv_cell_lod(index) % 2 if layout.cell_is_valid(index) else 0)
			var metadata := context.duplicate()
			metadata.merge({"target_label_set_sha256": "", "geometry_triangles_sha256": layout.geometry_triangles_sha256,
				"model_sha256": "1".repeat(64), "feature_schema_id": "test", "feature_schema_sha256": "2".repeat(64),
				"decision_policy_id": "test", "supported_probe_spacing_m": cell_spacing,
				"supported_target_cell_spacings_m": Inference.target_cell_spacings(layout),
				"feature_context_extent_m": Vector3.ONE * 0.5,
				"supported_feature_context_extents_m": PackedVector3Array([Vector3.ONE * 0.5]),
				"source_probe_positions": positions})
			var transient := layout.duplicate(false)
			var bound := SourceBaker.new().bind_olv_result(transient, {"labels": labels, "metadata": metadata}, context)
			check(bool(bound.get("ok", false)), "OLV binds every independently traced LOD: " + str(bound.get("error", "")))
			if bool(bound.get("ok", false)):
				check(bool(transient.olv_probe_domain_payload.validate_for_source(layout).get("ok", false)), "paged probe label payload is sealed")
				for index in layout.probe_count:
					if not layout.cell_is_valid(index): continue
					var identity := Domain.cell_identity(context.scene_id, context.volume_id,
						layout.olv_cell_lod(index), layout.cell_coordinates(index), context.layout_revision)
					check(bound.label_set.get_cell_label(identity) == labels[index], "each LOD keeps its own source label")
			if "--infer" in OS.get_cmdline_user_args():
				var started: Dictionary = await Inference.begin_bake()
				check(bool(started.get("ok", false)), "production OLV worker starts")
				if bool(started.get("ok", false)):
					var inferred: Dictionary = await started.runner.infer_source(layout, geometry, context)
					await started.runner.close()
					check(bool(inferred.get("ok", false)), "production model labels multires probes: " + str(inferred.get("error", "")))
					if bool(inferred.get("ok", false)):
						var classified := layout.duplicate(false)
						var model_bound := SourceBaker.new().bind_olv_result(classified, inferred, context)
						check(bool(model_bound.get("ok", false)), "production labels bind to the actual paged layout")
						if bool(model_bound.get("ok", false)):
							var snapshot := {"manifest": manifest, "olv_binding": {"managed": true, "enabled": true,
								"source_binding_valid": true, "manifest_instance_id": manifest.get_instance_id(),
								"payload": classified.olv_probe_domain_payload, "label_set": model_bound.label_set,
								"context": volume._manifest_olv_context(context, model_bound.label_set)}}
							check(not RenderPass.new()._validated_native_olv_binding(snapshot, Header.from_manifest(manifest)).is_empty(),
								"renderer accepts production OLV labels for a multiresolution header")
		var level_counts := PackedInt32Array()
		level_counts.resize(10)
		var samples: Dictionary = {}
		for entry in manifest.page_entries:
			var page := load(String(entry.resource_path)) as Page
			check(page != null and page.is_valid() and page.free_space_volume_source == null, "page reload has no dense raw source resource")
			var brick: Resource = page.prepared_transfer_brick
			check(is_equal_approx(brick.source_spacing_m, cell_spacing), "each real multires brick preserves base spacing")
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
