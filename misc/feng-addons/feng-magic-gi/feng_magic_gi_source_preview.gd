@tool
extends RefCounted
## Debug-only relighting of immutable free-space source probes. Safe to invoke
## from a worker: no scene traversal, Resource loading, RenderingServer, or RD.
## The result contains raw signed incident-radiance SH, with no convolution,
## strength, exposure, material response, or clamping of individual coefficients.

const Chunk = preload("feng_magic_gi_volume_source_chunk.gd")

## `cancelled`, when provided, must itself be safe to call from the worker.
## Cancellation returns an empty dictionary, never a partially published result.
static func build(chunk: Chunk, lighting: PackedFloat32Array,
		sky_lighting: PackedFloat32Array, emission_sources: PackedFloat32Array,
		cancelled: Callable = Callable()) -> Dictionary:
	if cancelled.is_valid() and bool(cancelled.call()):
		return {}
	var result := {
		"volume_probe_preview": true,
		"positions": PackedVector3Array(),
		"spacings": PackedFloat32Array(),
		"lods": PackedInt32Array(),
		"response_sh": PackedFloat32Array(),
		"source_indices": PackedInt32Array(),
		"current_available": false,
		"layout_key": "",
	}
	if chunk == null:
		return result
	var source_count := chunk.cell_count()
	var storage_count := chunk.storage_probe_count()
	if source_count <= 0 or chunk.probe_count != source_count \
			or chunk.validity.size() != source_count \
			or chunk.relocation_offset_m.size() != source_count \
			or not chunk.origin_world.is_finite() \
			or not is_finite(chunk.spacing_m) or chunk.spacing_m <= 0.0:
		return result
	var positions := PackedVector3Array()
	var indices := PackedInt32Array()
	for source in source_count:
		if source % 256 == 0 and cancelled.is_valid() and bool(cancelled.call()):
			return {}
		if not chunk.cell_is_valid(source):
			continue
		if chunk.storage_index(source) < 0 or chunk.storage_index(source) >= storage_count:
			return result
		var position := chunk.cell_position(source, true)
		if not position.is_finite():
			return result
		positions.append(position)
		indices.append(source)
	var spacings := PackedFloat32Array()
	spacings.resize(positions.size())
	spacings.fill(chunk.spacing_m)
	var lods := PackedInt32Array()
	lods.resize(positions.size())
	lods.fill(-1) # Original source probes are not cells of a resident CLV LOD.
	var response := PackedFloat32Array()
	response.resize(positions.size() * 27)
	result["positions"] = positions
	result["spacings"] = spacings
	result["lods"] = lods
	result["source_indices"] = indices
	result["response_sh"] = response
	result["layout_key"] = "source:%d:%d" % [chunk.get_instance_id(),
		hash([positions, indices, chunk.spacing_m])]
	if chunk.emitter_count < 0 or chunk.emitter_count > 32 \
			or storage_count <= 0 \
			or chunk.transfer.size() != storage_count * 243 \
			or chunk.sky.size() != storage_count * 81 \
			or chunk.emission.size() != chunk.emitter_count * storage_count * 54 \
			or lighting.size() != 27 or sky_lighting.size() != 27 \
			or emission_sources.size() != chunk.emitter_count * 6 \
			or not _finite(lighting) or not _finite(sky_lighting) \
			or not _finite(emission_sources):
		return result
	# Same coefficient-major indexing as magic_gi_dynamic_volume_relight.glsl:
	# [source][outgoing9][incoming9][RGB], achromatic primary-sky matrix, and
	# [emitter][source][outgoing9][base RGB, textured RGB]. Keep all families signed
	# until the consumer evaluates the complete directional response.
	for probe in indices.size():
		if probe % 32 == 0 and cancelled.is_valid() and bool(cancelled.call()):
			return {}
		var source := chunk.storage_index(indices[probe])
		for outgoing in 9:
			var red := 0.0
			var green := 0.0
			var blue := 0.0
			var transfer_row := source * 243 + outgoing * 27
			var sky_row := source * 81 + outgoing * 9
			for incoming in 9:
				var light_index := incoming * 3
				var transfer_index := transfer_row + light_index
				var sky := chunk.sky[sky_row + incoming]
				red += chunk.transfer[transfer_index] * lighting[light_index] \
					+ sky * sky_lighting[light_index]
				green += chunk.transfer[transfer_index + 1] * lighting[light_index + 1] \
					+ sky * sky_lighting[light_index + 1]
				blue += chunk.transfer[transfer_index + 2] * lighting[light_index + 2] \
					+ sky * sky_lighting[light_index + 2]
			for emitter in chunk.emitter_count:
				var emission_index := (emitter * storage_count + source) * 54 + outgoing * 6
				var source_index := emitter * 6
				red += chunk.emission[emission_index] * emission_sources[source_index] \
					+ chunk.emission[emission_index + 3] * emission_sources[source_index + 3]
				green += chunk.emission[emission_index + 1] * emission_sources[source_index + 1] \
					+ chunk.emission[emission_index + 4] * emission_sources[source_index + 4]
				blue += chunk.emission[emission_index + 2] * emission_sources[source_index + 2] \
					+ chunk.emission[emission_index + 5] * emission_sources[source_index + 5]
			if not is_finite(red) or not is_finite(green) or not is_finite(blue) \
					or maxf(absf(red), maxf(absf(green), absf(blue))) > 3.402823466e38:
				response.fill(0.0)
				result["response_sh"] = response
				return result
			var output := probe * 27 + outgoing * 3
			response[output] = red
			response[output + 1] = green
			response[output + 2] = blue
	result["response_sh"] = response
	result["current_available"] = true
	return result

static func _finite(values: PackedFloat32Array) -> bool:
	for value in values:
		if not is_finite(value):
			return false
	return true
