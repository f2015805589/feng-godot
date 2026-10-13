@tool
class_name FMagicGIPreview
extends RefCounted
## Editor-only response helpers. These visualize the saved transport without
## changing the runtime bake format or adding energy to zero-response probes.

const Data = preload("feng_magic_gi_data.gd")

static func layout_matches(data: FMagicGIData, probe_positions: PackedVector3Array) -> bool:
	if data == null or data.probe_count() != probe_positions.size() \
			or data.positions.size() != probe_positions.size():
		return false
	for index in probe_positions.size():
		if not data.positions[index].is_equal_approx(probe_positions[index]):
			return false
	return true

## Current complete per-probe response: secondary transport, primary sky
## visibility, and the live emissive contribution, all scaled as in the volume.
static func probe_response(data: FMagicGIData, index: int,
		lighting: PackedFloat32Array, sky_lighting: PackedFloat32Array,
		emission_payload: PackedFloat32Array, strength: float) -> Vector3:
	if data == null or index < 0 or index >= data.probe_count():
		return Vector3.ZERO
	var response := data.evaluate(index, lighting, sky_lighting)
	if emission_payload.size() == data.probe_count() * 3:
		var base := index * 3
		response += Vector3(emission_payload[base], emission_payload[base + 1], emission_payload[base + 2])
	return response * strength

## Unit-white-source angular transport for the SH gizmo. Emission is excluded
## because the bake stores no directional emitter response.
static func unit_source_response(data: FMagicGIData, index: int, direction: Vector3) -> Vector3:
	if data == null or index < 0 or index >= data.probe_count() or direction.length_squared() <= 0.000001:
		return Vector3.ZERO
	var secondary := data.transport_response(index, direction).max(Vector3.ZERO)
	var primary := 0.0
	if data.format_version >= Data.PRIMARY_SKY_FORMAT_VERSION \
			and data.primary_sky_visibility.size() == data.probe_count() * 9:
		var basis := Data.sh_basis(direction.normalized())
		var base := index * 9
		for coefficient in 9:
			primary += data.primary_sky_visibility[base + coefficient] * basis[coefficient]
	primary = maxf(primary / PI, 0.0)
	return secondary + Vector3.ONE * primary
