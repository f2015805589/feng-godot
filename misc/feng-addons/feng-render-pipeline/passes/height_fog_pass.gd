@tool
class_name FengHeightFogPass
extends FengRuntimeSnapshotPass
## Applies independently published height fog and spherical aerial perspective.
## Both providers are optional, world-scoped snapshots. Metadata preparation
## supplies direct-light transport before Lighting; the existing Sky-anchored
## dispatch applies aerial perspective and height fog to opaque scene color.
## With neither provider, the pass is a no-op. Authoring/lifecycles stay outside it.

const UBO_BINDING := 2
const UBO_SIZE := 496 # Two mat4s + seven fog vec4s + sixteen atmosphere vec4s.
const AtmospherePacket = preload("atmosphere_packet.gd")
const SKY_RUNTIME_PATH := "res://addons/feng-sky/feng_sky_runtime.gd"
const RUNTIME_SCRIPT_PATH := "res://addons/feng-fog/feng_fog_runtime.gd"
var _pre_exposure := 1.0
var _sky_runtime: Script
var _next_sky_runtime_probe_msec := 0
var _atmosphere_snapshot: Dictionary = {}
var _prepared_context_id := 0
var _atmosphere_optical := RID()
var _atmosphere_multiple := RID()
var _empty_atmosphere_lut := RID()
var _atmosphere_sampler := RID()
var _capture_snapshot_active := false
var _capture_fog_snapshot: Dictionary = {}
var _capture_atmosphere_snapshot: Dictionary = {}
var _capture_exposure_normalization := 1.0

## The capture-only effect is a private duplicate of this resource. These value
## snapshots and their texture references stay frozen for the six-face capture.
func set_capture_snapshots(fog_snapshot: Dictionary, atmosphere_snapshot: Dictionary) -> void:
	_capture_fog_snapshot = fog_snapshot.duplicate(true)
	_capture_atmosphere_snapshot = atmosphere_snapshot.duplicate(true)
	_capture_snapshot_active = true

func clear_capture_snapshots() -> void:
	_capture_snapshot_active = false
	_capture_fog_snapshot = {}
	_capture_atmosphere_snapshot = {}

func _atmosphere_for_target(buffers: RenderSceneBuffersRD) -> Dictionary:
	if buffers == null:
		return {}
	if _sky_runtime == null:
		var now := Time.get_ticks_msec()
		if now < _next_sky_runtime_probe_msec:
			return {}
		_next_sky_runtime_probe_msec = now + 500
		if ResourceLoader.exists(SKY_RUNTIME_PATH):
			var script: Variant = load(SKY_RUNTIME_PATH)
			if script is Script and script.has_method("rendering_snapshots"):
				_sky_runtime = script
	if _sky_runtime == null:
		return {}
	var snapshots: Variant = _sky_runtime.call("rendering_snapshots")
	if snapshots is Array:
		for snapshot in snapshots:
			if snapshot is Dictionary and snapshot.get("render_targets", []).has(buffers.get_render_target()):
				return snapshot
	return {}

func _prepare_atmosphere(ctx: FRPPassContext) -> PackedFloat32Array:
	_atmosphere_snapshot = {}
	_atmosphere_optical = RID()
	_atmosphere_multiple = RID()
	if ctx == null:
		return PackedFloat32Array()
	_atmosphere_snapshot = _capture_atmosphere_snapshot.duplicate(true) if _capture_snapshot_active \
			else _atmosphere_for_target(ctx.get_render_scene_buffers() as RenderSceneBuffersRD)
	var render_data := ctx.get_render_data()
	var scene_data: RenderSceneData = render_data.get_render_scene_data() if render_data != null else null
	if _atmosphere_snapshot.is_empty() or scene_data == null:
		return PackedFloat32Array()
	var optical: Variant = _atmosphere_snapshot.get("optical_column_lut")
	var multiple: Variant = _atmosphere_snapshot.get("multi_scattering_lut")
	var settings: Dictionary = _atmosphere_snapshot.get("settings", {})
	var lut_safe := float(settings.get("atmosphere_height_km", 60.0)) / maxf(minf(float(settings.get("rayleigh_scale_height_km", 8.0)), float(settings.get("mie_scale_height_km", 1.2))), 0.001) <= 64.0
	if optical is Texture2D and lut_safe and bool(_atmosphere_snapshot.get("use_optical_column_lut", true)):
		_atmosphere_optical = RenderingServer.texture_get_rd_texture(optical.get_rid())
	if multiple is Texture2D:
		_atmosphere_multiple = RenderingServer.texture_get_rd_texture(multiple.get_rid())
	return AtmospherePacket.make(_atmosphere_snapshot, scene_data.get_cam_transform(), _atmosphere_optical.is_valid(), _atmosphere_multiple.is_valid())

## Metadata only: publish before deferred lighting, while the actual compute
## work retains the existing Sky-anchored pass position.
func _frp_prepare(ctx: FRPPassContext) -> void:
	_prepared_context_id = ctx.get_instance_id() if ctx != null else 0
	var packet := _prepare_atmosphere(ctx)
	if ctx != null and ctx.has_method("set_atmosphere_parameters"):
		ctx.call("set_atmosphere_parameters", packet,
			_atmosphere_snapshot.get("sun_light_rid", RID()),
			_atmosphere_snapshot.get("secondary_sun_light_rid", RID()),
			_atmosphere_optical, _atmosphere_multiple)


func _frp_execute(ctx: FRPPassContext) -> void:
	if _capture_snapshot_active:
		if ctx == null:
			return
		_prepared_context_id = ctx.get_instance_id()
		var packet := _prepare_atmosphere(ctx)
		if ctx.has_method("set_atmosphere_parameters"):
			ctx.call("set_atmosphere_parameters", packet,
				_atmosphere_snapshot.get("sun_light_rid", RID()),
				_atmosphere_snapshot.get("secondary_sun_light_rid", RID()),
				_atmosphere_optical, _atmosphere_multiple)
		_pre_exposure = ctx.get_pre_exposure(0)
		_capture_exposure_normalization = ctx.get_scene_exposure_normalization() \
				if ctx.has_method("get_scene_exposure_normalization") else 1.0
		var frame_snapshot := _capture_fog_snapshot.duplicate(true)
		var render_data := ctx.get_render_data()
		var scene_data: RenderSceneData = render_data.get_render_scene_data() if render_data != null else null
		var frame_parameters := PackedFloat32Array()
		if not frame_snapshot.is_empty() and scene_data != null:
			var resolved: Variant = get_resolved_parameters(ctx).get("parameters", parameters)
			var fog_scale := float(resolved.x) if resolved is Vector4 else 1.0
			frame_parameters = _make_forward_parameters(frame_snapshot, scene_data.get_cam_transform(),
				fog_scale, scene_data.get_view_projection(0))
		ctx.call("set_height_fog_parameters", frame_parameters)
		super._frp_execute_with_snapshot(ctx, frame_snapshot)
		_pre_exposure = 1.0
		_capture_exposure_normalization = 1.0
		return
	# Reuse one immutable frame lease from pre-lighting through opaque/forward
	# work. Keep its Texture2D references alive until the next frame preparation.
	# Older engines without the optional hook can still execute compute AP.
	if ctx == null or _prepared_context_id != ctx.get_instance_id():
		_prepare_atmosphere(ctx)
	_pre_exposure = ctx.get_pre_exposure(0) if ctx != null else 1.0
	if ctx != null:
		var buffers := ctx.get_render_scene_buffers() as RenderSceneBuffersRD
		var snapshot := _snapshot_for_target(buffers)
		var frame_parameters := PackedFloat32Array()
		if not snapshot.is_empty():
			var render_data := ctx.get_render_data()
			var scene_data: RenderSceneData = render_data.get_render_scene_data() if render_data != null else null
			if scene_data != null:
				var resolved: Variant = get_resolved_parameters(ctx).get("parameters", parameters)
				var fog_scale := float(resolved.x) if resolved is Vector4 else 1.0
				frame_parameters = _make_forward_parameters(snapshot, scene_data.get_cam_transform(),
					fog_scale, scene_data.get_view_projection(0))
		ctx.call("set_height_fog_parameters", frame_parameters)
	super._frp_execute(ctx)
	_pre_exposure = 1.0

func _make_forward_parameters(snapshot: Dictionary, camera: Transform3D, fog_scale: float,
		projection: Projection) -> PackedFloat32Array:
	var density := float(snapshot.get("fog_density", 0.0))
	var falloff := float(snapshot.get("fog_height_falloff", 0.0))
	var height := float(snapshot.get("fog_height", 0.0))
	var density2 := float(snapshot.get("second_fog_density", 0.0))
	var falloff2 := float(snapshot.get("second_fog_height_falloff", 0.0))
	var height2 := float(snapshot.get("second_fog_height", 0.0))
	var observer_y := _observer_height(camera.origin.y, density, height, density2, height2, projection)
	var global_density := density * pow(2.0, clampf(-falloff * (observer_y - height), -125.0, 126.0))
	var global_density2 := density2 * pow(2.0, clampf(-falloff2 * (observer_y - height2), -125.0, 126.0))
	var fog_color: Variant = snapshot.get("fog_color", Vector3.ZERO)
	var sun_direction: Variant = snapshot.get("sun_direction", Vector3.ZERO)
	var inscattering_color: Variant = snapshot.get("inscattering_color", Vector3.ZERO)
	var values := PackedFloat32Array([camera.origin.x, camera.origin.y, camera.origin.z, 1.0,
			global_density, falloff, observer_y, float(snapshot.get("start_distance", 0.0)),
			global_density2, falloff2, density2, height2,
			density, height, fog_scale, float(snapshot.get("cutoff_distance", 0.0))])
	if fog_color is Vector3:
		values.append_array(PackedFloat32Array([fog_color.x, fog_color.y, fog_color.z,
				float(snapshot.get("min_opacity", 0.0))]))
	else:
		values.append_array(PackedFloat32Array([0.0, 0.0, 0.0, float(snapshot.get("min_opacity", 0.0))]))
	if sun_direction is Vector3:
		values.append_array(PackedFloat32Array([sun_direction.x, sun_direction.y, sun_direction.z,
				float(snapshot.get("inscattering_start", -1.0))]))
	else:
		values.append_array(PackedFloat32Array([0.0, 0.0, 0.0, -1.0]))
	if inscattering_color is Vector3:
		values.append_array(PackedFloat32Array([inscattering_color.x, inscattering_color.y, inscattering_color.z,
				clampf(float(snapshot.get("inscattering_exponent", 4.0)), 0.000001, 1000.0)]))
	else:
		values.append_array(PackedFloat32Array([0.0, 0.0, 0.0, 4.0]))
	return values


func _observer_height(camera_y: float, density: float, height: float, density2: float,
		height2: float, projection: Projection) -> float:
	# Unreal caps the observer for perspective rays to 65536 cm above each
	# nonzero fog layer. Orthographic cameras use ViewTarget distance instead;
	# Godot exposes no equivalent target distance, so retain their actual height.
	if projection.is_orthogonal() or not is_finite(camera_y):
		return camera_y
	var cap := INF
	if density > 0.0 and is_finite(density) and is_finite(height):
		cap = minf(cap, height + 655.36)
	if density2 > 0.0 and is_finite(density2) and is_finite(height2):
		cap = minf(cap, height2 + 655.36)
	return minf(camera_y, cap) if is_finite(cap) else camera_y

func _parameter_bytes() -> PackedByteArray:
	var value: Vector4 = _frame_parameters if _frame_parameters is Vector4 else parameters
	var exposure := _pre_exposure * (_capture_exposure_normalization if _capture_snapshot_active else 1.0)
	return PackedFloat32Array([value.x, exposure, value.z, value.w]).to_byte_array()

func _init() -> void:
	inputs = _make_inputs()

func runtime_script_path() -> String:
	return RUNTIME_SCRIPT_PATH

## Resources saved before the contract changed are repaired on load (see
## FengRenderer._observe_pass): the declaration is rebuilt without touching the
## authored enabled state or parameter scale.
func ensure_frp_contract() -> bool:
	var expected_inputs := _make_inputs()
	if _inputs_match(inputs, expected_inputs):
		return false
	inputs = expected_inputs
	return true

func _make_inputs() -> Array[TextureInput]:
	var color := TextureInput.new()
	color.binding = 0
	color.source = TextureInput.Source.COLOR
	color.binding_type = TextureInput.BindingType.STORAGE_IMAGE
	var depth := TextureInput.new()
	depth.binding = 1
	depth.source = TextureInput.Source.DEPTH
	return [color, depth]

func get_volume_parameter_names() -> PackedStringArray:
	return PackedStringArray(["parameters"])

func _render(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice) -> void:
	# No fog node in this world: the pass is a true no-op — color is modified in
	# place, so there is nothing to clear and no dispatch to schedule.
	if (_frame_snapshot.is_empty() and _atmosphere_snapshot.is_empty()) or _frame_scene_data == null:
		return
	if not _update_frame_ubo(_frame_snapshot, _frame_scene_data, view, rd):
		return
	super._render(buffers, view, rd)

func _update_frame_ubo(snapshot: Dictionary, scene_data: RenderSceneData, view: int, rd: RenderingDevice) -> bool:
	if scene_data == null or view >= scene_data.get_view_count():
		return false
	# Godot's view projection is the eye's projection matrix, not a combined
	# world-to-clip matrix. The shader must apply the camera transform as well.
	var projection: Projection = scene_data.get_view_projection(view)
	var inverse_projection: Projection = projection.inverse()
	var camera: Transform3D = scene_data.get_cam_transform()
	camera.origin += camera.basis.orthonormalized() * scene_data.get_view_eye_offset(view)
	var values := PackedFloat32Array()
	_append_projection(values, inverse_projection)
	var view_to_world := Transform3D(camera.basis.orthonormalized(), camera.origin)
	_append_transform(values, view_to_world)
	# Both paths use the same seven vec4s. Compute applies strength through its
	# push constant, so its reserved packet lane remains zero.
	values.append_array(_make_forward_parameters(snapshot, camera, 0.0, projection))
	values.append_array(AtmospherePacket.make(_atmosphere_snapshot, camera, _atmosphere_optical.is_valid(), _atmosphere_multiple.is_valid()))
	return _commit_frame_ubo(values, UBO_SIZE, rd)

func _collect_bindings(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice) -> Dictionary:
	var binding_data := super._collect_bindings(buffers, view, rd)
	if _binding_error or not _ubo.is_valid():
		return binding_data
	var uniforms: Array[RDUniform] = binding_data["uniforms"]
	uniforms.append(_ubo_uniform(UBO_BINDING))
	if not _atmosphere_sampler.is_valid():
		var state := RDSamplerState.new()
		state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		_atmosphere_sampler = rd.sampler_create(state)
	if not _empty_atmosphere_lut.is_valid():
		var format := RDTextureFormat.new()
		format.width = 1
		format.height = 1
		format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
		format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		_empty_atmosphere_lut = rd.texture_create(format, RDTextureView.new(), [PackedFloat32Array([0.0, 0.0, 0.0, 0.0]).to_byte_array()])
	for slot in 2:
		var texture: RID = _atmosphere_optical if slot == 0 else _atmosphere_multiple
		if not texture.is_valid() or not rd.texture_is_valid(texture):
			texture = _empty_atmosphere_lut
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		uniform.binding = 3 + slot
		uniform.add_id(_atmosphere_sampler)
		uniform.add_id(texture)
		uniforms.append(uniform)
	binding_data["uniforms"] = uniforms
	return binding_data

func _cleanup(rd: RenderingDevice) -> void:
	if rd != null and _empty_atmosphere_lut.is_valid():
		rd.free_rid(_empty_atmosphere_lut)
	_empty_atmosphere_lut = RID()
	if rd != null and _atmosphere_sampler.is_valid():
		rd.free_rid(_atmosphere_sampler)
	_atmosphere_sampler = RID()
	super._cleanup(rd)

func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return
	# Value-capture the UBO: the instance is being torn down, so only local
	# state is safe here (see FengRuntimeSnapshotPass._free_on_render_thread).
	var ubo := _ubo
	var empty_lut := _empty_atmosphere_lut
	var atmosphere_sampler := _atmosphere_sampler
	_atmosphere_sampler = RID()
	_empty_atmosphere_lut = RID()
	_ubo = RID()
	if ubo.is_valid() or empty_lut.is_valid() or atmosphere_sampler.is_valid():
		_free_on_render_thread([ubo, empty_lut, atmosphere_sampler])
