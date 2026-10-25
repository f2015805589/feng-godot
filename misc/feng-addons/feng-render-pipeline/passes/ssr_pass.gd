@tool
class_name FengSSRPass
extends "pass_base.gd"
## Screen-space reflection candidate for FRP. Publishes premultiplied hits and
## coverage for the internal Reflection Resolve; misses leave lower-priority
## configured candidates available.

const NativeSpec = preload("../pipeline/native_spec.gd")
const U = preload("../rd/uniforms.gd")
const PIPELINE_SCOPE: StringName = NativeSpec.SCOPE_PIPELINE
const OUTPUT_NAME: StringName = &"ssr_reflection"
const SHADER_DIR := "res://addons/feng-render-pipeline/library/ssr/"
const SHADER_NAMES := ["ssr_copy", "ssr_hiz_base", "ssr_hiz_reduce", "ssr_trace", "ssr_temporal", "ssr_upsample"]
const GEOMETRY_SHADER_NAME := "ssr_geometry.glslinc"
const GEOMETRY_INCLUDE_MARKER := "// SSR_GEOMETRY_INCLUDE"
const HIZ_TRAVERSAL_SHADER_NAME := "ssr_hiz_traversal.glslinc"
const HIZ_TRAVERSAL_INCLUDE_MARKER := "// SSR_HIZ_TRAVERSAL_INCLUDE"
const UBO_SIZE := 384
const WORKGROUP_SIZE := 8
const HISTORY_LIFETIME_FRAMES := 180
const HALF_FORMAT := RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
const HIT_FORMAT := RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
const HIZ_FORMAT := RenderingDevice.DATA_FORMAT_R32G32_SFLOAT

enum ResolutionMode { HALF_RESOLUTION, FULL_RESOLUTION }

@export_group("Screen Space Reflections")
## Full resolution avoids the half-resolution receiver and trace grid.
## It uses more GPU time and history memory.
@export_enum("Half Resolution", "Full Resolution") var resolution_mode: int = ResolutionMode.HALF_RESOLUTION:
	set(value):
		resolution_mode = clampi(value, ResolutionMode.HALF_RESOLUTION, ResolutionMode.FULL_RESOLUTION)
		emit_changed()
@export_range(8, 128, 1) var max_steps := 48:
	set(value):
		max_steps = clampi(value, 8, 128)
		emit_changed()
@export_range(1.0, 500.0, 0.5, "or_greater", "suffix:m") var max_distance := 80.0:
	set(value):
		max_distance = maxf(value, 1.0)
		emit_changed()
## Caps the visible-surface plane residual accepted for a reflection hit.
@export_range(0.001, 2.0, 0.001, "or_greater", "suffix:m") var thickness := 0.12:
	set(value):
		thickness = maxf(value, 0.001)
		emit_changed()
@export_range(0.0, 1.0, 0.01) var max_roughness := 0.65:
	set(value):
		max_roughness = clampf(value, 0.0, 1.0)
		emit_changed()
@export_range(0.0, 0.95, 0.01) var history_weight := 0.95:
	set(value):
		history_weight = clampf(value, 0.0, 0.95)
		emit_changed()
@export_range(0.0, 4.0, 0.01) var intensity := 1.0:
	set(value):
		intensity = clampf(value, 0.0, 4.0)
		emit_changed()
@export_group("")

var _shaders: Array[RID] = []
var _pipelines: Array[RID] = []
var _nearest_sampler := RID()
var _linear_sampler := RID()
var _zero_velocity_texture := RID()
var _hiz_format_supported := false
var _hit_format_supported := false
var _states: Dictionary = {}
var _frame_context: FRPPassContext
var _frame_parameters: Dictionary = {}
var _frame_scene_data: RenderSceneData
var _frame_buffers: RenderSceneBuffersRD
var _frame_enabled := false

func _init() -> void:
	inputs = _make_inputs()
	outputs = _make_outputs()
	stage = EFFECT_CALLBACK_TYPE_POST_LIGHTING
	needs_motion_vectors = true

func _make_inputs() -> Array[TextureInput]:
	var declarations: Array[TextureInput] = []
	for binding in 8:
		var input := TextureInput.new()
		input.binding = binding
		match binding:
			0: input.source = TextureInput.Source.COLOR
			1: input.source = TextureInput.Source.DEPTH
			2: input.source = TextureInput.Source.NORMAL_ROUGHNESS
			3: input.source = TextureInput.Source.ALBEDO
			4: input.source = TextureInput.Source.ORM
			5: input.source = TextureInput.Source.EMISSION
			6: input.source = TextureInput.Source.INDIRECT_SPECULAR
			7: input.source = TextureInput.Source.MOTION_VECTORS
		declarations.append(input)
	return declarations

func _make_outputs() -> Array[OutputDeclaration]:
	var reflection := OutputDeclaration.new()
	reflection.name = OUTPUT_NAME
	reflection.data_format = HALF_FORMAT
	reflection.usage = OutputDeclaration.Usage.SAMPLED | OutputDeclaration.Usage.STORAGE | OutputDeclaration.Usage.COPY_TO
	reflection.scale = Vector2.ONE
	return [reflection]

func ensure_frp_contract() -> bool:
	var changed := false
	if not _inputs_match(inputs, _make_inputs()):
		inputs = _make_inputs()
		changed = true
	if not _outputs_match(outputs, _make_outputs()):
		outputs = _make_outputs()
		changed = true
	needs_motion_vectors = true
	return changed

func get_required_before_native_ids() -> PackedInt32Array:
	return PackedInt32Array([NativeSpec.PASS_SKY, NativeSpec.PASS_TRANSPARENT,
			NativeSpec.PASS_TEMPORAL_AA, NativeSpec.PASS_BLOOM, NativeSpec.PASS_POST_PROCESS])

func get_reflection_source_kind() -> StringName:
	return &"ssr"

func get_volume_parameter_names() -> PackedStringArray:
	return PackedStringArray(["resolution_mode", "max_steps", "max_distance", "thickness", "max_roughness",
			"history_weight", "intensity"])

func refresh_resource_flags() -> void:
	needs_motion_vectors = true
	super.refresh_resource_flags()

func _validate_runtime_inputs(buffers: RenderSceneBuffersRD, view: int) -> bool:
	# Motion vectors improve history stability but are optional on render paths that
	# cannot produce them. All lighting and material inputs remain mandatory.
	for index in inputs.size():
		if index == 7:
			continue
		var declaration: TextureInput = inputs[index]
		if declaration == null or not declaration.get_texture(buffers, view).is_valid():
			var binding := declaration.binding if declaration != null else index
			_report("SSR input is unavailable for binding %d." % binding)
			return false
	return true

func _frp_prepare(ctx: FRPPassContext) -> void:
	_frame_enabled = ctx != null
	if _frame_enabled:
		# The scene-color snapshot must include the separate-specular sidecar when
		# SSS routes specular into its own target. The reflection resolver requests
		# the same native inputs for its final fallback.
		ctx.request_indirect_specular()

func _frp_execute(ctx: FRPPassContext) -> void:
	var rd := RenderingServer.get_rendering_device()
	var buffers := ctx.get_render_scene_buffers() as RenderSceneBuffersRD if ctx != null else null
	if rd == null or buffers == null:
		_frame_enabled = false
		return
	if not ctx.is_reflection_components_available():
		_clear_outputs(rd, buffers)
		_invalidate_buffer_history(buffers)
		_frame_enabled = false
		return
	_sweep_idle_states(rd)
	if not _frame_enabled:
		_clear_outputs(rd, buffers)
		_invalidate_buffer_history(buffers)
		_frame_enabled = false
		return
	var render_data := ctx.get_render_data()
	if render_data == null:
		_clear_outputs(rd, buffers)
		_frame_enabled = false
		return
	_frame_context = ctx
	_frame_buffers = buffers
	_frame_scene_data = render_data.get_render_scene_data() as RenderSceneData
	_frame_parameters = get_resolved_parameters(ctx)
	if _frame_scene_data != null:
		super._frp_execute(ctx)
	else:
		_clear_outputs(rd, buffers)
	_frame_context = null
	_frame_buffers = null
	_frame_scene_data = null
	_frame_parameters.clear()
	_frame_enabled = false

func _clear_outputs(rd: RenderingDevice, buffers: RenderSceneBuffersRD) -> void:
	for view in buffers.get_view_count():
		var output := buffers.get_texture_slice(PIPELINE_SCOPE, OUTPUT_NAME, view, 0, 1, 1)
		_clear_output(rd, output)

func _clear_output(rd: RenderingDevice, output: RID) -> void:
	if output.is_valid():
		rd.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)

func _render(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice) -> void:
	if _frame_context == null or _frame_scene_data == null:
		return
	var output := buffers.get_texture_slice(PIPELINE_SCOPE, OUTPUT_NAME, view, 0, 1, 1)
	if _shaders.size() != SHADER_NAMES.size() or _pipelines.size() != SHADER_NAMES.size() \
			or not _hiz_format_supported or not _hit_format_supported or inputs.size() != 8:
		_clear_output(rd, output)
		return
	var textures: Array[RID] = []
	for declaration in inputs:
		textures.append(declaration.get_texture(buffers, view))
	var valid_inputs := true
	for index in range(0, 7):
		if not textures[index].is_valid():
			valid_inputs = false
			break
	if not valid_inputs or not output.is_valid():
		_clear_output(rd, output)
		return
	var size := buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0:
		_clear_output(rd, output)
		return
	var half_size := Vector2i(maxi(1, ceili(float(size.x) * 0.5)), maxi(1, ceili(float(size.y) * 0.5)))
	var selected_resolution_mode := clampi(int(_frame_parameters.get("resolution_mode", resolution_mode)),
			ResolutionMode.HALF_RESOLUTION, ResolutionMode.FULL_RESOLUTION)
	var working_size := size if selected_resolution_mode == ResolutionMode.FULL_RESOLUTION else half_size
	var state := _ensure_view_state(buffers, view, size, working_size, rd)
	if state.is_empty():
		_clear_output(rd, output)
		return
	var velocity: RID = textures[7]
	var has_motion := velocity.is_valid()
	if not has_motion:
		velocity = _ensure_zero_velocity(rd)
		if not velocity.is_valid():
			_clear_output(rd, output)
			return
	var specular_sidecar := _frame_context.get_indirect_specular_composite_target(view)
	if not specular_sidecar.is_valid():
		_clear_output(rd, output)
		return
	var color_target: RID = buffers.get_color_layer(view)
	if not color_target.is_valid():
		_clear_output(rd, output)
		return
	var is_separate_specular := specular_sidecar != color_target
	var output_slice := output
	var frame := _frame_context.get_volume_frame_inputs(view)
	var near_plane := float(frame.get("near_plane_m", 0.05))
	var far_plane := float(frame.get("far_plane_m", maxf(near_plane + 1.0, max_distance)))
	if not is_finite(near_plane) or not is_finite(far_plane) \
			or near_plane <= 0.0 or far_plane <= near_plane:
		_report("SSR received invalid view clipping planes.")
		_clear_output(rd, output)
		state["valid"] = false
		return
	var projection: Projection = frame.get("projection", _frame_scene_data.get_view_projection(view))
	var inverse_projection: Projection = frame.get("inverse_projection", projection.inverse())
	var camera_transform: Transform3D = frame.get("camera_transform", _frame_scene_data.get_cam_transform())
	var generation := int(frame.get("frame_generation", Engine.get_frames_drawn()))
	var jitter: Vector2 = _frame_context.get_taa_jitter()
	var previous_jitter: Vector2 = state.get("taa_jitter", jitter)
	var jitter_delta := (previous_jitter - jitter) * 0.5
	var camera_cut := bool(frame.get("camera_cut", false)) or _is_camera_cut(state,
			camera_transform, projection, generation)
	var valid_history := bool(state.get("valid", false)) and not camera_cut \
			and has_motion and int(state.get("generation", -2)) + 1 == generation
	var previous_exposure := maxf(float(state.get("exposure", 1.0)), 1e-6)
	var current_exposure := float(frame.get("pre_exposure", 1.0)) \
			* float(frame.get("scene_normalization", 1.0))
	if not is_finite(current_exposure) or current_exposure <= 0.0:
		current_exposure = 1.0
	var exposure_ratio := current_exposure / previous_exposure
	var previous_camera_transform: Transform3D = state.get("camera_transform", camera_transform)
	var previous_projection: Projection = state.get("projection", projection)
	var params_bytes := _make_parameter_bytes(size, inverse_projection, projection, jitter_delta,
			exposure_ratio, valid_history, has_motion, generation, is_separate_specular,
			camera_transform, previous_camera_transform, previous_projection)
	if rd.buffer_update(state["ubo"], 0, params_bytes.size(), params_bytes) != OK:
		_report("Cannot update SSR frame parameters.")
		_clear_output(rd, output)
		return
	var history: Array = state["history"]
	var read_index := int(state["read_index"])
	var write_index := 1 - read_index
	var previous_history: Array = history[read_index]
	var next_history: Array = history[write_index]
	var dfg_value: Variant = frame.get("dfg_texture", RID())
	if not dfg_value is RID or not dfg_value.is_valid():
		_report("The native DFG LUT is unavailable; SSR publishes no reflection candidate.")
		_clear_output(rd, output)
		state["valid"] = false
		return
	var dfg: RID = dfg_value
	var copy_set := _uniform_set(_shaders[0], [
		_sampled(0, textures[0]), _sampled(1, specular_sidecar),
		_image(2, state["color_copy"]), _ubo(3, state["ubo"]),
	])
	var hiz_base_set := _uniform_set(_shaders[1], [
		_sampled(0, textures[1]), _image(1, state["hiz_mip_views"][0]),
		_ubo(2, state["ubo"]),
	])
	var hiz_reduce_sets: Array[RID] = []
	var hiz_reduce_sizes: Array[Vector2i] = []
	for mip in range(1, state["hiz_mip_views"].size()):
		var source_view: RID = state["hiz_source_views"][mip - 1]
		var destination_view: RID = state["hiz_mip_views"][mip]
		hiz_reduce_sets.append(_uniform_set(_shaders[2], [
			_sampled(0, source_view), _image(1, destination_view),
		]))
		hiz_reduce_sizes.append(Vector2i(maxi(1, size.x >> mip), maxi(1, size.y >> mip)))
	var trace_set := _uniform_set(_shaders[3], [
		_sampled(0, textures[1]), _sampled(1, textures[2]), _sampled(2, textures[3]),
		_sampled(3, textures[4]), _sampled(4, textures[5]), _sampled(5, state["color_copy"]),
		_linear_sampled(6, dfg), _image(7, state["raw"]), _image(8, state["raw_receiver"]),
		_image(9, state["raw_hit"]), _image(10, state["raw_material"]),
		_image(11, state["raw_previous_hit"]), _ubo(12, state["ubo"]),
		_sampled(13, state["hiz"]), _sampled(14, velocity),
	])
	var temporal_set := _uniform_set(_shaders[4], [
		_sampled(0, state["raw"]), _sampled(1, state["raw_receiver"]), _sampled(2, state["raw_hit"]),
		_sampled(3, state["raw_material"]), _sampled(4, velocity),
		_sampled(5, previous_history[0]), _sampled(6, previous_history[1]),
		_sampled(7, previous_history[2]), _sampled(8, previous_history[3]),
		_image(9, next_history[0]), _image(10, next_history[1]), _image(11, next_history[2]),
		_image(12, next_history[3]), _sampled(14, textures[1]),
		_sampled(15, state["raw_previous_hit"]), _ubo(16, state["ubo"]),
	])
	var upsample_set := _uniform_set(_shaders[5], [
		_sampled(0, next_history[1]), _sampled(1, next_history[3]), _sampled(2, next_history[0]),
		_sampled(3, textures[1]), _sampled(4, textures[2]), _sampled(5, textures[3]),
		_sampled(6, textures[4]), _sampled(7, textures[5]), _image(8, output_slice),
		_ubo(9, state["ubo"]),
	])
	var reduction_sets_valid := true
	for uniform_set in hiz_reduce_sets:
		if not uniform_set.is_valid():
			reduction_sets_valid = false
			break
	if not reduction_sets_valid:
		_report("SSR HiZ reduction bindings do not match their mip layout.")
		_clear_output(rd, output)
		state["valid"] = false
		return
	for uniform_set in [copy_set, hiz_base_set, trace_set, temporal_set, upsample_set]:
		if not uniform_set.is_valid():
			_report("SSR shader bindings do not match the declared texture contract.")
			_clear_output(rd, output)
			state["valid"] = false
			return
	var list := rd.compute_list_begin()
	if list < 0:
		_report("Cannot begin the SSR compute list.")
		_clear_output(rd, output)
		return
	rd.compute_list_bind_compute_pipeline(list, _pipelines[0])
	rd.compute_list_bind_uniform_set(list, copy_set, 0)
	rd.compute_list_dispatch(list, ceili(float(size.x) / WORKGROUP_SIZE), ceili(float(size.y) / WORKGROUP_SIZE), 1)
	rd.compute_list_add_barrier(list)
	rd.compute_list_bind_compute_pipeline(list, _pipelines[1])
	rd.compute_list_bind_uniform_set(list, hiz_base_set, 0)
	rd.compute_list_dispatch(list, ceili(float(size.x) / WORKGROUP_SIZE), ceili(float(size.y) / WORKGROUP_SIZE), 1)
	rd.compute_list_add_barrier(list)
	for reduction_index in hiz_reduce_sets.size():
		rd.compute_list_bind_compute_pipeline(list, _pipelines[2])
		rd.compute_list_bind_uniform_set(list, hiz_reduce_sets[reduction_index], 0)
		var mip := reduction_index + 1
		rd.compute_list_set_push_constant(list,
				PackedInt32Array([mip - 1, 0, 0, 0]).to_byte_array(), 16)
		var reduction_size: Vector2i = hiz_reduce_sizes[reduction_index]
		rd.compute_list_dispatch(list, ceili(float(reduction_size.x) / WORKGROUP_SIZE),
				ceili(float(reduction_size.y) / WORKGROUP_SIZE), 1)
		rd.compute_list_add_barrier(list)
	rd.compute_list_bind_compute_pipeline(list, _pipelines[3])
	rd.compute_list_bind_uniform_set(list, trace_set, 0)
	rd.compute_list_set_push_constant(list,
			PackedFloat32Array([near_plane, far_plane, 0.0, 0.0]).to_byte_array(), 16)
	rd.compute_list_dispatch(list, ceili(float(working_size.x) / WORKGROUP_SIZE),
			ceili(float(working_size.y) / WORKGROUP_SIZE), 1)
	rd.compute_list_end()
	list = rd.compute_list_begin()
	if list < 0:
		_report("Cannot begin the SSR temporal compute list.")
		_clear_output(rd, output)
		state["valid"] = false
		return
	rd.compute_list_bind_compute_pipeline(list, _pipelines[4])
	rd.compute_list_bind_uniform_set(list, temporal_set, 0)
	rd.compute_list_dispatch(list, ceili(float(working_size.x) / WORKGROUP_SIZE),
			ceili(float(working_size.y) / WORKGROUP_SIZE), 1)
	rd.compute_list_add_barrier(list)
	rd.compute_list_bind_compute_pipeline(list, _pipelines[5])
	rd.compute_list_bind_uniform_set(list, upsample_set, 0)
	rd.compute_list_dispatch(list, ceili(float(size.x) / WORKGROUP_SIZE), ceili(float(size.y) / WORKGROUP_SIZE), 1)
	rd.compute_list_end()
	_frame_context.publish_reflection_candidate(&"ssr", output_slice, view)
	state["read_index"] = write_index
	state["valid"] = true
	state["generation"] = generation
	state["exposure"] = current_exposure
	state["camera_transform"] = camera_transform
	state["projection"] = projection
	state["taa_jitter"] = jitter
	state["last_seen"] = Engine.get_frames_drawn()
	_states[buffers.get_instance_id()]["views"][view] = state
	_sync_owned_rid_snapshot()
	_clear_report()

func _make_parameter_bytes(size: Vector2i, inverse_projection: Projection, projection: Projection,
		jitter_delta: Vector2, exposure_ratio: float, valid_history: bool,
		has_motion: bool, generation: int, separate_specular: bool,
		camera_transform: Transform3D, previous_camera_transform: Transform3D,
		previous_projection: Projection) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.append_array(_matrix_bytes(inverse_projection))
	bytes.append_array(_matrix_bytes(projection))
	bytes.append_array(PackedFloat32Array([float(size.x), float(size.y), jitter_delta.x, jitter_delta.y]).to_byte_array())
	bytes.append_array(PackedFloat32Array([
			_finite_option("max_distance", max_distance, 1.0, 500.0),
			_finite_option("thickness", thickness, 0.001, 2.0),
			0.06,
			_finite_option("max_roughness", max_roughness, 0.0, 1.0),
	]).to_byte_array())
	var ratio := exposure_ratio if is_finite(exposure_ratio) and exposure_ratio > 0.0 else 1.0
	bytes.append_array(PackedFloat32Array([
			_finite_option("history_weight", history_weight, 0.0, 0.95),
			clampf(ratio, 0.05, 20.0),
			1.0 if valid_history else 0.0,
			1.0 if has_motion else 0.0,
	]).to_byte_array())
	bytes.append_array(PackedFloat32Array([
			float(clampi(int(_frame_parameters.get("max_steps", max_steps)), 8, 128)),
			float(generation % 65536),
			_finite_option("intensity", intensity, 0.0, 4.0),
			1.0 if separate_specular else 0.0,
	]).to_byte_array())
	bytes.append_array(_matrix_bytes(Projection(camera_transform)))
	bytes.append_array(_matrix_bytes(Projection(previous_camera_transform.affine_inverse())))
	bytes.append_array(_matrix_bytes(previous_projection))
	return bytes

func _finite_option(name: String, fallback: float, minimum: float, maximum: float) -> float:
	var value := float(_frame_parameters.get(name, fallback))
	if not is_finite(value):
		value = fallback
	return clampf(value, minimum, maximum)

func _matrix_bytes(matrix: Projection) -> PackedByteArray:
	var values := PackedFloat32Array()
	for column in 4:
		var axis: Vector4 = matrix[column]
		values.append_array(PackedFloat32Array([axis.x, axis.y, axis.z, axis.w]))
	return values.to_byte_array()

func _is_camera_cut(state: Dictionary, transform: Transform3D, projection: Projection,
		generation: int) -> bool:
	if not bool(state.get("valid", false)):
		return true
	if int(state.get("generation", -2)) + 1 != generation:
		return true
	var old_transform: Transform3D = state.get("camera_transform", Transform3D.IDENTITY)
	if old_transform.origin.distance_to(transform.origin) > 2.0:
		return true
	var old_rotation := old_transform.basis.orthonormalized().get_rotation_quaternion()
	var new_rotation := transform.basis.orthonormalized().get_rotation_quaternion()
	if old_rotation.angle_to(new_rotation) > deg_to_rad(35.0):
		return true
	var old_projection: Projection = state.get("projection", projection)
	var delta := 0.0
	for column in 4:
		var a: Vector4 = old_projection[column]
		var b: Vector4 = projection[column]
		delta = maxf(delta, absf(a.x - b.x))
		delta = maxf(delta, absf(a.y - b.y))
		delta = maxf(delta, absf(a.z - b.z))
		delta = maxf(delta, absf(a.w - b.w))
	return delta > 0.25

func _ensure_view_state(buffers: RenderSceneBuffersRD, view: int, full_size: Vector2i,
		working_size: Vector2i, rd: RenderingDevice) -> Dictionary:
	var key := buffers.get_instance_id()
	var entry: Dictionary = _states.get(key, {})
	if not entry.is_empty() and entry["wr"].get_ref() == null:
		for old in entry["views"].values():
			_free_view_state(rd, old)
		_states.erase(key)
		entry = {}
	if entry.is_empty():
		entry = {"wr": weakref(buffers), "views": {}}
		_states[key] = entry
	var state: Dictionary = entry["views"].get(view, {})
	if not state.is_empty() and (state["full_size"] != full_size or state["half_size"] != working_size):
		_free_view_state(rd, state)
		entry["views"].erase(view)
		state = {}
	if state.is_empty():
		state = _create_view_state(full_size, working_size, rd)
		if state.is_empty():
			_sync_owned_rid_snapshot()
			return {}
		entry["views"][view] = state
		_states[key] = entry
	_sync_owned_rid_snapshot()
	return state

func _create_view_state(full_size: Vector2i, working_size: Vector2i,
		rd: RenderingDevice) -> Dictionary:
	if not _hiz_format_supported or not _hit_format_supported:
		return {}
	var state := {
		"full_size": full_size,
		"half_size": working_size,
		"hiz": RID(),
		"hiz_mip_views": [],
		"hiz_source_views": [],
		"color_copy": _create_texture(rd, full_size, HALF_FORMAT),
		"raw": _create_texture(rd, working_size, HALF_FORMAT),
		"raw_receiver": _create_texture(rd, working_size, HALF_FORMAT),
		"raw_hit": _create_texture(rd, working_size, HIT_FORMAT),
		"raw_material": _create_texture(rd, working_size, HALF_FORMAT),
		"raw_previous_hit": _create_texture(rd, working_size, HALF_FORMAT),
		"history": [
			[_create_texture(rd, working_size, HALF_FORMAT), _create_texture(rd, working_size, HALF_FORMAT), _create_texture(rd, working_size, HIT_FORMAT), _create_texture(rd, working_size, HALF_FORMAT)],
			[_create_texture(rd, working_size, HALF_FORMAT), _create_texture(rd, working_size, HALF_FORMAT), _create_texture(rd, working_size, HIT_FORMAT), _create_texture(rd, working_size, HALF_FORMAT)],
		],
		"ubo": rd.uniform_buffer_create(UBO_SIZE),
		"read_index": 0,
		"valid": false,
		"generation": -1,
		"exposure": 1.0,
		"last_seen": Engine.get_frames_drawn(),
	}
	if not _create_hiz_resources(state, full_size, rd):
		_free_view_state(rd, state)
		_report("Cannot allocate the SSR linear-depth HiZ chain.")
		return {}
	for rid in _state_rids(state, true):
		if not rid.is_valid():
			_free_view_state(rd, state)
			_report("Cannot allocate SSR scratch and history textures.")
			return {}
	return state

func _state_rids(state: Dictionary, include_invalid: bool = false) -> Array[RID]:
	var rids: Array[RID] = []
	for name in ["hiz_source_views", "hiz_mip_views"]:
		for view in state.get(name, []):
			if view is RID and (include_invalid or view.is_valid()):
				rids.append(view)
	for name in ["color_copy", "raw", "raw_receiver", "raw_hit", "raw_material", "raw_previous_hit"]:
		var rid: RID = state.get(name, RID())
		if include_invalid or rid.is_valid():
			rids.append(rid)
	for group in state.get("history", []):
		for rid in group:
			if rid is RID and (include_invalid or rid.is_valid()):
				rids.append(rid)
	var hiz: RID = state.get("hiz", RID())
	if include_invalid or hiz.is_valid():
		rids.append(hiz)
	var ubo: RID = state.get("ubo", RID())
	if include_invalid or ubo.is_valid():
		rids.append(ubo)
	return rids

func _create_hiz_resources(state: Dictionary, size: Vector2i,
		rd: RenderingDevice) -> bool:
	if not _hiz_format_supported or size.x <= 0 or size.y <= 0:
		return false
	var mip_count := 1
	var mip_size := size
	while mip_size.x > 1 or mip_size.y > 1:
		mip_size = Vector2i(maxi(1, mip_size.x >> 1), maxi(1, mip_size.y >> 1))
		mip_count += 1
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.format = HIZ_FORMAT
	format.width = size.x
	format.height = size.y
	format.depth = 1
	format.array_layers = 1
	format.mipmaps = mip_count
	format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	state["hiz"] = rd.texture_create(format, RDTextureView.new())
	if not state["hiz"].is_valid():
		return false
	for mip in mip_count:
		var mip_view := rd.texture_create_shared_from_slice(RDTextureView.new(),
				state["hiz"], 0, mip, 1, RenderingDevice.TEXTURE_SLICE_2D)
		if not mip_view.is_valid():
			return false
		state["hiz_mip_views"].append(mip_view)
	for mip in range(1, mip_count):
		var source_prefix := rd.texture_create_shared_from_slice(RDTextureView.new(),
				state["hiz"], 0, 0, mip, RenderingDevice.TEXTURE_SLICE_2D)
		if not source_prefix.is_valid():
			return false
		state["hiz_source_views"].append(source_prefix)
	return true

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
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	var texture := rd.texture_create(format, RDTextureView.new())
	if texture.is_valid():
		rd.texture_clear(texture, Color(0, 0, 0, 0), 0, 1, 0, 1)
	return texture

func _free_view_state(rd: RenderingDevice, state: Dictionary) -> void:
	var ubo: RID = state.get("ubo", RID())
	for rid in _state_rids(state):
		if rid == ubo:
			if rid.is_valid():
				rd.free_rid(rid)
		elif rd.texture_is_valid(rid):
			rd.free_rid(rid)
	state.clear()

func _invalidate_buffer_history(buffers: RenderSceneBuffersRD) -> void:
	var entry: Dictionary = _states.get(buffers.get_instance_id(), {})
	if entry.is_empty():
		return
	for view in entry["views"].keys():
		var state: Dictionary = entry["views"][view]
		state["valid"] = false
		entry["views"][view] = state
	_states[buffers.get_instance_id()] = entry

func _sweep_idle_states(rd: RenderingDevice) -> void:
	var frame := Engine.get_frames_drawn()
	var remove_keys: Array = []
	var removed_any := false
	for key in _states.keys():
		var entry: Dictionary = _states[key]
		if entry["wr"].get_ref() == null:
			for state in entry["views"].values():
				_free_view_state(rd, state)
			remove_keys.append(key)
			removed_any = true
			continue
		for view in entry["views"].keys():
			var state: Dictionary = entry["views"][view]
			if frame - int(state.get("last_seen", frame)) > HISTORY_LIFETIME_FRAMES:
				_free_view_state(rd, state)
				entry["views"].erase(view)
				removed_any = true
		_states[key] = entry
	for key in remove_keys:
		_states.erase(key)
	if removed_any:
		_sync_owned_rid_snapshot()

func _ensure_zero_velocity(rd: RenderingDevice) -> RID:
	if _zero_velocity_texture.is_valid():
		return _zero_velocity_texture
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.format = HALF_FORMAT
	format.width = 1
	format.height = 1
	format.depth = 1
	format.array_layers = 1
	format.mipmaps = 1
	format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var zero := PackedByteArray()
	zero.resize(8)
	_zero_velocity_texture = rd.texture_create(format, RDTextureView.new(), [zero])
	return _zero_velocity_texture

func _setup(rd: RenderingDevice) -> void:
	super._setup(rd)
	var hiz_usage := RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	_hiz_format_supported = rd.texture_is_format_supported_for_usage(HIZ_FORMAT, hiz_usage)
	if not _hiz_format_supported:
		_report("SSR HiZ requires sampled and storage support for R32G32_SFLOAT.")
		_take_setup_rids(rd)
		return
	var hit_usage := RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	_hit_format_supported = rd.texture_is_format_supported_for_usage(HIT_FORMAT, hit_usage)
	if not _hit_format_supported:
		_report("SSR hit history requires sampled, storage, and copy support for R32G32B32A32_SFLOAT.")
		_take_setup_rids(rd)
		return
	var geometry_source := FileAccess.get_file_as_string(SHADER_DIR + GEOMETRY_SHADER_NAME)
	if geometry_source.is_empty():
		_report("SSR geometry shader is missing: " + GEOMETRY_SHADER_NAME)
		_take_setup_rids(rd)
		return
	var traversal_source := FileAccess.get_file_as_string(SHADER_DIR + HIZ_TRAVERSAL_SHADER_NAME)
	if traversal_source.is_empty():
		_report("SSR HiZ traversal shader is missing: " + HIZ_TRAVERSAL_SHADER_NAME)
		_take_setup_rids(rd)
		return
	for shader_name in SHADER_NAMES:
		var source := RDShaderSource.new()
		var shader_source := FileAccess.get_file_as_string(SHADER_DIR + shader_name + ".glslinc")
		if shader_source.is_empty():
			_report("SSR shader is missing: " + shader_name)
			_take_setup_rids(rd)
			return
		if shader_name in ["ssr_hiz_base", "ssr_trace", "ssr_temporal"]:
			var marker_position := shader_source.find(GEOMETRY_INCLUDE_MARKER)
			var duplicate_marker_position := -1
			if marker_position >= 0:
				duplicate_marker_position = shader_source.find(GEOMETRY_INCLUDE_MARKER,
						marker_position + GEOMETRY_INCLUDE_MARKER.length())
			if marker_position < 0 or duplicate_marker_position >= 0:
				_report("SSR geometry include marker is missing or duplicated: " + shader_name)
				_take_setup_rids(rd)
				return
			shader_source = shader_source.replace(GEOMETRY_INCLUDE_MARKER, geometry_source)
		if shader_name == "ssr_trace":
			var traversal_marker_position := shader_source.find(HIZ_TRAVERSAL_INCLUDE_MARKER)
			var duplicate_traversal_marker_position := -1
			if traversal_marker_position >= 0:
				duplicate_traversal_marker_position = shader_source.find(
						HIZ_TRAVERSAL_INCLUDE_MARKER,
						traversal_marker_position + HIZ_TRAVERSAL_INCLUDE_MARKER.length())
			if traversal_marker_position < 0 or duplicate_traversal_marker_position >= 0:
				_report("SSR HiZ traversal include marker is missing or duplicated.")
				_take_setup_rids(rd)
				return
			shader_source = shader_source.replace(HIZ_TRAVERSAL_INCLUDE_MARKER, traversal_source)
		source.source_compute = shader_source
		var spirv := rd.shader_compile_spirv_from_source(source)
		if not spirv.compile_error_compute.is_empty():
			_report("SSR shader compile failed (%s): %s" % [shader_name, spirv.compile_error_compute])
			_take_setup_rids(rd)
			return
		var shader := rd.shader_create_from_spirv(spirv, "FengSSR_" + shader_name)
		if not shader.is_valid():
			_report("Cannot create SSR shader: " + shader_name)
			_take_setup_rids(rd)
			return
		var pipeline := rd.compute_pipeline_create(shader)
		if not pipeline.is_valid():
			rd.free_rid(shader)
			_report("Cannot create SSR pipeline: " + shader_name)
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
		_report("Cannot create SSR sampler.")
		_take_setup_rids(rd)
		return
	var linear_sampler_state := RDSamplerState.new()
	linear_sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	linear_sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	linear_sampler_state.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	linear_sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	linear_sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	linear_sampler_state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_linear_sampler = rd.sampler_create(linear_sampler_state)
	if not _linear_sampler.is_valid():
		_report("Cannot create SSR DFG sampler.")
		_take_setup_rids(rd)
		return
	if not _ensure_zero_velocity(rd).is_valid():
		_report("Cannot create neutral SSR motion texture.")
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
	for rid in [_nearest_sampler, _linear_sampler, _zero_velocity_texture]:
		if rid.is_valid():
			rd.free_rid(rid)
	_nearest_sampler = RID()
	_linear_sampler = RID()
	_zero_velocity_texture = RID()
	_hiz_format_supported = false
	_hit_format_supported = false
	_sync_owned_rid_snapshot()

func _uniform_set(shader: RID, uniforms: Array[RDUniform]) -> RID:
	return UniformSetCacheRD.get_cache(shader, 0, uniforms)

func _sampled(binding: int, texture: RID) -> RDUniform:
	return U.sampled(binding, _nearest_sampler, texture)

func _linear_sampled(binding: int, texture: RID) -> RDUniform:
	return U.sampled(binding, _linear_sampler, texture)

func _image(binding: int, texture: RID) -> RDUniform:
	return U.image(binding, texture)

func _ubo(binding: int, buffer: RID) -> RDUniform:
	return U.uniform_buffer(binding, buffer)

func _current_owned_rids() -> Array[RID]:
	var rids: Array[RID] = []
	for entry in _states.values():
		for state in entry["views"].values():
			rids.append_array(_state_rids(state))
	rids.append_array(_pipelines)
	rids.append_array(_shaders)
	rids.append_array([_nearest_sampler, _linear_sampler, _zero_velocity_texture])
	return rids

func _sync_owned_rid_snapshot() -> void:
	_replace_owned_rid_snapshot(_current_owned_rids())

func _take_owned_rids() -> Array[RID]:
	# During ordinary cleanup the derived fields are live, so return their RIDs and
	# reset the pass for a later setup. PREDELETE can suspend derived script dispatch;
	# in that case the base-owned snapshot is the only safe source of its RIDs.
	var states_value: Variant = super.call("get", "_states")
	if not states_value is Dictionary:
		return super._take_owned_rids()
	var rids: Array[RID] = []
	for entry_value in states_value.values():
		if not entry_value is Dictionary:
			continue
		var views_value: Variant = entry_value.get("views", {})
		if not views_value is Dictionary:
			continue
		for state_value in views_value.values():
			if not state_value is Dictionary:
				continue
			for name in ["hiz_source_views", "hiz_mip_views"]:
				var texture_views: Variant = state_value.get(name, [])
				if texture_views is Array:
					for view_rid in texture_views:
						if view_rid is RID and view_rid.is_valid():
							rids.append(view_rid)
			for name in ["color_copy", "raw", "raw_receiver", "raw_hit", "raw_material", "raw_previous_hit"]:
				var rid_value: Variant = state_value.get(name, RID())
				if rid_value is RID and rid_value.is_valid():
					rids.append(rid_value)
			for group_value in state_value.get("history", []):
				if not group_value is Array:
					continue
				for history_group_rid in group_value:
					if history_group_rid is RID and history_group_rid.is_valid():
						rids.append(history_group_rid)
			var hiz_value: Variant = state_value.get("hiz", RID())
			if hiz_value is RID and hiz_value.is_valid():
				rids.append(hiz_value)
			var ubo_value: Variant = state_value.get("ubo", RID())
			if ubo_value is RID and ubo_value.is_valid():
				rids.append(ubo_value)
	var pipelines_value: Variant = super.call("get", "_pipelines")
	if pipelines_value is Array:
		for pipeline_rid in pipelines_value:
			if pipeline_rid is RID and pipeline_rid.is_valid():
				rids.append(pipeline_rid)
	var shaders_value: Variant = super.call("get", "_shaders")
	if shaders_value is Array:
		for shader_rid in shaders_value:
			if shader_rid is RID and shader_rid.is_valid():
				rids.append(shader_rid)
	for name in ["_nearest_sampler", "_linear_sampler", "_zero_velocity_texture"]:
		var sampler_rid: Variant = super.call("get", name)
		if sampler_rid is RID and sampler_rid.is_valid():
			rids.append(sampler_rid)
	states_value.clear()
	var pipelines_clear: Variant = super.call("get", "_pipelines")
	if pipelines_clear is Array:
		pipelines_clear.clear()
	var shaders_clear: Variant = super.call("get", "_shaders")
	if shaders_clear is Array:
		shaders_clear.clear()
	super.call("set", "_nearest_sampler", RID())
	super.call("set", "_linear_sampler", RID())
	super.call("set", "_zero_velocity_texture", RID())
	var base_rids := super._take_owned_rids()
	base_rids.append_array(rids)
	return base_rids

