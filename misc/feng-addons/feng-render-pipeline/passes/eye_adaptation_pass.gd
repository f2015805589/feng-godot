@tool
class_name FengEyeAdaptationPass
extends "pass_base.gd"
## UE 5.7 eye adaptation. This pass owns the extended luminance and
## pre-exposure switches; Volumes own the camera exposure settings.

const HISTOGRAM_SHADER := "res://addons/feng-render-pipeline/library/eye-adaptation/eye_adaptation_histogram.glsl"
const ADAPT_SHADER := "res://addons/feng-render-pipeline/library/eye-adaptation/eye_adaptation.glsl"
const PreviewExposure = preload("editor_preview_exposure_cache.gd")
const NUM_BINS := 64
const PARAMS_BYTES := NUM_BINS * 8 + 16 # 64 low/overflow histogram pairs and exposure state
const STATE_PRUNE_LIMIT := 16
const EXPOSURE_SOURCE_AUTOMATIC := 0
const EXPOSURE_SOURCE_CAMERA_ATTRIBUTES := 1
const EXPOSURE_SOURCE_PASS_SETTINGS := 2
const EXPOSURE_ROUTE_PASS_SETTINGS := 0
const EXPOSURE_ROUTE_CAMERA_ATTRIBUTES := 1
const INTERNAL_METERING_CAMERA_AUTO := 3
const INTERNAL_METERING_CAMERA_MANUAL := 4
## UE Scene.cpp keeps distinct defaults for the legacy and extended modes.
## The latter fields are EV100; with UE's default lens attenuation 0.78,
## EV100ToLuminance is exactly exp2(EV100).
@export_group("Eye Adaptation")
@export var extend_default_luminance_range := false:
	set(value):
		extend_default_luminance_range = value
		emit_changed()
@export var pre_exposure := true:
	set(value):
		pre_exposure = value
		emit_changed()
@export_group("Exposure")
## Automatic (default) always uses FRP Histogram auto metering. Camera Attributes
## uses the linked camera: its auto toggle selects camera metering or fixed
## exposure. Pass Settings uses this pass's metering, including Manual.
@export_enum("Automatic", "Camera Attributes", "Pass Settings") var exposure_source := EXPOSURE_SOURCE_AUTOMATIC:
	set(value):
		exposure_source = clampi(value, EXPOSURE_SOURCE_AUTOMATIC, EXPOSURE_SOURCE_PASS_SETTINGS)
		emit_changed()
@export_enum("Histogram", "Basic", "Manual") var metering_mode := 0:
	set(value):
		metering_mode = value
		emit_changed()
@export_group("Histogram Metering")
@export_range(1.0, 99.0, 0.1) var low_percent := 10.0:
	set(value):
		low_percent = value
		emit_changed()
@export_range(1.0, 99.0, 0.1) var high_percent := 90.0:
	set(value):
		high_percent = value
		emit_changed()
@export var min_brightness := 0.03:
	set(value):
		min_brightness = value
		emit_changed()
@export var max_brightness := 8.0:
	set(value):
		max_brightness = value
		emit_changed()
@export var min_ev100 := -10.0:
	set(value):
		min_ev100 = value
		emit_changed()
@export var max_ev100 := 20.0:
	set(value):
		max_ev100 = value
		emit_changed()
@export var speed_up := 3.0:
	set(value):
		speed_up = value
		emit_changed()
@export var speed_down := 1.0:
	set(value):
		speed_down = value
		emit_changed()
@export var exposure_compensation := 1.0:
	set(value):
		exposure_compensation = value
		emit_changed()
## CurveTexture's normalized X range maps to UE's default [-10, 20] EV100 LUT.
@export var exposure_compensation_curve: CurveTexture:
	set(value):
		exposure_compensation_curve = value
		emit_changed()
@export var metering_mask: Texture2D:
	set(value):
		metering_mask = value
		emit_changed()
@export var histogram_log_min := -8.0:
	set(value):
		histogram_log_min = value
		emit_changed()
@export var histogram_log_max := 4.0:
	set(value):
		histogram_log_max = value
		emit_changed()
@export var histogram_ev100_min := -10.0:
	set(value):
		histogram_ev100_min = value
		emit_changed()
@export var histogram_ev100_max := 20.0:
	set(value):
		histogram_ev100_max = value
		emit_changed()
@export_group("Manual Exposure")
@export var apply_physical_camera_exposure := true:
	set(value):
		apply_physical_camera_exposure = value
		emit_changed()
@export var aperture := 4.0:
	set(value):
		aperture = value
		emit_changed()
@export var shutter_speed := 60.0:
	set(value):
		shutter_speed = value
		emit_changed()
@export var iso := 100.0:
	set(value):
		iso = value
		emit_changed()
@export_group("")

var _histogram_pipeline := RID()
var _adapt_pipeline := RID()
var _shaders: Array[RID] = []
var _sampler := RID()
var _linear_sampler := RID()
# buffers instance id -> {"wr": WeakRef, "views": {view: {"params": RID, "last_usec": int}}}
var _state: Dictionary = {}
var _frame_parameters: Variant = null
var _frame_context: FRPPassContext

static func resolve_exposure_route(source: int, _has_volume_override: bool,
		has_camera_attributes: bool) -> int:
	var selected := clampi(source, EXPOSURE_SOURCE_AUTOMATIC, EXPOSURE_SOURCE_PASS_SETTINGS)
	if selected == EXPOSURE_SOURCE_CAMERA_ATTRIBUTES:
		return EXPOSURE_ROUTE_CAMERA_ATTRIBUTES if has_camera_attributes else EXPOSURE_ROUTE_PASS_SETTINGS
	# Automatic is the FRP histogram route. CameraAttributes are opt-in so a
	# linked resource with auto exposure disabled cannot silently freeze metering.
	return EXPOSURE_ROUTE_PASS_SETTINGS

static func resolve_exposure_method(source: int, route: int, camera_auto_enabled: bool,
		pass_metering_mode: int) -> int:
	if route == EXPOSURE_ROUTE_CAMERA_ATTRIBUTES:
		return INTERNAL_METERING_CAMERA_AUTO if camera_auto_enabled else INTERNAL_METERING_CAMERA_MANUAL
	if clampi(source, EXPOSURE_SOURCE_AUTOMATIC, EXPOSURE_SOURCE_PASS_SETTINGS) == EXPOSURE_SOURCE_AUTOMATIC:
		return 0 # Histogram
	return clampi(pass_metering_mode, 0, 2)

func _init() -> void:
	var color := TextureInput.new()
	color.binding = 0
	color.source = TextureInput.Source.COLOR
	color.binding_type = TextureInput.BindingType.SAMPLED_TEXTURE
	inputs = [color]

func ensure_frp_contract() -> bool:
	# Older saved Eye Adaptation resources declared Color as an image because
	# the pass used to apply exposure directly to HDR scene color.
	if inputs.size() != 1 or inputs[0] == null or inputs[0].binding_type == TextureInput.BindingType.SAMPLED_TEXTURE:
		return false
	inputs[0].binding_type = TextureInput.BindingType.SAMPLED_TEXTURE
	return true

func get_volume_parameter_names() -> PackedStringArray:
	return PackedStringArray([
		"exposure_source",
		"metering_mode", "low_percent", "high_percent",
		"min_brightness", "max_brightness", "min_ev100", "max_ev100",
		"speed_up", "speed_down", "exposure_compensation",
		"exposure_compensation_curve", "metering_mask",
		"histogram_log_min", "histogram_log_max",
		"histogram_ev100_min", "histogram_ev100_max",
		"apply_physical_camera_exposure", "aperture", "shutter_speed", "iso",
	])

func _frp_execute(ctx: FRPPassContext) -> void:
	_frame_parameters = get_resolved_parameters(ctx)
	_frame_context = ctx
	super._frp_execute(ctx)
	_frame_context = null
	_frame_parameters = null

func _setup(rd: RenderingDevice) -> void:
	super._setup(rd)
	for path in [HISTOGRAM_SHADER, ADAPT_SHADER]:
		var shader_file: RDShaderFile = load(path)
		if shader_file == null:
			_report("Eye adaptation shader file is missing: " + path)
			return
		var spirv := shader_file.get_spirv()
		if spirv == null or spirv.compile_error_compute != "":
			_report("Eye adaptation shader failed to compile: %s %s" % [path, spirv.compile_error_compute if spirv != null else ""])
			return
		var shader := rd.shader_create_from_spirv(spirv)
		if not shader.is_valid():
			_report("Cannot create eye adaptation shader: " + path)
			return
		_shaders.append(shader)
		var pipeline := rd.compute_pipeline_create(shader)
		if not pipeline.is_valid():
			_report("Cannot create eye adaptation pipeline: " + path)
			return
		match _shaders.size():
			1: _histogram_pipeline = pipeline
			2: _adapt_pipeline = pipeline
	var state := RDSamplerState.new()
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = rd.sampler_create(state)
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	_linear_sampler = rd.sampler_create(state)

func _get_view_state(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice) -> Dictionary:
	var key := buffers.get_instance_id()
	var entry: Dictionary = _state.get(key, {})
	if entry.is_empty() or not entry["wr"].get_ref():
		entry = {"wr": weakref(buffers), "views": {}}
		_state[key] = entry
	if _state.size() > STATE_PRUNE_LIMIT:
		for other_key in _state.keys():
			if other_key != key and _state[other_key]["wr"].get_ref() == null:
				for view_state in _state[other_key]["views"].values():
					rd.free_rid(view_state["params"])
					rd.free_rid(view_state["exposure_texture"])
				_state.erase(other_key)
	var view_state: Dictionary = entry["views"].get(view, {})
	if view_state.is_empty():
		var initial_state := PackedByteArray()
		initial_state.resize(PARAMS_BYTES)
		var params := rd.storage_buffer_create(PARAMS_BYTES, initial_state)
		if not params.is_valid():
			_report("Cannot create eye adaptation buffer.")
			return {}
		var format := RDTextureFormat.new()
		format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
		format.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
		format.width = 1
		format.height = 1
		format.depth = 1
		format.array_layers = 1
		format.mipmaps = 1
		format.samples = RenderingDevice.TEXTURE_SAMPLES_1
		format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		var exposure_texture := rd.texture_create(format, RDTextureView.new(), [PackedFloat32Array([1.0]).to_byte_array()])
		if not exposure_texture.is_valid():
			rd.free_rid(params)
			_report("Cannot create eye adaptation tonemap texture.")
			return {}
		view_state = {"params": params, "exposure_texture": exposure_texture, "last_usec": 0}
		entry["views"][view] = view_state
	return view_state

func _render(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice) -> void:
	if _shaders.size() != 2 or not _sampler.is_valid():
		return
	var color := buffers.get_color_layer(view)
	if not color.is_valid():
		return
	var size := buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0:
		return
	var state := _get_view_state(buffers, view, rd)
	if state.is_empty():
		return
	var params: RID = state["params"]
	var exposure_texture: RID = state["exposure_texture"]
	var values: Dictionary = _frame_parameters if _frame_parameters is Dictionary else {}
	var camera_data: Dictionary = _frame_context.get_camera_exposure_data() if _frame_context != null else {}
	var camera_available := bool(camera_data.get("available", false))
	var source := int(values.get("exposure_source", exposure_source))
	var route := resolve_exposure_route(
		source,
		bool(values.get("_frp_volume_eye_exposure_override", false)),
		camera_available)
	var camera_auto_min_luminance := float(camera_data.get("auto_min_luminance", 1.0e-12))
	var camera_auto_max_luminance := float(camera_data.get("auto_max_luminance", camera_auto_min_luminance))
	if not is_finite(camera_auto_min_luminance) or camera_auto_min_luminance <= 0.0:
		camera_auto_min_luminance = 1.0e-12
	if not is_finite(camera_auto_max_luminance) or camera_auto_max_luminance <= 0.0:
		camera_auto_max_luminance = camera_auto_min_luminance
	camera_auto_min_luminance = clampf(camera_auto_min_luminance, 1.0e-12, 1.0e12)
	camera_auto_max_luminance = clampf(camera_auto_max_luminance,
		camera_auto_min_luminance, 1.0e12)
	var extend := bool(values.get("extend_default_luminance_range", extend_default_luminance_range))
	var use_pre_exposure := bool(values.get("pre_exposure", pre_exposure))
	var previous_pre_exposure := 1.0
	if use_pre_exposure and _frame_context != null:
		previous_pre_exposure = maxf(_frame_context.get_pre_exposure(view), 1e-12)
	var pass_metering_mode := clampi(int(values.get("metering_mode", metering_mode)), 0, 2)
	var internal_method := resolve_exposure_method(source, route,
		bool(camera_data.get("auto_enabled", false)), pass_metering_mode)
	# Camera-specific modes use 3/4 internally; the pass's histogram controls
	# should only see Histogram/Basic/Manual when Pass Settings is selected.
	var method := clampi(internal_method, 0, 2)
	var camera_auto := internal_method == INTERNAL_METERING_CAMERA_AUTO
	var camera_manual := internal_method == INTERNAL_METERING_CAMERA_MANUAL
	var low := clampf(float(values.get("low_percent", low_percent)), 1.0, 99.0) * 0.01
	var high := clampf(float(values.get("high_percent", high_percent)), 1.0, 99.0) * 0.01
	low = minf(low, high)
	var min_white := float(values.get("min_ev100", min_ev100)) if extend else float(values.get("min_brightness", min_brightness))
	var max_white := float(values.get("max_ev100", max_ev100)) if extend else float(values.get("max_brightness", max_brightness))
	if extend:
		min_white = pow(2.0, min_white)
		max_white = pow(2.0, max_white)
	min_white = maxf(min_white, 0.0001)
	max_white = maxf(max_white, min_white)
	var authored_up := float(values.get("speed_up", speed_up))
	var authored_down := float(values.get("speed_down", speed_down))
	if not is_finite(authored_up): authored_up = 0.0
	if not is_finite(authored_down): authored_down = 0.0
	var valid_speeds := authored_up >= 0.0 and authored_down >= 0.0
	var up := clampf(authored_up, 0.001, 1.0e6)
	var down := clampf(authored_down, 0.001, 1.0e6)
	var authored_compensation_ev := float(values.get("exposure_compensation", exposure_compensation))
	if not is_finite(authored_compensation_ev): authored_compensation_ev = 0.0
	var compensation := clampf(pow(2.0, clampf(authored_compensation_ev, -40.0, 40.0)), 1.0e-12, 1.0e12)
	var mask_texture: Variant = values.get("metering_mask", metering_mask)
	var mask_rid := RenderingServer.texture_get_rd_texture(mask_texture.get_rid()) if not camera_auto and not camera_manual and mask_texture is Texture2D else RID()
	var curve_texture: Variant = values.get("exposure_compensation_curve", exposure_compensation_curve)
	var curve_rid := RenderingServer.texture_get_rd_texture(curve_texture.get_rid()) if not camera_auto and not camera_manual and curve_texture is CurveTexture else RID()
	var manual_ev100 := 0.0
	if bool(values.get("apply_physical_camera_exposure", apply_physical_camera_exposure)):
		var fstop := maxf(float(values.get("aperture", aperture)), 0.001)
		var shutter := maxf(float(values.get("shutter_speed", shutter_speed)), 0.001)
		var sensitivity := maxf(float(values.get("iso", iso)), 1.0)
		manual_ev100 = log(fstop * fstop * shutter * 100.0 / sensitivity) / log(2.0)
	manual_ev100 = clampf(manual_ev100, -40.0, 40.0)
	var manual_white := clampf(pow(2.0, manual_ev100), 1.0e-12, 1.0e12)
	if camera_auto:
		internal_method = INTERNAL_METERING_CAMERA_AUTO
		min_white = clampf(camera_auto_min_luminance / 0.18, 1.0e-12, 1.0e12)
		max_white = clampf(camera_auto_max_luminance / 0.18, min_white, 1.0e12)
		var camera_speed := float(camera_data.get("auto_speed", 1.0))
		if not is_finite(camera_speed): camera_speed = 1.0
		up = clampf(camera_speed, 0.0, 1.0e6)
		down = up
		compensation = clampf(float(camera_data.get("auto_scale", 1.0)), 1.0e-12, 1.0e12)
		manual_white = 1.0
	elif camera_manual:
		internal_method = INTERNAL_METERING_CAMERA_MANUAL
		manual_white = clampf(float(camera_data.get("normalization_factor", 1.0)), 1.0e-12, 1.0e12)
		compensation = 1.0
	if method == 2:
		if not camera_auto and not camera_manual:
			min_white = manual_white
			max_white = manual_white

	var now_usec := Time.get_ticks_usec()
	var last_usec: int = state["last_usec"]
	state["last_usec"] = now_usec
	var mode_key := "pass:%d" % method
	if camera_auto:
		mode_key = "camera-auto:%d:%d" % [int(camera_data.get("identity", 0)), int(camera_data.get("auto_version", 0))]
	elif camera_manual:
		mode_key = "camera-manual:%d" % int(camera_data.get("identity", 0))
	var set_immediate := last_usec == 0 or str(state.get("mode_key", "")) != mode_key
	state["mode_key"] = mode_key
	var dt := maxf(float(now_usec - last_usec) / 1000000.0, 0.0) * maxf(Engine.time_scale, 0.0)
	var log_min := float(values.get("histogram_ev100_min", histogram_ev100_min)) if extend else float(values.get("histogram_log_min", histogram_log_min))
	var log_max := float(values.get("histogram_ev100_max", histogram_ev100_max)) if extend else float(values.get("histogram_log_max", histogram_log_max))
	if camera_auto:
		log_min = log(camera_auto_min_luminance) / log(2.0)
		log_max = log(camera_auto_max_luminance) / log(2.0)
		if log_max <= log_min:
			log_max = log_min + 1.0
	log_min = minf(log_min, log_max - 1.0)

	var params_uniform := RDUniform.new()
	params_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	params_uniform.binding = 0
	params_uniform.add_id(params)

	var list := rd.compute_list_begin()
	if not camera_manual:
		# Meter the frame's luminance into a 64-bin log histogram. Camera manual
		# exposure bypasses this pass entirely and reuses the same state buffer.
		var source_uniform := RDUniform.new()
		source_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		source_uniform.binding = 0
		source_uniform.add_id(_sampler)
		source_uniform.add_id(color)
		var mask_uniform := RDUniform.new()
		mask_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		mask_uniform.binding = 1
		mask_uniform.add_id(_linear_sampler)
		mask_uniform.add_id(mask_rid if mask_rid.is_valid() else color)
		var histogram_set := UniformSetCacheRD.get_cache(_shaders[0], 0, [source_uniform, mask_uniform])
		var histogram_params_set := UniformSetCacheRD.get_cache(_shaders[0], 1, [params_uniform])
		if not histogram_set.is_valid() or not histogram_params_set.is_valid():
			rd.compute_list_end()
			_report("Eye adaptation histogram bindings are invalid.")
			return
		var histogram_luminance_min := maxf(float(camera_data.get("auto_min_luminance", 1.0e-12)), 1.0e-12) if camera_auto else (0.0001 if method == 1 else pow(2.0, log_min))
		var histogram_push := PackedInt32Array([size.x, size.y]).to_byte_array() + PackedFloat32Array([
			log_min, 1.0 / (log_max - log_min), 1.0 / previous_pre_exposure,
			histogram_luminance_min, 0.0, 1.0 if mask_rid.is_valid() else 0.0,
			1.0 if method == 1 and not camera_auto else 0.0, 0.05 if method == 1 and not camera_auto else 0.0,
		]).to_byte_array()
		rd.compute_list_bind_compute_pipeline(list, _histogram_pipeline)
		rd.compute_list_bind_uniform_set(list, histogram_set, 0)
		rd.compute_list_bind_uniform_set(list, histogram_params_set, 1)
		rd.compute_list_set_push_constant(list, histogram_push, histogram_push.size())
		rd.compute_list_dispatch(list, ceili(float(size.x) / 16.0), ceili(float(size.y) / 16.0), 1)
		rd.compute_list_add_barrier(list)

	# Percentile metering and UE's two-speed EV adaptation.
	var adapt_set := UniformSetCacheRD.get_cache(_shaders[1], 0, [params_uniform])
	var curve_uniform := RDUniform.new()
	curve_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	curve_uniform.binding = 0
	curve_uniform.add_id(_linear_sampler)
	curve_uniform.add_id(curve_rid if curve_rid.is_valid() else color)
	var curve_set := UniformSetCacheRD.get_cache(_shaders[1], 1, [curve_uniform])
	var exposure_set := UniformSetCacheRD.get_cache(_shaders[1], 2, [_image_uniform(exposure_texture)])
	if not adapt_set.is_valid() or not curve_set.is_valid() or not exposure_set.is_valid():
		rd.compute_list_end()
		_report("Eye adaptation bindings are invalid.")
		return
	var adapt_push := PackedFloat32Array([
		log_min, log_max - log_min, min_white, max_white,
		low if method == 0 else 0.0, high if method == 0 else 1.0,
		up, down, dt, compensation, manual_white,
		1.0 if method == 2 or min_white == max_white or not valid_speeds else 0.0,
		1.0 if set_immediate else 0.0, float(internal_method), 1.0 if curve_rid.is_valid() else 0.0, previous_pre_exposure,
	]).to_byte_array()
	rd.compute_list_bind_compute_pipeline(list, _adapt_pipeline)
	rd.compute_list_bind_uniform_set(list, adapt_set, 0)
	rd.compute_list_bind_uniform_set(list, curve_set, 1)
	rd.compute_list_bind_uniform_set(list, exposure_set, 2)
	rd.compute_list_set_push_constant(list, adapt_push, adapt_push.size())
	rd.compute_list_dispatch(list, 1, 1, 1)

	rd.compute_list_end()
	var render_target := buffers.get_render_target()
	if camera_manual and render_target.is_valid():
		PreviewExposure.publish_known_scale(render_target.get_id(), view, manual_white, self)
	elif PreviewExposure.should_sample(render_target, view):
		PreviewExposure.request_scale_readback(rd, params, render_target, view, self)
	if _frame_context != null and view == 0:
		_frame_context.set_tonemap_exposure_texture(exposure_texture)
	if use_pre_exposure and _frame_context != null and camera_manual:
		_frame_context.set_next_pre_exposure(view, manual_white)
	elif use_pre_exposure and _frame_context != null:
		# UE uses an asynchronous GPU readback for the next frame's pre-exposure.
		# The native callback owns its context until readback completes, including
		# when the pass resource is released during editor shutdown.
		var readback_error := _frame_context.request_next_pre_exposure(params, view, NUM_BINS * 8 + 4)
		if readback_error != OK:
			_report("Eye adaptation exposure readback failed: %d" % readback_error)

func _image_uniform(texture: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = 0
	uniform.add_id(texture)
	return uniform

func _take_owned_rids() -> Array[RID]:
	var rids := super._take_owned_rids()
	# PREDELETE can null the script's direct Object method dispatch. PassBase
	# already uses this native identity route for its shutdown cleanup.
	var producer_id := int(super.call("get_instance_id"))
	if producer_id != 0:
		PreviewExposure.retire_producer(producer_id)
	for entry in _state.values():
		for view_state in entry["views"].values():
			rids.append(view_state["params"])
			rids.append(view_state["exposure_texture"])
	rids.append_array([_histogram_pipeline, _adapt_pipeline, _sampler, _linear_sampler])
	rids.append_array(_shaders)
	_histogram_pipeline = RID()
	_adapt_pipeline = RID()
	_sampler = RID()
	_linear_sampler = RID()
	_state.clear()
	_shaders.clear()
	return rids
