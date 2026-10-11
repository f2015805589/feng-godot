@tool
class_name FengGTAOPass
extends "pass_base.gd"
## Screen-space diffuse ambient occlusion. One scheduler entry owns the complete
## horizon, spatial filter, temporal resolve, and depth-aware upsample sequence.

const NativeSpec = preload("../pipeline/native_spec.gd")
const IndirectGISelection = preload("../pipeline/indirect_gi_selection.gd")
const PIPELINE_SCOPE: StringName = NativeSpec.SCOPE_PIPELINE
const OUTPUT_NAME: StringName = &"gtao_ao"
const SHADER_PATHS := [
	"res://addons/feng-render-pipeline/library/gtao/gtao_horizon.glsl",
	"res://addons/feng-render-pipeline/library/gtao/gtao_spatial.glsl",
	"res://addons/feng-render-pipeline/library/gtao/gtao_temporal.glsl",
	"res://addons/feng-render-pipeline/library/gtao/gtao_upsample.glsl",
]
const UBO_SIZE := 112
const WORKGROUP_SIZE := 8
const OUTPUT_FORMAT := RenderingDevice.DATA_FORMAT_R16_SFLOAT
const PACKED_FORMAT := RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT

@export_group("GTAO")
@export_range(0.05, 20.0, 0.05, "or_greater", "suffix:m") var radius_m := 2.0:
	set(value):
		radius_m = maxf(value, 0.05)
		emit_changed()
@export_range(0.0, 1.0, 0.01) var falloff_start_ratio := 0.5:
	set(value):
		falloff_start_ratio = clampf(value, 0.0, 1.0)
		emit_changed()
@export_range(0.0, 1.0, 0.01) var thickness_blend := 0.5:
	set(value):
		thickness_blend = clampf(value, 0.0, 1.0)
		emit_changed()
@export_range(0.0, 2.0, 0.01) var strength := 1.0:
	set(value):
		strength = clampf(value, 0.0, 2.0)
		emit_changed()
@export_range(0.0, 0.99, 0.01) var history_weight := 0.9:
	set(value):
		history_weight = clampf(value, 0.0, 0.99)
		emit_changed()
@export_group("")

var _shaders: Array[RID] = []
var _pipelines: Array[RID] = []
var _nearest_sampler := RID()
var _zero_velocity_texture := RID()
var _states: Dictionary = {}
var _frame_context: FRPPassContext
var _frame_scene_data: RenderSceneData
var _frame_parameters: Dictionary = {}
var _frame_rendered_views := 0
var _frame_expected_views := 0
var _frame_buffers: RenderSceneBuffersRD

func _init() -> void:
	inputs = _make_inputs()
	outputs = _make_outputs()
	stage = EFFECT_CALLBACK_TYPE_POST_GBUFFER
	needs_motion_vectors = true

func _make_inputs() -> Array[TextureInput]:
	var depth := TextureInput.new()
	depth.binding = 0
	depth.source = TextureInput.Source.DEPTH
	var normal := TextureInput.new()
	normal.binding = 1
	normal.source = TextureInput.Source.NORMAL_ROUGHNESS
	var orm := TextureInput.new()
	orm.binding = 2
	orm.source = TextureInput.Source.ORM
	return [depth, normal, orm]

func _make_outputs() -> Array[OutputDeclaration]:
	var ao := OutputDeclaration.new()
	ao.name = OUTPUT_NAME
	ao.data_format = OUTPUT_FORMAT
	ao.usage = OutputDeclaration.Usage.SAMPLED | OutputDeclaration.Usage.STORAGE
	return [ao]

func _inputs_match(actual: Array[TextureInput], expected: Array[TextureInput]) -> bool:
	if actual.size() != expected.size():
		return false
	for i in actual.size():
		var left := actual[i]
		var right := expected[i]
		if left == null or left.binding != right.binding or left.source != right.source \
				or left.binding_type != right.binding_type or left.custom_scope != right.custom_scope \
				or left.custom_name != right.custom_name:
			return false
	return true

func _outputs_match(actual: Array[OutputDeclaration], expected: Array[OutputDeclaration]) -> bool:
	if actual.size() != expected.size():
		return false
	for i in actual.size():
		var left := actual[i]
		var right := expected[i]
		if left == null or left.name != right.name or left.data_format != right.data_format \
				or left.usage != right.usage or left.scale != right.scale:
			return false
	return true

func ensure_frp_contract() -> bool:
	var expected_inputs := _make_inputs()
	var expected_outputs := _make_outputs()
	var changed := false
	if not _inputs_match(inputs, expected_inputs):
		inputs = expected_inputs
		changed = true
	if not _outputs_match(outputs, expected_outputs):
		outputs = expected_outputs
		changed = true
	if stage != EFFECT_CALLBACK_TYPE_POST_GBUFFER:
		stage = EFFECT_CALLBACK_TYPE_POST_GBUFFER
		changed = true
	needs_motion_vectors = true
	return changed

func get_required_before_native_ids() -> PackedInt32Array:
	return PackedInt32Array([NativeSpec.PASS_LIGHTING])

func get_volume_parameter_names() -> PackedStringArray:
	return PackedStringArray(["radius_m", "falloff_start_ratio", "thickness_blend", "strength", "history_weight"])

func refresh_resource_flags() -> void:
	needs_motion_vectors = true
	super.refresh_resource_flags()

func _frp_execute(ctx: FRPPassContext) -> void:
	if ctx == null:
		return
	var buffers := ctx.get_render_scene_buffers() as RenderSceneBuffersRD
	var render_data := ctx.get_render_data()
	if buffers == null or render_data == null:
		ctx.set_diffuse_ambient_occlusion_texture(RID())
		return
	_frame_parameters = get_resolved_parameters(ctx)
	_frame_context = ctx
	_frame_buffers = buffers
	_frame_expected_views = buffers.get_view_count()
	_frame_rendered_views = 0
	_frame_scene_data = render_data.get_render_scene_data() as RenderSceneData
	if _rtgi_owns_diffuse_slot(ctx):
		_invalidate_buffer_history(buffers)
		ctx.set_diffuse_ambient_occlusion_texture(RID())
		_clear_frame_state()
		return
	super._frp_execute(ctx)
	var published := buffers.get_texture(PIPELINE_SCOPE, OUTPUT_NAME)
	if _frame_rendered_views == _frame_expected_views and _valid_output_texture(published, buffers):
		ctx.set_diffuse_ambient_occlusion_texture(published)
	else:
		# A missing input, failed stage, or resize race leaves native lighting on its
		# frame-local white fallback; an older viewport texture is never published.
		ctx.set_diffuse_ambient_occlusion_texture(RID())
	_clear_frame_state()

func _clear_frame_state() -> void:
	_frame_context = null
	_frame_scene_data = null
	_frame_buffers = null
	_frame_parameters.clear()
	_frame_expected_views = 0
	_frame_rendered_views = 0

func _rtgi_owns_diffuse_slot(ctx: FRPPassContext) -> bool:
	var values := get_resolved_parameters(ctx)
	var owner: Variant = values.get(IndirectGISelection.OWNER_PARAMETER, null)
	if not owner is Dictionary or StringName(owner.get("kind", &"")) != IndirectGISelection.KIND_RT:
		return false
	if bool(owner.get("blocked", false)):
		return true
	var owner_key := String(owner.get("key", ""))
	if owner_key.is_empty():
		return true
	var resolved := ctx.get_pass_parameters(owner_key)
	if not resolved.has("strength"):
		return true
	var owner_strength := float(resolved.get("strength", 0.0))
	if not is_finite(owner_strength):
		return true
	return owner_strength > 0.0

func _render(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice) -> void:
	if _frame_scene_data == null or _shaders.size() != 4 or _pipelines.size() != 4:
		return
	var depth: RID = inputs[0].get_texture(buffers, view)
	var normal: RID = inputs[1].get_texture(buffers, view)
	var orm: RID = inputs[2].get_texture(buffers, view)
	var output := buffers.get_texture_slice(PIPELINE_SCOPE, OUTPUT_NAME, view, 0, 1, 1)
	var velocity := buffers.get_velocity_layer(view)
	if not depth.is_valid() or not normal.is_valid() or not orm.is_valid() or not output.is_valid():
		return
	var size := buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0:
		return
	var half_size := Vector2i(maxi(1, ceili(float(size.x) * 0.5)), maxi(1, ceili(float(size.y) * 0.5)))
	var state := _ensure_view_state(buffers, view, half_size, rd)
	if state.is_empty():
		return
	var has_motion := velocity.is_valid()
	if not velocity.is_valid():
		velocity = _ensure_zero_velocity(rd)
		if not velocity.is_valid():
			return
	var frame_number := Engine.get_frames_drawn()
	var camera_transform: Transform3D = _frame_scene_data.get_cam_transform()
	var projection: Projection = _frame_scene_data.get_view_projection(view)
	var current_jitter: Vector2 = _frame_context.get_taa_jitter()
	var previous_jitter: Vector2 = state.get("taa_jitter", current_jitter)
	var jitter_delta_uv := (previous_jitter - current_jitter) * 0.5
	var camera_cut := _is_camera_cut(state, camera_transform, projection, frame_number, has_motion)
	var valid_history := bool(state.get("history_valid", false)) and not camera_cut
	var params_bytes := _make_parameter_bytes(size, jitter_delta_uv, projection.inverse(), frame_number,
			valid_history, camera_cut)
	if rd.buffer_update(state["ubo"], 0, params_bytes.size(), params_bytes) != OK:
		_report("Cannot update GTAO frame parameters.")
		return
	var history: Array = state["history"]
	var read_index := int(state["read_index"])
	var write_index := 1 - read_index
	var raw: RID = state["raw"]
	var spatial: RID = state["spatial"]
	var previous: RID = history[read_index]
	var next_history: RID = history[write_index]
	var output_sets: Array[RID] = [
		_uniform_set(_shaders[0], [
			_sampled(0, depth, _nearest_sampler), _sampled(1, normal, _nearest_sampler),
			_sampled(2, orm, _nearest_sampler), _image(3, raw), _ubo(4, state["ubo"]),
		]),
		_uniform_set(_shaders[1], [
			_sampled(0, raw, _nearest_sampler), _sampled(1, depth, _nearest_sampler),
			_sampled(2, normal, _nearest_sampler), _image(3, spatial), _ubo(4, state["ubo"]),
		]),
		_uniform_set(_shaders[2], [
			_sampled(0, spatial, _nearest_sampler), _sampled(1, velocity, _nearest_sampler),
			_sampled(2, previous, _nearest_sampler), _image(3, next_history), _ubo(4, state["ubo"]),
		]),
		_uniform_set(_shaders[3], [
			_sampled(0, depth, _nearest_sampler), _sampled(1, normal, _nearest_sampler),
			_sampled(2, next_history, _nearest_sampler), _image(3, output), _ubo(4, state["ubo"]),
		]),
	]
	for uniform_set in output_sets:
		if not uniform_set.is_valid():
			_report("GTAO shader bindings do not match the declared texture contract.")
			return
	var list := rd.compute_list_begin()
	for stage_index in 4:
		rd.compute_list_bind_compute_pipeline(list, _pipelines[stage_index])
		rd.compute_list_bind_uniform_set(list, output_sets[stage_index], 0)
		var dispatch_size := size if stage_index == 3 else half_size
		rd.compute_list_dispatch(list, ceili(float(dispatch_size.x) / WORKGROUP_SIZE), ceili(float(dispatch_size.y) / WORKGROUP_SIZE), 1)
		if stage_index < 3:
			rd.compute_list_add_barrier(list)
	rd.compute_list_end()
	state["read_index"] = write_index
	state["history_valid"] = true
	state["last_frame"] = frame_number
	state["camera_transform"] = camera_transform
	state["projection"] = projection
	state["taa_jitter"] = current_jitter
	state["has_camera"] = true
	_states[buffers.get_instance_id()]["views"][view] = state
	_frame_rendered_views += 1

func _is_camera_cut(state: Dictionary, transform: Transform3D, projection: Projection,
		frame_number: int, has_motion: bool) -> bool:
	if not has_motion or not bool(state.get("history_valid", false)) or not bool(state.get("has_camera", false)):
		return true
	if int(state.get("last_frame", -2)) != frame_number - 1:
		return true
	var previous_transform: Transform3D = state["camera_transform"]
	if previous_transform.origin.distance_to(transform.origin) > maxf(radius_m * 2.0, 2.0):
		return true
	var previous_rotation := previous_transform.basis.orthonormalized().get_rotation_quaternion()
	var current_rotation := transform.basis.orthonormalized().get_rotation_quaternion()
	if previous_rotation.angle_to(current_rotation) > deg_to_rad(35.0):
		return true
	var previous_projection: Projection = state["projection"]
	var projection_delta := 0.0
	for column in 4:
		var previous_axis: Vector4 = previous_projection[column]
		var current_axis: Vector4 = projection[column]
		projection_delta = maxf(projection_delta, absf(previous_axis.x - current_axis.x))
		projection_delta = maxf(projection_delta, absf(previous_axis.y - current_axis.y))
		projection_delta = maxf(projection_delta, absf(previous_axis.z - current_axis.z))
		projection_delta = maxf(projection_delta, absf(previous_axis.w - current_axis.w))
	return projection_delta > 0.25

func _make_parameter_bytes(size: Vector2i, jitter_delta_uv: Vector2, inverse_projection: Projection,
		frame_number: int, valid_history: bool, camera_cut: bool) -> PackedByteArray:
	var values := PackedFloat32Array()
	for column in 4:
		var axis: Vector4 = inverse_projection[column]
		values.append_array(PackedFloat32Array([axis.x, axis.y, axis.z, axis.w]))
	values.append_array(PackedFloat32Array([float(size.x), float(size.y), jitter_delta_uv.x, jitter_delta_uv.y]))
	values.append_array(PackedFloat32Array([
		maxf(float(_frame_parameters.get("radius_m", radius_m)), 0.05),
		clampf(float(_frame_parameters.get("falloff_start_ratio", falloff_start_ratio)), 0.0, 1.0),
		clampf(float(_frame_parameters.get("thickness_blend", thickness_blend)), 0.0, 1.0),
		clampf(float(_frame_parameters.get("strength", strength)), 0.0, 2.0),
	]))
	values.append_array(PackedFloat32Array([
		clampf(float(_frame_parameters.get("history_weight", history_weight)), 0.0, 0.99),
		1.0 if valid_history else 0.0,
		1.0 if camera_cut else 0.0,
		float(frame_number % 65536),
	]))
	return values.to_byte_array()

func _ensure_view_state(buffers: RenderSceneBuffersRD, view: int, half_size: Vector2i,
		rd: RenderingDevice) -> Dictionary:
	var key := buffers.get_instance_id()
	var entry: Dictionary = _states.get(key, {})
	if not entry.is_empty() and entry["wr"].get_ref() == null:
		for old_state in entry["views"].values():
			_free_view_state(rd, old_state)
		_states.erase(key)
		entry = {}
	if entry.is_empty():
		entry = {"wr": weakref(buffers), "views": {}}
		_states[key] = entry
	var state: Dictionary = entry["views"].get(view, {})
	if not state.is_empty() and state.get("half_size", Vector2i()) != half_size:
		_free_view_state(rd, state)
		entry["views"].erase(view)
		_states[key] = entry
		state = {}
	if state.is_empty():
		state = _create_view_state(half_size, rd)
		if state.is_empty():
			_sync_owned_rid_snapshot()
			return {}
		entry["views"][view] = state
		_states[key] = entry
		_prune_states(key, rd)
		_sync_owned_rid_snapshot()
	return state

func _create_view_state(half_size: Vector2i, rd: RenderingDevice) -> Dictionary:
	var state := {
		"half_size": half_size,
		"raw": _create_texture(rd, half_size, PACKED_FORMAT),
		"spatial": _create_texture(rd, half_size, PACKED_FORMAT),
		"history": [
			_create_texture(rd, half_size, PACKED_FORMAT),
			_create_texture(rd, half_size, PACKED_FORMAT),
		],
		"ubo": rd.uniform_buffer_create(UBO_SIZE),
		"read_index": 0,
		"history_valid": false,
		"last_frame": -1,
		"has_camera": false,
	}
	if not state["raw"].is_valid() or not state["spatial"].is_valid() \
			or not state["history"][0].is_valid() or not state["history"][1].is_valid() \
			or not state["ubo"].is_valid():
		_free_view_state(rd, state)
		_report("Cannot allocate GTAO scratch and history textures.")
		return {}
	return state

func _create_texture(rd: RenderingDevice, size: Vector2i, data_format: int) -> RID:
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.format = data_format
	format.width = size.x
	format.height = size.y
	format.depth = 1
	format.array_layers = 1
	format.mipmaps = 1
	format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	return rd.texture_create(format, RDTextureView.new(), [])

func _prune_states(keep_key: int, rd: RenderingDevice) -> void:
	for other_key in _states.keys():
		if other_key == keep_key:
			continue
		var entry: Dictionary = _states[other_key]
		if entry["wr"].get_ref() == null:
			for state in entry["views"].values():
				_free_view_state(rd, state)
			_states.erase(other_key)

func _free_view_state(rd: RenderingDevice, state: Dictionary) -> void:
	for name in ["raw", "spatial", "ubo"]:
		var rid: RID = state.get(name, RID())
		if rid.is_valid():
			rd.free_rid(rid)
	for rid in state.get("history", []):
		if rid is RID and rid.is_valid():
			rd.free_rid(rid)

func _invalidate_buffer_history(buffers: RenderSceneBuffersRD) -> void:
	var entry: Dictionary = _states.get(buffers.get_instance_id(), {})
	if entry.is_empty():
		return
	for view in entry["views"].keys():
		var state: Dictionary = entry["views"][view]
		state["history_valid"] = false
		entry["views"][view] = state
	_states[buffers.get_instance_id()] = entry

func _valid_output_texture(texture: RID, buffers: RenderSceneBuffersRD) -> bool:
	if not texture.is_valid():
		return false
	var rd := RenderingServer.get_rendering_device()
	if rd == null or not rd.texture_is_valid(texture):
		return false
	var format := rd.texture_get_format(texture)
	var multi := buffers.get_view_count() > 1
	var expected := RenderingDevice.TEXTURE_TYPE_2D_ARRAY if multi else RenderingDevice.TEXTURE_TYPE_2D
	var size := buffers.get_internal_size()
	return format.texture_type == expected and format.format == OUTPUT_FORMAT \
			and (format.usage_bits & RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT) != 0 \
			and format.width == size.x and format.height == size.y \
			and (not multi or format.array_layers >= buffers.get_view_count())

func _setup(rd: RenderingDevice) -> void:
	super._setup(rd)
	for path in SHADER_PATHS:
		var shader_file := load(path) as RDShaderFile
		if shader_file == null:
			_report("GTAO shader is missing: " + path)
			_take_setup_rids(rd)
			return
		var spirv := shader_file.get_spirv()
		if spirv == null or spirv.compile_error_compute != "" or spirv.bytecode_compute.is_empty():
			_report("GTAO compute shader failed to compile: %s %s" % [path, spirv.compile_error_compute if spirv != null else ""])
			_take_setup_rids(rd)
			return
		var shader := rd.shader_create_from_spirv(spirv)
		if not shader.is_valid():
			_report("Cannot create GTAO shader: " + path)
			_take_setup_rids(rd)
			return
		var pipeline := rd.compute_pipeline_create(shader)
		if not pipeline.is_valid():
			rd.free_rid(shader)
			_report("Cannot create GTAO compute pipeline: " + path)
			_take_setup_rids(rd)
			return
		_shaders.append(shader)
		_pipelines.append(pipeline)
	var sampler_state := RDSamplerState.new()
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_nearest_sampler = rd.sampler_create(sampler_state)
	if not _nearest_sampler.is_valid():
		_report("Cannot create GTAO samplers.")
		_take_setup_rids(rd)
		return
	if not _ensure_zero_velocity(rd).is_valid():
		_report("Cannot create the neutral GTAO motion texture.")
		_take_setup_rids(rd)
		return
	_sync_owned_rid_snapshot()

func _take_setup_rids(rd: RenderingDevice) -> void:
	for rid in _pipelines:
		if rid.is_valid():
			rd.free_rid(rid)
	for rid in _shaders:
		if rid.is_valid():
			rd.free_rid(rid)
	_pipelines.clear()
	_shaders.clear()
	for rid in [_nearest_sampler, _zero_velocity_texture]:
		if rid.is_valid():
			rd.free_rid(rid)
	_nearest_sampler = RID()
	_zero_velocity_texture = RID()
	_sync_owned_rid_snapshot()

func _ensure_zero_velocity(rd: RenderingDevice) -> RID:
	if _zero_velocity_texture.is_valid():
		return _zero_velocity_texture
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.format = PACKED_FORMAT
	format.width = 1
	format.height = 1
	format.depth = 1
	format.array_layers = 1
	format.mipmaps = 1
	format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var zero_velocity := PackedByteArray()
	# One RGBA16F texel occupies eight bytes.
	zero_velocity.resize(8)
	_zero_velocity_texture = rd.texture_create(format, RDTextureView.new(), [zero_velocity])
	return _zero_velocity_texture

func _uniform_set(shader: RID, uniforms: Array[RDUniform]) -> RID:
	return UniformSetCacheRD.get_cache(shader, 0, uniforms)

func _sampled(binding: int, texture: RID, sampler: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform.binding = binding
	uniform.add_id(sampler)
	uniform.add_id(texture)
	return uniform

func _image(binding: int, texture: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = binding
	uniform.add_id(texture)
	return uniform

func _ubo(binding: int, buffer: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	uniform.binding = binding
	uniform.add_id(buffer)
	return uniform

func _current_owned_rids() -> Array[RID]:
	var rids: Array[RID] = []
	for entry in _states.values():
		for state in entry["views"].values():
			for name in ["raw", "spatial", "ubo"]:
				var rid: RID = state.get(name, RID())
				if rid.is_valid():
					rids.append(rid)
			for rid in state.get("history", []):
				if rid is RID and rid.is_valid():
					rids.append(rid)
	rids.append_array(_pipelines)
	rids.append_array(_shaders)
	rids.append_array([_nearest_sampler, _zero_velocity_texture])
	return rids

func _sync_owned_rid_snapshot() -> void:
	_replace_owned_rid_snapshot(_current_owned_rids())

func _take_owned_rids() -> Array[RID]:
	var owned_rids: Array[RID] = super.call("_current_owned_rids")
	_states.clear()
	_pipelines.clear()
	_shaders.clear()
	_nearest_sampler = RID()
	_zero_velocity_texture = RID()
	var rids := super._take_owned_rids()
	rids.append_array(owned_rids)
	return rids
