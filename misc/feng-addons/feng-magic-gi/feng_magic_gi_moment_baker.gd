@tool
extends RefCounted
## Octahedral distance moments, operating only on a CPU trace snapshot.

const Data = preload("feng_magic_gi_data.gd")
const MIN_VISIBILITY_RAYS_PER_TEXEL := 4

static func bake(data: Data, geometry: RefCounted, probe: int,
		shift: Vector2,
		visibility_rays: int,
		minimum_qmc_coordinates: Array[PackedFloat64Array],
		extra_qmc_coordinates: Array[PackedFloat64Array]) -> bool:
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
			var jitter_x := fposmod(minimum_qmc_coordinates[0][sample_index] + shift.x, 1.0)
			var jitter_y := fposmod(minimum_qmc_coordinates[1][sample_index] + shift.y, 1.0)
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
			var u := fposmod(extra_qmc_coordinates[0][extra_index] + shift.x, 1.0)
			var v := fposmod(extra_qmc_coordinates[1][extra_index] + shift.y, 1.0)
			var y := 1.0 - 2.0 * u
			var radius := sqrt(maxf(0.0, 1.0 - y * y))
			var phi := TAU * v
			direction = Vector3(radius * cos(phi), y, radius * sin(phi))
		var hit: Dictionary = geometry.trace(data.positions[probe], direction, data.bake_distance)
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
	for texel in texel_count:
		var output_base := (probe * texel_count + texel) * Data.VISIBILITY_MOMENT_CHANNELS
		if weights[texel] <= 0.0:
			return false
		data.visibility_moments[output_base] = first_sums[texel] / weights[texel]
		data.visibility_moments[output_base + 1] = second_sums[texel] / weights[texel]
	return true

