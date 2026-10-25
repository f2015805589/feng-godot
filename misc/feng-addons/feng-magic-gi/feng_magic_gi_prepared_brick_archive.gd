@tool
extends RefCounted
## Exact slicing/persistence of versioned prepared linear transport.
const Chunk = preload("feng_magic_gi_volume_source_chunk.gd")
const Builder = preload("feng_magic_gi_clv_transfer_builder.gd")
const Brick = preload("feng_magic_gi_prepared_transfer_brick.gd")
const Page = preload("feng_magic_gi_page.gd")
const Manifest = preload("feng_magic_gi_manifest.gd")
const DOMAIN := "prepared_free_space_bricks_v1"
const TRANSPORT_DOMAIN := DOMAIN

static func slice_source(source: Chunk, core_axis := 16,
		cancelled := Callable()) -> Dictionary:
	if source == null or not source.is_valid() or not source.has_preinterpolated_clv() \
			or core_axis < 1 or core_axis > 32:
		return {"ok": false, "error": "valid_prepared_source_and_brick_size_required"}
	var bricks: Array[Resource] = []
	for level in source.clv_prepared_offsets.size():
		var dims := Vector3i(source.clv_prepared_dimensions[level * 3],
				source.clv_prepared_dimensions[level * 3 + 1], source.clv_prepared_dimensions[level * 3 + 2])
		for z in range(0, dims.z, core_axis):
			for y in range(0, dims.y, core_axis):
				for x in range(0, dims.x, core_axis):
					if cancelled.is_valid() and bool(cancelled.call()): return {"ok": false, "error": "cancelled"}
					var core := Vector3i(x, y, z)
					var core_size := (dims - core).min(Vector3i.ONE * core_axis)
					var brick := _slice(source, level, core, core_size, dims)
					if brick != null: bricks.append(brick)
	return {"ok": true, "bricks": bricks, "level_count": source.clv_prepared_offsets.size()}

static func _slice(source: Chunk, level: int, core: Vector3i,
		core_size: Vector3i, dims: Vector3i) -> Brick:
	if source.clv_preparation_schema_version != 2:
		return null
	var offset := source.clv_prepared_offsets[level]
	var any_valid := false
	for z in range(core.z, core.z + core_size.z):
		for y in range(core.y, core.y + core_size.y):
			for x in range(core.x, core.x + core_size.x):
				if source.clv_prepared_validity[offset + (z * dims.y + y) * dims.x + x] != 0:
					any_valid = true
	if not any_valid: return null
	var brick := Brick.new()
	brick.operator_schema_version = 2
	brick.source_origin_world = source.origin_world
	brick.level = level
	brick.cell_origin = (core - Vector3i.ONE).max(Vector3i.ZERO)
	brick.dimensions = (core + core_size + Vector3i.ONE).min(dims) - brick.cell_origin
	brick.core_cell_origin = core
	brick.core_dimensions = core_size
	brick.source_transform_world = source.source_transform_world
	brick.source_size_m = source.source_size_m
	brick.domain_bounds_world = source.domain_bounds_world
	brick.emitter_count = source.emitter_count
	brick.emitter_ids = source.emitter_ids
	brick.emitter_static_signatures = source.emitter_static_signatures
	brick.geometry_signature = source.geometry_signature
	brick.directional_source_signature = source.directional_source_signature
	brick.maximum_operator_row_l1 = float(source.clv_preparation_stats.get("maximum_operator_row_l1", 0.0))
	brick.probe_count = brick.cell_count()
	var stride := brick.operator_stride()
	brick.validity.resize(brick.probe_count)
	for z in brick.dimensions.z:
		for y in brick.dimensions.y:
			for x in brick.dimensions.x:
				var cell := brick.cell_origin + Vector3i(x, y, z)
				var source_index := offset + (cell.z * dims.y + cell.y) * dims.x + cell.x
				var target := (z * brick.dimensions.y + y) * brick.dimensions.x + x
				brick.validity[target] = source.clv_prepared_validity[source_index]
				brick.operators.append_array(source.clv_prepared_operators.slice(source_index * stride, (source_index + 1) * stride))
	return brick

static func page_for(brick: Brick, generation: String) -> Page:
	var page := Page.new()
	page.generation = generation
	page.page_key = "prepared_l%d_%d_%d_%d" % [brick.level, brick.core_cell_origin.x, brick.core_cell_origin.y, brick.core_cell_origin.z]
	page.core_bounds = brick.core_bounds()
	page.support_bounds = brick.support_bounds()
	page.probe_count = brick.probe_count
	page.geometry_signature = brick.geometry_signature
	page.settings_signature = hash([brick.directional_source_signature, brick.level, brick.core_cell_origin, brick.core_dimensions])
	page.prepared_transfer_brick = brick
	page.cpu_bytes = brick.estimated_cpu_resident_bytes()
	page.gpu_bytes = brick.estimated_gpu_payload_bytes()
	return page

static func save_page(brick: Brick, generation: String, generation_root: String) -> Dictionary:
	if brick == null or not brick.is_valid() or generation.is_empty():
		return {"ok": false, "error": "invalid_prepared_brick"}
	var page := page_for(brick, generation)
	var path := generation_root.path_join(page.page_key + ".res")
	if ResourceSaver.save(page, path, ResourceSaver.FLAG_COMPRESS) != OK:
		return {"ok": false, "error": "prepared_page_save_failed"}
	return {"ok": true, "entry": {
		"page_key": page.page_key, "page_generation": generation,
		"core_bounds": page.core_bounds, "support_bounds": page.support_bounds,
		"influence_bounds": page.support_bounds, "probe_count": page.probe_count,
		"cpu_bytes": page.cpu_bytes, "gpu_bytes": page.gpu_bytes,
		"geometry_signature": page.geometry_signature, "settings_signature": page.settings_signature,
		"prepared_level": brick.level, "cell_origin": brick.cell_origin, "dimensions": brick.dimensions,
		"core_cell_origin": brick.core_cell_origin, "core_dimensions": brick.core_dimensions,
		"prepared_source_signature": brick.directional_source_signature,
		"prepared_operator_schema_version": brick.operator_schema_version,
		"maximum_operator_row_l1": brick.maximum_operator_row_l1,
		"resource_path": path, "content_hash": FileAccess.get_sha256(path), "empty": false}}

static func save_source(source: Chunk, template: Manifest, generation: String,
		output_root: String, core_axis := 16, cancelled := Callable()) -> Dictionary:
	if template == null or not template.is_valid() or generation.is_empty() or not output_root.begins_with("res://"):
		return {"ok": false, "error": "valid_template_generation_and_output_required"}
	var result := slice_source(source, core_axis, cancelled)
	if not bool(result.get("ok", false)): return result
	var root := output_root.path_join("generation_" + generation)
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(root)):
		return {"ok": false, "error": "generation_already_exists"}
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(root)) != OK:
		return {"ok": false, "error": "generation_directory_failed"}
	var entries: Array[Dictionary] = []
	for brick in result.bricks:
		if cancelled.is_valid() and bool(cancelled.call()): return {"ok": false, "error": "cancelled"}
		var saved := save_page(brick, generation, root)
		if not bool(saved.get("ok", false)): return saved
		entries.append(saved.entry)
	var manifest := template.duplicate(true) as Manifest
	manifest.generation = generation
	manifest.transport_domain = DOMAIN
	manifest.prepared_source_origin_world = source.origin_world
	manifest.prepared_core_axis = core_axis
	manifest.prepared_bake_algorithm = "prepared_clv_sh2_l0_l1_v3"
	manifest.bake_settings_signature = hash([manifest.bake_settings_signature,
		Builder.REVISION])
	if template.get_page_count() == 1:
		manifest.prepared_debug_source_path = String(template.page_entries[0].get("resource_path", ""))
	manifest.prepared_level_count = int(result.level_count)
	manifest.prepared_emitter_ids = source.emitter_ids
	manifest.prepared_emitter_static_signatures = source.emitter_static_signatures
	manifest.prepared_source_signature = source.directional_source_signature
	manifest.prepared_operator_schema_version = source.clv_preparation_schema_version
	manifest.prepared_source_transform_world = source.source_transform_world
	manifest.prepared_source_size_m = source.source_size_m
	manifest.prepared_maximum_operator_row_l1 = float(source.clv_preparation_stats.get("maximum_operator_row_l1", 0.0))
	manifest.page_core_size = core_axis * 0.25 * float(1 << (manifest.prepared_level_count - 1))
	manifest.management_block_size = maxf(512.0, manifest.page_core_size)
	manifest.configure(entries)
	return save_manifest(manifest, root)

static func save_manifest(manifest: Manifest, generation_root: String) -> Dictionary:
	if not manifest.is_valid(): return {"ok": false, "error": manifest.get_index_error()}
	var path := generation_root.path_join("manifest_" + manifest.generation + ".res")
	if ResourceSaver.save(manifest, path, ResourceSaver.FLAG_COMPRESS) != OK:
		return {"ok": false, "error": "prepared_manifest_save_failed"}
	var verified := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as Manifest
	if verified == null or not verified.is_valid(): return {"ok": false, "error": "prepared_manifest_reload_failed"}
	return {"ok": true, "manifest": verified, "manifest_path": path, "page_count": verified.get_page_count()}
