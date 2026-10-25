@tool
extends RefCounted
## New multi-resolution transport bake. Each level is independently path traced
## on the same global lattice and prepared in bounded tiles. Only immutable
## prepared bricks survive a tile; no world-sized .25 m source array is allocated.
const SourceBaker = preload("feng_magic_gi_volume_source_baker.gd")
const Placement = preload("feng_magic_gi_placement.gd")
const Builder = preload("feng_magic_gi_clv_transfer_builder.gd")
const Brick = preload("feng_magic_gi_prepared_transfer_brick.gd")
const Archive = preload("feng_magic_gi_prepared_brick_archive.gd")
const Manifest = preload("feng_magic_gi_manifest.gd")
const SceneTracker = preload("feng_magic_gi_scene_tracker.gd")
const Baker = preload("feng_magic_gi_baker.gd")
const SOURCE_HALO_CELLS := 6 # 1 output + ceil(1.5 + 2.6 + relocation/spacing).

static func settings_signature(volume: Node3D, options: Dictionary = {}) -> int:
	return hash(["multires_prepared_bake_sh2_v3", SOURCE_HALO_CELLS, Builder.REVISION, Builder.OUTPUT_SCHEMA_VERSION,
		SourceBaker.settings_signature(volume),
		int(options.get("prepared_levels", 10)), int(options.get("core_axis", 16)),
		int(options.get("samples", volume.bake_samples)), int(options.get("bounces", volume.bake_bounces)),
		float(options.get("trace_distance_m", volume.bake_distance)),
		int(options.get("moment_rays", maxi(int(options.get("samples", volume.bake_samples)), 256)))])

static func tile_layout(global_dimensions: Vector3i, level: int,
		core_origin: Vector3i, core_axis := 16) -> Dictionary:
	if level < 0 or level >= 10 or core_axis < 1 or core_axis > 16: return {}
	var dims := Vector3i((Vector3(global_dimensions) / float(1 << level)).ceil())
	for axis in 3:
		if dims[axis] <= 0 or core_origin[axis] < 0 or core_origin[axis] >= dims[axis] \
				or core_origin[axis] % core_axis != 0: return {}
	var core_size := (dims - core_origin).min(Vector3i.ONE * core_axis)
	var output_origin := (core_origin - Vector3i.ONE).max(Vector3i.ZERO)
	var output_end := (core_origin + core_size + Vector3i.ONE).min(dims)
	var source_origin := (core_origin - Vector3i.ONE * SOURCE_HALO_CELLS).max(Vector3i.ZERO)
	var source_end := (core_origin + core_size + Vector3i.ONE * SOURCE_HALO_CELLS).min(dims)
	return {"core_origin": core_origin, "core_dimensions": core_size,
		"output_origin": output_origin, "output_dimensions": output_end - output_origin,
		"source_origin": source_origin, "source_dimensions": source_end - source_origin,
		"level_dimensions": dims, "spacing": 0.25 * float(1 << level)}

func bake_async(volume: Node3D, generation: String, output_root: String,
		options: Dictionary = {}, progress := Callable(), cancelled := Callable()) -> Dictionary:
	if not is_instance_valid(volume) or not volume.is_inside_tree() or generation.is_empty() \
			or not output_root.begins_with("res://"):
		return {"ok": false, "error": "paged_bake_requires_volume_generation_and_output"}
	var levels := int(options.get("prepared_levels", 10))
	var core_axis := int(options.get("core_axis", 16))
	if levels < 1 or levels > 10 or core_axis < 1 or core_axis > 16:
		return {"ok": false, "error": "invalid_paged_level_or_brick_size"}
	var transform: Transform3D = volume.global_transform
	var size: Vector3 = volume.size
	var domain: AABB = transform * AABB(-size * 0.5, size)
	if not domain.position.is_finite() or not domain.size.is_finite() \
			or minf(domain.size.x, minf(domain.size.y, domain.size.z)) <= 0:
		return {"ok": false, "error": "invalid_paged_world_domain"}
	var global_dimensions := Vector3i((domain.size / 0.25).ceil())
	var global_origin := domain.position + Vector3.ONE * 0.125
	var trace_distance := float(options.get("trace_distance_m", volume.bake_distance))
	var bounces := int(options.get("bounces", volume.bake_bounces))
	var root := output_root.path_join("generation_" + generation)
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(root)):
		return {"ok": false, "error": "generation_already_exists"}
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(root)) != OK:
		return {"ok": false, "error": "generation_directory_failed"}
	if progress.is_valid(): progress.call("Capturing paged transport geometry", 0, 1, 0, 0)
	var geometry := Placement.new()
	if not geometry.collect(volume, true, true, true, false, domain.grow(trace_distance * float(bounces + 1))):
		return {"ok": false, "error": "paged_geometry_capture_failed: " + geometry.error_message}
	var geometry_signature := SourceBaker.geometry_signature_for(geometry)
	var emitter_ids: PackedStringArray = geometry.emitters.keys.duplicate()
	var emitter_signatures: PackedInt64Array = geometry.emitters.static_signatures.duplicate()
	if emitter_ids.size() > 32: return {"ok": false, "error": "paged_emitter_limit_exceeded"}
	var samples := int(options.get("samples", volume.bake_samples))
	var moment_rays := int(options.get("moment_rays",
			maxi(samples, SourceBaker.MIN_MOMENT_RAYS)))
	if progress.is_valid():
		progress.call("Preparing free-space sample coordinates", 0, 1, 0, 0)
	var sampling_cache := SourceBaker.make_sampling_cache(samples, bounces, moment_rays)
	if not bool(sampling_cache.get("ok", false)):
		return {"ok": false, "error": "invalid_samples_bounces_or_moment_rays"}
	if progress.is_valid():
		progress.call("Preparing free-space sample coordinates", 1, 1, 0, 0)
	var baked_settings_signature := settings_signature(volume, options)
	var source_signature := "%x" % hash([geometry_signature, baked_settings_signature, global_origin, global_dimensions, emitter_ids, emitter_signatures])
	var entries: Array[Dictionary] = []
	var peak_source_cells := 0
	var maximum_operator_bound := 0.0
	var completed_tiles := 0
	var total_tiles := 0
	var surface_target_cache: Dictionary = {}
	var surface_target_constraints := 0
	var surface_target_cache_hits := 0
	var surface_direct_probes := 0
	var surface_direct_samples := 0
	var surface_direct_bake_usec := 0
	for level in levels:
		var dims := Vector3i((Vector3(global_dimensions) / float(1 << level)).ceil())
		total_tiles += ceili(float(dims.x) / core_axis) * ceili(float(dims.y) / core_axis) * ceili(float(dims.z) / core_axis)
	# Coarse levels become available first on disk, but only the fully completed
	# manifest is published, so cancellation never replaces an existing bake.
	for level in range(levels - 1, -1, -1):
		var dims := Vector3i((Vector3(global_dimensions) / float(1 << level)).ceil())
		for z in range(0, dims.z, core_axis):
			for y in range(0, dims.y, core_axis):
				for x in range(0, dims.x, core_axis):
					if cancelled.is_valid() and bool(cancelled.call()): return {"ok": false, "error": "cancelled"}
					var tile := tile_layout(global_dimensions, level, Vector3i(x, y, z), core_axis)
					var source_dims: Vector3i = tile.source_dimensions
					peak_source_cells = maxi(peak_source_cells, source_dims.x * source_dims.y * source_dims.z)
					var working := options.duplicate()
					working["multires_working_chunk"] = true
					working["source_spacing_m"] = tile.spacing
					working["source_level"] = level
					working["global_cell_origin"] = tile.source_origin
					working["_magic_gi_sampling_cache"] = sampling_cache
					working["source_bounds_world"] = AABB(global_origin + Vector3(tile.source_origin) * tile.spacing - Vector3.ONE * tile.spacing * 0.5,
							Vector3(source_dims) * tile.spacing)
					working["captured_geometry"] = geometry
					var baked: Dictionary = await SourceBaker.new().bake_async(volume, working, progress, cancelled)
					if not bool(baked.get("ok", false)): return baked
					if not bool(baked.get("empty", false)):
						var builder := Builder.new()
						var prepared: Dictionary = await builder.prepare_region_async(baked.chunk, geometry,
							tile.output_origin - tile.source_origin, tile.output_dimensions,
							cancelled, progress, sampling_cache.coordinates, surface_target_cache, level)
						if not bool(prepared.get("ok", false)): return prepared
						var target_stats: Dictionary = prepared.stats
						surface_target_constraints += int(target_stats.get("surface_target_constraints", 0))
						surface_target_cache_hits += int(target_stats.get("surface_target_cache_hits", 0))
						surface_direct_probes += int(target_stats.get("surface_direct_probes", 0))
						surface_direct_samples += int(target_stats.get("surface_direct_samples", 0))
						surface_direct_bake_usec += int(target_stats.get("surface_direct_bake_usec", 0))
						var brick := Brick.new()
						brick.operator_schema_version = int(prepared.get("operator_schema_version", 0))
						brick.source_origin_world = global_origin
						brick.level = level
						brick.cell_origin = tile.output_origin
						brick.dimensions = tile.output_dimensions
						brick.core_cell_origin = tile.core_origin
						brick.core_dimensions = tile.core_dimensions
						brick.operators = prepared.operators
						brick.validity = prepared.validity
						brick.probe_count = brick.cell_count()
						brick.source_transform_world = transform
						brick.source_size_m = size
						brick.domain_bounds_world = domain
						brick.emitter_count = emitter_ids.size()
						brick.emitter_ids = emitter_ids
						brick.emitter_static_signatures = emitter_signatures
						brick.geometry_signature = geometry_signature
						brick.directional_source_signature = source_signature
						brick.maximum_operator_row_l1 = float(prepared.stats.maximum_operator_row_l1)
						maximum_operator_bound = maxf(maximum_operator_bound, brick.maximum_operator_row_l1)
						if _core_has_support(brick):
							if progress.is_valid():
								progress.call("Writing prepared CLV page", completed_tiles, total_tiles,
										level + 1, levels)
							var saved := Archive.save_page(brick, generation, root)
							if not bool(saved.get("ok", false)): return saved
							entries.append(saved.entry)
						builder = null
						prepared.clear()
					baked.clear()
					completed_tiles += 1
					if progress.is_valid(): progress.call("Baking paged CLV bricks", completed_tiles, total_tiles, level + 1, levels)
					await volume.get_tree().process_frame
	if entries.is_empty(): return {"ok": false, "error": "no_supported_prepared_bricks"}
	var manifest := Manifest.new()
	manifest.generation = generation
	manifest.manifest_key = Baker.new()._stable_manifest_key(output_root, SceneTracker.scene_identity(volume), SceneTracker.scene_relative_path(volume))
	manifest.scene_identity = SceneTracker.scene_identity(volume)
	manifest.volume_identity = SceneTracker.scene_relative_path(volume)
	manifest.transport_domain = Archive.DOMAIN
	manifest.world_bounds = domain
	manifest.management_block_size = 512.0
	manifest.page_core_size = core_axis * 0.25 * float(1 << (levels - 1))
	manifest.bake_geometry_signature = geometry_signature
	manifest.bake_settings_signature = baked_settings_signature
	manifest.bake_samples = samples
	manifest.bake_bounces = bounces
	manifest.bake_moment_rays = moment_rays
	manifest.scene_watch_signature = int(options.get("scene_watch_signature", 0))
	manifest.scene_watch_signature_schema_version = SceneTracker.SIGNATURE_SCHEMA_CURRENT
	manifest.prepared_source_origin_world = global_origin
	manifest.prepared_level_count = levels
	manifest.prepared_core_axis = core_axis
	manifest.prepared_bake_algorithm = "multires_independent_transport_sh2_v3"
	manifest.prepared_emitter_ids = emitter_ids
	manifest.prepared_emitter_static_signatures = emitter_signatures
	manifest.prepared_source_signature = source_signature
	manifest.prepared_source_transform_world = transform
	manifest.prepared_source_size_m = size
	manifest.prepared_maximum_operator_row_l1 = maximum_operator_bound
	manifest.prepared_operator_schema_version = Builder.OUTPUT_SCHEMA_VERSION
	manifest.configure(entries)
	if cancelled.is_valid() and bool(cancelled.call()): return {"ok": false, "error": "cancelled"}
	if progress.is_valid(): progress.call("Writing prepared CLV manifest", 0, 1, 0, 0)
	var result := Archive.save_manifest(manifest, root)
	result["peak_working_source_cells"] = peak_source_cells
	result["completed_tiles"] = completed_tiles
	result["generation"] = generation
	result["geometry_signature"] = geometry_signature
	result["directional_source_signature"] = source_signature
	result["surface_target_stats"] = {"constraints": surface_target_constraints,
		"cache_hits": surface_target_cache_hits, "direct_probes": surface_direct_probes,
		"direct_samples": surface_direct_samples, "direct_bake_usec": surface_direct_bake_usec,
		"cache_entries_after_bake": surface_target_cache.size(),
		"cache_entry_limit": Builder.SURFACE_TARGET_CACHE_LIMIT}
	return result

static func _core_has_support(brick: Brick) -> bool:
	for z in brick.core_dimensions.z:
		for y in brick.core_dimensions.y:
			for x in brick.core_dimensions.x:
				if brick.validity[brick.cell_index(brick.core_cell_origin + Vector3i(x, y, z))] != 0: return true
	return false
