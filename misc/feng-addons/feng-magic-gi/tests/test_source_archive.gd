extends SceneTree
## Lossless source v1 -> v2 packing and malformed-index guards, CPU only.
const Chunk = preload("../feng_magic_gi_volume_source_chunk.gd")
const Archive = preload("../feng_magic_gi_source_archive.gd")
const Builder = preload("../feng_magic_gi_clv_transfer_builder.gd")
var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)

func run() -> void:
	var source := _fixture()
	check(source.format_version == 1 and source.is_valid(), "dense default remains readable v1")
	var result := Archive.pack(source)
	check(bool(result.get("ok", false)), "valid prepared source can be losslessly packed")
	if not bool(result.get("ok", false)):
		_finish()
		return
	var packed: Chunk = result.chunk
	check(packed.format_version == 2 and packed.is_valid(), "packed v2 passes deep validation")
	check(source.format_version == 1 and source.transfer.size() == 8 * 243,
			"packing does not mutate the input or its dense arrays")
	check(packed.probe_count == 8 and packed.cell_count() == 8 \
			and packed.storage_probe_count() == 4 and packed.stored_valid_cell_count() == 4,
			"logical grid capacity and actual stored source count remain distinct")
	check(packed.validity == source.validity and packed.relocation_offset_m == source.relocation_offset_m,
			"all physical source classifications and relocation offsets are preserved")
	check(packed.clv_prepared_operators.to_byte_array() == source.clv_prepared_operators.to_byte_array() \
			and packed.clv_prepared_validity == source.clv_prepared_validity \
			and packed.clv_prepared_dimensions == source.clv_prepared_dimensions \
			and packed.clv_prepared_offsets == source.clv_prepared_offsets \
			and packed.clv_preparation_signature == source.clv_preparation_signature,
			"runtime prepared transport, validity, layout and signature stay byte-identical")
	var expected_index := 0
	for logical in 8:
		check(packed.cell_is_valid(logical) == source.cell_is_valid(logical),
				"physical validity is unchanged at logical cell %d" % logical)
		if not source.cell_is_valid(logical):
			check(packed.storage_index(logical) == -1 and not packed.cell_has_stored_sample(logical),
					"invalid cell %d has no stored payload" % logical)
			continue
		var index := packed.storage_index(logical)
		check(index == expected_index and packed.cell_has_stored_sample(logical),
				"retained source has canonical one-to-one mapping")
		check(packed.cell_position(logical) == source.cell_position(logical),
				"source marker remains at its original relocated world position")
		for family in ["transfer", "sky", "receiver_visibility_moments"]:
			var stride := 243 if family == "transfer" else (81 if family == "sky" else 128)
			var original: PackedFloat32Array = source.get(family)
			var stored: PackedFloat32Array = packed.get(family)
			check(stored.slice(index * stride, (index + 1) * stride).to_byte_array() \
					== original.slice(logical * stride, (logical + 1) * stride).to_byte_array(),
					"all signed %s coefficients are byte-identical for retained source" % family)
		for emitter in 2:
			check(packed.emission.slice((emitter * 4 + index) * 54, (emitter * 4 + index + 1) * 54).to_byte_array() \
					== source.emission.slice((emitter * 8 + logical) * 54, (emitter * 8 + logical + 1) * 54).to_byte_array(),
					"emitter-major compact stride preserves both base/textured transport")
		expected_index += 1
	check(packed.storage_index(-1) == -1 and packed.storage_index(8) == -1,
			"invalid logical indices never expose a payload")
	var sum_bytes := packed.transfer.size() * 4 + packed.sky.size() * 4 \
			+ packed.emission.size() * 4 + packed.receiver_visibility_moments.size() * 4 \
			+ packed.validity.size() + packed.relocation_offset_m.size() * 12 \
			+ packed.source_storage_indices.size() * 4 + packed.clv_prepared_operators.size() * 4 \
			+ packed.clv_prepared_validity.size() \
			+ (packed.clv_prepared_dimensions.size() + packed.clv_prepared_offsets.size()) * 4
	check(packed.estimated_payload_bytes() == sum_bytes \
			and packed.estimated_cpu_resident_bytes() == sum_bytes + 2 * 6 * 4,
			"payload/residency estimates count actual compact arrays and emitter values")
	check(packed.estimated_gpu_payload_bytes() == source.estimated_gpu_payload_bytes(),
			"lossless source archive does not claim to reduce unchanged prepared GPU operators")
	check(packed.estimated_payload_bytes() < source.estimated_payload_bytes(),
			"removed invalid payloads save CPU memory after accounting for mapping")
	check(Archive.pack(packed).chunk == packed, "packing an existing v2 source is idempotent")
	check(not bool(Archive.pack(source, func() -> bool: return true).ok),
			"cancelled archive does not publish a replacement")
	var full_source := _fixture()
	for logical in full_source.cell_count():
		if full_source.validity[logical] == 0:
			full_source.validity[logical] = 1
			for texel in 64:
				full_source.receiver_visibility_moments[logical * 128 + texel * 2] = 2.0
				full_source.receiver_visibility_moments[logical * 128 + texel * 2 + 1] = 4.0
	check(full_source.is_valid(), "all-valid dense source fixture is valid")
	var full_result := Archive.pack(full_source)
	check(bool(full_result.get("ok", false)) and full_result.chunk == full_source \
			and full_source.format_version == 1 and full_source.source_storage_indices.is_empty(),
			"all-valid grid retains dense storage instead of allocating an unnecessary mapping")
	check(full_result.stats.reason == "no_savings" \
			and full_result.stats.cpu_bytes_before == full_result.stats.cpu_bytes_after,
			"no-savings archive result reports unchanged CPU size")
	for mutation in ["duplicate", "out_of_bounds", "valid_missing", "invalid_stored",
			"count", "truncated", "nan", "no_prepared"]:
		var malformed := packed.duplicate(true) as Chunk
		match mutation:
			"duplicate": malformed.source_storage_indices[2] = 0
			"out_of_bounds": malformed.source_storage_indices[2] = 400
			"valid_missing": malformed.source_storage_indices[2] = -1
			"invalid_stored": malformed.source_storage_indices[1] = 0
			"count": malformed.source_storage_count = 3
			"truncated": malformed.sky.resize(malformed.sky.size() - 1)
			"nan": malformed.transfer[0] = NAN
			"no_prepared": malformed.clv_preparation_revision = 0
		check(not malformed.is_valid(), mutation + " is rejected before unsafe payload indexing")
	var rejected: Dictionary = await Builder.new().prepare_async(packed, null)
	check(not bool(rejected.get("ok", false)) \
			and String(rejected.get("error", "")).contains("original_dense_bake"),
			"packed archives never silently rebuild geometry-conditioned prepared transport")
	var path := "res://source_archive_roundtrip.res"
	check(ResourceSaver.save(packed, path, ResourceSaver.FLAG_COMPRESS) == OK, "packed resource saves")
	var restored := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as Chunk
	check(restored != null and restored.is_valid() and restored.format_version == 2 \
			and restored.transfer.to_byte_array() == packed.transfer.to_byte_array() \
			and restored.clv_prepared_operators.to_byte_array() == packed.clv_prepared_operators.to_byte_array(),
			"saved v2 reload retains source and prepared coefficients exactly")
	_finish()

func _fixture() -> Chunk:
	var source := Chunk.new()
	source.allocate(Vector3i(2, 2, 2), PackedStringArray(["a", "b"]))
	source.source_size_m = Vector3.ONE * 0.5
	source.source_transform_world = Transform3D(Basis.IDENTITY, Vector3.ONE * 0.25)
	source.source_bounds_world = AABB(Vector3.ZERO, source.source_size_m)
	source.domain_bounds_world = source.source_bounds_world
	source.origin_world = Vector3.ONE * 0.125
	source.trace_distance_m = 8.0
	source.bake_samples = 1
	source.bake_bounces = 1
	source.moment_rays = 256
	source.maximum_relocation_m = 0.05
	source.validity = PackedByteArray([1, 0, 2, 0, 1, 0, 1, 0])
	source.relocation_offset_m[2] = Vector3(0.01, 0, 0)
	for logical in 8:
		if not source.cell_is_valid(logical): continue
		for i in 243: source.transfer[logical * 243 + i] = float(logical + i - 100) * 0.01
		for i in 81: source.sky[logical * 81 + i] = float(logical - i) * 0.02
		for emitter in 2:
			for i in 54:
				source.emission[(emitter * 8 + logical) * 54 + i] = float(emitter + logical - i) * 0.03
		for texel in 64:
			source.receiver_visibility_moments[logical * 128 + texel * 2] = 2
			source.receiver_visibility_moments[logical * 128 + texel * 2 + 1] = 4
	source.directional_source_signature = source.make_directional_source_signature()
	source.clv_preparation_revision = 1
	source.clv_preparation_signature = source.directional_source_signature
	source.clv_prepared_dimensions = PackedInt32Array([2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1])
	source.clv_prepared_offsets = PackedInt32Array([0, 8, 9, 10])
	source.clv_prepared_validity.resize(11)
	source.clv_prepared_validity.fill(1)
	source.clv_prepared_operators.resize(11 * 9 * 48)
	for i in source.clv_prepared_operators.size():
		source.clv_prepared_operators[i] = float(i % 19 - 10) * 0.0001
	return source

func _finish() -> void:
	print("MAGIC_GI_SOURCE_ARCHIVE checks=", checks, " failures=", failures)
	quit(1 if failures else 0)
