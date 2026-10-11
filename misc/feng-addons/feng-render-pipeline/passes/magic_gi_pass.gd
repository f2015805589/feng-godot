@tool
class_name FengMagicGIPass
extends FengRuntimeSnapshotPass
## Applies the current lighting to a baked surface PRT field.
##
## Bake textures are cached by the immutable data identity and bake version. The
## per-frame work only refreshes the camera and live-lighting uniform buffer.

const MAGIC_GI_OUTPUT: StringName = &"magic_gi"
const IndirectGISelection = preload("../pipeline/indirect_gi_selection.gd")
const UBO_BINDING := 9
const UBO_SIZE := 448 # Three mat4, two vec4, and separate secondary/sky SH vec4 arrays.
const MAX_CACHED_BAKES := 8
const RUNTIME_SCRIPT_PATH := "res://addons/feng-magic-gi/feng_magic_gi_runtime.gd"
const SKY_DIFFUSE_TEXTURE: StringName = &"sky_light_diffuse"
const DIFFUSE_AO_BINDING := 16
const DIFFUSE_AO_VIEW_CACHE_LIMIT := 32

var _bake_resources: Dictionary = {}
var _cache_clock := 0
var _pre_exposure := 1.0
var _scene_exposure_normalization := 1.0
var _sky_diffuse_input: TextureInput
var _zero_sky_diffuse := RID()
var _replacement_request_prepared := false
var _frame_replacement_enabled := false
var _replacement_bridge_warning_shown := false
var _frame_diffuse_ao_texture := RID()
var _diffuse_ao_white := RID()
var _diffuse_ao_view_cache: Dictionary = {}
var _diffuse_ao_cache_clock := 0

func get_indirect_gi_kind() -> StringName:
	return IndirectGISelection.KIND_MAGIC

func _frp_execute(ctx: FRPPassContext) -> void:
	_frame_diffuse_ao_texture = RID()
	var rd := RenderingServer.get_rendering_device()
	if rd != null and not _diffuse_ao_view_cache.is_empty():
		_prune_diffuse_ao_view_cache(rd)
	if not IndirectGISelection.is_owner(ctx, String(get_parameter_key()),
			IndirectGISelection.KIND_MAGIC, true):
		# An active RTGI plan owns the diffuse-indirect slot, even if its scene or
		# backend is unsupported this frame. Leave native SkyDiffuse untouched and
		# clear this pass's old sidecar so no later consumer can reuse stale GI.
		_replacement_request_prepared = false
		_frame_replacement_enabled = false
		_clear_magic_gi_output(ctx)
		return
	_frame_diffuse_ao_texture = ctx.get_diffuse_ambient_occlusion_texture() if ctx != null else RID()
	_frame_replacement_enabled = false
	_pre_exposure = ctx.get_pre_exposure(0) if ctx != null else 1.0
	_scene_exposure_normalization = _get_scene_exposure_normalization(ctx)
	super._frp_execute(ctx)
	_pre_exposure = 1.0
	_scene_exposure_normalization = 1.0
	_replacement_request_prepared = false
	_frame_replacement_enabled = false
	_frame_diffuse_ao_texture = RID()

func _get_scene_exposure_normalization(ctx: FRPPassContext) -> float:
	if ctx == null:
		return 1.0
	var value: float = ctx.get_scene_exposure_normalization()
	if is_finite(value) and value > 0.0:
		return value
	return 1.0

## Prepare runs before the native lighting operation. It opts this frame into
## the exact SkyLight diffuse attachment only when a current bake can replace it.
func _frp_prepare(ctx: FRPPassContext) -> void:
	_replacement_request_prepared = false
	if ctx == null or not IndirectGISelection.is_owner(ctx, String(get_parameter_key()),
			IndirectGISelection.KIND_MAGIC, true):
		return
	var buffers := ctx.get_render_scene_buffers() as RenderSceneBuffersRD
	var snapshot := _snapshot_for_target(buffers)
	var resolved: Variant = get_resolved_parameters(ctx).get("parameters", parameters)
	var pass_strength := float(resolved.x) if resolved is Vector4 else float(parameters.x)
	if not _replacement_requested(snapshot, pass_strength):
		return
	ctx.request_sky_light_diffuse()
	_replacement_request_prepared = true

func _clear_magic_gi_output(ctx: FRPPassContext) -> void:
	if ctx == null:
		return
	var buffers := ctx.get_render_scene_buffers() as RenderSceneBuffersRD
	var rd := RenderingServer.get_rendering_device()
	if buffers == null or rd == null or inputs.size() <= 5:
		return
	var declaration: TextureInput = inputs[5]
	if declaration == null:
		return
	for view in buffers.get_view_count():
		var output := declaration.get_texture(buffers, view)
		if output.is_valid():
			rd.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)

func _replacement_requested(snapshot: Dictionary, pass_strength := 1.0) -> bool:
	return bool(snapshot.get("replacement_enabled", false)) \
		and float(snapshot.get("strength", 1.0)) * pass_strength > 0.0

func _warn_missing_replacement_bridge() -> void:
	if _replacement_bridge_warning_shown:
		return
	_replacement_bridge_warning_shown = true
	push_warning("Magic GI is using additive fallback because FRP did not provide the requested SkyLight diffuse attachment. Rebuild/update feng-godot to enable exact SkyLight replacement.")

func _parameter_bytes() -> PackedByteArray:
	var value: Vector4 = _frame_parameters if _frame_parameters is Vector4 else parameters
	return PackedFloat32Array([value.x, _pre_exposure * _scene_exposure_normalization, value.z, value.w]).to_byte_array()

func _init() -> void:
	inputs = _make_inputs()
	outputs = _make_outputs()
	_sky_diffuse_input = TextureInput.new()
	_sky_diffuse_input.binding = 12
	_sky_diffuse_input.source = TextureInput.Source.CUSTOM
	_sky_diffuse_input.custom_scope = NativeSpec.SCOPE_FRP_CLUSTERED
	_sky_diffuse_input.custom_name = SKY_DIFFUSE_TEXTURE

func runtime_script_path() -> String:
	return RUNTIME_SCRIPT_PATH

## Saved pre-PRT-v2 resources carry only four inputs and no independent output.
## FengRenderer calls this on the main thread after deserialization so old authored
## passes are upgraded without changing their enabled state or strength settings.
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
	return changed

func _make_inputs() -> Array[TextureInput]:
	var color := TextureInput.new()
	color.binding = 0
	color.source = TextureInput.Source.COLOR
	color.binding_type = TextureInput.BindingType.STORAGE_IMAGE
	var depth := TextureInput.new()
	depth.binding = 1
	depth.source = TextureInput.Source.DEPTH
	var normal := TextureInput.new()
	normal.binding = 2
	normal.source = TextureInput.Source.NORMAL_ROUGHNESS
	var albedo := TextureInput.new()
	albedo.binding = 3
	albedo.source = TextureInput.Source.ALBEDO
	var orm := TextureInput.new()
	orm.binding = 4
	orm.source = TextureInput.Source.ORM
	var contribution := TextureInput.new()
	contribution.binding = 5
	contribution.source = TextureInput.Source.CUSTOM
	contribution.custom_scope = NativeSpec.SCOPE_PIPELINE
	contribution.custom_name = MAGIC_GI_OUTPUT
	contribution.binding_type = TextureInput.BindingType.STORAGE_IMAGE
	return [color, depth, normal, albedo, orm, contribution]

func _make_outputs() -> Array[OutputDeclaration]:
	var output := OutputDeclaration.new()
	output.name = MAGIC_GI_OUTPUT
	output.data_format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	output.usage = OutputDeclaration.Usage.SAMPLED | OutputDeclaration.Usage.STORAGE | OutputDeclaration.Usage.COPY_TO
	return [output]

func get_volume_parameter_names() -> PackedStringArray:
	return PackedStringArray(["parameters"])

func refresh_resource_flags() -> void:
	# These are pass-owned inputs and requirements. Do not change FengPass's
	# raise-only behavior for third-party passes which set flags manually.
	access_resolved_color = true
	access_resolved_depth = true
	needs_normal_roughness = true
	super.refresh_resource_flags()

func _render(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice) -> void:
	var resolved_parameters: Vector4 = _frame_parameters if _frame_parameters is Vector4 else parameters
	var replacement_eligible := _replacement_requested(_frame_snapshot, resolved_parameters.x)
	var sky_diffuse: RID = _sky_diffuse_input.get_texture(buffers, view)
	_frame_replacement_enabled = replacement_eligible and _replacement_request_prepared and sky_diffuse.is_valid()
	if replacement_eligible and not _frame_replacement_enabled:
		_warn_missing_replacement_bridge()
	var output: RID = inputs[5].get_texture(buffers, view)
	if not output.is_valid():
		return
	var cache_key := str(_frame_snapshot.get("cache_key", ""))
	var data: Variant = _frame_snapshot.get("data")
	var version := int(_frame_snapshot.get("version", -1))
	if _frame_scene_data == null or cache_key.is_empty() or not is_instance_valid(data) \
			or not _ensure_bake_resources(cache_key, data, version, rd) \
			or not _update_emission_texture(cache_key, _frame_snapshot, data, rd) \
			or not _update_frame_ubo(_frame_snapshot, _frame_scene_data, view, rd):
		rd.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)
		return
	var cached: Dictionary = _bake_resources[cache_key]
	_cache_clock += 1
	cached["last_used"] = _cache_clock
	_bake_resources[cache_key] = cached
	var shader_before := _shader
	var compute_before := _compute_pipeline
	var sampler_before := _sampler
	var raster_count_before := _raster_pipelines.size()
	super._render(buffers, view, rd)
	if shader_before != _shader or compute_before != _compute_pipeline \
			or sampler_before != _sampler or raster_count_before != _raster_pipelines.size():
		_sync_owned_rid_snapshot()

func _ensure_bake_resources(cache_key: String, data: Resource, version: int, rd: RenderingDevice) -> bool:
	if _bake_resources.has(cache_key):
		var cached: Dictionary = _bake_resources[cache_key]
		if cached.get("data_id", -1) == data.get_instance_id() \
				and cached.get("version", -1) == version \
				and cached.get("transfer", RID()).is_valid() \
				and cached.get("primary_sky", RID()).is_valid() \
				and cached.get("geometry", RID()).is_valid() \
				and cached.get("visibility_moments", RID()).is_valid() \
				and cached.get("visibility_nodes", RID()).is_valid() \
				and cached.get("visibility_triangles", RID()).is_valid() \
				and cached.get("indices", RID()).is_valid() \
				and cached.get("emission", RID()).is_valid():
			return true
		_release_bake_resources(cache_key, rd)

	# Data owns validation and all atlas layouts. It validates once, then prepares
	# the complete immutable upload bundle; the FRP boundary only checks its shape.
	if not data.has_method("make_render_upload"):
		_report("The selected Magic GI bake does not provide runtime upload data; rebake or update the Magic GI addon.")
		return false
	var upload: Variant = data.call("make_render_upload")
	if not upload is Dictionary:
		_report("The selected Magic GI bake is invalid or stale; rebake it with the current PRT format.")
		return false
	var transfer_value: Variant = upload.get("transfer_image")
	var primary_sky_value: Variant = upload.get("primary_sky_image")
	var geometry_value: Variant = upload.get("geometry_image")
	var visibility_value: Variant = upload.get("visibility_moment_image")
	var node_value: Variant = upload.get("visibility_node_bytes")
	var triangle_value: Variant = upload.get("visibility_triangle_bytes")
	var index_value: Variant = upload.get("index_bytes")
	var emission_value: Variant = upload.get("emission_image")
	if not transfer_value is Image or not primary_sky_value is Image or not geometry_value is Image \
			or not visibility_value is Image \
			or not node_value is PackedByteArray or not triangle_value is PackedByteArray \
			or not index_value is PackedByteArray \
			or not emission_value is Image:
		_report("The selected Magic GI bake could not create its complete PRT upload bundle.")
		return false
	var transfer_image: Image = transfer_value
	var primary_sky_image: Image = primary_sky_value
	var geometry_image: Image = geometry_value
	var visibility_image: Image = visibility_value
	var node_bytes: PackedByteArray = node_value
	var triangle_bytes: PackedByteArray = triangle_value
	var index_bytes: PackedByteArray = index_value
	var emission_image: Image = emission_value
	if transfer_image.is_empty() or primary_sky_image.is_empty() or geometry_image.is_empty() \
			or visibility_image.is_empty() or index_bytes.is_empty() \
			or node_bytes.is_empty() or node_bytes.size() % 32 != 0 \
			or triangle_bytes.is_empty() or triangle_bytes.size() % 48 != 0 \
			or emission_image.is_empty():
		_report("The selected Magic GI bake returned an empty runtime upload payload.")
		return false
	var transfer_rid := _create_image_texture(rd, transfer_image, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
	var primary_sky_rid := _create_image_texture(rd, primary_sky_image, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
	var geometry_rid := _create_image_texture(rd, geometry_image, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
	var visibility_rid := _create_image_texture(rd, visibility_image, RenderingDevice.DATA_FORMAT_R32G32_SFLOAT)
	var node_rid := rd.storage_buffer_create(node_bytes.size(), node_bytes)
	var triangle_rid := rd.storage_buffer_create(triangle_bytes.size(), triangle_bytes)
	var dims: Vector3i = data.get("grid_dims")
	var index_rid := _create_index_texture(rd, dims, index_bytes)
	var emission_rid := _create_image_texture(rd, emission_image, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,
			RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT)
	if not transfer_rid.is_valid() or not primary_sky_rid.is_valid() or not geometry_rid.is_valid() \
			or not visibility_rid.is_valid() \
			or not node_rid.is_valid() or not triangle_rid.is_valid() \
			or not index_rid.is_valid() or not emission_rid.is_valid():
		for rid in [transfer_rid, primary_sky_rid, geometry_rid, visibility_rid,
				node_rid, triangle_rid, index_rid, emission_rid]:
			if rid.is_valid():
				rd.free_rid(rid)
		_report("RenderingDevice could not upload the Magic GI PRT atlas, emission atlas, or index grid.")
		return false
	_bake_resources[cache_key] = {
		"data_id": data.get_instance_id(),
		"version": version,
		"transfer": transfer_rid,
		"primary_sky": primary_sky_rid,
		"geometry": geometry_rid,
		"visibility_moments": visibility_rid,
		"visibility_nodes": node_rid,
		"visibility_triangles": triangle_rid,
		"indices": index_rid,
		"emission": emission_rid,
		"emission_identity": "",
		"emission_revision": -1,
		"grid_dims": dims,
		"spacing": float(data.get("spacing")),
		"probe_count": int(data.call("probe_count")),
		"exact_visibility": int(data.get("format_version")) >= 6,
		"last_used": _cache_clock,
	}
	_prune_bake_cache(rd)
	_sync_owned_rid_snapshot()
	return true

func _make_emission_image(data: Resource, snapshot: Dictionary) -> Image:
	var payload: Variant = snapshot.get("emission_payload", PackedFloat32Array())
	if not payload is PackedFloat32Array:
		_report("Magic GI emissive response is not a packed float array; using a black emission atlas.")
		payload = PackedFloat32Array()
	var payload_array: PackedFloat32Array = payload
	var image: Variant = data.call("make_emission_atlas_image", payload_array)
	if image is Image:
		return image
	if not payload_array.is_empty():
		_report("Magic GI emissive response does not match the bake; using a black emission atlas.")
	image = data.call("make_emission_atlas_image", PackedFloat32Array())
	return image if image is Image else null

func _update_emission_texture(cache_key: String, snapshot: Dictionary, data: Resource, rd: RenderingDevice) -> bool:
	if not _bake_resources.has(cache_key):
		return false
	var cached: Dictionary = _bake_resources[cache_key]
	var identity := str(snapshot.get("emission_identity", cache_key))
	var revision := int(snapshot.get("emission_revision", 0))
	if cached.get("emission_identity", "") == identity \
			and cached.get("emission_revision", -1) == revision:
		return true
	var image := _make_emission_image(data, snapshot)
	if image == null:
		_report("Magic GI could not create the emissive atlas.")
		return false
	var emission_rid: RID = cached.get("emission", RID())
	if not emission_rid.is_valid() or rd.texture_update(emission_rid, 0, image.get_data()) != OK:
		_report("RenderingDevice could not update the Magic GI emission atlas.")
		return false
	cached["emission_identity"] = identity
	cached["emission_revision"] = revision
	_bake_resources[cache_key] = cached
	return true

func _create_image_texture(rd: RenderingDevice, image: Image, data_format: int, extra_usage_bits := 0) -> RID:
	return _create_texture(rd, image.get_size(), data_format, image.get_data(), extra_usage_bits)

func _create_index_texture(rd: RenderingDevice, dims: Vector3i, bytes: PackedByteArray) -> RID:
	return _create_texture(rd, Vector2i(dims.x * 8, dims.y * dims.z), RenderingDevice.DATA_FORMAT_R32_SINT, bytes)

func _create_texture(rd: RenderingDevice, size: Vector2i, data_format: int, bytes: PackedByteArray,
		extra_usage_bits := 0) -> RID:
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.format = data_format
	format.width = size.x
	format.height = size.y
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | extra_usage_bits
	return rd.texture_create(format, RDTextureView.new(), [bytes])

func _prune_bake_cache(rd: RenderingDevice) -> void:
	while _bake_resources.size() > MAX_CACHED_BAKES:
		var oldest_key: String = ""
		var oldest := 0x7fffffff
		for key in _bake_resources:
			var last_used := int(_bake_resources[key].get("last_used", 0))
			if last_used < oldest:
				oldest = last_used
				oldest_key = str(key)
		if oldest_key == "":
			return
		_release_bake_resources(oldest_key, rd)

func _release_bake_resources(cache_key: String, rd: RenderingDevice) -> void:
	_free_rids(rd, _take_bake_rids(cache_key))
	_sync_owned_rid_snapshot()

func _take_bake_rids(cache_key: String) -> Array[RID]:
	var rids: Array[RID] = []
	if not _bake_resources.has(cache_key):
		return rids
	var cached: Dictionary = _bake_resources[cache_key]
	_bake_resources.erase(cache_key)
	for name in ["transfer", "primary_sky", "geometry", "visibility_moments",
			"visibility_nodes", "visibility_triangles", "indices", "emission"]:
		var rid: RID = cached.get(name, RID())
		if rid.is_valid():
			rids.append(rid)
	return rids

func _update_frame_ubo(snapshot: Dictionary, scene_data: RenderSceneData, view: int, rd: RenderingDevice) -> bool:
	if scene_data == null or view >= scene_data.get_view_count():
		return false
	var cached: Dictionary = _bake_resources[str(snapshot.get("cache_key", ""))]
	var inverse_view_projection: Projection = scene_data.get_view_projection(view).inverse()
	var camera: Transform3D = scene_data.get_cam_transform()
	var dimensions: Vector3i = cached["grid_dims"]
	var lighting: Variant = snapshot.get("lighting", PackedFloat32Array())
	if not lighting is PackedFloat32Array or lighting.size() != 27:
		return false
	var sky_lighting: Variant = snapshot.get("sky_lighting", PackedFloat32Array())
	if not sky_lighting is PackedFloat32Array or sky_lighting.size() != 27:
		sky_lighting = PackedFloat32Array()
		sky_lighting.resize(27)
	var values := PackedFloat32Array()
	_append_projection(values, inverse_view_projection)
	var bake_data: Resource = snapshot["data"]
	var world_to_grid: Transform3D = bake_data.get("world_to_grid")
	_append_transform(values, world_to_grid)
	_append_transform(values, Transform3D(camera.basis.orthonormalized(), camera.origin))
	values.append_array(PackedFloat32Array([float(dimensions.x), float(dimensions.y), float(dimensions.z), float(cached["probe_count"])]))
	values.append_array(PackedFloat32Array([
		float(snapshot.get("strength", 1.0)),
		float(cached["spacing"]),
		1.0 if _frame_replacement_enabled else 0.0,
		1.0 if cached["exact_visibility"] else 0.0,
	]))
	for coefficients in [lighting, sky_lighting]:
		values.append_array(coefficients)
		values.append(0.0) # SH9 RGB occupies seven vec4s, with one padding lane.
	# No bake or no runtime producer is a true no-op: only allocate GPU state
	# after the matching, validated snapshot has made it all the way to the shader.
	return _commit_frame_ubo(values, UBO_SIZE, rd)

func _commit_frame_ubo(values: PackedFloat32Array, ubo_size: int, rd: RenderingDevice) -> bool:
	var had_ubo := _ubo.is_valid()
	var succeeded := super._commit_frame_ubo(values, ubo_size, rd)
	if succeeded and not had_ubo:
		_sync_owned_rid_snapshot()
	return succeeded

func _collect_bindings(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice) -> Dictionary:
	var binding_data := super._collect_bindings(buffers, view, rd)
	if _binding_error or _frame_snapshot.is_empty():
		return binding_data
	var cache_key := str(_frame_snapshot.get("cache_key", ""))
	if not _bake_resources.has(cache_key) or not _ensure_sampler(rd):
		_binding_error = true
		return binding_data
	var cached: Dictionary = _bake_resources[cache_key]
	var uniforms: Array[RDUniform] = binding_data["uniforms"]
	var sky_diffuse: RID = _sky_diffuse_input.get_texture(buffers, view)
	if not sky_diffuse.is_valid():
		sky_diffuse = _ensure_zero_sky_diffuse(rd)
	if not sky_diffuse.is_valid():
		_binding_error = true
		_report("Cannot create the zero SkyLight diffuse fallback texture.")
		return binding_data
	for spec in [
		{"binding": 6, "texture": cached["transfer"]},
		{"binding": 7, "texture": cached["geometry"]},
		{"binding": 8, "texture": cached["indices"]},
		{"binding": 10, "texture": cached["emission"]},
		{"binding": 11, "texture": cached["primary_sky"]},
		{"binding": 12, "texture": sky_diffuse},
		{"binding": 13, "texture": cached["visibility_moments"]},
	]:
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		uniform.binding = int(spec["binding"])
		uniform.add_id(_sampler)
		uniform.add_id(spec["texture"])
		uniforms.append(uniform)
	var diffuse_ao := _get_diffuse_ao_view(buffers, view, rd)
	if not diffuse_ao.is_valid():
		diffuse_ao = _ensure_white_diffuse_ao(rd)
	if not diffuse_ao.is_valid():
		_binding_error = true
		_report("Cannot create the neutral diffuse AO texture.")
		return binding_data
	var diffuse_ao_uniform := RDUniform.new()
	diffuse_ao_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	diffuse_ao_uniform.binding = DIFFUSE_AO_BINDING
	diffuse_ao_uniform.add_id(_sampler)
	diffuse_ao_uniform.add_id(diffuse_ao)
	uniforms.append(diffuse_ao_uniform)
	for spec in [
		{"binding": 14, "buffer": cached["visibility_nodes"]},
		{"binding": 15, "buffer": cached["visibility_triangles"]},
	]:
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		uniform.binding = int(spec["binding"])
		uniform.add_id(spec["buffer"])
		uniforms.append(uniform)
	uniforms.append(_ubo_uniform(UBO_BINDING))
	binding_data["uniforms"] = uniforms
	return binding_data

func _get_diffuse_ao_view(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice) -> RID:
	var texture := _frame_diffuse_ao_texture
	if buffers == null or not texture.is_valid() or not rd.texture_is_valid(texture):
		return RID()
	var format := rd.texture_get_format(texture)
	var size := buffers.get_internal_size()
	var multi := buffers.get_view_count() > 1
	var expected_type := RenderingDevice.TEXTURE_TYPE_2D_ARRAY if multi else RenderingDevice.TEXTURE_TYPE_2D
	if format.texture_type != expected_type or (format.usage_bits & RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT) == 0 \
			or format.width != size.x or format.height != size.y \
			or (multi and format.array_layers < buffers.get_view_count()):
		return RID()
	if not multi:
		return texture
	var cache_key := "%s:%d" % [str(texture.get_id()), view]
	_diffuse_ao_cache_clock += 1
	var cached: Dictionary = _diffuse_ao_view_cache.get(cache_key, {})
	if not cached.is_empty() and cached.get("base", RID()) == texture and rd.texture_is_valid(cached.get("view", RID())):
		cached["last_used"] = _diffuse_ao_cache_clock
		_diffuse_ao_view_cache[cache_key] = cached
		return cached["view"]
	var texture_view := RDTextureView.new()
	texture_view.format_override = format.format
	var slice := rd.texture_create_shared_from_slice(texture_view, texture, view, 0, 1, RenderingDevice.TEXTURE_SLICE_2D)
	if not slice.is_valid():
		return RID()
	_diffuse_ao_view_cache[cache_key] = {"base": texture, "view": slice, "last_used": _diffuse_ao_cache_clock}
	_prune_diffuse_ao_view_cache(rd)
	_sync_owned_rid_snapshot()
	return slice

func _prune_diffuse_ao_view_cache(rd: RenderingDevice) -> void:
	var removed_invalid := false
	for key in _diffuse_ao_view_cache.keys():
		var cached: Dictionary = _diffuse_ao_view_cache[key]
		var base: RID = cached.get("base", RID())
		var view: RID = cached.get("view", RID())
		if not base.is_valid() or not rd.texture_is_valid(base) or not view.is_valid() or not rd.texture_is_valid(view):
			if view.is_valid() and rd.texture_is_valid(view):
				rd.free_rid(view)
			_diffuse_ao_view_cache.erase(key)
			removed_invalid = true
	while _diffuse_ao_view_cache.size() > DIFFUSE_AO_VIEW_CACHE_LIMIT:
		var oldest_key := ""
		var oldest := 0x7fffffff
		for key in _diffuse_ao_view_cache:
			var last_used := int(_diffuse_ao_view_cache[key].get("last_used", 0))
			if last_used < oldest:
				oldest = last_used
				oldest_key = str(key)
		if oldest_key.is_empty():
			return
		var cached: Dictionary = _diffuse_ao_view_cache[oldest_key]
		var view: RID = cached.get("view", RID())
		if view.is_valid():
			rd.free_rid(view)
		_diffuse_ao_view_cache.erase(oldest_key)
		removed_invalid = true
	if removed_invalid:
		_sync_owned_rid_snapshot()

func _ensure_white_diffuse_ao(rd: RenderingDevice) -> RID:
	if _diffuse_ao_white.is_valid() and rd.texture_is_valid(_diffuse_ao_white):
		return _diffuse_ao_white
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.format = RenderingDevice.DATA_FORMAT_R16_SFLOAT
	format.width = 1
	format.height = 1
	format.depth = 1
	format.array_layers = 1
	format.mipmaps = 1
	format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	# IEEE 754 binary16 1.0, serialized little-endian for one R16F texel.
	_diffuse_ao_white = rd.texture_create(format, RDTextureView.new(), [PackedByteArray([0x00, 0x3c])])
	_sync_owned_rid_snapshot()
	return _diffuse_ao_white

func _ensure_zero_sky_diffuse(rd: RenderingDevice) -> RID:
	if _zero_sky_diffuse.is_valid():
		return _zero_sky_diffuse
	var image := Image.create_empty(1, 1, false, Image.FORMAT_RGBAH)
	if image == null:
		return RID()
	image.set_pixel(0, 0, Color(0, 0, 0, 0))
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	format.width = 1
	format.height = 1
	format.depth = 1
	format.array_layers = 1
	format.mipmaps = 1
	format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var layer_data: Array[PackedByteArray] = [image.get_data()]
	_zero_sky_diffuse = rd.texture_create(format, RDTextureView.new(), layer_data)
	_sync_owned_rid_snapshot()
	return _zero_sky_diffuse

func _current_owned_rids() -> Array[RID]:
	var rids: Array[RID] = []
	rids.append_array(_raster_pipelines.values())
	rids.append_array([_compute_pipeline, _shader, _sampler, _ubo])
	rids.append_array([_zero_sky_diffuse, _diffuse_ao_white])
	for cached in _bake_resources.values():
		for name in ["transfer", "primary_sky", "geometry", "visibility_moments",
				"visibility_nodes", "visibility_triangles", "indices", "emission"]:
			var rid: RID = cached.get(name, RID())
			if rid.is_valid():
				rids.append(rid)
	for cached in _diffuse_ao_view_cache.values():
		var view: RID = cached.get("view", RID())
		var rd := RenderingServer.get_rendering_device()
		if view.is_valid() and rd != null and rd.texture_is_valid(view):
			rids.append(view)
	return rids

func _sync_owned_rid_snapshot() -> void:
	_replace_owned_rid_snapshot(_current_owned_rids())

func _take_owned_rids() -> Array[RID]:
	# PREDELETE invalidates this script's live dispatch after the inherited
	# shader pass transfers its RIDs. Capture the complete owned-only inventory
	# and clear our fields first; only append the detached snapshot afterwards.
	var owned_rids: Array[RID] = super.call("_current_owned_rids")
	_bake_resources.clear()
	_zero_sky_diffuse = RID()
	_diffuse_ao_white = RID()
	_frame_diffuse_ao_texture = RID()
	_diffuse_ao_view_cache.clear()
	var rids := super._take_owned_rids()
	rids.append_array(owned_rids)
	return rids
