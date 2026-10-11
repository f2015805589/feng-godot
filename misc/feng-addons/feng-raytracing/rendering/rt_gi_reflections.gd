@tool
extends RefCounted
## Independent full-resolution reflection trace, history and native-specular replacement.
const U = preload("res://addons/feng-render-pipeline/rd/uniforms.gd")
const SHADER_DIR := "res://addons/feng-raytracing/shaders/"

var rd: RenderingDevice
var sky_array := false
var error := ""
var owned: Array[RID] = []
var ray_shader := RID()
var ray_pipeline := RID()
var shadow_shader := RID()
var sbt := RID()
var sbt_range := 0
var frame_buffer := RID()
var temporal_shader := RID()
var temporal_pipeline := RID()
var composite_shader := RID()
var composite_pipeline := RID()

func _keep(rid: RID) -> RID:
	if rid.is_valid():
		owned.append(rid)
	return rid

func all_rids() -> Array[RID]:
	return owned.duplicate()

func release() -> void:
	if rd != null:
		var releasing := owned.duplicate()
		releasing.reverse()
		for rid in releasing:
			if rid.is_valid():
				rd.free_rid(rid)
	owned.clear()
	ray_shader = RID()
	ray_pipeline = RID()
	shadow_shader = RID()
	sbt = RID()
	sbt_range = 0
	frame_buffer = RID()
	temporal_shader = RID()
	temporal_pipeline = RID()
	composite_shader = RID()
	composite_pipeline = RID()
	rd = null

func initialize(device: RenderingDevice, p_sky_array: bool) -> bool:
	if rd == device and sky_array == p_sky_array and ray_pipeline.is_valid() \
			and temporal_pipeline.is_valid() and composite_pipeline.is_valid():
		return true
	release()
	rd = device
	sky_array = p_sky_array
	error = ""
	if not _create_ray_pipeline() or not _create_compute_pipelines():
		var build_error := error
		release()
		error = build_error
		return false
	frame_buffer = _keep(rd.uniform_buffer_create(256))
	if not frame_buffer.is_valid():
		error = "RT reflection frame buffer creation failed"
		var buffer_error := error
		release()
		error = buffer_error
		return false
	return true

func _set_stage(source: RDShaderSource, stage: int, file_stem: String, entry_point: String) -> void:
	var define := "#define FENG_GI_SKY_ARRAY %d" % int(sky_array)
	var code := FileAccess.get_file_as_string(SHADER_DIR + file_stem + ".glslinc")
	if code.begins_with("#version"):
		var line_end := code.find("\n")
		code = code.substr(0, line_end + 1) + define + "\n" + code.substr(line_end + 1)
	else:
		code = define + "\n" + code
	source.set_stage_source(stage, code)
	var native_code := define + "\n" + FileAccess.get_file_as_string(SHADER_DIR + file_stem + ".hlslinc")
	if source.has_method("set_native_hlsl_stage_source"):
		source.call("set_native_hlsl_stage_source", stage, native_code)
		source.call("set_native_hlsl_stage_export", stage, entry_point)
		source.call("set_native_hlsl_max_payload_size_bytes", 24)
		source.call("set_native_hlsl_max_attribute_size_bytes", 8)

func _compile(source: RDShaderSource, label: String) -> RID:
	var spirv := rd.shader_compile_spirv_from_source(source)
	for stage in range(RenderingDevice.SHADER_STAGE_MAX):
		var stage_error := spirv.get_stage_compile_error(stage)
		if not stage_error.is_empty():
			error = "%s: %s" % [label, stage_error]
			return RID()
	var shader := _keep(rd.shader_create_from_spirv(spirv, label))
	if not shader.is_valid():
		error = "%s shader creation failed" % label
	return shader

func _create_ray_pipeline() -> bool:
	var source := RDShaderSource.new()
	var stages := [
		[RenderingDevice.SHADER_STAGE_RAYGEN, "gi_reflection_raygen", "FengGIReflectionRayGen"],
		[RenderingDevice.SHADER_STAGE_MISS, "gi_primary_miss", "FengGIPrimaryMiss"],
		[RenderingDevice.SHADER_STAGE_CLOSEST_HIT, "gi_closest_hit", "FengGIClosestHit"],
		[RenderingDevice.SHADER_STAGE_ANY_HIT, "gi_any_hit", "FengGIAnyHit"],
	]
	for stage in stages:
		_set_stage(source, stage[0], stage[1], stage[2])
	ray_shader = _compile(source, "FengGIReflection")
	if not ray_shader.is_valid():
		return false
	var shadow_source := RDShaderSource.new()
	_set_stage(shadow_source, RenderingDevice.SHADER_STAGE_MISS, "gi_shadow_miss", "FengGIShadowMiss")
	shadow_shader = _compile(shadow_source, "FengGIReflectionShadowMiss")
	if not shadow_shader.is_valid():
		return false
	var raygen := RDPipelineShader.new()
	raygen.shader = ray_shader
	var miss := RDPipelineShader.new()
	miss.shader = ray_shader
	var shadow_miss := RDPipelineShader.new()
	shadow_miss.shader = shadow_shader
	var hit := RDHitGroup.new()
	hit.closest_hit_shader = raygen
	hit.any_hit_shader = raygen
	ray_pipeline = _keep(rd.raytracing_pipeline_create([raygen], [miss, shadow_miss], [hit], 2))
	if not ray_pipeline.is_valid():
		error = "RT reflection ray tracing pipeline creation failed"
		return false
	sbt = _keep(rd.hit_sbt_create(ray_pipeline, 1))
	if not sbt.is_valid():
		error = "RT reflection shader binding table creation failed"
		return false
	sbt_range = rd.hit_sbt_range_alloc(sbt, 1)
	if sbt_range == 0 or rd.hit_sbt_range_update(sbt, sbt_range, 0, PackedInt32Array([0])) != OK:
		error = "RT reflection hit group binding failed"
		return false
	return true

func _create_compute_pipelines() -> bool:
	for shader_name in ["gi_reflection_temporal", "gi_reflection_composite"]:
		var source := RDShaderSource.new()
		source.source_compute = FileAccess.get_file_as_string(SHADER_DIR + shader_name + ".glslinc")
		var spirv := rd.shader_compile_spirv_from_source(source)
		if not spirv.compile_error_compute.is_empty():
			error = "%s: %s" % [shader_name, spirv.compile_error_compute]
			return false
		var shader := _keep(rd.shader_create_from_spirv(spirv, shader_name))
		if not shader.is_valid():
			error = "%s shader creation failed" % shader_name
			return false
		var pipeline := _keep(rd.compute_pipeline_create(shader))
		if not pipeline.is_valid():
			error = "%s pipeline creation failed" % shader_name
			return false
		if shader_name == "gi_reflection_temporal":
			temporal_shader = shader
			temporal_pipeline = pipeline
		else:
			composite_shader = shader
			composite_pipeline = pipeline
	return true

func _texture(size: Vector2i, format: int) -> RID:
	var desc := RDTextureFormat.new()
	desc.width = size.x
	desc.height = size.y
	desc.format = format
	desc.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
			| RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var texture := rd.texture_create(desc, RDTextureView.new())
	if texture.is_valid():
		rd.texture_clear(texture, Color(0, 0, 0, 0), 0, 1, 0, 1)
	return texture

func create_state(size: Vector2i) -> Dictionary:
	var resources: Array[RID] = []
	var raw := _texture(size, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
	resources.append(raw)
	var histories: Array = []
	var formats := [RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
			RenderingDevice.DATA_FORMAT_R32_SFLOAT,
			RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
			RenderingDevice.DATA_FORMAT_R32_SFLOAT,
			RenderingDevice.DATA_FORMAT_R16G16_SFLOAT,
			RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT]
	for history_index in 2:
		var images: Array[RID] = []
		for format in formats:
			var image := _texture(size, format)
			images.append(image)
			resources.append(image)
		histories.append(images)
	var ubo := rd.uniform_buffer_create(256)
	resources.append(ubo)
	for rid in resources:
		if not rid.is_valid():
			_free_resources(resources)
			return {}
	return {"size": size, "raw": raw, "history": histories, "resources": resources,
			"ubo": ubo, "ping": 0, "valid": false, "generation": -1, "signature": [],
			"exposure": 1.0, "camera": Transform3D.IDENTITY, "vp": Projection.IDENTITY,
			"last_seen": Engine.get_frames_drawn()}

func _free_resources(resources: Array[RID]) -> void:
	if rd == null:
		return
	for rid in resources:
		if rid.is_valid():
			rd.free_rid(rid)

func release_state(state: Dictionary) -> void:
	if state.is_empty():
		return
	var resources: Array[RID] = state.get("resources", [])
	_free_resources(resources)

func _camera_matches(a: Transform3D, b: Transform3D) -> bool:
	return a.origin.distance_to(b.origin) <= 0.0001 and a.basis.x.distance_to(b.basis.x) <= 0.00001 \
			and a.basis.y.distance_to(b.basis.y) <= 0.00001 and a.basis.z.distance_to(b.basis.z) <= 0.00001

func _matrix_bytes(matrix: Projection) -> PackedByteArray:
	var values := PackedFloat32Array()
	for column in 4:
		for row in 4:
			values.append(matrix[column][row])
	return values.to_byte_array()

func _dispatch(shader: RID, pipeline: RID, uniforms: Array[RDUniform], size: Vector2i) -> bool:
	var uniform_set := rd.uniform_set_create(uniforms, shader, 0)
	if not uniform_set.is_valid():
		return false
	var list := rd.compute_list_begin()
	if list < 0:
		rd.free_rid(uniform_set)
		return false
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	rd.compute_list_dispatch(list, (size.x + 7) / 8, (size.y + 7) / 8, 1)
	rd.compute_list_end()
	rd.free_rid(uniform_set)
	return true

func trace(scene: Variant, textures: Array[RID], frame_data: PackedByteArray, lighting: Dictionary,
		output: RID, dfg_texture: RID, size: Vector2i) -> bool:
	if scene == null or not scene.tlas.is_valid() or not output.is_valid() or not dfg_texture.is_valid():
		error = "RT reflection scene, output or native DFG LUT is unavailable"
		return false
	if textures.size() < 5:
		error = "RT reflection requires depth, normal, albedo, ORM and emission G-buffer inputs"
		return false
	if rd.buffer_update(frame_buffer, 0, frame_data.size(), frame_data) != OK:
		error = "RT reflection frame data upload failed"
		return false
	var uniforms: Array[RDUniform] = scene.build_trace_uniforms(textures, lighting, frame_buffer, output,
			dfg_texture, true, sky_array)
	var uniform_set := rd.uniform_set_create(uniforms, ray_shader, 0)
	if not uniform_set.is_valid():
		error = "RT reflection descriptor binding failed"
		return false
	var list := rd.raytracing_list_begin()
	if list < 0:
		rd.free_rid(uniform_set)
		error = "RT reflection ray tracing list could not begin"
		return false
	rd.raytracing_list_bind_raytracing_pipeline(list, ray_pipeline)
	rd.raytracing_list_bind_uniform_set(list, uniform_set, 0)
	rd.raytracing_list_trace_rays(list, 0, sbt, size.x, size.y, 1)
	rd.raytracing_list_end()
	rd.free_rid(uniform_set)
	return true

func resolve(state: Dictionary, scene_sampler_rid: RID, frame: Dictionary, textures: Array[RID], generation: int,
		signature: Array, options: Dictionary, replacement_strength: float) -> bool:
	if state.is_empty() or textures.size() < 5:
		return false
	var transform: Transform3D = frame.get("camera_transform", Transform3D.IDENTITY)
	var exposure := float(frame.get("pre_exposure", 1.0)) * float(frame.get("scene_normalization", 1.0))
	if not is_finite(exposure) or exposure <= 0.0:
		state.valid = false
		return false
	var camera_cut := bool(frame.get("camera_cut", false))
	var valid_history: bool = state.valid and state.generation + 1 == generation \
			and state.signature == signature and not camera_cut
	var inverse_projection: Projection = frame.get("inverse_projection", Projection.IDENTITY)
	var inverse_vp := Projection(transform) * inverse_projection
	var vp := inverse_vp.inverse()
	var weight := clampf(float(options.get("history_weight", 0.97)), 0.0, 0.98)
	var exposure_ratio := exposure / maxf(float(state.exposure), 1e-8)
	var bytes := PackedFloat32Array([weight, exposure_ratio, 0.03, 0.95,
			0.03, 0.15, 0.02, 0.02]).to_byte_array()
	bytes.append_array(PackedInt32Array([int(valid_history), generation & 0xffffffff,
			generation >> 32]).to_byte_array())
	bytes.append_array(PackedFloat32Array([clampf(replacement_strength, 0.0, 1.0)]).to_byte_array())
	bytes.append_array(PackedFloat32Array([float(not _camera_matches(state.camera, transform)),
			0.0, 0.0, 0.0]).to_byte_array())
	bytes.append_array(_matrix_bytes(inverse_vp))
	bytes.append_array(_matrix_bytes(state.vp))
	bytes.append_array(_matrix_bytes(Projection(transform)))
	if rd.buffer_update(state.ubo, 0, bytes.size(), bytes) != OK:
		state.valid = false
		return false
	var previous: Array = state.history[state.ping]
	var next_index: int = 1 - int(state.ping)
	var next: Array = state.history[next_index]
	var sampled := [state.raw, previous[0], previous[1], previous[2], previous[3],
			textures[0], textures[1], textures[3], previous[4], textures[4], textures[2], previous[5]]
	var uniforms: Array[RDUniform] = []
	for index in sampled.size():
		uniforms.append(U.sampled(index, scene_sampler_rid, sampled[index]))
	for index in 6:
		uniforms.append(U.image(12 + index, next[index]))
	uniforms.append(U.uniform_buffer(18, state.ubo))
	if not _dispatch(temporal_shader, temporal_pipeline, uniforms, state.size):
		state.valid = false
		return false
	state.ping = next_index
	state.valid = true
	state.generation = generation
	state.signature = signature.duplicate(true)
	state.exposure = exposure
	state.camera = transform
	state.vp = vp
	state.last_seen = Engine.get_frames_drawn()
	return true

func composite(state: Dictionary, target: RID, native_indirect_specular: RID,
		scene_sampler_rid: RID, full_size: Vector2i, replacement_strength: float) -> bool:
	if state.is_empty() or not state.valid or not target.is_valid() \
			or not native_indirect_specular.is_valid() or not scene_sampler_rid.is_valid():
		return false
	var result: Array = state.history[state.ping]
	var uniforms: Array[RDUniform] = [U.image(0, target),
			U.sampled(1, scene_sampler_rid, native_indirect_specular),
			U.sampled(2, scene_sampler_rid, result[0]), U.uniform_buffer(3, state.ubo)]
	return _dispatch(composite_shader, composite_pipeline, uniforms, full_size)
