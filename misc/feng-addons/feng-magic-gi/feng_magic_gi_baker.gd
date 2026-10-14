@tool
class_name FMagicGIBaker
extends RefCounted
## Offline diffuse PRT: bake only geometry transport. Current light and the
## receiving material remain dynamic and are applied by the render pass.

const Data = preload("feng_magic_gi_data.gd")
const Placement = preload("feng_magic_gi_placement.gd")
const BakeJob = preload("feng_magic_gi_bake_job.gd")
const MAX_BAKE_PATHS := 100000000
const SAMPLER_REVISION := Data.SAMPLER_REVISION
const QMC_PRIME_BASES := [2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59]
const MIN_VISIBILITY_RAYS_PER_TEXEL := 4

## The persisted geometry signature also identifies the estimator that created it.
## This leaves the v2 transport layout intact while making older random bakes stale.
static func signature_for_geometry(geometry_signature: int) -> int:
	return Data.signature_for_geometry(geometry_signature)

## Explicit v5 upgrade: keep light transport byte-for-byte and only build static
## blockers. Never assigns the volume or saves a scene; callers own that choice.
func upgrade_visibility_bake(volume: FMagicGIVolume, collected_geometry: Placement = null) -> Data:
	var previous: Data = volume.bake_data
	if not volume.is_inside_tree() or previous == null \
			or previous.format_version != Data.MOMENT_FORMAT_VERSION or not previous.is_valid():
		return null
	var geometry := collected_geometry
	if geometry == null:
		geometry = Placement.new()
		if not geometry.collect(volume, true, true, true):
			return null
	if previous.scene_signature != signature_for_geometry(geometry.scene_signature):
		return null
	var upgraded: Data = previous.duplicate(true)
	upgraded.format_version = Data.FORMAT_VERSION
	if not upgraded.matches_layout(volume.size, volume.probe_spacing, volume.surface_offset,
			volume.global_transform, volume.bake_samples, volume.bake_bounces,
			volume.bake_distance, volume.terrain_reflectance, volume.fallback_material_reflectance) \
			or not _build_visibility_geometry(upgraded, geometry.faces):
		return null
	upgraded.bake_version = maxi(previous.bake_version + 1, Time.get_ticks_usec())
	return upgraded if upgraded.is_valid() else null

static func _build_visibility_geometry(data: Data, faces: PackedVector3Array) -> bool:
	var blockers := Data.Visibility.build(faces)
	if blockers.is_empty():
		return false
	data.visibility_nodes = blockers.nodes
	data.visibility_triangles = blockers.triangles
	return true

func bake_volume(volume: FMagicGIVolume, generation: int) -> Data:
	if not volume.is_inside_tree():
		return null
	var geometry := Placement.new()
	if not geometry.collect(volume, true, true, true):
		push_warning("FMagicGI: " + geometry.error_message)
		return null
	if geometry.positions.is_empty():
		push_warning("FMagicGI: no surfaces inside the volume; no air probes were created.")
		return null
	var rays: int = volume.bake_samples
	var bounces: int = volume.bake_bounces
	if rays < 1 or rays > 65536 or bounces < 1 or bounces > 8 or volume.bake_distance <= 0.0:
		push_warning("FMagicGI: invalid bake sample, bounce, or distance settings.")
		return null
	var work_per_probe_sample := (bounces + 1) * (1 + geometry.emitters.groups.size())
	var visibility_rays := maxi(rays,
			Data.VISIBILITY_TEXELS_PER_PROBE * MIN_VISIBILITY_RAYS_PER_TEXEL)
	var total_work := geometry.positions.size() * (rays * work_per_probe_sample + visibility_rays)
	if total_work > MAX_BAKE_PATHS:
		push_warning("FMagicGI: PRT, directional visibility, and emissive-source shadow rays exceed the 100,000,000 work limit; increase Probe Spacing or reduce samples, bounces, or emitter count.")
		return null
	var data := Data.new()
	data.format_version = Data.FORMAT_VERSION
	data.grid_dims = volume.grid_dimensions()
	data.volume_size = volume.size
	data.spacing = volume.probe_spacing
	data.adaptive_placement = volume.adaptive_placement
	data.minimum_probe_spacing = minf(volume.minimum_probe_spacing, volume.probe_spacing)
	data.probe_spacings = geometry.probe_spacings
	data.surface_offset = volume.surface_offset
	data.volume_transform = volume.global_transform
	data.world_to_grid = volume.world_to_grid_transform()
	data.bake_samples = rays
	data.bake_bounces = bounces
	data.bake_distance = volume.bake_distance
	data.terrain_reflectance = volume.terrain_reflectance
	data.material_reflectance = volume.fallback_material_reflectance
	var geometry_signature: int = geometry.scene_signature
	data.scene_signature = signature_for_geometry(geometry_signature)
	data.positions = geometry.positions
	data.surface_positions = geometry.surface_positions
	data.normals = geometry.normals
	if not _build_visibility_geometry(data, geometry.faces):
		push_warning("FMagicGI: could not build static segment blockers; discarded the incomplete bake.")
		return null
	data.transfer.resize(data.probe_count() * 27)
	data.primary_sky_visibility.resize(data.probe_count() * 9)
	data.visibility_moments.resize(data.probe_count() * Data.VISIBILITY_TEXELS_PER_PROBE
			* Data.VISIBILITY_MOMENT_CHANNELS)
	data.emitter_keys = geometry.emitters.keys
	data.emitter_static_signatures = geometry.emitters.static_signatures
	data.emitter_transport.resize(data.probe_count() * geometry.emitters.groups.size() * 6)
	data.directional = Data.DirectionalData.new()
	data.directional.allocate(data.probe_count(), geometry.emitters.groups.size())
	var qmc_dimension_count := (bounces + 1) * 2
	var qmc_base_coordinates := _build_qmc_base_coordinates(rays, qmc_dimension_count)
	var minimum_visibility_rays := Data.VISIBILITY_TEXELS_PER_PROBE * MIN_VISIBILITY_RAYS_PER_TEXEL
	var minimum_visibility_qmc_coordinates := _build_qmc_base_coordinates(minimum_visibility_rays, 2)
	var extra_visibility_qmc_coordinates := _build_qmc_base_coordinates(
			visibility_rays - minimum_visibility_rays, 2)
	var trace_scene: RefCounted = geometry.trace_scene
	var jobs_completed: bool = await _run_probe_jobs(data, volume, generation, trace_scene, geometry_signature,
			qmc_base_coordinates, minimum_visibility_qmc_coordinates,
			extra_visibility_qmc_coordinates, visibility_rays)
	if not jobs_completed:
		return null
	# Recollect after yielding so edits to static scene content invalidate this
	# result even if the volume transform did not change.
	var verification := Placement.new()
	if not verification.collect(volume, true, true, true) or verification.scene_signature != geometry_signature \
			or verification.emitters.keys != geometry.emitters.keys \
			or verification.emitters.static_signatures != geometry.emitters.static_signatures:
		push_warning("FMagicGI: scene geometry changed during baking; discarded stale transfer.")
		return null
	if not is_instance_valid(volume) or not volume.is_bake_request_current(generation) \
			or not data.matches_layout(
			volume.size, volume.probe_spacing, volume.surface_offset, volume.global_transform,
			volume.bake_samples, volume.bake_bounces, volume.bake_distance,
			volume.terrain_reflectance, volume.fallback_material_reflectance):
		push_warning("FMagicGI: volume changed during baking; discarded stale transfer.")
		return null
	if not data.build_cell_indices():
		push_warning("FMagicGI: probe lookup construction failed; discarded incomplete transport.")
		return null
	data.bake_version = Time.get_ticks_usec()
	if not data.is_valid():
		push_warning("FMagicGI: generated PRT payload failed validation.")
		return null
	if not data.has_nonzero_transfer():
		push_warning("FMagicGI: " + volume.ZERO_TRANSFER_DIAGNOSTIC)
	return data

## Keep at most one worker window in flight. Completing and merging each probe
## immediately lets a fast worker take the next slot without waiting for the
## slowest probe in an arbitrary batch.
func _run_probe_jobs(data: Data, volume: Node3D, generation: int,
		trace_scene: RefCounted, geometry_signature: int,
		qmc_base_coordinates: Array[PackedFloat64Array],
		minimum_visibility_qmc_coordinates: Array[PackedFloat64Array],
		extra_visibility_qmc_coordinates: Array[PackedFloat64Array],
		visibility_rays: int) -> bool:
	var worker_limit := clampi(_probe_worker_limit(), 1, 8)
	var next_probe := 0
	# One record owns each outstanding task's job and destination probe slot.
	var pending: Dictionary = {}
	var cancelled := false
	var failed := false
	while next_probe < data.probe_count() or not pending.is_empty():
		cancelled = cancelled or not _bake_request_current(volume, generation)
		var completed_tasks := PackedInt64Array()
		for task_id in pending:
			if WorkerThreadPool.is_task_completed(task_id):
				completed_tasks.append(task_id)
		if not completed_tasks.is_empty():
			var completed_records: Array[Dictionary] = []
			for task_id in completed_tasks:
				# Join before releasing the task's job or its immutable geometry snapshot.
				WorkerThreadPool.wait_for_task_completion(task_id)
				var record: Dictionary = pending[task_id]
				pending.erase(task_id)
				var job: BakeJob = record.job
				if not job.valid:
					failed = true
				completed_records.append(record)
			# Merge only after all newly completed jobs are known to be valid. Once a
			# cancellation or failure is known, remaining results are only joined.
			if not cancelled and not failed:
				for record in completed_records:
					var completed_job: BakeJob = record.job
					completed_job.merge(data, int(record.probe))
		if not cancelled and not failed:
			while next_probe < data.probe_count() and pending.size() < worker_limit:
				if not _bake_request_current(volume, generation):
					cancelled = true
					break
				var probe := next_probe
				var job := _create_bake_job(data, probe)
				var task_id := WorkerThreadPool.add_task(Callable(job, "run").bind(trace_scene,
					geometry_signature, probe, qmc_base_coordinates,
					minimum_visibility_qmc_coordinates, extra_visibility_qmc_coordinates,
					visibility_rays), false, "Magic GI Bake")
				if task_id < 0:
					failed = true
					break
				pending[task_id] = {"job": job, "probe": probe}
				next_probe += 1
		if (cancelled or failed) and pending.is_empty():
			break
		if not pending.is_empty():
			await Engine.get_main_loop().process_frame
	if failed:
		push_warning("FMagicGI: incomplete directional visibility; discarded the bake.")
	return not cancelled and not failed and next_probe == data.probe_count() \
		and _bake_request_current(volume, generation)

func _probe_worker_limit() -> int:
	return clampi(OS.get_processor_count() - 2, 1, 8)

func _create_bake_job(data: Data, probe: int) -> BakeJob:
	var job := BakeJob.new()
	job.initialize(data, probe)
	return job

func _bake_request_current(volume: Node3D, generation: int) -> bool:
	return is_instance_valid(volume) and volume.is_inside_tree() \
		and bool(volume.call("is_bake_request_current", generation))

## Randomized Hammersley sequence: the first coordinate is stratified over N
## samples and later coordinates use radical inverses in distinct prime bases.
## Cranley-Patterson shifts preserve the uniform marginal distribution.
static func qmc_sample(sample_index: int, sample_count: int, dimension: int, shift: float) -> float:
	if sample_count <= 0 or sample_index < 0 or sample_index >= sample_count \
			or dimension < 0 or dimension > QMC_PRIME_BASES.size():
		return 0.0
	return fposmod(_qmc_base_coordinate(sample_index, sample_count, dimension) + shift, 1.0)

static func _qmc_base_coordinate(sample_index: int, sample_count: int, dimension: int) -> float:
	if dimension == 0:
		return (float(sample_index) + 0.5) / float(sample_count)
	return _radical_inverse(sample_index, QMC_PRIME_BASES[dimension - 1])

static func _build_qmc_base_coordinates(sample_count: int,
		dimension_count: int) -> Array[PackedFloat64Array]:
	var coordinates: Array[PackedFloat64Array] = []
	coordinates.resize(dimension_count)
	for dimension in dimension_count:
		var values := PackedFloat64Array()
		values.resize(sample_count)
		for sample_index in sample_count:
			values[sample_index] = _qmc_base_coordinate(sample_index, sample_count, dimension)
		coordinates[dimension] = values
	return coordinates

static func _radical_inverse(index: int, base: int) -> float:
	var result := 0.0
	var factor := 1.0 / float(base)
	var remaining := index
	while remaining > 0:
		var digit := remaining % base
		result += float(digit) * factor
		remaining = int(floor(float(remaining) / float(base)))
		factor /= float(base)
	return result

static func cosine_direction(normal: Vector3, u: float, v: float) -> Vector3:
	var tangent := normal.cross(Vector3.UP if absf(normal.y) < 0.99 else Vector3.RIGHT).normalized()
	var bitangent := normal.cross(tangent)
	var radius := sqrt(u)
	return (tangent * (radius * cos(TAU * v)) + bitangent * (radius * sin(TAU * v)) + normal * sqrt(1.0 - u)).normalized()

static func _cosine_direction_with_frame(normal: Vector3, u: float, v: float,
		tangent: Vector3, bitangent: Vector3) -> Vector3:
	var radius := sqrt(u)
	return (tangent * (radius * cos(TAU * v)) + bitangent * (radius * sin(TAU * v)) + normal * sqrt(1.0 - u)).normalized()
