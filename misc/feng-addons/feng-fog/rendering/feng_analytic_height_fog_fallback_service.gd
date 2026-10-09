@tool
extends RefCounted
## Restores the analytic near-height-fog segment if late volume composition fails.
## Color/depth layers are borrowed from the current FRP callback and never freed.

const SHADER_ROOT := "res://addons/feng-fog/rendering/shaders/"
const OwnedRids = preload("res://addons/feng-render-pipeline/rd/owned_rids.gd")
const ShaderSource = preload("res://addons/feng-render-pipeline/rd/shader_source.gd")
const RDUniforms = preload("res://addons/feng-render-pipeline/rd/uniforms.gd")
const FRAME_BYTES := 256
const WORKGROUP := 8

var _pipeline := RID()
var _shader := RID()
var _sampler := RID()
var _frame_ubos: Array[RID] = []
var _last_error := ""
var _failed_pipeline_fingerprint := ""
var _failed_pipeline_error := ""


func composite_analytic_near(rd: RenderingDevice, color_layers: Array[RID],
		depth_layers: Array[RID], frames: Array[Dictionary],
		fog_parameters_by_view: Array[PackedFloat32Array], size: Vector2i,
		pre_exposure: float) -> bool:
	_last_error = ""
	if rd == null or size.x <= 0 or size.y <= 0 or not is_finite(pre_exposure) \
			or pre_exposure <= 0.0 or color_layers.is_empty() \
			or color_layers.size() != depth_layers.size() \
			or color_layers.size() != frames.size() \
			or color_layers.size() != fog_parameters_by_view.size():
		_last_error = "Analytic fallback inputs have inconsistent view counts, size, or exposure."
		return false
	if not _ensure_pipeline(rd) or not _ensure_sampler(rd):
		if _last_error.is_empty():
			_last_error = "Analytic fallback pipeline or sampler is unavailable."
		return false
	if not _ensure_frame_ubos(rd, frames.size()):
		_last_error = "Analytic fallback frame UBO allocation failed."
		return false
	var uniform_sets: Array[RID] = []
	for view in color_layers.size():
		var color := color_layers[view]
		var depth := depth_layers[view]
		if not _valid_texture(rd, color) or not _valid_texture(rd, depth):
			_last_error = "Analytic fallback preflight failed at view %d: color or depth is invalid." % view
			return false
		var frame_values := _pack_frame(frames[view], fog_parameters_by_view[view], pre_exposure)
		if frame_values.size() * 4 != FRAME_BYTES \
				or not _update_ubo(_frame_ubos[view], frame_values, rd):
			_last_error = "Analytic fallback preflight failed at view %d: frame data or UBO update is invalid." % view
			return false
		var uniforms: Array[RDUniform] = [
			RDUniforms.image(0, color),
			RDUniforms.sampled(1, _sampler, depth),
			RDUniforms.uniform_buffer(2, _frame_ubos[view]),
		]
		var uniform_set := UniformSetCacheRD.get_cache(_shader, 0, uniforms)
		if not uniform_set.is_valid():
			_last_error = "Analytic fallback preflight failed at view %d: uniform set creation failed." % view
			return false
		uniform_sets.append(uniform_set)
	# All views are validated before the first color write. After begin, the RD
	# dispatch methods return no status that could safely trigger a partial fallback.
	var list := rd.compute_list_begin()
	if list < 0:
		_last_error = "Analytic fallback dispatch could not begin after all-view preflight."
		return false
	rd.compute_list_bind_compute_pipeline(list, _pipeline)
	for view in uniform_sets.size():
		rd.compute_list_bind_uniform_set(list, uniform_sets[view], 0)
		rd.compute_list_dispatch(list, ceili(float(size.x) / WORKGROUP),
				ceili(float(size.y) / WORKGROUP), 1)
	rd.compute_list_end()
	return true


func get_last_error() -> String:
	return _last_error


func get_owned_rids() -> Array[RID]:
	return _collect_owned_rids(false)


func take_owned_rids() -> Array[RID]:
	return _collect_owned_rids(true)


func _collect_owned_rids(p_clear: bool) -> Array[RID]:
	var result: Array[RID] = []
	var seen: Dictionary = {}
	OwnedRids.append(result, seen, _pipeline)
	OwnedRids.append(result, seen, _shader)
	OwnedRids.append(result, seen, _sampler)
	OwnedRids.append_all(result, seen, _frame_ubos)
	if p_clear:
		_pipeline = RID()
		_shader = RID()
		_sampler = RID()
		_frame_ubos.clear()
		_failed_pipeline_fingerprint = ""
		_failed_pipeline_error = ""
	return result


func _ensure_pipeline(rd: RenderingDevice) -> bool:
	if _pipeline.is_valid() and _shader.is_valid():
		return true
	var path := SHADER_ROOT.path_join("analytic_height_fog_fallback.glslinc")
	if not FileAccess.file_exists(path):
		_last_error = "Analytic fallback shader source is missing."
		return false
	var expanded := ShaderSource.expand(path, FileAccess.get_file_as_string(path))
	if expanded.is_empty():
		_last_error = "Analytic fallback shader includes could not be expanded."
		return false
	var fingerprint := expanded.sha256_text()
	if fingerprint == _failed_pipeline_fingerprint:
		_last_error = _failed_pipeline_error
		return false
	_failed_pipeline_fingerprint = ""
	_failed_pipeline_error = ""
	var source := RDShaderSource.new()
	source.source_compute = expanded.replace("#[compute]", "")
	var spirv := rd.shader_compile_spirv_from_source(source)
	if spirv == null or not spirv.compile_error_compute.is_empty():
		_last_error = "Analytic fallback shader compile failed: %s" % \
				(spirv.compile_error_compute if spirv != null else "no SPIR-V result")
		_failed_pipeline_fingerprint = fingerprint
		_failed_pipeline_error = _last_error
		return false
	_shader = rd.shader_create_from_spirv(spirv)
	if not _shader.is_valid():
		_last_error = "Analytic fallback shader RID creation failed."
		_failed_pipeline_fingerprint = fingerprint
		_failed_pipeline_error = _last_error
		return false
	_pipeline = rd.compute_pipeline_create(_shader)
	if not _pipeline.is_valid():
		rd.free_rid(_shader)
		_shader = RID()
		_last_error = "Analytic fallback compute pipeline creation failed."
		_failed_pipeline_fingerprint = fingerprint
		_failed_pipeline_error = _last_error
		return false
	return true


func _ensure_sampler(rd: RenderingDevice) -> bool:
	if _sampler.is_valid():
		return true
	var state := RDSamplerState.new()
	state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = rd.sampler_create(state)
	if not _sampler.is_valid():
		_last_error = "Analytic fallback depth sampler creation failed."
		return false
	return true


func _ensure_frame_ubos(rd: RenderingDevice, count: int) -> bool:
	while _frame_ubos.size() < count:
		var ubo := rd.uniform_buffer_create(FRAME_BYTES)
		if not ubo.is_valid():
			return false
		_frame_ubos.append(ubo)
	return true


func _pack_frame(frame: Dictionary, fog_parameters: PackedFloat32Array,
		pre_exposure: float) -> PackedFloat32Array:
	if fog_parameters.size() != 28:
		return PackedFloat32Array()
	for value in fog_parameters:
		if not is_finite(value):
			return PackedFloat32Array()
	var projection: Variant = frame.get("inverse_projection")
	var camera: Variant = frame.get("camera_transform")
	if not projection is Projection or not camera is Transform3D or not camera.is_finite():
		return PackedFloat32Array()
	var inverse_projection: Projection = projection
	for column in 4:
		var projection_axis: Vector4 = inverse_projection[column]
		if not projection_axis.is_finite():
			return PackedFloat32Array()
	var values := PackedFloat32Array()
	_append_projection(values, inverse_projection)
	var view_to_world := Transform3D(camera.basis.orthonormalized(), camera.origin)
	_append_transform(values, view_to_world)
	var frame_exposure := float(frame.get("pre_exposure", pre_exposure))
	if not is_finite(frame_exposure) or frame_exposure <= 0.0:
		return PackedFloat32Array()
	values.append_array(PackedFloat32Array([
		camera.origin.x, camera.origin.y, camera.origin.z, frame_exposure,
	]))
	values.append_array(fog_parameters.slice(4, 28))
	values.append_array(PackedFloat32Array([maxf(fog_parameters[3], 0.0), 0.0, 0.0, 0.0]))
	return values


func _append_projection(values: PackedFloat32Array, projection: Projection) -> void:
	for column in 4:
		var axis: Vector4 = projection[column]
		values.append_array(PackedFloat32Array([axis.x, axis.y, axis.z, axis.w]))


func _append_transform(values: PackedFloat32Array, transform: Transform3D) -> void:
	for axis in [transform.basis.x, transform.basis.y, transform.basis.z]:
		values.append_array(PackedFloat32Array([axis.x, axis.y, axis.z, 0.0]))
	values.append_array(PackedFloat32Array([
		transform.origin.x, transform.origin.y, transform.origin.z, 1.0,
	]))


func _update_ubo(rid: RID, values: PackedFloat32Array, rd: RenderingDevice) -> bool:
	var bytes := values.to_byte_array()
	return rid.is_valid() and bytes.size() == FRAME_BYTES \
			and rd.buffer_update(rid, 0, bytes.size(), bytes) == OK


func _valid_texture(rd: RenderingDevice, rid: RID) -> bool:
	return rid.is_valid() and rd.texture_is_valid(rid)
