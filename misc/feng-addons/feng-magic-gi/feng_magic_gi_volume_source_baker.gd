@tool
class_name FMagicGIVolumeSourceBaker
extends RefCounted
## Offline regular free-space transport bake. This writes a new source domain and
## never converts or relabels the legacy surface-offset FMagicGIData payload.

const Data = preload("feng_magic_gi_data.gd")
const Volume = preload("feng_magic_gi_volume.gd")
const Placement = preload("feng_magic_gi_placement.gd")
const BakeJob = preload("feng_magic_gi_bake_job.gd")
const Chunk = preload("feng_magic_gi_volume_source_chunk.gd")
const SourceArchive = preload("feng_magic_gi_source_archive.gd")
const MultiresBakeChunk = preload("feng_magic_gi_multires_bake_chunk.gd")
const Baker = preload("feng_magic_gi_baker.gd")
const Page = preload("feng_magic_gi_page.gd")
const Manifest = preload("feng_magic_gi_manifest.gd")
const SceneTracker = preload("feng_magic_gi_scene_tracker.gd")
const MIN_MOMENT_RAYS := 256
const DEFAULT_WORK_BUDGET_PER_BATCH := 8000000
const DEFAULT_MAX_RELOCATION_M := 0.05
const MAX_BAKE_SAMPLES := 65536
const MAX_BAKE_BOUNCES := 8
const MAX_MOMENT_RAYS := 65536
const TRANSPORT_DOMAIN := "regular_free_space_clv_v1"

func bake_paged_async(volume: Node3D, generation: String, output_root: String,
		options: Dictionary = {}, progress := Callable(), cancelled := Callable()) -> Dictionary:
	var script := load("res://addons/feng-magic-gi/feng_magic_gi_paged_source_baker.gd") as Script
	return await script.new().bake_async(volume, generation, output_root, options, progress, cancelled)

class SourcePackJob:
	extends RefCounted
	var result: Dictionary = {}
	func run(source: Resource) -> void:
		result = SourceArchive.pack(source)

const RELOCATION_DIRECTIONS := [
	Vector3.RIGHT, Vector3.LEFT, Vector3.UP, Vector3.DOWN, Vector3.BACK, Vector3.FORWARD,
	Vector3(1, 1, 1), Vector3(-1, 1, 1), Vector3(1, -1, 1), Vector3(1, 1, -1),
	Vector3(-1, -1, 1), Vector3(-1, 1, -1), Vector3(1, -1, -1), Vector3(-1, -1, -1),
	Vector3(1, 1, 0), Vector3(1, -1, 0), Vector3(-1, 1, 0), Vector3(-1, -1, 0),
	Vector3(1, 0, 1), Vector3(1, 0, -1), Vector3(-1, 0, 1), Vector3(-1, 0, -1),
	Vector3(0, 1, 1), Vector3(0, 1, -1), Vector3(0, -1, 1), Vector3(0, -1, -1),
]

## `options` keys: samples, bounces, trace_distance_m, moment_rays,
## maximum_relocation_m, and max_work_per_batch. Work is split into bounded
## worker batches; sample counts are either honored exactly or rejected. The
## batch budget counts estimated trace-work units, not a measured ray total.
func bake_async(volume: Node3D, options: Dictionary = {},
		progress: Callable = Callable(), cancelled: Callable = Callable()) -> Dictionary:
	if not is_instance_valid(volume) or not volume is Volume or not volume.is_inside_tree():
		return _failure("A free-space source bake requires an in-tree FMagicGIVolume.")
	var samples := int(options.get("samples", volume.bake_samples))
	var multires := bool(options.get("multires_working_chunk", false))
	var source_spacing := float(options.get("source_spacing_m", Chunk.CELL_SPACING_M)) if multires else Chunk.CELL_SPACING_M
	if source_spacing not in [0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 16.0, 32.0, 64.0, 128.0]:
		return _failure("Invalid multiresolution source spacing.")
	var bounces := int(options.get("bounces", volume.bake_bounces))
	var trace_distance := float(options.get("trace_distance_m", volume.bake_distance))
	var moment_rays := int(options.get("moment_rays", maxi(samples, MIN_MOMENT_RAYS)))
	var maximum_relocation := float(options.get("maximum_relocation_m",
			DEFAULT_MAX_RELOCATION_M))
	var max_work_per_batch := int(options.get("max_work_per_batch",
			DEFAULT_WORK_BUDGET_PER_BATCH))
	if samples <= 0 or samples > MAX_BAKE_SAMPLES \
			or bounces <= 0 or bounces > MAX_BAKE_BOUNCES \
			or not is_finite(trace_distance) or trace_distance <= 0.0 or trace_distance > 4096.0 \
			or moment_rays < MIN_MOMENT_RAYS or moment_rays > MAX_MOMENT_RAYS \
			or not is_finite(maximum_relocation) or maximum_relocation < 0.0 \
			or maximum_relocation > Chunk.CELL_SPACING_M * 0.2 \
			or max_work_per_batch <= 0:
		return _failure("Invalid bake settings; samples are never silently reduced and moments require at least 256 rays.")
	var source_size: Vector3 = volume.size
	var source_transform: Transform3D = volume.global_transform
	if not source_size.is_finite() or minf(source_size.x, minf(source_size.y, source_size.z)) <= 0.0 \
			or not source_transform.is_finite() \
			or absf(source_transform.basis.determinant()) < 0.00000001:
		return _failure("The source volume has a non-finite or singular world transform/size.")
	var source_local_bounds := AABB(-source_size * 0.5, source_size)
	var source_bounds_world: AABB = source_transform * source_local_bounds
	if multires:
		source_bounds_world = options.get("source_bounds_world", source_bounds_world)
		source_size = source_bounds_world.size
		source_transform = Transform3D(Basis.IDENTITY, source_bounds_world.get_center())
	var dimensions := Vector3i((source_bounds_world.size / source_spacing).ceil())
	if dimensions.x <= 0 or dimensions.y <= 0 or dimensions.z <= 0 \
			or dimensions.x > Chunk.MAX_AXIS or dimensions.y > Chunk.MAX_AXIS \
			or dimensions.z > Chunk.MAX_AXIS:
		return _failure("The .25m free-space grid exceeds the supported per-axis extent.")
	# A path may advance one maximum-distance segment at every bounce; collecting
	# only one segment around the volume would silently omit farther indirect hits.
	var collection_bounds := source_bounds_world.grow(trace_distance * float(bounces + 1))
	var geometry: RefCounted = options.get("captured_geometry") if multires else null
	if geometry == null: geometry = Placement.new()
	if not (multires and options.has("captured_geometry")) \
			and not geometry.collect(volume, true, true, true, false, collection_bounds):
		return _failure("Geometry capture failed: " + geometry.error_message)
	if not geometry.error_message.is_empty():
		return _failure("Geometry capture failed: " + geometry.error_message)
	var emitter_ids: PackedStringArray = geometry.emitters.keys.duplicate()
	var emitter_signatures: PackedInt64Array = geometry.emitters.static_signatures.duplicate()
	if emitter_ids.size() > Data.MAX_EMITTERS \
			or emitter_signatures.size() != emitter_ids.size():
		return _failure("The captured emissive-source identity/signature list is inconsistent or exceeds the supported source count.")
	var source: Chunk = MultiresBakeChunk.new() if multires else Chunk.new()
	if not source.allocate(dimensions, emitter_ids):
		return _failure("The free-space chunk exceeds the supported cell or memory budget for its %d emitters." % emitter_ids.size())
	if multires: source.format_version = 3
	source.spacing_m = source_spacing
	source.origin_world = source_bounds_world.position + Vector3.ONE * (source_spacing * 0.5)
	source.source_transform_world = source_transform
	source.source_size_m = source_size
	source.source_bounds_world = source_bounds_world
	source.domain_bounds_world = source_bounds_world
	source.trace_distance_m = trace_distance
	source.bake_samples = samples
	source.bake_bounces = bounces
	source.moment_rays = moment_rays
	source.maximum_relocation_m = maximum_relocation
	source.emitter_ids = emitter_ids
	source.emitter_count = emitter_ids.size()
	source.emitter_static_signatures = emitter_signatures
	source.geometry_signature = geometry_signature_for(geometry)
	source.directional_source_signature = source.make_directional_source_signature()
	if not _classify_cells(source, volume, geometry, progress, cancelled):
		return _failure("Free-space cell classification was cancelled or failed.")
	var sampling_cache: Dictionary = options.get("_magic_gi_sampling_cache", {})
	var reused_sampling_cache := _sampling_cache_matches(sampling_cache, samples, bounces, moment_rays)
	if progress.is_valid():
		progress.call("Classifying free-space cells", source.probe_count, source.probe_count, 0, 0)
		if not reused_sampling_cache:
			progress.call("Preparing free-space sample coordinates", 0, 1, 0, 0)
	var scratch := _make_worker_input(source, volume,
			options.get("global_cell_origin", Vector3i.ZERO), int(options.get("source_level", -1)) if multires else -1)
	if not reused_sampling_cache:
		sampling_cache = make_sampling_cache(samples, bounces, moment_rays)
	if not bool(sampling_cache.get("ok", false)):
		return _failure("Could not prepare deterministic free-space sample coordinates.")
	var coordinates: Array[PackedFloat64Array] = sampling_cache.coordinates
	var minimum_moment_coordinates: Array[PackedFloat64Array] = sampling_cache.minimum_moment_coordinates
	var extra_moment_coordinates: Array[PackedFloat64Array] = sampling_cache.extra_moment_coordinates
	var estimated_work_units_per_cell := samples * (bounces + 1) \
			* (1 + source.emitter_count) + moment_rays
	if estimated_work_units_per_cell > max_work_per_batch:
		return _failure("One cell estimates %d trace-work units, above max_work_per_batch=%d; increase the explicit batch budget or reduce bake quality yourself." % [
			estimated_work_units_per_cell, max_work_per_batch])
	var worker_limit := clampi(OS.get_processor_count() - 2, 1, 8)
	var jobs_per_batch := mini(worker_limit, maxi(1,
			floori(float(max_work_per_batch) / float(estimated_work_units_per_cell))))
	var valid_indices := PackedInt32Array()
	for index in source.probe_count:
		if source.cell_is_valid(index):
			valid_indices.append(index)
	if valid_indices.is_empty():
		if multires: return {"ok": true, "empty": true}
		return _failure("No regular grid centers were classified as safe free-space samples.")
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return _failure("The chunked baker needs a SceneTree to yield between bounded worker batches.")
	var completed := 0
	var rejected_transport_cells := 0
	var batch_count := ceili(float(valid_indices.size()) / float(jobs_per_batch))
	if progress.is_valid():
		if not reused_sampling_cache:
			progress.call("Preparing free-space sample coordinates", 1, 1, 0, 0)
		progress.call("Baking free-space transfer", 0, valid_indices.size(), 0, batch_count)
	for batch_start in range(0, valid_indices.size(), jobs_per_batch):
		if _cancelled(cancelled):
			return _failure("Free-space transport bake was cancelled.")
		var pending: Dictionary = {}
		var batch_end := mini(batch_start + jobs_per_batch, valid_indices.size())
		for valid_index in range(batch_start, batch_end):
			var cell := int(valid_indices[valid_index])
			var job := BakeJob.new()
			job.initialize(scratch, cell)
			var task_id := WorkerThreadPool.add_task(Callable(job, "run").bind(
					geometry.trace_scene, source.geometry_signature, cell, coordinates,
					minimum_moment_coordinates, extra_moment_coordinates, moment_rays),
					false, "Magic GI Free-Space Source Bake")
			if task_id < 0:
				for pending_id in pending:
					WorkerThreadPool.wait_for_task_completion(int(pending_id))
				return _failure("Could not start a bounded free-space transport worker batch.")
			pending[task_id] = {"job": job, "cell": cell}
		while not pending.is_empty():
			var finished_ids := PackedInt64Array()
			for pending_id in pending:
				if WorkerThreadPool.is_task_completed(int(pending_id)):
					finished_ids.append(int(pending_id))
			if finished_ids.is_empty():
				await tree.process_frame
				continue
			for task_id in finished_ids:
				WorkerThreadPool.wait_for_task_completion(task_id)
				var record: Dictionary = pending[task_id]
				pending.erase(task_id)
				var job: BakeJob = record.job
				var cell := int(record.cell)
				if not job.valid:
					for other_id in pending:
						WorkerThreadPool.wait_for_task_completion(int(other_id))
					return _failure("The CPU trace worker failed for free-space cell %d." % cell)
				if not _merge_cell(source, cell, job.result):
					_clear_cell(source, cell)
					rejected_transport_cells += 1
				completed += 1
		if progress.is_valid():
			progress.call("Baking free-space transfer", completed, valid_indices.size(),
					batch_start / jobs_per_batch + 1, batch_count)
		await tree.process_frame
	if _cancelled(cancelled):
		return _failure("Free-space transport bake was cancelled.")
	if not source.is_valid(source.geometry_signature, source.emitter_ids,
			source.emitter_static_signatures):
		return _failure("The completed free-space source chunk failed structural validation.")
	if multires:
		return {"ok": true, "chunk": source, "empty": false,
			"geometry_signature": source.geometry_signature, "valid_cells": valid_indices.size()}
	var clv_builder_script := load("res://addons/feng-magic-gi/feng_magic_gi_clv_transfer_builder.gd") as Script
	if clv_builder_script == null:
		return _failure("The CLV transfer preinterpolator is unavailable.")
	var clv_builder: RefCounted = clv_builder_script.new()
	var clv_result: Dictionary = await clv_builder.prepare_async(source, geometry,
		cancelled, progress, coordinates, {})
	if not bool(clv_result.get("ok", false)):
		return _failure("CLV transfer preparation failed: " + str(clv_result.get("error", "invalid_output")))
	# Keep every valid baked probe and all prepared operators exactly. Packing
	# removes only the zero payloads of invalid grid slots, after preparation.
	if progress.is_valid():
		progress.call("Packing valid source probe payloads", 0, 1, 0, 0)
	var pack_job := SourcePackJob.new()
	var pack_task := WorkerThreadPool.add_task(pack_job.run.bind(source), false,
		"Magic GI source payload packing")
	if pack_task < 0:
		return _failure("Could not start source payload packing.")
	while not WorkerThreadPool.is_task_completed(pack_task):
		await tree.process_frame
	WorkerThreadPool.wait_for_task_completion(pack_task)
	if _cancelled(cancelled):
		return _failure("Free-space source packing was cancelled.")
	if not bool(pack_job.result.get("ok", false)):
		return _failure("Free-space source packing failed: " + str(pack_job.result.get("error", "invalid_output")))
	source = pack_job.result.chunk as Chunk
	var valid_count := 0
	var relocated_count := 0
	for state in source.validity:
		if state == Chunk.RELOCATION_STATUS_VALID:
			valid_count += 1
		elif state == Chunk.RELOCATION_STATUS_RELOCATED:
			valid_count += 1
			relocated_count += 1
	return {
		"ok": true,
		"chunk": source,
		"probe_count": source.probe_count,
		"stored_probe_count": source.stored_valid_cell_count(),
		"source_storage_layout": source.source_storage_layout(),
		"valid_cells": valid_count,
		"relocated_cells": relocated_count,
		"invalid_cells": source.probe_count - valid_count,
		"rejected_transport_cells": rejected_transport_cells,
		"estimated_work_units_per_cell": estimated_work_units_per_cell,
		"estimated_work_units_total": estimated_work_units_per_cell * valid_count,
		"work_per_cell": estimated_work_units_per_cell,
		"jobs_per_batch": jobs_per_batch,
		"batches": batch_count,
		"geometry_signature": source.geometry_signature,
		"directional_source_signature": source.directional_source_signature,
	}

## Attach a completed chunk to a source-only immutable page. The chunk has already
## passed deep validation in bake_async; callers may then save the chunk/page and
## add the page metadata to their manifest using the normal page-store workflow.
static func populate_page(page: Resource, chunk: Resource,
		page_generation: String, page_key: String) -> bool:
	if page == null or not page is Page or chunk == null or not chunk is Chunk \
			or page_generation.is_empty() or page_key.is_empty() \
			or not chunk.is_valid():
		return false
	page.format_version = 1
	page.generation = page_generation
	page.page_key = page_key
	page.core_bounds = chunk.domain_bounds_world
	page.support_bounds = chunk.domain_bounds_world
	page.probe_count = chunk.probe_count
	page.geometry_signature = chunk.geometry_signature
	page.settings_signature = hash([chunk.directional_source_signature,
		chunk.bake_samples, chunk.bake_bounces, chunk.trace_distance_m,
		chunk.moment_rays])
	page.data = null
	page.free_space_volume_source = chunk
	page.cpu_bytes = chunk.estimated_cpu_resident_bytes()
	page.gpu_bytes = chunk.estimated_gpu_payload_bytes()
	return page.is_header_valid(page_generation, page_key)

## Persist one immutable source-only page and its manifest. The caller publishes
## the returned Manifest only after this method has saved and reloaded both files.
static func save_generation(volume: Node3D, chunk: Resource, generation: String,
		output_root: String, settings_signature: int, scene_watch_signature: int,
		cancelled: Callable = Callable()) -> Dictionary:
	if not is_instance_valid(volume) or not volume is Volume \
			or chunk == null or not chunk is Chunk or generation.is_empty() \
			or output_root.is_empty() or not output_root.begins_with("res://"):
		return {"error": "A source-only generation requires a valid Volume, chunk, and writable res:// output root."}
	if _cancelled(cancelled):
		return {"error": "Free-space source generation was cancelled before persistence."}
	if not chunk.is_valid(chunk.geometry_signature, chunk.emitter_ids,
			chunk.emitter_static_signatures):
		return {"error": "The free-space chunk failed validation before persistence."}
	var generation_root := output_root.path_join("generation_" + generation)
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(generation_root)) != OK:
		return {"error": "Could not create the immutable free-space source generation directory."}
	var page_key := "free_space_volume"
	var page_path := generation_root.path_join("page_free_space_volume.res")
	var page := Page.new()
	if not populate_page(page, chunk, generation, page_key):
		return {"error": "Could not create a valid source-only FMagicGIPage."}
	if page.cpu_bytes > volume.cpu_resident_budget_bytes \
			or page.gpu_bytes > volume.gpu_resident_budget_bytes:
		return {"error": "The free-space source page exceeds the current CPU/GPU residency budget; increase the budget or reduce the volume extent."}
	if _cancelled(cancelled):
		return {"error": "Free-space source generation was cancelled before page save."}
	var save_error := ResourceSaver.save(page, page_path, ResourceSaver.FLAG_COMPRESS)
	if save_error != OK:
		return {"error": "Could not save the immutable free-space source page (error %d)." % save_error}
	if _cancelled(cancelled):
		return {"error": "Free-space source generation was cancelled after page save; the previous manifest remains active."}
	var reloaded_page := ResourceLoader.load(page_path, "", ResourceLoader.CACHE_MODE_IGNORE) as Page
	if reloaded_page == null or not reloaded_page.is_valid(generation, page_key) \
			or reloaded_page.data != null or reloaded_page.free_space_volume_source == null \
			or reloaded_page.free_space_volume_source.geometry_signature != chunk.geometry_signature \
			or reloaded_page.free_space_volume_source.spacing_m != Chunk.CELL_SPACING_M \
			or reloaded_page.free_space_volume_source.emitter_ids != chunk.emitter_ids:
		return {"error": "Saved free-space source page failed reload validation."}
	var domain: AABB = chunk.domain_bounds_world
	var influence := domain.grow(chunk.trace_distance_m * float(chunk.bake_bounces + 1))
	var page_entry := {
		"page_key": page_key,
		"page_generation": generation,
		"core_bounds": domain,
		"support_bounds": domain,
		"influence_bounds": influence,
		"probe_count": chunk.probe_count,
		"stored_probe_count": chunk.stored_valid_cell_count(),
		"source_storage_layout": chunk.source_storage_layout(),
		"valid_cell_count": int(chunk.valid_cell_count()),
		"relocated_cell_count": int(chunk.relocated_cell_count()),
		"cpu_bytes": page.cpu_bytes,
		"gpu_bytes": page.gpu_bytes,
		"geometry_signature": chunk.geometry_signature,
		"settings_signature": page.settings_signature,
		"free_space_source_format_version": chunk.format_version,
		"resource_path": page_path,
		"content_hash": FileAccess.get_sha256(page_path),
		"empty": false,
	}
	var manifest := Manifest.new()
	manifest.format_version = Manifest.FORMAT_VERSION
	manifest.manifest_key = Baker.new()._stable_manifest_key(output_root,
			SceneTracker.scene_identity(volume), SceneTracker.scene_relative_path(volume))
	manifest.generation = generation
	manifest.scene_identity = SceneTracker.scene_identity(volume)
	manifest.volume_identity = SceneTracker.scene_relative_path(volume)
	manifest.transport_domain = TRANSPORT_DOMAIN
	manifest.world_bounds = domain
	var largest_extent := maxf(domain.size.x, maxf(domain.size.y, domain.size.z))
	manifest.management_block_size = maxf(volume.management_block_size, largest_extent)
	manifest.page_core_size = maxf(volume.core_page_size, largest_extent)
	manifest.bake_geometry_signature = chunk.geometry_signature
	manifest.bake_settings_signature = settings_signature
	manifest.bake_samples = chunk.bake_samples
	manifest.bake_bounces = chunk.bake_bounces
	manifest.bake_moment_rays = chunk.moment_rays
	manifest.scene_watch_signature = scene_watch_signature
	manifest.scene_watch_signature_schema_version = SceneTracker.SIGNATURE_SCHEMA_CURRENT
	manifest.partial_generation = false
	# This generation stores live TransferMatrix inputs, not a frozen baked-SH field.
	manifest.baked_indirect_sh_revision = 0
	manifest.configure([page_entry])
	if not manifest.is_valid() or manifest.has_baked_indirect_sh():
		return {"error": "Generated free-space source manifest failed validation: %s" % manifest.get_index_error()}
	if _cancelled(cancelled):
		return {"error": "Free-space source generation was cancelled before manifest save."}
	var manifest_path := generation_root.path_join("manifest_" + generation + ".res")
	save_error = ResourceSaver.save(manifest, manifest_path, ResourceSaver.FLAG_COMPRESS)
	if save_error != OK:
		return {"error": "Could not save the free-space source manifest (error %d)." % save_error}
	if _cancelled(cancelled):
		return {"error": "Free-space source generation was cancelled after manifest save; the previous manifest remains active."}
	var verified_manifest := ResourceLoader.load(manifest_path, "", ResourceLoader.CACHE_MODE_IGNORE) as Manifest
	if verified_manifest == null or not verified_manifest.is_valid() \
			or verified_manifest.transport_domain != TRANSPORT_DOMAIN \
			or verified_manifest.get_page_count() != 1 \
			or verified_manifest.has_baked_indirect_sh() \
			or String(verified_manifest.get_page_metadata(page_key).get("content_hash", "")) \
			!= FileAccess.get_sha256(page_path):
		return {"error": "Saved free-space source manifest failed reload validation."}
	return {"manifest": verified_manifest, "manifest_path": manifest_path,
		"page_path": page_path, "generation": generation,
		"probe_count": chunk.probe_count,
		"stored_probe_count": chunk.stored_valid_cell_count(),
		"source_storage_layout": chunk.source_storage_layout(),
		"valid_cells": int(chunk.valid_cell_count()),
		"relocated_cells": int(chunk.relocated_cell_count()),
		"geometry_signature": chunk.geometry_signature,
		"directional_source_signature": chunk.directional_source_signature}

static func geometry_signature_for(geometry: RefCounted) -> int:
	if geometry == null:
		return 0
	var sampler_fingerprint: int = geometry.material_sampler.fingerprint() \
			if geometry.material_sampler != null else 0
	return hash([geometry.faces, geometry.reflectance, geometry.face_materials,
		geometry.face_uv, geometry.face_uv2, geometry.face_emitter_indices,
		sampler_fingerprint])

## Source-domain bake signature. Surface-placement and paging controls do not
## affect this fixed .25 m regular grid and therefore must not stale its data.
static func settings_signature(volume: Node3D) -> int:
	if not is_instance_valid(volume) or not volume is Volume:
		return 0
	var moment_rays := maxi(int(volume.bake_samples), MIN_MOMENT_RAYS)
	return hash([TRANSPORT_DOMAIN, Chunk.SOURCE_SCHEMA_REVISION_CURRENT,
		Chunk.CELL_SPACING_M, volume.global_transform, volume.size,
		volume.bake_samples, volume.bake_bounces, volume.bake_distance,
		volume.terrain_reflectance, volume.fallback_material_reflectance,
		volume.clv_cell_size, moment_rays, DEFAULT_MAX_RELOCATION_M])

func _classify_cells(source: Chunk, volume: Node3D, geometry: RefCounted,
		progress: Callable, cancelled: Callable) -> bool:
	var inverse := volume.global_transform.affine_inverse()
	var half_size: Vector3 = volume.size * 0.5
	var maximum_offset: float = source.maximum_relocation_m
	var count := source.probe_count
	for index in count:
		if index % 64 == 0:
			if _cancelled(cancelled):
				return false
			if progress.is_valid():
				progress.call("Classifying free-space cells", index, count, 0, 0)
		var cell := source.cell_coordinates(index)
		var center := source.origin_world + Vector3(cell) * source.spacing_m
		var local_center := inverse * center
		if not _inside_obb(local_center, half_size):
			continue # Ceil padding and rotated-AABB corners do not become samples.
		if not geometry.point_is_inside_or_ambiguous_solid(center):
			source.validity[index] = Chunk.RELOCATION_STATUS_VALID
			continue
		var relocated := _find_safe_local_relocation(center, inverse, half_size,
				maximum_offset, geometry)
		if relocated.is_empty():
			continue
		var actual_center: Vector3 = relocated["position"]
		var delta := actual_center - center
		if not delta.is_finite() or delta.length() > maximum_offset + 0.000001:
			continue
		source.relocation_offset_m[index] = delta
		source.validity[index] = Chunk.RELOCATION_STATUS_RELOCATED
	return true

func _find_safe_local_relocation(center: Vector3, inverse: Transform3D,
		half_size: Vector3, maximum_offset: float, geometry: RefCounted) -> Dictionary:
	if maximum_offset <= 0.0:
		return {}
	for radius_scale in [0.25, 0.5, 0.75, 1.0]:
		var radius := maximum_offset * float(radius_scale)
		for direction in RELOCATION_DIRECTIONS:
			var candidate: Vector3 = center + direction.normalized() * radius
			if not _inside_obb(inverse * candidate, half_size):
				continue
			if not geometry.point_is_inside_or_ambiguous_solid(candidate):
				return {"position": candidate}
	return {}

static func _inside_obb(point: Vector3, half_size: Vector3) -> bool:
	return point.is_finite() and absf(point.x) <= half_size.x + 0.000001 \
			and absf(point.y) <= half_size.y + 0.000001 \
			and absf(point.z) <= half_size.z + 0.000001

func _make_worker_input(source: Chunk, volume: Node3D,
		global_cell_origin := Vector3i.ZERO, source_level := -1) -> Data:
	var data := Data.new()
	data.positions.resize(source.probe_count)
	data.normals.resize(source.probe_count)
	data.stable_probe_ids.resize(source.probe_count)
	for index in source.probe_count:
		data.positions[index] = source.cell_position(index)
		# DirectionalBaker's shared worker output also computes a surface preview.
		# The normal is scratch-only and is never copied into this volume resource.
		data.normals[index] = Vector3.UP
		data.stable_probe_ids[index] = _stable_cell_id(source.geometry_signature,
				source.cell_coordinates(index)) if source_level < 0 else _stable_cell_id(
				hash([source.geometry_signature, "multires-prepared-v1", source_level]),
				source.cell_coordinates(index) + global_cell_origin)
	data.bake_samples = source.bake_samples
	data.bake_bounces = source.bake_bounces
	data.bake_distance = source.trace_distance_m
	data.emitter_keys = source.emitter_ids
	return data

static func _stable_cell_id(signature: int, cell: Vector3i) -> int:
	var identity := [signature, cell.x, cell.y, cell.z, Chunk.LAYOUT_REGULAR_CELL_CENTERS_V1]
	var low := int(hash(identity)) & 0xffffffff
	var high := int(hash([identity, "free-space-cell-high"])) & 0xffffffff
	var value := (high << 32) | low
	return value if value != 0 else 1

func _merge_cell(destination: Chunk, cell: int, result: Data) -> bool:
	if result == null or result.directional == null \
			or not result.directional.is_valid(1, destination.emitter_count) \
			or result.visibility_moments.size() != Chunk.MOMENT_TEXELS_PER_CELL * Chunk.MOMENT_CHANNELS:
		return false
	for value in result.directional.transfer:
		if not is_finite(value):
			return false
	for value in result.directional.sky:
		if not is_finite(value):
			return false
	for value in result.directional.emission:
		if not is_finite(value):
			return false
	for texel in Chunk.MOMENT_TEXELS_PER_CELL:
		var mean := result.visibility_moments[texel * Chunk.MOMENT_CHANNELS]
		var second := result.visibility_moments[texel * Chunk.MOMENT_CHANNELS + 1]
		if not is_finite(mean) or not is_finite(second) \
				or mean <= 0.0 or second <= 0.0 \
				or mean > destination.trace_distance_m + 0.001 \
				or second + maxf(0.0001, mean * mean * 0.0001) < mean * mean \
				or second > destination.trace_distance_m * destination.trace_distance_m + 0.01:
			return false
	for coefficient in 243:
		destination.transfer[cell * 243 + coefficient] = result.directional.transfer[coefficient]
	for coefficient in 81:
		destination.sky[cell * 81 + coefficient] = result.directional.sky[coefficient]
	for emitter in destination.emitter_count:
		var source_base := emitter * 54
		var destination_base := (emitter * destination.probe_count + cell) * 54
		for coefficient in 54:
			destination.emission[destination_base + coefficient] = \
					result.directional.emission[source_base + coefficient]
	var moment_base := cell * Chunk.MOMENT_TEXELS_PER_CELL * Chunk.MOMENT_CHANNELS
	for coefficient in result.visibility_moments.size():
		destination.receiver_visibility_moments[moment_base + coefficient] = \
				result.visibility_moments[coefficient]
	return true

func _clear_cell(destination: Chunk, cell: int) -> void:
	destination.validity[cell] = Chunk.RELOCATION_STATUS_INVALID
	destination.relocation_offset_m[cell] = Vector3.ZERO
	for coefficient in 243:
		destination.transfer[cell * 243 + coefficient] = 0.0
	for coefficient in 81:
		destination.sky[cell * 81 + coefficient] = 0.0
	for emitter in destination.emitter_count:
		var emission_start := (emitter * destination.probe_count + cell) * 54
		for coefficient in 54:
			destination.emission[emission_start + coefficient] = 0.0
	var moment_start := cell * Chunk.MOMENT_TEXELS_PER_CELL * Chunk.MOMENT_CHANNELS
	for coefficient in Chunk.MOMENT_TEXELS_PER_CELL * Chunk.MOMENT_CHANNELS:
		destination.receiver_visibility_moments[moment_start + coefficient] = 0.0

static func make_sampling_cache(samples: int, bounces: int, moment_rays: int) -> Dictionary:
	if samples <= 0 or samples > MAX_BAKE_SAMPLES \
			or bounces <= 0 or bounces > MAX_BAKE_BOUNCES \
			or moment_rays < MIN_MOMENT_RAYS or moment_rays > MAX_MOMENT_RAYS:
		return {"ok": false}
	var minimum_moment_rays := Chunk.MIN_MOMENT_RAYS
	var coordinates := _build_qmc_coordinates(samples, (bounces + 1) * 2)
	return {"ok": true, "samples": samples, "bounces": bounces,
		"moment_rays": moment_rays,
		"coordinates": coordinates,
		"minimum_moment_coordinates": _build_qmc_coordinates(minimum_moment_rays, 2),
		"extra_moment_coordinates": _build_qmc_coordinates(moment_rays - minimum_moment_rays, 2)}

static func _sampling_cache_matches(cache: Dictionary, samples: int, bounces: int,
		moment_rays: int) -> bool:
	if not bool(cache.get("ok", false)) or int(cache.get("samples", -1)) != samples \
			or int(cache.get("bounces", -1)) != bounces \
			or int(cache.get("moment_rays", -1)) != moment_rays:
		return false
	var coordinates: Variant = cache.get("coordinates", null)
	var minimum: Variant = cache.get("minimum_moment_coordinates", null)
	var extra: Variant = cache.get("extra_moment_coordinates", null)
	return _qmc_coordinates_match(coordinates, (bounces + 1) * 2, samples) \
			and _qmc_coordinates_match(minimum, 2, Chunk.MIN_MOMENT_RAYS) \
			and _qmc_coordinates_match(extra, 2, moment_rays - Chunk.MIN_MOMENT_RAYS)

static func _qmc_coordinates_match(value: Variant, dimensions: int, samples: int) -> bool:
	if not value is Array or value.size() != dimensions:
		return false
	for coordinate_value in value:
		if not coordinate_value is PackedFloat64Array or coordinate_value.size() != samples:
			return false
	return true

static func _build_qmc_coordinates(sample_count: int, dimensions: int) -> Array[PackedFloat64Array]:
	var coordinates: Array[PackedFloat64Array] = []
	coordinates.resize(dimensions)
	for dimension in dimensions:
		var values := PackedFloat64Array()
		values.resize(sample_count)
		for sample in sample_count:
			values[sample] = Baker._qmc_base_coordinate(sample, sample_count, dimension)
		coordinates[dimension] = values
	return coordinates

static func _cancelled(cancelled: Callable) -> bool:
	return cancelled.is_valid() and bool(cancelled.call())

func _failure(message: String) -> Dictionary:
	return {"ok": false, "error": message, "chunk": null}
