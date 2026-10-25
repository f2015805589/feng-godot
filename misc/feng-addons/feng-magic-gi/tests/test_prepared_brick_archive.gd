extends SceneTree
const Chunk = preload("../feng_magic_gi_volume_source_chunk.gd")
const Archive = preload("../feng_magic_gi_prepared_brick_archive.gd")
const Manifest = preload("../feng_magic_gi_manifest.gd")
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
	var source := fixture()
	check(source.is_valid(), "dense fixture validates")
	var sliced := Archive.slice_source(source, 2)
	check(bool(sliced.get("ok", false)), "prepared transport splits into bricks")
	if not bool(sliced.get("ok", false)): quit(1); return
	var ownership: Dictionary = {}
	for brick in sliced.bricks:
		check(brick.is_valid() and Archive.page_for(brick, "test").is_valid(), "brick and source-only page validate")
		var dims := Vector3i(source.clv_prepared_dimensions[brick.level * 3], source.clv_prepared_dimensions[brick.level * 3 + 1], source.clv_prepared_dimensions[brick.level * 3 + 2])
		for z in brick.dimensions.z:
			for y in brick.dimensions.y:
				for x in brick.dimensions.x:
					var global_cell: Vector3i = brick.cell_origin + Vector3i(x, y, z)
					var local_index: int = brick.cell_index(global_cell)
					var original_index: int = source.clv_prepared_offsets[brick.level] + (global_cell.z * dims.y + global_cell.y) * dims.x + global_cell.x
					var stride: int = brick.operator_stride()
					check(brick.validity[local_index] == source.clv_prepared_validity[original_index] \
						and brick.operators.slice(local_index * stride, (local_index + 1) * stride).to_byte_array() \
						== source.clv_prepared_operators.slice(original_index * stride, (original_index + 1) * stride).to_byte_array(), "core/halo coefficient bytes equal original")
		for z in brick.core_dimensions.z:
			for y in brick.core_dimensions.y:
				for x in brick.core_dimensions.x:
					var cell: Vector3i = brick.core_cell_origin + Vector3i(x, y, z)
					var key := str(brick.level) + ":" + str(cell)
					check(not ownership.has(key), "same-LOD core ownership is unique")
					ownership[key] = true
	check(ownership.size() == source.clv_prepared_validity.size(), "all original prepared cells retain ownership")
	var malformed: Resource = sliced.bricks[0].duplicate(true)
	malformed.operators[0] = NAN
	check(not malformed.is_valid(), "nonfinite transport is rejected")
	malformed = sliced.bricks[0].duplicate(true)
	malformed.cell_origin -= Vector3i.ONE * 2
	check(not malformed.is_valid(), "unbounded halo is rejected")
	check(not bool(Archive.slice_source(source, 0).get("ok", false)), "invalid brick axis rejected")
	check(not bool(Archive.slice_source(source, 2, func(): return true).get("ok", false)), "migration cancellation does not publish")
	var template := Manifest.new()
	template.generation = "source"
	template.world_bounds = source.domain_bounds_world
	template.configure([])
	var generation := "bricks_" + str(Time.get_ticks_usec())
	var saved := Archive.save_source(source, template, generation, "res://Temp/brick_archive", 2)
	check(bool(saved.get("ok", false)), "new generation saves and reloads")
	if bool(saved.get("ok", false)):
		var manifest: Resource = saved.manifest
		check(manifest.transport_domain == Archive.DOMAIN and manifest.prepared_level_count == 4, "manifest preserves actual level count")
		for entry in manifest.page_entries:
			var page := ResourceLoader.load(entry.resource_path, "", ResourceLoader.CACHE_MODE_IGNORE) as Page
			check(page != null and page.is_valid() and page.data == null and page.free_space_volume_source == null, "paged runtime loads prepared-only payload without raw source duplicates")
			var core: AABB = entry.core_bounds
			var keys: PackedStringArray = manifest.get_page_keys_for_level_bounds(int(entry.prepared_level), AABB(core.get_center(), Vector3.ONE * 0.001))
			check(keys.size() == 1 and keys[0] == entry.page_key, "level-specific spatial lookup visits the owning brick only")
		check(manifest.get_page_keys_for_level_bounds(9, source.domain_bounds_world).is_empty(), "unbaked level is not invented")
		check(manifest.get_page_keys_for_level_bounds(0, AABB(Vector3.ONE * 100, Vector3.ONE)).is_empty(), "outside-domain sparse lookup returns no page")
		var duplicate: Resource = manifest.duplicate(true)
		var entries: Array[Dictionary] = duplicate.page_entries.duplicate(true)
		var repeated: Dictionary = entries[0].duplicate(true)
		repeated.page_key = "duplicate_core"
		entries.append(repeated)
		duplicate.configure(entries)
		check(not duplicate.is_valid(), "same-level duplicate ownership still fails")
		check(not bool(Archive.save_source(source, template, generation, "res://Temp/brick_archive", 2).get("ok", false)), "immutable generation cannot be overwritten")
	print("MAGIC_GI_PREPARED_BRICK_ARCHIVE checks=", checks, " failures=", failures)
	quit(1 if failures else 0)

func fixture() -> Chunk:
	var source := Chunk.new()
	source.allocate(Vector3i(6, 3, 2), PackedStringArray())
	source.source_size_m = Vector3(source.dimensions) * 0.25
	source.source_transform_world = Transform3D(Basis.IDENTITY, source.source_size_m * 0.5)
	source.source_bounds_world = AABB(Vector3.ZERO, source.source_size_m)
	source.domain_bounds_world = source.source_bounds_world
	source.origin_world = Vector3.ONE * 0.125
	source.trace_distance_m = 8
	source.bake_samples = 1
	source.bake_bounces = 1
	source.moment_rays = 256
	source.validity.fill(1)
	for cell in source.probe_count:
		for texel in 64:
			source.receiver_visibility_moments[cell * 128 + texel * 2] = 2
			source.receiver_visibility_moments[cell * 128 + texel * 2 + 1] = 4
	source.directional_source_signature = source.make_directional_source_signature()
	source.clv_preparation_revision = Chunk.CLV_PREPARATION_REVISION_CURRENT
	source.clv_preparation_schema_version = 2
	source.clv_preparation_signature = source.directional_source_signature
	var total := 0
	for level in 4:
		var dims := Vector3i((Vector3(source.dimensions) / float(1 << level)).ceil())
		source.clv_prepared_offsets.append(total)
		source.clv_prepared_dimensions.append_array(PackedInt32Array([dims.x, dims.y, dims.z]))
		total += dims.x * dims.y * dims.z
	source.clv_prepared_validity.resize(total)
	source.clv_prepared_validity.fill(1)
	source.clv_prepared_operators.resize(total * 4 * 16)
	for i in source.clv_prepared_operators.size():
		source.clv_prepared_operators[i] = float(i % 23 - 11) * 0.01
	return source
