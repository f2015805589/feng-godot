class_name FFogRayInputGenerator
extends RefCounted
## Generates the provider's 48-byte shadow-ray records on the main RD.
## CPU input is O(light slots); no GDScript loop writes individual rays.

const SHADER_DIR := "res://addons/feng-fog/rendering/raytracing"
const NATIVE_LIGHT_ABI_PATH := "res://addons/feng-fog/rendering/shaders/native_light_inputs.glslinc"
const LIGHT_EXTENSION_ABI_PATH := "res://addons/feng-fog/rendering/lighting/light_extensions/fog_light_extension.glslinc"
const OwnedRids = preload("res://addons/feng-render-pipeline/rd/owned_rids.gd")
const RDUniforms = preload("res://addons/feng-render-pipeline/rd/uniforms.gd")
const FRAME_INPUT_ABI_VERSION := 1
const RAY_INPUT_ABI_VERSION := 2
const LIGHT_EXTENSION_ABI_VERSION := 2
const RAY_INPUT_STRIDE_BYTES := 48
const RAY_FRAME_UNIFORM_BYTES := 256
const RAY_DEPTH_PARAMETERS_UNIFORM_BYTES := 144
const RAY_DEPTH_SAMPLER_BINDING := 7
const RAY_DEPTH_PARAMETERS_BINDING := 8
const WORK_MASK_PARAMETERS_UNIFORM_BYTES := 16
const WORK_MASK_STORAGE_BINDING := 9
const WORK_MASK_PARAMETERS_BINDING := 10
const LIGHT_EXTENSION_SET := 3
const LIGHT_EXTENSION_RECORD_BINDING := 0
const LIGHT_EXTENSION_COOKIE_BINDING := 1
const LIGHT_EXTENSION_HEADER_BINDING := 2
const LIGHT_EXTENSION_RECORD_STRIDE_BYTES := 144
const LIGHT_EXTENSION_HEADER_BYTES := 16
const DIRECTIONAL_LIGHT_CAPACITY := 8
const DIRECTIONAL_LIGHT_STRIDE_BYTES := 464
const LOCAL_LIGHT_STRIDE_BYTES := 224
const MAX_RAY_COUNT := 1 << 24
const MAX_INPUT_BUFFER_BYTES := 128 * 1024 * 1024
const MAX_RAYS_BY_BYTES := 2796202 # floor(128 MiB / 48 bytes).
const WORKGROUP_SIZE_X := 64

const LIGHT_DIRECTIONAL := 0
const LIGHT_OMNI := 1
const LIGHT_SPOT := 2
const LIGHT_AREA := 3

var _rd: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _ray_buffer := RID()
var _ray_capacity_bytes := 0
var _frame_buffer := RID()
var _depth_parameters_buffer := RID()
var _work_mask_parameters_buffer := RID()
var _neutral_extension_records_buffer := RID()
var _neutral_extension_header_buffer := RID()
var _neutral_extension_cookie_array := RID()
var _neutral_extension_sampler := RID()
var _depth_sampler := RID()
var _fallback_depth_texture := RID()
var _light_slot_buffer := RID()
var _light_slot_capacity_bytes := 0
var _neutral_storage_buffer := RID()
var _neutral_directional_buffer := RID()
var _last_error := ""


func get_contract() -> Dictionary:
	return {
		"abi_version": RAY_INPUT_ABI_VERSION,
		"ray_record_stride_bytes": RAY_INPUT_STRIDE_BYTES,
		"ray_frame_uniform_bytes": RAY_FRAME_UNIFORM_BYTES,
		"depth_parameters_uniform_bytes": RAY_DEPTH_PARAMETERS_UNIFORM_BYTES,
		"depth_sampler_binding": RAY_DEPTH_SAMPLER_BINDING,
		"depth_parameters_binding": RAY_DEPTH_PARAMETERS_BINDING,
		"work_mask_parameters_uniform_bytes": WORK_MASK_PARAMETERS_UNIFORM_BYTES,
		"work_mask_storage_binding": WORK_MASK_STORAGE_BINDING,
		"work_mask_parameters_binding": WORK_MASK_PARAMETERS_BINDING,
		"light_extension_set": LIGHT_EXTENSION_SET,
		"light_extension_bindings": [LIGHT_EXTENSION_RECORD_BINDING,
				LIGHT_EXTENSION_COOKIE_BINDING, LIGHT_EXTENSION_HEADER_BINDING],
		"light_extension_abi_version": LIGHT_EXTENSION_ABI_VERSION,
		"light_extension_record_stride_bytes": LIGHT_EXTENSION_RECORD_STRIDE_BYTES,
		"light_extension": "optional same-frame set-3 provider output; directional/omni/spot/area native slots map to omni/spot/area/directional records",
		"capsule_source": "explicit source_length_m and local axis from set-3 ABI v2; zero length preserves native size disk / area sampling",
		"capsule_random_sequence": "hash(ray_index XOR low32(frame_generation) XOR light_type*0x85ebca6b XOR sample_index*0xc2b2ae35); the third feng_ray_random() value samples the line segment",
		"work_mask": "optional per-froxel uint effective sample count (0, 1, or miss count); enabled only with matching frame generation, froxel count, capacity, and sample index",
		"depth_constraint": "144-byte jittered projection pair; enabled only after GBUFFER completion, depth prepass, and current sampled depth validation",
		"ray_order": "light_major_froxel_minor",
		"sample_offset": "shared XYZ within-froxel offset in [0,1], matching the volume service sample; defaults to center",
		"ray_fields": [
			{"name": "origin_min_t", "offset": 0, "format": "vec4", "unit": "world meters"},
			{"name": "direction_max_t", "offset": 16, "format": "vec4", "unit": "normalized world direction; meters"},
			{"name": "cone_words", "offset": 32, "format": "uvec4 raw words", "meaning": "ABI v1: x/y are IEEE-754 radius/growth bits and z/w are ignored; ABI v2: x/y unchanged, z is the raw uint32 light mask, w is IEEE-754 bits for active 1.0 or skip 0.0"},
		],
		"visibility_values": {"blocked": 0, "visible_or_inactive_neutral": 1},
		"ownership": "ray buffer is provider-owned; consumer borrows it through the returned generation",
		"input_lights": "native borrowed RD buffers are read by GPU; CPU only uploads 8-byte (type,index) slots",
		"maximum_input_bytes": MAX_INPUT_BUFFER_BYTES,
		"gpu_readback": false,
	}


func get_last_error() -> String:
	return _last_error


## Creates one bounded light batch. `p_light_slots` is [type,index,...], with
## types directional=0, omni=1, spot=2, area=3. Native light values remain in
## borrowed renderer buffers and are read by the compute shader.
func generate_batch(p_rd: RenderingDevice, p_frame_inputs: Dictionary,
		p_grid: Vector3i, p_log_z_params: Vector3, p_froxel_pixel_size: int,
		p_light_slots: PackedInt32Array, p_max_ray_distance_m: float = 0.0,
		p_min_ray_t_m: float = 0.01,
		p_sample_offset: Vector2 = Vector2(0.5, 0.5),
		p_sample_depth_offset: float = 0.5,
		p_depth_options: Dictionary = {},
		p_work_mask_options: Dictionary = {},
		p_light_extension_inputs: Dictionary = {}) -> Dictionary:
	_last_error = ""
	var validation := _validate_request(p_rd, p_frame_inputs, p_grid, p_log_z_params,
			p_froxel_pixel_size, p_light_slots, p_max_ray_distance_m, p_min_ray_t_m,
			p_sample_offset, p_sample_depth_offset)
	if not bool(validation.get("valid", false)):
		return _invalid_result(str(validation.get("reason", "Invalid ray batch.")),
				int(p_frame_inputs.get("frame_generation", -1)), int(validation.get("max_lights_per_batch", 0)))
	var frame_generation := int(p_frame_inputs.get("frame_generation", -1))
	var froxel_count := int(validation["froxel_count"])
	var work_mask := validate_work_mask_options(p_work_mask_options,
			frame_generation, froxel_count)
	if not bool(work_mask.get("valid", false)):
		return _invalid_result(str(work_mask.get("reason", "The work mask is invalid.")),
				frame_generation, int(validation.get("max_lights_per_batch", 0)))
	var light_count := int(p_light_slots.size() / 2)
	if light_count == 0:
		return {
			"valid": true,
			"no_work": true,
			"ray_input_buffer": RID(),
			"ray_input_capacity_bytes": 0,
			"ray_input_bytes_required": 0,
			"ray_count": 0,
			"light_count": 0,
			"froxel_count": froxel_count,
			"stride_bytes": RAY_INPUT_STRIDE_BYTES,
			"abi_version": RAY_INPUT_ABI_VERSION,
			"generation": frame_generation,
			"light_slots": PackedInt32Array(),
			"fallback_required": false,
		}
	var light_extension := validate_light_extension_inputs(
			p_light_extension_inputs, p_frame_inputs)
	if not bool(light_extension.get("valid", false)):
		return _invalid_result(str(light_extension.get("reason",
				"Same-frame light-extension inputs are invalid.")), frame_generation,
				int(validation.get("max_lights_per_batch", 0)))
	var ray_count := light_count * froxel_count
	var required_bytes := ray_count * RAY_INPUT_STRIDE_BYTES
	if ray_count > MAX_RAY_COUNT or required_bytes > MAX_INPUT_BUFFER_BYTES:
		return _invalid_result("Ray batch exceeds the bounded GPU input buffer; split it into smaller light batches.",
				frame_generation, int(validation["max_lights_per_batch"]))
	if not _ensure_device(p_rd):
		return _invalid_result("Could not attach the ray-input generator to the main RenderingDevice.",
				frame_generation, int(validation["max_lights_per_batch"]))
	if not _ensure_pipeline(p_rd):
		return _invalid_result(_last_error, frame_generation,
				int(validation["max_lights_per_batch"]))
	if not _ensure_buffers(p_rd, required_bytes, p_light_slots.size() * 4):
		return _invalid_result(_last_error, frame_generation,
				int(validation["max_lights_per_batch"]))
	var depth_input := _prepare_depth_input(p_rd, p_frame_inputs, p_depth_options)
	if not bool(depth_input.get("valid", false)):
		return _invalid_result(str(depth_input.get("reason", "Current depth input is invalid.")),
				frame_generation, int(validation["max_lights_per_batch"]))
	var depth_parameters := pack_depth_parameters_uniform(p_frame_inputs,
			bool(depth_input.get("available", false)))
	if depth_parameters.size() != RAY_DEPTH_PARAMETERS_UNIFORM_BYTES:
		return _invalid_result("Depth-constraint UBO packing did not produce the fixed 144-byte ABI.",
				frame_generation, int(validation["max_lights_per_batch"]))
	var effective_max_distance := float(p_frame_inputs["far_plane_m"]) \
			if p_max_ray_distance_m <= 0.0 else p_max_ray_distance_m
	var extension_enabled := bool(light_extension.get("enabled", false))
	var frame_bytes := pack_ray_frame_uniform(p_frame_inputs, p_grid, p_log_z_params,
			p_froxel_pixel_size, light_count, effective_max_distance, p_min_ray_t_m,
			p_sample_offset, p_sample_depth_offset, extension_enabled)
	if frame_bytes.size() != RAY_FRAME_UNIFORM_BYTES:
		return _invalid_result("RayFrame UBO packing did not produce the fixed 256-byte ABI.",
				frame_generation, int(validation["max_lights_per_batch"]))
	var slot_bytes := p_light_slots.to_byte_array()
	var work_mask_parameters := pack_work_mask_parameters_uniform(work_mask,
			frame_generation)
	if p_rd.buffer_update(_frame_buffer, 0, frame_bytes.size(), frame_bytes) != OK \
			or p_rd.buffer_update(_depth_parameters_buffer, 0, depth_parameters.size(), depth_parameters) != OK \
			or p_rd.buffer_update(_work_mask_parameters_buffer, 0,
					work_mask_parameters.size(), work_mask_parameters) != OK \
			or p_rd.buffer_update(_light_slot_buffer, 0, slot_bytes.size(), slot_bytes) != OK:
		return _invalid_result("Could not upload the RayFrame/depth/work-mask UBOs or light-slot list.",
				frame_generation, int(validation["max_lights_per_batch"]))
	var uniforms := _make_uniforms(p_rd, p_frame_inputs, depth_input, work_mask)
	if uniforms.is_empty():
		return _invalid_result(_last_error, frame_generation,
				int(validation["max_lights_per_batch"]))
	var uniform_set := p_rd.uniform_set_create(uniforms, _shader, 0)
	if not uniform_set.is_valid():
		return _invalid_result("Could not bind the native lights and ray output buffers.",
				frame_generation, int(validation["max_lights_per_batch"]))
	var extension_uniform_set := _make_light_extension_uniform_set(p_rd,
			light_extension, frame_generation)
	if not extension_uniform_set.is_valid():
		p_rd.free_rid(uniform_set)
		return _invalid_result(_last_error, frame_generation,
				int(validation["max_lights_per_batch"]))
	var compute_list := p_rd.compute_list_begin()
	if compute_list == RenderingDevice.INVALID_ID:
		p_rd.free_rid(uniform_set)
		p_rd.free_rid(extension_uniform_set)
		return _invalid_result("Could not begin the ray-input compute list.",
				frame_generation, int(validation["max_lights_per_batch"]))
	p_rd.compute_list_bind_compute_pipeline(compute_list, _pipeline)
	p_rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	p_rd.compute_list_bind_uniform_set(compute_list, extension_uniform_set, LIGHT_EXTENSION_SET)
	p_rd.compute_list_dispatch(compute_list,
			ceili(float(ray_count) / float(WORKGROUP_SIZE_X)), 1, 1)
	p_rd.compute_list_end()
	p_rd.free_rid(uniform_set)
	p_rd.free_rid(extension_uniform_set)
	return {
		"valid": true,
		"no_work": false,
		"provider": "frp_main_rd_ray_input_compute",
		"ray_input_buffer": _ray_buffer,
		"ray_input_capacity_bytes": _ray_capacity_bytes,
		"ray_input_bytes_required": required_bytes,
		"ray_count": ray_count,
		"light_count": light_count,
		"froxel_count": froxel_count,
		"stride_bytes": RAY_INPUT_STRIDE_BYTES,
		"abi_version": RAY_INPUT_ABI_VERSION,
		"generation": frame_generation,
		"ray_input_generation": frame_generation,
		"depth_constraint_available": bool(depth_input.get("available", false)),
		"depth_input_texture": depth_input.get("texture", RID()),
		"depth_input_ownership": "borrowed current depth layer when enabled; otherwise provider-owned neutral texture; caller never frees it",
		"work_mask_enabled": bool(work_mask.get("enabled", false)),
		"work_mask_buffer": work_mask.get("mask_buffer", RID()),
		"work_mask_capacity_bytes": int(work_mask.get("mask_capacity_bytes", 0)),
		"work_mask_frame_generation": frame_generation,
		"work_mask_froxel_count": froxel_count,
		"sample_index": int(work_mask.get("sample_index", 0)),
		"max_samples": int(work_mask.get("max_samples", 1)),
		"work_mask_ownership": "borrowed same-main-RD storage buffer; caller keeps it alive through compute dispatch; no CPU readback",
		"light_extension_enabled": extension_enabled,
		"light_extension_frame_generation": frame_generation,
		"light_extension_record_count": int(light_extension.get("record_count", 0)),
		"light_extension_record_stride_bytes": LIGHT_EXTENSION_RECORD_STRIDE_BYTES,
		"light_extension_ownership": "set-3 records/header/cookie inputs are borrowed same-main-RD provider outputs; no CPU readback or free; keep the provider snapshot alive through this dispatch",
		"light_slots": p_light_slots.duplicate(),
		"ray_order": "light_major_froxel_minor",
		"output_ownership": "provider",
		"output_lifetime": "borrowed until the next generate_batch call or release; consume immediately in the same RD command stream",
		"native_light_inputs_ownership": "borrowed_renderer_buffers",
		"compute_to_trace_ordering": "caller must issue the RT trace after this compute list on the same main RenderingDevice",
		"inactive_ray_semantics": "cone_words.z=0u and cone_words.w=floatBits(0.0); ABI v2 raygen writes neutral visibility 1 without tracing",
		"fallback_required": false,
		"max_lights_per_batch": int(validation["max_lights_per_batch"]),
	}


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
	OwnedRids.append_all(result, seen, [_ray_buffer, _frame_buffer, _light_slot_buffer,
			_depth_parameters_buffer, _work_mask_parameters_buffer,
			_neutral_extension_records_buffer, _neutral_extension_header_buffer,
			_neutral_extension_cookie_array, _neutral_extension_sampler,
			_depth_sampler, _fallback_depth_texture,
			_neutral_storage_buffer, _neutral_directional_buffer, _pipeline, _shader])
	if p_clear:
		_rd = null
		_shader = RID()
		_pipeline = RID()
		_ray_buffer = RID()
		_ray_capacity_bytes = 0
		_frame_buffer = RID()
		_depth_parameters_buffer = RID()
		_work_mask_parameters_buffer = RID()
		_neutral_extension_records_buffer = RID()
		_neutral_extension_header_buffer = RID()
		_neutral_extension_cookie_array = RID()
		_neutral_extension_sampler = RID()
		_depth_sampler = RID()
		_fallback_depth_texture = RID()
		_light_slot_buffer = RID()
		_light_slot_capacity_bytes = 0
		_neutral_storage_buffer = RID()
		_neutral_directional_buffer = RID()
		_last_error = ""
	return result


static func pack_ray_frame_uniform(p_frame_inputs: Dictionary, p_grid: Vector3i,
		p_log_z_params: Vector3, p_froxel_pixel_size: int, p_slot_count: int,
		p_max_ray_distance_m: float, p_min_ray_t_m: float,
		p_sample_offset: Vector2 = Vector2(0.5, 0.5),
		p_sample_depth_offset: float = 0.5,
		p_light_extension_enabled: bool = false) -> PackedByteArray:
	var projection: Projection = p_frame_inputs.get("inverse_projection_unjittered", Projection.IDENTITY)
	var camera: Transform3D = p_frame_inputs.get("camera_transform", Transform3D.IDENTITY)
	var frame_projection: Projection = p_frame_inputs.get("projection", Projection.IDENTITY)
	var eye_offset: Vector3 = p_frame_inputs.get("eye_offset", Vector3.ZERO)
	var internal_size: Vector2i = p_frame_inputs.get("internal_size", Vector2i.ZERO)
	var values := PackedFloat32Array()
	_append_projection(values, projection)
	_append_transform(values, camera)
	values.append_array(PackedFloat32Array([eye_offset.x, eye_offset.y, eye_offset.z, 0.0]))
	values.append_array(PackedFloat32Array([camera.origin.x, camera.origin.y, camera.origin.z,
			1.0 if frame_projection.is_orthogonal() else 0.0]))
	values.append_array(PackedFloat32Array([float(p_grid.x), float(p_grid.y), float(p_grid.z),
			p_sample_offset.y]))
	values.append_array(PackedFloat32Array([float(internal_size.x), float(internal_size.y),
			float(p_froxel_pixel_size), p_sample_offset.x]))
	values.append_array(PackedFloat32Array([p_log_z_params.x, p_log_z_params.y,
			p_log_z_params.z, float(p_frame_inputs.get("near_plane_m", 0.05))]))
	values.append_array(PackedFloat32Array([p_min_ray_t_m, p_max_ray_distance_m,
			float(p_frame_inputs.get("far_plane_m", 1000.0)), p_sample_depth_offset]))
	if values.size() != 56:
		return PackedByteArray()
	var bytes := values.to_byte_array()
	var counts := PackedInt32Array([
		int(p_frame_inputs.get("directional_light_count", 0)),
		int(p_frame_inputs.get("omni_light_count", 0)),
		int(p_frame_inputs.get("spot_light_count", 0)),
		int(p_frame_inputs.get("area_light_count", 0)),
	])
	var frame_generation := int(p_frame_inputs.get("frame_generation", 0))
	var batch := PackedInt32Array([
		p_slot_count, frame_generation & 0xffffffff,
		int(p_frame_inputs.get("selected_volume_directional_index", -1)),
		1 if p_light_extension_enabled else 0,
	])
	bytes.append_array(counts.to_byte_array())
	bytes.append_array(batch.to_byte_array())
	return bytes if bytes.size() == RAY_FRAME_UNIFORM_BYTES else PackedByteArray()


static func pack_depth_parameters_uniform(p_frame_inputs: Dictionary,
		p_available: bool) -> PackedByteArray:
	var projection: Variant = p_frame_inputs.get("projection")
	var inverse_projection: Variant = p_frame_inputs.get("inverse_projection")
	if not projection is Projection or not inverse_projection is Projection:
		return PackedByteArray()
	var values := PackedFloat32Array()
	_append_projection(values, projection)
	_append_projection(values, inverse_projection)
	values.append_array(PackedFloat32Array([
			1.0 if p_available else 0.0,
			0.5, # UE GridCenterOffsetFromDepthBuffer.
			1.0, # UE OffsetThresholdToAcceptDepthBufferOffset.
			0.0,
	]))
	var bytes := values.to_byte_array()
	return bytes if bytes.size() == RAY_DEPTH_PARAMETERS_UNIFORM_BYTES else PackedByteArray()


static func depth_constraint_requested(p_frame_inputs: Dictionary,
		p_depth_options: Dictionary) -> bool:
	return bool(p_depth_options.get("gbuffer_completed", false)) \
			and bool(p_frame_inputs.get("depth_prepass_enabled", false))


static func validate_work_mask_options(p_options: Dictionary,
		p_frame_generation: int, p_froxel_count: int) -> Dictionary:
	if p_options.is_empty():
		return {"valid": true, "enabled": false}
	if not p_options.has("enabled") or typeof(p_options["enabled"]) != TYPE_BOOL:
		return {"valid": false, "reason": "Work-mask options must explicitly state whether the mask is enabled."}
	if not bool(p_options["enabled"]):
		return {"valid": true, "enabled": false}
	for key in ["mask_buffer", "mask_capacity_bytes", "frame_generation",
			"froxel_count", "sample_index", "max_samples"]:
		if not p_options.has(key):
			return {"valid": false, "reason": "Enabled work-mask metadata is missing: " + key}
	var mask_buffer: Variant = p_options["mask_buffer"]
	if not mask_buffer is RID or not mask_buffer.is_valid():
		return {"valid": false, "reason": "Enabled work mask needs a valid borrowed RenderingDevice buffer RID."}
	for key in ["mask_capacity_bytes", "frame_generation", "froxel_count", "sample_index", "max_samples"]:
		if typeof(p_options[key]) != TYPE_INT:
			return {"valid": false, "reason": "Work-mask metadata must be integer-valued: " + key}
	var capacity_bytes := int(p_options["mask_capacity_bytes"])
	var work_generation := int(p_options["frame_generation"])
	var mask_froxel_count := int(p_options["froxel_count"])
	var sample_index := int(p_options["sample_index"])
	var max_samples := int(p_options["max_samples"])
	if p_froxel_count <= 0 or mask_froxel_count != p_froxel_count:
		return {"valid": false, "reason": "Work-mask froxel count does not match the current grid."}
	if work_generation != p_frame_generation:
		return {"valid": false, "reason": "Work mask belongs to a stale frame generation."}
	if capacity_bytes < p_froxel_count * 4:
		return {"valid": false, "reason": "Work-mask buffer capacity is smaller than one uint per froxel."}
	if max_samples <= 0 or sample_index < 0 or sample_index >= max_samples:
		return {"valid": false, "reason": "Work-mask sample index must be within the positive per-frame sample budget."}
	return {
		"valid": true,
		"enabled": true,
		"mask_buffer": mask_buffer,
		"mask_capacity_bytes": capacity_bytes,
		"frame_generation": work_generation,
		"froxel_count": mask_froxel_count,
		"sample_index": sample_index,
		"max_samples": max_samples,
	}


static func validate_light_extension_inputs(p_options: Dictionary,
		p_frame_inputs: Dictionary) -> Dictionary:
	if p_options.is_empty():
		return {"valid": true, "enabled": false, "record_count": 0}
	if not bool(p_options.get("valid", false)):
		return {"valid": false, "reason": "Light-extension output is not a valid same-frame provider result."}
	if int(p_options.get("abi_version", 0)) != LIGHT_EXTENSION_ABI_VERSION \
			or int(p_options.get("record_stride_bytes", 0)) != LIGHT_EXTENSION_RECORD_STRIDE_BYTES:
		return {"valid": false, "reason": "Light-extension ABI version or 144-byte record stride is incompatible."}
	var frame_generation := int(p_frame_inputs.get("frame_generation", -1))
	if frame_generation < 0 or int(p_options.get("frame_generation", -1)) != frame_generation:
		return {"valid": false, "reason": "Light-extension records belong to a stale or different frame."}
	var expected_counts := PackedInt32Array([
			int(p_frame_inputs.get("omni_light_count", -1)),
			int(p_frame_inputs.get("spot_light_count", -1)),
			int(p_frame_inputs.get("area_light_count", -1)),
			int(p_frame_inputs.get("directional_light_count", -1)),
	])
	var actual_counts: Variant = p_options.get("native_type_counts")
	if not actual_counts is PackedInt32Array or actual_counts.size() != 4:
		return {"valid": false, "reason": "Light-extension result is missing its [omni,spot,area,directional] native counts."}
	var record_count := 0
	for index in 4:
		if expected_counts[index] < 0 or actual_counts[index] != expected_counts[index]:
			return {"valid": false, "reason": "Light-extension per-type counts do not match the current native light arrays."}
		record_count += expected_counts[index]
	if int(p_options.get("record_count", -1)) != record_count:
		return {"valid": false, "reason": "Light-extension record count does not match the current frame."}
	var expected_offsets := {
		"omni": 0,
		"spot": expected_counts[0],
		"area": expected_counts[0] + expected_counts[1],
		"directional": expected_counts[0] + expected_counts[1] + expected_counts[2],
	}
	var offsets: Variant = p_options.get("record_offsets")
	if not offsets is Dictionary:
		return {"valid": false, "reason": "Light-extension record offsets are missing."}
	for kind in expected_offsets:
		if int(offsets.get(kind, -1)) != int(expected_offsets[kind]):
			return {"valid": false, "reason": "Light-extension record offset mismatch for %s." % kind}
	var records_buffer: Variant = p_options.get("records_buffer")
	var header_buffer: Variant = p_options.get("header_buffer")
	var cookie_texture: Variant = p_options.get("cookie_texture_array")
	var cookie_sampler: Variant = p_options.get("cookie_sampler")
	if not records_buffer is RID or not records_buffer.is_valid() \
			or not header_buffer is RID or not header_buffer.is_valid() \
			or not cookie_texture is RID or not cookie_texture.is_valid() \
			or not cookie_sampler is RID or not cookie_sampler.is_valid():
		return {"valid": false, "reason": "Light-extension set-3 borrowed RIDs are incomplete or invalid."}
	var required_capacity := maxi(LIGHT_EXTENSION_RECORD_STRIDE_BYTES,
			record_count * LIGHT_EXTENSION_RECORD_STRIDE_BYTES)
	if int(p_options.get("records_buffer_capacity_bytes", 0)) < required_capacity:
		return {"valid": false, "reason": "Light-extension record buffer capacity is too small."}
	if int(p_options.get("cookie_layer_count", -1)) < 0:
		return {"valid": false, "reason": "Light-extension cookie layer count is invalid."}
	return {
		"valid": true,
		"enabled": true,
		"record_count": record_count,
		"records_buffer": records_buffer,
		"header_buffer": header_buffer,
		"cookie_texture_array": cookie_texture,
		"cookie_sampler": cookie_sampler,
		"cookie_layer_count": int(p_options.get("cookie_layer_count", 0)),
		"frame_generation": frame_generation,
	}


static func capsule_axis_center_view_cpu(p_world_to_light: Transform3D,
		p_view_to_world: Transform3D, p_local_axis_index: int) -> Vector3:
	var local_axis := Vector3.ZERO
	match p_local_axis_index:
		0:
			local_axis = Vector3.RIGHT
		1:
			local_axis = Vector3.UP
		2:
			local_axis = Vector3.BACK
		_:
			return Vector3.ZERO
	var world_axis := p_world_to_light.basis.transposed() * local_axis
	var center_axis := p_view_to_world.basis.transposed() * world_axis
	return center_axis.normalized() if center_axis.length_squared() > 1.0e-8 else Vector3.ZERO


static func capsule_source_sample_cpu(p_center: Vector3, p_axis: Vector3,
		p_length_m: float, p_random: float) -> Vector3:
	if not p_center.is_finite() or not p_axis.is_finite() \
			or not is_finite(p_length_m) or p_length_m <= 0.0:
		return p_center
	var axis := p_axis.normalized()
	if axis.length_squared() <= 1.0e-8:
		return p_center
	var offset := (clampf(p_random, 0.0, 1.0) - 0.5) * p_length_m
	return p_center + axis * offset


static func extension_record_index_cpu(p_native_type: int, p_native_index: int,
		p_extension_counts: PackedInt32Array) -> int:
	if p_extension_counts.size() != 4 or p_native_index < 0:
		return -1
	var extension_kind := -1
	match p_native_type:
		LIGHT_DIRECTIONAL:
			extension_kind = 3
		LIGHT_OMNI:
			extension_kind = 0
		LIGHT_SPOT:
			extension_kind = 1
		LIGHT_AREA:
			extension_kind = 2
		_:
			return -1
	if p_native_index >= p_extension_counts[extension_kind]:
		return -1
	var offset := 0
	for kind in extension_kind:
		offset += p_extension_counts[kind]
	return offset + p_native_index


static func pack_work_mask_parameters_uniform(p_work_mask: Dictionary,
		p_frame_generation: int) -> PackedByteArray:
	var packed := PackedInt32Array([
			int(p_work_mask.get("sample_index", 0)),
			1 if bool(p_work_mask.get("enabled", false)) else 0,
			p_frame_generation & 0xffffffff,
			0,
	])
	var bytes := packed.to_byte_array()
	return bytes if bytes.size() == WORK_MASK_PARAMETERS_UNIFORM_BYTES else PackedByteArray()


static func work_mask_sample_is_active(p_sample_index: int,
		p_requested_samples: int, p_max_samples: int) -> bool:
	return p_max_samples > 0 and p_sample_index >= 0 and p_sample_index < p_max_samples \
			and p_requested_samples > 0 and p_requested_samples <= p_max_samples \
			and p_sample_index < p_requested_samples


static func flatten_ray_index(p_light_index: int, p_froxel_index: int,
		p_froxel_count: int) -> int:
	if p_light_index < 0 or p_froxel_index < 0 or p_froxel_index >= p_froxel_count:
		return -1
	return p_light_index * p_froxel_count + p_froxel_index


static func depth_from_slice(p_log_z_params: Vector3, p_slice: float) -> float:
	if not p_log_z_params.is_finite() or p_log_z_params.x <= 0.0 or p_log_z_params.z <= 0.0 \
			or not is_finite(p_slice):
		return 0.0
	var exponent := maxf(p_slice, 0.0) / p_log_z_params.z
	return maxf((pow(2.0, exponent) - p_log_z_params.y) / p_log_z_params.x, 0.0)


## CPU oracle for the UE front-depth adjustment. The caller passes a decoded
## scene slice; runtime GPU generation uses the same rule in GLSL.
static func depth_constrained_slice_cpu_oracle(p_cell_z: float, p_sample_offset_z: float,
		p_scene_slice: float, p_grid_center_offset: float = 0.5,
		p_accept_threshold: float = 1.0) -> float:
	var sample_slice := p_cell_z + p_sample_offset_z
	var delta_to_front := (p_scene_slice - p_grid_center_offset) - sample_slice
	if delta_to_front < 0.0 and -delta_to_front < p_accept_threshold:
		sample_slice += delta_to_front
	return maxf(sample_slice, 0.0)


static func froxel_center_uv(p_cell: Vector2i, p_internal_size: Vector2i,
		p_pixel_size: int) -> Vector2:
	if p_cell.x < 0 or p_cell.y < 0 or p_internal_size.x <= 0 or p_internal_size.y <= 0 \
			or p_pixel_size <= 0:
		return Vector2(-1.0, -1.0)
	return (Vector2(p_cell) + Vector2(0.5, 0.5)) * float(p_pixel_size) / Vector2(p_internal_size)


static func max_batch_lights(p_grid: Vector3i) -> int:
	if p_grid.x <= 0 or p_grid.y <= 0 or p_grid.z <= 0:
		return 0
	var froxel_count := p_grid.x * p_grid.y * p_grid.z
	return int(mini(MAX_RAY_COUNT, MAX_RAYS_BY_BYTES) / froxel_count)


static func validate_light_slots(p_slots: PackedInt32Array, p_counts: Vector4i) -> Dictionary:
	if p_slots.size() % 2 != 0:
		return {"valid": false, "reason": "Light slots must contain type/index pairs."}
	var counts := [p_counts.x, p_counts.y, p_counts.z, p_counts.w]
	var unique_slots := {}
	for offset in range(0, p_slots.size(), 2):
		var light_type := int(p_slots[offset])
		var light_index := int(p_slots[offset + 1])
		if light_type < LIGHT_DIRECTIONAL or light_type > LIGHT_AREA:
			return {"valid": false, "reason": "Light slot type must be directional, omni, spot, or area."}
		if light_index < 0 or light_index >= int(counts[light_type]):
			return {"valid": false, "reason": "A light slot index is outside its native buffer count."}
		var key := "%d:%d" % [light_type, light_index]
		if unique_slots.has(key):
			return {"valid": false, "reason": "Duplicate light slots would duplicate a shadow batch."}
		unique_slots[key] = true
	return {"valid": true, "slot_count": int(p_slots.size() / 2)}


static func _append_projection(p_values: PackedFloat32Array, p_projection: Projection) -> void:
	for column in 4:
		var axis: Vector4 = p_projection[column]
		p_values.append_array(PackedFloat32Array([axis.x, axis.y, axis.z, axis.w]))


static func _append_transform(p_values: PackedFloat32Array, p_transform: Transform3D) -> void:
	for axis in [p_transform.basis.x, p_transform.basis.y, p_transform.basis.z]:
		p_values.append_array(PackedFloat32Array([axis.x, axis.y, axis.z, 0.0]))
	p_values.append_array(PackedFloat32Array([
		p_transform.origin.x, p_transform.origin.y, p_transform.origin.z, 1.0,
	]))


func _validate_request(p_rd: RenderingDevice, p_frame: Dictionary,
		p_grid: Vector3i, p_log_z: Vector3, p_pixel_size: int,
		p_slots: PackedInt32Array, p_max_distance: float, p_min_t: float,
		p_sample_offset: Vector2, p_sample_depth_offset: float) -> Dictionary:
	if p_rd == null or p_rd != RenderingServer.get_rendering_device():
		return _validation_error("Ray input generation must use the RenderingServer main RenderingDevice.")
	if p_frame.is_empty() or not bool(p_frame.get("valid", false)) \
			or int(p_frame.get("abi_version", 0)) != FRAME_INPUT_ABI_VERSION:
		return _validation_error("A valid FRP volume frame input lease is required.")
	var projection: Variant = p_frame.get("projection")
	var inverse_projection: Variant = p_frame.get("inverse_projection_unjittered")
	var camera: Variant = p_frame.get("camera_transform")
	var eye_offset: Variant = p_frame.get("eye_offset", Vector3.ZERO)
	var size: Variant = p_frame.get("internal_size")
	if not projection is Projection or not inverse_projection is Projection \
			or not camera is Transform3D or not eye_offset is Vector3 or not size is Vector2i \
			or not camera.is_finite() or not eye_offset.is_finite() \
			or size.x <= 0 or size.y <= 0:
		return _validation_error("RayFrame projection, camera, eye offset, or viewport size is invalid.")
	if p_grid.x <= 0 or p_grid.y <= 0 or p_grid.z <= 0 \
			or p_pixel_size <= 0 or not p_log_z.is_finite() \
			or p_log_z.x <= 0.0 or p_log_z.z <= 0.0 \
			or not is_finite(p_sample_depth_offset) \
			or p_sample_depth_offset < 0.0 or p_sample_depth_offset > 1.0 \
			or not p_sample_offset.is_finite() \
			or p_sample_offset.x < 0.0 or p_sample_offset.x > 1.0 \
			or p_sample_offset.y < 0.0 or p_sample_offset.y > 1.0:
		return _validation_error("Froxel grid, pixel size, or logarithmic depth parameters are invalid.")
	var expected_grid := Vector2i(
			ceili(float(size.x) / float(p_pixel_size)),
			ceili(float(size.y) / float(p_pixel_size)))
	if p_grid.x != expected_grid.x or p_grid.y != expected_grid.y:
		return _validation_error("Froxel XY dimensions must equal ceil(internal_size / pixel_size).")
	var near_plane := float(p_frame.get("near_plane_m", 0.0))
	var far_plane := float(p_frame.get("far_plane_m", 0.0))
	var min_t := p_min_t
	var max_distance := far_plane if p_max_distance <= 0.0 else p_max_distance
	if not is_finite(near_plane) or near_plane <= 0.0 or not is_finite(far_plane) \
			or far_plane <= near_plane or not is_finite(min_t) or min_t < 0.0 \
			or not is_finite(max_distance) or max_distance <= min_t:
		return _validation_error("Ray distance bounds are not finite and ordered.")
	var counts := PackedInt32Array([
		int(p_frame.get("directional_light_count", -1)),
		int(p_frame.get("omni_light_count", -1)),
		int(p_frame.get("spot_light_count", -1)),
		int(p_frame.get("area_light_count", -1)),
	])
	for count in counts:
		if count < 0:
			return _validation_error("A native light count is missing or negative.")
	if int(p_frame.get("directional_light_buffer_capacity", 0)) != DIRECTIONAL_LIGHT_CAPACITY \
			or int(p_frame.get("directional_light_stride_bytes", 0)) != DIRECTIONAL_LIGHT_STRIDE_BYTES:
		return _validation_error("Directional UBO capacity or stride does not match the fixed v1 shader ABI.")
	if counts[0] > DIRECTIONAL_LIGHT_CAPACITY:
		return _validation_error("Directional light count exceeds the fixed UBO capacity.")
	for key in ["omni_light_stride_bytes", "spot_light_stride_bytes", "area_light_stride_bytes"]:
		if int(p_frame.get(key, 0)) != LOCAL_LIGHT_STRIDE_BYTES:
			return _validation_error("Local-light stride does not match the native 224-byte ABI.")
	var slot_validation := validate_light_slots(p_slots,
			Vector4i(counts[0], counts[1], counts[2], counts[3]))
	if not bool(slot_validation.get("valid", false)):
		return _validation_error(str(slot_validation.get("reason", "Invalid light-slot list.")))
	if not p_slots.is_empty() and (not p_rd.has_feature(RenderingDevice.SUPPORTS_RAYTRACING_PIPELINE) \
			or not p_rd.has_feature(RenderingDevice.SUPPORTS_BUFFER_DEVICE_ADDRESS)):
		return _validation_error("The active RenderingDevice cannot consume hardware RT batches; use the complete raster shadow batch.")
	var froxel_count := p_grid.x * p_grid.y * p_grid.z
	return {
		"valid": true,
		"froxel_count": froxel_count,
		"max_lights_per_batch": max_batch_lights(p_grid),
		"max_ray_distance_m": max_distance,
	}


func _make_uniforms(p_rd: RenderingDevice, p_frame: Dictionary,
		p_depth_input: Dictionary, p_work_mask: Dictionary) -> Array[RDUniform]:
	var directionals: RID = p_frame.get("directional_light_buffer", RID())
	if not directionals.is_valid() and int(p_frame.get("directional_light_count", 0)) == 0:
		directionals = _ensure_neutral_directional(p_rd)
	if not directionals.is_valid():
		_last_error = "The borrowed directional light UBO is invalid."
		return []
	var local_rids: Array[RID] = []
	for pair in [
		["omni_light_buffer", "omni_light_count"],
		["spot_light_buffer", "spot_light_count"],
		["area_light_buffer", "area_light_count"],
	]:
		var source: RID = p_frame.get(pair[0], RID())
		if not source.is_valid() and int(p_frame.get(pair[1], 0)) == 0:
			source = _ensure_neutral_storage(p_rd)
		if not source.is_valid():
			_last_error = "A borrowed local-light storage buffer is invalid: " + str(pair[0])
			return []
		local_rids.append(source)
	var uniforms: Array[RDUniform] = []
	uniforms.append(RDUniforms.uniform_buffer(0, _frame_buffer))
	uniforms.append(RDUniforms.uniform_buffer(1, directionals))
	for index in 3:
		uniforms.append(RDUniforms.storage_buffer(2 + index, local_rids[index]))
	uniforms.append(RDUniforms.storage_buffer(5, _light_slot_buffer))
	uniforms.append(RDUniforms.storage_buffer(6, _ray_buffer))
	var depth_texture: RID = p_depth_input.get("texture", RID())
	uniforms.append(RDUniforms.sampled(RAY_DEPTH_SAMPLER_BINDING, _depth_sampler, depth_texture))
	uniforms.append(RDUniforms.uniform_buffer(RAY_DEPTH_PARAMETERS_BINDING,
			_depth_parameters_buffer))
	var work_mask_buffer: RID = p_work_mask.get("mask_buffer", RID())
	if not bool(p_work_mask.get("enabled", false)):
		work_mask_buffer = _ensure_neutral_storage(p_rd)
	if not work_mask_buffer.is_valid():
		_last_error = "The borrowed work-mask storage buffer is invalid."
		return []
	uniforms.append(RDUniforms.storage_buffer(WORK_MASK_STORAGE_BINDING, work_mask_buffer))
	uniforms.append(RDUniforms.uniform_buffer(WORK_MASK_PARAMETERS_BINDING,
			_work_mask_parameters_buffer))
	return uniforms


func _make_light_extension_uniform_set(p_rd: RenderingDevice,
		p_extension: Dictionary, p_frame_generation: int) -> RID:
	var records: RID
	var cookie_texture: RID
	var cookie_sampler: RID
	var header: RID
	if bool(p_extension.get("enabled", false)):
		records = p_extension.get("records_buffer", RID())
		cookie_texture = p_extension.get("cookie_texture_array", RID())
		cookie_sampler = p_extension.get("cookie_sampler", RID())
		header = p_extension.get("header_buffer", RID())
		if not p_rd.texture_is_valid(cookie_texture):
			_last_error = "The borrowed light-extension cookie array is not valid on this main RenderingDevice."
			return RID()
		var format: RDTextureFormat = p_rd.texture_get_format(cookie_texture)
		if format == null or format.texture_type != RenderingDevice.TEXTURE_TYPE_2D_ARRAY \
				or format.width <= 0 or format.height <= 0 \
				or format.array_layers < maxi(1, int(p_extension.get("cookie_layer_count", 0))) \
				or (format.usage_bits & RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT) == 0:
			_last_error = "The borrowed light-extension cookie RID is not a sampleable 2D-array matching its layer metadata."
			return RID()
	else:
		if not _ensure_neutral_light_extension_resources(p_rd, p_frame_generation):
			_last_error = "Could not create neutral set-3 light-extension bindings."
			return RID()
		records = _neutral_extension_records_buffer
		cookie_texture = _neutral_extension_cookie_array
		cookie_sampler = _neutral_extension_sampler
		header = _neutral_extension_header_buffer
	var uniforms: Array[RDUniform] = []
	uniforms.append(RDUniforms.storage_buffer(LIGHT_EXTENSION_RECORD_BINDING, records))
	uniforms.append(RDUniforms.sampled(LIGHT_EXTENSION_COOKIE_BINDING,
			cookie_sampler, cookie_texture))
	uniforms.append(RDUniforms.uniform_buffer(LIGHT_EXTENSION_HEADER_BINDING, header))
	var result := p_rd.uniform_set_create(uniforms, _shader, LIGHT_EXTENSION_SET)
	if not result.is_valid():
		_last_error = "Could not bind the borrowed set-3 light-extension provider output."
	return result


func _ensure_neutral_light_extension_resources(p_rd: RenderingDevice,
		p_frame_generation: int) -> bool:
	if not _neutral_extension_records_buffer.is_valid():
		var record_bytes := PackedByteArray()
		record_bytes.resize(LIGHT_EXTENSION_RECORD_STRIDE_BYTES)
		_neutral_extension_records_buffer = p_rd.storage_buffer_create(
				LIGHT_EXTENSION_RECORD_STRIDE_BYTES, record_bytes)
	var header_bytes := PackedInt32Array([
			LIGHT_EXTENSION_ABI_VERSION, 1, 0, p_frame_generation & 0xffffffff,
	]).to_byte_array()
	if not _neutral_extension_header_buffer.is_valid():
		_neutral_extension_header_buffer = p_rd.uniform_buffer_create(
				LIGHT_EXTENSION_HEADER_BYTES, header_bytes)
	elif p_rd.buffer_update(_neutral_extension_header_buffer, 0,
			header_bytes.size(), header_bytes) != OK:
		return false
	if not _neutral_extension_cookie_array.is_valid() \
			or not p_rd.texture_is_valid(_neutral_extension_cookie_array):
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
		_neutral_extension_cookie_array = p_rd.texture_create(format,
				RDTextureView.new(), [PackedByteArray([255, 255, 255, 255])])
	if not _neutral_extension_sampler.is_valid():
		var sampler_state := RDSamplerState.new()
		sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		sampler_state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		_neutral_extension_sampler = p_rd.sampler_create(sampler_state)
	return _neutral_extension_records_buffer.is_valid() \
			and _neutral_extension_header_buffer.is_valid() \
			and _neutral_extension_cookie_array.is_valid() \
			and _neutral_extension_sampler.is_valid()


func _prepare_depth_input(p_rd: RenderingDevice, p_frame: Dictionary,
		p_options: Dictionary) -> Dictionary:
	if bool(p_frame.get("depth_prepass_enabled", false)) \
			and not p_options.has("gbuffer_completed"):
		return {"valid": false,
				"reason": "Frame depth prepass is enabled but no current GBuffer-completion fact was supplied; use the complete raster shadow batch."}
	var requested := depth_constraint_requested(p_frame, p_options)
	if not requested:
		var neutral := _ensure_fallback_depth_texture(p_rd)
		if not neutral.is_valid():
			return {"valid": false, "reason": "Could not create the neutral depth texture for an unavailable GBuffer."}
		return {"valid": true, "available": false, "texture": neutral}
	var texture: Variant = p_options.get("depth_texture", RID())
	if not texture is RID or not texture.is_valid() or not p_rd.texture_is_valid(texture):
		return {"valid": false,
				"reason": "The caller marked current GBuffer depth available, but its current per-view depth RID is invalid; use the complete raster shadow batch."}
	var format: RDTextureFormat = p_rd.texture_get_format(texture)
	var expected_size: Vector2i = p_frame.get("internal_size", Vector2i.ZERO)
	if format == null or format.texture_type != RenderingDevice.TEXTURE_TYPE_2D \
			or format.width <= 0 or format.height <= 0 \
			or format.width != expected_size.x or format.height != expected_size.y \
			or format.samples != RenderingDevice.TEXTURE_SAMPLES_1 \
			or (format.usage_bits & RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT) == 0:
		return {"valid": false,
				"reason": "Current GBuffer depth is not a resolved, sampleable 2D layer; use the complete raster shadow batch."}
	return {"valid": true, "available": true, "texture": texture}


func _ensure_fallback_depth_texture(p_rd: RenderingDevice) -> RID:
	if _fallback_depth_texture.is_valid() and p_rd.texture_is_valid(_fallback_depth_texture):
		return _fallback_depth_texture
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.width = 1
	format.height = 1
	format.depth = 1
	format.array_layers = 1
	format.mipmaps = 1
	format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	format.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	_fallback_depth_texture = p_rd.texture_create(format, RDTextureView.new(),
			[PackedFloat32Array([0.0]).to_byte_array()])
	return _fallback_depth_texture


func _ensure_device(p_rd: RenderingDevice) -> bool:
	if _rd != null and _rd != p_rd:
		release()
	_rd = p_rd
	return _rd == p_rd


func _ensure_pipeline(p_rd: RenderingDevice) -> bool:
	if _pipeline.is_valid() and _rd == p_rd:
		return true
	var ray_source := FileAccess.get_file_as_string(SHADER_DIR.path_join("fog_rt_ray_input_generate.glslinc"))
	var light_abi := FileAccess.get_file_as_string(NATIVE_LIGHT_ABI_PATH)
	var extension_abi := FileAccess.get_file_as_string(LIGHT_EXTENSION_ABI_PATH)
	if ray_source.is_empty() or light_abi.is_empty() or extension_abi.is_empty():
		_last_error = "Ray input compute source or a required native/light-extension ABI include is missing."
		return false
	ray_source = ray_source.replace("// FRP_NATIVE_LIGHT_ABI_INSERT", light_abi)
	ray_source = ray_source.replace("// FRP_LIGHT_EXTENSION_ABI_INSERT", extension_abi)
	var raw_compute_source := strip_compute_marker(ray_source)
	if raw_compute_source.is_empty():
		_last_error = "Godot compute marker is missing from the ray-input source."
		return false
	var source := RDShaderSource.new()
	source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	source.source_compute = raw_compute_source
	var spirv: RDShaderSPIRV = p_rd.shader_compile_spirv_from_source(source)
	if spirv == null:
		_last_error = "The RD compiler returned no ray-input compute SPIR-V."
		return false
	var compile_error := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not compile_error.is_empty():
		_last_error = "Ray-input compute shader compile failed: " + compile_error
		return false
	_shader = p_rd.shader_create_from_spirv(spirv, "FengFogRayInputGenerate")
	if not _shader.is_valid():
		_last_error = "Could not create the ray-input compute shader RID."
		return false
	_pipeline = p_rd.compute_pipeline_create(_shader)
	if not _pipeline.is_valid():
		_free_rid(p_rd, _shader)
		_shader = RID()
		_last_error = "Could not create the ray-input compute pipeline."
		return false
	return true


static func strip_compute_marker(p_source_text: String) -> String:
	var first_newline := p_source_text.find("\n")
	if first_newline < 0 or p_source_text.substr(0, first_newline).strip_edges() != "#[compute]":
		return ""
	return p_source_text.substr(first_newline + 1)


func _ensure_buffers(p_rd: RenderingDevice, p_required_ray_bytes: int,
		p_required_slot_bytes: int) -> bool:
	if not _frame_buffer.is_valid():
		_frame_buffer = p_rd.uniform_buffer_create(RAY_FRAME_UNIFORM_BYTES)
	if not _depth_parameters_buffer.is_valid():
		_depth_parameters_buffer = p_rd.uniform_buffer_create(RAY_DEPTH_PARAMETERS_UNIFORM_BYTES)
	if not _work_mask_parameters_buffer.is_valid():
		_work_mask_parameters_buffer = p_rd.uniform_buffer_create(WORK_MASK_PARAMETERS_UNIFORM_BYTES)
	if not _depth_sampler.is_valid():
		var sampler_state := RDSamplerState.new()
		sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		sampler_state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		_depth_sampler = p_rd.sampler_create(sampler_state)
	if not _ray_buffer.is_valid() or _ray_capacity_bytes < p_required_ray_bytes:
		_free_rid(p_rd, _ray_buffer)
		_ray_capacity_bytes = p_required_ray_bytes
		_ray_buffer = p_rd.storage_buffer_create(_ray_capacity_bytes)
	if not _light_slot_buffer.is_valid() or _light_slot_capacity_bytes < p_required_slot_bytes:
		_free_rid(p_rd, _light_slot_buffer)
		_light_slot_capacity_bytes = maxi(8, p_required_slot_bytes)
		_light_slot_buffer = p_rd.storage_buffer_create(_light_slot_capacity_bytes)
	if not _frame_buffer.is_valid() or not _depth_parameters_buffer.is_valid() \
			or not _work_mask_parameters_buffer.is_valid() \
			or not _depth_sampler.is_valid() or not _ray_buffer.is_valid() \
			or not _light_slot_buffer.is_valid():
		_last_error = "Could not allocate the RayFrame/depth/work-mask resources, light-slot, or ray-input buffer."
		return false
	return true


func _ensure_neutral_storage(p_rd: RenderingDevice) -> RID:
	if not _neutral_storage_buffer.is_valid():
		var zero_bytes := PackedByteArray()
		zero_bytes.resize(16)
		_neutral_storage_buffer = p_rd.storage_buffer_create(16, zero_bytes)
	return _neutral_storage_buffer


func _ensure_neutral_directional(p_rd: RenderingDevice) -> RID:
	if not _neutral_directional_buffer.is_valid():
		var zero_bytes := PackedByteArray()
		zero_bytes.resize(DIRECTIONAL_LIGHT_CAPACITY * DIRECTIONAL_LIGHT_STRIDE_BYTES)
		_neutral_directional_buffer = p_rd.uniform_buffer_create(zero_bytes.size(), zero_bytes)
	return _neutral_directional_buffer


func _validation_error(p_reason: String) -> Dictionary:
	return {"valid": false, "reason": p_reason, "max_lights_per_batch": 0}


func _invalid_result(p_reason: String, p_generation: int,
		p_max_lights: int = 0) -> Dictionary:
	_last_error = p_reason
	return {
		"valid": false,
		"reason": p_reason,
		"ray_input_buffer": RID(),
		"ray_input_capacity_bytes": 0,
		"ray_input_bytes_required": 0,
		"ray_count": 0,
		"light_count": 0,
		"froxel_count": 0,
		"stride_bytes": RAY_INPUT_STRIDE_BYTES,
		"generation": p_generation,
		"fallback_required": true,
		"fallback_provider": "complete_raster_shadow_batch",
		"max_lights_per_batch": p_max_lights,
	}


func _free_rid(p_rd: RenderingDevice, p_rid: RID) -> void:
	if p_rd != null and p_rid.is_valid():
		p_rd.free_rid(p_rid)
