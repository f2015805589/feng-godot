extends RefCounted
## Shared probe marker sizing and deterministic world-space layout helpers.

const MARKER_RADIUS_CELL_RATIO := 0.12
## Version of persisted world-space candidate arbitration and coverage selection.
const PLACEMENT_LAYOUT_REVISION := 3
const MAX_DOMAINS_PER_ARBITRATION_CELL := 8
const CANDIDATES_PER_DOMAIN := 2

static func marker_radius(cell_size: Vector3) -> float:
	if not cell_size.is_finite():
		return 0.0
	return maxf(minf(cell_size.x, minf(cell_size.y, cell_size.z)), 0.0) \
			* MARKER_RADIUS_CELL_RATIO

static func world_cell(world_center: Vector3, spacing: float) -> Vector3i:
	if not world_center.is_finite() or not is_finite(spacing) or spacing <= 0.0:
		return Vector3i(2147483647, 2147483647, 2147483647)
	return Vector3i(floori(world_center.x / spacing), floori(world_center.y / spacing),
			floori(world_center.z / spacing))

static func world_cell_center(cell: Vector3i, spacing: float) -> Vector3:
	return (Vector3(cell) + Vector3.ONE * 0.5) * spacing

static func world_center_separation_squared(spacing: float) -> float:
	if not is_finite(spacing) or spacing <= 0.0:
		return INF
	# This tolerance only accounts for floating-point coordinate error; it does not
	# scale with the Volume transform or the visual marker radius.
	var minimum_distance := maxf(0.0, spacing - maxf(0.000001, spacing * 0.000001))
	return minimum_distance * minimum_distance

static func world_cell_rank(domain_key: String, cell: Vector3i) -> int:
	# Deterministic FNV-1a over the stable domain key and signed cell coordinates.
	# The cell mix lets a bounded domain set rotate across space instead of always
	# retaining the same lexically first eight domains in every crowded voxel.
	var hash_value: int = 2166136261
	for byte_value in domain_key.to_utf8_buffer():
		hash_value = int((hash_value ^ int(byte_value)) * 16777619) & 0xffffffff
	for coordinate in [cell.x, cell.y, cell.z]:
		var bits: int = int(coordinate) & 0xffffffff
		for shift in [0, 8, 16, 24]:
			hash_value = int((hash_value ^ ((bits >> shift) & 0xff)) * 16777619) & 0xffffffff
	return hash_value

static func morton_words(cell: Vector3i) -> PackedInt64Array:
	# A signed-coordinate 96-bit Morton key represented as three unsigned 32-bit
	# words. This preserves interleaving over Vector3i's full range without a
	# platform-dependent signed overflow in one 64-bit scalar.
	var coordinates := PackedInt64Array([
		int(cell.x) ^ 0x80000000,
		int(cell.y) ^ 0x80000000,
		int(cell.z) ^ 0x80000000,
	])
	var words := PackedInt64Array([0, 0, 0])
	var output_bit := 0
	for bit in range(31, -1, -1):
		for axis in 3:
			var word_index := int(output_bit / 32)
			var word_bit := 31 - (output_bit % 32)
			words[word_index] = int(words[word_index]) \
					| (((int(coordinates[axis]) >> bit) & 1) << word_bit)
			output_bit += 1
	return words

static func morton_words_less(a: PackedInt64Array, b: PackedInt64Array) -> bool:
	for index in 3:
		if int(a[index]) != int(b[index]):
			return int(a[index]) < int(b[index])
	return false

