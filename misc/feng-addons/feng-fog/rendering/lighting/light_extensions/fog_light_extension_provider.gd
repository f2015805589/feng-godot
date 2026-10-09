class_name FFogLightExtensionProvider
extends RefCounted
## Builds set-3 per-light records and a provider-owned GPU cookie array.
## Source Texture2D resources are resolved to borrowed RD RIDs on the main
## thread by FFogLightExtensionRegistry; this provider receives only values/RIDs.

const Layout = preload("fog_light_extension_layout.gd")
const SHADER_PATH := "res://addons/feng-fog/rendering/lighting/light_extensions/fog_light_function_resample.glslinc"
const RESAMPLE_EDGE := Layout.COOKIE_SIZE
const RESAMPLE_GROUP_EDGE := 8
const MIN_SOURCE_EDGE := 1

var _rd: RenderingDevice
var _records_buffer := RID()
var _records_capacity_bytes := 0
var _header_buffer := RID()
var _sampler := RID()
var _resample_shader := RID()
var _resample_pipeline := RID()
var _cookie_array := RID()
var _neutral_cookie_array := RID()
var _cookie_source_key: Array = []
var _cookie_array_generation := 0
var _last_error := ""


## Rendering-side call. The snapshot itself must have been created on the main
## thread. Returned RIDs belong to this provider and are borrowed until the next
## update_frame_inputs()/release(); the source texture RIDs are never freed here.
func update_frame_inputs(p_snapshot: Dictionary, p_rd: RenderingDevice) -> Dictionary:
	_last_error = ""
	if not bool(p_snapshot.get("valid", false)) or int(p_snapshot.get("abi_version", 0)) != Layout.ABI_VERSION:
		return _invalid_result("Light extension snapshot is not valid ABI v1.")
	if p_rd == null or p_rd != RenderingServer.get_rendering_device():
		return _invalid_result("Light extension resources must use the RenderingServer main RenderingDevice.")
	if not _ensure_device(p_rd):
		return _invalid_result("Could not attach the light extension provider to the main RenderingDevice.")
	if not _ensure_cookie_sampler(p_rd):
		return _invalid_result("Could not create the light extension cookie sampler.")
	var rows: Variant = p_snapshot.get("rows")
	if not rows is Array or int(p_snapshot.get("native_light_count", -1)) != rows.size():
		return _invalid_result("Light extension row count does not match the native light list.")
	var sources := _collect_cookie_sources(rows, p_rd)
	var cookie_error := ""
	if int(sources.get("invalid_source_count", 0)) > 0:
		cookie_error = "%d cookie source(s) were invalid and use a neutral white multiplier." % int(sources["invalid_source_count"])
	if int(sources.get("unsupported_count", 0)) > 0:
		cookie_error = str(sources.get("reason", "Some cookie sources could not be used."))
		sources["items"] = []
		sources["row_keys"] = PackedStringArray()
		sources["source_key"] = []
	var cookie_items: Array = sources.get("items", [])
	var source_key: Array = sources.get("source_key", [])
	var cookie_cache_hit := source_key == _cookie_source_key
	var texture_ready := _ensure_cookie_array(p_rd, cookie_items, source_key)
	if not texture_ready:
		cookie_error = _last_error
		cookie_items = []
		sources["row_keys"] = PackedStringArray()
		_ensure_neutral_cookie_array(p_rd)
		var neutral_result := _ensure_cookie_array(p_rd, [], [])
		if not bool(neutral_result):
			return _invalid_result("No valid neutral cookie texture could be created: " + cookie_error)
	var row_keys: PackedStringArray = sources.get("row_keys", PackedStringArray())
	var key_to_layer: Dictionary = {}
	for index in cookie_items.size():
		key_to_layer[cookie_items[index].key] = index
	var records := PackedByteArray()
	for index in rows.size():
		var row: Dictionary = rows[index]
		var cookie_key := row_keys[index] if index < row_keys.size() else ""
		var layer := int(key_to_layer.get(cookie_key, -1))
		var record := Layout.pack_record(row, layer)
		if record.size() != Layout.RECORD_BYTES:
			return _invalid_result("A packed extension record has an invalid byte size.")
		records.append_array(record)
	if records.is_empty():
		records = Layout.neutral_record()
	var generation := int(p_snapshot.get("frame_generation", 0))
	var header := Layout.pack_header(rows.size(), cookie_items.size(), generation)
	if header.size() != Layout.HEADER_BYTES:
		return _invalid_result("A packed extension header has an invalid byte size.")
	if not _upload_records(p_rd, records) or not _upload_header(p_rd, header):
		return _invalid_result("Could not upload the per-frame light extension buffers.")
	if not _records_buffer.is_valid() or not _header_buffer.is_valid() \
			or not _cookie_array.is_valid() or not p_rd.texture_is_valid(_cookie_array) \
			or not _sampler.is_valid():
		return _invalid_result("Every extension result requires valid buffers, cookie texture, and sampler RIDs.")
	var native_counts := PackedInt32Array([0, 0, 0, 0])
	for row_value in rows:
		var kind := int((row_value as Dictionary).get("native_kind", -1))
		if kind < 0 or kind >= native_counts.size():
			return _invalid_result("A row has an invalid native light kind.")
		native_counts[kind] += 1
	var record_offsets := {
		"omni": 0,
		"spot": native_counts[Layout.KIND_OMNI],
		"area": native_counts[Layout.KIND_OMNI] + native_counts[Layout.KIND_SPOT],
		"directional": native_counts[Layout.KIND_OMNI] + native_counts[Layout.KIND_SPOT] + native_counts[Layout.KIND_AREA],
	}
	return {
		"valid": true,
		"abi_version": Layout.ABI_VERSION,
		"descriptor_set": Layout.FRAME_SET_INDEX,
		"record_binding": Layout.RECORDS_BINDING,
		"cookie_binding": Layout.COOKIE_TEXTURE_BINDING,
		"header_binding": Layout.HEADER_BINDING,
		"record_stride_bytes": Layout.RECORD_BYTES,
		"record_count": rows.size(),
		"record_order": Layout.KIND_NAMES.duplicate(),
		"native_type_counts": native_counts,
		"record_offsets": record_offsets,
		"records_buffer": _records_buffer,
		"records_buffer_capacity_bytes": _records_capacity_bytes,
		"cookie_texture_array": _cookie_array,
		"cookie_sampler": _sampler,
		"cookie_layer_count": cookie_items.size(),
		"cookie_array_generation": _cookie_array_generation,
		"header_buffer": _header_buffer,
		"frame_generation": generation,
		"registry_generation": int(p_snapshot.get("registry_generation", 0)),
		"cookie_cache_hit": cookie_cache_hit,
		"cookie_status": "ready" if cookie_error.is_empty() else "neutral_fallback",
		"cookie_diagnostic": cookie_error,
		"resource_ownership": "provider_owned_outputs_borrowed_until_next_update",
		"source_texture_ownership": "borrowed_RD_RIDs_never_freed",
		"last_error": "",
	}


func get_last_error() -> String:
	return _last_error


func release() -> void:
	var rd := _rd
	var owned := take_owned_rids()
	if rd != null:
		for rid in owned:
			_free_rid(rd, rid)
	_last_error = ""


func get_owned_rids() -> Array[RID]:
	return _collect_owned_rids(false)


func take_owned_rids() -> Array[RID]:
	return _collect_owned_rids(true)


func _collect_owned_rids(p_clear: bool) -> Array[RID]:
	var result: Array[RID] = []
	var seen: Dictionary = {}
	for rid in [_records_buffer, _header_buffer, _sampler, _resample_pipeline,
			_resample_shader, _cookie_array, _neutral_cookie_array]:
		if rid.is_valid() and not seen.has(rid):
			seen[rid] = true
			result.append(rid)
	if p_clear:
		_rd = null
		_records_buffer = RID()
		_records_capacity_bytes = 0
		_header_buffer = RID()
		_sampler = RID()
		_resample_shader = RID()
		_resample_pipeline = RID()
		_cookie_array = RID()
		_neutral_cookie_array = RID()
		_cookie_source_key.clear()
		_cookie_array_generation = 0
		_last_error = ""
	return result


## Pure validation used by CPU tests and by source collection.
static func source_identity_is_valid(p_resource_id: int, p_texture_rid: RID) -> bool:
	return Layout.is_resource_identity_valid(p_resource_id) and p_texture_rid.is_valid()


func _ensure_device(p_rd: RenderingDevice) -> bool:
	if _rd != null and _rd != p_rd:
		release()
	_rd = p_rd
	return true


func _collect_cookie_sources(p_rows: Array, p_rd: RenderingDevice) -> Dictionary:
	var items: Array[Dictionary] = []
	var key_to_index: Dictionary = {}
	var row_keys := PackedStringArray()
	var source_key: Array = []
	var invalid_source_count := 0
	for row_value in p_rows:
		var row: Dictionary = row_value
		var strength := float(row.get("cookie_strength", 0.0))
		if not is_finite(strength) or strength <= 0.0:
			row_keys.append("")
			continue
		var resource_id := int(row.get("cookie_texture_resource_id", 0))
		var texture: Variant = row.get("cookie_texture_rd_rid", RID())
		if not texture is RID or not source_identity_is_valid(resource_id, texture) \
				or not p_rd.texture_is_valid(texture):
			invalid_source_count += 1
			row_keys.append("")
			continue
		var format: RDTextureFormat = p_rd.texture_get_format(texture)
		if format == null or format.texture_type != RenderingDevice.TEXTURE_TYPE_2D \
				or format.width < MIN_SOURCE_EDGE or format.height < MIN_SOURCE_EDGE \
				or (format.usage_bits & RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT) == 0:
			invalid_source_count += 1
			row_keys.append("")
			continue
		var revision := int(row.get("cookie_texture_revision", 0))
		if revision <= 0:
			invalid_source_count += 1
			row_keys.append("")
			continue
		var srgb := bool(row.get("cookie_srgb", true))
		var key := "%d:%d:%d:%d:%d:%d:%d" % [
			texture.get_id(), resource_id, revision, 1 if srgb else 0,
			format.width, format.height, format.format,
		]
		if not key_to_index.has(key):
			key_to_index[key] = items.size()
			items.append({
				"key": key,
				"texture": texture,
				"source_width": format.width,
				"source_height": format.height,
				"srgb": srgb,
			})
			source_key.append(key)
		row_keys.append(key)
	var maximum_layers := p_rd.limit_get(RenderingDevice.LIMIT_MAX_TEXTURE_ARRAY_LAYERS)
	var unsupported_count := 0
	var reason := ""
	if items.size() > maximum_layers:
		unsupported_count = items.size()
		reason = "Cookie layer count %d exceeds this device limit %d; all cookies use the neutral fallback." % [
			items.size(), maximum_layers]
	return {
		"items": items,
		"row_keys": row_keys,
		"source_key": source_key,
		"unsupported_count": unsupported_count,
		"invalid_source_count": invalid_source_count,
		"reason": reason,
	}


func _ensure_cookie_array(p_rd: RenderingDevice, p_items: Array,
		p_source_key: Array) -> bool:
	if not requires_cookie_resampling(p_items.size()):
		if not _ensure_neutral_cookie_array(p_rd):
			return false
		if _cookie_array.is_valid() and _cookie_array != _neutral_cookie_array:
			_free_rid(p_rd, _cookie_array)
		_cookie_array = _neutral_cookie_array
		_cookie_source_key = []
		return true
	if p_source_key == _cookie_source_key and _cookie_array.is_valid() \
			and _cookie_array != _neutral_cookie_array and p_rd.texture_is_valid(_cookie_array):
		return true
	if not _ensure_resample_pipeline(p_rd):
		return false
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	format.width = RESAMPLE_EDGE
	format.height = RESAMPLE_EDGE
	format.depth = 1
	format.array_layers = p_items.size()
	format.mipmaps = 1
	format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
			| RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	format.is_discardable = false
	if not p_rd.texture_is_format_supported_for_usage(format.format, format.usage_bits):
		_last_error = "RGBA16F storage and sampling are unsupported for the cookie texture array."
		return false
	var candidate := p_rd.texture_create(format, RDTextureView.new())
	if not candidate.is_valid():
		_last_error = "Could not allocate the cookie texture array."
		return false
	var prepared := _prepare_resample_sets(p_rd, candidate, p_items)
	if not bool(prepared.get("valid", false)):
		_free_rid(p_rd, candidate)
		_last_error = str(prepared.get("reason", "Could not bind cookie source textures."))
		return false
	var compute_list := p_rd.compute_list_begin()
	if compute_list == RenderingDevice.INVALID_ID:
		_cleanup_resample_sets(p_rd, prepared)
		_free_rid(p_rd, candidate)
		_last_error = "Could not begin cookie texture resampling."
		return false
	p_rd.compute_list_bind_compute_pipeline(compute_list, _resample_pipeline)
	var sets: Array = prepared["sets"]
	for set_index in sets.size():
		p_rd.compute_list_bind_uniform_set(compute_list, sets[set_index], 0)
		p_rd.compute_list_dispatch(compute_list, RESAMPLE_EDGE / RESAMPLE_GROUP_EDGE,
				RESAMPLE_EDGE / RESAMPLE_GROUP_EDGE, 1)
		if set_index + 1 < sets.size():
			p_rd.compute_list_add_barrier(compute_list)
	p_rd.compute_list_end()
	_cleanup_resample_sets(p_rd, prepared)
	if _cookie_array.is_valid() and _cookie_array != _neutral_cookie_array:
		_free_rid(p_rd, _cookie_array)
	_cookie_array = candidate
	_cookie_source_key = p_source_key.duplicate()
	_cookie_array_generation += 1
	if _cookie_array_generation <= 0:
		_cookie_array_generation = 1
	return true


func _ensure_neutral_cookie_array(p_rd: RenderingDevice) -> bool:
	if _neutral_cookie_array.is_valid() and p_rd.texture_is_valid(_neutral_cookie_array):
		return true
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	format.width = 1
	format.height = 1
	format.depth = 1
	format.array_layers = 1
	format.mipmaps = 1
	format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	format.is_discardable = false
	var white := PackedByteArray([255, 255, 255, 255])
	_neutral_cookie_array = p_rd.texture_create(format, RDTextureView.new(), [white])
	return _neutral_cookie_array.is_valid()


static func requires_cookie_resampling(p_cookie_count: int) -> bool:
	return p_cookie_count > 0


func _ensure_cookie_sampler(p_rd: RenderingDevice) -> bool:
	if _sampler.is_valid():
		return true
	var sampler_state := RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = p_rd.sampler_create(sampler_state)
	return _sampler.is_valid()


func _ensure_resample_pipeline(p_rd: RenderingDevice) -> bool:
	if _sampler.is_valid() and _resample_shader.is_valid() and _resample_pipeline.is_valid():
		return true
	if _resample_pipeline.is_valid():
		_free_rid(p_rd, _resample_pipeline)
		_resample_pipeline = RID()
	if _resample_shader.is_valid():
		_free_rid(p_rd, _resample_shader)
		_resample_shader = RID()
	if not _ensure_cookie_sampler(p_rd):
		_last_error = "Could not create the cookie resampling sampler."
		return false
	var source := FileAccess.get_file_as_string(SHADER_PATH)
	if source.is_empty() or not source.begins_with("#version 450"):
		_last_error = "Cookie resampling shader source is missing or malformed."
		return false
	var shader_source := RDShaderSource.new()
	shader_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	shader_source.source_compute = source
	var spirv: RDShaderSPIRV = p_rd.shader_compile_spirv_from_source(shader_source)
	if spirv == null:
		_last_error = "RD returned no SPIR-V for the cookie resampling shader."
		return false
	var compile_error := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not compile_error.is_empty():
		_last_error = "Cookie resampling shader compile failed: " + compile_error
		return false
	_resample_shader = p_rd.shader_create_from_spirv(spirv, "FengFogLightCookieResample")
	if not _resample_shader.is_valid():
		_last_error = "Could not create the cookie resampling shader."
		return false
	_resample_pipeline = p_rd.compute_pipeline_create(_resample_shader)
	if not _resample_pipeline.is_valid():
		_last_error = "Could not create the cookie resampling pipeline."
		return false
	return true


func _prepare_resample_sets(p_rd: RenderingDevice, p_destination: RID,
		p_items: Array) -> Dictionary:
	var sets: Array[RID] = []
	var parameter_buffers: Array[RID] = []
	for index in p_items.size():
		var item: Dictionary = p_items[index]
		var scale := Vector2.ONE
		var source_size := Vector2(float(item.source_width), float(item.source_height))
		if source_size.x > source_size.y:
			scale.y = source_size.y / source_size.x
		else:
			scale.x = source_size.x / source_size.y
		var data := PackedByteArray()
		data.append_array(PackedInt32Array([
			int(item.source_width), int(item.source_height), index, RESAMPLE_EDGE,
		]).to_byte_array())
		data.append_array(PackedFloat32Array([scale.x, scale.y, 0.0, 0.0]).to_byte_array())
		var params := p_rd.uniform_buffer_create(data.size(), data)
		if not params.is_valid():
			_cleanup_resample_arrays(p_rd, sets, parameter_buffers)
			return {"valid": false, "reason": "Could not allocate cookie resampling parameters."}
		var uniforms: Array[RDUniform] = []
		var source_uniform := RDUniform.new()
		source_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		source_uniform.binding = 0
		source_uniform.add_id(_sampler)
		source_uniform.add_id(item.texture)
		uniforms.append(source_uniform)
		var destination_uniform := RDUniform.new()
		destination_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		destination_uniform.binding = 1
		destination_uniform.add_id(p_destination)
		uniforms.append(destination_uniform)
		var params_uniform := RDUniform.new()
		params_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
		params_uniform.binding = 2
		params_uniform.add_id(params)
		uniforms.append(params_uniform)
		var uniform_set := p_rd.uniform_set_create(uniforms, _resample_shader, 0)
		if not uniform_set.is_valid():
			p_rd.free_rid(params)
			_cleanup_resample_arrays(p_rd, sets, parameter_buffers)
			return {"valid": false, "reason": "Could not create a cookie resampling uniform set."}
		sets.append(uniform_set)
		parameter_buffers.append(params)
	return {"valid": true, "sets": sets, "parameter_buffers": parameter_buffers}


func _cleanup_resample_sets(p_rd: RenderingDevice, p_prepared: Dictionary) -> void:
	_cleanup_resample_arrays(p_rd, p_prepared.get("sets", []),
			p_prepared.get("parameter_buffers", []))


func _cleanup_resample_arrays(p_rd: RenderingDevice, p_sets: Array, p_buffers: Array) -> void:
	for rid in p_sets:
		_free_rid(p_rd, rid)
	for rid in p_buffers:
		_free_rid(p_rd, rid)


func _upload_records(p_rd: RenderingDevice, p_bytes: PackedByteArray) -> bool:
	var required := maxi(p_bytes.size(), Layout.RECORD_BYTES)
	if not _records_buffer.is_valid() or required > _records_capacity_bytes:
		_free_rid(p_rd, _records_buffer)
		_records_capacity_bytes = _next_power_of_two(required)
		var initial_bytes := p_bytes.duplicate()
		initial_bytes.resize(_records_capacity_bytes)
		_records_buffer = p_rd.storage_buffer_create(_records_capacity_bytes, initial_bytes)
		return _records_buffer.is_valid()
	return p_rd.buffer_update(_records_buffer, 0, p_bytes.size(), p_bytes) == OK


func _upload_header(p_rd: RenderingDevice, p_bytes: PackedByteArray) -> bool:
	if not _header_buffer.is_valid():
		_header_buffer = p_rd.uniform_buffer_create(Layout.HEADER_BYTES, p_bytes)
		return _header_buffer.is_valid()
	return p_rd.buffer_update(_header_buffer, 0, p_bytes.size(), p_bytes) == OK


static func _next_power_of_two(p_value: int) -> int:
	var result := 1
	while result < p_value:
		result <<= 1
	return result


func _invalid_result(p_reason: String) -> Dictionary:
	_last_error = p_reason
	return {
		"valid": false,
		"abi_version": Layout.ABI_VERSION,
		"reason": p_reason,
		"resource_ownership": "provider_owned_outputs",
	}


func _free_rid(p_rd: RenderingDevice, p_rid: RID) -> void:
	if p_rid.is_valid():
		p_rd.free_rid(p_rid)

