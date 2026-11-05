extends SceneTree
## GPU regression: compare both sides of every transition face using a
## spatially varying parent field. Constant colors cannot expose half-cell seams.
const Cache = preload("../passes/magic_gi_preinterpolated_volume_cache.gd")
const R := 16
const LEVELS := 4
var checks := 0
var failures := 0
var rd: RenderingDevice

func _initialize() -> void: call_deferred("run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)

func run() -> void:
	rd = RenderingServer.create_local_rendering_device()
	if rd == null:
		check(false, "GPU RenderingDevice required")
	else:
		for half in [false, true]:
			for partitions in [1, 2]:
				for camera: Vector3 in [Vector3(-0.91, 0.41, 1.31), Vector3(0.24, -0.17, -0.44)]:
					run_fixture(half, partitions, camera)
		rd.free()
	print("CLV cascade premix: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func run_fixture(half: bool, partitions: int, camera: Vector3) -> void:
	var cache := Cache.new()
	cache.dimensions = Vector3i(R, R, R * LEVELS)
	cache.clip_cell_count = R * R * R * LEVELS
	cache._half_fields = half
	if partitions == 2:
		# Only the existence of the existing OLV binding selects two partitions.
		# This test neither invokes a model nor changes any labels.
		var label_format := RDTextureFormat.new()
		label_format.width = 1
		label_format.height = 1
		label_format.format = RenderingDevice.DATA_FORMAT_R8_UNORM
		label_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		cache._olv_label_atlas = rd.texture_create(label_format, RDTextureView.new(), [PackedByteArray([1])])
	var source_origin := Vector3(-2.375, -1.125, -2.625)
	for level in LEVELS:
		var step := 0.25 * float(1 << level)
		var center := ((camera - source_origin) / step).round()
		cache._lod_layouts.append({"origin_world": source_origin + (center - Vector3.ONE * 8.0) * step,
			"spacing_m": step})
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	format.width = R * partitions
	format.height = R
	format.depth = R * LEVELS * 4
	format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT if half else RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var created := cache._create_response_fields(rd, format)
	check(created, "create premix resources: " + cache._error)
	if not cache._premix_pipeline.is_valid():
		free_cache(cache)
		return
	var raw := Image.create(format.width, format.height * format.depth, false, Image.FORMAT_RGBAF)
	for field in 4:
		for level in LEVELS:
			for z in R:
				for y in R:
					for x in R:
						for partition in partitions:
							# Oscillating parent samples deliberately have different slopes
							# in adjoining cells. Include fractional support/normalization.
							var mass := 0.4 + 0.025 * ((x + y + z) % 17)
							var energy := 1.0 + 0.2 * level + 0.1 * field + sin(x * 0.7) * 0.15 + y * 0.02 + z * 0.01
							energy += 1000.0 * partition
							var value := Color(energy, energy * 0.6, energy * 0.3, energy * 0.1) * mass
							if field == 3: value = Color(0, 0, 0, mass)
							raw.set_pixel(x + partition * R, y + (z + level * R + field * R * LEVELS) * R, value)
	if half: raw.convert(Image.FORMAT_RGBAH)
	var raw_bytes := raw.get_data()
	check(rd.texture_update(cache._raw_response, 0, raw_bytes) == OK, "upload analytic raw response")
	var dispatched := cache._premix_response(rd, false)
	check(dispatched, "dispatch actual production premix: " + cache._error)
	if not dispatched:
		free_cache(cache)
		return
	rd.submit()
	rd.sync()
	var mixed_bytes := rd.texture_get_data(cache.texture_fields[0], 0)
	var mixed := Image.create_from_data(raw.get_width(), raw.get_height(), false, raw.get_format(), mixed_bytes)
	var tolerance := 0.0015 if half else 0.00001
	for level in LEVELS:
		for partition in partitions:
			for field in 4:
				check(error(sample(mixed, Vector3(8, 8, 8), level, partition, field),
						sample(raw, Vector3(8, 8, 8), level, partition, field)) <= tolerance,
					"interior and coarsest response preserved")
		if level + 1 == LEVELS: continue
		var fine: Dictionary = cache._lod_layouts[level]
		var coarse: Dictionary = cache._lod_layouts[level + 1]
		# Enumerate the parent's exact world-space sample planes which fit the
		# fine window. No call to the shader's blend-bounds implementation.
		var lower: Vector3 = ((Vector3(fine.origin_world) - Vector3(coarse.origin_world)) / float(coarse.spacing_m)).ceil()
		var upper: Vector3 = ((Vector3(fine.origin_world) + Vector3.ONE * 15.0 * float(fine.spacing_m) \
			- Vector3(coarse.origin_world)) / float(coarse.spacing_m)).floor()
		for axis in 3:
			for face in [0, 1]:
				for offset in [0.27, 1.13, 2.49, 4.17, 5.63]:
					var parent_grid := lower + Vector3(offset, offset * 0.73, offset * 0.89)
					parent_grid[axis] = lower[axis] if face == 0 else upper[axis]
					var world: Vector3 = coarse.origin_world + parent_grid * float(coarse.spacing_m)
					var fine_grid: Vector3 = (world - Vector3(fine.origin_world)) / float(fine.spacing_m)
					for partition in partitions:
						for field in 4:
							check(error(sample(mixed, fine_grid, level, partition, field),
								sample(mixed, parent_grid, level + 1, partition, field)) <= tolerance,
								"adjacent cascade fields agree on the transition face (including OLV and coverage)")
	check(cache._premix_response(rd, false), "repeat premix from immutable raw field")
	rd.submit()
	rd.sync()
	check(rd.texture_get_data(cache.texture_fields[0], 0) == mixed_bytes, "repeated premix cannot accumulate blur")
	check(rd.texture_get_data(cache._raw_response, 0) == raw_bytes, "premix never overwrites relight output")
	if partitions == 2:
		for level in LEVELS:
			check(sample(mixed, Vector3(7.5, 7.5, 7.5), level, 0, 0).r < 5.0,
				"1000x exterior radiance never enters the other OLV partition")
	free_cache(cache)

func sample(data: Image, grid: Vector3, level: int, partition: int, field: int) -> Color:
	var base := Vector3i(grid.floor()).clamp(Vector3i.ZERO, Vector3i.ONE * (R - 2))
	var fraction := (grid - Vector3(base)).clamp(Vector3.ZERO, Vector3.ONE)
	var result := Color(0, 0, 0, 0)
	for corner in 8:
		var cell := base + Vector3i(corner & 1, (corner >> 1) & 1, (corner >> 2) & 1)
		var weight := 1.0
		for axis in 3: weight *= fraction[axis] if (corner & (1 << axis)) != 0 else 1.0 - fraction[axis]
		result += data.get_pixel(cell.x + partition * R,
			cell.y + (cell.z + level * R + field * R * LEVELS) * R) * weight
	return result

func error(a: Color, b: Color) -> float:
	var largest := 0.0
	for channel in 4: largest = maxf(largest, absf(a[channel] - b[channel]) / maxf(1.0, absf(b[channel])))
	return largest

func free_cache(cache: RefCounted) -> void:
	for rid: RID in cache.owned_rids():
		if rid.is_valid(): rd.free_rid(rid)
