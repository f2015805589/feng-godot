@tool
class_name FengVolumetricCloudPass
extends FengRuntimeSnapshotPass
## Publishes one immutable cloud snapshot to native FRP stages.
##
## The pass itself does no work for an empty world. The addon cloud trace and
## shadow passes, and the renderer's bounded cloud consumers, read this packet
## when the corresponding resources are available.

const RUNTIME_SCRIPT_PATH := "res://addons/feng-cloud/feng_cloud_runtime.gd"
const MATERIAL_FLOAT_COUNT := 76
const SHADER_CONFIGURATION_PROPERTIES := [
	"shader_file", "mode", "parameters", "workgroup_size", "shader_keywords",
	"raster_target", "dispatch_target", "target_name", "inputs", "outputs",
]


func requires_shader_file() -> bool:
	return false


func _validate_property(property: Dictionary) -> void:
	if str(property.get("name", "")) in SHADER_CONFIGURATION_PROPERTIES:
		# Cloud passes compile and bind their own compute pipelines. Preserve the
		# inherited storage fields for old resources, but do not expose a second,
		# inactive shader/binding configuration surface.
		property["usage"] = PROPERTY_USAGE_STORAGE


func runtime_script_path() -> String:
	return RUNTIME_SCRIPT_PATH


func _render(_buffers: RenderSceneBuffersRD, _view: int, _rd: RenderingDevice) -> void:
	# This resource is a metadata stage; the shadow and trace subclasses own
	# their GPU work. A no-op prevents the ShaderPass fallback from reporting a
	# missing RDShaderFile for this intentionally non-shader base pass.
	return


func _frp_prepare(ctx: FRPPassContext) -> void:
	var snapshot := _frame_snapshot.duplicate(true)
	if snapshot.is_empty() and ctx != null:
		var buffers := ctx.get_render_scene_buffers() as RenderSceneBuffersRD
		snapshot = _snapshot_for_target(buffers)
	_publish_snapshot(ctx, snapshot)


## Capture-only probes have no viewport target, so the caller supplies the
## immutable cloud snapshot frozen when the six-face batch was submitted.
func _frp_prepare_with_snapshot(ctx: FRPPassContext, frozen_snapshot: Dictionary) -> void:
	var previous_snapshot := _frame_snapshot
	_frame_snapshot = frozen_snapshot.duplicate(true)
	_frp_prepare(ctx)
	_frame_snapshot = previous_snapshot


func _publish_snapshot(ctx: FRPPassContext, source_snapshot: Dictionary) -> void:
	if ctx == null or not ctx.has_method("set_cloud_snapshot"):
		return
	var snapshot := source_snapshot.duplicate(true)
	if snapshot.is_empty():
		ctx.call("clear_cloud_snapshot")
		return
	var cloud_material: Dictionary = snapshot.get("material", {})
	if cloud_material.is_empty():
		ctx.call("clear_cloud_snapshot")
		return
	var textures: Array[RID] = [
		_texture_rid(cloud_material.get("shape_density_texture")),
		_texture_rid(cloud_material.get("detail_density_texture")),
		_texture_rid(cloud_material.get("weather_texture")),
		_texture_rid(cloud_material.get("curl_noise_texture")),
	]
	var layout_textures: Array[RID] = [
		_texture_rid(cloud_material.get("layout_pattern_texture")),
		_texture_rid(cloud_material.get("layout_cloud_mask_texture")),
		_texture_rid(cloud_material.get("layout_height_profile_texture")),
	]
	var kernel_layout := str(cloud_material.get("kernel_layout", "builtin"))
	if kernel_layout != "builtin" and kernel_layout != "ue58_default":
		ctx.call("clear_cloud_snapshot")
		_report("Unknown cloud kernel layout '%s'." % kernel_layout)
		return
	if kernel_layout == "ue58_default":
		if not ctx.has_method("set_cloud_layout_textures"):
			ctx.call("clear_cloud_snapshot")
			_report("The native FRP context does not expose the UE 5.8 layout texture API.")
			return
		for layout_texture in layout_textures:
			if not layout_texture.is_valid():
				ctx.call("clear_cloud_snapshot")
				_report("UE 5.8 cloud layout requires valid Pattern, Mask, and Height Profile textures.")
				return
	var parameters := _pack_material_snapshot(snapshot, cloud_material, textures)
	if parameters.size() != MATERIAL_FLOAT_COUNT:
		ctx.call("clear_cloud_snapshot")
		_report("Cloud material snapshot did not match the native 19-vec4 contract.")
		return
	var sun_inputs: Variant = snapshot.get("sun_inputs", [])
	var primary_sun := _sun_rid(sun_inputs, 0)
	var secondary_sun := _sun_rid(sun_inputs, 1)
	# Native reflection captures use this value together with probe RID and batch
	# revision to keep raw cloud lighting immutable across all six faces.
	var source_signature := int(hash(snapshot))
	ctx.call("set_cloud_snapshot", parameters,
		textures[0], textures[1], textures[2], textures[3],
		primary_sun, secondary_sun, source_signature)
	if kernel_layout == "ue58_default":
		ctx.call("set_cloud_layout_textures", layout_textures[0], layout_textures[1], layout_textures[2])
	ctx.call("set_cloud_sun_ground_transmittance", 0, _sun_ground_transmittance(sun_inputs, 0))
	ctx.call("set_cloud_sun_ground_transmittance", 1, _sun_ground_transmittance(sun_inputs, 1))
	ctx.call("set_cloud_sun_cast_shadows_on_clouds", 0, _sun_cast_shadows_on_clouds(sun_inputs, 0))
	ctx.call("set_cloud_sun_cast_shadows_on_clouds", 1, _sun_cast_shadows_on_clouds(sun_inputs, 1))


func _pack_material_snapshot(snapshot: Dictionary, material: Dictionary, textures: Array[RID]) -> PackedFloat32Array:
	var values := PackedFloat32Array()
	var center := _vector3(snapshot.get("planet_center_m", Vector3.ZERO), Vector3.ZERO)
	var ground_albedo := _vector3(snapshot.get("ground_albedo_linear", Vector3(0.4, 0.4, 0.4)), Vector3(0.4, 0.4, 0.4))
	var shape_uv := _vector3(material.get("shape_uv_scale", Vector3.ONE), Vector3.ONE)
	var detail_uv := _vector3(material.get("detail_uv_scale", Vector3.ONE), Vector3.ONE)
	var weather_uv := _vector2(material.get("weather_uv_scale", Vector2.ONE), Vector2.ONE)
	var curl_uv := _vector3(material.get("curl_uv_scale", Vector3.ONE), Vector3.ONE)
	var extinction := _vector3(material.get("extinction_per_km", Vector3.ONE), Vector3.ONE)
	var albedo := _vector3(material.get("albedo_linear", Vector3.ONE), Vector3.ONE)
	var emission := _vector3(material.get("emission_per_km", Vector3.ZERO), Vector3.ZERO)
	var wind := _vector3(material.get("wind_offset_km", Vector3.ZERO), Vector3.ZERO)
	var has_shape_texture := textures.size() > 0 and textures[0].is_valid()
	var has_detail_texture := textures.size() > 1 and textures[1].is_valid()
	var has_weather_texture := textures.size() > 2 and textures[2].is_valid()
	var has_curl_texture := textures.size() > 3 and textures[3].is_valid()
	var detail_enabled := bool(material.get("detail_enabled", true))
	_append4(values, center.x, center.y, center.z, float(snapshot.get("planet_radius_m", 6360000.0)))
	_append4(values, float(snapshot.get("layer_bottom_m", 5000.0)), float(snapshot.get("layer_height_m", 10000.0)),
		float(snapshot.get("tracing_start_max_distance_m", 350000.0)), float(snapshot.get("tracing_start_distance_from_camera_m", 0.0)))
	_append4(values, float(snapshot.get("tracing_max_distance_m", 50000.0)), float(snapshot.get("tracing_max_distance_mode", 0)),
		float(snapshot.get("shadow_tracing_distance_m", 15000.0)), float(snapshot.get("stop_tracing_transmittance_threshold", 0.005)))
	_append4(values, shape_uv.x, shape_uv.y, shape_uv.z, float(material.get("density_scale", 1.0)))
	_append4(values, detail_uv.x, detail_uv.y, detail_uv.z, float(material.get("detail_strength", 1.0)))
	_append4(values, weather_uv.x, weather_uv.y, float(material.get("weather_strength", 1.0)), float(material.get("coverage", 0.5)))
	_append4(values, wind.x, wind.y, wind.z, float(material.get("conservative_density", 1.0)))
	_append4(values, extinction.x, extinction.y, extinction.z, float(material.get("ambient_occlusion_strength", 1.0)))
	_append4(values, albedo.x, albedo.y, albedo.z, float(bool(material.get("ambient_occlusion_override", false))))
	_append4(values, emission.x, emission.y, emission.z, float(detail_enabled))
	_append4(values, float(material.get("phase_g", 0.0)), float(material.get("phase_g2", 0.0)),
		float(material.get("phase_blend", 0.0)), float(bool(material.get("per_sample_phase", false))))
	_append4(values, float(material.get("multi_scattering_octaves", 0)), float(material.get("multi_scattering_contribution", 0.5)),
		float(material.get("multi_scattering_occlusion", 0.5)), float(material.get("multi_scattering_eccentricity", 0.5)))
	_append4(values, float(bool(material.get("ground_contribution", false))), float(bool(material.get("grayscale", false))),
		float(bool(material.get("raymarch_volume_shadow", true))), float(bool(material.get("clamp_multi_scattering", true))))
	var bottom_occlusion := clampf(float(snapshot.get("sky_light_cloud_bottom_occlusion", 0.5)), 0.0, 1.0)
	_append4(values, ground_albedo.x, ground_albedo.y, ground_albedo.z, 1.0 - bottom_occlusion)
	_append4(values, float(snapshot.get("view_sample_count_scale", 1.0)), float(snapshot.get("reflection_view_sample_count_scale", 1.0)),
		float(snapshot.get("shadow_view_sample_count_scale", 1.0)), float(snapshot.get("shadow_reflection_view_sample_count_scale", 1.0)))
	_append4(values, float(snapshot.get("rayleigh_aerial_perspective_start_m", 0.0)), float(snapshot.get("rayleigh_aerial_perspective_fade_m", 0.0)),
		float(snapshot.get("mie_aerial_perspective_start_m", 0.0)), float(snapshot.get("mie_aerial_perspective_fade_m", 0.0)))
	_append4(values, float(bool(snapshot.get("per_sample_atmosphere_transmittance", false))),
		float(bool(snapshot.get("render_in_main_pass", true))), float(bool(snapshot.get("visible_in_realtime_sky_captures", true))),
		float(bool(snapshot.get("holdout", false))))
	_append4(values, float(has_shape_texture), float(detail_enabled and has_detail_texture),
		float(has_weather_texture), float(has_curl_texture))
	_append4(values, curl_uv.x, curl_uv.y, curl_uv.z, float(material.get("curl_strength", 1.0)))
	return values


func _sun_rid(sun_inputs: Variant, index: int) -> RID:
	if not sun_inputs is Array or index < 0 or index >= sun_inputs.size():
		return RID()
	var item: Variant = sun_inputs[index]
	if not item is Dictionary:
		return RID()
	var rid: Variant = item.get("light_rid", RID())
	return rid if rid is RID else RID()


func _sun_ground_transmittance(sun_inputs: Variant, index: int) -> Vector3:
	if not sun_inputs is Array or index < 0 or index >= sun_inputs.size():
		return Vector3.ONE
	var item: Variant = sun_inputs[index]
	if not item is Dictionary:
		return Vector3.ONE
	var transmittance: Variant = item.get("ground_transmittance", Vector3.ONE)
	return transmittance.max(Vector3.ZERO).min(Vector3.ONE) if transmittance is Vector3 and transmittance.is_finite() else Vector3.ONE


func _sun_cast_shadows_on_clouds(sun_inputs: Variant, index: int) -> bool:
	if not sun_inputs is Array or index < 0 or index >= sun_inputs.size():
		return false
	var item: Variant = sun_inputs[index]
	return bool(item.get("cast_shadows_on_clouds", false)) if item is Dictionary else false


func _texture_rid(resource: Variant) -> RID:
	if not (resource is Texture2D or resource is Texture3D):
		return RID()
	return RenderingServer.texture_get_rd_texture(resource.get_rid())


func _append4(values: PackedFloat32Array, x: float, y: float, z: float, w: float) -> void:
	values.append_array(PackedFloat32Array([x, y, z, w]))


func _vector2(value: Variant, fallback: Vector2) -> Vector2:
	return value if value is Vector2 and value.is_finite() else fallback


func _vector3(value: Variant, fallback: Vector3) -> Vector3:
	return value if value is Vector3 and value.is_finite() else fallback
