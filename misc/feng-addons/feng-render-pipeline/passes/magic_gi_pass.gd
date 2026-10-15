@tool
class_name FengMagicGIPass
extends FengRuntimeSnapshotPass
## Applies the current lighting to a baked surface PRT field.
##
## Bake textures are cached by the immutable data identity and bake version. The
## Lighting is cached per bake and refreshed only when its sources change.

const U = preload("../rd/uniforms.gd")
const DirectionalCache = preload("magic_gi_directional_cache.gd")
const ClipmapCache = preload("magic_gi_clv_cache.gd")
const PageStream = preload("magic_gi_page_stream.gd")
const PageResidency = preload("magic_gi_page_residency.gd")
const PageUpload = preload("magic_gi_page_upload.gd")
const ProbeClusters = preload("magic_gi_probe_clusters.gd")
const MAGIC_GI_OUTPUT: StringName = &"magic_gi"
const IndirectGISelection = preload("../pipeline/indirect_gi_selection.gd")
const UBO_BINDING := 9
const UBO_SIZE := 448 # Three mat4, two vec4, and separate secondary/sky SH vec4 arrays.
const MAX_CACHED_BAKES := 8
const MAX_FAILED_STREAM_PAGE_REVISIONS := 512
const RUNTIME_SCRIPT_PATH := "res://addons/feng-magic-gi/feng_magic_gi_runtime.gd"
const SKY_DIFFUSE_TEXTURE: StringName = &"sky_light_diffuse"
const DIFFUSE_AO_BINDING := 16
const DIFFUSE_AO_VIEW_CACHE_LIMIT := 32
const RELIGHT_SHADER: RDShaderFile = preload("../library/magic-gi/magic_gi_relight.glsl")
const PENDING_PAGE_SHADER: RDShaderFile = preload("../library/magic-gi/magic_gi_pending_page.glsl")
const PAGE_PARAMS_BINDING := 23
const PAGE_PARAMS_SIZE := 128
const PENDING_PARAMS_SIZE := 256
const PROBE_CLUSTER_BINDING := 24
const PROBE_CLUSTER_CPU_CACHE_LIMIT := 32
const PROBE_CLUSTER_CPU_CACHE_BYTES := 16 * 1024 * 1024

enum CLVDebugView { OFF, CASCADE_LEVELS, CACHE_VALIDITY, CELLS, RECONSTRUCTED_LIGHTING }

## Choose Magic GI in Debug Buffers to view this. Set GI Exposure to 0 EV for
## color-coded views. Reconstructed Lighting follows current exposure but omits
## receiver albedo, AO, and GI strength.
@export_enum("Off", "Cascade Levels", "Cache Validity", "Cells", "Reconstructed Lighting")
var clv_debug_view: int = CLVDebugView.OFF:
	set(value):
		var next := clampi(value, CLVDebugView.OFF, CLVDebugView.RECONSTRUCTED_LIGHTING)
		if clv_debug_view == next:
			return
		clv_debug_view = next
		emit_changed()

var _relight_shader := RID()
var _relight_pipeline := RID()
var _clipmaps: Dictionary = {}
var _frame_clipmap: RefCounted
var _clv_fallback: Dictionary = {}

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
var _page_residency: RefCounted
var _page_uploads: Dictionary = {}
var _page_ready_by_key: Dictionary = {}
var _page_failed_versions: Dictionary = {}
var _page_params_ubo := RID()
var _probe_cluster_fallback := RID()
var _pending_page_params_ubo := RID()
var _pending_page_shader := RID()
var _pending_page_pipeline := RID()
var _stream_frame_token := -1
var _stream_demand_frame_token := -1
var _stream_frame_demands: Dictionary = {}
var _stream_dispatch_active := false
var _stream_dispatch_rect := Rect2i()
var _stream_dispatch_extent := Vector2i()
var probe_cluster_culling_enabled := true
var _probe_cluster_payload_cache: Dictionary = {}
var _probe_cluster_payload_cache_bytes := 0
var _probe_cluster_payload_cache_clock := 0
var _probe_cluster_debug_frame := -1
var _probe_cluster_debug_bound_keys: Dictionary = {}

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
	if bool(snapshot.get("streamed", false)):
		_request_streaming_views(ctx, buffers)
	var resolved: Variant = get_resolved_parameters(ctx).get("parameters", parameters)
	var pass_strength := float(resolved.x) if resolved is Vector4 else float(parameters.x)
	if not _replacement_requested(snapshot, pass_strength):
		return
	ctx.request_sky_light_diffuse()
	_replacement_request_prepared = true

func _request_streaming_views(ctx: FRPPassContext, buffers: RenderSceneBuffersRD) -> void:
	if ctx == null or buffers == null:
		return
	var runtime_script := _get_runtime_script()
	if runtime_script == null or not runtime_script.has_method("request_streaming_view"):
		return
	var render_data := ctx.get_render_data()
	var scene_data := render_data.get_render_scene_data() if render_data != null else null
	if scene_data == null:
		return
	var camera: Transform3D = scene_data.get_cam_transform()
	var target: RID = buffers.get_render_target()
	if not target.is_valid():
		return
	for view in buffers.get_view_count():
		runtime_script.call("request_streaming_view", target, view, camera.origin, AABB())

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
	return PackedFloat32Array([value.x, _pre_exposure * _scene_exposure_normalization,
		value.z, float(clv_debug_view)]).to_byte_array()

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


## Diagnostic switch for paired validation; normal rendering enables culling when
## the immutable page metadata is valid.
func set_probe_cluster_culling_enabled(enabled: bool) -> void:
	probe_cluster_culling_enabled = enabled


func get_probe_cluster_debug_info(cache_key := "") -> Dictionary:
	var selected_key := cache_key
	if selected_key.is_empty():
		selected_key = str(_frame_snapshot.get("cache_key", ""))
	if not _bake_resources.has(selected_key):
		return {"cache_key": selected_key, "available": false,
			"culling_enabled": probe_cluster_culling_enabled}
	var cached: Dictionary = _bake_resources[selected_key]
	var cluster_rid: RID = cached.get("probe_clusters", RID())
	var table_valid := bool(cached.get("probe_cluster_enabled", false)) \
			and cluster_rid.is_valid()
	return {"cache_key": selected_key, "available": table_valid,
		"active": probe_cluster_culling_enabled and table_valid,
		"culling_enabled": probe_cluster_culling_enabled,
		"probe_cluster_bytes": int(cached.get("probe_cluster_bytes", 0)),
		"cluster_gpu_bytes": int(cached.get("probe_cluster_bytes", 0)),
		"cell_count": int(cached.get("probe_cluster_cell_count", 0)),
		"cluster_count": int(cached.get("probe_cluster_count", 0)),
		"probe_slots": int(cached.get("probe_cluster_probe_slots", 0)),
		"signature": str(cached.get("probe_cluster_signature", "")),
		"buffer_valid": cluster_rid.is_valid(),
		"streamed": bool(cached.get("stream_page", false)),
		"page_key": str(cached.get("page_key", "")),
		"active_for_last_draw": _probe_cluster_debug_bound_keys.has(selected_key),
		"gpu_bytes": int(cached.get("gpu_bytes", 0))}


func get_probe_cluster_debug_info_all() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for key_value in _bake_resources.keys():
		var info := get_probe_cluster_debug_info(str(key_value))
		if not info.is_empty():
			result.append(info)
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("cache_key", "")) < str(b.get("cache_key", "")))
	return result


func _record_probe_cluster_binding(cache_key: String) -> void:
	var frame := Engine.get_frames_drawn()
	if frame != _probe_cluster_debug_frame:
		_probe_cluster_debug_frame = frame
		_probe_cluster_debug_bound_keys.clear()
	_probe_cluster_debug_bound_keys[cache_key] = true

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
	if bool(_frame_snapshot.get("streamed", false)):
		_render_streamed(buffers, view, rd)
		return
	var output: RID = inputs[5].get_texture(buffers, view)
	if not output.is_valid():
		return
	if not _ensure_page_param_buffers(rd) \
			or not _write_page_params(rd, AABB(), Rect2i(Vector2i.ZERO, buffers.get_internal_size()),
				_frame_snapshot, false):
		rd.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)
		return
	var cache_key := str(_frame_snapshot.get("cache_key", ""))
	var data: Variant = _frame_snapshot.get("data")
	var version := int(_frame_snapshot.get("version", -1))
	if _frame_scene_data == null or cache_key.is_empty() or not is_instance_valid(data) \
			or not _ensure_bake_resources(cache_key, data, version, rd) \
			or not _update_emission_texture(cache_key, _frame_snapshot, data, rd):
		rd.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)
		return
	var cached: Dictionary = _bake_resources[cache_key]
	# Probe relighting consumes the frame lighting block. Create/update it for this
	# view before the first relight dispatch, including the initial frame.
	if not _update_frame_ubo(_frame_snapshot, _frame_scene_data, view, rd):
		rd.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)
		return
	if not _update_probe_lighting(cache_key, _frame_snapshot, rd):
		rd.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)
		return
	_frame_clipmap = null
	var directional: RefCounted = cached.get("directional")
	if directional != null and bool(_frame_snapshot.get("use_clv", true)):
		var clip_key := "%d:%d:%s" % [buffers.get_instance_id(), view, cache_key]
		if not _clipmaps.has(clip_key):
			var clipmap := ClipmapCache.new()
			if not clipmap.create(rd):
				_free_rids(rd, clipmap.owned_rids())
				rd.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)
				return
			_clipmaps[clip_key] = {"cache": clipmap, "owner": weakref(buffers), "last_used": _cache_clock, "bake": cache_key}
			_sync_owned_rid_snapshot()
		var entry: Dictionary = _clipmaps[clip_key]
		entry.last_used = _cache_clock
		var spacing := float(_frame_snapshot.get("clv_cell_size", 0.5))
		# Keep the trilinear-safe span over useful source geometry, centering bounds
		# that are smaller than the finest clipmap footprint.
		var source_bounds: AABB = cached.source_bounds
		var focus := ClipmapCache.focus_for_bounds(
				_frame_scene_data.get_cam_transform().origin, source_bounds, spacing)
		var clv_bake := cached
		var clv_cluster_buffer := _cluster_binding_for_cache(cached, rd)
		if not clv_cluster_buffer.is_valid():
			rd.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)
			return
		if clv_cluster_buffer != cached.get("probe_clusters", RID()):
			clv_bake = cached.duplicate(false)
			clv_bake["probe_clusters"] = clv_cluster_buffer
		if not entry.cache.update(rd, focus, spacing,
				directional.epoch, clv_bake, directional, _ubo, _sampler,
				int(_frame_snapshot.get("clv_cells_per_frame", 256))):
			rd.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)
			return
		_frame_clipmap = entry.cache
	_prune_clipmaps(rd)
	_cache_clock += 1
	cached["last_used"] = _cache_clock
	_bake_resources[cache_key] = cached
	var shader_before := _shader
	var compute_before := _compute_pipeline
	var sampler_before := _sampler
	var raster_count_before := _raster_pipelines.size()
	super._render(buffers, view, rd)
	_frame_clipmap = null
	if shader_before != _shader or compute_before != _compute_pipeline \
			or sampler_before != _sampler or raster_count_before != _raster_pipelines.size():
		_sync_owned_rid_snapshot()

func _ensure_page_param_buffers(rd: RenderingDevice) -> bool:
	if not _page_params_ubo.is_valid():
		var zero := PackedByteArray()
		zero.resize(PAGE_PARAMS_SIZE)
		_page_params_ubo = rd.uniform_buffer_create(PAGE_PARAMS_SIZE, zero)
	if not _pending_page_params_ubo.is_valid():
		var zero := PackedByteArray()
		zero.resize(PENDING_PARAMS_SIZE)
		_pending_page_params_ubo = rd.uniform_buffer_create(PENDING_PARAMS_SIZE, zero)
	return _page_params_ubo.is_valid() and _pending_page_params_ubo.is_valid()

func _append_matrix4(values: PackedFloat32Array, transform: Transform3D) -> void:
	for axis in [transform.basis.x, transform.basis.y, transform.basis.z, transform.origin]:
		values.append_array(PackedFloat32Array([axis.x, axis.y, axis.z, 0.0]))
	values[values.size() - 1] = 1.0

func _write_page_params(rd: RenderingDevice, core: AABB, rect: Rect2i,
		snapshot: Dictionary, enabled: bool) -> bool:
	var owner_transform: Variant = snapshot.get("owner_transform", Transform3D.IDENTITY)
	var owner_size: Variant = snapshot.get("owner_size", Vector3.ZERO)
	var has_owner: bool = owner_transform is Transform3D and owner_size is Vector3 \
			and owner_size.x > 0.0 and owner_size.y > 0.0 and owner_size.z > 0.0
	var bytes := PackedByteArray()
	bytes.append_array(PackedFloat32Array([core.position.x, core.position.y, core.position.z, 1.0 if enabled else 0.0]).to_byte_array())
	var core_max := core.position + core.size
	bytes.append_array(PackedFloat32Array([core_max.x, core_max.y, core_max.z, 0.0]).to_byte_array())
	bytes.append_array(PackedInt32Array([rect.position.x, rect.position.y, rect.size.x, rect.size.y]).to_byte_array())
	var inverse: Transform3D = owner_transform.affine_inverse() if has_owner else Transform3D.IDENTITY
	var matrix := PackedFloat32Array()
	_append_matrix4(matrix, inverse)
	bytes.append_array(matrix.to_byte_array())
	bytes.append_array(PackedFloat32Array([owner_size.x if has_owner else 0.0,
		owner_size.y if has_owner else 0.0, owner_size.z if has_owner else 0.0, 1.0 if has_owner else 0.0]).to_byte_array())
	return bytes.size() == PAGE_PARAMS_SIZE \
			and rd.buffer_update(_page_params_ubo, 0, PAGE_PARAMS_SIZE, bytes) == OK

func _write_pending_page_params(rd: RenderingDevice, core: AABB, rect: Rect2i,
		snapshot: Dictionary, enabled: bool, ownership: float) -> bool:
	var scene_data := _frame_scene_data
	if scene_data == null:
		return false
	var inverse_projection: Projection = scene_data.get_view_projection(_active_render_view).inverse()
	var camera: Transform3D = scene_data.get_cam_transform()
	var owner_transform: Variant = snapshot.get("owner_transform", Transform3D.IDENTITY)
	var owner_size: Variant = snapshot.get("owner_size", Vector3.ZERO)
	var has_owner: bool = owner_transform is Transform3D and owner_size is Vector3 \
			and owner_size.x > 0.0 and owner_size.y > 0.0 and owner_size.z > 0.0
	var bytes := PackedByteArray()
	var projection_values := PackedFloat32Array()
	_append_projection(projection_values, inverse_projection)
	bytes.append_array(projection_values.to_byte_array())
	var camera_values := PackedFloat32Array()
	_append_transform(camera_values, Transform3D(camera.basis.orthonormalized(), camera.origin))
	bytes.append_array(camera_values.to_byte_array())
	bytes.append_array(PackedFloat32Array([core.position.x, core.position.y, core.position.z, 1.0 if enabled else 0.0]).to_byte_array())
	var core_max := core.position + core.size
	bytes.append_array(PackedFloat32Array([core_max.x, core_max.y, core_max.z, ownership]).to_byte_array())
	bytes.append_array(PackedInt32Array([rect.position.x, rect.position.y, rect.size.x, rect.size.y]).to_byte_array())
	var inverse_owner: Transform3D = owner_transform.affine_inverse() if has_owner else Transform3D.IDENTITY
	var owner_values := PackedFloat32Array()
	_append_matrix4(owner_values, inverse_owner)
	bytes.append_array(owner_values.to_byte_array())
	bytes.append_array(PackedFloat32Array([owner_size.x if has_owner else 0.0,
		owner_size.y if has_owner else 0.0, owner_size.z if has_owner else 0.0, 1.0 if has_owner else 0.0]).to_byte_array())
	return bytes.size() == PENDING_PARAMS_SIZE \
			and rd.buffer_update(_pending_page_params_ubo, 0, PENDING_PARAMS_SIZE, bytes) == OK

var _active_render_view := 0

func _render_compute(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice) -> void:
	if not _stream_dispatch_active:
		return super._render_compute(buffers, view, rd)
	if workgroup_size.x <= 0 or workgroup_size.y <= 0 or _stream_dispatch_rect.size.x <= 0 \
			or _stream_dispatch_rect.size.y <= 0:
		return
	var binding_data := _collect_bindings(buffers, view, rd)
	if _binding_error:
		return
	var uniforms: Array[RDUniform] = binding_data["uniforms"]
	var uniform_set := _make_uniform_set(uniforms)
	if not uniforms.is_empty() and not uniform_set.is_valid():
		return
	var push := _parameter_bytes()
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, _compute_pipeline)
	if uniform_set.is_valid():
		rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	rd.compute_list_set_push_constant(list, push, push.size())
	rd.compute_list_dispatch(list, ceili(float(_stream_dispatch_rect.size.x) / workgroup_size.x),
		ceili(float(_stream_dispatch_rect.size.y) / workgroup_size.y), 1)
	rd.compute_list_end()

func _ensure_pending_page_pipeline(rd: RenderingDevice) -> bool:
	if _pending_page_shader.is_valid() and _pending_page_pipeline.is_valid():
		return true
	if _page_residency != null and _page_residency.allocation_budget_remaining() <= 0:
		return false
	var spirv := PENDING_PAGE_SHADER.get_spirv()
	if spirv == null or PENDING_PAGE_SHADER.base_error != "" \
			or spirv.bytecode_compute.is_empty() or spirv.compile_error_compute != "":
		_report("Magic GI pending-page shader failed to compile: " + PENDING_PAGE_SHADER.base_error)
		return false
	var allocated := 0
	if not _pending_page_shader.is_valid():
		_pending_page_shader = rd.shader_create_from_spirv(spirv, "Magic GI Pending Page Ownership")
		if not _pending_page_shader.is_valid():
			return false
		allocated += 1
	if not _pending_page_pipeline.is_valid():
		if _page_residency != null and _page_residency.allocation_budget_remaining() < 1:
			if allocated > 0:
				_page_residency.account_allocations(allocated)
			_sync_owned_rid_snapshot()
			return false
	if _pending_page_shader.is_valid():
		_pending_page_pipeline = rd.compute_pipeline_create(_pending_page_shader)
		if not _pending_page_pipeline.is_valid():
			if allocated > 0 and _page_residency != null:
				_page_residency.account_allocations(allocated)
			_sync_owned_rid_snapshot()
			return false
		allocated += 1
	if allocated > 0 and _page_residency != null \
			and not _page_residency.account_allocations(allocated):
		return false
	_sync_owned_rid_snapshot()
	return _pending_page_shader.is_valid() and _pending_page_pipeline.is_valid()

func _render_pending_page(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice,
		page: Dictionary, rect: Rect2i, snapshot: Dictionary) -> void:
	if not _frame_replacement_enabled or not _ensure_pending_page_pipeline(rd) \
			or not _ensure_sampler(rd):
		return
	var color: RID = inputs[0].get_texture(buffers, view)
	var depth: RID = inputs[1].get_texture(buffers, view)
	var orm: RID = inputs[4].get_texture(buffers, view)
	var output: RID = inputs[5].get_texture(buffers, view)
	var sky: RID = _sky_diffuse_input.get_texture(buffers, view)
	if not color.is_valid() or not depth.is_valid() or not orm.is_valid() \
			or not output.is_valid() or not sky.is_valid():
		return
	var resolved: Vector4 = _frame_parameters if _frame_parameters is Vector4 else parameters
	var ownership := clampf(float(snapshot.get("strength", 1.0)) * resolved.x, 0.0, 1.0)
	_active_render_view = view
	if not _write_pending_page_params(rd, page["core_bounds"], rect, snapshot, true, ownership):
		return
	var uniforms: Array[RDUniform] = [U.image(0, color), U.sampled(1, _sampler, depth),
		U.sampled(2, _sampler, orm), U.image(3, output), U.sampled(4, _sampler, sky),
		U.uniform_buffer(5, _pending_page_params_ubo)]
	var uniform_set := UniformSetCacheRD.get_cache(_pending_page_shader, 0, uniforms)
	if not uniform_set.is_valid():
		return
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, _pending_page_pipeline)
	rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	rd.compute_list_dispatch(list, ceili(float(rect.size.x) / 8.0), ceili(float(rect.size.y) / 8.0), 1)
	rd.compute_list_end()

func _render_streamed(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice) -> void:
	var output: RID = inputs[5].get_texture(buffers, view)
	if not output.is_valid() or _frame_scene_data == null \
			or view >= _frame_scene_data.get_view_count():
		return
	_active_render_view = view
	var extent: Vector2i = buffers.get_internal_size()
	if extent.x <= 0 or extent.y <= 0:
		return
	rd.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)
	if not _ensure_page_param_buffers(rd):
		return

	var root_snapshot := _frame_snapshot
	var root_replacement := _frame_replacement_enabled
	var previous_clipmap: RefCounted = _frame_clipmap
	var frame_token := Engine.get_frames_drawn()
	_stream_frame_token = frame_token
	var camera: Transform3D = _frame_scene_data.get_cam_transform()
	var all_ready_pages := PageStream.normalize_streamed_snapshot(root_snapshot)
	var pending_descriptors := _stream_pending_descriptors(root_snapshot)
	var cache_namespace := _stream_cache_namespace(root_snapshot)
	var demand_packet := _stream_gpu_demand_keys(root_snapshot,
		all_ready_pages, pending_descriptors, buffers, extent, frame_token)
	var desired_cache_keys: PackedStringArray = demand_packet.get("keys", PackedStringArray())
	var ready_projections: Array = demand_packet.get("ready_projections", [])
	var pending_projections: Array = demand_packet.get("pending_projections", [])
	var projected_by_key: Dictionary = ready_projections[view] \
			if view < ready_projections.size() and ready_projections[view] is Dictionary else {}
	var projected_pending_by_key: Dictionary = pending_projections[view] \
			if view < pending_projections.size() and pending_projections[view] is Dictionary else {}
	if bool(root_snapshot.get("use_clv", true)) and _stream_pages_have_directional(all_ready_pages):
		_ensure_streamed_clipmap_cache(buffers, view, rd, frame_token)
	var snapshot_budget_value: Variant = root_snapshot.get("streaming_budget", {})
	var stream_budget: Dictionary = snapshot_budget_value if snapshot_budget_value is Dictionary else {}
	var gpu_budget := int(stream_budget.get("gpu_bytes",
		stream_budget.get("gpu_resident_bytes", PageStream.GPU_RESIDENT_BUDGET_BYTES)))
	var upload_budget := int(stream_budget.get("upload_bytes_per_frame",
		PageStream.GPU_UPLOAD_BUDGET_BYTES_PER_FRAME))
	var allocation_budget := int(stream_budget.get("allocations_per_frame", 4))
	_prune_clipmaps(rd)
	var view_cache_reserve := _stream_clipmap_reserve_bytes()
	var global_reserve := maxi(PageStream.GPU_GLOBAL_RESERVE_BYTES,
		int(stream_budget.get("reserved_gpu_bytes", 0)))
	var frame_evictions := _begin_page_residency_frame(frame_token, gpu_budget,
		upload_budget, global_reserve + view_cache_reserve, allocation_budget,
		desired_cache_keys, rd)
	if not frame_evictions.is_empty():
		_sync_owned_rid_snapshot()

	var visible_pages: Array[Dictionary] = []
	var fallback_pages: Array[Dictionary] = []
	var pending_by_key: Dictionary = {}
	for pending_page in pending_descriptors:
		var pending_key := str(pending_page.get("page_key", ""))
		if not pending_key.is_empty():
			pending_by_key[pending_key] = pending_page

	# Each descriptor is immutable. The pass admits and incrementally uploads only
	# pages intersecting this view or the current clipmap prefetch window. This
	# keeps page uploads local while allowing the per-view CLV to warm before a
	# core reaches the screen.
	for page in all_ready_pages:
		var page_key := str(page.get("page_key", ""))
		var core_value: Variant = page.get("core_bounds", AABB())
		if page_key.is_empty() or not core_value is AABB:
			continue
		var core: AABB = core_value
		var selection: Dictionary = projected_by_key.get(page_key, {})
		var projected: Dictionary = selection.get("projection", {})
		var screen_visible := bool(projected.get("visible", false))
		var cache_near := bool(selection.get("cache_near", false))
		if not screen_visible and not cache_near:
			continue
		var cache_key := PageStream.stable_version_key(cache_namespace, page)
		var page_ready := _advance_stream_page(page, cache_key, rd)
		var render_page: Dictionary = page
		if not page_ready:
			# A current light-only revision can wait for its indivisible emission
			# atlas upload while the same immutable page continues using its prior,
			# internally-consistent lighting snapshot.
			var fallback := _stream_page_fallback(root_snapshot, page, cache_key)
			if fallback.is_empty():
				pending_by_key[page_key] = {"page_key": page_key, "core_bounds": core}
				continue
			render_page = fallback
			cache_key = str(render_page.get("_cache_key", cache_key))
		if root_replacement and not bool(render_page.get("replacement_enabled", false)):
			if screen_visible:
				pending_by_key[page_key] = {"page_key": page_key, "core_bounds": core}
			continue
		var rect: Rect2i = projected.get("rect", Rect2i())
		var ready_entry := _prepare_stream_page_for_view(root_snapshot, render_page,
				cache_key, view, rd)
		if bool(ready_entry.get("emission_pending", false)):
			var previous_page := _stream_page_fallback(root_snapshot, page, cache_key)
			if previous_page.is_empty():
				if screen_visible:
					pending_by_key[page_key] = {"page_key": page_key, "core_bounds": core}
				continue
			render_page = previous_page
			cache_key = str(render_page.get("_cache_key", cache_key))
			ready_entry = _prepare_stream_page_for_view(root_snapshot, render_page,
					cache_key, view, rd)
		if ready_entry.is_empty():
			if screen_visible:
				pending_by_key[page_key] = {"page_key": page_key, "core_bounds": core}
			continue
		if bool(ready_entry.get("emission_pending", false)):
			if screen_visible:
				pending_by_key[page_key] = {"page_key": page_key, "core_bounds": core}
			continue
		var selected_page: Dictionary = ready_entry.get("page", render_page)
		selected_page = selected_page.duplicate(false)
		selected_page["_cache_key"] = cache_key
		selected_page["_snapshot"] = ready_entry.get("snapshot", {})
		_page_ready_by_key[_stream_owner_page_key(root_snapshot, selected_page)] = cache_key
		fallback_pages.append(selected_page)
		if screen_visible:
			selected_page["_dispatch_rect"] = projected.get("rect", Rect2i())
			visible_pages.append(selected_page)
			pending_by_key.erase(page_key)

	var pending_to_draw: Array[Dictionary] = []
	var pending_keys: Array = pending_by_key.keys()
	pending_keys.sort()
	for key_value in pending_keys:
		var pending: Dictionary = pending_by_key[key_value]
		var core_value: Variant = pending.get("core_bounds", AABB())
		if not core_value is AABB:
			continue
		# During a same-core revision transition, keep the previous immutable page
		# visible until the replacement has completed upload and relighting.
		var previous_page := _stream_page_fallback(root_snapshot, pending, "")
		if not previous_page.is_empty():
			var previous_key := str(_page_ready_by_key.get(
				_stream_owner_page_key(root_snapshot, pending), ""))
			var previous_snapshot := PageStream.page_snapshot(root_snapshot,
				previous_page, previous_key)
			var previous_entry := _prepare_stream_page_for_view(root_snapshot,
				previous_page, previous_key, view, rd)
			if not previous_entry.is_empty() and not bool(previous_entry.get("emission_pending", false)):
				var previous_ready: Dictionary = previous_entry.get("page", previous_page).duplicate(false)
				previous_ready["_cache_key"] = previous_key
				previous_ready["_snapshot"] = previous_entry.get("snapshot", previous_snapshot)
				fallback_pages.append(previous_ready)
				var old_projection_entry: Dictionary = projected_pending_by_key.get(
					str(pending.get("page_key", "")), {})
				var old_projection: Dictionary = old_projection_entry.get("projection", {})
				if bool(old_projection.get("visible", false)):
					previous_ready["_dispatch_rect"] = old_projection.get("rect", Rect2i())
					visible_pages.append(previous_ready)
					continue
		var core: AABB = core_value
		var pending_projection: Dictionary = projected_pending_by_key.get(
			str(pending.get("page_key", "")), {}).get("projection", {})
		var projected := pending_projection
		if not bool(projected.get("visible", false)):
			continue
		pending["_dispatch_rect"] = projected.get("rect", Rect2i())
		pending_to_draw.append(pending)

	# CLV cache is unique per render target/view, never per page. Page revisions
	# enqueue only their owner cells; camera movement enqueues only entering slabs.
	_frame_clipmap = null
	if bool(root_snapshot.get("use_clv", true)):
		_frame_clipmap = _update_streamed_clipmap(buffers, view, rd, root_snapshot,
				fallback_pages, camera.origin, frame_token)

	for page in visible_pages:
		var page_snapshot: Dictionary = page.get("_snapshot", {})
		var page_cache_key := str(page.get("_cache_key", ""))
		var rect: Rect2i = page.get("_dispatch_rect", Rect2i())
		if page_snapshot.is_empty() or page_cache_key.is_empty() \
				or rect.size.x <= 0 or rect.size.y <= 0:
			continue
		_render_stream_page(buffers, view, rd, page, page_snapshot,
				page_cache_key, rect, root_snapshot)

	# Unknown manifest-covered cores keep SkyDiffuse ownership while their page is
	# loading, over budget, or failed. They are never treated as valid black pages.
	for page in pending_to_draw:
		_render_pending_page(buffers, view, rd, page,
				page.get("_dispatch_rect", Rect2i()), root_snapshot)

	_stream_dispatch_active = false
	_stream_dispatch_rect = Rect2i()
	_stream_dispatch_extent = Vector2i()
	_frame_snapshot = root_snapshot
	_frame_replacement_enabled = root_replacement
	_frame_clipmap = previous_clipmap
	_cache_clock += 1
	_prune_clipmaps(rd)
	_sync_owned_rid_snapshot()


func _stream_pending_descriptors(snapshot: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var seen: Dictionary = {}
	var explicit_pages: Variant = snapshot.get("pending_pages", [])
	if explicit_pages is Array:
		for value in explicit_pages:
			if value is Dictionary and value.get("core_bounds") is AABB:
				var page_key := str(value.get("page_key", ""))
				if not page_key.is_empty() and not seen.has(page_key):
					seen[page_key] = true
					result.append(value)
	var keys_value: Variant = snapshot.get("pending_page_keys", PackedStringArray())
	var manifest: Variant = snapshot.get("manifest")
	if keys_value is PackedStringArray and manifest is Object:
		for page_key in keys_value:
			if seen.has(page_key):
				continue
			var metadata := PageStream.descriptor_for_key(manifest, String(page_key))
			if not metadata.is_empty() and metadata.get("core_bounds") is AABB:
				seen[String(page_key)] = true
				result.append(metadata)
	return result


func _aabb_intersects(first: AABB, second: AABB) -> bool:
	var first_end := first.position + first.size
	var second_end := second.position + second.size
	return first.size.x > 0.0 and first.size.y > 0.0 and first.size.z > 0.0 \
			and second.size.x > 0.0 and second.size.y > 0.0 and second.size.z > 0.0 \
			and first.position.x < second_end.x and first_end.x > second.position.x \
			and first.position.y < second_end.y and first_end.y > second.position.y \
			and first.position.z < second_end.z and first_end.z > second.position.z


func _advance_stream_page(page: Dictionary, cache_key: String,
		rd: RenderingDevice) -> bool:
	var page_key := str(page.get("page_key", ""))
	var page_version := int(page.get("version", -1))
	if page_key.is_empty() or cache_key.is_empty() or page_version < 0:
		return false
	if _stream_page_failed_for_revision(cache_key, page_version):
		return false
	if _bake_resources.has(cache_key):
		var cached: Dictionary = _bake_resources[cache_key]
		var ledger_entry: Dictionary = _page_residency.entry(cache_key)
		if not ledger_entry.is_empty() and int(cached.get("gpu_bytes", -1)) \
				== int(ledger_entry.get("gpu_bytes", -2)) \
				and int(cached.get("source_gpu_bytes", -1)) == int(page.get("gpu_bytes", -2)) \
				and _stream_cached_page_valid(cached, page):
			_page_residency.touch(cache_key)
			return true
		_release_stream_page_resources(cache_key, rd, not ledger_entry.is_empty())

	var uploader: RefCounted = _page_uploads.get(cache_key)
	if uploader == null:
		var upload_page := _page_with_probe_clusters(page)
		var page_bytes := int(upload_page.get("gpu_bytes", 0))
		var admission := _admit_stream_page(cache_key, page_key, page_bytes, rd)
		if not bool(admission.get("admitted", false)):
			return false
		uploader = PageUpload.new()
		_page_uploads[cache_key] = uploader
		if not uploader.begin(rd, upload_page, cache_key):
			_report("Magic GI page %s could not begin upload: %s" % [page_key, uploader.error])
			_rollback_failed_stream_page(cache_key, page_version, rd)
			return false
		_sync_owned_rid_snapshot()
	if uploader.failed():
		_report("Magic GI page %s upload failed: %s" % [page_key, uploader.error])
		_rollback_failed_stream_page(cache_key, page_version, rd)
		return false

	var allocation_remaining: int = _page_residency.allocation_budget_remaining()
	if allocation_remaining > 0 and uploader.has_pending_allocations():
		var allocation_count: int = uploader.allocate_step(rd, mini(2, allocation_remaining))
		if allocation_count < 0 or not _page_residency.account_allocations(allocation_count):
			_report("Magic GI page %s allocation transaction failed." % page_key)
			_rollback_failed_stream_page(cache_key, page_version, rd)
			return false
		var actual_page_bytes := int(uploader.call("gpu_bytes"))
		var reservation: Dictionary = _page_residency.entry(cache_key)
		if not reservation.is_empty() and actual_page_bytes > 0 \
				and actual_page_bytes < int(reservation.get("gpu_bytes", 0)) \
				and not _page_residency.reduce_gpu_bytes(cache_key, actual_page_bytes):
			_report("Magic GI page %s could not reconcile optional cluster-buffer fallback bytes." % page_key)
			_rollback_failed_stream_page(cache_key, page_version, rd)
			return false
		if allocation_count > 0:
			# RIDs become owned as soon as they are allocated, even while the page is
			# still staged across frames. Keep teardown's ownership snapshot current.
			_sync_owned_rid_snapshot()
	if uploader.failed():
		_report("Magic GI page %s allocation failed: %s" % [page_key, uploader.error])
		_rollback_failed_stream_page(cache_key, page_version, rd)
		return false

	var remaining_upload: int = _page_residency.upload_budget_remaining()
	if remaining_upload > 0 and uploader.has_pending_uploads():
		var uploaded: int = uploader.upload_step(rd, remaining_upload)
		if uploaded < 0 or not _page_residency.account_upload(uploaded):
			_report("Magic GI page %s upload transaction failed." % page_key)
			_rollback_failed_stream_page(cache_key, page_version, rd)
			return false
	if uploader.failed():
		_report("Magic GI page %s upload failed: %s" % [page_key, uploader.error])
		_rollback_failed_stream_page(cache_key, page_version, rd)
		return false
	if not uploader.is_ready():
		return false

	var ready_cache: Dictionary = uploader.take_ready_cache()
	if ready_cache.is_empty():
		_report("Magic GI page %s completed without a transferable GPU cache." % page_key)
		_rollback_failed_stream_page(cache_key, page_version, rd)
		return false
	ready_cache["page_key"] = page_key
	ready_cache["identity"] = str(page.get("identity", ""))
	ready_cache["page_revision"] = page_version
	ready_cache["source_gpu_bytes"] = int(page.get("gpu_bytes", 0))
	ready_cache["gpu_bytes"] = int(ready_cache.get("gpu_bytes", page.get("gpu_bytes", 0)))
	ready_cache["published_page"] = page.duplicate(false)
	ready_cache["last_used"] = _cache_clock
	_bake_resources[cache_key] = ready_cache
	_page_residency.mark_ready(cache_key)
	_sync_owned_rid_snapshot()
	return true


func _stream_cached_page_valid(cached: Dictionary, page: Dictionary) -> bool:
	var data_value: Variant = page.get("data")
	if not data_value is Resource or int(cached.get("data_id", -1)) != data_value.get_instance_id() \
			or int(cached.get("version", -1)) != int(page.get("version", -2)):
		return false
	for name in ["transfer", "primary_sky", "geometry", "visibility_moments",
			"visibility_nodes", "visibility_triangles", "indices", "index_entries",
			"emission", "probe_lighting", "probe_clusters"]:
		var rid: RID = cached.get(name, RID())
		if not rid.is_valid():
			return false
	var directional: RefCounted = cached.get("directional")
	return directional == null or directional.is_ready()


func _page_with_probe_clusters(page: Dictionary) -> Dictionary:
	var result := page.duplicate(false)
	var data_value: Variant = page.get("data")
	var data: Resource = data_value if data_value is Resource else null
	var generation := int(page.get("version", data.get("bake_version") if data != null else -1))
	var geometry_revision := int(page.get("geometry_revision", generation))
	var signature := ProbeClusters.cache_key(data.get_instance_id() if data != null else -1,
		generation, geometry_revision)
	var payload: Dictionary = _probe_cluster_cached_payload(signature)
	if payload.is_empty():
		var dimensions: Vector3i = data.get("grid_dims") if data != null else Vector3i.ZERO
		var probe_count := int(data.call("probe_count")) \
				if data != null and data.has_method("probe_count") else 0
		var upload_value: Variant = page.get("render_upload", {})
		var upload: Dictionary = upload_value if upload_value is Dictionary else {}
		var current_geometry_format := data != null and int(data.get("format_version")) >= 6
		payload = ProbeClusters.build(upload, dimensions, probe_count, signature,
			current_geometry_format)
		_cache_probe_cluster_payload(signature, payload)
	var bytes_value: Variant = payload.get("bytes")
	var bytes: PackedByteArray = bytes_value if bytes_value is PackedByteArray else PackedByteArray()
	if bytes.size() < ProbeClusters.HEADER_BYTES:
		payload = ProbeClusters.disabled_payload(signature)
		bytes = payload["bytes"]
		_cache_probe_cluster_payload(signature, payload)
	result["probe_cluster_payload"] = payload
	result["probe_cluster_signature"] = signature
	result["source_gpu_bytes"] = int(page.get("gpu_bytes", 0))
	result["gpu_bytes"] = maxi(0, int(page.get("gpu_bytes", 0))) + bytes.size()
	return result


func _probe_cluster_cached_payload(signature: String) -> Dictionary:
	if not _probe_cluster_payload_cache.has(signature):
		return {}
	_probe_cluster_payload_cache_clock += 1
	var entry: Dictionary = _probe_cluster_payload_cache[signature]
	entry["last_used"] = _probe_cluster_payload_cache_clock
	_probe_cluster_payload_cache[signature] = entry
	var payload: Variant = entry.get("payload")
	return payload if payload is Dictionary else {}


func _cache_probe_cluster_payload(signature: String, payload: Dictionary) -> void:
	if signature.is_empty():
		return
	var existing: Dictionary = _probe_cluster_payload_cache.get(signature, {})
	_probe_cluster_payload_cache_bytes -= int(existing.get("byte_count", 0))
	_probe_cluster_payload_cache_clock += 1
	var bytes_value: Variant = payload.get("bytes")
	var byte_count: int = bytes_value.size() if bytes_value is PackedByteArray else 0
	_probe_cluster_payload_cache[signature] = {"payload": payload,
		"last_used": _probe_cluster_payload_cache_clock, "byte_count": byte_count}
	_probe_cluster_payload_cache_bytes += byte_count
	while _probe_cluster_payload_cache.size() > PROBE_CLUSTER_CPU_CACHE_LIMIT \
			or _probe_cluster_payload_cache_bytes > PROBE_CLUSTER_CPU_CACHE_BYTES:
		var oldest_signature := ""
		var oldest_clock := 0x7fffffff
		for candidate in _probe_cluster_payload_cache:
			if str(candidate) == signature:
				continue
			var candidate_clock := int(_probe_cluster_payload_cache[candidate].get("last_used", 0))
			if candidate_clock < oldest_clock:
				oldest_clock = candidate_clock
				oldest_signature = str(candidate)
		if oldest_signature.is_empty():
			break
		var removed: Dictionary = _probe_cluster_payload_cache[oldest_signature]
		_probe_cluster_payload_cache_bytes -= int(removed.get("byte_count", 0))
		_probe_cluster_payload_cache.erase(oldest_signature)


func _stream_cache_namespace(snapshot: Dictionary) -> String:
	return "%d:%d:%s" % [int(snapshot.get("world_id", -1)),
		int(snapshot.get("volume_id", -1)), str(snapshot.get("manifest_key", ""))]


func _stream_owner_page_key(snapshot: Dictionary, page: Dictionary) -> String:
	return "%d:%d:%s" % [int(snapshot.get("world_id", -1)),
		int(snapshot.get("volume_id", -1)), str(page.get("page_key", ""))]


func _stream_page_epoch(snapshot: Dictionary, page: Dictionary,
		directional_epoch: int) -> int:
	return int(hash([int(snapshot.get("world_id", -1)),
		int(snapshot.get("volume_id", -1)), str(snapshot.get("manifest_key", "")),
		str(snapshot.get("generation", "")),
		str(page.get("page_key", "")), str(page.get("identity", "")),
		int(page.get("version", -1)), int(page.get("emission_revision", 0)),
		directional_epoch]) & 0x7fffffff)


func _project_streamed_pages(pages: Array[Dictionary], projection: Projection,
		camera_position: Vector3, extent: Vector2i, world_to_view: Transform3D,
		cache_bounds: AABB) -> Dictionary:
	var result: Dictionary = {}
	for page in pages:
		var page_key := str(page.get("page_key", ""))
		var core_value: Variant = page.get("core_bounds", AABB())
		if page_key.is_empty() or not core_value is AABB:
			continue
		var core: AABB = core_value
		result[page_key] = {
			"projection": PageStream.project_core(core, projection,
				camera_position, extent, world_to_view),
			"cache_near": _aabb_intersects(core, cache_bounds),
		}
	return result


func _stream_gpu_demand_keys(root_snapshot: Dictionary, pages: Array[Dictionary],
		pending_pages: Array[Dictionary], buffers: RenderSceneBuffersRD,
		extent: Vector2i, frame_token: int) -> Dictionary:
	if _stream_demand_frame_token != frame_token:
		_stream_demand_frame_token = frame_token
		_stream_frame_demands.clear()
	if _frame_scene_data == null:
		return {}
	var target: RID = buffers.get_render_target()
	var target_id := target.get_id() if target.is_valid() else buffers.get_instance_id()
	var cache_namespace := _stream_cache_namespace(root_snapshot)
	var clv_spacing := maxf(float(root_snapshot.get("clv_cell_size", 0.5)), 0.1)
	var clv_radius := float(ClipmapCache.RESOLUTION) * clv_spacing
	var view_count := _frame_scene_data.get_view_count()
	var camera: Transform3D = _frame_scene_data.get_cam_transform()
	var world_to_view := Transform3D(camera.basis.orthonormalized(), camera.origin).affine_inverse()
	var cache_bounds := AABB(camera.origin - Vector3.ONE * clv_radius,
		Vector3.ONE * clv_radius * 2.0)
	var projections: Array[Projection] = []
	for candidate_view in range(view_count):
		projections.append(_frame_scene_data.get_view_projection(candidate_view))
	var input_signature := _stream_projection_input_signature(pages, pending_pages)
	var demand_key := var_to_str([target_id, frame_token, cache_namespace,
		str(root_snapshot.get("generation", "")), extent, view_count, input_signature])
	var scene_data_id := _frame_scene_data.get_instance_id()
	# The packet is shared by every view of this immutable frame snapshot. Exact
	# camera/projection checks also cover captures that reuse a target in one frame.
	if _stream_frame_demands.has(demand_key):
		var cached_packet: Dictionary = _stream_frame_demands[demand_key]
		if int(cached_packet.get("scene_data_id", -1)) == scene_data_id \
				and cached_packet.get("camera", Transform3D()) == camera \
				and cached_packet.get("projections", []) == projections \
				and float(cached_packet.get("clv_spacing", -1.0)) == clv_spacing:
			return cached_packet

	var ready_projections: Array[Dictionary] = []
	var pending_projections: Array[Dictionary] = []
	var requested: Dictionary = {}
	# Demand selection already needs the projection of every view. Keep those maps
	# for the later per-view draw instead of projecting the same page boxes again.
	for candidate_view in range(view_count):
		var projection: Projection = projections[candidate_view]
		var ready_projection := _project_streamed_pages(pages, projection,
			camera.origin, extent, world_to_view, cache_bounds)
		var pending_projection := _project_streamed_pages(pending_pages, projection,
			camera.origin, extent, world_to_view, cache_bounds)
		ready_projections.append(ready_projection)
		pending_projections.append(pending_projection)
		for page in pages:
			var core_value: Variant = page.get("core_bounds", AABB())
			if not core_value is AABB:
				continue
			var projected_entry: Dictionary = ready_projection.get(
				str(page.get("page_key", "")), {})
			var projected: Dictionary = projected_entry.get("projection", {})
			if not bool(projected.get("visible", false)) \
					and not bool(projected_entry.get("cache_near", false)):
				continue
			var cache_key := PageStream.stable_version_key(cache_namespace, page)
			if not cache_key.is_empty():
				requested[cache_key] = true
			var previous := _stream_page_fallback(root_snapshot, page, cache_key)
			if not previous.is_empty():
				var previous_key := str(_page_ready_by_key.get(
					_stream_owner_page_key(root_snapshot, page), ""))
				if not previous_key.is_empty():
					requested[previous_key] = true
		for pending_page in pending_pages:
			var core_value: Variant = pending_page.get("core_bounds", AABB())
			if not core_value is AABB:
				continue
			var projected_entry: Dictionary = pending_projection.get(
				str(pending_page.get("page_key", "")), {})
			var projected: Dictionary = projected_entry.get("projection", {})
			if not bool(projected.get("visible", false)) \
					and not bool(projected_entry.get("cache_near", false)):
				continue
			var previous := _stream_page_fallback(root_snapshot, pending_page, "")
			if previous.is_empty():
				continue
			var previous_key := str(_page_ready_by_key.get(
				_stream_owner_page_key(root_snapshot, pending_page), ""))
			if not previous_key.is_empty():
				requested[previous_key] = true
	var result := PackedStringArray()
	for key in requested:
		result.append(String(key))
	result.sort()
	var packet := {
		"keys": result,
		"ready_projections": ready_projections,
		"pending_projections": pending_projections,
		"scene_data_id": scene_data_id,
		"camera": camera,
		"projections": projections,
		"clv_spacing": clv_spacing,
	}
	_stream_frame_demands[demand_key] = packet
	return packet


func _stream_projection_input_signature(pages: Array[Dictionary],
		pending_pages: Array[Dictionary]) -> Array:
	var entries: Array = []
	for page in pages:
		var core_value: Variant = page.get("core_bounds", AABB())
		if not core_value is AABB:
			continue
		var data_value: Variant = page.get("data")
		var data_id: int = data_value.get_instance_id() if data_value is Resource else -1
		entries.append([0, str(page.get("page_key", "")),
			str(page.get("identity", "")), int(page.get("version", -1)),
			int(page.get("emission_revision", page.get("revision", 0))), data_id,
			core_value.position, core_value.size])
	for page in pending_pages:
		var core_value: Variant = page.get("core_bounds", AABB())
		if not core_value is AABB:
			continue
		entries.append([1, str(page.get("page_key", "")),
			core_value.position, core_value.size])
	entries.sort_custom(func(a: Array, b: Array) -> bool:
		return var_to_str(a) < var_to_str(b))
	return entries


func _stream_page_fallback(root_snapshot: Dictionary, page: Dictionary,
		cache_key: String) -> Dictionary:
	var old_key := str(_page_ready_by_key.get(_stream_owner_page_key(root_snapshot, page), ""))
	if old_key.is_empty() or not _bake_resources.has(old_key) \
			or _page_residency == null or not _page_residency.is_ready(old_key):
		return {}
	var cached: Dictionary = _bake_resources[old_key]
	var previous: Variant = cached.get("published_page", {})
	if not previous is Dictionary:
		return {}
	var old_core: Variant = previous.get("core_bounds")
	var new_core: Variant = page.get("core_bounds")
	if not old_core is AABB or not new_core is AABB or old_core != new_core:
		return {}
	if cache_key == old_key and (str(cached.get("identity", "")) != str(page.get("identity", "")) \
			or int(cached.get("page_revision", -1)) != int(page.get("version", -2))):
		return {}
	var result: Dictionary = previous.duplicate(false)
	result["_cache_key"] = old_key
	return result


func _prepare_stream_page_for_view(root_snapshot: Dictionary, page: Dictionary,
		cache_key: String, view: int, rd: RenderingDevice) -> Dictionary:
	if not _bake_resources.has(cache_key):
		return {}
	var cached: Dictionary = _bake_resources[cache_key]
	var page_snapshot := PageStream.page_snapshot(root_snapshot, page, cache_key)
	var previous_snapshot := _frame_snapshot
	var previous_replacement := _frame_replacement_enabled
	_frame_snapshot = page_snapshot
	_frame_replacement_enabled = previous_replacement \
			and bool(page_snapshot.get("replacement_enabled", true))
	if not _update_frame_ubo(page_snapshot, _frame_scene_data, view, rd):
		_frame_snapshot = previous_snapshot
		_frame_replacement_enabled = previous_replacement
		return {}
	if not _update_stream_emission_texture(cache_key, page_snapshot, rd):
		_frame_snapshot = previous_snapshot
		_frame_replacement_enabled = previous_replacement
		return {"page": page, "snapshot": page_snapshot, "emission_pending": true}
	if not _update_probe_lighting(cache_key, page_snapshot, rd):
		_frame_snapshot = previous_snapshot
		_frame_replacement_enabled = previous_replacement
		return {}
	cached = _bake_resources[cache_key]
	cached["published_page"] = page.duplicate(false)
	cached["last_used"] = _cache_clock
	_bake_resources[cache_key] = cached
	_frame_snapshot = previous_snapshot
	_frame_replacement_enabled = previous_replacement
	return {"page": page, "snapshot": page_snapshot}


func _update_stream_emission_texture(cache_key: String, page: Dictionary,
		rd: RenderingDevice) -> bool:
	if not _bake_resources.has(cache_key):
		return false
	var cached: Dictionary = _bake_resources[cache_key]
	var identity := str(page.get("identity", ""))
	var revision := int(page.get("emission_revision", page.get("revision", 0)))
	if str(cached.get("emission_identity", "")) == identity \
			and int(cached.get("emission_revision", -1)) == revision:
		return true
	var image_value: Variant = page.get("emission_image")
	if not image_value is Image or image_value.is_empty():
		return false
	var image: Image = image_value
	if image.get_size() != cached.get("emission_size", image.get_size()) \
			or image.get_format() != cached.get("emission_format", image.get_format()):
		return false # A size/format change requires a new immutable page identity.
	var byte_count := PageStream.image_byte_count(image)
	if byte_count <= 0 or byte_count > _page_residency.upload_budget_remaining():
		return false
	var bytes := image.get_data()
	if bytes.size() != byte_count:
		return false
	var emission_rid: RID = cached.get("emission", RID())
	if not emission_rid.is_valid() or rd.texture_update(emission_rid, 0, bytes) != OK:
		return false
	if not _page_residency.account_upload(bytes.size()):
		return false # The same render thread owns the ledger; this guards future callers.
	cached["emission_identity"] = identity
	cached["emission_revision"] = revision
	_bake_resources[cache_key] = cached
	return true


func _stream_clipmap_reserve_bytes() -> int:
	var result := 0
	for entry: Dictionary in _clipmaps.values():
		result += int(entry.get("gpu_bytes", ClipmapCache.estimate_gpu_bytes()))
	if _probe_cluster_fallback.is_valid():
		result += 16
	if not _clv_fallback.is_empty():
		result += 16 + 16 + 80 + 320
	return result


func _stream_pages_have_directional(pages: Array[Dictionary]) -> bool:
	for page in pages:
		var data: Variant = page.get("data")
		if data is Resource and data.get("directional") != null:
			return true
	return false


func _ensure_streamed_clipmap_cache(buffers: RenderSceneBuffersRD, view: int,
		rd: RenderingDevice, frame_token: int) -> RefCounted:
	var target: RID = buffers.get_render_target()
	var target_id := target.get_id() if target.is_valid() else buffers.get_instance_id()
	var clip_key := "stream:%d:%d" % [target_id, view]
	if _clipmaps.has(clip_key):
		var existing: Dictionary = _clipmaps[clip_key]
		var owner_ref: WeakRef = existing.get("owner")
		if owner_ref != null and owner_ref.get_ref() == buffers:
			existing["last_used"] = frame_token
			_clipmaps[clip_key] = existing
			return existing.cache
		_free_rids(rd, existing.cache.owned_rids())
		_clipmaps.erase(clip_key)
		_sync_owned_rid_snapshot()
	var clipmap := ClipmapCache.new()
	if not clipmap.create(rd):
		_free_rids(rd, clipmap.owned_rids())
		return null
	_clipmaps[clip_key] = {"cache": clipmap, "owner": weakref(buffers),
		"last_used": frame_token, "gpu_bytes": ClipmapCache.estimate_gpu_bytes(),
		"streamed": true, "bake": ""}
	_sync_owned_rid_snapshot()
	return clipmap


func _update_streamed_clipmap(buffers: RenderSceneBuffersRD, view: int,
		rd: RenderingDevice, root_snapshot: Dictionary,
		ready_pages: Array[Dictionary], camera: Vector3, frame_token: int) -> RefCounted:
	if ready_pages.is_empty():
		return null
	var pages_with_directional: Array[Dictionary] = []
	var pages_by_key: Dictionary = {}
	for page in ready_pages:
		var cache_key := str(page.get("_cache_key", ""))
		if cache_key.is_empty() or not _bake_resources.has(cache_key):
			continue
		var cached: Dictionary = _bake_resources[cache_key]
		if cached.get("directional") == null:
			continue
		var page_key := str(page.get("page_key", ""))
		if page_key.is_empty():
			continue
		pages_with_directional.append(page)
		pages_by_key[page_key] = page
	if pages_with_directional.is_empty():
		return null
	var target: RID = buffers.get_render_target()
	var target_id := target.get_id() if target.is_valid() else buffers.get_instance_id()
	var clip_key := "stream:%d:%d" % [target_id, view]
	var clipmap_value: RefCounted = _ensure_streamed_clipmap_cache(buffers,
		view, rd, frame_token)
	if clipmap_value == null:
		return null
	var entry: Dictionary = _clipmaps[clip_key]
	entry["last_used"] = frame_token
	_clipmaps[clip_key] = entry
	var clipmap: RefCounted = clipmap_value
	var spacing := float(root_snapshot.get("clv_cell_size", 0.5))
	var manifest_epoch := int(hash([int(root_snapshot.get("world_id", -1)),
		int(root_snapshot.get("volume_id", -1)), str(root_snapshot.get("manifest_key", "")),
		str(root_snapshot.get("generation", ""))]) & 0x7fffffff)
	clipmap.queue_updates(camera, spacing, manifest_epoch, true)
	if not clipmap.update_parameters(rd, spacing, manifest_epoch):
		return null
	var retained_keys := PackedStringArray()
	for page in pages_with_directional:
		var page_key := str(page.get("page_key", ""))
		var cache_key := str(page.get("_cache_key", ""))
		var cached: Dictionary = _bake_resources[cache_key]
		var directional: RefCounted = cached.get("directional")
		var token := _stream_page_epoch(root_snapshot, page, directional.epoch)
		retained_keys.append(page_key)
		clipmap.queue_page_revision(page_key, page.get("core_bounds", AABB()),
				spacing, token)
	clipmap.retain_page_epochs(retained_keys)
	var jobs: Array[Vector4i] = clipmap.take_jobs(clampi(
		int(root_snapshot.get("clv_cells_per_frame", 256)), 32, 512))
	var grouped: Dictionary = {}
	for cell in jobs:
		var owner_index := PageStream.owner_index(pages_with_directional,
				clipmap.world_position(cell, spacing))
		if owner_index < 0:
			continue
		var owner_page: Dictionary = pages_with_directional[owner_index]
		var owner_key := str(owner_page.get("page_key", ""))
		var cells: Array = grouped.get(owner_key, [])
		cells.append(cell)
		grouped[owner_key] = cells
	var owner_keys: Array = grouped.keys()
	owner_keys.sort()
	for page_key_value in owner_keys:
		var page_key := String(page_key_value)
		var owner_page: Dictionary = pages_by_key.get(page_key, {})
		if owner_page.is_empty():
			continue
		var page_cache_key := str(owner_page.get("_cache_key", ""))
		var page_snapshot: Dictionary = owner_page.get("_snapshot", {})
		if page_snapshot.is_empty() or not _bake_resources.has(page_cache_key):
			continue
		var previous_snapshot := _frame_snapshot
		var previous_replacement := _frame_replacement_enabled
		_frame_snapshot = page_snapshot
		_frame_replacement_enabled = previous_replacement \
				and bool(page_snapshot.get("replacement_enabled", true))
		if not _update_frame_ubo(page_snapshot, _frame_scene_data, view, rd):
			clipmap.requeue_jobs(grouped[page_key])
			_frame_snapshot = previous_snapshot
			_frame_replacement_enabled = previous_replacement
			continue
		var cached: Dictionary = _bake_resources[page_cache_key]
		var directional: RefCounted = cached.get("directional")
		var token := _stream_page_epoch(root_snapshot, owner_page, directional.epoch)
		var selected_cells: Array[Vector4i] = []
		for cell in grouped[page_key]:
			selected_cells.append(cell)
		if not clipmap.set_expected_page_epoch(rd, token) \
				or not clipmap.dispatch_page_jobs(rd, selected_cells, spacing, token,
					cached, directional, _ubo, _sampler):
			clipmap.requeue_jobs(selected_cells)
		_frame_snapshot = previous_snapshot
		_frame_replacement_enabled = previous_replacement
	return clipmap


func _render_stream_page(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice,
		page: Dictionary, snapshot: Dictionary, cache_key: String, rect: Rect2i,
		root_snapshot: Dictionary) -> void:
	var previous_snapshot := _frame_snapshot
	var previous_replacement := _frame_replacement_enabled
	var previous_clipmap: RefCounted = _frame_clipmap
	_frame_snapshot = snapshot
	_frame_replacement_enabled = previous_replacement \
			and bool(snapshot.get("replacement_enabled", true))
	if not _write_page_params(rd, page.get("core_bounds", AABB()), rect,
			root_snapshot, true) or not _update_frame_ubo(snapshot, _frame_scene_data, view, rd):
		_frame_snapshot = previous_snapshot
		_frame_replacement_enabled = previous_replacement
		_frame_clipmap = previous_clipmap
		return
	var cache_key_value := str(cache_key)
	var cached: Dictionary = _bake_resources.get(cache_key_value, {})
	if cached.is_empty():
		_frame_snapshot = previous_snapshot
		_frame_replacement_enabled = previous_replacement
		_frame_clipmap = previous_clipmap
		return
	var directional: RefCounted = cached.get("directional")
	if _frame_clipmap != null and directional != null \
			and bool(snapshot.get("use_clv", true)):
		var token := _stream_page_epoch(root_snapshot, page, directional.epoch)
		if not _frame_clipmap.set_expected_page_epoch(rd, token):
			_frame_clipmap = null
	else:
		_frame_clipmap = null
	if not shader_file is RDShaderFile or not _ensure_shader(rd):
		_frame_snapshot = previous_snapshot
		_frame_replacement_enabled = previous_replacement
		_frame_clipmap = previous_clipmap
		return
	var shader_before := _shader
	var compute_before := _compute_pipeline
	var sampler_before := _sampler
	var raster_count_before := _raster_pipelines.size()
	_stream_dispatch_rect = rect
	_stream_dispatch_extent = buffers.get_internal_size()
	_stream_dispatch_active = true
	super._render(buffers, view, rd)
	_stream_dispatch_active = false
	_stream_dispatch_rect = Rect2i()
	_stream_dispatch_extent = Vector2i()
	if shader_before != _shader or compute_before != _compute_pipeline \
			or sampler_before != _sampler or raster_count_before != _raster_pipelines.size():
		_sync_owned_rid_snapshot()
	_frame_snapshot = previous_snapshot
	_frame_replacement_enabled = previous_replacement
	_frame_clipmap = previous_clipmap

## Begin the shared per-frame page budget and release every LRU key the ledger
## retired. The ledger never owns RenderingDevice objects; this render-thread
## bridge keeps its byte accounting and physical residency in lockstep.
func _begin_page_residency_frame(frame_token: int, gpu_budget_bytes: int,
		upload_budget_bytes: int, reserved_bytes: int, allocation_budget: int,
		active_keys: PackedStringArray, rd: RenderingDevice) -> PackedStringArray:
	if _page_residency == null:
		_page_residency = PageResidency.new()
	var evicted: PackedStringArray = _page_residency.begin_frame(frame_token,
		gpu_budget_bytes, upload_budget_bytes, reserved_bytes, allocation_budget, active_keys)
	_release_page_residency_evictions(evicted, rd)
	return evicted

func _admit_stream_page(cache_key: String, page_key: String, gpu_bytes: int,
		rd: RenderingDevice) -> Dictionary:
	if _page_residency == null:
		_page_residency = PageResidency.new()
	var admission: Dictionary = _page_residency.admit(cache_key, page_key, gpu_bytes)
	_release_page_residency_evictions(admission.get("evicted", PackedStringArray()), rd)
	return admission

func _rollback_failed_stream_page(cache_key: String, page_version: int, rd: RenderingDevice) -> void:
	_release_stream_page_resources(cache_key, rd, true)
	# Do not retry a permanently-invalid/allocation-failing immutable revision every
	# frame. A new page version can clear this marker and start a fresh transaction.
	_remember_failed_stream_page_revision(cache_key, page_version)

func _remember_failed_stream_page_revision(cache_key: String, page_version: int) -> void:
	_page_failed_versions[cache_key] = page_version
	while _page_failed_versions.size() > MAX_FAILED_STREAM_PAGE_REVISIONS:
		var failed_keys: Array = _page_failed_versions.keys()
		if failed_keys.is_empty():
			break
		_page_failed_versions.erase(failed_keys[0])

func _stream_page_failed_for_revision(cache_key: String, page_version: int) -> bool:
	return int(_page_failed_versions.get(cache_key, -1)) == page_version

func _release_page_residency_evictions(evicted: PackedStringArray, rd: RenderingDevice) -> void:
	for cache_key in evicted:
		_release_stream_page_resources(str(cache_key), rd, false)

## Drop one staged or published streamed page. Call this for all upload/create
## failures so a failed page cannot retain either its reservation or partial RIDs.
func _release_stream_page_resources(cache_key: String, rd: RenderingDevice,
		rollback_ledger := true) -> void:
	var rids: Array[RID] = []
	if _page_uploads.has(cache_key):
		var uploader: RefCounted = _page_uploads[cache_key]
		if uploader != null and uploader.has_method("owned_rids"):
			rids.append_array(uploader.call("owned_rids"))
		_page_uploads.erase(cache_key)
	if _bake_resources.has(cache_key):
		var cached: Dictionary = _bake_resources[cache_key]
		_bake_resources.erase(cache_key)
		var directional: RefCounted = cached.get("directional")
		if directional != null:
			rids.append_array(directional.owned_rids())
		for name in ["transfer", "primary_sky", "geometry", "visibility_moments",
				"visibility_nodes", "visibility_triangles", "indices", "index_entries",
				"emission", "probe_lighting", "probe_clusters"]:
			var rid: RID = cached.get(name, RID())
			if rid.is_valid():
				rids.append(rid)
	for page_key in _page_ready_by_key.keys():
		if str(_page_ready_by_key[page_key]) == cache_key:
			_page_ready_by_key.erase(page_key)
	_page_failed_versions.erase(cache_key)
	if rollback_ledger and _page_residency != null:
		_page_residency.remove(cache_key)
	# Normally staging and published ownership are exclusive. Deduplicate defensively
	# so a failure during the publication handoff cannot issue free_rid twice.
	var unique_rids: Array[RID] = []
	var seen: Dictionary = {}
	for rid in rids:
		if rid.is_valid() and not seen.has(rid):
			seen[rid] = true
			unique_rids.append(rid)
	_free_rids(rd, unique_rids)
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
				and cached.get("index_entries", RID()).is_valid() \
				and cached.get("probe_clusters", RID()).is_valid() \
				and cached.get("probe_lighting", RID()).is_valid() \
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
	var index_rid := _create_index_texture(rd, dims, index_bytes, bool(upload.get("sparse_indices", false)))
	var index_entries: PackedByteArray = upload.get("index_entries", PackedInt32Array([0]).to_byte_array())
	var entries_rid := rd.storage_buffer_create(index_entries.size(), index_entries)
	var probe_count := int(data.call("probe_count"))
	var estimated_gpu_bytes := int(data.call("estimate_gpu_bytes")) \
			if data.has_method("estimate_gpu_bytes") else 0
	var geometry_revision := int(_frame_snapshot.get("geometry_revision", version))
	var cluster_signature := ProbeClusters.cache_key(data.get_instance_id(), version, geometry_revision)
	var cluster_payload := ProbeClusters.build(upload, dims, probe_count, cluster_signature,
		int(data.get("format_version")) >= 6)
	var cluster_bytes: PackedByteArray = cluster_payload["bytes"]
	var cluster_rid := rd.storage_buffer_create(cluster_bytes.size(), cluster_bytes)
	if not cluster_rid.is_valid() and bool(cluster_payload.get("enabled", false)):
		cluster_payload = ProbeClusters.disabled_payload(cluster_signature,
				dims.x * dims.y * dims.z)
		cluster_bytes = cluster_payload["bytes"]
		cluster_rid = rd.storage_buffer_create(cluster_bytes.size(), cluster_bytes)
	var emission_rid := _create_image_texture(rd, emission_image, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,
			RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT)
	var lighting_rid := rd.storage_buffer_create(probe_count * 32)
	var source_positions: PackedVector3Array = data.get("positions")
	var source_bounds := AABB(source_positions[0], Vector3.ZERO)
	for position in source_positions:
		source_bounds = source_bounds.expand(position)
	var directional: RefCounted
	if data.get("directional") != null:
		directional = DirectionalCache.new()
		if not directional.create(rd, data):
			_free_rids(rd, directional.owned_rids())
			_free_rids(rd, [transfer_rid, primary_sky_rid, geometry_rid, visibility_rid,
				node_rid, triangle_rid, index_rid, entries_rid, cluster_rid, emission_rid, lighting_rid])
			return false
	if not transfer_rid.is_valid() or not primary_sky_rid.is_valid() or not geometry_rid.is_valid() \
			or not visibility_rid.is_valid() \
			or not node_rid.is_valid() or not triangle_rid.is_valid() \
			or not index_rid.is_valid() or not entries_rid.is_valid() or not cluster_rid.is_valid() \
			or not emission_rid.is_valid() or not lighting_rid.is_valid():
		if directional != null:
			_free_rids(rd, directional.owned_rids())
		for rid in [transfer_rid, primary_sky_rid, geometry_rid, visibility_rid,
				node_rid, triangle_rid, index_rid, entries_rid, cluster_rid, emission_rid, lighting_rid]:
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
		"index_entries": entries_rid,
		"probe_clusters": cluster_rid,
		"probe_cluster_enabled": bool(cluster_payload.get("enabled", false)),
		"probe_cluster_bytes": cluster_bytes.size(),
		"probe_cluster_signature": cluster_signature,
		"probe_cluster_cell_count": int(cluster_payload.get("cell_count", 0)),
		"probe_cluster_count": int(cluster_payload.get("cluster_count", 0)),
		"probe_cluster_probe_slots": int(cluster_payload.get("probe_slots", 0)),
		"gpu_bytes": maxi(0, estimated_gpu_bytes) + cluster_bytes.size(),
		"emission": emission_rid,
		"probe_lighting": lighting_rid,
		"directional": directional,
		"source_bounds": source_bounds,
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

## Relight each probe only when its sources change. Geometry filtering remains in
## the surface gather; this cache is independent of camera, exposure and material.
func _update_probe_lighting(cache_key: String, snapshot: Dictionary, rd: RenderingDevice) -> bool:
	var cached: Dictionary = _bake_resources[cache_key]
	var sources := [snapshot.get("lighting", PackedFloat32Array()),
		snapshot.get("sky_lighting", PackedFloat32Array()),
		cached["emission_identity"], cached["emission_revision"]]
	if cached.get("lighting_sources", []) == sources:
		return true
	if not _ensure_sampler(rd):
		return false
	if not _relight_shader.is_valid():
		_relight_shader = rd.shader_create_from_spirv(RELIGHT_SHADER.get_spirv(), "Magic GI Relight")
		_sync_owned_rid_snapshot()
		if not _relight_shader.is_valid():
			return false
	if not _relight_pipeline.is_valid():
		_relight_pipeline = rd.compute_pipeline_create(_relight_shader)
		_sync_owned_rid_snapshot()
		if not _relight_pipeline.is_valid():
			return false
	var uniform_set := UniformSetCacheRD.get_cache(_relight_shader, 0, [
		U.sampled(0, _sampler, cached["transfer"]),
		U.sampled(1, _sampler, cached["primary_sky"]),
		U.sampled(2, _sampler, cached["emission"]),
		U.uniform_buffer(3, _ubo), U.storage_buffer(4, cached["probe_lighting"]),
	])
	if not uniform_set.is_valid():
		return false
	rd.draw_command_begin_label("Magic GI Relight", Color(0.4, 0.8, 0.3))
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, _relight_pipeline)
	rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	rd.compute_list_dispatch(list, (int(cached["probe_count"]) + 63) / 64, 1, 1)
	rd.compute_list_end()
	rd.draw_command_end_label()
	var directional: RefCounted = cached.get("directional")
	if directional != null and not directional.update(rd, _ubo, snapshot, cached["probe_lighting"]):
		return false
	cached["lighting_sources"] = sources.duplicate(true)
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

func _create_index_texture(rd: RenderingDevice, dims: Vector3i, bytes: PackedByteArray, sparse := false) -> RID:
	return _create_texture(rd, Vector2i(dims.x * (1 if sparse else 8), dims.y * dims.z),
		RenderingDevice.DATA_FORMAT_R32G32_SINT if sparse else RenderingDevice.DATA_FORMAT_R32_SINT, bytes)

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
	var legacy_count := 0
	for cached: Dictionary in _bake_resources.values():
		if not bool(cached.get("stream_page", false)):
			legacy_count += 1
	while legacy_count > MAX_CACHED_BAKES:
		var oldest_key: String = ""
		var oldest := 0x7fffffff
		for key in _bake_resources:
			if bool(_bake_resources[key].get("stream_page", false)):
				continue
			var last_used := int(_bake_resources[key].get("last_used", 0))
			if last_used < oldest:
				oldest = last_used
				oldest_key = str(key)
		if oldest_key == "":
			return
		_release_bake_resources(oldest_key, rd)
		legacy_count -= 1

func _release_bake_resources(cache_key: String, rd: RenderingDevice) -> void:
	_free_rids(rd, _take_bake_rids(cache_key))
	_sync_owned_rid_snapshot()

func _take_bake_rids(cache_key: String) -> Array[RID]:
	var rids: Array[RID] = []
	if not _bake_resources.has(cache_key):
		return rids
	var cached: Dictionary = _bake_resources[cache_key]
	_bake_resources.erase(cache_key)
	var directional: RefCounted = cached.get("directional")
	if directional != null:
		rids.append_array(directional.owned_rids())
	for key in _clipmaps.keys():
		if _clipmaps[key].bake == cache_key:
			rids.append_array(_clipmaps[key].cache.owned_rids())
			_clipmaps.erase(key)
	for name in ["transfer", "primary_sky", "geometry", "visibility_moments",
			"visibility_nodes", "visibility_triangles", "indices", "index_entries",
			"probe_clusters", "emission", "probe_lighting"]:
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
	var cluster_buffer := _cluster_binding_for_cache(cached, rd)
	if not cluster_buffer.is_valid():
		_binding_error = true
		return binding_data
	var uniforms: Array[RDUniform] = binding_data["uniforms"]
	var sky_diffuse: RID = _sky_diffuse_input.get_texture(buffers, view)
	if not sky_diffuse.is_valid():
		sky_diffuse = _ensure_zero_sky_diffuse(rd)
	if not sky_diffuse.is_valid():
		_binding_error = true
		_report("Cannot create the zero SkyLight diffuse fallback texture.")
		return binding_data
	for spec in [
		{"binding": 7, "texture": cached["geometry"]},
		{"binding": 8, "texture": cached["indices"]},
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
		{"binding": 17, "buffer": cached["probe_lighting"]},
		{"binding": 22, "buffer": cached["index_entries"]},
		{"binding": PROBE_CLUSTER_BINDING, "buffer": cluster_buffer},
	]:
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		uniform.binding = int(spec["binding"])
		uniform.add_id(spec["buffer"])
		uniforms.append(uniform)
	uniforms.append(_ubo_uniform(UBO_BINDING))
	if not _ensure_clv_fallback(rd):
		_binding_error = true
		return binding_data
	var directional: RefCounted = cached.get("directional")
	if _frame_clipmap == null:
		var mode := PackedInt32Array([1 if directional != null else 0]).to_byte_array()
		rd.buffer_update(_clv_fallback.parameters, 76, 4, mode)
	uniforms.append(U.storage_buffer(18, directional.lighting if directional != null else _clv_fallback.lighting))
	uniforms.append(U.sampled(19, _frame_clipmap.sampler if _frame_clipmap != null else _sampler,
		_frame_clipmap.texture if _frame_clipmap != null else _clv_fallback.texture))
	uniforms.append(U.sampled(20, _sampler, _frame_clipmap.tags if _frame_clipmap != null else _clv_fallback.tags))
	uniforms.append(U.uniform_buffer(21, _frame_clipmap.parameters if _frame_clipmap != null else _clv_fallback.parameters))
	if not _page_params_ubo.is_valid():
		_binding_error = true
		return binding_data
	uniforms.append(U.uniform_buffer(PAGE_PARAMS_BINDING, _page_params_ubo))
	binding_data["uniforms"] = uniforms
	_record_probe_cluster_binding(cache_key)
	return binding_data


func _cluster_binding_for_cache(cached: Dictionary, rd: RenderingDevice) -> RID:
	var cluster_rid: RID = cached.get("probe_clusters", RID())
	if probe_cluster_culling_enabled and bool(cached.get("probe_cluster_enabled", false)) \
			and cluster_rid.is_valid():
		return cluster_rid
	if not _probe_cluster_fallback.is_valid():
		var disabled := ProbeClusters.disabled_payload("diagnostic-fallback")
		var bytes: PackedByteArray = disabled["bytes"]
		_probe_cluster_fallback = rd.storage_buffer_create(bytes.size(), bytes)
		if _probe_cluster_fallback.is_valid():
			_sync_owned_rid_snapshot()
	return _probe_cluster_fallback

func _ensure_clv_fallback(rd: RenderingDevice) -> bool:
	if not _clv_fallback.is_empty():
		return true
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	format.width = 1
	format.height = 1
	format.depth = 1
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	var zero := PackedByteArray()
	zero.resize(16)
	var texture := rd.texture_create(format, RDTextureView.new(), [zero])
	format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SINT
	var tags := rd.texture_create(format, RDTextureView.new(), [zero])
	zero.resize(80)
	_clv_fallback = {"texture": texture, "tags": tags,
		"parameters": rd.uniform_buffer_create(80, zero), "lighting": rd.storage_buffer_create(320)}
	for rid: RID in _clv_fallback.values():
		if not rid.is_valid():
			for allocated: RID in _clv_fallback.values():
				if allocated.is_valid():
					rd.free_rid(allocated)
			_clv_fallback.clear()
			return false
	_sync_owned_rid_snapshot()
	return true

func _prune_clipmaps(rd: RenderingDevice) -> void:
	var removed := false
	for key in _clipmaps.keys():
		if _clipmaps[key].owner.get_ref() == null:
			_free_rids(rd, _clipmaps[key].cache.owned_rids())
			_clipmaps.erase(key)
			removed = true
	while _clipmaps.size() > 32:
		var oldest_key := ""
		var oldest := 0x7fffffff
		for key in _clipmaps:
			var entry: Dictionary = _clipmaps[key]
			if entry.cache == _frame_clipmap or (bool(entry.get("streamed", false)) \
					and int(entry.get("last_used", -1)) >= _stream_frame_token):
				continue
			if int(entry.last_used) < oldest:
				oldest = int(_clipmaps[key].last_used)
				oldest_key = key
		if oldest_key.is_empty():
			break
		_free_rids(rd, _clipmaps[oldest_key].cache.owned_rids())
		_clipmaps.erase(oldest_key)
		removed = true
	if removed:
		_sync_owned_rid_snapshot()

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
	rids.append_array([_relight_pipeline, _relight_shader])
	rids.append_array([_page_params_ubo, _probe_cluster_fallback, _pending_page_params_ubo,
		_pending_page_pipeline, _pending_page_shader])
	for uploader: RefCounted in _page_uploads.values():
		if uploader != null and uploader.has_method("owned_rids"):
			rids.append_array(uploader.call("owned_rids"))
	for rid: RID in _clv_fallback.values():
		rids.append(rid)
	for entry: Dictionary in _clipmaps.values():
		rids.append_array(entry.cache.owned_rids())
	for bake: Dictionary in _bake_resources.values():
		if bake.get("directional") != null:
			rids.append_array(bake.directional.owned_rids())
	rids.append_array([_zero_sky_diffuse, _diffuse_ao_white])
	for cached in _bake_resources.values():
		for name in ["transfer", "primary_sky", "geometry", "visibility_moments",
				"visibility_nodes", "visibility_triangles", "indices", "index_entries",
				"probe_clusters", "emission", "probe_lighting"]:
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
	_page_uploads.clear()
	_page_ready_by_key.clear()
	_page_failed_versions.clear()
	_stream_frame_demands.clear()
	_page_residency = null
	_clipmaps.clear()
	_clv_fallback.clear()
	_frame_clipmap = null
	_relight_shader = RID()
	_relight_pipeline = RID()
	_page_params_ubo = RID()
	_probe_cluster_fallback = RID()
	_pending_page_params_ubo = RID()
	_pending_page_shader = RID()
	_pending_page_pipeline = RID()
	_zero_sky_diffuse = RID()
	_diffuse_ao_white = RID()
	_frame_diffuse_ao_texture = RID()
	_diffuse_ao_view_cache.clear()
	_probe_cluster_payload_cache.clear()
	_probe_cluster_payload_cache_bytes = 0
	_probe_cluster_debug_bound_keys.clear()
	_probe_cluster_debug_frame = -1
	var rids := super._take_owned_rids()
	rids.append_array(owned_rids)
	return rids
