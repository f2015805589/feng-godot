@tool
extends RefCounted
## D3D12/Vulkan trace pipeline shared by the diffuse and reflection renderers.
const U = preload("res://addons/feng-render-pipeline/rd/uniforms.gd")
const DIR = "res://addons/feng-raytracing/shaders/"
var rd: RenderingDevice
var scene: Variant
var owned: Array[RID] = []
var shader := RID()
var shadow_shader := RID()
var pipeline := RID()
var sbt := RID()
var sbt_range := 0
var frame_buffer := RID()
var fallback_hit_distance := RID()
var sky_array := false
var error := ""

func keep(rid: RID) -> RID:
	if rid.is_valid():
		owned.append(rid)
	return rid

func release() -> void:
	if rd == null:
		return
	var releasing := owned.duplicate()
	releasing.reverse()
	for rid in releasing:
		if rid.is_valid():
			rd.free_rid(rid)
	owned.clear()
	shader = RID()
	shadow_shader = RID()
	pipeline = RID()
	sbt = RID()
	sbt_range = 0
	frame_buffer = RID()
	fallback_hit_distance = RID()

func all_rids() -> Array[RID]:
	return owned.duplicate()

func initialize(device: RenderingDevice, array_sky: bool) -> bool:
	if pipeline.is_valid() and rd == device and sky_array == array_sky:
		return true
	release()
	rd = device
	sky_array = array_sky
	if scene == null or not scene.initialize(device):
		error = "RTGI shared scene resources failed to initialize"
		return false
	var source := RDShaderSource.new()
	var stages = [[RenderingDevice.SHADER_STAGE_RAYGEN, "gi_raygen", "FengGIRayGen"],
		[RenderingDevice.SHADER_STAGE_MISS, "gi_primary_miss", "FengGIPrimaryMiss"],
		[RenderingDevice.SHADER_STAGE_CLOSEST_HIT, "gi_closest_hit", "FengGIClosestHit"],
		[RenderingDevice.SHADER_STAGE_ANY_HIT, "gi_any_hit", "FengGIAnyHit"]]
	for entry in stages:
		attach_stage(source, entry)
	shader = compile(source, "FengRTGI")
	var shadow_source := RDShaderSource.new()
	attach_stage(shadow_source, [RenderingDevice.SHADER_STAGE_MISS, "gi_shadow_miss", "FengGIShadowMiss"])
	var shadow_shader := compile(shadow_source, "FengRTGIShadowMiss")
	self.shadow_shader = shadow_shader
	if not shader.is_valid() or not self.shadow_shader.is_valid():
		return false
	var raygen := RDPipelineShader.new()
	raygen.shader = shader
	var miss := RDPipelineShader.new()
	miss.shader = shader
	var shadow_miss := RDPipelineShader.new()
	shadow_miss.shader = shadow_shader
	var hit := RDHitGroup.new()
	hit.closest_hit_shader = raygen
	hit.any_hit_shader = raygen
	pipeline = keep(rd.raytracing_pipeline_create([raygen], [miss, shadow_miss], [hit], 2))
	if not pipeline.is_valid():
		error = "RTGI pipeline creation failed"
		return false
	sbt = keep(rd.hit_sbt_create(pipeline, 1))
	sbt_range = rd.hit_sbt_range_alloc(sbt, 1)
	if sbt_range == 0 or rd.hit_sbt_range_update(sbt, sbt_range, 0, PackedInt32Array([0])) != OK:
		return false
	frame_buffer = keep(rd.uniform_buffer_create(256))
	var format := RDTextureFormat.new()
	format.width = 1
	format.height = 1
	format.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	fallback_hit_distance = keep(rd.texture_create(format, RDTextureView.new()))
	return frame_buffer.is_valid() and fallback_hit_distance.is_valid()

func attach_stage(source: RDShaderSource, entry: Array) -> void:
	var code := FileAccess.get_file_as_string(DIR + entry[1] + ".glslinc")
	code = code.replace("#version 460", "#version 460\n#define FENG_GI_SKY_ARRAY %d" % int(sky_array))
	source.set_stage_source(entry[0], code)
	var native_code := "#define FENG_GI_SKY_ARRAY %d\n" % int(sky_array) + FileAccess.get_file_as_string(DIR + entry[1] + ".hlslinc")
	if source.has_method("set_native_hlsl_stage_source"):
		source.call("set_native_hlsl_stage_source", entry[0], native_code)
		source.call("set_native_hlsl_stage_export", entry[0], entry[2])
		source.call("set_native_hlsl_max_payload_size_bytes", 24)
		source.call("set_native_hlsl_max_attribute_size_bytes", 8)

func compile(source: RDShaderSource, label: String) -> RID:
	var spirv := rd.shader_compile_spirv_from_source(source)
	for stage in range(RenderingDevice.SHADER_STAGE_MAX):
		if not spirv.get_stage_compile_error(stage).is_empty():
			error = spirv.get_stage_compile_error(stage)
			return RID()
	var result := keep(rd.shader_create_from_spirv(spirv, label))
	if not result.is_valid():
		error = label + " native compilation failed"
	return result

func sync_scene(snapshot: Dictionary) -> bool:
	return scene != null and scene.sync_scene(snapshot, sbt_range)

func trace(textures: Array[RID], frame: PackedByteArray, lighting: Dictionary, output: RID,
		dfg_texture: RID, size: Vector2i, hit_distance: RID = RID()) -> bool:
	if scene == null or not scene.tlas.is_valid():
		error = "RTGI shared TLAS is unavailable"
		return false
	if rd.buffer_update(frame_buffer, 0, frame.size(), frame) != OK:
		error = "RTGI frame data upload failed"
		return false
	var uniforms: Array[RDUniform] = scene.build_trace_uniforms(textures, lighting, frame_buffer, output, dfg_texture, false, sky_array)
	uniforms.append(U.image(24, hit_distance if hit_distance.is_valid() else fallback_hit_distance))
	var uniform_set := rd.uniform_set_create(uniforms, shader, 0)
	if not uniform_set.is_valid():
		error = "RTGI descriptor binding failed"
		return false
	var list := rd.raytracing_list_begin()
	if list < 0:
		rd.free_rid(uniform_set)
		error = "RTGI ray tracing list could not begin"
		return false
	rd.raytracing_list_bind_raytracing_pipeline(list, pipeline)
	rd.raytracing_list_bind_uniform_set(list, uniform_set, 0)
	rd.raytracing_list_trace_rays(list, 0, sbt, size.x, size.y, 1)
	rd.raytracing_list_end()
	rd.free_rid(uniform_set)
	return true
