@tool
extends RefCounted
## Owns the optional RT shadow batch bridge for the volumetric light pass.
## All rays and visibility stay on the main RenderingDevice; no readback occurs.

const Codec = preload("feng_volumetric_fog_codec.gd")
const LightExtensionLayout = preload("res://addons/feng-fog/rendering/lighting/light_extensions/fog_light_extension_layout.gd")
const RayInputGeneratorScript = preload("res://addons/feng-fog/rendering/raytracing/fog_rt_ray_input_generator.gd")
const RayTracingShadowProviderScript = preload("res://addons/feng-fog/rendering/raytracing/fog_rt_shadow_provider.gd")
const MAX_VISIBILITY_BYTES := 128 * 1024 * 1024

var _ray_input_generator: RefCounted = RayInputGeneratorScript.new()
var _ray_tracing_shadow_provider: RefCounted = RayTracingShadowProviderScript.new()
var _visibility_buffer := RID()
var _visibility_capacity_bytes := 0
var _slot_map_buffer := RID()
var _slot_map_capacity_bytes := 0


func prepare_view(ctx: FRPPassContext, rd: RenderingDevice, frame: Dictionary,
		snapshot: Dictionary, volume: Dictionary, grid: Vector3i, view: int,
		extension_rows: Dictionary, extension_inputs: Dictionary, requested_samples: int,
		current_depth_layer: RID) -> Dictionary:
	var rows_value: Variant = extension_rows.get("rows", [])
	if not rows_value is Array:
		return _raster_fallback("light-extension rows are not an Array")
	var rows: Array = rows_value
	var slot_map := _neutral_slot_map(rows.size())
	if not bool(volume.get("ray_traced_shadows_enabled", false)):
		return _disabled(slot_map, "ray-traced shadows are disabled")
	if not bool(extension_inputs.get("valid", false)) \
			or int(extension_inputs.get("abi_version", 0)) != 2 \
			or int(extension_inputs.get("frame_generation", -1)) \
			!= int(frame.get("frame_generation", -2)):
		return _disabled(slot_map,
				"current frame light-extension GPU inputs are invalid or from another frame")
	var directional_count := maxi(int(frame.get("directional_light_count", 0)), 0)
	var selected_sun: RID = snapshot.get("volumetric_selected_sun_rid", RID())
	var selected_index := _selected_directional_index(frame, selected_sun, directional_count)
	var slots := PackedInt32Array()
	for row_index in rows.size():
		var row_value: Variant = rows[row_index]
		if not row_value is Dictionary:
			return _raster_fallback("light-extension row %d is not a Dictionary" % row_index)
		var row: Dictionary = row_value
		if int(row.get("shadow_policy", LightExtensionLayout.SHADOW_INHERIT_NATIVE)) \
				!= LightExtensionLayout.SHADOW_HARDWARE_RT_OPT_IN:
			continue
		var native_kind := int(row.get("native_kind", -1))
		var native_index := int(row.get("native_index", -1))
		var ray_type := -1
		match native_kind:
			LightExtensionLayout.KIND_DIRECTIONAL:
				if native_index != selected_index or selected_index < 0:
					continue
				ray_type = RayInputGeneratorScript.LIGHT_DIRECTIONAL
			LightExtensionLayout.KIND_OMNI:
				ray_type = RayInputGeneratorScript.LIGHT_OMNI
			LightExtensionLayout.KIND_SPOT:
				ray_type = RayInputGeneratorScript.LIGHT_SPOT
			LightExtensionLayout.KIND_AREA:
				ray_type = RayInputGeneratorScript.LIGHT_AREA
		if ray_type < 0 or native_index < 0:
			return _raster_fallback("RT opt-in light has invalid kind/index")
		slot_map[row_index] = int(slots.size() / 2)
		slots.append(ray_type)
		slots.append(native_index)
	if slots.is_empty():
		return _disabled(slot_map, "no RT opt-in lights are active in this frame")
	var capability: Dictionary = _ray_tracing_shadow_provider.call("get_capability_report", rd)
	if not bool(capability.get("supported", false)):
		return _disabled(_neutral_slot_map(rows.size()),
				str(capability.get("reason", "hardware RT is unavailable")))
	var geometry_value: Variant = snapshot.get("ray_tracing_geometry", {})
	if not geometry_value is Dictionary or geometry_value.is_empty():
		return _disabled(_neutral_slot_map(rows.size()), "no current-world RT geometry snapshot")
	var geometry_snapshot: Dictionary = geometry_value
	var unsupported_geometry: Variant = geometry_snapshot.get("unsupported_shadow_geometry", [])
	var geometry_instances: Variant = geometry_snapshot.get("instances", [])
	if not unsupported_geometry is Array or not unsupported_geometry.is_empty() \
			or not geometry_instances is Array or geometry_instances.is_empty():
		return _disabled(_neutral_slot_map(rows.size()),
				"current shadow geometry is empty or requires complete raster fallback")
	var depth_result: Dictionary = _depth_options(ctx, rd, frame, current_depth_layer)
	if not bool(depth_result.get("valid", false)):
		return _disabled(_neutral_slot_map(rows.size()), str(depth_result.get("reason", "invalid current depth")))
	var depth_options: Dictionary = depth_result.get("options", {})
	var froxel_count := grid.x * grid.y * grid.z
	var total_slots := int(slots.size() / 2)
	var sample_count := Codec.normalize_history_miss_count(requested_samples)
	var visibility_bytes := froxel_count * total_slots * sample_count * 4
	if visibility_bytes <= 0 or visibility_bytes > MAX_VISIBILITY_BYTES:
		return _disabled(_neutral_slot_map(rows.size()),
				"sample-major RT visibility atlas exceeds the 128 MiB safety limit")
	if not _ensure_visibility_buffer(rd, visibility_bytes):
		return _disabled(_neutral_slot_map(rows.size()),
				"could not allocate the bounded sample-major RT visibility atlas")
	if not _update_slot_map(rd, slot_map):
		return _disabled(_neutral_slot_map(rows.size()),
				"could not upload the current light-to-RT-slot map")
	var max_batch_lights := int(RayInputGeneratorScript.max_batch_lights(grid))
	if max_batch_lights <= 0:
		return _disabled(_neutral_slot_map(rows.size()), "froxel grid exceeds the RT generator batch limit")
	var log_z := Codec.grid_z_params(float(frame.get("near_plane_m", 0.05)),
			float(volume.get("start_distance", 0.0)), float(volume.get("far_distance", 1.0)), grid.z)
	return {
		"valid": true, "enabled": true, "reason": "",
		"frame_generation": int(frame.get("frame_generation", -1)),
		"view": view, "grid": grid, "froxel_count": froxel_count,
		"slot_count": total_slots, "slots": slots, "slot_map": slot_map,
		"light_extension_inputs": extension_inputs,
		"slot_map_buffer": _slot_map_buffer,
		"geometry_snapshot": geometry_snapshot,
		"depth_options": depth_options,
		"visibility_bytes": visibility_bytes,
		"sample_count": sample_count,
		"jitter_enabled": bool(volume.get("jitter_enabled", true)),
		"max_batch_lights": max_batch_lights,
		"log_z_params": log_z,
		"max_ray_distance_m": maxf(float(volume.get("far_distance", 1.0))
				- float(volume.get("start_distance", 0.0)), 0.01),
		"froxel_pixel_size": maxi(int(volume.get("froxel_pixel_size", Codec.FROXEL_PIXEL_SIZE)), 1),
	}


func trace_prepared_view(rd: RenderingDevice, frame: Dictionary, prepared: Dictionary,
		history_work_mask: RID = RID(), history_work_mask_bytes: int = 0) -> Dictionary:
	var prepared_slot_map_value: Variant = prepared.get("slot_map", PackedInt32Array())
	var prepared_slot_map: PackedInt32Array = prepared_slot_map_value \
			if prepared_slot_map_value is PackedInt32Array else PackedInt32Array()
	var fallback_record_count := prepared_slot_map.size()
	if not bool(prepared.get("enabled", false)):
		return _disabled(prepared_slot_map,
				str(prepared.get("reason", "RT was not selected for this view")))
	var grid: Vector3i = prepared.get("grid", Vector3i.ZERO)
	var frame_generation := int(prepared.get("frame_generation", -1))
	var sample_count := int(prepared.get("sample_count", 0))
	var froxel_count := int(prepared.get("froxel_count", 0))
	var work_mask_enabled := history_work_mask.is_valid()
	if work_mask_enabled and history_work_mask_bytes < froxel_count * 4:
		return _disabled(_neutral_slot_map(fallback_record_count),
				"history work-mask buffer is smaller than the current froxel grid")
	var sample_offsets: Array[Vector3] = Codec.history_miss_sample_offsets(frame_generation,
			sample_count, bool(prepared.get("jitter_enabled", true)))
	if sample_offsets.size() != sample_count:
		return _disabled(_neutral_slot_map(fallback_record_count),
				"volume and RT sample-offset counts disagree")
	var slots: PackedInt32Array = prepared.get("slots", PackedInt32Array())
	var total_slots := int(prepared.get("slot_count", 0))
	var max_batch_lights := int(prepared.get("max_batch_lights", 0))
	if total_slots <= 0 or max_batch_lights <= 0:
		return _disabled(_neutral_slot_map(fallback_record_count),
				"prepared RT batch has no active slots")
	for sample_index in sample_count:
		var sample_offset: Vector3 = sample_offsets[sample_index]
		for batch_start in range(0, total_slots, max_batch_lights):
			var batch_end := mini(batch_start + max_batch_lights, total_slots)
			var batch_slots := slots.slice(batch_start * 2, batch_end * 2)
			var work_mask_options: Dictionary = {}
			if work_mask_enabled:
				work_mask_options = {
					"enabled": true,
					"mask_buffer": history_work_mask,
					"mask_capacity_bytes": history_work_mask_bytes,
					"frame_generation": frame_generation,
					"froxel_count": froxel_count,
					"sample_index": sample_index,
					"max_samples": sample_count,
				}
			var generated_value: Variant = _ray_input_generator.call("generate_batch", rd,
					frame, grid, prepared.log_z_params, int(prepared.froxel_pixel_size),
					batch_slots, float(prepared.max_ray_distance_m), 0.01,
					Vector2(sample_offset.x, sample_offset.y), sample_offset.z,
					prepared.depth_options, work_mask_options,
					prepared.light_extension_inputs)
			if not generated_value is Dictionary or not bool(generated_value.get("valid", false)) \
					or bool(generated_value.get("fallback_required", false)):
				return _disabled(_neutral_slot_map(fallback_record_count),
						str(generated_value.get("reason", _ray_input_generator.call("get_last_error"))) \
						if generated_value is Dictionary else "ray input generator returned a non-Dictionary result")
			var generated: Dictionary = generated_value
			if bool(generated.get("no_work", false)):
				return _disabled(_neutral_slot_map(fallback_record_count),
						"RT generator returned no_work for a non-empty prepared batch")
			var ray_count := int(generated.get("ray_count", 0))
			var batch_light_count := int(generated.get("light_count", 0))
			if ray_count != batch_light_count * froxel_count or batch_light_count != batch_end - batch_start:
				return _disabled(_neutral_slot_map(fallback_record_count),
						"generated ray count does not match the current light/froxel batch")
			var trace_value: Variant = _ray_tracing_shadow_provider.call("trace_shadow_batch",
					rd, prepared.geometry_snapshot, generated.get("ray_input_buffer", RID()),
					int(generated.get("ray_input_capacity_bytes", 0)),
					int(generated.get("stride_bytes", 0)),
					int(generated.get("ray_input_generation", -1)), ray_count,
					batch_light_count, froxel_count, frame_generation,
					int(generated.get("abi_version", 0)))
			if not trace_value is Dictionary or not bool(trace_value.get("valid", false)) \
					or bool(trace_value.get("fallback_required", false)):
				return _disabled(_neutral_slot_map(fallback_record_count),
						str(trace_value.get("reason", _ray_tracing_shadow_provider.call("get_last_error"))) \
						if trace_value is Dictionary else "RT provider returned a non-Dictionary result")
			var trace: Dictionary = trace_value
			var visibility: Variant = trace.get("visibility_buffer", RID())
			var copy_bytes := ray_count * 4
			if not visibility is RID or not visibility.is_valid() \
					or int(trace.get("frame_generation", -1)) != frame_generation \
					or int(trace.get("ray_count", -1)) != ray_count \
					or int(trace.get("visibility_stride_bytes", 0)) != 4 \
					or int(trace.get("ray_input_generation", -1)) != frame_generation:
				return _disabled(_neutral_slot_map(fallback_record_count),
						"RT visibility result failed the same-frame uint32 contract")
			# Copy each borrowed provider result before the next generator/trace call
			# can overwrite either source buffer. Layout is [sample][slot][froxel].
			var destination_offset := (sample_index * total_slots + batch_start) * froxel_count * 4
			if rd.buffer_copy(visibility, _visibility_buffer, 0, destination_offset, copy_bytes) != OK:
				return _disabled(_neutral_slot_map(fallback_record_count),
						"could not copy borrowed RT visibility into the persistent sample atlas")
	return {
		"valid": true, "enabled": true, "reason": "",
		"slot_count": total_slots, "slot_map_buffer": _slot_map_buffer,
		"visibility_buffer": _visibility_buffer,
		"visibility_capacity_bytes": _visibility_capacity_bytes,
		"visibility_bytes": int(prepared.visibility_bytes),
		"work_mask_valid": work_mask_enabled,
		"sample_count": sample_count,
	}


func get_last_error() -> String:
	return str(_ray_input_generator.call("get_last_error")) + " " \
			+ str(_ray_tracing_shadow_provider.call("get_last_error"))


func take_owned_rids() -> Array[RID]:
	var result: Array[RID] = []
	if _visibility_buffer.is_valid():
		result.append(_visibility_buffer)
	if _slot_map_buffer.is_valid():
		result.append(_slot_map_buffer)
	_visibility_buffer = RID()
	_visibility_capacity_bytes = 0
	_slot_map_buffer = RID()
	_slot_map_capacity_bytes = 0
	_ray_input_generator.release()
	_ray_tracing_shadow_provider.release()
	return result


func _depth_options(ctx: FRPPassContext, rd: RenderingDevice,
		frame: Dictionary, current_depth_layer: RID) -> Dictionary:
	var gbuffer_completed := ctx != null and ctx.has_method("is_operation_completed") \
			and bool(ctx.call("is_operation_completed", FRPPassContext.OP_GBUFFER))
	var depth_prepass_enabled := bool(frame.get("depth_prepass_enabled", false))
	var depth_claimed := depth_prepass_enabled and gbuffer_completed
	var options: Dictionary = {"gbuffer_completed": false, "depth_texture": RID()}
	if not depth_claimed:
		return {"valid": true, "options": options}
	var depth_format: RDTextureFormat = rd.texture_get_format(current_depth_layer) \
			if current_depth_layer.is_valid() and rd.texture_is_valid(current_depth_layer) else null
	var internal_size: Vector2i = frame.get("internal_size", Vector2i.ZERO)
	if depth_format == null or depth_format.texture_type != RenderingDevice.TEXTURE_TYPE_2D \
			or depth_format.width != internal_size.x or depth_format.height != internal_size.y \
			or (depth_format.usage_bits & RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT) == 0:
		return {"valid": false,
				"reason": "current GBuffer depth was claimed but is not sampleable; use complete raster shadows"}
	options = {"gbuffer_completed": true, "depth_texture": current_depth_layer}
	return {"valid": true, "options": options}


func _selected_directional_index(frame: Dictionary, selected_sun: RID, count: int) -> int:
	if not selected_sun.is_valid():
		return -1
	var base_rids: Variant = frame.get("directional_light_base_rids", [])
	if not base_rids is Array:
		return -1
	for index in mini(base_rids.size(), count):
		var candidate: Variant = base_rids[index]
		if candidate is RID and candidate == selected_sun:
			return index
	return -1


func _update_slot_map(rd: RenderingDevice, slot_map: PackedInt32Array) -> bool:
	var upload := slot_map
	if upload.is_empty():
		upload = PackedInt32Array([-1])
	var bytes := upload.to_byte_array()
	if not _slot_map_buffer.is_valid() or _slot_map_capacity_bytes < bytes.size():
		var replacement := rd.storage_buffer_create(bytes.size(), bytes)
		if not replacement.is_valid():
			return false
		if _slot_map_buffer.is_valid():
			rd.free_rid(_slot_map_buffer)
		_slot_map_buffer = replacement
		_slot_map_capacity_bytes = bytes.size()
		return true
	return rd.buffer_update(_slot_map_buffer, 0, bytes.size(), bytes) == OK


func _ensure_visibility_buffer(rd: RenderingDevice, required_bytes: int) -> bool:
	if required_bytes <= 0 or required_bytes > MAX_VISIBILITY_BYTES:
		return false
	if _visibility_buffer.is_valid() and _visibility_capacity_bytes >= required_bytes:
		return true
	var replacement := rd.storage_buffer_create(required_bytes)
	if not replacement.is_valid():
		return false
	if _visibility_buffer.is_valid():
		rd.free_rid(_visibility_buffer)
	_visibility_buffer = replacement
	_visibility_capacity_bytes = required_bytes
	return true


func _neutral_slot_map(record_count: int) -> PackedInt32Array:
	var result := PackedInt32Array()
	result.resize(maxi(record_count, 0))
	result.fill(-1)
	return result


func _disabled(slot_map: PackedInt32Array, reason: String) -> Dictionary:
	return {"valid": true, "enabled": false, "reason": reason,
		"slot_count": 0, "slot_map": slot_map, "slot_map_buffer": RID(),
		"visibility_buffer": RID(), "visibility_capacity_bytes": 0,
		"work_mask_valid": false, "sample_count": 1}


func _raster_fallback(reason: String) -> Dictionary:
	return _disabled(PackedInt32Array(), reason)
