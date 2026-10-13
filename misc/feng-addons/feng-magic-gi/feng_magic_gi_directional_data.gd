@tool
extends Resource
## Directional incident radiance transport. Unlike the surface estimator, each
## output coefficient can be convolved with any receiver normal after relighting.
## Layout: probe, outgoing SH9, incident SH9, RGB. Sky is achromatic SH9 x SH9.

const REVISION := 1
const COEFFICIENTS := 9
const TRANSFER_STRIDE := 243
const SKY_STRIDE := 81
const EMISSION_STRIDE := 54

@export_storage var revision := REVISION
@export_storage var probe_count := 0
@export_storage var source_count := 0
@export_storage var transfer := PackedFloat32Array()
@export_storage var sky := PackedFloat32Array()
@export_storage var emission := PackedFloat32Array()

func allocate(probes: int, sources: int) -> void:
	probe_count = probes
	source_count = sources
	transfer.resize(probes * TRANSFER_STRIDE)
	sky.resize(probes * SKY_STRIDE)
	emission.resize(probes * sources * EMISSION_STRIDE)

func is_valid(probes: int, sources: int) -> bool:
	if revision != REVISION or probes <= 0 or sources < 0 \
			or probe_count != probes or source_count != sources \
			or transfer.size() != probes * TRANSFER_STRIDE \
			or sky.size() != probes * SKY_STRIDE \
			or emission.size() != probes * sources * EMISSION_STRIDE:
		return false
	for values in [transfer, sky, emission]:
		for value in values:
			if not is_finite(value):
				return false
	return true

func relight(probe: int, lighting: PackedFloat32Array, sky_lighting: PackedFloat32Array,
		sources: PackedFloat32Array) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	result.resize(54) # Secondary + emission SH9 RGB, followed by primary sky SH9 RGB.
	if probe < 0 or probe >= probe_count or lighting.size() != 27 \
			or sky_lighting.size() != 27 or sources.size() != source_count * 6:
		return result
	for outgoing in 9:
		for incoming in 9:
			for channel in 3:
				result[outgoing * 3 + channel] += transfer[probe * 243 + outgoing * 27 + incoming * 3 + channel] * lighting[incoming * 3 + channel]
				result[27 + outgoing * 3 + channel] += sky[probe * 81 + outgoing * 9 + incoming] * sky_lighting[incoming * 3 + channel]
		for source in source_count:
			for channel in 3:
				var base := (source * probe_count + probe) * 54 + outgoing * 6 + channel
				result[outgoing * 3 + channel] += emission[base] * sources[source * 6 + channel] \
						+ emission[base + 3] * sources[source * 6 + 3 + channel]
	return result

static func diffuse_response(coefficients: PackedFloat32Array, normal: Vector3) -> Vector3:
	if coefficients.size() != 27:
		return Vector3.ZERO
	var y := basis(normal.normalized())
	var result := Vector3.ZERO
	for k in 9:
		# Cosine convolution divided by PI: radiance -> unit-albedo diffuse radiance.
		var kernel := 1.0 if k == 0 else (2.0 / 3.0 if k < 4 else 0.25)
		for channel in 3:
			result[channel] += coefficients[k * 3 + channel] * y[k] * kernel
	return result.max(Vector3.ZERO)

static func basis(direction: Vector3) -> PackedFloat32Array:
	var d := direction
	return PackedFloat32Array([0.2820947918, 0.4886025119 * d.y, 0.4886025119 * d.z,
		0.4886025119 * d.x, 1.0925484306 * d.x * d.y, 1.0925484306 * d.y * d.z,
		0.3153915653 * (3.0 * d.z * d.z - 1.0), 1.0925484306 * d.x * d.z,
		0.5462742153 * (d.x * d.x - d.y * d.y)])
