extends SceneTree

const BakedCache = preload("../passes/magic_gi_baked_sh_clv_cache.gd")
var checks := 0
var failures := 0

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)

func _initialize() -> void:
	call_deferred("run")

func reference_jobs(cache: RefCounted, cells: Array[Vector4i], spacing: float,
		clear_only: bool) -> PackedByteArray:
	var bytes := PackedByteArray()
	for cell in cells:
		var step := spacing * float(1 << cell.w)
		var center := (Vector3(cell.x, cell.y, cell.z) + Vector3.ONE * 0.5) * step
		bytes.append_array(PackedFloat32Array([center.x, center.y, center.z,
				-step if clear_only else step]).to_byte_array())
		bytes.append_array(PackedInt32Array([cell.x, cell.y, cell.z, cell.w]).to_byte_array())
		var record_index := int(cache._boundary_tensor_record_index_by_cell.get(cell, 0)) \
				if not clear_only else 0
		bytes.append_array(PackedInt32Array([record_index, 0, 0, 0]).to_byte_array())
	return bytes

func reference_identity(cache: RefCounted, signature: String) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(signature.to_utf8_buffer())
	context.update(PackedInt32Array([cache._field_format_tag]).to_byte_array())
	var codec: Vector4 = cache._codec
	context.update(PackedFloat32Array([codec.x, codec.y, codec.z, codec.w]).to_byte_array())
	return context.finish().hex_encode()

func benchmark_pack(cache: RefCounted, cells: Array[Vector4i], optimized: bool) -> int:
	var start := Time.get_ticks_usec()
	for _iteration in 384:
		if optimized:
			cache._pack_job_records(cells, 0.25, false)
		else:
			reference_jobs(cache, cells, 0.25, false)
	return Time.get_ticks_usec() - start

func run() -> void:
	check(RenderingServer.get_rendering_device() == null,
		"CPU update tests must not initialize a GPU device")
	var cache: RefCounted = BakedCache.new()
	cache.resolution = 32
	var cells: Array[Vector4i] = []
	for level in 3:
		for coordinate in [-2147483648, -1048576, -17, -1, 0, 1, 32, 1048576, 2147483647]:
			cells.append(Vector4i(coordinate, -13, 23, level))
	cache._boundary_tensor_record_index_by_cell[cells[0]] = 6258
	cache._boundary_tensor_record_index_by_cell[cells[13]] = 1
	var empty: Array[Vector4i] = []
	check(cache._pack_job_records(empty, 0.25, false).is_empty(), "empty batches stay empty")
	for spacing in [0.001, 0.25, 17.5]:
		for clear_only in [false, true]:
			var packed: PackedByteArray = cache._pack_job_records(cells, spacing, clear_only)
			check(packed == reference_jobs(cache, cells, spacing, clear_only),
				"packing preserves every byte, sign, padding and boundary index: %s %s" % [spacing, clear_only])

	var original_signature := "test-payload-a"
	var original_digest: String = cache._boundary_tensor_cache_identity(original_signature)
	check(original_digest == reference_identity(cache, original_signature), "identity is unchanged SHA256")
	check(cache._boundary_tensor_cache_identity(original_signature) == original_digest,
		"reusing an identity is byte-exact")
	cache._codec = Vector4(2.0, 0.5, 16.0, 1.0)
	cache._field_format_tag = 16
	check(cache._boundary_tensor_cache_identity(original_signature) == reference_identity(cache, original_signature)
			and cache._boundary_tensor_cache_identity(original_signature) != original_digest,
		"changing scale and format invalidates the identity")
	cache._field_format_tag = 32
	check(cache._boundary_tensor_cache_identity(original_signature) == reference_identity(cache, original_signature),
		"changing only format invalidates the identity")
	check(cache._boundary_tensor_cache_identity("test-payload-b") == reference_identity(cache, "test-payload-b"),
		"changing only source signature invalidates the identity")
	cache._codec = BakedCache.DEFAULT_CODEC_R32
	check(cache._boundary_tensor_cache_identity(original_signature) == original_digest,
		"switching contexts back restores the exact old identity")

	cache.queue_updates(Vector3.ZERO, 0.25, 7)
	check(not cache._parameters_are_current(0.25, 7, Vector3.ZERO), "unsubmitted parameters are dirty")
	cache._record_parameter_upload(0.25, 7, Vector3.ZERO)
	check(cache._parameters_are_current(0.25, 7, Vector3.ZERO), "unchanged submitted parameters are reusable")
	check(not cache._parameters_are_current(0.5, 7, Vector3.ZERO), "spacing changes require an upload")
	check(not cache._parameters_are_current(0.25, 8, Vector3.ZERO), "geometry changes require an upload")
	check(not cache._parameters_are_current(0.25, 7, Vector3(0.001, 0, 0)),
		"camera motion inside the same CLV cell requires an upload")
	cache.resolution = 24
	check(not cache._parameters_are_current(0.25, 7, Vector3.ZERO), "resolution changes require an upload")
	cache.resolution = 32
	cache._codec = Vector4(2.0, 0.5, 16.0, 1.0)
	check(not cache._parameters_are_current(0.25, 7, Vector3.ZERO), "codec changes require an upload")
	cache._codec = BakedCache.DEFAULT_CODEC_R32
	cache._origins[0].x += 1
	check(not cache._parameters_are_current(0.25, 7, Vector3.ZERO),
		"origin snapshot is independent and scroll invalidates the upload")
	check(cache._parameter_upload_count == 1, "dirty checks alone never publish a successful upload")
	cache._record_parameter_upload(0.25, 7, Vector3.ZERO)
	check(cache._parameters_are_current(0.25, 7, Vector3.ZERO) and cache._parameter_upload_count == 2,
		"recording a successful retry restores the clean state")
	cache._uploaded_parameter_origins.clear()
	check(not cache._parameters_are_current(0.25, 7, Vector3.ZERO),
		"recreating the parameter buffer invalidates prior uploaded state")

	var batch: Array[Vector4i] = []
	for index in 256:
		batch.append(Vector4i(index % 32 - 16, index / 32 - 16, -8, index % 3))
	var old_usec := benchmark_pack(cache, batch, false)
	var new_usec := benchmark_pack(cache, batch, true)
	new_usec += benchmark_pack(cache, batch, true)
	old_usec += benchmark_pack(cache, batch, false)
	var identity_start := Time.get_ticks_usec()
	for _iteration in 10000:
		reference_identity(cache, original_signature)
	var old_identity_usec := Time.get_ticks_usec() - identity_start
	identity_start = Time.get_ticks_usec()
	for _iteration in 10000:
		cache._boundary_tensor_cache_identity(original_signature)
	var new_identity_usec := Time.get_ticks_usec() - identity_start
	print("MAGICDAWN_BAKED_CLV_CPU_UPDATES checks=%d failures=%d packing_old_usec=%d packing_new_usec=%d identity_old_usec=%d identity_new_usec=%d" % [
		checks, failures, old_usec, new_usec, old_identity_usec, new_identity_usec])
	quit(1 if failures > 0 else 0)
