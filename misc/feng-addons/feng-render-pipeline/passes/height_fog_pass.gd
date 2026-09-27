@tool
class_name FengHeightFogPass
extends FengRuntimeSnapshotPass
## Applies Unreal-style exponential height fog to the lit color.
##
## The pass is a no-op until a FengHeightFog node publishes a snapshot for this
## render target through the feng-fog addon's runtime. Per-frame work is a single
## camera-dependent UBO; the shader mirrors Unreal's HeightFogCommon.ush.

const UBO_BINDING := 2
const UBO_SIZE := 176 # mat4 + seven vec4.
const RUNTIME_SCRIPT_PATH := "res://addons/feng-fog/feng_fog_runtime.gd"

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
	if _frame_snapshot.is_empty() or _frame_scene_data == null:
		return
	if not _update_frame_ubo(_frame_snapshot, _frame_scene_data, view, rd):
		return
	super._render(buffers, view, rd)

func _update_frame_ubo(snapshot: Dictionary, scene_data: RenderSceneData, view: int, rd: RenderingDevice) -> bool:
	if scene_data == null or view >= scene_data.get_view_count():
		return false
	var inverse_view_projection: Projection = scene_data.get_view_projection(view).inverse()
	var camera: Transform3D = scene_data.get_cam_transform()
	var density := float(snapshot.get("fog_density", 0.0))
	var falloff := float(snapshot.get("fog_height_falloff", 0.0))
	var height := float(snapshot.get("fog_height", 0.0))
	var density2 := float(snapshot.get("second_fog_density", 0.0))
	var falloff2 := float(snapshot.get("second_fog_height_falloff", 0.0))
	var height2 := float(snapshot.get("second_fog_height", 0.0))
	# GlobalDensity = FogDensity * exp2(-FogHeightFalloff * (CameraZ - FogHeight)).
	var global_density := density * pow(2.0, -falloff * (camera.origin.y - height))
	var global_density2 := density2 * pow(2.0, -falloff2 * (camera.origin.y - height2))
	var fog_color: Variant = snapshot.get("fog_color", Vector3.ZERO)
	var sun_direction: Variant = snapshot.get("sun_direction", Vector3.ZERO)
	var inscattering_color: Variant = snapshot.get("inscattering_color", Vector3.ZERO)
	var values := PackedFloat32Array()
	for column in 4:
		var axis: Vector4 = inverse_view_projection[column]
		values.append_array(PackedFloat32Array([axis.x, axis.y, axis.z, axis.w]))
	values.append_array(PackedFloat32Array([camera.origin.x, camera.origin.y, camera.origin.z, 1.0]))
	values.append_array(PackedFloat32Array([global_density, falloff, 0.0, float(snapshot.get("start_distance", 0.0))]))
	values.append_array(PackedFloat32Array([global_density2, falloff2, density2, height2]))
	values.append_array(PackedFloat32Array([density, height, 0.0, float(snapshot.get("cutoff_distance", 0.0))]))
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
				float(snapshot.get("inscattering_exponent", 4.0))]))
	else:
		values.append_array(PackedFloat32Array([0.0, 0.0, 0.0, 4.0]))
	return _commit_frame_ubo(values, UBO_SIZE, rd)

func _collect_bindings(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice) -> Dictionary:
	var binding_data := super._collect_bindings(buffers, view, rd)
	if _binding_error or _frame_snapshot.is_empty() or not _ubo.is_valid():
		return binding_data
	var uniforms: Array[RDUniform] = binding_data["uniforms"]
	uniforms.append(_ubo_uniform(UBO_BINDING))
	binding_data["uniforms"] = uniforms
	return binding_data

func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return
	# Value-capture the UBO: the instance is being torn down, so only local
	# state is safe here (see FengRuntimeSnapshotPass._free_on_render_thread).
	var ubo := _ubo
	_ubo = RID()
	if ubo.is_valid():
		_free_on_render_thread([ubo])
