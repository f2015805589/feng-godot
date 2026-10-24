@tool
extends RefCounted
## Worker-only debug SH of resident prepared brick CORE cells. This is explicitly
## prepared transport, never presented as the original free-space source probes.
const Brick = preload("feng_magic_gi_prepared_transfer_brick.gd")
static func build(pages: Array, lighting: PackedFloat32Array, sky: PackedFloat32Array,
		cancelled := Callable()) -> Dictionary:
	if lighting.size() != 27 or sky.size() != 27 or not _finite(lighting) or not _finite(sky): return {}
	var positions := PackedVector3Array()
	var spacings := PackedFloat32Array()
	var lods := PackedInt32Array()
	var response := PackedFloat32Array()
	for page in pages:
		var brick: Resource = page.get("prepared_transfer_brick")
		if not brick is Brick or not brick.is_header_valid(): continue
		var emission: PackedFloat32Array = page.get("emission_sources", PackedFloat32Array())
		if emission.size() != brick.emitter_count * 6 or not _finite(emission): return {}
		var columns: int = 36 + brick.emitter_count * 6
		for z in brick.core_dimensions.z:
			for y in brick.core_dimensions.y:
				for x in brick.core_dimensions.x:
					if positions.size() % 32 == 0 and cancelled.is_valid() and bool(cancelled.call()): return {}
					var cell: Vector3i = brick.core_cell_origin + Vector3i(x, y, z)
					var index: int = brick.cell_index(cell)
					if brick.validity[index] == 0: continue
					positions.append(brick.cell_position(cell))
					spacings.append(brick.spacing_m())
					lods.append(brick.level)
					for outgoing in 9:
						for channel in 3:
							var value := 0.0
							var row: int = (index * 9 + outgoing) * columns
							for incoming in 9:
								value += brick.operators[row + incoming * 3 + channel] * lighting[incoming * 3 + channel] \
									+ brick.operators[row + 27 + incoming] * sky[incoming * 3 + channel]
							for emitter in brick.emitter_count:
								var offset: int = emitter * 6 + channel
								value += brick.operators[row + 36 + offset] * emission[offset] \
									+ brick.operators[row + 39 + offset] * emission[offset + 3]
							if not is_finite(value) or absf(value) > 3.402823466e38: return {}
							response.append(value)
	return {"volume_probe_preview": true, "current_available": true,
		"source_kind": "prepared_brick", "status": "Resident prepared brick core cells (not original source probes)",
		"positions": positions, "spacings": spacings, "lods": lods, "response_sh": response,
		"layout_key": "prepared-bricks:" + str(hash([positions, spacings, lods]))}

static func _finite(values: PackedFloat32Array) -> bool:
	for value in values:
		if not is_finite(value): return false
	return true
