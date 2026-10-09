@tool
extends RefCounted
## Late screen-color composition for the already integrated 3D volume.
## This owns only its pipeline and sampler; FRP textures and the pass UBO are borrowed.

const SHADER_ROOT := "res://addons/feng-fog/rendering/shaders/"
const OwnedRids = preload("res://addons/feng-render-pipeline/rd/owned_rids.gd")
const ShaderSource = preload("res://addons/feng-render-pipeline/rd/shader_source.gd")
const RDUniforms = preload("res://addons/feng-render-pipeline/rd/uniforms.gd")
const FRAME_BYTES := 256
const WORKGROUP := 8

var _pipeline := RID()
var _shader := RID()
var _sampler := RID()
var _empty_volume_texture := RID()
var _empty_fsss_texture := RID()
var _empty_cloud_radiance := RID()
var _empty_cloud_transmittance := RID()
var _frame_ubos: Array[RID] = []
var _last_error := ""
var _failed_pipeline_fingerprint := ""
var _failed_pipeline_error := ""


func composite_volume_and_fsss(rd: RenderingDevice, color_layers: Array[RID],
		depth_layers: Array[RID], volume_texture: RID, fsss_textures: Array,
		sampling_ubos: Array[RID], frames: Array[Dictionary],
		fog_parameters_by_view: Array[PackedFloat32Array], size: Vector2i,
		cloud_composition: Dictionary = {}) -> bool:
	_last_error = ""
	if rd == null or size.x <= 0 or size.y <= 0 \
			or color_layers.is_empty() or color_layers.size() != depth_layers.size() \
			or sampling_ubos.size() < color_layers.size() \
			or color_layers.size() != frames.size() \
			or color_layers.size() != fog_parameters_by_view.size():
		_last_error = "Late volume composite inputs have inconsistent view counts or size."
		return false
	if not _ensure_pipeline(rd) or not _ensure_sampler(rd):
		if _last_error.is_empty():
			_last_error = "Late volume composite pipeline or sampler is unavailable."
		return false
	if not _ensure_frame_ubos(rd, frames.size()):
		_last_error = "Late volume composite frame UBO allocation failed."
		return false
	var uniform_sets: Array[RID] = []
	for view in color_layers.size():
		var color: RID = color_layers[view]
		var depth: RID = depth_layers[view]
		var ubo: RID = sampling_ubos[view]
		if not _valid_texture(rd, color) or not _valid_texture(rd, depth) or not ubo.is_valid():
			_last_error = "Late volume composite preflight failed at view %d: color, depth, or sampling UBO is invalid." % view
			return false
		var volume := volume_texture if _valid_texture(rd, volume_texture) else _empty_volume(rd)
		if not volume.is_valid():
			_last_error = "Late volume composite preflight failed at view %d: volume placeholder allocation failed." % view
			return false
		var fsss: RID = fsss_textures[view] if view < fsss_textures.size() else RID()
		if not _valid_texture(rd, fsss):
			fsss = _empty_fsss(rd)
		if not fsss.is_valid():
			_last_error = "Late volume composite preflight failed at view %d: FSSS placeholder allocation failed." % view
			return false
		var raw_cloud_radiance: Variant = cloud_composition.get("radiance", RID())
		var raw_cloud_transmittance: Variant = cloud_composition.get("transmittance", RID())
		var cloud_radiance: RID = raw_cloud_radiance if raw_cloud_radiance is RID else RID()
		var cloud_transmittance: RID = raw_cloud_transmittance \
				if raw_cloud_transmittance is RID else RID()
		var cloud_valid: bool = cloud_composition.get("view_count", 0) == frames.size() \
				and cloud_composition.get("internal_size", Vector2i.ZERO) == size \
				and _valid_texture(rd, cloud_radiance) and _valid_texture(rd, cloud_transmittance)
		if not cloud_valid:
			cloud_radiance = _ensure_empty_cloud_radiance(rd)
			cloud_transmittance = _ensure_empty_cloud_transmittance(rd)
		if not cloud_radiance.is_valid() or not cloud_transmittance.is_valid():
			_last_error = "Late volume composite preflight failed at view %d: cloud placeholder allocation failed." % view
			return false
		var frame_values := _pack_frame(frames[view], fog_parameters_by_view[view], view, cloud_valid)
		if frame_values.size() * 4 != FRAME_BYTES \
				or not _update_ubo(_frame_ubos[view], frame_values, rd):
			_last_error = "Late volume composite preflight failed at view %d: frame UBO update failed." % view
			return false
		var uniforms: Array[RDUniform] = [
			RDUniforms.image(0, color),
			RDUniforms.sampled(1, _sampler, depth),
			RDUniforms.uniform_buffer(2, _frame_ubos[view]),
			RDUniforms.sampled(9, _sampler, volume),
			RDUniforms.sampled(10, _sampler, fsss),
			RDUniforms.uniform_buffer(11, ubo),
			RDUniforms.sampled(12, _sampler, cloud_radiance),
			RDUniforms.sampled(13, _sampler, cloud_transmittance),
		]
		var uniform_set := UniformSetCacheRD.get_cache(_shader, 0, uniforms)
		if not uniform_set.is_valid():
			_last_error = "Late volume composite preflight failed at view %d: uniform set creation failed." % view
			return false
		uniform_sets.append(uniform_set)
	# No color is written until every view has valid inputs and a ready uniform set.
	var list := rd.compute_list_begin()
	if list < 0:
		_last_error = "Late volume composite dispatch could not begin after all-view preflight."
		return false
	rd.compute_list_bind_compute_pipeline(list, _pipeline)
	for view in uniform_sets.size():
		rd.compute_list_bind_uniform_set(list, uniform_sets[view], 0)
		rd.compute_list_dispatch(list, ceili(float(size.x) / WORKGROUP),
				ceili(float(size.y) / WORKGROUP), 1)
	rd.compute_list_end()
	return true


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
	OwnedRids.append(result, seen, _empty_volume_texture)
	OwnedRids.append(result, seen, _empty_fsss_texture)
	OwnedRids.append(result, seen, _empty_cloud_radiance)
	OwnedRids.append(result, seen, _empty_cloud_transmittance)
	OwnedRids.append_all(result, seen, _frame_ubos)
	if p_clear:
		_pipeline = RID()
		_shader = RID()
		_failed_pipeline_fingerprint = ""
		_failed_pipeline_error = ""
		_sampler = RID()
		_empty_volume_texture = RID()
		_empty_fsss_texture = RID()
		_empty_cloud_radiance = RID()
		_empty_cloud_transmittance = RID()
		_frame_ubos.clear()
	return result


func get_last_error() -> String:
	return _last_error


func _ensure_pipeline(rd: RenderingDevice) -> bool:
	if _pipeline.is_valid() and _shader.is_valid():
		return true
	var path := SHADER_ROOT.path_join("volumetric_fog_composite.glslinc")
	if not FileAccess.file_exists(path):
		_last_error = "Cannot load volume composite shader."
		return false
	var source := FileAccess.get_file_as_string(path)
	var expanded := ShaderSource.expand(path, source)
	if expanded.is_empty():
		_last_error = "Cannot expand volume composite shader includes."
		return false
	var source_fingerprint: String = expanded.sha256_text()
	if source_fingerprint == _failed_pipeline_fingerprint:
		_last_error = _failed_pipeline_error
		return false
	_failed_pipeline_fingerprint = ""
	_failed_pipeline_error = ""
	var shader_source := RDShaderSource.new()
	shader_source.source_compute = expanded.replace("#[compute]", "")
	var spirv := rd.shader_compile_spirv_from_source(shader_source)
	if spirv == null or not spirv.compile_error_compute.is_empty():
		_last_error = "Volume composite shader compile failed: %s" % \
				(spirv.compile_error_compute if spirv != null else "no SPIR-V result")
		_failed_pipeline_fingerprint = source_fingerprint
		_failed_pipeline_error = _last_error
		return false
	_shader = rd.shader_create_from_spirv(spirv)
	if not _shader.is_valid():
		_last_error = "Cannot create volume composite shader RID."
		_failed_pipeline_fingerprint = source_fingerprint
		_failed_pipeline_error = _last_error
		return false
	_pipeline = rd.compute_pipeline_create(_shader)
	if not _pipeline.is_valid():
		rd.free_rid(_shader)
		_shader = RID()
		_last_error = "Cannot create volume composite compute pipeline."
		_failed_pipeline_fingerprint = source_fingerprint
		_failed_pipeline_error = _last_error
		return false
	return true


func _ensure_sampler(rd: RenderingDevice) -> bool:
	if _sampler.is_valid():
		return true
	var state := RDSamplerState.new()
	state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = rd.sampler_create(state)
	return _sampler.is_valid()


func _ensure_frame_ubos(rd: RenderingDevice, count: int) -> bool:
	while _frame_ubos.size() < count:
		var ubo := rd.uniform_buffer_create(FRAME_BYTES)
		if not ubo.is_valid():
			return false
		_frame_ubos.append(ubo)
	return true


func _pack_frame(frame: Dictionary, fog_parameters: PackedFloat32Array, view: int,
		cloud_valid: bool) -> PackedFloat32Array:
	if fog_parameters.size() != 28:
		return PackedFloat32Array()
	var values := PackedFloat32Array()
	_append_projection(values, frame.inverse_projection)
	_append_transform(values, frame.camera_transform)
	values.append_array(PackedFloat32Array([
		frame.camera_transform.origin.x, frame.camera_transform.origin.y,
		frame.camera_transform.origin.z, 1.0,
	]))
	# The first vec4 of _make_forward_parameters is the camera position and
	# volume far distance. CompositeFrame stores camera_position separately, so
	# copy only the six actual analytic-fog vec4s here.
	values.append_array(fog_parameters.slice(4, 28))
	values.append_array(PackedFloat32Array([float(view), 1.0 if cloud_valid else 0.0, 0.0, 0.0]))
	return values


func _append_projection(values: PackedFloat32Array, projection: Projection) -> void:
	for column in 4:
		var axis: Vector4 = projection[column]
		values.append_array(PackedFloat32Array([axis.x, axis.y, axis.z, axis.w]))


func _append_transform(values: PackedFloat32Array, transform: Transform3D) -> void:
	for axis in [transform.basis.x, transform.basis.y, transform.basis.z]:
		values.append_array(PackedFloat32Array([axis.x, axis.y, axis.z, 0.0]))
	values.append_array(PackedFloat32Array([transform.origin.x, transform.origin.y,
			transform.origin.z, 1.0]))


func _update_ubo(rid: RID, values: PackedFloat32Array, rd: RenderingDevice) -> bool:
	var bytes := values.to_byte_array()
	return rid.is_valid() and bytes.size() == FRAME_BYTES \
			and rd.buffer_update(rid, 0, bytes.size(), bytes) == OK


func _empty_volume(rd: RenderingDevice) -> RID:
	if _valid_texture(rd, _empty_volume_texture):
		return _empty_volume_texture
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	format.width = 1
	format.height = 1
	format.depth = 1
	format.array_layers = 1
	format.mipmaps = 1
	format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	# RGBA16F is eight bytes per texel: zero RGB, half-float 1.0 alpha.
	_empty_volume_texture = rd.texture_create(format, RDTextureView.new(), [
		PackedByteArray([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3c])])
	return _empty_volume_texture


func _empty_fsss(rd: RenderingDevice) -> RID:
	if _valid_texture(rd, _empty_fsss_texture):
		return _empty_fsss_texture
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.width = 1
	format.height = 1
	format.depth = 1
	format.array_layers = 1
	format.mipmaps = 1
	format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	_empty_fsss_texture = rd.texture_create(format, RDTextureView.new(), [
		PackedByteArray([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])])
	return _empty_fsss_texture


func _ensure_empty_cloud_radiance(rd: RenderingDevice) -> RID:
	if _valid_texture(rd, _empty_cloud_radiance):
		return _empty_cloud_radiance
	var format := _empty_cloud_texture_format()
	_empty_cloud_radiance = rd.texture_create(format, RDTextureView.new(), [
		PackedByteArray([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])])
	return _empty_cloud_radiance


func _ensure_empty_cloud_transmittance(rd: RenderingDevice) -> RID:
	if _valid_texture(rd, _empty_cloud_transmittance):
		return _empty_cloud_transmittance
	var format := _empty_cloud_texture_format()
	_empty_cloud_transmittance = rd.texture_create(format, RDTextureView.new(), [
		PackedByteArray([0x00, 0x3c, 0x00, 0x3c, 0x00, 0x3c, 0x00, 0x3c])])
	return _empty_cloud_transmittance


func _empty_cloud_texture_format() -> RDTextureFormat:
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	format.width = 1
	format.height = 1
	format.depth = 1
	format.array_layers = 1
	format.mipmaps = 1
	format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	return format


func _valid_texture(rd: RenderingDevice, rid: RID) -> bool:
	return rid.is_valid() and rd.texture_is_valid(rid)
