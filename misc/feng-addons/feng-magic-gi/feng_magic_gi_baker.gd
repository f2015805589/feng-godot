@tool
class_name FMagicGIBaker
extends RefCounted
## Offline diffuse PRT: bake only geometry transport. Current light and the
## receiving material remain dynamic and are applied by the render pass.

const Data = preload("feng_magic_gi_data.gd")
const Placement = preload("feng_magic_gi_placement.gd")
const MAX_BAKE_PATHS := 20000000
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
	var work_per_probe_sample := (bounces + 1) * (1 + geometry.emitter_groups.size())
	var visibility_rays := maxi(rays,
			Data.VISIBILITY_TEXELS_PER_PROBE * MIN_VISIBILITY_RAYS_PER_TEXEL)
	var total_work := geometry.positions.size() * (rays * work_per_probe_sample + visibility_rays)
	if total_work > MAX_BAKE_PATHS:
		push_warning("FMagicGI: PRT, directional visibility, and emissive-source shadow rays exceed the 20,000,000 work limit; increase Probe Spacing or reduce samples, bounces, or emitter count.")
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
	data.surface_positions = geometry.surface_positions
	data.normals = geometry.normals
	if not _build_visibility_geometry(data, geometry.faces):
		push_warning("FMagicGI: could not build static segment blockers; discarded the incomplete bake.")
		return null
	data.transfer.resize(data.probe_count() * 27)
	data.primary_sky_visibility.resize(data.probe_count() * 9)
	data.visibility_moments.resize(data.probe_count() * Data.VISIBILITY_TEXELS_PER_PROBE
			* Data.VISIBILITY_MOMENT_CHANNELS)
	data.emitter_keys = geometry.emitter_keys
	data.emitter_static_signatures = geometry.emitter_static_signatures
	data.emitter_transport.resize(data.probe_count() * geometry.emitter_groups.size() * 6)
	var qmc_dimension_count := (bounces + 1) * 2
	var qmc_base_coordinates: Array[PackedFloat64Array] = []
	qmc_base_coordinates.resize(qmc_dimension_count)
	for dimension in qmc_dimension_count:
		var coordinates := PackedFloat64Array()
		coordinates.resize(rays)
		for sample_index in rays:
			coordinates[sample_index] = _qmc_base_coordinate(sample_index, rays, dimension)
		qmc_base_coordinates[dimension] = coordinates
	for p in data.probe_count():
		var visibility_shift_rng := RandomNumberGenerator.new()
		visibility_shift_rng.seed = int(hash([geometry_signature, SAMPLER_REVISION, p, "visibility-moments"]))
		var visibility_shifts := Vector2(visibility_shift_rng.randf(), visibility_shift_rng.randf())
		if not await _bake_visibility_moments(data, geometry, p,
				visibility_shifts, visibility_rays, volume, generation):
			push_warning("FMagicGI: directional visibility bake did not measure every octahedral moment bin; discarded the incomplete bake.")
			return null
		# A per-probe Cranley-Patterson shift randomizes the low-discrepancy
		# sequence without correlating the same ray directions across probes.
		var shift_rng := RandomNumberGenerator.new()
		shift_rng.seed = int(hash([geometry_signature, SAMPLER_REVISION, p]))
		var shifts := PackedFloat32Array()
		shifts.resize((bounces + 1) * 2)
		for dimension in shifts.size():
			shifts[dimension] = shift_rng.randf()
		var emitter_shifts := PackedFloat32Array()
		emitter_shifts.resize((bounces + 1) * geometry.emitter_groups.size() * 3)
		var emitter_shift_rng := RandomNumberGenerator.new()
		emitter_shift_rng.seed = int(hash([geometry_signature, SAMPLER_REVISION, p, "emission"]))
		for dimension in emitter_shifts.size():
			emitter_shifts[dimension] = emitter_shift_rng.randf()
		for sample_index in rays:
			var origin := data.positions[p]
			var vertex_position := data.surface_positions[p]
			var vertex_normal := data.normals[p]
			var vertex_offset := vertex_position.distance_to(data.positions[p])
			var direction := cosine_direction(data.normals[p],
				fposmod(qmc_base_coordinates[0][sample_index] + shifts[0], 1.0),
				fposmod(qmc_base_coordinates[1][sample_index] + shifts[1], 1.0))
			var throughput := Vector3.ONE
			for bounce in bounces + 1:
				for emitter in geometry.emitter_groups.size():
					var shift_index := (bounce * geometry.emitter_groups.size() + emitter) * 3
					var source_sample := geometry.sample_emitter_connection(emitter,
						vertex_position, vertex_normal,
						fposmod(qmc_base_coordinates[0][sample_index] + emitter_shifts[shift_index], 1.0),
						fposmod(qmc_base_coordinates[1][sample_index] + emitter_shifts[shift_index + 1], 1.0),
						fposmod(qmc_base_coordinates[2][sample_index] + emitter_shifts[shift_index + 2], 1.0),
						volume.bake_distance, vertex_offset)
					if not source_sample.is_empty():
						var blocked := geometry.trace(source_sample.ray_origin,
							source_sample.direction, source_sample.ray_distance)
						if blocked.is_empty():
							var emitter_base := (emitter * data.probe_count() + p) * 6
							var factor: float = float(source_sample.weight) / rays
							var texture_rgb: Vector3 = source_sample.texture_rgb
							for channel in 3:
								data.emitter_transport[emitter_base + channel] += throughput[channel] * factor
								data.emitter_transport[emitter_base + 3 + channel] += throughput[channel] * factor * texture_rgb[channel]
				var hit := geometry.trace(origin, direction, volume.bake_distance)
				if hit.is_empty():
					var basis := Data.sh_basis(direction)
					if bounce == 0:
						# The cosine sampler's pdf is cos(theta)/PI. These SH9
						# coefficients integrate primary sky irradiance without
						# mixing the current sky radiance into secondary transport.
						for k in 9:
							data.primary_sky_visibility[p * 9 + k] += PI * basis[k] / rays
					elif bounce > 0:
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
				vertex_position = hit.position
				vertex_normal = hit_normal
				vertex_offset = geometry.safe_surface_offset(hit.position, hit_normal)
				if vertex_offset <= 0.0:
					break
				origin = hit.position + hit_normal * vertex_offset
				var dimension := (bounce + 1) * 2
				direction = cosine_direction(hit_normal,
					fposmod(qmc_base_coordinates[dimension][sample_index] + shifts[dimension], 1.0),
					fposmod(qmc_base_coordinates[dimension + 1][sample_index] + shifts[dimension + 1], 1.0))
		if p % 4 == 0:
			await volume.get_tree().process_frame
			if not is_instance_valid(volume) or not volume.is_inside_tree() \
					or not volume.is_bake_request_current(generation):
				return null
	# Recollect after yielding so edits to static scene content invalidate this
	# result even if the volume transform did not change.
	var verification := Placement.new()
	if not verification.collect(volume, true, true, true) or verification.scene_signature != geometry_signature \
			or verification.emitter_keys != geometry.emitter_keys \
			or verification.emitter_static_signatures != geometry.emitter_static_signatures:
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
		push_warning("FMagicGI: surface probes exceed the 8-slot lookup cell capacity.")
		return null
	data.bake_version = Time.get_ticks_usec()
	if not data.is_valid():
		push_warning("FMagicGI: generated PRT payload failed validation.")
		return null
	if not data.has_nonzero_transfer():
		push_warning("FMagicGI: " + volume.ZERO_TRANSFER_DIAGNOSTIC)
	return data

func _bake_visibility_moments(data: Data, geometry: Placement, probe: int,
		shift: Vector2,
		visibility_rays: int, volume: FMagicGIVolume, generation: int) -> bool:
	var size := Data.VISIBILITY_TILE_SIZE
	var texel_count := Data.VISIBILITY_TEXELS_PER_PROBE
	var minimum_bin_rays := texel_count * MIN_VISIBILITY_RAYS_PER_TEXEL
	var first_sums := PackedFloat64Array()
	var second_sums := PackedFloat64Array()
	var weights := PackedFloat64Array()
	first_sums.resize(texel_count)
	second_sums.resize(texel_count)
	weights.resize(texel_count)
	first_sums.fill(0.0)
	second_sums.fill(0.0)
	weights.fill(0.0)
	for sample_index in visibility_rays:
		var direction: Vector3
		var texel := -1
		if sample_index < minimum_bin_rays:
			var bin_index := floori(float(sample_index) / float(MIN_VISIBILITY_RAYS_PER_TEXEL))
			var stratum := sample_index % MIN_VISIBILITY_RAYS_PER_TEXEL
			var jitter_x := fposmod(_qmc_base_coordinate(sample_index, minimum_bin_rays, 0) + shift.x, 1.0)
			var jitter_y := fposmod(_qmc_base_coordinate(sample_index, minimum_bin_rays, 1) + shift.y, 1.0)
			var sub_x := float(stratum % 2) * 0.5 + jitter_x * 0.5
			var sub_y := float(stratum / 2) * 0.5 + jitter_y * 0.5
			var bin_x := bin_index % size
			var bin_y := floori(float(bin_index) / float(size))
			var uv := Vector2((bin_x + sub_x) / float(size),
					(bin_y + sub_y) / float(size))
			direction = Data.octahedral_decode(uv)
			texel = bin_index
		else:
			var extra_index := sample_index - minimum_bin_rays
			var extra_count := visibility_rays - minimum_bin_rays
			var u := fposmod(_qmc_base_coordinate(extra_index, extra_count, 0) + shift.x, 1.0)
			var v := fposmod(_qmc_base_coordinate(extra_index, extra_count, 1) + shift.y, 1.0)
			var y := 1.0 - 2.0 * u
			var radius := sqrt(maxf(0.0, 1.0 - y * y))
			var phi := TAU * v
			direction = Vector3(radius * cos(phi), y, radius * sin(phi))
		var hit := geometry.trace(data.positions[probe], direction, data.bake_distance)
		var distance := data.bake_distance
		if not hit.is_empty():
			distance = clampf((hit.position - data.positions[probe]).dot(direction), 0.0, data.bake_distance)
		if texel >= 0:
			first_sums[texel] += distance
			second_sums[texel] += distance * distance
			weights[texel] += 1.0
		else:
			var texel_position := Data.octahedral_encode(direction) * float(size) - Vector2(0.5, 0.5)
			var base := Vector2i(floori(texel_position.x), floori(texel_position.y))
			var fraction := texel_position - Vector2(base)
			for dy in 2:
				for dx in 2:
					var weight := (fraction.x if dx == 1 else 1.0 - fraction.x) \
							* (fraction.y if dy == 1 else 1.0 - fraction.y)
					var folded := Data.fold_visibility_texel(base + Vector2i(dx, dy))
					var splat_texel := folded.y * size + folded.x
					first_sums[splat_texel] += distance * weight
					second_sums[splat_texel] += distance * distance * weight
					weights[splat_texel] += weight
		if sample_index % 1024 == 1023:
			await volume.get_tree().process_frame
			if not is_instance_valid(volume) or not volume.is_inside_tree() \
					or not volume.is_bake_request_current(generation):
				return false
	for texel in texel_count:
		var output_base := (probe * texel_count + texel) * Data.VISIBILITY_MOMENT_CHANNELS
		if weights[texel] <= 0.0:
			return false
		data.visibility_moments[output_base] = first_sums[texel] / weights[texel]
		data.visibility_moments[output_base + 1] = second_sums[texel] / weights[texel]
	return true

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
