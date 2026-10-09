@tool
extends RefCounted
## Render-thread GPU resources and dispatches for the Feng cloud library passes.
## This helper deliberately owns only addon-created RIDs; texture RIDs returned
## by FRPPassContext and Texture resources remain borrowed.

const SHADER_ROOT := "res://addons/feng-cloud/shaders/"
const BUFFER_SCOPE: StringName = &"frp_cloud_gpu"
const WORKGROUP := 8
const FRAME_BYTES := 304
const MATERIAL_BYTES := 304
const LIGHTING_BYTES := 192
const ATMOSPHERE_BYTES := 256
const FOG_BYTES := 112
const NATIVE_SHADOW_BYTES := 624
const PROJECTION_BYTES := 560
const CLOUD_ATMOSPHERE_VISIBILITY_BYTES := 32
const VOLUME_SAMPLING_BYTES := 96
const MAX_BUFFER_STATES := 8
const PURE_UE58_KERNEL_SHA256 := [
	"1fca2733bbf40247374a16b71510c1bd45bdb83978c15af89ea997fbc624df10",
	"84a48a812c126c163dc5f21c94637787df37bb41fc03f178350ac72f10d88f9b",
]
const VRT_MODE0_PHASE_ORDER := [0, 2, 3, 1]
const VRT_MODE2_PHASE_ORDER := [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]

var _pipelines: Dictionary = {}
var _buffers: Dictionary = {}
var _sampler := RID()
var _material_sampler := RID()
var _shadow_sampler := RID()
var _neutral_shape := RID()
var _neutral_weather := RID()
var _neutral_lut := RID()
var _neutral_volume := RID()
var _neutral_depth := RID()
var _neutral_sky_2d := RID()
var _neutral_sky_array := RID()
var _last_error := ""


func render_shadow(ctx: FRPPassContext, snapshot: Dictionary, scene_data: RenderSceneData,
		view: int, buffers: RenderSceneBuffersRD, rd: RenderingDevice, owner_id: int) -> bool:
	if buffers == null or rd == null or ctx == null or scene_data == null:
		_release_buffer(buffers, rd)
		return false
	if view != 0:
		return true
	if snapshot.is_empty() or not ctx.has_cloud_snapshot():
		_clear_shadow(ctx, buffers, rd)
		return true
	var shadow_settings := _effective_shadow_settings(snapshot)
	var ao_settings: Dictionary = snapshot.get("sky_ao", {})
	var shadow_requested := false
	for settings in shadow_settings:
		shadow_requested = shadow_requested or (bool(settings.get("enabled", false))
				and float(settings.get("producer_strength", 0.0)) > 0.0)
	var ao_requested := bool(ao_settings.get("enabled", false)) and float(ao_settings.get("strength", 0.0)) > 0.0
	if not shadow_requested and not ao_requested:
		_clear_shadow(ctx, buffers, rd)
		return true
	ctx.prepare_lighting()
	var packets := _read_packets(ctx)
	if not _packets_valid(packets):
		return false
	var light_enabled0: bool = packets.lighting.size() > 19 and packets.lighting[19] > 0.5
	var light_enabled1: bool = packets.lighting.size() > 31 and packets.lighting[31] > 0.5
	var map_enabled0: bool = shadow_requested and bool(shadow_settings[0].get("enabled", false)) and light_enabled0
	var map_enabled1: bool = shadow_requested and bool(shadow_settings[1].get("enabled", false)) and light_enabled1
	var ao_enabled := ao_requested
	var shadow_size0 := _shadow_resolution(shadow_settings[0]) if map_enabled0 else 1
	var shadow_size1 := _shadow_resolution(shadow_settings[1]) if map_enabled1 else 1
	var filter_count0 := _shadow_spatial_filter_count(shadow_settings[0], shadow_size0) if map_enabled0 else 0
	var filter_count1 := _shadow_spatial_filter_count(shadow_settings[1], shadow_size1) if map_enabled1 else 0
	if not map_enabled0 and not map_enabled1 and _buffers.is_empty():
		_release_pipeline_family(rd, "cloud_shadow.glslinc")
		_release_native_shadow_sampler(rd)
	if filter_count0 == 0 and filter_count1 == 0 and _buffers.is_empty():
		_release_pipeline_family(rd, "cloud_shadow_filter.glslinc")
	if not ao_enabled and _buffers.is_empty():
		_release_pipeline_family(rd, "cloud_ao.glslinc")
		_release_pipeline_family(rd, "cloud_ao_filter.glslinc")
		_release_clamp_sampler(rd)
	if not map_enabled0 and not map_enabled1 and not ao_enabled:
		_clear_shadow(ctx, buffers, rd)
		return true
	var state := _ensure_buffer_state(buffers, rd, owner_id, Vector2i.ONE, 1, 0, true)
	if state.is_empty() or not _ensure_shadow_neutral_resources(rd,
			map_enabled0 or map_enabled1, ao_enabled):
		return false
	if not _update_ubo(state, "material_ubo", packets.material, MATERIAL_BYTES, rd, true):
		return false
	state.capture = ctx.is_cloud_capture()
	var projection_data := _make_projection_parameters(snapshot, packets.lighting, packets.material, scene_data)
	if projection_data.size() != 140 or not _update_ubo(state, "projection_ubo", projection_data, PROJECTION_BYTES, rd):
		return false
	ctx.set_cloud_projection_parameters(projection_data)
	var ao_size := _resolution(ao_settings.get("resolution", 512)) if ao_enabled else 1
	if not _ensure_shadow_textures(buffers, rd, state, shadow_size0, shadow_size1, ao_size,
			map_enabled0, map_enabled1, ao_enabled, filter_count0, filter_count1):
		return false
	var inputs: Array[RID] = _material_textures(ctx, rd)
	var layout_inputs := _material_layout_inputs(ctx, snapshot, rd)
	if not bool(layout_inputs.get("ok", false)):
		return false
	var material_uniforms: Array[RDUniform] = []
	_add_uniform_buffer(material_uniforms, 1, state.material_ubo)
	_add_uniform_buffer(material_uniforms, 23, state.projection_ubo)
	_add_sampled(material_uniforms, 5, _material_sampler, inputs[0])
	_add_sampled(material_uniforms, 6, _material_sampler, inputs[1])
	_add_sampled(material_uniforms, 7, _material_sampler, inputs[2])
	_add_sampled(material_uniforms, 8, _material_sampler, inputs[3])
	_add_material_layout_uniforms(material_uniforms, layout_inputs)
	if bool(layout_inputs.get("enabled", false)):
		var ue58_time_ubo := _update_ue58_time_ubo(ctx, snapshot, state, rd, scene_data, 0)
		if not ue58_time_ubo.is_valid():
			return false
		_add_uniform_buffer(material_uniforms, 32, ue58_time_ubo)
	var kernel_source := str(snapshot.get("material", {}).get("kernel_source", ""))
	var layout_defines: Dictionary = layout_inputs.get("defines", {})
	var shadow_pipeline: Dictionary = _ensure_pipeline(rd, "cloud_shadow.glslinc", layout_defines, kernel_source) if map_enabled0 or map_enabled1 else {}
	var shadow_filter_pipeline: Dictionary = _ensure_pipeline(rd, "cloud_shadow_filter.glslinc") \
		if filter_count0 > 0 or filter_count1 > 0 else {}
	var ao_pipeline: Dictionary = _ensure_pipeline(rd, "cloud_ao.glslinc", layout_defines, kernel_source) if ao_enabled else {}
	var ao_filter_pipeline: Dictionary = _ensure_pipeline(rd, "cloud_ao_filter.glslinc") if ao_enabled else {}
	if ((map_enabled0 or map_enabled1) and shadow_pipeline.is_empty()) \
			or ((filter_count0 > 0 or filter_count1 > 0) and shadow_filter_pipeline.is_empty()) \
			or (ao_enabled and (ao_pipeline.is_empty() or ao_filter_pipeline.is_empty())):
		return false
	var filtered_outputs: Array[RID] = [state.shadow0, state.shadow1]
	for slot in 2:
		var map_active := map_enabled0 if slot == 0 else map_enabled1
		if not map_active:
			continue
		var output: RID = state.shadow0 if slot == 0 else state.shadow1
		var settings: Dictionary = shadow_settings[slot]
		var shadow_uniforms := material_uniforms.duplicate()
		var set0 := _uniform_set(shadow_pipeline.shader, 0, shadow_uniforms)
		var set1 := _uniform_set(shadow_pipeline.shader, 1, _image_uniforms(3, output))
		var push := PackedInt32Array([slot, 0, 0, 0]).to_byte_array()
		var res := Vector2i(_shadow_resolution(settings), _shadow_resolution(settings))
		if not _dispatch(rd, shadow_pipeline.pipeline, [set0, set1], res, 1, push):
			return false
		var filter_count: int = filter_count0 if slot == 0 else filter_count1
		if filter_count > 0:
			var filtered: RID = _dispatch_shadow_filter_chain(rd, shadow_filter_pipeline,
				state, slot, output, filter_count)
			if not filtered.is_valid():
				return false
			filtered_outputs[slot] = filtered
	if ao_enabled:
		var ao_uniforms := material_uniforms.duplicate()
		var ao_set0 := _uniform_set(ao_pipeline.shader, 0, ao_uniforms)
		var ao_set1 := _uniform_set(ao_pipeline.shader, 1, _image_uniforms(7, state.ao_stats))
		if not _dispatch(rd, ao_pipeline.pipeline, [ao_set0, ao_set1], Vector2i(ao_size, ao_size)):
			return false
		var filter_uniforms: Array[RDUniform] = []
		_add_uniform_buffer(filter_uniforms, 1, state.material_ubo)
		_add_uniform_buffer(filter_uniforms, 23, state.projection_ubo)
		_add_sampled(filter_uniforms, 28, _sampler, state.ao_stats)
		var filter_set0 := _uniform_set(ao_filter_pipeline.shader, 0, filter_uniforms)
		var filter_set1 := _uniform_set(ao_filter_pipeline.shader, 1, _image_uniforms(5, state.ao_final))
		if not _dispatch(rd, ao_filter_pipeline.pipeline, [filter_set0, filter_set1], Vector2i(ao_size, ao_size)):
			return false
	ctx.set_cloud_shadow_outputs(filtered_outputs[0] if map_enabled0 else RID(),
			filtered_outputs[1] if map_enabled1 else RID(), state.ao_final if ao_enabled else RID(),
			state.ao_stats if ao_enabled else RID())
	_buffers[buffers.get_instance_id()] = state
	return true


func _clear_shadow(ctx: FRPPassContext, buffers: RenderSceneBuffersRD, rd: RenderingDevice) -> void:
	ctx.set_cloud_shadow_outputs(RID(), RID(), RID(), RID())
	ctx.clear_cloud_projection_parameters()
	_release_buffer(buffers, rd)
	_release_idle_resources(rd)


func render_clouds(ctx: FRPPassContext, snapshot: Dictionary, scene_data: RenderSceneData,
		view: int, buffers: RenderSceneBuffersRD, rd: RenderingDevice, owner_id: int,
		vrt_mode: int) -> bool:
	var volume_deferred := ctx != null and ctx.has_method("is_volume_deferred_composition") \
			and bool(ctx.call("is_volume_deferred_composition"))
	var fsss_deferred := ctx != null \
			and bool(ctx.get_meta(&"frp_fsss_deferred_composition", false))
	var composition_deferred := volume_deferred or fsss_deferred
	if ctx != null and view == 0:
		ctx.set_meta(&"frp_cloud_fog_composition", {})
	if buffers == null or rd == null or ctx == null or scene_data == null:
		_release_buffer(buffers, rd)
		return false
	if snapshot.is_empty():
		ctx.set_cloud_outputs(RID(), RID(), RID(), RID())
		_release_buffer(buffers, rd)
		_release_idle_resources(rd)
		return true
	if not ctx.has_cloud_snapshot():
		ctx.set_cloud_outputs(RID(), RID(), RID(), RID())
		_release_buffer(buffers, rd)
		_release_idle_resources(rd)
		return false
	var capture := ctx.is_cloud_capture()
	if not capture and not bool(snapshot.get("render_in_main_pass", true)):
		ctx.set_cloud_outputs(RID(), RID(), RID(), RID())
		_release_buffer(buffers, rd)
		_release_idle_resources(rd)
		return true
	var orthographic_view := scene_data.get_cam_projection().is_orthogonal()
	var mode := 3 if capture or orthographic_view else clampi(vrt_mode, 0, 3)
	var buffers_size := buffers.get_internal_size()
	if buffers_size.x <= 0 or buffers_size.y <= 0:
		return false
	var view_count := maxi(buffers.get_view_count(), 1)
	var state := _ensure_buffer_state(buffers, rd, owner_id, buffers_size, view_count, mode, false)
	if state.is_empty() or not _ensure_neutral_resources(rd):
		return false
	var volume_sidecar_radiance := RID()
	var volume_sidecar_transmittance := RID()
	if composition_deferred:
		if not _ensure_volume_composition_outputs(buffers, state, buffers_size, view_count, rd):
			return false
		volume_sidecar_radiance = _named(buffers, state, "volume_composition_radiance")
		volume_sidecar_transmittance = _named(buffers, state, "volume_composition_transmittance")
		if not _valid_texture(rd, volume_sidecar_radiance) \
				or not _valid_texture(rd, volume_sidecar_transmittance):
			return false
		if view == 0:
			rd.texture_clear(volume_sidecar_radiance, Color(0.0, 0.0, 0.0, 0.0),
				0, 1, 0, view_count)
			rd.texture_clear(volume_sidecar_transmittance, Color(1.0, 1.0, 1.0, 1.0),
				0, 1, 0, view_count)
	var packets := _read_packets(ctx)
	if not _packets_valid(packets):
		return false
	var material: PackedFloat32Array = packets.material
	var inputs: Array[RID] = _material_textures(ctx, rd)
	var layout_inputs := _material_layout_inputs(ctx, snapshot, rd)
	if not bool(layout_inputs.get("ok", false)):
		return false
	var blue_noise := _neutral_lut if capture else _blue_noise_texture(snapshot, rd)
	if not blue_noise.is_valid():
		return false
	var source_signature := _source_signature(snapshot, material, inputs, layout_inputs.textures,
		blue_noise, packets.lighting, packets.atmosphere, mode)
	var now_usec := Time.get_ticks_usec()
	if view == 0:
		_begin_cloud_frame(ctx, state, scene_data, buffers_size, source_signature, now_usec, mode, capture)
	var frame_packet := _make_frame_packet(ctx, snapshot, scene_data, buffers, state, view, mode, capture)
	var frame_key := "frame_ubo_%d" % view
	if frame_packet.bytes.size() != FRAME_BYTES or not _update_ubo_bytes(state, frame_key, frame_packet.bytes, FRAME_BYTES, rd):
		return false
	if not _update_shared_ubos(state, rd, packets):
		return false
	if not _update_cloud_atmosphere_ubos(ctx, state, rd):
		return false
	if bool(layout_inputs.get("enabled", false)):
		if not _update_ue58_time_ubo(ctx, snapshot, state, rd, scene_data, view).is_valid():
			return false
	var sky_ambient: RID = state.sky_ambient
	var lighting: PackedFloat32Array = packets.lighting
	var ambient_lighting := PackedFloat32Array()
	if lighting.size() >= 48:
		ambient_lighting.append_array(lighting.slice(0, 16))
		ambient_lighting.append_array(lighting.slice(40, 48))
	var ambient_atmosphere: PackedFloat32Array = packets.atmosphere.duplicate()
	if ambient_atmosphere.size() >= 3:
		ambient_atmosphere[0] = 0.0
		ambient_atmosphere[1] = 0.0
		ambient_atmosphere[2] = 0.0
	var ambient_signature := hash([
		snapshot.get("provider_id", 0), snapshot.get("world_id", 0),
		snapshot.get("sky_rendering_signature", []), snapshot.get("atmosphere_revision", -1),
		ctx.get_cloud_capture_batch_id() if capture else 0,
		ambient_lighting, ambient_atmosphere, _rid_id(ctx.get_cloud_sky_octmap()),
		float(snapshot.get("planet_radius_m", 0.0)), snapshot.get("planet_center_m", Vector3.ZERO)
	])
	if ambient_signature != state.ambient_signature:
		if not _dispatch_ambient(ctx, state, packets, rd):
			return false
		state.ambient_signature = ambient_signature
	var kernel_source := str(snapshot.get("material", {}).get("kernel_source", ""))
	var material_snapshot: Dictionary = snapshot.get("material", {})
	var kernel_layout := str(material_snapshot.get("kernel_layout", snapshot.get("kernel_layout", "builtin")))
	var kernel_hash := kernel_source.sha256_text() if not kernel_source.is_empty() else ""
	var pure_kernel := kernel_source.is_empty()
	if kernel_layout == "ue58_default" \
			and PURE_UE58_KERNEL_SHA256.has(kernel_hash):
		pure_kernel = true
	var secondary_enabled := mode == 0
	var layout_defines: Dictionary = layout_inputs.get("defines", {}).duplicate()
	layout_defines["FENG_CLOUD_VRT_SECONDARY"] = 1 if secondary_enabled else 0
	layout_defines["FENG_CLOUD_SAFE_SELF_SHADOW_SATURATION_BREAK"] = 1 if pure_kernel else 0
	var trace_pipeline := _ensure_pipeline(rd, "cloud_trace.glslinc", layout_defines,
		kernel_source, kernel_hash)
	var reconstruct_pipeline := _ensure_pipeline(rd, "cloud_reconstruct.glslinc", {"FENG_CLOUD_VRT_SECONDARY": 1 if secondary_enabled else 0})
	var scene_format_layer := buffers.get_color_layer(view, false)
	var composite_format := _scene_format_variant(rd, scene_format_layer)
	if not composite_format.has("FENG_CLOUD_SCENE_RGBA32"):
		return false
	composite_format["FENG_CLOUD_VRT_SECONDARY"] = 1 if secondary_enabled else 0
	composite_format["FENG_CLOUD_VOLUME_DEFERRED"] = 1 if composition_deferred else 0
	var composite_pipeline := _ensure_pipeline(rd, "cloud_composite.glslinc", composite_format)
	if trace_pipeline.is_empty() or reconstruct_pipeline.is_empty() or composite_pipeline.is_empty():
		return false
	var trace_ubo: RID = state.ubos.get(frame_key, RID())
	var trace_uniforms: Array[RDUniform] = []
	_add_uniform_buffer(trace_uniforms, 0, trace_ubo)
	_add_uniform_buffer(trace_uniforms, 1, state.material_ubo)
	_add_uniform_buffer(trace_uniforms, 2, state.lighting_ubo)
	_add_uniform_buffer(trace_uniforms, 3, state.atmosphere_ubo)
	_add_uniform_buffer(trace_uniforms, 4, state.fog_ubo)
	_add_uniform_buffer(trace_uniforms, 23, state.ubos.get("cloud_projection_ubo", RID()))
	_add_uniform_buffer(trace_uniforms, 34, state.ubos.get("cloud_atmosphere_visibility_ubo", RID()))
	_add_sampled(trace_uniforms, 39, _sampler, blue_noise)
	_add_sampled(trace_uniforms, 5, _material_sampler, inputs[0])
	_add_sampled(trace_uniforms, 6, _material_sampler, inputs[1])
	_add_sampled(trace_uniforms, 7, _material_sampler, inputs[2])
	_add_sampled(trace_uniforms, 8, _material_sampler, inputs[3])
	_add_material_layout_uniforms(trace_uniforms, layout_inputs)
	if bool(layout_inputs.get("enabled", false)):
		_add_uniform_buffer(trace_uniforms, 32, state.ubos.get("ue58_time_ubo", RID()))
	_add_sampled(trace_uniforms, 9, _sampler, _texture_or(rd, ctx.get_atmosphere_optical_texture(), _neutral_lut))
	_add_sampled(trace_uniforms, 10, _sampler, _texture_or(rd, ctx.get_atmosphere_multiple_texture(), _neutral_lut))
	var native_shadow_depth := ctx.get_cloud_shadow_sampler()
	if not native_shadow_depth.is_valid():
		native_shadow_depth = _shadow_sampler
	var native_shadow_atlas := _texture_or(rd, ctx.get_cloud_directional_shadow_atlas(), _neutral_depth)
	_add_sampled(trace_uniforms, 12, native_shadow_depth, native_shadow_atlas)
	var scene_depth := buffers.get_depth_layer(view)
	if not _valid_texture(rd, scene_depth):
		scene_depth = _neutral_depth
	_add_sampled(trace_uniforms, 13, _sampler, scene_depth)
	_add_uniform_buffer(trace_uniforms, 22, state.native_shadow_ubo)
	_add_sampled(trace_uniforms, 27, _sampler, sky_ambient)
	var cloud_shadow0 := _texture_or(rd, ctx.get_cloud_output(3), _neutral_lut)
	var cloud_shadow1 := _texture_or(rd, ctx.get_cloud_output(4), _neutral_lut)
	var cloud_ao_stats := _texture_or(rd, ctx.get_cloud_output(7), _neutral_lut)
	_add_sampled(trace_uniforms, 24, _sampler, cloud_shadow0)
	_add_sampled(trace_uniforms, 25, _sampler, cloud_shadow1)
	_add_sampled(trace_uniforms, 28, _sampler, cloud_ao_stats)
	var trace_output_items: Array = [
		[0, state.trace_radiance], [1, state.trace_transmittance], [2, state.trace_depth]
	]
	if secondary_enabled:
		trace_output_items.append_array([[9, state.trace_secondary_radiance], [10, state.trace_secondary_transmittance]])
	var trace_set0 := _uniform_set(trace_pipeline.shader, 0, trace_uniforms)
	var trace_set1 := _uniform_set(trace_pipeline.shader, 1, _image_uniforms3(trace_output_items))
	var trace_size: Vector2i = state.trace_size
	if not _dispatch(rd, trace_pipeline.pipeline, [trace_set0, trace_set1], trace_size):
		return false
	var write_index: int = state.write_index
	var previous_index: int = state.history_index
	var current_radiance: RID = state.trace_radiance
	var current_transmittance: RID = state.trace_transmittance
	var current_depth: RID = state.trace_depth
	var current_secondary_radiance: RID = RID()
	var current_secondary_transmittance: RID = RID()
	if mode == 0 or mode == 2:
		var reconstruct_uniforms: Array[RDUniform] = []
		_add_uniform_buffer(reconstruct_uniforms, 0, trace_ubo)
		_add_sampled(reconstruct_uniforms, 15, _sampler, state.full_radiance[previous_index])
		_add_sampled(reconstruct_uniforms, 16, _sampler, state.full_transmittance[previous_index])
		_add_sampled(reconstruct_uniforms, 17, _sampler, state.full_depth[previous_index])
		_add_sampled(reconstruct_uniforms, 18, _sampler, state.trace_radiance)
		_add_sampled(reconstruct_uniforms, 19, _sampler, state.trace_transmittance)
		_add_sampled(reconstruct_uniforms, 20, _sampler, state.trace_depth)
		_add_sampled(reconstruct_uniforms, 13, _sampler, scene_depth)
		if secondary_enabled:
			_add_sampled(reconstruct_uniforms, 35, _sampler, state.trace_secondary_radiance)
			_add_sampled(reconstruct_uniforms, 36, _sampler, state.trace_secondary_transmittance)
			_add_sampled(reconstruct_uniforms, 37, _sampler, state.full_secondary_radiance[previous_index])
			_add_sampled(reconstruct_uniforms, 38, _sampler, state.full_secondary_transmittance[previous_index])
		var reconstruct_set0 := _uniform_set(reconstruct_pipeline.shader, 0, reconstruct_uniforms)
		var reconstruct_output_items: Array = [
			[0, state.full_radiance[write_index]], [1, state.full_transmittance[write_index]], [2, state.full_depth[write_index]]
		]
		if secondary_enabled:
			reconstruct_output_items.append_array([
				[9, state.full_secondary_radiance[write_index]],
				[10, state.full_secondary_transmittance[write_index]]
			])
		var reconstruct_set1 := _uniform_set(reconstruct_pipeline.shader, 1, _image_uniforms3(reconstruct_output_items))
		if not _dispatch(rd, reconstruct_pipeline.pipeline, [reconstruct_set0, reconstruct_set1], state.reconstruct_size):
			return false
		current_radiance = state.full_radiance[write_index]
		current_transmittance = state.full_transmittance[write_index]
		current_depth = state.full_depth[write_index]
		if secondary_enabled:
			current_secondary_radiance = state.full_secondary_radiance[write_index]
			current_secondary_transmittance = state.full_secondary_transmittance[write_index]
	var color_layer: RID = scene_format_layer
	if not _valid_texture(rd, color_layer):
		_report("The current eye color layer is unavailable for cloud composition.")
		return false
	var composite_uniforms: Array[RDUniform] = []
	_add_uniform_buffer(composite_uniforms, 0, trace_ubo)
	_add_sampled(composite_uniforms, 18, _sampler, current_radiance)
	_add_sampled(composite_uniforms, 19, _sampler, current_transmittance)
	_add_sampled(composite_uniforms, 20, _sampler, current_depth)
	_add_sampled(composite_uniforms, 13, _sampler, scene_depth)
	var volume_packet := PackedFloat32Array()
	var volume_texture := RID()
	if ctx.has_method("get_volume_sampling_parameters") and ctx.has_method("get_volume_texture"):
		var packet_value: Variant = ctx.call("get_volume_sampling_parameters")
		if packet_value is PackedFloat32Array:
			volume_packet = packet_value
		volume_texture = ctx.call("get_volume_texture")
	var volume_valid := volume_deferred and volume_packet.size() == 20 and volume_packet[19] > 0.5 \
			and _valid_texture(rd, volume_texture)
	if volume_packet.size() != 20:
		volume_packet = PackedFloat32Array([
			1.0, 0.0, 32.0, 1.0,
			1.0, 1.0, 1.0, 1.0,
			1.0, 1.0, 1.0, 1.0,
			0.0, 1.0, 0.05, 1.0,
			1.0, 1.0, 1.0, 0.0,
		])
	else:
		volume_packet = volume_packet.duplicate()
		if not volume_valid:
			volume_packet[19] = 0.0
	volume_packet.append_array(PackedFloat32Array([
		float(view), _pre_exposure(ctx, view), 1.0 if volume_valid else 0.0, 0.0,
	]))
	var volume_ubo_key := "volume_sampling_ubo_%d" % view
	if not _update_ubo(state, volume_ubo_key, volume_packet, VOLUME_SAMPLING_BYTES, rd):
		return false
	_add_sampled(composite_uniforms, 40, _sampler,
			_texture_or(rd, volume_texture, _neutral_volume))
	_add_uniform_buffer(composite_uniforms, 41, state.ubos[volume_ubo_key])
	if secondary_enabled:
		_add_sampled(composite_uniforms, 35, _sampler, current_secondary_radiance)
		_add_sampled(composite_uniforms, 36, _sampler, current_secondary_transmittance)
	var composite_set0 := _uniform_set(composite_pipeline.shader, 0, composite_uniforms)
	var composite_output_items: Array = [[4, color_layer]]
	if composition_deferred:
		composite_output_items.append_array([
			[11, volume_sidecar_radiance], [12, volume_sidecar_transmittance]])
	var composite_set1 := _uniform_set(composite_pipeline.shader, 1,
			_image_uniforms3(composite_output_items))
	if not _dispatch(rd, composite_pipeline.pipeline, [composite_set0, composite_set1], buffers_size):
		return false
	ctx.set_cloud_outputs(current_radiance, current_transmittance, current_depth, sky_ambient)
	if composition_deferred and view == view_count - 1:
		var frame_inputs: Variant = ctx.call("get_volume_frame_inputs", 0) \
				if ctx.has_method("get_volume_frame_inputs") else {}
		var frame_generation := int(frame_inputs.get("frame_generation", -1)) \
				if frame_inputs is Dictionary and bool(frame_inputs.get("valid", false)) else -1
		var history_material_snapshot: Dictionary = snapshot.get("material", {})
		var material_revision := int(history_material_snapshot.get("revision", -1))
		var material_layout := str(history_material_snapshot.get("kernel_layout",
				snapshot.get("kernel_layout", "builtin")))
		var history_identity := var_to_str([
			int(snapshot.get("provider_id", 0)), int(snapshot.get("world_id", 0)),
			int(snapshot.get("planet_source_id", 0)), material_revision,
			material_layout, view_count,
		]).sha256_text()
		var native_snapshot_signature := _read_native_cloud_snapshot_signature(ctx)
		if bool(native_snapshot_signature.get("valid", false)):
			ctx.set_meta(&"frp_cloud_fog_composition", {
				"radiance": volume_sidecar_radiance,
				"transmittance": volume_sidecar_transmittance,
				"native_snapshot_source_signature": int(native_snapshot_signature.signature),
				"gpu_source_signature": source_signature,
				"history_identity": history_identity,
				"view_count": view_count,
				"frame_generation": frame_generation,
				"buffer_id": buffers.get_instance_id(),
				"internal_size": buffers_size,
			})
		else:
			# No verifiable current native snapshot means the sidecar must not be
			# consumed by the later Height Fog callback.
			ctx.set_meta(&"frp_cloud_fog_composition", {})
	if not capture and (mode == 0 or mode == 2):
		state.view_history[view] = {
			"view_projection": frame_packet.view_projection,
			"camera": frame_packet.camera,
			"projection": frame_packet.projection_unjittered,
			"wind": frame_packet.wind,
			"radiance_scale": frame_packet.radiance_scale,
		}
	if view == state.view_count - 1 and not capture and (mode == 0 or mode == 2):
		state.history_index = write_index
		state.write_index = previous_index
		state.history_valid = true
	_buffers[buffers.get_instance_id()] = state
	return true


func cleanup(rd: RenderingDevice) -> void:
	_release_payload(rd, take_cleanup_payload())


func _release_pipeline_family(rd: RenderingDevice, filename: String) -> void:
	var prefix := filename + "|"
	for key in _pipelines.keys():
		if str(key) != filename and not str(key).begins_with(prefix):
			continue
		var entry: Dictionary = _pipelines[key]
		for resource_name in ["pipeline", "shader"]:
			var rid: RID = entry.get(resource_name, RID())
			if rd != null and rid.is_valid():
				rd.free_rid(rid)
		_pipelines.erase(key)


func _release_native_shadow_sampler(rd: RenderingDevice) -> void:
	if rd != null and _shadow_sampler.is_valid():
		rd.free_rid(_shadow_sampler)
	_shadow_sampler = RID()


func _release_clamp_sampler(rd: RenderingDevice) -> void:
	if rd != null and _sampler.is_valid():
		rd.free_rid(_sampler)
	_sampler = RID()


func _release_idle_resources(rd: RenderingDevice) -> void:
	if _buffers.is_empty():
		cleanup(rd)


func take_cleanup_payload(extra_rids: Array[RID] = []) -> Dictionary:
	var contexts: Array = []
	var rids: Array[RID] = []
	for state in _buffers.values():
		var reference: Variant = state.get("weak")
		var buffers: RenderSceneBuffersRD = reference.get_ref() if reference is WeakRef else null
		if buffers != null:
			for scope in state.get("owned_scopes", [state.get("scope", BUFFER_SCOPE)]):
				contexts.append({"buffers": buffers, "scope": scope})
		for buffer in state.get("ubos", {}).values():
			if buffer is RID and buffer.is_valid():
				rids.append(buffer)
	for entry in _pipelines.values():
		for name in ["pipeline", "shader"]:
			var rid: RID = entry.get(name, RID())
			if rid.is_valid():
				rids.append(rid)
	for rid in [_sampler, _material_sampler, _shadow_sampler, _neutral_shape, _neutral_weather,
			_neutral_lut, _neutral_volume, _neutral_depth, _neutral_sky_2d, _neutral_sky_array]:
		if rid.is_valid():
			rids.append(rid)
	for rid in extra_rids:
		if rid.is_valid():
			rids.append(rid)
	_buffers.clear()
	_pipelines.clear()
	_sampler = RID()
	_material_sampler = RID()
	_shadow_sampler = RID()
	_neutral_shape = RID()
	_neutral_weather = RID()
	_neutral_lut = RID()
	_neutral_volume = RID()
	_neutral_depth = RID()
	_neutral_sky_2d = RID()
	_neutral_sky_array = RID()
	return {"contexts": contexts, "rids": rids}


static func release_cleanup_payload(payload: Dictionary) -> void:
	RenderingServer.call_on_render_thread(func():
		_release_payload(RenderingServer.get_rendering_device(), payload)
	)


static func _release_payload(rd: RenderingDevice, payload: Dictionary) -> void:
	if rd == null:
		return
	# Scene buffers own named textures; the payload owns only standalone RIDs.
	for context in payload.contexts:
		context.buffers.clear_context(context.scope)
	for rid in payload.rids:
		rd.free_rid(rid)


func _ensure_buffer_state(buffers: RenderSceneBuffersRD, rd: RenderingDevice, owner_id: int,
		full_size: Vector2i, view_count: int, mode: int, shadow_only: bool) -> Dictionary:
	var key := buffers.get_instance_id()
	var state: Dictionary = _buffers.get(key, {})
	var trace_scale := 1
	var reconstruct_scale := 1
	if not shadow_only:
		trace_scale = 4 if mode == 0 or mode == 2 else (2 if mode == 1 else 1)
	var trace_size := Vector2i(ceili(float(full_size.x) / trace_scale), ceili(float(full_size.y) / trace_scale))
	if not shadow_only and mode == 0:
		reconstruct_scale = 2
	var reconstruct_size := Vector2i(ceili(float(full_size.x) / reconstruct_scale), ceili(float(full_size.y) / reconstruct_scale))
	var signature := [full_size, view_count, trace_size, reconstruct_size, shadow_only, mode, owner_id]
	var recreate: bool = state.is_empty() or state.get("signature", []) != signature
	if not recreate and not shadow_only and not _buffer_state_textures_valid(buffers, rd, state, mode):
		recreate = true
	if recreate:
		if not state.is_empty():
			self._release_named_state(buffers, rd, state)
		state = {
			"weak": weakref(buffers),
			"scope": StringName("frp_cloud_gpu_%d" % owner_id),
			"owned_scopes": [StringName("frp_cloud_gpu_%d" % owner_id)],
			"signature": signature,
			"size": full_size,
			"view_count": view_count,
			"trace_size": trace_size,
			"reconstruct_size": reconstruct_size,
			"mode": mode,
			"ubos": {},
			"view_history": {},
			"history_valid": false,
			"history_index": 0,
			"write_index": 1,
			"frame_index": 0,
			"last_frame_usec": 0,
			"source_signature": -1,
			"ambient_signature": -1,
			"ue58_time_key": [],
			"ue58_time_seconds": 0.0,
			"ue58_camera_world_m": Vector3.ZERO,
			"ue58_time_valid": false,
		}
		_buffers[key] = state
		if not shadow_only:
			var array_count := maxi(view_count, 1)
			state.trace_secondary_radiance = RID()
			state.trace_secondary_transmittance = RID()
			state.full_secondary_radiance = []
			state.full_secondary_transmittance = []
			var layout := _cloud_texture_layout(mode)
			for channel in layout:
				var spec: Array = layout[channel]
				var trace_key := "trace_" + str(channel)
				var texture := _create_cloud_texture(buffers, state, rd, trace_key,
						spec[0], trace_size, array_count, true, spec[1])
				if not texture.is_valid():
					return {}
				state[trace_key] = texture
				var history: Array[RID] = []
				state["full_" + str(channel)] = history
				if mode == 0 or mode == 2:
					for index in 2:
						texture = _create_cloud_texture(buffers, state, rd,
								"full_%s_%d" % [channel, index], spec[0], reconstruct_size,
								array_count, true, spec[1])
						if not texture.is_valid():
							return {}
						history.append(texture)
			state.sky_ambient = _create_cloud_texture(buffers, state, rd, "sky_ambient",
					RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, Vector2i.ONE,
					1, false, Color(0.0, 0.0, 0.0, 0.0))
			if not state.sky_ambient.is_valid():
				return {}
		_buffers[key] = state
		_prune_buffers(key, rd)
	return state


func _cloud_texture_layout(mode: int) -> Dictionary:
	var radiance := [RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, Color(0.0, 0.0, 0.0, 0.0)]
	var transmittance := [RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, Color(1.0, 1.0, 1.0, 0.0)]
	var layout := {
		"radiance": radiance,
		"transmittance": transmittance,
		"depth": [RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, Color(0.0, 0.0, 0.0, 0.0)],
	}
	if mode == 0:
		layout["secondary_radiance"] = radiance
		layout["secondary_transmittance"] = transmittance
	return layout


func _ensure_volume_composition_outputs(buffers: RenderSceneBuffersRD, state: Dictionary,
		size: Vector2i, view_count: int, rd: RenderingDevice) -> bool:
	for texture_name in ["volume_composition_radiance", "volume_composition_transmittance"]:
		var texture := _named(buffers, state, texture_name)
		if _valid_texture(rd, texture):
			continue
		if not _create_named_texture(buffers, state, texture_name,
				RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, size,
				view_count, true, rd):
			return false
		texture = _named(buffers, state, texture_name)
		if not _valid_texture(rd, texture):
			return false
	return true


func _create_cloud_texture(buffers: RenderSceneBuffersRD, state: Dictionary,
		rd: RenderingDevice, name: String, format: int, size: Vector2i, layers: int,
		array_texture: bool, clear_color: Color) -> RID:
	if not _create_named_texture(buffers, state, name, format, size, layers, array_texture, rd):
		return RID()
	var texture := _named(buffers, state, name)
	rd.texture_clear(texture, clear_color, 0, 1, 0, layers)
	return texture


func _buffer_state_textures_valid(buffers: RenderSceneBuffersRD, rd: RenderingDevice,
		state: Dictionary, mode: int) -> bool:
	var required := {"sky_ambient": state.get("sky_ambient", RID())}
	for channel in _cloud_texture_layout(mode):
		var trace_key := "trace_" + str(channel)
		required[trace_key] = state.get(trace_key, RID())
		if mode == 0 or mode == 2:
			var history: Array = state.get("full_" + str(channel), [])
			if history.size() != 2:
				return false
			for index in 2:
				required["full_%s_%d" % [channel, index]] = history[index]
	for name in required:
		var current := _named(buffers, state, name)
		if current != required[name] or not _valid_texture(rd, current):
			return false
	return true


func _ensure_shadow_textures(buffers: RenderSceneBuffersRD, rd: RenderingDevice, state: Dictionary,
		resolution0: int, resolution1: int, ao_resolution: int,
		map_enabled0: bool, map_enabled1: bool, ao_enabled: bool,
		filter_count0: int, filter_count1: int) -> bool:
	return _ensure_shadow_map(buffers, rd, state, 0, map_enabled0, resolution0) \
		and _ensure_shadow_map(buffers, rd, state, 1, map_enabled1, resolution1) \
		and _ensure_shadow_filter_chain(buffers, rd, state, 0, map_enabled0, resolution0, filter_count0) \
		and _ensure_shadow_filter_chain(buffers, rd, state, 1, map_enabled1, resolution1, filter_count1) \
		and _ensure_ao_textures(buffers, rd, state, ao_enabled, ao_resolution)


func _ensure_shadow_filter_chain(buffers: RenderSceneBuffersRD, rd: RenderingDevice,
		state: Dictionary, slot: int, enabled: bool, source_resolution: int,
		filter_count: int) -> bool:
	var stages_key := "shadow%d_filter_stages" % slot
	var signature_key := "shadow%d_filter_signature" % slot
	var signature := [enabled, source_resolution, filter_count]
	var existing: Array = state.get(stages_key, [])
	if state.get(signature_key, []) == signature and existing.size() == filter_count:
		var existing_valid := true
		for stage in existing:
			if not _valid_texture(rd, stage.get("texture", RID())):
				existing_valid = false
				break
		if existing_valid:
			return true
	_release_shadow_filter_chain(buffers, state, slot)
	if not enabled or filter_count <= 0:
		state[signature_key] = signature
		return true
	var stages: Array[Dictionary] = []
	state[stages_key] = stages
	var size := source_resolution
	for index in filter_count:
		size = maxi(size >> 1, 1)
		var scope := StringName("%s_shadow%d_filter%d" % [str(state.scope), slot, index])
		var texture_name := "shadow_filter_%d" % index
		var stage := {"scope": scope, "texture": RID(), "size": Vector2i(size, size)}
		stages.append(stage)
		state[stages_key] = stages
		if not _create_named_texture(buffers, state, texture_name,
				RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, Vector2i(size, size), 1, false, rd, scope):
			_release_shadow_filter_chain(buffers, state, slot)
			return false
		var texture := _named(buffers, state, texture_name, scope)
		if not _valid_texture(rd, texture):
			_release_shadow_filter_chain(buffers, state, slot)
			return false
		stage["texture"] = texture
	state[signature_key] = signature
	return true


func _release_shadow_filter_chain(buffers: RenderSceneBuffersRD, state: Dictionary, slot: int) -> void:
	var stages_key := "shadow%d_filter_stages" % slot
	for stage in state.get(stages_key, []):
		var scope: StringName = stage.get("scope", &"")
		_clear_owned_scope(buffers, state, scope)
	state[stages_key] = []
	state.erase("shadow%d_filter_signature" % slot)


func _dispatch_shadow_filter_chain(rd: RenderingDevice, pipeline: Dictionary,
		state: Dictionary, slot: int, source: RID, filter_count: int) -> RID:
	var stages: Array = state.get("shadow%d_filter_stages" % slot, [])
	if stages.size() != filter_count or not pipeline.get("pipeline", RID()).is_valid():
		return RID()
	var current_source := source
	for stage in stages:
		var uniforms: Array[RDUniform] = []
		_add_sampled(uniforms, 33, _material_sampler, current_source)
		var set0 := _uniform_set(pipeline.shader, 0, uniforms)
		var destination: RID = stage.get("texture", RID())
		var set1 := _uniform_set(pipeline.shader, 1, _image_uniforms(8, destination))
		var size: Vector2i = stage.get("size", Vector2i.ZERO)
		if not _dispatch(rd, pipeline.pipeline, [set0, set1], size):
			return RID()
		current_source = destination
	return current_source


func _ensure_shadow_map(buffers: RenderSceneBuffersRD, rd: RenderingDevice, state: Dictionary,
		slot: int, enabled: bool, resolution: int) -> bool:
	var scope_key := "shadow%d_scope" % slot
	var texture_key := "shadow%d" % slot
	var resolution_key := "shadow%d_resolution" % slot
	var scope: StringName = state.get(scope_key, StringName("%s_shadow%d" % [str(state.scope), slot]))
	state[scope_key] = scope
	if not enabled:
		_clear_owned_scope(buffers, state, scope)
		state[texture_key] = RID()
		state.erase(resolution_key)
		return true
	var texture := _named(buffers, state, texture_key, scope)
	if _valid_texture(rd, texture) and int(state.get(resolution_key, 0)) == resolution:
		state[texture_key] = texture
		return true
	_clear_owned_scope(buffers, state, scope)
	if not _create_named_texture(buffers, state, texture_key, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
			Vector2i(resolution, resolution), 1, false, rd, scope):
		return false
	texture = _named(buffers, state, texture_key, scope)
	if not _valid_texture(rd, texture):
		return false
	state[texture_key] = texture
	state[resolution_key] = resolution
	rd.texture_clear(texture, Color(0.0, 0.0, 0.0, 0.0), 0, 1, 0, 1)
	return true


func _ensure_ao_textures(buffers: RenderSceneBuffersRD, rd: RenderingDevice, state: Dictionary,
		enabled: bool, resolution: int) -> bool:
	var scope_key := "ao_scope"
	var scope: StringName = state.get(scope_key, StringName("%s_ao" % str(state.scope)))
	state[scope_key] = scope
	if not enabled:
		_clear_owned_scope(buffers, state, scope)
		state.ao_stats = RID()
		state.ao_final = RID()
		state.erase("ao_resolution")
		return true
	var stats := _named(buffers, state, "ao_stats", scope)
	var final := _named(buffers, state, "ao_final", scope)
	if _valid_texture(rd, stats) and _valid_texture(rd, final) \
			and int(state.get("ao_resolution", 0)) == resolution:
		state.ao_stats = stats
		state.ao_final = final
		return true
	_clear_owned_scope(buffers, state, scope)
	if not _create_named_texture(buffers, state, "ao_stats", RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
			Vector2i(resolution, resolution), 1, false, rd, scope) \
			or not _create_named_texture(buffers, state, "ao_final", RenderingDevice.DATA_FORMAT_R16_SFLOAT,
				Vector2i(resolution, resolution), 1, false, rd, scope):
		return false
	stats = _named(buffers, state, "ao_stats", scope)
	final = _named(buffers, state, "ao_final", scope)
	if not _valid_texture(rd, stats) or not _valid_texture(rd, final):
		return false
	state.ao_stats = stats
	state.ao_final = final
	state.ao_resolution = resolution
	rd.texture_clear(stats, Color(0.0, 0.0, 0.0, 0.0), 0, 1, 0, 1)
	rd.texture_clear(final, Color(1.0, 1.0, 1.0, 1.0), 0, 1, 0, 1)
	return true


func _clear_owned_scope(buffers: RenderSceneBuffersRD, state: Dictionary, scope: StringName) -> void:
	if buffers != null and scope != &"":
		var known_scopes: Array = state.get("owned_scopes", [])
		if scope in known_scopes:
			buffers.clear_context(scope)
			known_scopes.erase(scope)
			state.owned_scopes = known_scopes


func _register_owned_scope(state: Dictionary, scope: StringName) -> void:
	var known_scopes: Array = state.get("owned_scopes", [])
	if scope not in known_scopes:
		known_scopes.append(scope)
		state.owned_scopes = known_scopes


func _create_named_texture(buffers: RenderSceneBuffersRD, state: Dictionary, name: String,
		format: int, size: Vector2i, layers: int, array_texture: bool, rd: RenderingDevice,
		scope_override: StringName = &"") -> bool:
	var scope: StringName = state.scope if scope_override == &"" else scope_override
	_register_owned_scope(state, scope)
	var texture_format := RDTextureFormat.new()
	texture_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY if array_texture else RenderingDevice.TEXTURE_TYPE_2D
	texture_format.format = format
	texture_format.width = maxi(size.x, 1)
	texture_format.height = maxi(size.y, 1)
	texture_format.depth = 1
	texture_format.array_layers = maxi(layers, 1)
	texture_format.mipmaps = 1
	texture_format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	texture_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	texture_format.is_discardable = false
	var texture := buffers.create_texture_from_format(scope, StringName(name), texture_format, RDTextureView.new(), true)
	return _valid_texture(rd, texture)


func _named(buffers: RenderSceneBuffersRD, state: Dictionary, name: String,
		scope_override: StringName = &"") -> RID:
	var scope: StringName = state.scope if scope_override == &"" else scope_override
	return buffers.get_texture(scope, StringName(name)) if buffers.has_texture(scope, StringName(name)) else RID()


func _read_packets(ctx: FRPPassContext) -> Dictionary:
	return {
		"material": ctx.get_cloud_material_parameters(),
		"lighting": ctx.get_cloud_lighting_parameters(),
		"atmosphere": ctx.get_atmosphere_parameters(),
		"fog": ctx.get_height_fog_parameters(),
		"native_shadow": ctx.get_cloud_native_shadow_parameters(),
	}


func _packets_valid(packets: Dictionary) -> bool:
	if packets.material.size() != 76 or packets.lighting.size() != 48:
		_report("Cloud material or lighting packet does not match its frozen GPU layout.")
		return false
	return true


func _update_shared_ubos(state: Dictionary, rd: RenderingDevice, packets: Dictionary) -> bool:
	if not _update_ubo(state, "material_ubo", packets.material, MATERIAL_BYTES, rd, true) \
			or not _update_ubo(state, "lighting_ubo", packets.lighting, LIGHTING_BYTES, rd, true):
		return false
	var atmosphere: PackedFloat32Array = packets.atmosphere
	var fog: PackedFloat32Array = packets.fog
	var native_shadow: PackedFloat32Array = packets.native_shadow
	if atmosphere.size() != 64:
		atmosphere = PackedFloat32Array()
		atmosphere.resize(64)
	if fog.size() != 28:
		fog = PackedFloat32Array()
		fog.resize(28)
	if native_shadow.size() != 156:
		native_shadow = PackedFloat32Array()
		native_shadow.resize(156)
	return _update_ubo(state, "atmosphere_ubo", atmosphere, ATMOSPHERE_BYTES, rd, true) \
		and _update_ubo(state, "fog_ubo", fog, FOG_BYTES, rd, true) \
		and _update_ubo(state, "native_shadow_ubo", native_shadow, NATIVE_SHADOW_BYTES, rd, true)


func _update_cloud_atmosphere_ubos(ctx: FRPPassContext, state: Dictionary,
		rd: RenderingDevice) -> bool:
	var packet := ctx.get_cloud_atmosphere_parameters()
	if packet.size() != 148:
		_report("Cloud atmosphere packet must contain 148 floats; using its disabled default.")
		packet = PackedFloat32Array()
		packet.resize(148)
		packet[140] = -1.0
		packet[141] = -1.0
	return _update_ubo(state, "cloud_projection_ubo", packet.slice(0, 140), PROJECTION_BYTES, rd) \
		and _update_ubo(state, "cloud_atmosphere_visibility_ubo", packet.slice(140, 148),
		CLOUD_ATMOSPHERE_VISIBILITY_BYTES, rd)


func _update_ubo(state: Dictionary, key: String, values: PackedFloat32Array,
		byte_count: int, rd: RenderingDevice, cache_identical: bool = false) -> bool:
	var buffer: RID = state.ubos.get(key, RID())
	if cache_identical and buffer.is_valid() \
			and state.get("ubo_cache_values_" + key) == values:
		return true
	if not _update_ubo_bytes(state, key, values.to_byte_array(), byte_count, rd):
		return false
	if cache_identical:
		state["ubo_cache_values_" + key] = values.duplicate()
	return true


func _update_ubo_bytes(state: Dictionary, key: String, bytes: PackedByteArray,
		byte_count: int, rd: RenderingDevice) -> bool:
	if bytes.size() != byte_count:
		_report("Cloud %s packet has %d bytes; expected %d." % [key, bytes.size(), byte_count])
		return false
	state.erase("ubo_cache_values_" + key)
	var ubos: Dictionary = state.ubos
	var buffer: RID = ubos.get(key, RID())
	if not buffer.is_valid():
		buffer = rd.uniform_buffer_create(byte_count)
		if not buffer.is_valid():
			return false
		ubos[key] = buffer
		state.ubos = ubos
	state[key] = buffer
	return rd.buffer_update(buffer, 0, bytes.size(), bytes) == OK


func _material_textures(ctx: FRPPassContext, rd: RenderingDevice) -> Array[RID]:
	var textures: Array[RID] = []
	for index in 4:
		var texture := _texture_or(rd, ctx.get_cloud_texture(index), RID())
		if not texture.is_valid():
			texture = _neutral_shape if index == 0 or index == 1 or index == 3 else _neutral_weather
		textures.append(texture)
	return textures


func _material_layout_inputs(ctx: FRPPassContext, snapshot: Dictionary,
		rd: RenderingDevice) -> Dictionary:
	var material: Variant = snapshot.get("material", {})
	var kernel_layout := str(snapshot.get("kernel_layout", "builtin"))
	if material is Dictionary:
		kernel_layout = str(material.get("kernel_layout", kernel_layout))
	if kernel_layout == "" or kernel_layout == "builtin":
		return {"ok": true, "enabled": false, "textures": [], "defines": {}}
	if kernel_layout != "ue58_default":
		_report("Unsupported cloud material layout '%s'." % kernel_layout)
		return {"ok": false, "enabled": false, "textures": [], "defines": {}}
	if not material is Dictionary or str(material.get("kernel_source", "")).is_empty():
		_report("UE 5.8 cloud layout requires its generated material kernel source.")
		return {"ok": false, "enabled": true, "textures": [], "defines": {}}
	var textures: Array[RID] = []
	var labels := ["Pattern", "Mask", "Height Profile"]
	for index in 3:
		var value := ctx.get_cloud_layout_texture(index)
		if not _valid_texture(rd, value):
			_report("UE 5.8 cloud %s texture is missing or invalid." % labels[index])
			return {"ok": false, "enabled": true, "textures": [], "defines": {}}
		var texture_format: RDTextureFormat = rd.texture_get_format(value)
		if texture_format == null or texture_format.texture_type != RenderingDevice.TEXTURE_TYPE_2D:
			_report("UE 5.8 cloud %s input must be a 2D texture." % labels[index])
			return {"ok": false, "enabled": true, "textures": [], "defines": {}}
		textures.append(value)
	return {
		"ok": true,
		"enabled": true,
		"textures": textures,
		"defines": {"FENG_CLOUD_UE58_LAYOUT_INPUTS": 1},
	}


func _add_material_layout_uniforms(uniforms: Array[RDUniform], layout_inputs: Dictionary) -> void:
	if not bool(layout_inputs.get("enabled", false)):
		return
	var textures: Array = layout_inputs.get("textures", [])
	_add_sampled(uniforms, 29, _material_sampler, textures[0])
	_add_sampled(uniforms, 30, _material_sampler, textures[1])
	_add_sampled(uniforms, 31, _material_sampler, textures[2])


func _update_ue58_time_ubo(ctx: FRPPassContext, snapshot: Dictionary,
		state: Dictionary, rd: RenderingDevice, scene_data: RenderSceneData, view: int) -> RID:
	var capture := ctx.is_cloud_capture()
	var seconds := 0.0
	var camera_world_m := Vector3.ZERO
	if capture:
		var capture_origin := ctx.get_cloud_capture_origin_world_m()
		if not capture_origin.is_finite():
			_report("UE 5.8 cloud capture camera origin is invalid.")
			return RID()
		var material: Dictionary = snapshot.get("material", {})
		var cache_key := [
			int(snapshot.get("provider_id", 0)), int(snapshot.get("world_id", 0)),
			int(snapshot.get("planet_source_id", 0)), int(snapshot.get("atmosphere_revision", -1)),
			snapshot.get("sky_rendering_signature", []), int(material.get("revision", -1)),
			str(material.get("kernel_source", "")),
			ctx.get_cloud_capture_batch_id(),
		]
		if bool(state.get("ue58_time_valid", false)) and state.get("ue58_time_key", []) == cache_key:
			seconds = float(state.get("ue58_time_seconds", 0.0))
			camera_world_m = state.get("ue58_camera_world_m", capture_origin)
		else:
			seconds = float(ctx.get_cloud_time_seconds())
			camera_world_m = capture_origin
			state.ue58_time_key = cache_key
			state.ue58_time_seconds = seconds
			state.ue58_camera_world_m = camera_world_m
			state.ue58_time_valid = true
	else:
		seconds = float(ctx.get_cloud_time_seconds())
		var camera := scene_data.get_cam_transform().orthonormalized()
		camera.origin += camera.basis * scene_data.get_view_eye_offset(view)
		camera_world_m = camera.origin
	if not is_finite(seconds):
		seconds = 0.0
	if not camera_world_m.is_finite():
		camera_world_m = Vector3.ZERO
	var time_values := PackedFloat32Array([
		seconds, camera_world_m.x, camera_world_m.y, camera_world_m.z
	])
	if not _update_ubo(state, "ue58_time_ubo", time_values, 16, rd):
		return RID()
	return state.ubos.get("ue58_time_ubo", RID())


func _ensure_shadow_neutral_resources(rd: RenderingDevice, needs_native_shadow: bool,
		needs_clamp_sampler: bool) -> bool:
	if not _ensure_cloud_samplers(rd, needs_native_shadow, needs_clamp_sampler):
		return false
	if not _neutral_shape.is_valid():
		_neutral_shape = _create_neutral_texture(rd, RenderingDevice.TEXTURE_TYPE_3D,
			RenderingDevice.DATA_FORMAT_R8_UNORM, PackedByteArray([0]), 1, 1, 1)
	if not _neutral_weather.is_valid():
		_neutral_weather = _create_neutral_texture(rd, RenderingDevice.TEXTURE_TYPE_2D,
			RenderingDevice.DATA_FORMAT_R8_UNORM, PackedByteArray([255]), 1, 1, 1)
	return _material_sampler.is_valid() and _neutral_shape.is_valid() and _neutral_weather.is_valid() \
		and (not needs_clamp_sampler or _sampler.is_valid()) \
		and (not needs_native_shadow or _shadow_sampler.is_valid())


func _ensure_neutral_resources(rd: RenderingDevice) -> bool:
	if not _ensure_shadow_neutral_resources(rd, true, true):
		return false
	if not _neutral_lut.is_valid():
		_neutral_lut = _create_neutral_texture(rd, RenderingDevice.TEXTURE_TYPE_2D,
			RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, PackedFloat32Array([0.0, 0.0, 0.0, 0.0]).to_byte_array(), 1, 1, 1)
	if not _neutral_volume.is_valid():
		_neutral_volume = _create_neutral_texture(rd, RenderingDevice.TEXTURE_TYPE_3D,
			RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
			PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0x3c]), 1, 1, 1)
	if not _neutral_depth.is_valid():
		_neutral_depth = _create_neutral_depth_texture(rd)
	if not _neutral_sky_2d.is_valid():
		_neutral_sky_2d = _create_neutral_texture(rd, RenderingDevice.TEXTURE_TYPE_2D,
			RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0]), 1, 1, 1)
	if not _neutral_sky_array.is_valid():
		_neutral_sky_array = _create_neutral_texture(rd, RenderingDevice.TEXTURE_TYPE_2D_ARRAY,
			RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0]), 1, 1, 1)
	return _neutral_lut.is_valid() and _neutral_volume.is_valid() \
		and _neutral_depth.is_valid() and _neutral_sky_2d.is_valid() \
		and _neutral_sky_array.is_valid()


func _ensure_cloud_samplers(rd: RenderingDevice, needs_native_shadow: bool,
		needs_clamp_sampler: bool) -> bool:
	if needs_clamp_sampler and not _sampler.is_valid():
		var state := RDSamplerState.new()
		state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		state.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		_sampler = rd.sampler_create(state)
	if not _material_sampler.is_valid():
		var material_state := RDSamplerState.new()
		material_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		material_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		material_state.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		material_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
		material_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
		material_state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
		_material_sampler = rd.sampler_create(material_state)
	if needs_native_shadow and not _shadow_sampler.is_valid():
		var shadow_state := RDSamplerState.new()
		shadow_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		shadow_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		shadow_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		shadow_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		shadow_state.enable_compare = true
		shadow_state.compare_op = RenderingDevice.COMPARE_OP_GREATER
		_shadow_sampler = rd.sampler_create(shadow_state)
	return (not needs_clamp_sampler or _sampler.is_valid()) and _material_sampler.is_valid() \
		and (not needs_native_shadow or _shadow_sampler.is_valid())


func _create_neutral_texture(rd: RenderingDevice, texture_type: int, format: int,
		data: PackedByteArray, width: int, height: int, depth: int) -> RID:
	var texture_format := RDTextureFormat.new()
	texture_format.texture_type = texture_type
	texture_format.format = format
	texture_format.width = width
	texture_format.height = height
	texture_format.depth = depth
	texture_format.array_layers = 1
	texture_format.mipmaps = 1
	texture_format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	texture_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	return rd.texture_create(texture_format, RDTextureView.new(), [data])


func _create_neutral_depth_texture(rd: RenderingDevice) -> RID:
	var texture_format := RDTextureFormat.new()
	texture_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	texture_format.format = RenderingDevice.DATA_FORMAT_D32_SFLOAT
	texture_format.width = 1
	texture_format.height = 1
	texture_format.depth = 1
	texture_format.array_layers = 1
	texture_format.mipmaps = 1
	texture_format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	texture_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var depth_texture := rd.texture_create(texture_format, RDTextureView.new())
	if not depth_texture.is_valid():
		return RID()
	if rd.texture_update(depth_texture, 0, PackedFloat32Array([0.0]).to_byte_array()) != OK:
		rd.free_rid(depth_texture)
		return RID()
	return depth_texture


func _dispatch_ambient(ctx: FRPPassContext, state: Dictionary, packets: Dictionary,
		rd: RenderingDevice) -> bool:
	var lighting: PackedFloat32Array = packets.lighting
	var sky_is_array := lighting.size() >= 44 and lighting[43] > 0.5
	var sky := _texture_or(rd, ctx.get_cloud_sky_octmap(), RID())
	if not _valid_texture(rd, sky):
		sky = _neutral_sky_array if sky_is_array else _neutral_sky_2d
	var variant := {"FENG_CLOUD_SKY_OCTMAP_ARRAY": 1 if sky_is_array else 0}
	var ambient_pipeline := _ensure_pipeline(rd, "cloud_sky_ambient.glslinc", variant)
	if ambient_pipeline.is_empty():
		return false
	var uniforms: Array[RDUniform] = []
	_add_uniform_buffer(uniforms, 2, state.lighting_ubo)
	_add_uniform_buffer(uniforms, 3, state.atmosphere_ubo)
	_add_sampled(uniforms, 9, _sampler, _texture_or(rd, ctx.get_atmosphere_optical_texture(), _neutral_lut))
	_add_sampled(uniforms, 10, _sampler, _texture_or(rd, ctx.get_atmosphere_multiple_texture(), _neutral_lut))
	_add_sampled(uniforms, 11, _sampler, sky)
	var set0 := _uniform_set(ambient_pipeline.shader, 0, uniforms)
	var set1 := _uniform_set(ambient_pipeline.shader, 1, _image_uniforms(6, state.sky_ambient))
	return _dispatch(rd, ambient_pipeline.pipeline, [set0, set1], Vector2i(8, 8))


func _begin_cloud_frame(ctx: FRPPassContext, state: Dictionary, scene_data: RenderSceneData,
		viewport_size: Vector2i, source_signature: int, now_usec: int, mode: int, capture: bool) -> void:
	var previous_frame_usec: int = state.last_frame_usec
	var dt := float(now_usec - previous_frame_usec) / 1000000.0 if previous_frame_usec > 0 else 0.0
	var should_reset: bool = source_signature != state.source_signature or mode != state.mode or dt > 0.25
	var camera: Transform3D = scene_data.get_cam_transform()
	var jitter := _taa_jitter(ctx)
	var projection: Projection = _projection_without_jitter(scene_data.get_view_projection(0), jitter)
	var old_history: Dictionary = state.view_history.get(0, {})
	if not old_history.is_empty():
		var old_camera: Transform3D = old_history.camera
		var moved := camera.origin.distance_to(old_camera.origin)
		var angle := camera.basis.z.normalized().angle_to(old_camera.basis.z.normalized())
		if moved > 100.0 or angle > deg_to_rad(45.0) or _projection_changed(old_history.projection, projection, viewport_size):
			should_reset = true
	if should_reset:
		state.frame_index = 0
	if should_reset or capture:
		state.history_valid = false
		state.view_history.clear()
	state.frame_index = int(state.frame_index) + 1
	state.last_frame_usec = now_usec
	state.source_signature = source_signature
	state.mode = mode
	state.capture = capture
	state.dt = clampf(dt, 0.0, 1.0)


func _make_frame_packet(ctx: FRPPassContext, snapshot: Dictionary, scene_data: RenderSceneData,
		buffers: RenderSceneBuffersRD, state: Dictionary, view: int, mode: int,
		capture: bool) -> Dictionary:
	var full_size := buffers.get_internal_size()
	var trace_size: Vector2i = state.trace_size
	var base_camera: Transform3D = scene_data.get_cam_transform().orthonormalized()
	var camera: Transform3D = base_camera
	camera.origin += camera.basis * scene_data.get_view_eye_offset(view)
	var camera_projection: Projection = scene_data.get_view_projection(view)
	var camera_projection_unjittered: Projection = _projection_without_jitter(camera_projection, _taa_jitter(ctx))
	# UE removes TAA jitter before applying the cloud's own VRT sample phase.
	# get_view_projection() already contains the renderer eye offset, so use the
	# base camera inverse here and retain the eye origin only for ray distances.
	var view_projection: Projection = camera_projection_unjittered * Projection(base_camera.affine_inverse())
	var previous: Dictionary = state.view_history.get(view, {})
	var previous_projection: Projection = previous.get("view_projection", view_projection)
	var previous_camera: Transform3D = previous.get("camera", camera)
	var previous_wind: Vector3 = previous.get("wind", Vector3.ZERO)
	var wind := Vector3.ZERO
	var material_snapshot: Dictionary = snapshot.get("material", {})
	var wind_value: Variant = material_snapshot.get("wind_offset_km", Vector3.ZERO)
	if wind_value is Vector3 and wind_value.is_finite():
		wind = wind_value
	var wind_delta := wind - previous_wind if not previous.is_empty() else Vector3.ZERO
	var scene_norm := _scene_exposure_normalization(ctx)
	var pre_exposure := _pre_exposure(ctx, view)
	var radiance_scale := scene_norm * pre_exposure
	var previous_scale := float(previous.get("radiance_scale", radiance_scale))
	var phase := Vector2.ZERO
	if not capture and mode == 0:
		var phase_code: int = VRT_MODE0_PHASE_ORDER[int(state.frame_index) % VRT_MODE0_PHASE_ORDER.size()]
		var half_pixel_offset := Vector2(phase_code & 1, phase_code >> 1)
		# Mode 0 traces on the quarter-res grid but phases the half-res target.
		phase = half_pixel_offset * 2.0 + Vector2(0.5, 0.5)
	elif not capture and mode == 2:
		var phase_code: int = VRT_MODE2_PHASE_ORDER[int(state.frame_index) % VRT_MODE2_PHASE_ORDER.size()]
		phase = Vector2(phase_code & 3, phase_code >> 2)
	var flags := 0
	if capture: flags |= 1
	if bool(state.history_valid) and not capture and (mode == 0 or mode == 2) and not previous.is_empty(): flags |= 2
	if not previous.is_empty() and _camera_cut(previous.camera, camera, previous.projection, camera_projection_unjittered, full_size): flags |= 4
	if camera_projection.is_orthogonal(): flags |= 8
	if not capture and ctx.supports_cloud_holdout(): flags |= 16
	var floats := PackedFloat32Array()
	_append_projection(floats, view_projection.inverse())
	_append_projection(floats, previous_projection)
	_append_projection(floats, Projection(base_camera.affine_inverse()))
	_append4(floats, camera.origin.x, camera.origin.y, camera.origin.z, 1.0)
	_append4(floats, previous_camera.origin.x, previous_camera.origin.y, previous_camera.origin.z, 1.0)
	_append4(floats, full_size.x, full_size.y, 1.0 / maxf(float(full_size.x), 1.0), 1.0 / maxf(float(full_size.y), 1.0))
	_append4(floats, phase.x, phase.y, trace_size.x, trace_size.y)
	_append4(floats, radiance_scale, previous_scale, scene_norm, pre_exposure)
	_append4(floats, wind_delta.x, wind_delta.y, wind_delta.z, state.dt)
	var u32_values := PackedInt32Array([view, int(state.frame_index), flags, mode])
	return {
		"bytes": floats.to_byte_array() + u32_values.to_byte_array(),
		"view_projection": view_projection,
		"camera": camera,
		"projection": camera_projection_unjittered,
		"projection_unjittered": camera_projection_unjittered,
		"wind": wind,
		"radiance_scale": radiance_scale,
	}


func _source_signature(snapshot: Dictionary, material: PackedFloat32Array, textures: Array[RID],
		layout_textures: Array, blue_noise: RID, lighting: PackedFloat32Array,
		atmosphere: PackedFloat32Array, mode: int) -> int:
	var appearance := material.duplicate()
	if appearance.size() >= 28:
		appearance[24] = 0.0
		appearance[25] = 0.0
		appearance[26] = 0.0
	var ids: Array[int] = []
	for texture in textures:
		ids.append(_rid_id(texture))
	var layout_ids: Array[int] = []
	for texture in layout_textures:
		layout_ids.append(_rid_id(texture))
	var history_atmosphere := atmosphere.duplicate()
	if history_atmosphere.size() >= 3:
		history_atmosphere[0] = 0.0
		history_atmosphere[1] = 0.0
		history_atmosphere[2] = 0.0
	return hash([
		int(snapshot.get("provider_id", 0)), int(snapshot.get("world_id", 0)),
		int(snapshot.get("planet_source_id", 0)), int(snapshot.get("atmosphere_revision", -1)),
		snapshot.get("planet_center_m", Vector3.ZERO), snapshot.get("planet_radius_m", 0.0),
		snapshot.get("layer_bottom_m", 0.0), snapshot.get("layer_height_m", 0.0),
		snapshot.get("tracing_max_distance_m", 0.0), snapshot.get("tracing_max_distance_mode", 0),
		snapshot.get("tracing_start_max_distance_m", 0.0),
		snapshot.get("tracing_start_distance_from_camera_m", 0.0),
		snapshot.get("shadow_tracing_distance_m", 0.0),
		snapshot.get("sky_rendering_signature", []), snapshot.get("cloud_shadow", {}),
		snapshot.get("sky_ao", {}), snapshot.get("sun_inputs", []),
		lighting, history_atmosphere, appearance, ids, _rid_id(blue_noise), mode,
		layout_ids, str(snapshot.get("material", {}).get("kernel_layout", snapshot.get("kernel_layout", "builtin"))),
		str(snapshot.get("material", {}).get("kernel_source", "")),
	])


func _read_native_cloud_snapshot_signature(ctx: Object) -> Dictionary:
	if ctx == null or not ctx.has_method("has_cloud_snapshot") \
			or not ctx.has_method("get_cloud_snapshot_source_signature"):
		return {"valid": false}
	var has_snapshot: Variant = ctx.call("has_cloud_snapshot")
	if typeof(has_snapshot) != TYPE_BOOL or not bool(has_snapshot):
		return {"valid": false}
	var signature: Variant = ctx.call("get_cloud_snapshot_source_signature")
	if typeof(signature) != TYPE_INT:
		return {"valid": false}
	return {"valid": true, "signature": int(signature)}


func _blue_noise_texture(snapshot: Dictionary, rd: RenderingDevice) -> RID:
	var resource: Variant = snapshot.get("blue_noise_texture")
	if not resource is Texture2D or not is_instance_valid(resource):
		_report("UE cloud tracing requires the published BlueNoiseScalar texture.")
		return RID()
	var texture := RenderingServer.texture_get_rd_texture(resource.get_rid())
	if not _valid_texture(rd, texture):
		_report("UE cloud BlueNoiseScalar has no live RenderingDevice texture.")
		return RID()
	var texture_format: RDTextureFormat = rd.texture_get_format(texture)
	if texture_format == null or texture_format.texture_type != RenderingDevice.TEXTURE_TYPE_2D \
			or texture_format.width != 128 or texture_format.height != 8192 \
			or texture_format.format != RenderingDevice.DATA_FORMAT_R8_UNORM:
		_report("UE cloud BlueNoiseScalar must be an R8 128x8192 2D texture.")
		return RID()
	return texture


func _make_projection_parameters(snapshot: Dictionary, lighting: PackedFloat32Array,
		material: PackedFloat32Array, scene_data: RenderSceneData) -> PackedFloat32Array:
	var settings := _effective_shadow_settings(snapshot)
	var ao_settings: Dictionary = snapshot.get("sky_ao", {})
	var center := _vector3(snapshot.get("planet_center_m", Vector3.ZERO), Vector3.ZERO)
	var radius := maxf(_finite(float(snapshot.get("planet_radius_m", 6360000.0)), 6360000.0), 1.0)
	var camera := scene_data.get_cam_transform().orthonormalized()
	var radial := (camera.origin - center).normalized()
	if radial.length_squared() < 1e-8:
		radial = Vector3.UP
	var anchor := center + radial * radius
	var output := PackedFloat32Array()
	var world_to_shadow: Array[Projection] = []
	var shadow_to_world: Array[Projection] = []
	var far_depths := PackedFloat32Array([1.0, 1.0])
	var resolutions := PackedFloat32Array([1.0, 1.0])
	var strengths := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	var surface_atmosphere := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	var enabled := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	var counts := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	var sizes: Array[Vector2i] = [Vector2i.ONE, Vector2i.ONE]
	var sun_inputs: Variant = snapshot.get("sun_inputs", [])
	for slot in 2:
		var sun_dictionary: Dictionary = sun_inputs[slot] if sun_inputs is Array and slot < sun_inputs.size() and sun_inputs[slot] is Dictionary else {}
		var direction_index := 16 + slot * 12
		var sun_direction := _vector3_from_packet(lighting, direction_index, Vector3.UP).normalized()
		if sun_direction.length_squared() < 1e-8:
			sun_direction = Vector3.UP
		var config: Dictionary = settings[slot]
		var sun_enabled := direction_index + 3 < lighting.size() and lighting[direction_index + 3] > 0.5
		var map_enabled := sun_enabled and bool(sun_dictionary.get("cast_cloud_shadows", false)) \
			and float(config.get("producer_strength", 1.0)) > 0.0
		var extent_km := maxf(_finite(float(config.get("extent_km", 150.0)), 150.0), 0.1)
		var extent_m := extent_km * 1000.0
		var snap_km := maxf(_finite(float(config.get("snap_length_km", 20.0)), 20.0), 0.0)
		var res := _shadow_resolution(config) if map_enabled else 1
		var snapped_anchor := _snap_anchor(anchor, center, radial, sun_direction, snap_km, extent_m, res,
			bool(config.get("snap_to_pixel_grid", true)))
		var projection_pair := _make_shadow_projection(snapped_anchor, sun_direction, extent_m)
		world_to_shadow.append(projection_pair[0])
		shadow_to_world.append(projection_pair[1])
		far_depths[slot] = 4.0 * extent_km
		resolutions[slot] = float(res)
		var filtered_resolution := _shadow_filtered_resolution(config, res)
		sizes[slot] = Vector2i(filtered_resolution, filtered_resolution)
		strengths[slot] = float(config.get("producer_strength", 1.0)) if map_enabled else 0.0
		strengths[slot + 2] = float(config.get("depth_bias_km", 0.0))
		surface_atmosphere[slot] = float(config.get("surface_strength", 1.0))
		surface_atmosphere[slot + 2] = float(config.get("atmosphere_strength", 1.0))
		enabled[slot] = 1.0 if map_enabled else 0.0
		counts[slot] = _shadow_trace_samples(config, sun_direction, radial)
	var self_shadow_enabled := material.size() > 50 and material[50] > 0.5
	counts[2] = 1.0 if self_shadow_enabled else 0.0
	counts[3] = 1.0 if self_shadow_enabled else 0.0
	var ao_enabled := bool(ao_settings.get("enabled", false)) and float(ao_settings.get("strength", 0.0)) > 0.0
	var ao_extent_km := maxf(_finite(float(ao_settings.get("extent_km", 150.0)), 150.0), 0.1)
	var layer_top_km := maxf(float(snapshot.get("layer_bottom_m", 5000.0)) + float(snapshot.get("layer_height_m", 10000.0)), 1.0) * 0.001
	var ao_snap_km := maxf(_finite(float(ao_settings.get("snap_length_km", 20.0)), 20.0), 0.0)
	var ao_res := _resolution(ao_settings.get("resolution", 512)) if ao_enabled else 1
	var ao_anchor := _snap_anchor(anchor, center, radial, Vector3.DOWN, ao_snap_km,
		ao_extent_km * 1000.0, ao_res, true)
	var ao_near := ao_anchor - Vector3.DOWN * ((layer_top_km + ao_snap_km) * 1000.0)
	var ao_far_depth_km := 2.0 * (layer_top_km + ao_snap_km)
	var ao_projection_pair := _make_direction_projection(ao_near, Vector3.DOWN, ao_extent_km * 1000.0, ao_far_depth_km * 1000.0)
	_append_projection(output, world_to_shadow[0])
	_append_projection(output, world_to_shadow[1])
	_append_projection(output, shadow_to_world[0])
	_append_projection(output, shadow_to_world[1])
	_append_projection(output, ao_projection_pair[0])
	_append_projection(output, ao_projection_pair[1])
	_append4(output, far_depths[0], far_depths[1], resolutions[0], resolutions[1])
	_append4(output, strengths[0], strengths[1], strengths[2], strengths[3])
	_append4(output, surface_atmosphere[0], surface_atmosphere[1], surface_atmosphere[2], surface_atmosphere[3])
	_append4(output, enabled[0], enabled[1], 1.0 if ao_enabled else 0.0, 0.0)
	_append4(output, counts[0], counts[1], counts[2], counts[3])
	_append4(output, float(sizes[0].x), float(sizes[0].y), 1.0 / sizes[0].x, 1.0 / sizes[0].y)
	_append4(output, float(sizes[1].x), float(sizes[1].y), 1.0 / sizes[1].x, 1.0 / sizes[1].y)
	_append4(output, ao_far_depth_km, float(ao_settings.get("strength", 1.0)) if ao_enabled else 0.0,
		float(ao_settings.get("aperture", 0.05)), float(ao_settings.get("sample_count", 10)))
	_append4(output, float(ao_res), float(ao_res), 1.0 / ao_res, 1.0 / ao_res)
	_append4(output, 0.0, -1.0, 0.0, ao_extent_km)
	_append4(output, ao_anchor.x, ao_anchor.y, ao_anchor.z, ao_snap_km)
	return output


func _make_shadow_projection(anchor: Vector3, direction_to_light: Vector3, extent_m: float) -> Array[Projection]:
	return _make_direction_projection(anchor + direction_to_light * (2.0 * extent_m),
		-direction_to_light, extent_m, 4.0 * extent_m)


func _make_direction_projection(origin: Vector3, ray_direction: Vector3, extent_m: float, far_m: float) -> Array[Projection]:
	var direction := ray_direction.normalized()
	if direction.length_squared() < 1e-8:
		direction = Vector3.DOWN
	var camera := Transform3D.IDENTITY
	camera.origin = origin
	var up := Vector3.UP
	if absf(direction.dot(up)) > 0.98:
		up = Vector3.FORWARD
	camera.basis = Basis.looking_at(direction, up)
	var view := Projection(camera.affine_inverse())
	var projection := Projection.create_orthogonal(-extent_m, extent_m, -extent_m, extent_m, 0.1, maxf(far_m, 0.2))
	var world_to_clip := projection * view
	var godot_clip_correction := Projection.create_depth_correction(false)
	world_to_clip = godot_clip_correction * world_to_clip
	var result: Array[Projection] = [world_to_clip, world_to_clip.inverse()]
	return result


func _snap_anchor(anchor: Vector3, planet_center: Vector3, radial: Vector3, direction: Vector3,
		snap_km: float, extent_m: float, resolution: int, pixel_snap: bool) -> Vector3:
	var axis_x := direction.cross(Vector3.UP)
	if axis_x.length_squared() < 1e-8:
		axis_x = direction.cross(Vector3.FORWARD)
	axis_x = axis_x.normalized()
	var axis_y := axis_x.cross(direction).normalized()
	var horizontal := Vector2(anchor.dot(axis_x), anchor.dot(axis_y))
	if snap_km > 0.0:
		var step := snap_km * 1000.0
		horizontal.x = floor((horizontal.x + 0.5 * step) / step) * step
		horizontal.y = floor((horizontal.y + 0.5 * step) / step) * step
	if pixel_snap and resolution > 0:
		var pixel_size := 4.0 * extent_m / float(resolution)
		horizontal.x = round(horizontal.x / pixel_size) * pixel_size
		horizontal.y = round(horizontal.y / pixel_size) * pixel_size
	var radial_component := planet_center + radial * (anchor - planet_center).length()
	return radial_component + axis_x * (horizontal.x - anchor.dot(axis_x)) + axis_y * (horizontal.y - anchor.dot(axis_y))


func _effective_shadow_settings(snapshot: Dictionary) -> Array[Dictionary]:
	var shared: Variant = snapshot.get("cloud_shadow", {})
	var suns: Variant = snapshot.get("sun_inputs", [])
	var result: Array[Dictionary] = []
	for slot in 2:
		var settings: Dictionary = shared.duplicate(true) if shared is Dictionary else {}
		var sun: Dictionary = suns[slot] if suns is Array and slot < suns.size() and suns[slot] is Dictionary else {}
		var override: Variant = sun.get("cloud_shadow", {})
		if override is Dictionary:
			settings.merge(override, true)
		settings["enabled"] = bool(sun.get("cast_cloud_shadows", false))
		result.append(settings)
	return result


func _shadow_resolution(settings: Dictionary) -> int:
	return _resolution(settings.get("resolution", 512))


func _shadow_spatial_filter_count(settings: Dictionary, resolution: int) -> int:
	var requested := clampi(int(round(_finite(float(settings.get("spatial_filtering", 1.0)), 1.0))), 0, 4)
	var count := 0
	var current_size := maxi(resolution, 1)
	while count < requested and current_size > 1:
		current_size = maxi(current_size >> 1, 1)
		count += 1
	return count


func _shadow_filtered_resolution(settings: Dictionary, resolution: int) -> int:
	var output_size := maxi(resolution, 1)
	var count := _shadow_spatial_filter_count(settings, output_size)
	for _index in count:
		output_size = maxi(output_size >> 1, 1)
	return output_size


func _resolution(value: Variant) -> int:
	return clampi(int(round(_finite(float(value), 512.0))), 1, 2048)


func _shadow_trace_samples(settings: Dictionary, sun_direction: Vector3, planet_up: Vector3) -> float:
	var base := clampf(_finite(float(settings.get("sample_count", 16.0)), 16.0), 1.0, 128.0)
	var multiplier := clampf(_finite(float(settings.get("horizon_multiplier", settings.get("horizon_sample_multiplier", 2.0))), 2.0), 1.0, 4.0)
	var horizon := clampf(0.2 / maxf(absf(sun_direction.dot(planet_up)), 1e-6), 0.0, 1.0)
	var extra := maxf(0.0, multiplier - 1.0) * base * horizon
	return minf(256.0, base + extra)


func _scene_format_variant(rd: RenderingDevice, scene_layer: RID) -> Dictionary:
	if not _valid_texture(rd, scene_layer):
		return {}
	var format: RDTextureFormat = rd.texture_get_format(scene_layer)
	if format == null:
		return {}
	if (format.usage_bits & RenderingDevice.TEXTURE_USAGE_STORAGE_BIT) == 0:
		_report("Cloud composition requires storage usage on the resolved scene color layer.")
		return {}
	if format.format == RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT:
		return {"FENG_CLOUD_SCENE_RGBA32": 0}
	if format.format == RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT:
		return {"FENG_CLOUD_SCENE_RGBA32": 1}
	_report("Cloud composition requires an RGBA16F or RGBA32F scene color layer.")
	return {}


func _projection_changed(a: Projection, b: Projection, viewport_size := Vector2i.ONE) -> bool:
	var jitter_tolerance := Vector2(1.0 / maxf(float(viewport_size.x), 1.0), 1.0 / maxf(float(viewport_size.y), 1.0))
	for column in 4:
		var projection_delta: Vector4 = a[column] - b[column]
		if column == 3:
			if absf(projection_delta.x) > jitter_tolerance.x + 1e-5 or absf(projection_delta.y) > jitter_tolerance.y + 1e-5:
				return true
			projection_delta.x = 0.0
			projection_delta.y = 0.0
		if projection_delta.length() > 1e-4:
			return true
	return false


func _taa_jitter(ctx: FRPPassContext) -> Vector2:
	var jitter := ctx.get_taa_jitter()
	return jitter if jitter.is_finite() else Vector2.ZERO


func _projection_without_jitter(value: Projection, jitter: Vector2) -> Projection:
	# RenderSceneData left-multiplies clip translation by the TAA jitter. Undo
	# only that translation so stereo/off-axis terms in the projection survive.
	var correction := Projection.IDENTITY
	var translation: Vector4 = correction[3]
	translation.x = -jitter.x
	translation.y = -jitter.y
	correction[3] = translation
	return correction * value


func _camera_cut(previous: Transform3D, current: Transform3D, previous_projection: Projection,
		current_projection: Projection, viewport_size := Vector2i.ONE) -> bool:
	return previous.origin.distance_to(current.origin) > 100.0 \
		or previous.basis.z.normalized().angle_to(current.basis.z.normalized()) > deg_to_rad(45.0) \
		or _projection_changed(previous_projection, current_projection, viewport_size)


func _scene_exposure_normalization(ctx: FRPPassContext) -> float:
	var value := ctx.get_scene_exposure_normalization()
	return value if is_finite(value) and value > 0.0 else 1.0


func _pre_exposure(ctx: FRPPassContext, view: int) -> float:
	var value := ctx.get_pre_exposure(view)
	return value if is_finite(value) and value > 0.0 else 1.0


func _texture_or(rd: RenderingDevice, texture: RID, fallback: RID) -> RID:
	return texture if _valid_texture(rd, texture) else fallback


func _valid_texture(rd: RenderingDevice, rid: RID) -> bool:
	return rid.is_valid() and rd != null and rd.texture_is_valid(rid)


func _rid_id(rid: RID) -> int:
	return rid.get_id() if rid.is_valid() else 0


func _ensure_pipeline(rd: RenderingDevice, filename: String, defines: Dictionary = {},
		material_kernel_source: String = "", material_kernel_hash: String = "") -> Dictionary:
	var define_keys := defines.keys()
	define_keys.sort()
	var key_parts := PackedStringArray([filename])
	for define_key in define_keys:
		key_parts.append("%s=%s" % [str(define_key), str(defines[define_key])])
	if not material_kernel_source.is_empty():
		key_parts.append("kernel=" + (material_kernel_hash if not material_kernel_hash.is_empty()
				else material_kernel_source.sha256_text()))
	var key := "|".join(key_parts)
	if _pipelines.has(key):
		return _pipelines[key]
	var source_path := SHADER_ROOT.path_join(filename)
	var source_text := _expand_shader(source_path, 0)
	if source_text == "":
		_report("Cannot load cloud shader source %s." % source_path)
		return {}
	if not material_kernel_source.is_empty():
		if filename not in ["cloud_trace.glslinc", "cloud_shadow.glslinc", "cloud_ao.glslinc"]:
			_report("A custom material kernel was requested for unsupported entry %s." % filename)
			return {}
		var material_marker := "#ifndef FENG_CLOUD_MATERIAL_KERNEL"
		if not source_text.contains(material_marker):
			_report("Cloud material kernel marker was not found while compiling %s." % filename)
			return {}
		var injected := "#define FENG_CLOUD_MATERIAL_KERNEL feng_cloud_custom_material_sample\n" + material_kernel_source + "\n"
		source_text = source_text.replace(material_marker, injected + material_marker)
	source_text = _assemble_shader_source(source_text, defines)
	if source_text.is_empty():
		_report("Cloud shader is missing #version 450: %s" % filename)
		return {}
	var shader_source := RDShaderSource.new()
	shader_source.source_compute = source_text
	var spirv: RDShaderSPIRV = rd.shader_compile_spirv_from_source(shader_source)
	if spirv == null or spirv.compile_error_compute != "":
		_report("Cloud shader compile failed (%s): %s" % [filename, spirv.compile_error_compute if spirv != null else "no SPIR-V result"])
		return {}
	var shader := rd.shader_create_from_spirv(spirv)
	if not shader.is_valid():
		_report("Cannot create cloud shader RID for %s." % filename)
		return {}
	var pipeline := rd.compute_pipeline_create(shader)
	if not pipeline.is_valid():
		rd.free_rid(shader)
		_report("Cannot create cloud compute pipeline for %s." % filename)
		return {}
	var entry := {"shader": shader, "pipeline": pipeline}
	_pipelines[key] = entry
	return entry


func _assemble_shader_source(source_text: String, defines: Dictionary) -> String:
	var assembled := source_text.replace("#[compute]", "")
	if assembled.find("#version 450") < 0:
		return ""
	var define_keys := defines.keys()
	define_keys.sort()
	var macro_lines := PackedStringArray()
	for define_key in define_keys:
		macro_lines.append("#define %s %s" % [str(define_key), str(defines[define_key])])
	if macro_lines.is_empty():
		return assembled
	var version_end := assembled.find("#version 450") + String("#version 450").length()
	return assembled.substr(0, version_end) + "\n" + "\n".join(macro_lines) + assembled.substr(version_end)


func _expand_shader(path: String, depth: int) -> String:
	if depth > 32 or not FileAccess.file_exists(path):
		return ""
	var text := FileAccess.get_file_as_string(path)
	var output := PackedStringArray()
	for line in text.split("\n"):
		var trimmed := line.strip_edges()
		if trimmed.begins_with("#include"):
			var first := trimmed.find("\"")
			var last := trimmed.rfind("\"")
			if first < 0 or last <= first:
				return ""
			var include_name := trimmed.substr(first + 1, last - first - 1)
			var included := _expand_shader(path.get_base_dir().path_join(include_name), depth + 1)
			if included == "":
				return ""
			output.append(included)
		else:
			output.append(line)
	return "\n".join(output)


func _uniform_set(shader: RID, index: int, uniforms: Array[RDUniform]) -> RID:
	if uniforms.is_empty():
		return RID()
	return UniformSetCacheRD.get_cache(shader, index, uniforms)


func _add_uniform_buffer(uniforms: Array[RDUniform], binding: int, buffer: RID) -> void:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	uniform.binding = binding
	uniform.add_id(buffer)
	uniforms.append(uniform)


func _add_sampled(uniforms: Array[RDUniform], binding: int, sampler: RID, texture: RID) -> void:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform.binding = binding
	uniform.add_id(sampler)
	uniform.add_id(texture)
	uniforms.append(uniform)


func _add_image(uniforms: Array[RDUniform], binding: int, texture: RID) -> void:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = binding
	uniform.add_id(texture)
	uniforms.append(uniform)


func _image_uniforms(binding: int, texture: RID) -> Array[RDUniform]:
	var result: Array[RDUniform] = []
	_add_image(result, binding, texture)
	return result


func _image_uniforms3(items: Array) -> Array[RDUniform]:
	var result: Array[RDUniform] = []
	for item in items:
		_add_image(result, int(item[0]), item[1])
	return result


func _dispatch(rd: RenderingDevice, pipeline: RID, uniform_sets: Array,
		size: Vector2i, z_groups: int = 1, push: PackedByteArray = PackedByteArray()) -> bool:
	if not pipeline.is_valid() or size.x <= 0 or size.y <= 0:
		return false
	var list := rd.compute_list_begin()
	if list < 0:
		return false
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	for set_index in uniform_sets.size():
		var uniform_set: RID = uniform_sets[set_index]
		if not uniform_set.is_valid():
			rd.compute_list_end()
			_report("Cloud dispatch has an invalid descriptor set at set %d." % set_index)
			return false
		rd.compute_list_bind_uniform_set(list, uniform_set, set_index)
	if not push.is_empty():
		rd.compute_list_set_push_constant(list, push, push.size())
	rd.compute_list_dispatch(list, ceili(float(size.x) / WORKGROUP), ceili(float(size.y) / WORKGROUP), maxi(z_groups, 1))
	rd.compute_list_end()
	return true


func _free_state_buffers(state: Dictionary, rd: RenderingDevice) -> void:
	if rd == null:
		return
	for buffer in state.get("ubos", {}).values():
		if buffer is RID and buffer.is_valid():
			rd.free_rid(buffer)


func _release_named_state(buffers: RenderSceneBuffersRD, rd: RenderingDevice, state: Dictionary) -> void:
	if buffers != null:
		for scope in state.get("owned_scopes", [state.get("scope", BUFFER_SCOPE)]):
			buffers.clear_context(scope)
	_free_state_buffers(state, rd)


func _release_buffer(buffers: RenderSceneBuffersRD, rd: RenderingDevice) -> void:
	if buffers == null:
		return
	var key := buffers.get_instance_id()
	if not _buffers.has(key):
		return
	var state: Dictionary = _buffers[key]
	_release_named_state(buffers, rd, state)
	_buffers.erase(key)


func _prune_buffers(current_key: int, rd: RenderingDevice) -> void:
	if _buffers.size() <= MAX_BUFFER_STATES:
		return
	for key in _buffers.keys():
		if key == current_key:
			continue
		var state: Dictionary = _buffers[key]
		var reference: Variant = state.get("weak")
		if reference is WeakRef and reference.get_ref() == null:
			_free_state_buffers(state, rd)
			_buffers.erase(key)
			if _buffers.size() <= MAX_BUFFER_STATES:
				break


func _vector3(value: Variant, fallback: Vector3) -> Vector3:
	return value if value is Vector3 and value.is_finite() else fallback


func _vector3_from_packet(values: PackedFloat32Array, offset: int, fallback: Vector3) -> Vector3:
	if offset < 0 or offset + 2 >= values.size():
		return fallback
	var result := Vector3(values[offset], values[offset + 1], values[offset + 2])
	return result if result.is_finite() else fallback


func _finite(value: float, fallback: float) -> float:
	return value if is_finite(value) else fallback


func _append_projection(values: PackedFloat32Array, projection: Projection) -> void:
	for column in 4:
		var axis: Vector4 = projection[column]
		_append4(values, axis.x, axis.y, axis.z, axis.w)


func _append4(values: PackedFloat32Array, x: float, y: float, z: float, w: float) -> void:
	values.append_array(PackedFloat32Array([x, y, z, w]))


func _report(message: String) -> void:
	if message != _last_error:
		push_error("FengCloudGPU: " + message)
		_last_error = message
