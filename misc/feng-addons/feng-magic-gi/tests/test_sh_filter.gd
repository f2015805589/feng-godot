extends SceneTree
## CPU-only proof checks for the runtime SH9 atlas window.

const Data = preload("../feng_magic_gi_data.gd")
const SHFilter = preload("../feng_magic_gi_sh_filter.gd")
const Y00 := 0.2820947918
const L1_BOUND := 0.488602512
const L2_BOUND := 0.630783131
var failures := 0
var checks := 0

func require(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)

func _initialize() -> void:
	var cosine := PackedFloat32Array([
		Y00, 0.0, 0.3257350079, 0.0, 0.0, 0.0, 0.15769578265, 0.0, 0.0])
	var cosine_transfer := _single_channel_transfer(cosine)
	var cosine_scale := SHFilter.high_band_scale(cosine_transfer, 0).x
	var cosine_min := _minimum_response(cosine, cosine_scale, 4096)
	require(cosine_scale > 0.85 and cosine_scale <= 1.0,
			"the cosine-hemisphere SH9 fixture should retain substantially more l=1,2 energy than the old envelope")
	require(cosine_min >= -0.000001,
			"the filtered cosine-hemisphere SH9 response should stay nonnegative on a dense sphere")

	var pure_l2 := PackedFloat32Array([0.45, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0])
	var pure_l2_scale := SHFilter.high_band_scale(_single_channel_transfer(pure_l2), 0).x
	require(pure_l2_scale > 0.35 and pure_l2_scale < 0.5
			and _minimum_response(pure_l2, pure_l2_scale, 4096) >= -0.000001,
			"pure l=2 with a repeated minimum eigenvalue must filter without losing the hard case")
	var hard_case := pure_l2.duplicate()
	hard_case[2] = 0.05 # b is perpendicular to the repeated minimum-eigenvalue plane.
	var hard_case_scale := SHFilter.high_band_scale(_single_channel_transfer(hard_case), 0).x
	require(absf(hard_case_scale - pure_l2_scale) < 0.005
			and _minimum_response(hard_case, hard_case_scale, 4096) >= -0.000001,
			"the trust-region hard case must retain its boundary dual solution")

	# These three coefficient vectors are direct channel slices from probes 346,
	# 632 and 0 of the 634-probe Cornell bake; they are kept here as small stable
	# regression fixtures rather than making the test depend on an author project.
	var actual_vectors: Array[PackedFloat32Array] = [
		PackedFloat32Array([0.025148632, -0.0017303731, 0.032012, -0.0015311866,
				-0.000061774925, -0.002772998, 0.020940933, -0.0013662456, 0.000013620636]),
		PackedFloat32Array([0.03568994, -0.0033970547, 0.046510402, 0.003845972,
				-0.00095416076, -0.0035174664, 0.032849416, 0.005272482, -0.0003819392]),
		PackedFloat32Array([0.0022038657, 0.0019364832, 0.0008931864, -0.00019123705,
				-0.000093173329, 0.00010207952, -0.000111305155, -0.00048209075, -0.00049589574]),
	]
	for fixture_index in actual_vectors.size():
		var coefficients := actual_vectors[fixture_index]
		var transfer := _single_channel_transfer(coefficients)
		var scale := SHFilter.high_band_scale(transfer, 0).x
		var dc_before := coefficients[0] * Y00
		var old_bound := L1_BOUND * sqrt(coefficients[1] * coefficients[1]
				+ coefficients[2] * coefficients[2] + coefficients[3] * coefficients[3]) \
				+ L2_BOUND * sqrt(coefficients[4] * coefficients[4]
				+ coefficients[5] * coefficients[5] + coefficients[6] * coefficients[6]
				+ coefficients[7] * coefficients[7] + coefficients[8] * coefficients[8])
		var old_scale := dc_before * (1.0 - 0.00001) / old_bound
		require(scale > old_scale + 0.05,
				"representative baked channel %d should retain more directional energy than the old envelope" % fixture_index)
		require(_minimum_response(coefficients, scale, 4096) >= -0.000001,
				"representative baked channel %d should remain nonnegative on a dense sphere" % fixture_index)

	var tiny_transfer := _single_channel_transfer(actual_vectors[0])
	var huge_transfer := _single_channel_transfer(actual_vectors[0])
	for value_index in tiny_transfer.size():
		tiny_transfer[value_index] *= 1.0e-20
		huge_transfer[value_index] *= 1.0e20
	var tiny_scale := SHFilter.high_band_scale(tiny_transfer, 0).x
	var huge_scale := SHFilter.high_band_scale(huge_transfer, 0).x
	require(absf(tiny_scale - huge_scale) < 0.0001,
			"coefficient normalization must keep the filter homogeneous at small and large finite magnitudes")

	var mixed_transfer := PackedFloat32Array()
	mixed_transfer.resize(27)
	mixed_transfer.fill(0.0)
	for coefficient in 9:
		mixed_transfer[coefficient * 3] = cosine[coefficient]
		mixed_transfer[coefficient * 3 + 1] = actual_vectors[0][coefficient]
	mixed_transfer[1 * 3 + 2] = 1.0 # Blue has high bands but no positive DC.
	var mixed_scale := SHFilter.high_band_scale(mixed_transfer, 0)
	require(mixed_scale.x > 0.85 and mixed_scale.y > 0.65 and mixed_scale.z == 0.0,
			"RGB channels must be filtered independently, including the no-DC channel")
	require(_minimum_transfer_response(mixed_transfer, 0, mixed_scale.x, 4096) >= -0.000001
			and _minimum_transfer_response(mixed_transfer, 1, mixed_scale.y, 4096) >= -0.000001
			and _minimum_transfer_response(mixed_transfer, 2, mixed_scale.z, 4096) >= -0.000001,
			"mixed RGB runtime responses must stay nonnegative across a dense sphere")
	var packed_data := Data.new()
	packed_data.positions = PackedVector3Array([Vector3.ZERO])
	packed_data.transfer = mixed_transfer
	var image: Image = packed_data._pack_atlas_image(true)
	require(packed_data.transfer == mixed_transfer,
			"runtime filtering must leave the serialized transfer array untouched")
	var dc_preserved := true
	var high_bands_scaled := true
	for coefficient in 27:
		var packed_color := image.get_pixel(int(coefficient / 4), 0)
		var packed_value: float = float(packed_color[coefficient % 4])
		var expected_value := mixed_transfer[coefficient]
		if coefficient >= 3:
			expected_value *= mixed_scale[(coefficient % 3)]
		if coefficient < 3:
			dc_preserved = dc_preserved and is_equal_approx(packed_value, expected_value)
		else:
			high_bands_scaled = high_bands_scaled and is_equal_approx(packed_value, expected_value)
	require(dc_preserved, "runtime atlas packing must preserve all three raw DC coefficients")
	require(high_bands_scaled,
			"runtime atlas packing must apply each independent scale only to that channel's l>=1")

	var no_dc := PackedFloat32Array([0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0])
	require(SHFilter.high_band_scale(_single_channel_transfer(no_dc), 0).x == 0.0,
			"zero DC must not introduce a floor to suppress negative lobes")
	print("MAGIC_GI_SH_FILTER_RESULT checks=", checks, " failures=", failures)
	quit(1 if failures else 0)

func _single_channel_transfer(coefficients: PackedFloat32Array) -> PackedFloat32Array:
	var transfer := PackedFloat32Array()
	transfer.resize(27)
	transfer.fill(0.0)
	for coefficient in 9:
		transfer[coefficient * 3] = coefficients[coefficient]
	return transfer

func _minimum_response(coefficients: PackedFloat32Array, high_band_scale: float,
			sample_count: int) -> float:
	var minimum := INF
	for sample_index in sample_count:
		var z := 1.0 - 2.0 * (float(sample_index) + 0.5) / float(sample_count)
		var azimuth := PI * (3.0 - sqrt(5.0)) * float(sample_index)
		var radius := sqrt(maxf(0.0, 1.0 - z * z))
		var direction := Vector3(radius * cos(azimuth), radius * sin(azimuth), z)
		var basis := Data.sh_basis(direction)
		var value := coefficients[0] * basis[0]
		for coefficient in range(1, 9):
			value += coefficients[coefficient] * basis[coefficient] * high_band_scale
		minimum = minf(minimum, value)
	return minimum

func _minimum_transfer_response(transfer: PackedFloat32Array, channel: int,
			high_band_scale: float, sample_count: int) -> float:
	var minimum := INF
	for sample_index in sample_count:
		var z := 1.0 - 2.0 * (float(sample_index) + 0.5) / float(sample_count)
		var azimuth := PI * (3.0 - sqrt(5.0)) * float(sample_index)
		var radius := sqrt(maxf(0.0, 1.0 - z * z))
		var direction := Vector3(radius * cos(azimuth), radius * sin(azimuth), z)
		var basis := Data.sh_basis(direction)
		var value := transfer[channel] * basis[0]
		for coefficient in range(1, 9):
			value += transfer[coefficient * 3 + channel] * basis[coefficient] * high_band_scale
		minimum = minf(minimum, value)
	return minimum
