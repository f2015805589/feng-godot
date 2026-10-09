extends SceneTree
## CPU-only contract checks for the 3D volume light-injection shader and its
## native packet scaling. Runtime shader dispatch is covered by the GPU gate.

const SHADER_PATH := "res://addons/feng-fog/rendering/shaders/volumetric_fog_light.glslinc"
const SERVICE_PATH := "res://addons/feng-fog/rendering/feng_volumetric_fog_gpu_service.gd"
const RENDERER_ENTRY_PATH := "res://addons/feng-fog/rendering/feng_fog_renderer_entry.gd"
const HEIGHT_FOG_PASS_PATH := "res://addons/feng-render-pipeline/passes/height_fog_pass.gd"
const VolumetricFogGPUServiceScript = preload("res://addons/feng-fog/rendering/feng_volumetric_fog_gpu_service.gd")
const VolumetricLightmapProviderScript = preload("res://addons/feng-fog/rendering/baked_lighting/volumetric_lightmap/fog_volumetric_lightmap_provider.gd")

var _checks := 0
var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _require(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("REGRESSION: " + message)


func _run() -> void:
	var shader := FileAccess.get_file_as_string(SHADER_PATH)
	var service := FileAccess.get_file_as_string(SERVICE_PATH)
	var service_instance: RefCounted = VolumetricFogGPUServiceScript.new()
	_test_packet_scaling(shader, service)
	_test_light_selection_and_rect_path(shader, service)
	_test_phase_convention(shader)
	_test_baked_source_selection(service_instance)
	_test_baked_resource_lifetimes(service_instance)
	_test_disabled_volume_lifecycle(service)
	if _failures == 0:
		print("PASS volumetric light shader contract (%d checks)" % _checks)
	else:
		push_error("volumetric light shader contract failed: %d/%d" % [_failures, _checks])
	quit(1 if _failures > 0 else 0)


func _test_baked_source_selection(service_instance: RefCounted) -> void:
	var service_source := FileAccess.get_file_as_string(SERVICE_PATH)
	var provider_source := FileAccess.get_file_as_string(
		"res://addons/feng-fog/rendering/baked_lighting/volumetric_lightmap/fog_volumetric_lightmap_provider.gd")
	var tetra_mode: int = int(service_instance.call("_baked_mode_for_snapshot", {
		"valid": true, "source_mode": "lightmap_gi_probe_tetra",
	}))
	var vlm_mode: int = int(service_instance.call("_baked_mode_for_snapshot", {
		"valid": true, "source_mode": "ue_volumetric_lightmap_bricks",
	}))
	var invalid_mode: int = int(service_instance.call("_baked_mode_for_snapshot", {
		"valid": false, "source_mode": "ue_volumetric_lightmap_bricks",
	}))
	_require(tetra_mode == 1 and vlm_mode == 2 and invalid_mode == 0,
		"the existing baked-resource slot selects exactly one validated GI representation")
	var spaced_key := "  static-sun-A  "
	var preserved_key: String = service_instance.call("_exact_static_lighting_key", {
		"static_lighting_key": spaced_key,
	})
	_require(preserved_key == spaced_key
			and VolumetricLightmapProviderScript.static_light_key_matches(spaced_key, spaced_key)
			and not VolumetricLightmapProviderScript.static_light_key_matches(spaced_key,
				spaced_key.strip_edges()),
		"static lighting keys remain exact opaque identifiers, including authored whitespace")
	_require(provider_source.contains("\"payload_valid\": not bool(p_entry.get(\"neutral\", false))")
			and provider_source.contains("inputs[\"payload_valid\"] = false")
			and service_source.contains("vlm_inputs.get(\"payload_valid\", false)"),
		"active VLM snapshots and neutral Set 5 resources are distinguished by their provider contract")


func _test_baked_resource_lifetimes(service_instance: RefCounted) -> void:
	var states: Dictionary = {
		"viewport_a": {"baked_source_mode": 2, "baked_resource_id": -101},
		"viewport_b": {"baked_source_mode": 2, "baked_resource_id": -102},
	}
	var vlm_tracked: Dictionary = {-101: true, -102: true, -103: true}
	var unused: Array = service_instance.call("_unreferenced_baked_resource_ids",
		states, vlm_tracked, 2)
	_require(unused.size() == 1 and int(unused[0]) == -103,
		"alternating viewports retain each VLM resource still referenced by a live state")
	states["viewport_a"]["baked_resource_id"] = -103
	unused = service_instance.call("_unreferenced_baked_resource_ids", states, vlm_tracked, 2)
	_require(unused.size() == 1 and int(unused[0]) == -101,
		"switching one viewport releases only its old resource when no other state uses it")
	states.erase("viewport_b") # Mirrors weak-buffer pruning after a viewport is destroyed.
	states["viewport_a"]["baked_source_mode"] = 0 # Mirrors disabling baked lighting.
	states["viewport_a"]["baked_resource_id"] = 0
	unused = service_instance.call("_unreferenced_baked_resource_ids", states, vlm_tracked, 2)
	_require(unused.size() == 3,
		"weak-state pruning and baked-source disable release every unreferenced VLM entry")
	var tetra_states: Dictionary = {
		"viewport_c": {"baked_source_mode": 1, "baked_resource_id": -201},
	}
	var tetra_tracked: Dictionary = {-201: true, -202: true}
	var unused_tetra: Array = service_instance.call("_unreferenced_baked_resource_ids",
		tetra_states, tetra_tracked, 1)
	_require(unused_tetra.size() == 1 and int(unused_tetra[0]) == -202,
		"LightmapGI probe cache lifetime is tracked independently from VLM IDs")
	var service_source := FileAccess.get_file_as_string(SERVICE_PATH)
	var ensure_state_start: int = service_source.find("func _ensure_state(")
	var release_old_state: int = service_source.find("_free_state(state, rd)", ensure_state_start)
	var erase_old_state: int = service_source.find("_states.erase(key)", release_old_state)
	var allocate_replacement: int = service_source.find("var texture := _create_3d_texture", erase_old_state)
	_require(service_source.contains("A failed replacement allocation must not leave freed RIDs")
			and ensure_state_start >= 0 and release_old_state > ensure_state_start
			and erase_old_state > release_old_state and allocate_replacement > erase_old_state,
		"a failed froxel-state resize cannot retain a map entry pointing at freed RIDs")


func _test_disabled_volume_lifecycle(service_source: String) -> void:
	var pass_source := FileAccess.get_file_as_string(HEIGHT_FOG_PASS_PATH)
	var entry_source := FileAccess.get_file_as_string(RENDERER_ENTRY_PATH)
	_require(pass_source.contains("if not _volume_requested(snapshot) and _fog_renderer != null and buffers != null:")
			and pass_source.contains("_fog_renderer.call(\"clear_volume\", ctx, buffers, volume_clear_rd)")
			and pass_source.contains("if not volume_service_cleared and ctx != null and ctx.has_method(\"clear_volume_output\")"),
			"disabling volumetric fog clears the existing per-buffer service state and keeps native-output fallback")
	_require(entry_source.contains("func clear_volume(ctx: FRPPassContext, buffers: RenderSceneBuffersRD,")
			and entry_source.contains("_volume.clear(ctx, buffers, rd)"),
			"the optional renderer entry exposes a narrow volume-only lifecycle adapter")
	var clear_start := service_source.find("func clear(ctx: FRPPassContext, buffers: RenderSceneBuffersRD, rd: RenderingDevice) -> void:")
	var clear_state_call := service_source.find("_release_state_for(buffers, rd)", clear_start)
	var release_state_start := service_source.find("func _release_state_for(buffers: RenderSceneBuffersRD, rd: RenderingDevice) -> void:")
	var release_state_end := service_source.find("func _prune_states(", release_state_start)
	var release_state_body := service_source.substr(release_state_start, release_state_end - release_state_start) \
			if release_state_start >= 0 and release_state_end > release_state_start else ""
	_require(clear_start >= 0 and clear_state_call > clear_start
			and release_state_body.contains("_states.erase(key)")
			and release_state_body.contains("_release_unreferenced_baked_resources()"),
			"per-target disable releases only its volume state and unreferenced baked-resource cache entries")
	_require(pass_source.contains("elif _fsss_requested(snapshot):")
			and pass_source.contains("if _fsss_requested(fsss_snapshot) and _fog_renderer != null:"),
			"volume cleanup remains separate from independently requested 2D scattering")


func _test_packet_scaling(shader: String, service: String) -> void:
	_require(service.contains("var baked_scale := scene_norm / baked_exposure if baked_valid else 0.0"),
			"baked capture exposure and scene normalization are applied before common P0")
	_require(not service.contains("scene_norm * storage_exposure / baked_exposure"),
			"baked irradiance is not pre-exposed twice")
	_require(service.contains("const LIGHT_BYTES := 224")
			and service.contains("const MAX_DIRECTIONAL_LIGHTS := 8"),
			"light UBO matches 14 vec4s and native directional buffer capacity")
	_require(service.contains("history_miss_supersample_count")
			and service.contains("ray_traced_shadows_enabled")
			and shader.contains("vec4 quality_control"),
			"UE history sample quality and opt-in ray-tracing request have an explicit light UBO lane")
	_require(service.contains("directional_light_buffer_capacity"),
			"directional binding is validated against fixed native capacity")
	_require(service.contains("var scene_norm := _positive(frame.get(\"scene_normalization\", 1.0), 1.0)"),
			"the frame scene-normalization source is explicit")
	_require(shader.contains("scene_normalization = max(fog_lights.sky_extra.x"),
			"direct lights and live sky use scene normalization in UBO lane x")
	_require(shader.contains("* max(fog_lights.sky_extra.z, 0.0) * static_scattering"),
			"baked probes use their baked-exposure-corrected UBO lane z")
	_require(shader.contains("* storage_pre_exposure"),
			"direct, sky, and baked radiance receive common atlas P0 once")
	_require(shader.contains("max(emissive, vec3(0.0)) * scene_normalization")
			and shader.contains("* max(fog_frame.distance_exposure.w, 1.0e-8)"),
			"emissive uses scene normalization and common atlas P0 exactly once")
	_require(shader.contains("sky_control.z"),
			"live sky capture exposure is normalized in scene space")
	_require(shader.contains("const float SH_AMBIENT_FUNCTION = 0.28209479177387814")
			and shader.contains("fog_color_override_sky.rgb * SH_AMBIENT_FUNCTION")
			and not shader.contains("sky_luminance"),
			"UE fog-color override uses its constant SH L0 branch without sky luminance")
	_require(service.contains("const UE_DEFAULT_LIGHT_SOFT_FADING := 0.0"),
			"UE global light-soft-fading default stays disabled")
	_require(shader.contains("shadow_atlas") and shader.contains("directional_shadow_atlas"),
			"local and directional shadow atlas paths are bound")
	var vlm_include := FileAccess.get_file_as_string(
		"res://addons/feng-fog/rendering/baked_lighting/volumetric_lightmap/fog_volumetric_lightmap_sampling.glslinc")
	_require(service.contains("_volumetric_lightmap_provider.get_neutral_gpu_inputs(rd)")
			and service.contains("VolumetricLightmapProviderScript.make_set5_uniforms(vlm_inputs)")
			and service.contains("_baked_uniforms(baked_inputs), 2")
			and service.contains("5: vlm_set"),
			"both baked descriptor sets are always bound with provider-owned neutral resources")
	_require(service.contains("_baked_mode_for_snapshot")
			and service.contains("BAKED_MODE_LIGHTMAP_GI_PROBES")
			and service.contains("BAKED_MODE_UE_VOLUMETRIC_LIGHTMAP")
			and service.contains("static_directional_light_key")
			and shader.contains("vec4 baked_control"),
			"the existing baked resource slot selects exactly one validated source mode and carries key-match state")
	_require(shader.contains("ffog_sample_volumetric_lightmap(world_position, world_view_ray, g)")
			and shader.contains("ffog_vlm_contains_static_direct_directional_lighting(vlm_sample)")
			and shader.contains("ffog_vlm_includes_environment_radiance(vlm_sample)")
			and shader.contains("vlm_sample.directional_shadow"),
			"VLM uses UE camera-ray SH2, matched static-Sun suppression, shadow-only, and environment paths")
	_require(vlm_include.contains("layout(set = 5, binding = 0, std140)")
			and vlm_include.contains("layout(set = 5, binding = 10)")
			and vlm_include.contains("FFOG_VLM_FLAG_STATIC_LIGHT_KEY_MATCH"),
			"the VLM sampling include exposes the versioned Set 5 ABI and matched source flags")


func _test_light_selection_and_rect_path(shader: String, service: String) -> void:
	_require(shader.contains("float selected_index = fog_lights.cluster_words.w"),
			"volume injection selects one directional source rather than summing all directionals")
	_require(not shader.contains("for (uint directional_index"),
			"directional lights are not all injected as duplicate sun sources")
	_require(shader.contains("ffog_rect_integrate(")
			and shader.contains("ffog_rect_radius_mask(")
			and shader.contains("ffog_rect_front_and_soft_fade("),
			"rect area lighting uses its angular integral, radius mask, and front fade")
	var visible_rect_call := shader.find("FFogRectVisibleRect visible_rect = ffog_rect_visible_rect(")
	var visible_integral_call := shader.find("ffog_rect_integrate(visible_rect.to_light")
	var original_phase_call := shader.find("vec3 center_light_direction = normalize(to_light)")
	var source_texture_call := shader.find("ffog_rect_source_texture_uv(center_light_direction")
	var radius_mask_call := shader.find("ffog_rect_radius_mask(receiver_distance_squared")
	var source_texture_arguments := shader.substr(source_texture_call, 400) \
			if source_texture_call >= 0 else ""
	_require(visible_rect_call >= 0 and visible_integral_call > visible_rect_call
			and shader.contains("barn_cos_angle, barn_length_m, barn_enabled)"),
			"the matching area extension clips the visible source rect before spherical integration")
	_require(original_phase_call >= 0 and source_texture_call > original_phase_call
			and source_texture_arguments.contains("to_light, light.area_width, light.area_height, light.direction")
			and radius_mask_call > visible_integral_call,
			"rect phase, source-texture projection, and range mask retain the original center and full spans")
	_require(shader.contains("if (area_extension.barn_door.z > 0.5 && fog_lights.sky_extra.w > 0.0)"),
			"the additional volumetric barn-door soft fade remains gated by the global soft-fade control")
	_require(shader.contains("ffog_rect_sample_source_texture(area_profile_atlas"),
			"area source textures sample the native packed atlas")
	_require(not shader.contains("light_color = fog_lights.fog_color_override"),
			"artist fog-color override does not replace local-light colors")
	_require(shader.contains("light_volumetric_energy")
			and shader.contains("max(light.volumetric_fog_energy, 0.0)"),
			"native VolumetricFogScatteringIntensity is multiplied separately once")
	_require(service.contains("var selected_index := _selected_directional_index(frame, selected_sun, directional_count)"),
			"the selected component sun is matched through native directional base RIDs")
	_require(service.contains("func _selected_sun_static_lighting_key")
			and service.contains("native_rids[selected_index] != selected_sun")
			and service.contains("return _exact_static_lighting_key(row_value)")
			and service.contains("static func _exact_static_lighting_key"),
			"VLM static-light keys are taken only from the same-frame selected directional RID row")


func _test_phase_convention(shader: String) -> void:
	var view_ray := Vector3(0.0, 0.0, -1.0) # GetCameraVector: camera to froxel.
	for g_value in [-0.5, 0.5]:
		var g: float = float(g_value)
		for light_value in [view_ray, -view_ray]:
			var light_direction: Vector3 = light_value
			var ue_cosine: float = light_direction.dot(-view_ray)
			var addon_cosine: float = light_direction.dot(view_ray)
			var ue_phase := _ue_phase(g, ue_cosine)
			var addon_phase := _addon_phase(g, addon_cosine)
			_require(absf(ue_phase - addon_phase) < 1.0e-7,
					"plus/minus HG equations agree for g=%s, L=%s" % [g, light_direction])
	var forward_phase := _addon_phase(0.5, view_ray.dot(view_ray))
	var backward_phase := _addon_phase(0.5, (-view_ray).dot(view_ray))
	var negative_forward := _addon_phase(-0.5, view_ray.dot(view_ray))
	var negative_backward := _addon_phase(-0.5, (-view_ray).dot(view_ray))
	_require(forward_phase > backward_phase and negative_forward < negative_backward,
			"positive and negative HG anisotropy peak in opposite source directions")
	_require(shader.contains("dot(normalize(light.direction), view_ray)"),
			"selected directional phase uses camera-to-froxel cosine for the minus HG form")
	_require(shader.contains("dot(normalize(to_light), view_ray)"),
			"omni, spot, and rect phase use sample-to-light against camera-to-froxel")
	_require(shader.contains("ffog_sample_baked_probe_volume_ue_two_band(")
			and shader.contains("world_position, world_camera_vector_to_camera, g"),
			"UE's default baked VLM path uses L0/L1 with the documented toward-camera argument")


func _ue_phase(g: float, cosine: float) -> float:
	var denominator := maxf(1.0 + g * g + 2.0 * g * clampf(cosine, -1.0, 1.0), 1.0e-6)
	return (1.0 - g * g) / (4.0 * PI * denominator * sqrt(denominator))


func _addon_phase(g: float, cosine: float) -> float:
	var denominator := maxf(1.0 + g * g - 2.0 * g * clampf(cosine, -1.0, 1.0), 1.0e-6)
	return (1.0 - g * g) / (4.0 * PI * denominator * sqrt(denominator))
