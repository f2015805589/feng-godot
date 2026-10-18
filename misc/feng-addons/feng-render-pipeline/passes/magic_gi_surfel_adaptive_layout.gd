@tool
extends RefCounted
## Small CPU-side contracts shared by the bounded adaptive surfel layout.

const LEVEL_COUNT := 2
const TILE_SIZE := 16
const TILE_REPRESENTATIVE_COUNT := 4
const TILE_REPRESENTATIVE_PHASE_COUNT := 64
const LOD_TARGET_PIXELS := 8.0
const COARSE_SCALE := 2.0
const GUIDE_BINS := 16
const MIN_COSINE_MIX := 0.25
const DEFAULT_CHANGE_Z_THRESHOLD := 0.75
const DEFAULT_FAST_HISTORY_WEIGHT := 0.5


static func level_radius(base_radius: float, level: int, adaptive: bool) -> float:
	var radius := base_radius if is_finite(base_radius) and base_radius > 0.0 else 0.15
	return radius * (COARSE_SCALE if adaptive and level > 0 else 1.0)


static func level_for_footprint(pixel_footprint: float, base_radius: float, adaptive: bool,
		current_level := -1) -> int:
	if not adaptive or not is_finite(pixel_footprint) or not is_finite(base_radius) \
			or base_radius <= 0.0:
		return 0
	var support_footprint := pixel_footprint * LOD_TARGET_PIXELS
	if current_level == 0:
		return 1 if support_footprint >= base_radius * 1.25 else 0
	if current_level == 1:
		return 0 if support_footprint < base_radius * 0.8 else 1
	return 1 if support_footprint >= base_radius else 0


static func tile_count(size: Vector2i) -> int:
	if size.x <= 0 or size.y <= 0:
		return 0
	return ceili(float(size.x) / TILE_SIZE) * ceili(float(size.y) / TILE_SIZE)


static func seed_work_count(updates: int, size: Vector2i, adaptive: bool) -> int:
	var pixels := maxi(size.x, 0) * maxi(size.y, 0)
	var candidates := tile_count(size) if adaptive else pixels
	return mini(maxi(updates, 0), candidates)


static func tile_representative_offset(candidate_index: int, phase: int) -> Vector2i:
	var candidate := posmod(candidate_index, TILE_REPRESENTATIVE_COUNT)
	var local_phase := posmod(phase + candidate * 17, TILE_REPRESENTATIVE_PHASE_COUNT)
	var local_offset := Vector2i(local_phase & 7, local_phase >> 3)
	return Vector2i((candidate & 1) * 8, ((candidate >> 1) & 1) * 8) + local_offset


static func tile_representative_phase(tile_cursor: int, sample_index: int,
		total_tiles: int) -> int:
	if total_tiles <= 0:
		return 0
	var absolute_visit := maxi(tile_cursor + sample_index, 0)
	var tile_index := absolute_visit % total_tiles
	var tile_sweep := absolute_visit / total_tiles
	return posmod(tile_index * 7 + tile_sweep * 13, TILE_REPRESENTATIVE_PHASE_COUNT)


static func least_covered_tile_candidate(coverage: PackedFloat32Array,
		valid: PackedByteArray, start_index: int) -> int:
	if coverage.size() < TILE_REPRESENTATIVE_COUNT \
			or valid.size() < TILE_REPRESENTATIVE_COUNT:
		return -1
	var start := posmod(start_index, TILE_REPRESENTATIVE_COUNT)
	var selected := -1
	var minimum_coverage := INF
	for offset in TILE_REPRESENTATIVE_COUNT:
		var candidate := (start + offset) % TILE_REPRESENTATIVE_COUNT
		if valid[candidate] == 0 or not is_finite(coverage[candidate]):
			continue
		# The shader uses scores above one for cells whose hash insertion is
		# currently locked. Leave those candidates for a later tile visit.
		if coverage[candidate] > 1.0:
			continue
		if coverage[candidate] < minimum_coverage:
			minimum_coverage = coverage[candidate]
			selected = candidate
	return selected


static func advance_tile_cursor(cursor: int, work_count: int, total_tiles: int) -> int:
	if total_tiles <= 0:
		return 0
	return posmod(cursor + maxi(work_count, 0), total_tiles * TILE_REPRESENTATIVE_PHASE_COUNT)


static func maintenance_lod_key(camera: Transform3D, inverse_projection: Projection,
		viewport_size: Vector2i, base_radius: float) -> int:
	var quantum := maxf(base_radius * 0.5, 0.05)
	var position_cell := Vector3i(floori(camera.origin.x / quantum),
		floori(camera.origin.y / quantum), floori(camera.origin.z / quantum))
	var forward := -camera.basis.z.normalized()
	var forward_cell := Vector3i(roundi(forward.x * 16.0), roundi(forward.y * 16.0),
		roundi(forward.z * 16.0))
	var projection_scale := roundi(inverse_projection[1][1] * 4096.0)
	var projection_kind := roundi(inverse_projection[3][3] * 4096.0)
	return hash([position_cell, forward_cell, projection_scale, projection_kind,
		viewport_size.y, roundi(base_radius * 4096.0)])


static func surface_tracking_changed(previous_revision: int, current_revision: int) -> bool:
	return previous_revision >= 0 and previous_revision != current_revision


static func maintenance_dispatch_count(capacity: int, remaining: int,
		surface_tracking_changed_value: bool, max_batch := 2048) -> int:
	var bounded_capacity := maxi(capacity, 0)
	if bounded_capacity == 0 or remaining <= 0:
		return 0
	if surface_tracking_changed_value:
		return bounded_capacity
	return mini(maxi(max_batch, 1), mini(remaining, bounded_capacity))


static func guide_bin_probability(packed_bins: PackedByteArray, bin_index: int) -> float:
	if packed_bins.size() != GUIDE_BINS or bin_index < 0 or bin_index >= GUIDE_BINS:
		return 1.0 / float(GUIDE_BINS)
	var total := 0.0
	for value in packed_bins:
		total += float(value)
	if total <= 0.0:
		return 1.0 / float(GUIDE_BINS)
	return float(packed_bins[bin_index]) / total


static func mixture_pdf(cosine_pdf: float, bin_probability: float,
		cosine_mix: float) -> float:
	var alpha := clampf(cosine_mix if is_finite(cosine_mix) else 1.0,
		MIN_COSINE_MIX, 1.0)
	var p_cos := maxf(cosine_pdf if is_finite(cosine_pdf) else 0.0, 0.0)
	var p_guide := p_cos * float(GUIDE_BINS) \
		* maxf(bin_probability if is_finite(bin_probability) else 0.0, 0.0)
	return alpha * p_cos + (1.0 - alpha) * p_guide


static func ray_strategy_counts(budget: int, emitter_nee_enabled: bool,
		emitter_count: int, total_power: float) -> Vector2i:
	var count := maxi(budget, 0)
	if not emitter_nee_enabled or emitter_count <= 0 or count < 2 \
			or not is_finite(total_power) or total_power <= 1e-12:
		return Vector2i(count, 0)
	var nee_count := count / 2
	return Vector2i(count - nee_count, nee_count)


static func responsive_history_weight(base_history: float, old_response: Vector3,
		short_mean: Vector3, second_moment: float, initialized: bool,
		change_z_threshold := DEFAULT_CHANGE_Z_THRESHOLD,
		fast_history_weight := DEFAULT_FAST_HISTORY_WEIGHT) -> float:
	var base := clampf(base_history if is_finite(base_history) else 0.9, 0.0, 0.99)
	if not initialized:
		return 0.0
	if not is_finite(short_mean.x) or not is_finite(short_mean.y) \
			or not is_finite(short_mean.z) or not is_finite(old_response.x) \
			or not is_finite(old_response.y) or not is_finite(old_response.z) \
			or not is_finite(second_moment):
		return base
	var variance := maxf(second_moment - short_mean.length_squared() / 3.0, 0.0)
	var innovation := (short_mean - old_response).length() / sqrt(3.0)
	var short_scale := maxf(sqrt(maxf(second_moment, 0.0)), 1e-3)
	var sigma := sqrt(variance + pow(short_scale * 0.02, 2.0))
	var z_score := innovation / maxf(sigma, 1e-6)
	var threshold := clampf(change_z_threshold if is_finite(change_z_threshold) else 0.75,
		0.5, 2.0)
	var confidence := smoothstep(threshold, threshold * 2.0, z_score)
	var fast := clampf(fast_history_weight if is_finite(fast_history_weight) else 0.5,
		0.0, base)
	return lerpf(base, fast, confidence)
