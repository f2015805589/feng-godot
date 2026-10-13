@tool
class_name FengReflectProbePass
extends "res://addons/feng-render-pipeline/passes/pass_base.gd"
## Runtime producer installed by FengRenderer when the addon is available.
## It consumes immutable probe snapshots and publishes one premultiplied candidate.

const NativeSpec = preload("res://addons/feng-render-pipeline/pipeline/native_spec.gd")
const U = preload("res://addons/feng-render-pipeline/rd/uniforms.gd")
const Runtime = preload("../rendering/feng_reflect_probe_runtime.gd")
const SHADER_PATH := "res://addons/feng-reflect-probe/shaders/probe_candidate.glslinc"
const PREFILTER_SHADER_PATH := "res://addons/feng-reflect-probe/shaders/probe_prefilter.glslinc"
const EXTERNAL_COPY_SHADER_PATH := "res://addons/feng-reflect-probe/shaders/probe_external_copy.glslinc"
const PIPELINE_SCOPE: StringName = NativeSpec.SCOPE_PIPELINE
const OUTPUT_NAME: StringName = &"feng_probe_reflection"
const WORKGROUP_SIZE := 8
const CUBE_SIZE := 128
const MIP_COUNT := 8
const EXTERNAL_SOURCE_MAX_SIZE := 256
const DEPTH_FORMATS := [RenderingDevice.DATA_FORMAT_D16_UNORM,
		RenderingDevice.DATA_FORMAT_X8_D24_UNORM_PACK32,
		RenderingDevice.DATA_FORMAT_D32_SFLOAT, RenderingDevice.DATA_FORMAT_S8_UINT,
		RenderingDevice.DATA_FORMAT_D16_UNORM_S8_UINT,
		RenderingDevice.DATA_FORMAT_D24_UNORM_S8_UINT,
		RenderingDevice.DATA_FORMAT_D32_SFLOAT_S8_UINT]
## A 128px RGBA16F cubemap with 8 mips costs about 1 MiB. The shared atlas
## therefore stays below about 32 MiB per viewport at this explicit cap.
const MAX_PROBES := 32

var _candidate_shader := RID()
var _candidate_pipeline := RID()
var _prefilter_shader := RID()
var _prefilter_pipeline := RID()
var _external_copy_shader := RID()
var _external_copy_pipeline := RID()
var _sampler := RID()
var _atlas := RID()
var _atlas_signature: Array = []
var _probe_buffer := RID()
var _probe_buffer_capacity := 0
var _candidate_ubo := RID()
var _prefilter_ubos: Array[RID] = []
var _external_states: Dictionary = {} # owner id -> addon-owned raw/filtered cube state
var _frame_context: FRPPassContext
var _frame_target := RID()
var _frame_probes: Array[Dictionary] = []
var _warnings: Dictionary = {}

func _init() -> void:
	resource_name = "Feng Reflect Probe"
	stage = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	inputs = _make_inputs()
	outputs = _make_outputs()
	access_resolved_color = false
	access_resolved_depth = false

func get_reflection_source_kind() -> StringName:
	return &"feng_probe"

func get_required_before_native_ids() -> PackedInt32Array:
	return PackedInt32Array([NativeSpec.PASS_SKY, NativeSpec.PASS_TRANSPARENT,
			NativeSpec.PASS_TEMPORAL_AA, NativeSpec.PASS_POST_PROCESS])

func _make_inputs() -> Array[TextureInput]:
	var result: Array[TextureInput] = []
	for source in [TextureInput.Source.DEPTH, TextureInput.Source.NORMAL_ROUGHNESS,
			TextureInput.Source.ALBEDO, TextureInput.Source.ORM, TextureInput.Source.EMISSION]:
		var input := TextureInput.new()
		input.binding = result.size()
		input.source = source
		result.append(input)
	return result

func _make_outputs() -> Array[OutputDeclaration]:
	var output := OutputDeclaration.new()
	output.name = OUTPUT_NAME
	output.data_format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	output.usage = OutputDeclaration.Usage.SAMPLED | OutputDeclaration.Usage.STORAGE \
			| OutputDeclaration.Usage.COPY_TO
	output.scale = Vector2.ONE
	var result: Array[OutputDeclaration] = [output]
	return result

func ensure_frp_contract() -> bool:
	var expected_inputs := _make_inputs()
	var expected_outputs := _make_outputs()
	if _same_inputs(inputs, expected_inputs) and _same_outputs(outputs, expected_outputs):
		return false
	inputs = expected_inputs
	outputs = expected_outputs
	return true

func _same_inputs(actual: Array[TextureInput], expected: Array[TextureInput]) -> bool:
	if actual.size() != expected.size():
		return false
	for index in expected.size():
		if actual[index] == null or actual[index].binding != expected[index].binding \
				or actual[index].source != expected[index].source:
			return false
	return true

func _same_outputs(actual: Array[OutputDeclaration], expected: Array[OutputDeclaration]) -> bool:
	if actual.size() != expected.size():
		return false
	for index in expected.size():
		if actual[index] == null or actual[index].name != expected[index].name \
				or actual[index].data_format != expected[index].data_format \
				or actual[index].usage != expected[index].usage \
				or actual[index].scale != expected[index].scale:
			return false
	return true

func _frp_prepare(ctx: FRPPassContext) -> void:
	_frame_context = ctx
	_frame_target = RID()
	_frame_probes.clear()
	if ctx == null:
		return
	var buffers := ctx.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers == null:
		return
	_frame_target = buffers.get_render_target()
	_frame_probes = Runtime.snapshots_for_target(_frame_target)
	for snapshot in _frame_probes:
		var radiance: Variant = snapshot.get("radiance_rid", RID())
		if (String(snapshot.get("source_mode", "")) == "external_cubemap" \
				and int(snapshot.get("source_size", 0)) > 0) \
				or bool(snapshot.get("has_saved_seed", false)) \
				or (radiance is RID and radiance.is_valid()):
			ctx.request_reflection_components()
			break

func _frp_execute(ctx: FRPPassContext) -> void:
	if ctx == null:
		_frame_context = null
		return
	_frame_context = ctx
	if _frame_probes.is_empty() and _external_states.is_empty() and not _atlas.is_valid():
		_frame_context = null
		return
	var data := ctx.get_render_data()
	if data != null:
		_render_callback(effect_callback_type, data)
	_frame_context = null

func _setup(rd: RenderingDevice) -> void:
	_candidate_shader = _compile_shader(rd, SHADER_PATH, "Feng Reflect Probe Candidate")
	if _candidate_shader.is_valid():
		_candidate_pipeline = rd.compute_pipeline_create(_candidate_shader)
	_prefilter_shader = _compile_shader(rd, PREFILTER_SHADER_PATH, "Feng Reflect Probe Prefilter")
	if _prefilter_shader.is_valid():
		_prefilter_pipeline = rd.compute_pipeline_create(_prefilter_shader)
	_external_copy_shader = _compile_shader(rd, EXTERNAL_COPY_SHADER_PATH,
			"Feng Reflect Probe External Cubemap Copy")
	if _external_copy_shader.is_valid():
		_external_copy_pipeline = rd.compute_pipeline_create(_external_copy_shader)
	var sampler_state := RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = rd.sampler_create(sampler_state)
	_candidate_ubo = rd.uniform_buffer_create(160)
	_prefilter_ubos.clear()
	for mip in MIP_COUNT:
		var prefilter_ubo := rd.uniform_buffer_create(32)
		if prefilter_ubo.is_valid():
			var mip_size := maxi(1, CUBE_SIZE >> mip)
			var bytes := PackedInt32Array([mip_size, mip_size, 0, mip]).to_byte_array()
			bytes.append_array(PackedFloat32Array([float(MIP_COUNT - 1), 128.0, 0.0, 0.0]).to_byte_array())
			if rd.buffer_update(prefilter_ubo, 0, bytes.size(), bytes) != OK:
				rd.free_rid(prefilter_ubo)
				prefilter_ubo = RID()
		_prefilter_ubos.append(prefilter_ubo)
	_sync_owned_rids()
	if not _candidate_shader.is_valid() or not _candidate_pipeline.is_valid() \
			or not _prefilter_shader.is_valid() or not _prefilter_pipeline.is_valid() \
			or not _external_copy_shader.is_valid() or not _external_copy_pipeline.is_valid() \
			or not _sampler.is_valid() or not _candidate_ubo.is_valid() \
			or _prefilter_ubos.size() != MIP_COUNT:
		_warn_once("Probe shaders or shared GPU resources could not be created.")
		return
	for prefilter_ubo in _prefilter_ubos:
		if not prefilter_ubo.is_valid():
			_warn_once("A per-mip GGX parameter buffer could not be created.")
			return

func _compile_shader(rd: RenderingDevice, path: String, label: String) -> RID:
	if not FileAccess.file_exists(path):
		_warn_once("Missing shader: " + path)
		return RID()
	var source := RDShaderSource.new()
	source.source_compute = FileAccess.get_file_as_string(path)
	var spirv := rd.shader_compile_spirv_from_source(source)
	if not spirv.compile_error_compute.is_empty():
		_warn_once(label + " compilation failed: " + spirv.compile_error_compute)
		return RID()
	return rd.shader_create_from_spirv(spirv, label)

func _render(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice) -> void:
	var output := buffers.get_texture_slice(PIPELINE_SCOPE, OUTPUT_NAME, view, 0, 1, 1)
	_clear_output(rd, output)
	if not output.is_valid():
		return
	if _frame_context == null:
		return
	var current_probes: Array[Dictionary] = []
	for probe in _frame_probes:
		if Runtime.has_probe_owner(_frame_target, int(probe.get("owner_id", 0))):
			current_probes.append(probe)
	_sweep_external_states(rd, current_probes)
	if current_probes.is_empty():
		_release_atlas(rd)
		return
	if not _candidate_pipeline.is_valid() or not _prefilter_pipeline.is_valid() \
			or not _sampler.is_valid() or not _candidate_ubo.is_valid() \
			or _prefilter_ubos.size() != MIP_COUNT:
		return
	var size := buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0:
		return
	var textures: Array[RID] = []
	for declaration in inputs:
		textures.append(declaration.get_texture(buffers, view))
	for texture in textures:
		if not texture.is_valid():
			return
	var frame := _frame_context.get_volume_frame_inputs(view)
	var projection: Projection = frame.get("projection", Projection.IDENTITY)
	var inverse_projection: Projection = frame.get("inverse_projection", projection.inverse())
	var camera_transform: Transform3D = frame.get("camera_transform", Transform3D.IDENTITY)
	var dfg_value: Variant = frame.get("dfg_texture", RID())
	if not dfg_value is RID or not dfg_value.is_valid():
		_warn_once("The native DFG LUT is unavailable; FengReflectProbe publishes no candidate.")
		return
	var ready := _ready_probes(rd, current_probes)
	if ready.is_empty():
		_release_atlas(rd)
		return
	if not _prepare_atlas(rd, ready):
		return
	if not _update_probe_buffer(rd, ready):
		return
	if not buffers.get_color_layer(view).is_valid():
		return
	var inverse_view := camera_transform
	var inverse_projection_bytes := _projection_bytes(inverse_projection)
	var view_to_world_bytes := _transform_bytes(inverse_view)
	var exposure := _frame_context.get_pre_exposure(view) * _frame_context.get_scene_exposure_normalization()
	if not is_finite(exposure) or exposure <= 1e-8:
		return
	var parameter_bytes := PackedByteArray()
	parameter_bytes.append_array(inverse_projection_bytes)
	parameter_bytes.append_array(view_to_world_bytes)
	parameter_bytes.append_array(PackedInt32Array([size.x, size.y, ready.size(), MIP_COUNT]).to_byte_array())
	parameter_bytes.append_array(PackedFloat32Array([exposure, 0.0, 0.0, 0.0]).to_byte_array())
	if parameter_bytes.size() != 160 or rd.buffer_update(_candidate_ubo, 0, parameter_bytes.size(), parameter_bytes) != OK:
		_warn_once("Candidate frame parameters could not be uploaded.")
		return
	var uniforms: Array[RDUniform] = [
		U.sampled(0, _sampler, textures[0]), U.sampled(1, _sampler, textures[1]),
		U.sampled(2, _sampler, textures[2]), U.sampled(3, _sampler, textures[3]),
		U.sampled(4, _sampler, textures[4]), U.sampled(5, _sampler, dfg_value),
		U.sampled(6, _sampler, _atlas), U.storage_buffer(7, _probe_buffer),
		U.image(8, output), U.uniform_buffer(9, _candidate_ubo)]
	var uniform_set := UniformSetCacheRD.get_cache(_candidate_shader, 0, uniforms)
	if not uniform_set.is_valid():
		_warn_once("Candidate shader bindings do not match the reflected textures.")
		return
	var list := rd.compute_list_begin()
	if list < 0:
		return
	rd.compute_list_bind_compute_pipeline(list, _candidate_pipeline)
	rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	rd.compute_list_dispatch(list, ceili(float(size.x) / WORKGROUP_SIZE), ceili(float(size.y) / WORKGROUP_SIZE), 1)
	rd.compute_list_end()
	if not _frame_context.publish_reflection_candidate(&"feng_probe", output, view):
		_clear_output(rd, output)
		_warn_once("The current-frame FengReflectProbe candidate could not be published.")
	else:
		_clear_report()

func _ready_probes(rd: RenderingDevice, snapshots: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for snapshot in snapshots:
		if result.size() >= MAX_PROBES:
			break
		var texture: RID = RID()
		var ready_snapshot := snapshot.duplicate(true)
		var owner_id := int(snapshot.get("owner_id", 0))
		var source_mode := String(snapshot.get("source_mode", ""))
		if source_mode == "external_cubemap":
			var state := _ensure_external_probe(rd, snapshot, "external_cubemap")
			if not state.is_empty() and bool(state.get("ready", false)):
				texture = state.get("filtered", RID())
				ready_snapshot["source_revision"] = int(state.get("revision", -1))
				ready_snapshot["source_size"] = int(state.get("source_size", 0))
				ready_snapshot["capture_position"] = state.get("capture_position", Vector3.ZERO)
				ready_snapshot["source_basis"] = state.get("source_basis", Basis.IDENTITY)
		elif source_mode == "scene_capture":
			var completed := Runtime.completed_scene_capture_for_owner(owner_id)
			if not completed.is_empty():
				var texture_value: Variant = completed.get("radiance_rid", RID())
				if texture_value is RID and rd.texture_is_valid(texture_value):
					texture = texture_value
				ready_snapshot.merge(completed, true)
			if not texture.is_valid() and bool(snapshot.get("has_saved_seed", false)):
				var state := _ensure_external_probe(rd, snapshot, "saved_scene_seed")
				if not state.is_empty() and bool(state.get("ready", false)):
					texture = state.get("filtered", RID())
					ready_snapshot["source_revision"] = int(state.get("revision", -1))
					ready_snapshot["capture_position"] = state.get("capture_position", Vector3.ZERO)
					ready_snapshot["source_basis"] = state.get("source_basis", Basis.IDENTITY)
		if not texture.is_valid() or not rd.texture_is_valid(texture):
			continue
		var format := rd.texture_get_format(texture)
		if format.texture_type != RenderingDevice.TEXTURE_TYPE_CUBE \
				or format.format != RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT \
				or format.width != CUBE_SIZE or format.height != CUBE_SIZE \
				or format.mipmaps < MIP_COUNT:
			continue
		ready_snapshot["radiance_rid"] = texture
		result.append(ready_snapshot)
	return result

func _sweep_external_states(rd: RenderingDevice, live_probes: Array[Dictionary]) -> void:
	var active_external := {}
	for snapshot in live_probes:
		var owner_id := int(snapshot.get("owner_id", 0))
		var source_mode := String(snapshot.get("source_mode", ""))
		if source_mode == "external_cubemap" and int(snapshot.get("source_size", 0)) > 0:
			active_external[owner_id] = true
		elif source_mode == "scene_capture" and bool(snapshot.get("has_saved_seed", false)):
			var completed := Runtime.completed_scene_capture_for_owner(owner_id)
			var completed_rid: Variant = completed.get("radiance_rid", RID())
			if completed_rid is not RID or not rd.texture_is_valid(completed_rid):
				active_external[owner_id] = true
	var changed := false
	for owner_id in _external_states.keys():
		if active_external.has(int(owner_id)):
			continue
		var state: Variant = _external_states[owner_id]
		if state is Dictionary:
			for key in ["active", "pending"]:
				var substate: Variant = state.get(key, {})
				if substate is Dictionary:
					_free_external_state(rd, substate)
		_external_states.erase(owner_id)
		changed = true
	if changed:
		_sync_owned_rids()

func _release_atlas(rd: RenderingDevice) -> void:
	var changed := not _atlas_signature.is_empty()
	if _atlas.is_valid():
		rd.free_rid(_atlas)
		_atlas = RID()
		changed = true
	_atlas_signature.clear()
	if changed:
		_sync_owned_rids()

func _ensure_external_probe(rd: RenderingDevice, snapshot: Dictionary,
		expected_source_kind: String) -> Dictionary:
	var owner_id := int(snapshot.get("owner_id", 0))
	if owner_id <= 0:
		return {}
	var state: Dictionary = _external_states.get(owner_id, {})
	if state.is_empty():
		state = {"owner_id": owner_id, "active": {}, "pending": {},
				"rejected_revision": -1, "rejected_kind": "", "last_advance_frame": -1}
	var active: Dictionary = state.get("active", {})
	var pending: Dictionary = state.get("pending", {})
	if not pending.is_empty():
		_advance_external_pending_for_frame(rd, state, pending)
		if bool(pending.get("ready", false)):
			active = _promote_external_pending(rd, active, pending)
			pending = {}
			state["active"] = active
			state["pending"] = pending
	var latest := Runtime.external_source_for_owner(owner_id)
	var latest_revision := int(latest.get("revision", -1))
	var latest_kind := String(latest.get("source_kind", "external_cubemap"))
	var active_kind := String(active.get("source_kind", ""))
	if pending.is_empty() and not latest.is_empty() \
			and latest_kind == expected_source_kind \
			and (int(active.get("revision", -1)) != latest_revision or active_kind != latest_kind) \
			and (int(state.get("rejected_revision", -1)) != latest_revision \
				or String(state.get("rejected_kind", "")) != latest_kind) \
			and int(state.get("last_advance_frame", -1)) != Engine.get_process_frames():
		pending = _begin_external_pending(rd, owner_id, latest,
				int(snapshot.get("prefilter_mips_per_frame", 1)))
		if pending.is_empty():
			state["rejected_revision"] = latest_revision
			state["rejected_kind"] = latest_kind
		else:
			state["pending"] = pending
			_advance_external_pending_for_frame(rd, state, pending)
			if bool(pending.get("ready", false)):
				active = _promote_external_pending(rd, active, pending)
				pending = {}
				state["active"] = active
				state["pending"] = pending
	state["owner_id"] = owner_id
	state["active"] = active
	state["pending"] = pending
	_external_states[owner_id] = state
	_sync_owned_rids()
	return active if String(active.get("source_kind", "")) == expected_source_kind else {}

func _advance_external_pending_for_frame(rd: RenderingDevice, owner_state: Dictionary,
			pending: Dictionary) -> void:
	var frame := Engine.get_process_frames()
	if int(owner_state.get("last_advance_frame", -1)) == frame:
		return
	owner_state["last_advance_frame"] = frame
	var budget := clampi(int(pending.get("prefilter_mips_per_frame", 1)), 1, MIP_COUNT)
	_advance_external_prefilter(rd, pending, budget)

func _begin_external_pending(rd: RenderingDevice, owner_id: int, packet: Dictionary,
			mips_per_frame: int) -> Dictionary:
	var revision := int(packet.get("revision", -1))
	var source_size := int(packet.get("size", 0))
	var source_width := int(packet.get("source_width", 0))
	var source_height := int(packet.get("source_height", 0))
	var source_rid: Variant = packet.get("source_rid", RID())
	var source_lease: Variant = packet.get("source_lease", null)
	var capture_position: Variant = packet.get("capture_position", Vector3.ZERO)
	var source_basis: Variant = packet.get("source_basis", Basis.IDENTITY)
	if revision < 0 or source_size <= 0 or source_size > EXTERNAL_SOURCE_MAX_SIZE \
			or source_width <= 0 or source_width != source_height \
			or source_size != clampi(source_width, 16, EXTERNAL_SOURCE_MAX_SIZE) \
			or not source_rid is RID or not source_rid.is_valid() \
			or not capture_position is Vector3 \
			or not source_basis is Basis:
		_warn_once("An external Cubemap packet failed its immutable value checks.")
		return {}
	var borrowed := RenderingServer.texture_get_rd_texture(source_rid, false)
	if not borrowed.is_valid() or not rd.texture_is_valid(borrowed):
		_warn_once("An external Cubemap has no valid RenderingDevice texture.")
		return {}
	var source_format := rd.texture_get_format(borrowed)
	var sampling_usage := RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	if source_format.texture_type != RenderingDevice.TEXTURE_TYPE_CUBE \
			or source_format.array_layers != 6 or source_format.depth != 1 \
			or source_format.width != source_width or source_format.height != source_height \
			or source_format.samples != RenderingDevice.TEXTURE_SAMPLES_1 \
			or (source_format.usage_bits & sampling_usage) == 0 \
			or source_format.format in DEPTH_FORMATS \
			or not rd.texture_is_format_supported_for_usage(source_format.format, sampling_usage):
		_warn_once("An external Cubemap must be a square, six-layer, sampleable color texture.")
		return {}
	if not _external_copy_pipeline.is_valid() or not _prefilter_pipeline.is_valid() \
			or _prefilter_ubos.size() != MIP_COUNT:
		return {}
	var raw_usage := RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
			| RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	var raw := _create_cube(rd, source_size, 1, raw_usage)
	var filtered_usage := RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
			| RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	var filtered := _create_cube(rd, CUBE_SIZE, MIP_COUNT, filtered_usage)
	var mip_views := _create_cube_mip_views(rd, filtered)
	if not raw.is_valid() or not filtered.is_valid() or mip_views.size() != MIP_COUNT:
		_free_external_state(rd, {"raw": raw, "filtered": filtered, "mip_views": mip_views})
		_warn_once("An owned HDR snapshot or its GGX mip views could not be created.")
		return {}
	var copy_uniforms: Array[RDUniform] = [
		U.sampled(0, _sampler, borrowed), U.image(1, raw)]
	var copy_set := UniformSetCacheRD.get_cache(_external_copy_shader, 0, copy_uniforms)
	if not copy_set.is_valid():
		_free_external_state(rd, {"raw": raw, "filtered": filtered, "mip_views": mip_views})
		_warn_once("External Cubemap copy bindings do not match the copy shader.")
		return {}
	var list := rd.compute_list_begin()
	if list < 0:
		_free_external_state(rd, {"raw": raw, "filtered": filtered, "mip_views": mip_views})
		return {}
	rd.compute_list_bind_compute_pipeline(list, _external_copy_pipeline)
	rd.compute_list_bind_uniform_set(list, copy_set, 0)
	rd.compute_list_dispatch(list, ceili(float(source_size) / WORKGROUP_SIZE),
			ceili(float(source_size) / WORKGROUP_SIZE), 6)
	rd.compute_list_end()
	return {"owner_id": owner_id, "revision": revision, "source_size": source_size,
			"source_kind": String(packet.get("source_kind", "external_cubemap")),
			"capture_position": capture_position, "source_basis": source_basis,
			"prefilter_mips_per_frame": clampi(mips_per_frame, 1, MIP_COUNT),
			"source_lease": source_lease, "raw": raw, "filtered": filtered,
			"mip_views": mip_views, "next_mip": 0, "ready": false}

func _promote_external_pending(rd: RenderingDevice, active: Dictionary,
			pending: Dictionary) -> Dictionary:
	var filtered: RID = pending.get("filtered", RID())
	var owner_id := int(pending.get("owner_id", 0))
	var revision := int(pending.get("revision", -1))
	var source_size := int(pending.get("source_size", 0))
	var capture_position: Vector3 = pending.get("capture_position", Vector3.ZERO)
	var source_basis: Basis = pending.get("source_basis", Basis.IDENTITY)
	_free_external_state(rd, active)
	pending["filtered"] = RID()
	_free_external_state(rd, pending)
	return {"owner_id": owner_id,
			"revision": revision,
			"source_kind": String(pending.get("source_kind", "external_cubemap")),
			"source_size": source_size,
			"capture_position": capture_position,
			"source_basis": source_basis,
			"filtered": filtered, "ready": filtered.is_valid()}

func _advance_external_prefilter(rd: RenderingDevice, state: Dictionary, budget: int) -> void:
	var raw: RID = state.get("raw", RID())
	var filtered: RID = state.get("filtered", RID())
	var mip_views: Array = state.get("mip_views", [])
	if not raw.is_valid() or not filtered.is_valid() or mip_views.size() != MIP_COUNT:
		return
	var end_mip := mini(MIP_COUNT, int(state.get("next_mip", 0)) + maxi(budget, 1))
	while int(state.get("next_mip", 0)) < end_mip:
		var mip := int(state.get("next_mip", 0))
		var mip_size := maxi(1, CUBE_SIZE >> mip)
		if mip >= _prefilter_ubos.size() or not _prefilter_ubos[mip].is_valid():
			return
		var uniforms: Array[RDUniform] = [
			U.sampled(0, _sampler, raw), U.image(1, mip_views[mip]),
			U.uniform_buffer(2, _prefilter_ubos[mip])]
		var uniform_set := UniformSetCacheRD.get_cache(_prefilter_shader, 0, uniforms)
		if not uniform_set.is_valid():
			return
		var list := rd.compute_list_begin()
		if list < 0:
			return
		rd.compute_list_bind_compute_pipeline(list, _prefilter_pipeline)
		rd.compute_list_bind_uniform_set(list, uniform_set, 0)
		rd.compute_list_dispatch(list, ceili(float(mip_size) / WORKGROUP_SIZE),
				ceili(float(mip_size) / WORKGROUP_SIZE), 6)
		rd.compute_list_end()
		state["next_mip"] = mip + 1
	state["ready"] = int(state.get("next_mip", 0)) >= MIP_COUNT

func _create_cube(rd: RenderingDevice, size: int, mips: int, usage: int) -> RID:
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_CUBE
	format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	format.width = size
	format.height = size
	format.depth = 1
	format.array_layers = 6
	format.mipmaps = mips
	format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	format.usage_bits = usage
	return rd.texture_create(format, RDTextureView.new())

func _create_cube_mip_views(rd: RenderingDevice, texture: RID) -> Array[RID]:
	var result: Array[RID] = []
	if not texture.is_valid():
		return result
	for mip in MIP_COUNT:
		var view := rd.texture_create_shared_from_slice(RDTextureView.new(), texture, 0, mip, 1,
				RenderingDevice.TEXTURE_SLICE_CUBEMAP)
		if not view.is_valid():
			for created in result:
				if created.is_valid(): rd.free_rid(created)
			return []
		result.append(view)
	return result

func _prepare_atlas(rd: RenderingDevice, probes: Array[Dictionary]) -> bool:
	var signature: Array = []
	for probe in probes:
		signature.append(int(probe.get("owner_id", 0)))
		signature.append(int(probe.get("source_revision", 0)))
		signature.append(probe.get("radiance_rid", RID()))
	if signature == _atlas_signature and _atlas.is_valid() and rd.texture_is_valid(_atlas):
		return true
	if _atlas.is_valid():
		rd.free_rid(_atlas)
		_atlas = RID()
	_atlas_signature.clear()
	if probes.is_empty():
		_sync_owned_rids()
		return false
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_CUBE_ARRAY
	format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	format.width = CUBE_SIZE
	format.height = CUBE_SIZE
	format.depth = 1
	format.array_layers = probes.size() * 6
	format.mipmaps = MIP_COUNT
	format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	_atlas = rd.texture_create(format, RDTextureView.new())
	if not _atlas.is_valid():
		return false
	for probe_index in probes.size():
		var source: RID = probes[probe_index].get("radiance_rid", RID())
		if not source.is_valid():
			return false
		for mip in MIP_COUNT:
			var dimension := maxi(1, CUBE_SIZE >> mip)
			for face in 6:
				var copy_error := rd.texture_copy(source, _atlas, Vector3i.ZERO, Vector3i.ZERO,
						Vector3i(dimension, dimension, 1), mip, mip, face, probe_index * 6 + face)
				if copy_error != OK:
					_warn_once("A filtered cubemap could not be copied into the shared probe atlas.")
					return false
	_atlas_signature = signature
	_sync_owned_rids()
	return true

func _update_probe_buffer(rd: RenderingDevice, probes: Array[Dictionary]) -> bool:
	var count := probes.size()
	if count <= 0 or count > MAX_PROBES:
		return false
	var required := count * 224
	if not _probe_buffer.is_valid() or _probe_buffer_capacity < required:
		if _probe_buffer.is_valid(): rd.free_rid(_probe_buffer)
		_probe_buffer = rd.storage_buffer_create(required)
		_probe_buffer_capacity = required
		_sync_owned_rids()
		if not _probe_buffer.is_valid(): return false
	var floats := PackedFloat32Array()
	floats.resize(count * 56)
	var offset := 0
	for probe in probes:
		var local_to_world: Transform3D = probe.get("local_to_world", Transform3D.IDENTITY)
		var world_to_local := local_to_world.affine_inverse()
		_append_transform(floats, offset, local_to_world)
		_append_transform(floats, offset + 16, world_to_local)
		var source_basis: Basis = probe.get("source_basis", Basis.IDENTITY)
		var source_world_to_local := Transform3D(source_basis.orthonormalized(), Vector3.ZERO).affine_inverse()
		_append_transform(floats, offset + 32, source_world_to_local)
		offset += 48
		var capture_origin: Vector3 = probe.get("capture_position", local_to_world.origin)
		var blend_distance := maxf(float(probe.get("blend_distance", 0.0)), 0.0)
		var size: Vector3 = probe.get("size", Vector3.ONE)
		var intensity := maxf(float(probe.get("intensity", 1.0)), 0.0)
		for value in [capture_origin.x, capture_origin.y, capture_origin.z, blend_distance,
				size.x * 0.5, size.y * 0.5, size.z * 0.5, intensity]:
			floats[offset] = value
			offset += 1
	var bytes := floats.to_byte_array()
	return rd.buffer_update(_probe_buffer, 0, bytes.size(), bytes) == OK

func _append_transform(values: PackedFloat32Array, offset: int, transform: Transform3D) -> void:
	var basis := transform.basis
	var columns := [basis.x, basis.y, basis.z]
	for column in 3:
		var value: Vector3 = columns[column]
		values[offset + column * 4] = value.x
		values[offset + column * 4 + 1] = value.y
		values[offset + column * 4 + 2] = value.z
		values[offset + column * 4 + 3] = 0.0
	var origin := transform.origin
	values[offset + 12] = origin.x
	values[offset + 13] = origin.y
	values[offset + 14] = origin.z
	values[offset + 15] = 1.0

func _transform_bytes(transform: Transform3D) -> PackedByteArray:
	var values := PackedFloat32Array()
	values.resize(16)
	_append_transform(values, 0, transform)
	return values.to_byte_array()

func _projection_bytes(projection: Projection) -> PackedByteArray:
	var values := PackedFloat32Array()
	values.resize(16)
	for column in 4:
		for row in 4:
			values[column * 4 + row] = projection[column][row]
	return values.to_byte_array()

func _clear_output(rd: RenderingDevice, texture: RID) -> void:
	if texture.is_valid():
		rd.texture_clear(texture, Color(0, 0, 0, 0), 0, 1, 0, 1)

func _free_external_state(rd: RenderingDevice, state: Dictionary) -> void:
	for value in state.get("mip_views", []):
		if value is RID and value.is_valid(): rd.free_rid(value)
	for key in ["raw", "filtered"]:
		var value: Variant = state.get(key, RID())
		if value is RID and value.is_valid(): rd.free_rid(value)
	state.erase("source_lease")

func _current_owned_rids() -> Array[RID]:
	var result: Array[RID] = [_candidate_pipeline, _candidate_shader, _prefilter_pipeline,
			_prefilter_shader, _external_copy_pipeline, _external_copy_shader,
			_sampler, _atlas, _probe_buffer, _candidate_ubo]
	result.append_array(_prefilter_ubos)
	for state in _external_states.values():
		if state is Dictionary:
			for substate_key in ["active", "pending"]:
				var substate: Variant = state.get(substate_key, {})
				if substate is Dictionary:
					# Free shared views before the parent textures they reference.
					for value in substate.get("mip_views", []):
						if value is RID: result.append(value)
					for key in ["raw", "filtered"]:
						var value: Variant = substate.get(key, RID())
						if value is RID: result.append(value)
	return result

func _sync_owned_rids() -> void:
	_replace_owned_rid_snapshot(_current_owned_rids())

func _take_owned_rids() -> Array[RID]:
	# PREDELETE may have suspended dispatch to this Resource's script. Read only
	# detached property values through Object.get, matching PassBase's snapshot
	# lifecycle; never call a derived helper on the dying script instance.
	var states_value: Variant = super.call("get", "_external_states")
	if not states_value is Dictionary:
		return super._take_owned_rids()
	var owned: Array[RID] = []
	for name in ["_candidate_pipeline", "_prefilter_pipeline", "_candidate_shader",
			"_prefilter_shader", "_external_copy_pipeline", "_external_copy_shader",
			"_sampler", "_atlas", "_probe_buffer", "_candidate_ubo"]:
		var value: Variant = super.call("get", name)
		if value is RID and value.is_valid():
			owned.append(value)
	var prefilter_ubos_value: Variant = super.call("get", "_prefilter_ubos")
	if prefilter_ubos_value is Array:
		for value in prefilter_ubos_value:
			if value is RID and value.is_valid():
				owned.append(value)
	for state_value in states_value.values():
		if not state_value is Dictionary:
			continue
		for substate_key in ["active", "pending"]:
			var substate: Variant = state_value.get(substate_key, {})
			if not substate is Dictionary:
				continue
			for value in substate.get("mip_views", []):
				if value is RID and value.is_valid():
					owned.append(value)
			for key in ["raw", "filtered"]:
				var texture_value: Variant = substate.get(key, RID())
				if texture_value is RID and texture_value.is_valid():
					owned.append(texture_value)
	states_value.clear()
	for name in ["_candidate_pipeline", "_prefilter_pipeline", "_candidate_shader",
			"_prefilter_shader", "_external_copy_pipeline", "_external_copy_shader",
			"_sampler", "_atlas", "_probe_buffer", "_candidate_ubo"]:
		super.call("set", name, RID())
	var empty_prefilter_ubos: Array[RID] = []
	super.call("set", "_prefilter_ubos", empty_prefilter_ubos)
	super.call("set", "_atlas_signature", [])
	super.call("set", "_probe_buffer_capacity", 0)
	var rids := super._take_owned_rids()
	rids.append_array(owned)
	return rids

func _warn_once(message: String) -> void:
	if _warnings.has(message):
		return
	_warnings[message] = true
	push_warning("FengReflectProbe: " + message)
