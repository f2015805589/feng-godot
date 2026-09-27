@tool
class_name FMagicGIBaker
extends RefCounted
## Offline diffuse PRT: bake only geometry transport. Current light and the
## receiving material remain dynamic and are applied by the render pass.

const Data = preload("feng_magic_gi_data.gd")
const Placement = preload("feng_magic_gi_placement.gd")
const MAX_BAKE_PATHS := 20000000
const SAMPLER_REVISION := 2
const QMC_PRIME_BASES := [2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59]

## The persisted geometry signature also identifies the estimator that created it.
## This leaves the v2 transport layout intact while making older random bakes stale.
static func signature_for_geometry(geometry_signature: int) -> int:
	# Placement signatures are 32-bit hashes; keep their bits and reserve the
	# high word for the estimator revision so legacy raw signatures cannot match.
	return (SAMPLER_REVISION << 32) | (geometry_signature & 0xffffffff)

func bake_volume(volume: FMagicGIVolume, generation: int) -> Data:
	if not volume.is_inside_tree():
		return null
	var geometry := Placement.new()
	if not geometry.collect(volume, true):
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
	if geometry.positions.size() * rays * (bounces + 1) > MAX_BAKE_PATHS:
		push_warning("FMagicGI: requested bake exceeds the 20,000,000 ray-work limit; increase Probe Spacing or reduce samples/bounces.")
		return null
	var data := Data.new()
	data.format_version = Data.FORMAT_VERSION
	data.grid_dims = volume.grid_dimensions()
	data.volume_size = volume.size
	data.spacing = volume.probe_spacing
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
	data.normals = geometry.normals
	data.transfer.resize(data.probe_count() * 27)
	var epsilon: float = maxf(0.001, volume.surface_offset)
	for p in data.probe_count():
		# A per-probe Cranley-Patterson shift randomizes the low-discrepancy
		# sequence without correlating the same ray directions across probes.
		var shift_rng := RandomNumberGenerator.new()
		shift_rng.seed = int(hash([geometry_signature, SAMPLER_REVISION, p]))
		var shifts := PackedFloat32Array()
		shifts.resize((bounces + 1) * 2)
		for dimension in shifts.size():
			shifts[dimension] = shift_rng.randf()
		for sample_index in rays:
			var origin := data.positions[p]
			var direction := cosine_direction(data.normals[p],
				qmc_sample(sample_index, rays, 0, shifts[0]),
				qmc_sample(sample_index, rays, 1, shifts[1]))
			var throughput := Vector3.ONE
			for bounce in bounces + 1:
				var hit := geometry.trace(origin, direction, volume.bake_distance)
				if hit.is_empty():
					# The initial escape is direct lighting and must not be baked:
					# the engine's direct-light pass already handles it.
					if bounce > 0:
						var basis := Data.sh_basis(direction)
						for k in 9:
							for channel in 3:
								data.transfer[p * 27 + k * 3 + channel] += throughput[channel] * basis[k] / rays
					break
				if bounce == bounces:
					break
				throughput *= hit.albedo
				if throughput.length_squared() < 0.00001:
					break
				var hit_normal: Vector3 = hit.normal
				origin = hit.position + hit_normal * epsilon
				var dimension := (bounce + 1) * 2
				direction = cosine_direction(hit_normal,
					qmc_sample(sample_index, rays, dimension, shifts[dimension]),
					qmc_sample(sample_index, rays, dimension + 1, shifts[dimension + 1]))
		if p % 4 == 0:
			await volume.get_tree().process_frame
			if not is_instance_valid(volume) or not volume.is_inside_tree() or volume._bake_generation != generation:
				return null
	# Recollect after yielding so edits to static scene content invalidate this
	# result even if the volume transform did not change.
	var verification := Placement.new()
	if not verification.collect(volume, true) or verification.scene_signature != geometry_signature:
		push_warning("FMagicGI: scene geometry changed during baking; discarded stale transfer.")
		return null
	if volume._bake_generation != generation or not data.matches_layout(
			volume.size, volume.probe_spacing, volume.surface_offset, volume.global_transform,
			volume.bake_samples, volume.bake_bounces, volume.bake_distance,
			volume.terrain_reflectance, volume.fallback_material_reflectance):
		push_warning("FMagicGI: volume changed during baking; discarded stale transfer.")
		return null
	if not data.build_cell_indices():
		push_warning("FMagicGI: surface probes exceed the 8-slot lookup cell capacity.")
		return null
	data.bake_version = Time.get_ticks_usec()
	if not data.is_valid():
		push_warning("FMagicGI: generated PRT payload failed validation.")
		return null
	if not data.has_nonzero_transfer():
		push_warning("FMagicGI: " + volume.ZERO_TRANSFER_DIAGNOSTIC)
	return data

## Randomized Hammersley sequence: the first coordinate is stratified over N
## samples and later coordinates use radical inverses in distinct prime bases.
## Cranley-Patterson shifts preserve the uniform marginal distribution.
static func qmc_sample(sample_index: int, sample_count: int, dimension: int, shift: float) -> float:
	if sample_count <= 0 or sample_index < 0 or sample_index >= sample_count \
			or dimension < 0 or dimension > QMC_PRIME_BASES.size():
		return 0.0
	var coordinate: float
	if dimension == 0:
		coordinate = (float(sample_index) + 0.5) / float(sample_count)
	else:
		coordinate = _radical_inverse(sample_index, QMC_PRIME_BASES[dimension - 1])
	return fposmod(coordinate + shift, 1.0)

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
