@tool
class_name FengRTGIPass
extends FengPass
## Optional diffuse hardware ray tracing, replacing the native SkyLight diffuse term.
const Runtime = preload("../scene/feng_rt_gi_runtime.gd")
const GPU = preload("../rendering/rt_gi_gpu.gd")
const U = preload("res://addons/feng-render-pipeline/rd/uniforms.gd")
const Selection = preload("res://addons/feng-render-pipeline/pipeline/indirect_gi_selection.gd")
@export_range(0, 8, 0.01) var strength := 1.0:
	set(value):
		strength = value
		emit_changed()
@export_range(1, 1000, 1) var max_distance := 100.0:
	set(value):
		max_distance = value
		emit_changed()
@export_enum("1:1", "2:2", "4:4") var samples_per_pixel := 1:
	set(value):
		samples_per_pixel = value
		emit_changed()
@export var half_resolution := true:
	set(value):
		half_resolution = value
		emit_changed()
@export_range(0, 0.98, 0.01) var history_weight := 0.9:
	set(value):
		history_weight = value
		emit_changed()
var _states: Dictionary = {}
var _warnings: Dictionary = {}
var _sky_input: TextureInput
var _temporal_shader := RID()
var _temporal_pipeline := RID()
var _composite_shader := RID()
var _composite_pipeline := RID()
var _shared: Array[RID] = []

func _init() -> void:
	stage = 8
	resource_name = "Hardware RTGI"
	access_resolved_color = true
	access_resolved_depth = true
	needs_normal_roughness = true
	for source in [TextureInput.Source.DEPTH, TextureInput.Source.NORMAL_ROUGHNESS, TextureInput.Source.ALBEDO, TextureInput.Source.ORM]:
		var input := TextureInput.new()
		input.source = source
		input.binding = inputs.size() + 1
		inputs.append(input)
	_sky_input = TextureInput.new()
	_sky_input.source = TextureInput.Source.CUSTOM
	_sky_input.custom_scope = &"frp_clustered"
	_sky_input.custom_name = &"sky_light_diffuse"
	_start_runtime.call_deferred()

func _start_runtime() -> void:
	Runtime.start()

func can_share_view_execution() -> bool:
	return true

func get_indirect_gi_kind() -> StringName:
	return Selection.KIND_RT

func _frp_prepare(ctx: FRPPassContext) -> void:
	if not Selection.is_owner(ctx, String(get_parameter_key()), Selection.KIND_RT, false):
		return
	var buffers := ctx.get_render_scene_buffers()
	if buffers != null:
		Runtime.request_target(buffers.get_render_target())
	ctx.request_sky_light_diffuse()

func _frp_execute(ctx: FRPPassContext) -> void:
	_execute_frame(ctx)
	refresh_owned()

func _execute_frame(ctx: FRPPassContext) -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd == null or not Selection.is_owner(ctx, String(get_parameter_key()), Selection.KIND_RT, false):
		return
	if not rd.has_feature(RenderingDevice.SUPPORTS_RAYTRACING_PIPELINE):
		warn_once("Hardware RT pipelines are unavailable; SkyLight remains active.")
		return
	var buffers := ctx.get_render_scene_buffers()
	var target := buffers.get_render_target()
	Runtime.request_target(target)
	var snapshot := Runtime.snapshot_for_target(target)
	if not bool(snapshot.get("valid", false)):
		var reasons: Array = snapshot.get("unsupported_reasons", [])
		if not reasons.is_empty():
			warn_once("Unsupported scene geometry/material: " + str(reasons[0]) + "; SkyLight remains active.")
		invalidate(target)
		return
	var options := get_resolved_parameters(ctx)
	var amount := float(options.get("strength", strength))
	if not is_finite(amount) or amount <= 0.0:
		invalidate(target)
		return
	if not ensure_compute(rd):
		return
	for view in buffers.get_view_count():
		var frame := ctx.get_volume_frame_inputs(view)
		if frame.is_empty():
			continue
		var sky := _sky_input.get_texture(buffers, view)
		if not sky.is_valid():
			continue
		var full_size := buffers.get_internal_size()
		var size := Vector2i(maxi(1, (full_size.x + 1) / 2), maxi(1, (full_size.y + 1) / 2)) if bool(options.get("half_resolution", half_resolution)) else full_size
		var key: Array = [target, view]
		var state: Dictionary = _states.get(key, {})
		var sky_array := bool(frame.get("sky_radiance_is_array", false))
		if state.is_empty() or state.size != size or state.gpu.sky_array != sky_array:
			free_state(rd, state)
			state = create_state(rd, size, sky_array)
			_states[key] = state
		if state.is_empty():
			continue
		var gpu: RefCounted = state.gpu
		if not gpu.sync_scene(snapshot):
			warn_once(gpu.error)
			state.valid = false
			continue
		var textures: Array[RID] = []
		for input in inputs:
			textures.append(input.get_texture(buffers, view))
		if textures.has(RID()):
			state.valid = false
			continue
		var generation := int(frame.get("frame_generation", Engine.get_frames_drawn()))
		var frame_bytes := pack_frame(frame, size, generation, view, amount, options)
		if not gpu.trace(textures, frame_bytes, frame, state.raw, size):
			warn_once(gpu.error)
			state.valid = false
			continue
		resolve(rd, state, frame, textures, generation, hash([snapshot.get("registry_epoch", 0), snapshot.snapshot_generation, gpu.transform_key, amount, options.get("max_distance", max_distance), options.get("samples_per_pixel", samples_per_pixel)]), options)
		var history: Array = state.history[state.ping]
		dispatch(rd, _composite_shader, _composite_pipeline, [U.image(0, buffers.get_color_layer(view)), U.sampled(1, gpu.sampler, history[0]), U.sampled(2, gpu.sampler, sky), U.sampled(3, gpu.sampler, textures[0]), U.sampled(4, gpu.sampler, history[2])], full_size)
		state.last_seen = Engine.get_frames_drawn()
	for key in _states.keys():
		if Engine.get_frames_drawn() - int(_states[key].get("last_seen", 0)) > 120:
			free_state(rd, _states[key])
			_states.erase(key)
	refresh_owned()

func invalidate(target: RID) -> void:
	for key in _states:
		if key[0] == target:
			_states[key].valid = false

func warn_once(message: String) -> void:
	if message.is_empty() or _warnings.has(message):
		return
	_warnings[message] = true
	push_warning("FengRTGI: " + message)

func matrix_bytes(matrix: Projection) -> PackedByteArray:
	var values := PackedFloat32Array()
	for column in 4:
		for row in 4:
			values.append(matrix[column][row])
	return values.to_byte_array()

func pack_frame(frame: Dictionary, size: Vector2i, generation: int, view: int, amount: float, options: Dictionary) -> PackedByteArray:
	var bytes := matrix_bytes(frame.inverse_projection)
	bytes.append_array(matrix_bytes(Projection(frame.camera_transform)))
	bytes.append_array(PackedFloat32Array([size.x,size.y,frame.get("pre_exposure",1.0),frame.get("scene_normalization",1.0),frame.get("light_buffer_exposure_normalization",1.0),frame.get("sky_light_energy",0.0),frame.get("sky_captured_exposure",1.0),frame.get("sky_uv_border_size",0.0)]).to_byte_array())
	var rotation: Basis = frame.get("sky_light_rotation", Basis.IDENTITY)
	rotation = rotation.inverse()
	for column in [rotation.x,rotation.y,rotation.z]:
		bytes.append_array(PackedFloat32Array([column.x,column.y,column.z,0]).to_byte_array())
	var sun := int(frame.get("cloud_primary_sun_directional_index", -1))
	if sun < 0 and int(frame.get("directional_light_count", 0)) > 0:
		sun = 0
	bytes.append_array(PackedInt32Array([sun,view,generation & 0xffffffff,int(frame.get("sky_radiance_is_array",false))]).to_byte_array())
	bytes.append_array(PackedFloat32Array([options.get("max_distance",max_distance),amount,options.get("samples_per_pixel",samples_per_pixel),options.get("history_weight",history_weight)]).to_byte_array())
	bytes.append_array(PackedInt32Array([generation >> 32,0,0,0]).to_byte_array())
	return bytes

func texture(rd: RenderingDevice, size: Vector2i, format: int) -> RID:
	var desc := RDTextureFormat.new()
	desc.width = size.x
	desc.height = size.y
	desc.format = format
	desc.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	var rid := rd.texture_create(desc, RDTextureView.new())
	if rid.is_valid():
		rd.texture_clear(rid, Color(0,0,0,0),0,1,0,1)
	return rid

func create_state(rd: RenderingDevice, size: Vector2i, sky_array: bool) -> Dictionary:
	var gpu := GPU.new()
	if not gpu.initialize(rd, sky_array):
		warn_once(gpu.error)
		gpu.release()
		return {}
	var resources: Array[RID] = []
	var raw := texture(rd,size,RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
	resources.append(raw)
	var history: Array = []
	for index in 2:
		var images: Array[RID] = []
		for format in [RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,RenderingDevice.DATA_FORMAT_R16G16_SFLOAT,RenderingDevice.DATA_FORMAT_R32_SFLOAT,RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT]:
			images.append(texture(rd,size,format))
		resources.append_array(images)
		history.append(images)
	var ubo := rd.uniform_buffer_create(240)
	resources.append(ubo)
	return {"gpu":gpu,"size":size,"raw":raw,"history":history,"resources":resources,"ubo":ubo,"ping":0,"valid":false,"generation":-1,"revision":-1,"exposure":1.0,"vp":Projection.IDENTITY,"last_seen":Engine.get_frames_drawn()}

func resolve(rd: RenderingDevice, state: Dictionary, frame: Dictionary, textures: Array[RID], generation: int, revision: int, options: Dictionary) -> void:
	var transform: Transform3D = frame.camera_transform
	var projection: Projection = frame.projection
	var vp := projection * Projection(transform.affine_inverse())
	var exposure := float(frame.get("pre_exposure",1.0)) * float(frame.get("scene_normalization",1.0))
	var camera_cut := bool(frame.get("camera_cut",false))
	var valid: bool = state.valid and state.generation + 1 == generation and state.revision == revision and not camera_cut and state.get("camera", -1) == frame.get("camera_generation", 0)
	var bytes := matrix_bytes(vp.inverse())
	bytes.append_array(matrix_bytes(state.vp))
	bytes.append_array(PackedFloat32Array([state.size.x,state.size.y,options.get("history_weight",history_weight),exposure / maxf(state.exposure,1e-8),0.85,0.01,0.0001,float(valid)]).to_byte_array())
	bytes.append_array(PackedInt32Array([generation & 0xffffffff,generation >> 32,0,0]).to_byte_array())
	bytes.append_array(matrix_bytes(Projection(transform)))
	rd.buffer_update(state.ubo,0,bytes.size(),bytes)
	var previous: Array = state.history[state.ping]
	state.ping = 1 - state.ping
	var next: Array = state.history[state.ping]
	var sampler: RID = state.gpu.sampler
	var bindings: Array[RDUniform] = []
	var sampled: Array = [state.raw,previous[0],previous[1],textures[0],textures[1],previous[2],previous[3]]
	for index in sampled.size():
		bindings.append(U.sampled(index,sampler,sampled[index]))
	for index in 4:
		bindings.append(U.image(7+index,next[index]))
	bindings.append(U.uniform_buffer(11,state.ubo))
	dispatch(rd,_temporal_shader,_temporal_pipeline,bindings,state.size)
	state.valid = true
	state.generation = generation
	state.revision = revision
	state.exposure = exposure
	state.vp = vp
	state.camera = frame.get("camera_generation", 0)

func dispatch(rd: RenderingDevice, shader: RID, pipeline: RID, bindings: Array[RDUniform], size: Vector2i) -> void:
	var uniform_set := rd.uniform_set_create(bindings,shader,0)
	if not uniform_set.is_valid():
		return
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list,pipeline)
	rd.compute_list_bind_uniform_set(list,uniform_set,0)
	rd.compute_list_dispatch(list,(size.x+7)/8,(size.y+7)/8,1)
	rd.compute_list_end()
	rd.free_rid(uniform_set)

func ensure_compute(rd: RenderingDevice) -> bool:
	if _temporal_pipeline.is_valid():
		return true
	for name in ["gi_temporal","gi_composite"]:
		var source := RDShaderSource.new()
		source.source_compute = FileAccess.get_file_as_string("res://addons/feng-raytracing/shaders/"+name+".glslinc")
		var spirv := rd.shader_compile_spirv_from_source(source)
		if not spirv.compile_error_compute.is_empty():
			warn_once(spirv.compile_error_compute)
			return false
		var shader := rd.shader_create_from_spirv(spirv,name)
		var pipeline := rd.compute_pipeline_create(shader)
		_shared.append_array([shader,pipeline])
		if name == "gi_temporal":
			_temporal_shader = shader
			_temporal_pipeline = pipeline
		else:
			_composite_shader = shader
			_composite_pipeline = pipeline
	return _temporal_pipeline.is_valid() and _composite_pipeline.is_valid()

func free_state(rd: RenderingDevice, state: Dictionary) -> void:
	if state.is_empty():
		return
	state.gpu.release()
	for rid: RID in state.resources:
		if rid.is_valid():
			rd.free_rid(rid)

func refresh_owned() -> void:
	var resources: Array[RID] = []
	resources.append_array(_shared)
	for state in _states.values():
		if not state.is_empty():
			resources.append_array(state.resources)
			resources.append_array(state.gpu.all_rids())
	resources.reverse()
	_replace_owned_rid_snapshot(resources)
