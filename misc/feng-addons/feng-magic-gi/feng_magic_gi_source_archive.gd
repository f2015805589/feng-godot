@tool
extends RefCounted
## Lossless post-preparation source packing. This does not reduce bake rays or
## change the resident CLV operators, source positions, or valid probe count.
## V2 stores only valid source payloads, with an explicit logical-grid mapping.
const Chunk = preload("feng_magic_gi_volume_source_chunk.gd")

static func pack(source: Chunk, cancelled: Callable = Callable()) -> Dictionary:
	if source == null or not source.is_valid() or not source.has_preinterpolated_clv():
		return {"ok": false, "error": "source_pack_requires_valid_prepared_source"}
	if cancelled.is_valid() and bool(cancelled.call()):
		return {"ok": false, "error": "cancelled"}
	if source.format_version == Chunk.FORMAT_VERSION_PACKED:
		return {"ok": true, "chunk": source, "already_packed": true}
	var count := source.cell_count()
	var valid_count := source.valid_cell_count()
	var removed_payload_bytes := (count - valid_count) * (243 + 81 + 54 * source.emitter_count \
			+ Chunk.MOMENT_TEXELS_PER_CELL * Chunk.MOMENT_CHANNELS) * 4
	var mapping_bytes := count * 4
	if removed_payload_bytes <= mapping_bytes:
		return {"ok": true, "chunk": source, "already_packed": false, "stats": {
			"method": "dense_grid_v1", "reason": "no_savings",
			"logical_slots": count, "stored_probes": count,
			"removed_invalid_payloads": 0, "removed_valid_probes": 0,
			"cpu_bytes_before": source.estimated_cpu_resident_bytes(),
			"cpu_bytes_after": source.estimated_cpu_resident_bytes(),
			"prepared_output_changed": false, "bake_rays_saved": 0,
		}}
	var packed := source.duplicate(false) as Chunk
	var indices := PackedInt32Array()
	indices.resize(count)
	indices.fill(-1)
	var kept := PackedInt32Array()
	for logical in count:
		if source.cell_is_valid(logical):
			indices[logical] = kept.size()
			kept.append(logical)
	var transfer := PackedFloat32Array()
	var sky := PackedFloat32Array()
	var moments := PackedFloat32Array()
	var emission := PackedFloat32Array()
	var stride := Chunk.MOMENT_TEXELS_PER_CELL * Chunk.MOMENT_CHANNELS
	for stored in kept.size():
		if stored % 128 == 0 and cancelled.is_valid() and bool(cancelled.call()):
			return {"ok": false, "error": "cancelled"}
		var logical := kept[stored]
		transfer.append_array(source.transfer.slice(logical * 243, (logical + 1) * 243))
		sky.append_array(source.sky.slice(logical * 81, (logical + 1) * 81))
		moments.append_array(source.receiver_visibility_moments.slice(logical * stride, (logical + 1) * stride))
	for emitter in source.emitter_count:
		for stored in kept.size():
			if stored % 128 == 0 and cancelled.is_valid() and bool(cancelled.call()):
				return {"ok": false, "error": "cancelled"}
			var start := (emitter * count + kept[stored]) * 54
			emission.append_array(source.emission.slice(start, start + 54))
	packed.source_storage_count = kept.size()
	packed.source_storage_indices = indices
	packed.transfer = transfer
	packed.sky = sky
	packed.emission = emission
	packed.receiver_visibility_moments = moments
	packed.format_version = Chunk.FORMAT_VERSION_PACKED
	packed.source_archive_stats = {
		"method": "lossless_invalid_slot_pack_v2",
		"logical_slots": count, "stored_probes": kept.size(),
		"removed_invalid_payloads": count - kept.size(),
		"removed_valid_probes": 0,
		"cpu_bytes_before": source.estimated_cpu_resident_bytes(),
		"cpu_bytes_after": packed.estimated_cpu_resident_bytes(),
		"prepared_output_changed": false,
		"bake_rays_saved": 0,
	}
	if cancelled.is_valid() and bool(cancelled.call()):
		return {"ok": false, "error": "cancelled"}
	if not packed.is_valid():
		return {"ok": false, "error": "packed_source_validation_failed"}
	return {"ok": true, "chunk": packed, "already_packed": false,
		"stats": packed.source_archive_stats}
