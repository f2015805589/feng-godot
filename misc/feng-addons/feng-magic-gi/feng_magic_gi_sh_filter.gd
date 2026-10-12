extends RefCounted
## Runtime-only nonnegative window for one RGB channel of an SH9 transfer.
## This pure helper reads coefficients in-place and never changes saved bake data.

const SH_Y00 := 0.2820947918
const SH_L1_ABSOLUTE_BOUND := 0.488602512
const SH_L2_ABSOLUTE_BOUND := 0.630783131
const FILTER_EPSILON := 0.00001
const EIGEN_RELATIVE_MARGIN := 0.000002
const DUAL_RELATIVE_MARGIN := 0.00005 # Covers f32 Vector3 return and RGBAF packing roundoff.
const DUAL_ITERATIONS := 24

## `probe_base` is the first float of a 27-float, coefficient-major RGB probe.
## No per-channel array is built, so atlas packing remains bounded by the bake.
static func high_band_scale(transfer: PackedFloat32Array, probe_base: int) -> Vector3:
	var result := Vector3.ZERO
	for channel in 3:
		result[channel] = _channel_scale(transfer, probe_base, channel)
	return result

static func _channel_scale(transfer: PackedFloat32Array, probe_base: int, channel: int) -> float:
	var c0 := float(transfer[probe_base + channel])
	var c1 := float(transfer[probe_base + 3 + channel])
	var c2 := float(transfer[probe_base + 6 + channel])
	var c3 := float(transfer[probe_base + 9 + channel])
	var c4 := float(transfer[probe_base + 12 + channel])
	var c5 := float(transfer[probe_base + 15 + channel])
	var c6 := float(transfer[probe_base + 18 + channel])
	var c7 := float(transfer[probe_base + 21 + channel])
	var c8 := float(transfer[probe_base + 24 + channel])
	var coefficient_scale := maxf(absf(c0), maxf(absf(c1), maxf(absf(c2), maxf(absf(c3),
			maxf(absf(c4), maxf(absf(c5), maxf(absf(c6), maxf(absf(c7), absf(c8)))))))))
	if not is_finite(coefficient_scale) or coefficient_scale <= 0.0:
		return 0.0
	c0 /= coefficient_scale
	c1 /= coefficient_scale
	c2 /= coefficient_scale
	c3 /= coefficient_scale
	c4 /= coefficient_scale
	c5 /= coefficient_scale
	c6 /= coefficient_scale
	c7 /= coefficient_scale
	c8 /= coefficient_scale
	var dc := SH_Y00 * c0
	if dc <= 0.0:
		# Preserve the established no-floor behavior for zero/negative DC.
		return 0.0
	var l1_bound := SH_L1_ABSOLUTE_BOUND * sqrt(c1 * c1 + c2 * c2 + c3 * c3)
	var l2_bound := SH_L2_ABSOLUTE_BOUND * sqrt(c4 * c4 + c5 * c5 + c6 * c6 + c7 * c7 + c8 * c8)
	var original_bound := l1_bound + l2_bound
	if not is_finite(original_bound):
		return 0.0
	if original_bound <= dc:
		# The original addition-theorem envelope already proves scale 1 safe.
		return 1.0
	var original_scale := clampf(dc * (1.0 - FILTER_EPSILON) / original_bound, 0.0, 1.0)

	# Write the l=1,2 reconstruction as b.n + n^T Q n. The simple spectral
	# bound and the dual below are both lower bounds on its unit-sphere minimum.
	var b_x := SH_L1_ABSOLUTE_BOUND * c3
	var b_y := SH_L1_ABSOLUTE_BOUND * c1
	var b_z := SH_L1_ABSOLUTE_BOUND * c2
	var q_xx := -0.3153915653 * c6 + 0.5462742153 * c8
	var q_yy := -0.3153915653 * c6 - 0.5462742153 * c8
	var q_zz := 0.6307831306 * c6
	var q_xy := 0.5 * 1.0925484306 * c4
	var q_yz := 0.5 * 1.0925484306 * c5
	var q_xz := 0.5 * 1.0925484306 * c7
	var lambda_estimate := _symmetric_min_eigenvalue(
			q_xx, q_yy, q_zz, q_xy, q_yz, q_xz)
	if not is_finite(lambda_estimate):
		return original_scale
	var row_lower := minf(q_xx - absf(q_xy) - absf(q_xz),
			minf(q_yy - absf(q_xy) - absf(q_yz), q_zz - absf(q_xz) - absf(q_yz)))
	# Gershgorin's row bound is the certified simple eigenvalue bound. The
	# closed-form eigen estimate only seeds the dual shift; Cholesky verifies it.
	var simple_margin := DUAL_RELATIVE_MARGIN * maxf(1.0, absf(row_lower))
	var simple_lower := row_lower - simple_margin - sqrt(b_x * b_x + b_y * b_y + b_z * b_z)
	var dual_result := _dual_minimum_lower_bound(
			q_xx, q_yy, q_zz, q_xy, q_yz, q_xz,
			b_x, b_y, b_z, lambda_estimate, row_lower)
	if not is_finite(dual_result):
		# Any failed SPD/finite check falls back to the established safe filter.
		return original_scale
	var minimum_lower := maxf(-original_bound, maxf(simple_lower, dual_result))
	if not is_finite(minimum_lower):
		return original_scale
	if minimum_lower >= -dc:
		return 1.0
	return clampf(dc * (1.0 - FILTER_EPSILON) / -minimum_lower, 0.0, 1.0)

## For lambda < lambda_min(Q), A=Q-lambda*I is positive definite and
## n^TQn+b.n >= lambda - b^T A^-1 b/4 for every unit n (complete the square;
## the omitted squared term is nonnegative). Bisection maximizes this certified
## dual lower bound. The SPD solve rejects uncertain shifts; margins round both
## the eigenvalue shift and the final bound down before RGBAF atlas upload.
static func _dual_minimum_lower_bound(q_xx: float, q_yy: float, q_zz: float,
		q_xy: float, q_yz: float, q_xz: float,
		b_x: float, b_y: float, b_z: float,
		lambda_estimate: float, row_lower: float) -> float:
	var margin := EIGEN_RELATIVE_MARGIN * maxf(1.0, absf(lambda_estimate))
	var lambda_upper := lambda_estimate - margin
	var upper_eval := _dual_evaluate(q_xx, q_yy, q_zz, q_xy, q_yz, q_xz,
			b_x, b_y, b_z, lambda_upper)
	for _retry in 8:
		if upper_eval.z > 0.5:
			break
		margin *= 2.0
		lambda_upper = lambda_estimate - margin
		upper_eval = _dual_evaluate(q_xx, q_yy, q_zz, q_xy, q_yz, q_xz,
				b_x, b_y, b_z, lambda_upper)
	if upper_eval.z <= 0.5:
		return NAN
	var best_lower := upper_eval.y
	var b_length := sqrt(b_x * b_x + b_y * b_y + b_z * b_z)
	var span := maxf(1.0, maxf(absf(row_lower), maxf(absf(lambda_upper), b_length)))
	var lambda_lower := minf(row_lower, lambda_upper) - span
	var lower_eval := _dual_evaluate(q_xx, q_yy, q_zz, q_xy, q_yz, q_xz,
			b_x, b_y, b_z, lambda_lower)
	for _retry in 8:
		if lower_eval.z > 0.5 and lower_eval.x > 0.0:
			break
		lambda_lower -= span
		span *= 2.0
		lower_eval = _dual_evaluate(q_xx, q_yy, q_zz, q_xy, q_yz, q_xz,
				b_x, b_y, b_z, lambda_lower)
	if lower_eval.z <= 0.5 or lower_eval.x <= 0.0:
		return NAN
	best_lower = maxf(best_lower, lower_eval.y)
	if upper_eval.x >= 0.0:
		return best_lower # The dual is still increasing at the SPD boundary.
	for _iteration in DUAL_ITERATIONS:
		var lambda_mid := 0.5 * (lambda_lower + lambda_upper)
		var middle_eval := _dual_evaluate(q_xx, q_yy, q_zz, q_xy, q_yz, q_xz,
				b_x, b_y, b_z, lambda_mid)
		if middle_eval.z <= 0.5:
			lambda_upper = lambda_mid
			continue
		best_lower = maxf(best_lower, middle_eval.y)
		if middle_eval.x > 0.0:
			lambda_lower = lambda_mid
		else:
			lambda_upper = lambda_mid
	return best_lower

static func _dual_evaluate(q_xx: float, q_yy: float, q_zz: float,
		q_xy: float, q_yz: float, q_xz: float,
		b_x: float, b_y: float, b_z: float, lambda_value: float) -> Vector3:
	# Keep the solve in scalar GDScript floats: Vector3/Vector4 storage is f32
	# and would quantize the witness before its downward margin is applied.
	var a_xx := q_xx - lambda_value
	var a_yy := q_yy - lambda_value
	var a_zz := q_zz - lambda_value
	if not is_finite(a_xx) or not is_finite(a_yy) or not is_finite(a_zz) \
			or a_xx <= 0.0:
		return Vector3(NAN, NAN, 0.0)
	var l_00 := sqrt(a_xx)
	var l_10 := q_xy / l_00
	var l_20 := q_xz / l_00
	var diagonal_1 := a_yy - l_10 * l_10
	if not is_finite(diagonal_1) or diagonal_1 <= 0.0:
		return Vector3(NAN, NAN, 0.0)
	var l_11 := sqrt(diagonal_1)
	var l_21 := (q_yz - l_20 * l_10) / l_11
	var diagonal_2 := a_zz - l_20 * l_20 - l_21 * l_21
	if not is_finite(diagonal_2) or diagonal_2 <= 0.0:
		return Vector3(NAN, NAN, 0.0)
	var l_22 := sqrt(diagonal_2)
	var y_0 := b_x / l_00
	var y_1 := (b_y - l_10 * y_0) / l_11
	var y_2 := (b_z - l_20 * y_0 - l_21 * y_1) / l_22
	var inverse_b_z := y_2 / l_22
	var inverse_b_y := (y_1 - l_21 * inverse_b_z) / l_11
	var inverse_b_x := (y_0 - l_10 * inverse_b_y - l_20 * inverse_b_z) / l_00
	if not is_finite(inverse_b_x) or not is_finite(inverse_b_y) or not is_finite(inverse_b_z):
		return Vector3(NAN, NAN, 0.0)
	var quadratic := b_x * inverse_b_x + b_y * inverse_b_y + b_z * inverse_b_z
	if not is_finite(quadratic) or quadratic < 0.0:
		return Vector3(NAN, NAN, 0.0)
	var raw_lower := lambda_value - 0.25 * quadratic
	var rounding_margin := DUAL_RELATIVE_MARGIN * maxf(1.0,
			absf(lambda_value) + 0.25 * quadratic)
	var derivative := 1.0 - 0.25 * (inverse_b_x * inverse_b_x
			+ inverse_b_y * inverse_b_y + inverse_b_z * inverse_b_z)
	if not is_finite(raw_lower) or not is_finite(derivative):
		return Vector3(NAN, NAN, 0.0)
	return Vector3(derivative, raw_lower - rounding_margin, 1.0)

static func _symmetric_min_eigenvalue(q_xx: float, q_yy: float, q_zz: float,
		q_xy: float, q_yz: float, q_xz: float) -> float:
	var mean := (q_xx + q_yy + q_zz) / 3.0
	var xx := q_xx - mean
	var yy := q_yy - mean
	var zz := q_zz - mean
	var p_squared := (xx * xx + yy * yy + zz * zz \
			+ 2.0 * (q_xy * q_xy + q_yz * q_yz + q_xz * q_xz)) / 6.0
	if not is_finite(p_squared) or p_squared < 0.0:
		return NAN
	if p_squared <= 0.00000000000000000001:
		return mean
	var p := sqrt(p_squared)
	var a := xx / p
	var d := yy / p
	var f := zz / p
	var b := q_xy / p
	var c := q_yz / p
	var e := q_xz / p
	var determinant := a * d * f + 2.0 * b * c * e - a * c * c - d * e * e - f * b * b
	var r := clampf(0.5 * determinant, -1.0, 1.0)
	var angle := acos(r) / 3.0
	return mean + 2.0 * p * cos(angle + 2.0 * PI / 3.0)
