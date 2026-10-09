extends SceneTree
## CPU-only contracts for Feng's Unreal 5.8 exponential height fog path.

const FengHeightFog = preload("res://addons/feng-fog/feng_height_fog.gd")
const FengVolumetricFogVolume = preload("res://addons/feng-fog/feng_volumetric_fog_volume.gd")
const FengFogRuntime = preload("res://addons/feng-fog/feng_fog_runtime.gd")
const VolumetricLightmapResourceScript = preload("res://addons/feng-fog/rendering/baked_lighting/volumetric_lightmap/fog_volumetric_lightmap.gd")
const VolumetricFogCodec = preload("res://addons/feng-fog/rendering/feng_volumetric_fog_codec.gd")
const VolumetricFogGPUService = preload("res://addons/feng-fog/rendering/feng_volumetric_fog_gpu_service.gd")
const LocalVolumeCodec = preload("res://addons/feng-fog/rendering/feng_local_volume_codec.gd")
const FsssGPUService = preload("res://addons/feng-fog/rendering/feng_fsss_gpu_service.gd")
const FengSkyRuntime = preload("res://addons/feng-sky/feng_sky_runtime.gd")
const LUMA := Vector3(0.2126, 0.7152, 0.0722)

class SkyProvider extends RefCounted:
	var world_id: int
	var active := true

	func _feng_sky_runtime_is_active(candidate_world_id: int) -> bool:
		return active and candidate_world_id == world_id

class UnsupportedBakedResource extends Resource:
	var revision := 1

var _failures := 0
var _checks := 0


func _initialize() -> void:
	call_deferred("run")


func require(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("REGRESSION: " + message)


func require_vec(actual: Vector3, expected: Vector3, message: String) -> void:
	var tolerance := maxf(expected.length() * 0.00001, 0.000001)
	require(actual.is_finite() and actual.distance_to(expected) <= tolerance,
		"%s: actual=%s expected=%s" % [message, actual, expected])


func make_viewport() -> SubViewport:
	var viewport := SubViewport.new()
	viewport.world_3d = World3D.new()
	root.add_child(viewport)
	return viewport


func snapshot_for(fog: FengHeightFog) -> Dictionary:
	FengFogRuntime._publish()
	for snapshot in FengFogRuntime.snapshots():
		if snapshot.get("fog_id") == fog.get_instance_id():
			return snapshot
	require(false, "enabled fog has no published snapshot")
	return {}


func publish_sky(provider: SkyProvider, primary_sun_id: int, ambient: Vector3,
		ground: Vector3, contribution: float = 1.0, affect_fog: bool = true) -> void:
	FengSkyRuntime.publish_snapshot(provider, provider.world_id, {
		"ambient_radiance": ambient,
		"height_fog_contribution": contribution,
		"sun_light_id": primary_sun_id,
		"sun_ground_illuminance": ground,
		"affect_height_fog": affect_fog,
	})


func raw_light_rgb(light: DirectionalLight3D, physical: bool) -> Vector3:
	var color := light.light_color.srgb_to_linear()
	var rgb := Vector3(color.r, color.g, color.b)
	if physical:
		var temperature := light.get_correlated_color().srgb_to_linear()
		rgb *= Vector3(temperature.r, temperature.g, temperature.b)
	var energy := light.light_energy * (light.light_intensity_lux if physical else PI)
	if light.light_negative:
		energy *= -1.0
	return rgb * energy


func has_property(object: Object, wanted: StringName) -> bool:
	for property in object.get_property_list():
		if StringName(property["name"]) == wanted:
			return true
	return false


func run() -> void:
	test_baked_source_snapshot_modes()
	test_fsss_source_contract()
	test_temporal_depth_contract()
	test_conservative_depth_fixup()
	test_volume_depth_range_contract()
	test_history_miss_supersampling()
	test_quality_profiles()
	test_projection_depth_contract()
	test_eye_offset_history_continuity()
	var physical := bool(ProjectSettings.get_setting(
		"rendering/lights_and_shadows/use_physical_light_units", false))
	var viewport_a := make_viewport()
	var viewport_b := make_viewport()
	var world_a_id := viewport_a.world_3d.get_instance_id()
	var world_b_id := viewport_b.world_3d.get_instance_id()

	# Add the primary first and a decoy afterwards: tree scanning alone would
	# encounter the decoy, while the active atmosphere snapshot must win.
	var primary := DirectionalLight3D.new()
	primary.light_color = Color(0.9, 0.6, 0.4)
	primary.light_temperature = 7100.0
	primary.light_intensity_lux = 18.0
	primary.light_energy = 1.25
	primary.rotation = Vector3(0.23, 0.51, 0.0)
	viewport_a.add_child(primary)
	var decoy := DirectionalLight3D.new()
	decoy.light_color = Color(0.1, 0.3, 0.95)
	decoy.light_intensity_lux = 70000.0
	decoy.rotation = Vector3(-0.4, -0.2, 0.0)
	viewport_a.add_child(decoy)
	var foreign_sun := DirectionalLight3D.new()
	foreign_sun.light_color = Color(0.2, 1.0, 0.2)
	foreign_sun.light_intensity_lux = 90000.0
	viewport_b.add_child(foreign_sun)

	var fog := FengHeightFog.new()
	viewport_a.add_child(fog)
	var fog_b := FengHeightFog.new()
	viewport_b.add_child(fog_b)
	var later_fog := FengHeightFog.new()
	viewport_a.add_child(later_fog)
	FengFogRuntime.register(fog)
	require(snapshot_for(later_fog).get("fog_id") == later_fog.get_instance_id(), "Repeated registration changed fog precedence")
	later_fog.enabled = false
	require(snapshot_for(fog).get("fog_id") == fog.get_instance_id(), "Disabled newest fog did not restore its predecessor")
	later_fog.enabled = true
	require(snapshot_for(later_fog).get("fog_id") == later_fog.get_instance_id(), "Re-enabled newest fog lost its precedence")
	later_fog.free()
	require(snapshot_for(fog).get("fog_id") == fog.get_instance_id(), "Removing newest fog retained a stale publication")

	var provider_a := SkyProvider.new()
	provider_a.world_id = world_a_id
	var provider_b := SkyProvider.new()
	provider_b.world_id = world_b_id
	var ambient := Vector3(2.0, 4.0, 8.0)
	var ground := Vector3(12.0, 22.0, 42.0)
	var contribution := 0.25
	var authored := Vector3(1.5, -0.25, 0.5)
	var artist := Vector3(0.3, 0.5, 0.8)

	require(not has_property(fog, &"fog_color_mode")
		and not has_property(fog, &"fog_albedo")
		and not has_property(fog, &"sun_light"),
		"the fog component must expose one Unreal path without color-mode, albedo, or sun override properties")
	require(fog.fog_inscattering_color == Color.BLACK,
		"the authored Unreal Fog Inscattering Color default must be black")
	require(fog.fog_height_falloff == 0.2 and fog.second_fog_height_falloff == 0.2,
		"both Unreal fog-layer falloff defaults must remain 0.2")
	require_vec(fog.snapshot_fields().get("fog_color", Vector3.INF), Vector3.ZERO,
		"default black source must stay raw black")
	require(fog.fog_density > 0.0 and is_zero_approx(float(fog.snapshot_fields()["min_opacity"]))
		and is_equal_approx(fog.directional_inscattering_start_distance, 100.0),
		"black source must retain default extinction, opacity, and directional start settings")
	var medium_before_volume := fog.snapshot_fields()
	var volume_defaults: Dictionary = medium_before_volume["volumetric_fog"]
	var fsss_defaults: Dictionary = medium_before_volume["screen_space_scattering"]
	require(not bool(volume_defaults["enabled"])
		and is_equal_approx(float(volume_defaults["scattering_distribution"]), 0.2)
		and is_equal_approx(float(volume_defaults["extinction_scale"]), 1.0)
		and is_equal_approx(float(volume_defaults["distance"]), 60.0)
		and is_zero_approx(float(volume_defaults["start_distance"]))
		and is_zero_approx(float(volume_defaults["near_fade_in_distance"]))
		and is_equal_approx(float(volume_defaults["static_lighting_scattering_intensity"]), 1.0)
		and not bool(volume_defaults["override_light_colors_with_fog_inscattering_colors"])
		and is_equal_approx(float(volume_defaults["history_weight"]), 0.9)
		and int(volume_defaults["history_miss_supersample_count"]) == 4
		and not bool(volume_defaults["history_miss_supersample_override"])
		and int(volume_defaults["quality"]) == 0
		and int(volume_defaults["froxel_pixel_size"]) == 16
		and int(volume_defaults["froxel_depth"]) == 64
		and bool(volume_defaults["jitter_enabled"])
		and not bool(volume_defaults["ray_traced_shadows_enabled"]),
		"UE volumetric fog defaults must be published in a disabled, meter-based packet")
	require_vec(volume_defaults["albedo"], Vector3.ONE,
		"UE white FColor albedo must publish as linear white")
	require_vec(volume_defaults["emissive"], Vector3.ZERO,
		"UE linear black emissive must publish as zero")
	require(not bool(fsss_defaults["enabled"])
		and is_equal_approx(float(fsss_defaults["scene_color_scattering_amount_scale"]), 1.0)
		and is_equal_approx(float(fsss_defaults["scene_color_scattering_amount_power"]), 1.0)
		and is_equal_approx(float(fsss_defaults["spread_scale"]), 0.1)
		and is_equal_approx(float(fsss_defaults["blur_control"]), 0.5),
		"UE FSSS defaults must remain in their separate disabled snapshot packet")
	fog.volumetric_fog_enabled = true
	fog.volumetric_fog_scattering_distribution = 1.4
	fog.volumetric_fog_albedo = Color(0.5, 0.25, 1.0)
	fog.volumetric_fog_emissive = Color(10000.0, 20000.0, -3.0)
	fog.volumetric_fog_extinction_scale = 4.0
	fog.volumetric_fog_distance = 80.0
	fog.volumetric_fog_start_distance = 12.0
	fog.volumetric_fog_near_fade_in_distance = 8.0
	fog.volumetric_fog_static_lighting_scattering_intensity = 4.0
	fog.volumetric_fog_override_light_colors_with_fog_inscattering_colors = true
	fog.volumetric_fog_history_weight = 0.75
	fog.volumetric_fog_history_miss_supersample_count = 8
	fog.volumetric_fog_jitter_enabled = false
	fog.volumetric_fog_ray_traced_shadows_enabled = true
	fog.fsss_enabled = true
	fog.fsss_scene_color_scattering_amount_scale = 1.25
	fog.fsss_scene_color_scattering_amount_power = 0.75
	fog.fsss_spread_scale = 0.25
	fog.fsss_blur_control = 0.75
	var volume_snapshot: Dictionary = snapshot_for(fog)["volumetric_fog"]
	require(bool(volume_snapshot["enabled"])
		and is_equal_approx(float(volume_snapshot["scattering_distribution"]), 0.99)
		and is_equal_approx(float(volume_snapshot["extinction_scale"]), 4.0)
		and is_equal_approx(float(volume_snapshot["distance"]), 80.0)
		and is_equal_approx(float(volume_snapshot["start_distance"]), 12.0)
		and is_equal_approx(float(volume_snapshot["near_fade_in_distance"]), 8.0)
		and is_equal_approx(float(volume_snapshot["static_lighting_scattering_intensity"]), 4.0)
		and bool(volume_snapshot["override_light_colors_with_fog_inscattering_colors"])
		and is_equal_approx(float(volume_snapshot["history_weight"]), 0.75)
		and int(volume_snapshot["history_miss_supersample_count"]) == 8
		and not bool(volume_snapshot["jitter_enabled"])
		and bool(volume_snapshot["ray_traced_shadows_enabled"]),
		"authored volumetric controls must survive safe packet packing")
	require_vec(volume_snapshot["albedo"], Vector3(0.21404114, 0.05087609, 1.0),
		"FColor-style albedo must be decoded from sRGB to linear RGB")
	require_vec(volume_snapshot["emissive"], Vector3(100.0, 200.0, 0.0),
		"UE emissive per-centimeter values must be scaled to per-meter radiance")
	var fsss_snapshot: Dictionary = snapshot_for(fog)["screen_space_scattering"]
	require(bool(fsss_snapshot["enabled"])
		and is_equal_approx(float(fsss_snapshot["scene_color_scattering_amount_scale"]), 1.25)
		and is_equal_approx(float(fsss_snapshot["scene_color_scattering_amount_power"]), 0.75)
		and is_equal_approx(float(fsss_snapshot["spread_scale"]), 0.25)
		and is_equal_approx(float(fsss_snapshot["blur_control"]), 0.75),
		"advanced FSSS controls must publish separately from the 3D volume packet")
	fog.volumetric_fog_scattering_distribution = INF
	fog.volumetric_fog_extinction_scale = NAN
	fog.volumetric_fog_distance = -1.0
	fog.volumetric_fog_start_distance = -1.0
	fog.volumetric_fog_near_fade_in_distance = INF
	fog.volumetric_fog_static_lighting_scattering_intensity = -1.0
	fog.volumetric_fog_history_weight = INF
	fog.volumetric_fog_history_miss_supersample_count = 5
	fog.volumetric_fog_albedo = Color(NAN, 0.0, 0.0)
	fog.volumetric_fog_emissive = Color(INF, 0.0, 0.0)
	fog.fsss_scene_color_scattering_amount_scale = NAN
	fog.fsss_scene_color_scattering_amount_power = -1.0
	fog.fsss_spread_scale = INF
	fog.fsss_blur_control = 2.0
	var invalid_snapshot := fog.snapshot_fields()
	var safe_volume: Dictionary = invalid_snapshot["volumetric_fog"]
	var safe_fsss: Dictionary = invalid_snapshot["screen_space_scattering"]
	require(is_equal_approx(float(safe_volume["scattering_distribution"]), 0.2)
		and is_equal_approx(float(safe_volume["extinction_scale"]), 1.0)
		and is_equal_approx(float(safe_volume["distance"]), 0.0)
		and is_zero_approx(float(safe_volume["start_distance"]))
		and is_zero_approx(float(safe_volume["near_fade_in_distance"]))
		and is_zero_approx(float(safe_volume["static_lighting_scattering_intensity"]))
		and is_equal_approx(float(safe_volume["history_weight"]), 0.9)
		and int(safe_volume["history_miss_supersample_count"]) == 8,
		"non-finite and negative volumetric values must sanitize to finite safe values")
	require_vec(safe_volume["albedo"], Vector3.ONE,
		"invalid sRGB albedo must fall back to finite white")
	require_vec(safe_volume["emissive"], Vector3.ZERO,
		"invalid linear emissive must fall back to finite black")
	require(is_equal_approx(float(safe_fsss["scene_color_scattering_amount_scale"]), 1.0)
		and is_zero_approx(float(safe_fsss["scene_color_scattering_amount_power"]))
		and is_equal_approx(float(safe_fsss["spread_scale"]), 0.1)
		and is_equal_approx(float(safe_fsss["blur_control"]), 1.0),
		"invalid FSSS values must be sanitized inside their independent packet")
	require(is_equal_approx(float(invalid_snapshot["fog_density"]),
		float(medium_before_volume["fog_density"]))
		and is_equal_approx(float(invalid_snapshot["fog_height_falloff"]),
		float(medium_before_volume["fog_height_falloff"]))
		and is_equal_approx(float(invalid_snapshot["second_fog_density"]),
		float(medium_before_volume["second_fog_density"]))
		and is_equal_approx(float(invalid_snapshot["second_fog_height_falloff"]),
		float(medium_before_volume["second_fog_height_falloff"])),
		"adding volume and FSSS packets must leave the existing height-fog medium fields unchanged")
	fog.volumetric_fog_enabled = false
	fog.volumetric_fog_scattering_distribution = 0.2
	fog.volumetric_fog_albedo = Color.WHITE
	fog.volumetric_fog_emissive = Color.BLACK
	fog.volumetric_fog_extinction_scale = 1.0
	fog.volumetric_fog_distance = 60.0
	fog.volumetric_fog_start_distance = 0.0
	fog.volumetric_fog_near_fade_in_distance = 0.0
	fog.volumetric_fog_static_lighting_scattering_intensity = 1.0
	fog.volumetric_fog_override_light_colors_with_fog_inscattering_colors = false
	fog.volumetric_fog_history_weight = 0.9
	fog.volumetric_fog_history_miss_supersample_count = 4
	fog.volumetric_fog_jitter_enabled = true
	fog.volumetric_fog_ray_traced_shadows_enabled = false
	fog.fsss_enabled = false
	fog.fsss_scene_color_scattering_amount_scale = 1.0
	fog.fsss_scene_color_scattering_amount_power = 1.0
	fog.fsss_spread_scale = 0.1
	fog.fsss_blur_control = 0.5
	fog.fog_height_falloff = 0.0
	fog.second_fog_height_falloff = 0.0
	var zero_falloff := snapshot_for(fog)
	require(fog.fog_height_falloff == 0.0 and fog.second_fog_height_falloff == 0.0
		and float(zero_falloff["fog_height_falloff"]) == 0.0
		and float(zero_falloff["second_fog_height_falloff"]) == 0.0,
		"zero falloff must be preserved for both authored layers and the runtime snapshot")
	fog.fog_height_falloff = -0.25
	fog.second_fog_height_falloff = -0.5
	var negative_falloff := snapshot_for(fog)
	require(fog.fog_height_falloff == 0.0 and fog.second_fog_height_falloff == 0.0
		and float(negative_falloff["fog_height_falloff"]) == 0.0
		and float(negative_falloff["second_fog_height_falloff"]) == 0.0,
		"negative falloff inputs must clamp to zero rather than a positive lower bound")
	fog.fog_height_falloff = 0.2
	fog.second_fog_height_falloff = 0.2

	# Authored source is linear RGB exactly as entered, without conversion,
	# clamping, albedo tint, or dependence on sunlight.
	fog.fog_inscattering_color = Color(authored.x, authored.y, authored.z)
	fog.directional_inscattering_color = Color(artist.x, artist.y, artist.z)
	var raw_without_sky := snapshot_for(fog)
	require_vec(raw_without_sky["fog_color"], authored,
		"authored source must remain unchanged with no atmosphere provider")
	var fallback_rgb := raw_light_rgb(decoy, physical)
	require_vec(raw_without_sky["inscattering_color"], artist * fallback_rgb.dot(LUMA),
		"without an atmosphere provider the scene-light RGB luminance drives only the artist direction")

	# The atmosphere selects its primary sun independent of scene traversal.
	publish_sky(provider_a, primary.get_instance_id(), ambient, ground, contribution)
	var matched := snapshot_for(fog)
	var primary_rgb := raw_light_rgb(primary, physical)
	var expected_artist := artist * primary_rgb.dot(LUMA)
	require_vec(matched["sun_direction"], primary.global_transform.basis.z.normalized(),
		"the active atmosphere primary sun must take precedence over another scene light")
	require_vec(matched["fog_color"], authored + ambient * contribution,
		"Sky ambient adds independently to raw authored Fog Inscattering Color")
	require_vec(matched["inscattering_color"], expected_artist + ground * contribution,
		"raw selected-light artist luma and post-transmittance ground sun must remain separate directional terms")
	require(not matched.has("fog_albedo"), "fog snapshots must not publish an albedo path")

	# A hidden or cross-world atmosphere primary is unusable. Fall back to a
	# visible light in this world, and never borrow another world's ground term.
	primary.visible = false
	var hidden_primary := snapshot_for(fog)
	require_vec(hidden_primary["sun_direction"], decoy.global_transform.basis.z.normalized(),
		"a hidden primary must fall back to a visible directional light in the same world")
	require_vec(hidden_primary["inscattering_color"],
		artist * raw_light_rgb(decoy, physical).dot(LUMA),
		"the fallback light must drive only its raw-luminance artist lobe")
	primary.visible = true
	publish_sky(provider_a, foreign_sun.get_instance_id(), ambient, ground, contribution)
	var foreign_primary := snapshot_for(fog)
	require_vec(foreign_primary["sun_direction"], decoy.global_transform.basis.z.normalized(),
		"an atmosphere primary in another World3D must fall back to a same-world scene light")
	require_vec(foreign_primary["inscattering_color"], artist * raw_light_rgb(decoy, physical).dot(LUMA),
		"a foreign-world primary must not contribute ground illuminance to this fog")

	# HFC and Affect Height Fog gate atmosphere terms, but leave authored and
	# artist-controlled terms alone.
	publish_sky(provider_a, primary.get_instance_id(), ambient, ground, 0.0)
	var zero_contribution := snapshot_for(fog)
	require_vec(zero_contribution["fog_color"], authored,
		"zero HFC must suppress only atmosphere ambient")
	require_vec(zero_contribution["inscattering_color"], expected_artist,
		"zero HFC must suppress physical sun while retaining the artist lobe")
	publish_sky(provider_a, primary.get_instance_id(), ambient, ground, contribution, false)
	var disabled_atmosphere := snapshot_for(fog)
	require_vec(disabled_atmosphere["fog_color"], authored,
		"Affect Height Fog off must preserve authored source and remove sky ambient")
	require_vec(disabled_atmosphere["inscattering_color"], expected_artist,
		"Affect Height Fog off must remove physical sun and preserve the artist direction")

	# Negative lights retain their signed artist behavior but cannot add the
	# non-negative physical ground illuminance supplied by the atmosphere.
	primary.light_negative = true
	publish_sky(provider_a, primary.get_instance_id(), ambient, ground, contribution)
	var negative_sun := snapshot_for(fog)
	require_vec(negative_sun["inscattering_color"], artist * raw_light_rgb(primary, physical).dot(LUMA),
		"negative selected lights retain signed artist-lobe behavior only")
	require_vec(negative_sun["fog_color"], authored + ambient * contribution,
		"negative sunlight must not alter the independent base and sky ambient")
	primary.light_negative = false

	# Finite guards must reject overflowed atmosphere products without clipping
	# authored or artist values to an arbitrary radiance ceiling.
	publish_sky(provider_a, primary.get_instance_id(), Vector3.ONE * 1.0e30,
		ground, 1.0e30)
	var overflow_ambient := snapshot_for(fog)
	require_vec(overflow_ambient["fog_color"], authored,
		"a non-finite composed atmosphere ambient must leave the finite authored source intact")
	publish_sky(provider_a, primary.get_instance_id(), Vector3.ZERO,
		Vector3.ONE * 1.0e30, 1.0e30)
	var overflow_sun := snapshot_for(fog)
	require((overflow_sun["inscattering_color"] as Vector3).is_finite(),
		"overflowing ground illuminance times HFC must not publish Inf or NaN")
	require_vec(overflow_sun["inscattering_color"], expected_artist,
		"rejecting an invalid physical term must retain the finite artist lobe")

	# Providers and selected fog stay world-scoped.
	FengSkyRuntime.publish_snapshot(provider_b, world_b_id, {
		"ambient_radiance": Vector3(11.0, 13.0, 17.0),
		"height_fog_contribution": 1.0,
		"sun_light_id": 0,
		"sun_ground_illuminance": Vector3.ZERO,
		"affect_height_fog": true,
	})
	require_vec(snapshot_for(fog_b)["fog_color"], Vector3(11.0, 13.0, 17.0),
		"World B atmosphere ambient must reach only its own fog")
	require_vec(snapshot_for(fog)["fog_color"], authored,
		"publishing World B must not change World A source")

	# With no active atmosphere, a single visible scene directional still drives
	# the artist term, while the default black authored source continues to fog
	# through extinction without adding radiance.
	var viewport_c := make_viewport()
	var scene_sun := DirectionalLight3D.new()
	scene_sun.light_color = Color(0.4, 0.8, 0.2)
	scene_sun.light_intensity_lux = 24.0
	viewport_c.add_child(scene_sun)
	var scene_fog := FengHeightFog.new()
	viewport_c.add_child(scene_fog)
	scene_fog.directional_inscattering_color = Color(0.2, 0.4, 0.1)
	var scene_only := snapshot_for(scene_fog)
	require_vec(scene_only["fog_color"], Vector3.ZERO,
		"no atmosphere and black authored source must retain extinction without isotropic sun")
	require_vec(scene_only["inscattering_color"],
		Vector3(0.2, 0.4, 0.1) * raw_light_rgb(scene_sun, physical).dot(LUMA),
		"no atmosphere must preserve visible scene-light artist direction")
	scene_sun.visible = false
	var replacement_sun := DirectionalLight3D.new()
	replacement_sun.light_color = Color(0.7, 0.2, 0.3)
	replacement_sun.light_intensity_lux = 36.0
	viewport_c.add_child(replacement_sun)
	var replaced_scene_sun := snapshot_for(scene_fog)
	require_vec(replaced_scene_sun["sun_direction"], replacement_sun.global_transform.basis.z.normalized(),
		"a hidden cached scene sun must trigger immediate same-world fallback selection")
	require_vec(replaced_scene_sun["inscattering_color"],
		Vector3(0.2, 0.4, 0.1) * raw_light_rgb(replacement_sun, physical).dot(LUMA),
		"the replacement scene sun must drive the artist lobe without an atmosphere provider")

	# A local medium is published by its own world-scoped provider; it does not
	# need a HeightFog node or WorldEnvironment fog resource.
	var viewport_d := make_viewport()
	var local_volume := FengVolumetricFogVolume.new()
	local_volume.position = Vector3(12.0, 3.0, -4.0)
	local_volume.shape = FengVolumetricFogVolume.Shape.ELLIPSOID
	local_volume.size_m = Vector3(8.0, 6.0, 4.0)
	local_volume.density_per_m = 0.25
	local_volume.edge_fade_m = 1.5
	viewport_d.add_child(local_volume)
	FengFogRuntime._publish()
	var local_snapshot: Dictionary = {}
	for candidate in FengFogRuntime.snapshots():
		if int(candidate.get("world_id", 0)) == viewport_d.world_3d.get_instance_id():
			local_snapshot = candidate
			break
	require(not local_snapshot.is_empty()
		and int(local_snapshot.get("fog_id", -1)) == 0
		and not (local_snapshot.get("volumetric_fog", {}) as Dictionary).get("enabled", false)
		and (local_snapshot.get("local_volumes", []) as Array).size() == 1,
			"a local volume must publish a separate world packet without enabling component volume or height fog")
	var local_packet: Dictionary = LocalVolumeCodec.pack(local_snapshot.get("local_volumes", []))
	require(int(local_packet.get("count", 0)) == 1
		and (local_packet.get("bytes", PackedByteArray()) as PackedByteArray).size() == LocalVolumeCodec.BUFFER_BYTES,
		"local shape snapshots must pack into the fixed 16-record GPU buffer ABI")
	var empty_local_packet: Dictionary = LocalVolumeCodec.pack([])
	require(int(empty_local_packet.get("count", -1)) == 0
		and (empty_local_packet.get("bytes", PackedByteArray()) as PackedByteArray).size() == LocalVolumeCodec.BUFFER_BYTES,
		"an empty local-medium set must still upload a fully sized zeroed GPU buffer")
	var overflowing_local_values: Array = []
	for index in LocalVolumeCodec.MAX_VOLUMES + 1:
		var overflow_volume: Dictionary = (local_snapshot.local_volumes[0] as Dictionary).duplicate(true)
		overflow_volume["volume_id"] = index + 1
		if index == LocalVolumeCodec.MAX_VOLUMES:
			overflow_volume["emissive_per_m"] = Vector3(0.3, 0.4, 0.5)
		overflowing_local_values.append(overflow_volume)
	var overflowing_local_packet: Dictionary = LocalVolumeCodec.pack(overflowing_local_values)
	var local_batches: Array = overflowing_local_packet.get("batches", [])
	require(int(overflowing_local_packet.get("count", 0)) == LocalVolumeCodec.MAX_VOLUMES + 1
		and int(overflowing_local_packet.get("overflow_count", -1)) == 0
		and local_batches.size() == 2
		and int(overflowing_local_packet.get("batch_count", 0)) == 2,
		"local media beyond one 16-entry GPU batch must remain represented")
	if local_batches.size() == 2:
		var first_batch: Dictionary = local_batches[0]
		var second_batch: Dictionary = local_batches[1]
		var first_bytes: PackedByteArray = first_batch.get("bytes", PackedByteArray())
		var second_bytes: PackedByteArray = second_batch.get("bytes", PackedByteArray())
		require(first_bytes.size() == LocalVolumeCodec.BUFFER_BYTES
			and second_bytes.size() == LocalVolumeCodec.BUFFER_BYTES
			and first_bytes.decode_s32(0) == LocalVolumeCodec.MAX_VOLUMES
			and first_bytes.decode_s32(4) == 0
			and second_bytes.decode_s32(0) == 1
			and second_bytes.decode_s32(4) == 1,
			"local batch ABI must carry fixed byte size, item count, and ordered batch index")
		require(is_equal_approx(second_bytes.decode_float(128), 0.3)
			and is_equal_approx(second_bytes.decode_float(132), 0.4)
			and is_equal_approx(second_bytes.decode_float(136), 0.5),
			"the 17th local medium's independent emissive source must survive into batch two")
	var rotated_transform := Transform3D(
			Basis(Vector3.UP, 0.61).scaled(Vector3(1.5, 2.0, 0.75)), Vector3(7.0, -2.0, 9.0))
	var rotated_volume: Dictionary = (local_snapshot.local_volumes[0] as Dictionary).duplicate(true)
	rotated_volume["transform"] = rotated_transform
	rotated_volume["size_m"] = Vector3(8.0, 6.0, 4.0)
	var rotated_packet: Dictionary = LocalVolumeCodec.pack([rotated_volume])
	var rotated_bytes: PackedByteArray = rotated_packet.get("bytes", PackedByteArray())
	var test_world_position := Vector3(13.0, 1.0, -6.0)
	var inverse_x := Vector3(rotated_bytes.decode_float(16), rotated_bytes.decode_float(20), rotated_bytes.decode_float(24))
	var inverse_y := Vector3(rotated_bytes.decode_float(32), rotated_bytes.decode_float(36), rotated_bytes.decode_float(40))
	var inverse_z := Vector3(rotated_bytes.decode_float(48), rotated_bytes.decode_float(52), rotated_bytes.decode_float(56))
	var inverse_origin := Vector3(rotated_bytes.decode_float(64), rotated_bytes.decode_float(68), rotated_bytes.decode_float(72))
	var shader_local_position := inverse_x * test_world_position.x \
			+ inverse_y * test_world_position.y + inverse_z * test_world_position.z + inverse_origin
	require(shader_local_position.distance_to(rotated_transform.affine_inverse() * test_world_position) < 0.00001,
		"packed inverse-basis columns must map rotated, non-uniformly scaled world points to local space")
	local_volume.albedo = Color(1.5, -0.25, 0.5)
	local_volume.emissive_per_m = Color(4.0, 2.0, 1.5)
	var clamped_local_snapshot: Dictionary = local_volume.snapshot_fields()
	var clamped_local_packet: Dictionary = LocalVolumeCodec.pack([clamped_local_snapshot])
	var clamped_local_bytes: PackedByteArray = clamped_local_packet.get("bytes", PackedByteArray())
	require_vec(clamped_local_snapshot.get("albedo", Vector3.INF), Vector3(1.0, 0.0, 0.5),
		"local fog albedo is linear and clamped to the UE UNorm8 range")
	require(is_equal_approx(clamped_local_bytes.decode_float(112), 1.0)
		and is_zero_approx(clamped_local_bytes.decode_float(116))
		and is_equal_approx(clamped_local_bytes.decode_float(120), 0.5),
		"local volume codec must preserve the same clamped linear albedo in its GPU record")
	var packed_albedo := Vector3(clamped_local_bytes.decode_float(112),
			clamped_local_bytes.decode_float(116), clamped_local_bytes.decode_float(120))
	var packed_density: float = maxf(clamped_local_bytes.decode_float(80), 0.0)
	var packed_extinction_scale: float = maxf(clamped_local_bytes.decode_float(124), 0.0)
	var center_extinction := packed_density * packed_extinction_scale
	var center_scattering := packed_albedo * center_extinction
	require(center_scattering.x <= center_extinction + 1.0e-6
		and center_scattering.y <= center_extinction + 1.0e-6
		and center_scattering.z <= center_extinction + 1.0e-6,
		"local scattering coefficients must not exceed their extinction coefficient")
	require(is_equal_approx(clamped_local_snapshot.emissive_per_m.x, 4.0)
		and is_equal_approx(clamped_local_bytes.decode_float(128), 4.0)
		and is_equal_approx(clamped_local_bytes.decode_float(132), 2.0)
		and is_equal_approx(clamped_local_bytes.decode_float(136), 1.5),
		"local emissive remains independent HDR radiance in the snapshot and packed record")
	var medium_shader := FileAccess.get_file_as_string(
		"res://addons/feng-fog/rendering/shaders/volumetric_fog_medium.glslinc")
	require(medium_shader.contains("clamp(volume.albedo_extinction_scale.rgb")
		and medium_shader.contains("* local_extinction"),
		"GPU local scattering must apply bounded linear albedo to the final extinction coefficient")
	var extreme_emission_snapshot: Dictionary = clamped_local_snapshot.duplicate(true)
	extreme_emission_snapshot["emissive_per_m"] = Vector3(100000.0, 2.0, 3.0)
	var extreme_emission_packet: Dictionary = LocalVolumeCodec.pack([extreme_emission_snapshot])
	var extreme_emission_bytes: PackedByteArray = extreme_emission_packet.get("bytes", PackedByteArray())
	require(is_equal_approx(extreme_emission_bytes.decode_float(128), 65504.0)
		and is_equal_approx(extreme_emission_bytes.decode_float(132), 2.0),
		"local HDR emissive must remain above one and sanitize to the half-float range")
	local_volume.albedo = Color.WHITE
	local_volume.emissive_per_m = Color.BLACK
	var local_bytes: PackedByteArray = local_packet.bytes
	require(is_equal_approx(local_bytes.decode_float(64), -12.0)
		and is_equal_approx(local_bytes.decode_float(68), -3.0)
		and is_equal_approx(local_bytes.decode_float(72), 4.0),
		"local volume records must carry the inverse world origin for GPU world-to-local evaluation")
	local_volume.enabled = false
	FengFogRuntime._publish()
	local_snapshot = {}
	for candidate in FengFogRuntime.snapshots():
		if int(candidate.get("world_id", 0)) == viewport_d.world_3d.get_instance_id():
			local_snapshot = candidate
			break
	require(local_snapshot.is_empty(), "disabling the only local medium must remove its world snapshot")

	FengSkyRuntime.remove_snapshot(provider_a, world_a_id)
	FengSkyRuntime.remove_snapshot(provider_b, world_b_id)
	viewport_a.free()
	viewport_b.free()
	viewport_c.free()
	viewport_d.free()
	if _failures == 0:
		print("PASS Unreal height fog physical_units=", physical, " checks=", _checks)
	else:
		print("Feng Unreal height fog tests failed: ", _failures, " / ", _checks)
	quit(1 if _failures > 0 else 0)


func test_baked_source_snapshot_modes() -> void:
	var vlm: Resource = VolumetricLightmapResourceScript.new()
	var import_result: Dictionary = vlm.call("import_decoded_payload", _minimal_vlm_payload())
	require(bool(import_result.get("valid", false)),
		"a real decoded VLM Resource accepts the minimal valid brick payload")
	var resource_id := vlm.get_instance_id()
	FengFogRuntime._baked_payload_cache.erase(resource_id)
	var first: Dictionary = FengFogRuntime._baked_payload_snapshot(vlm)
	var cached: Dictionary = FengFogRuntime._baked_payload_snapshot(vlm)
	require(first.get("source_mode", "") == "ue_volumetric_lightmap_bricks"
		and int(first.get("resource_id", 0)) == resource_id
		and first.get("brick_size", 0) == 1
		and int(cached.get("revision", 0)) == int(first.get("revision", -1))
		and first.get("snapshot_thread_contract", "") == "main_thread_immutable_values_only",
		"the actual UE VLM Resource publishes and reuses its immutable value snapshot")
	var previous_revision: int = int(vlm.get("revision"))
	vlm.set("capture_transform", Transform3D(Basis.IDENTITY, Vector3(3.0, 0.0, 0.0)))
	var refreshed: Dictionary = FengFogRuntime._baked_payload_snapshot(vlm)
	var refreshed_world_to_capture: Transform3D = refreshed.get("world_to_capture", Transform3D.IDENTITY)
	require(int(refreshed.get("revision", 0)) == previous_revision + 1
		and refreshed_world_to_capture.origin.is_equal_approx(Vector3(-3.0, 0.0, 0.0)),
		"a changed VLM capture transform replaces the cached snapshot by resource revision")
	var unsupported := UnsupportedBakedResource.new()
	var unsupported_snapshot: Dictionary = FengFogRuntime._baked_payload_snapshot(unsupported)
	require(unsupported_snapshot.is_empty(),
		"a Resource without a supported baked payload API must not be mislabeled as either baked format")
	FengFogRuntime._baked_payload_cache.erase(resource_id)
	FengFogRuntime._baked_payload_cache.erase(unsupported.get_instance_id())
	vlm = null
	unsupported = null


func _minimal_vlm_payload() -> Dictionary:
	var ambient := PackedByteArray()
	ambient.resize(8 * 8)
	var sh_layers: Array[PackedByteArray] = []
	for _layer_index in 6:
		var layer := PackedByteArray()
		layer.resize(8 * 4)
		sh_layers.append(layer)
	return {
		"format_version": 1,
		"coordinate_units": "m",
		"capture_transform": Transform3D.IDENTITY,
		"bounds_local": AABB(Vector3.ZERO, Vector3.ONE),
		"brick_size": 1,
		"indirection_dimensions": Vector3i.ONE,
		"brick_atlas_dimensions": Vector3i(2, 2, 2),
		"indirection_rgba8_uint": PackedByteArray([0, 0, 0, 1]),
		"ambient_rgba16f": ambient,
		"sh_coefficients_rgba8_unorm": sh_layers,
		"sky_bent_normal_rgba8_unorm": PackedByteArray(),
		"directional_shadow_r8_unorm": PackedByteArray(),
		"baked_exposure": 1.0,
		"includes_environment_radiance": false,
		"contains_static_direct_directional_lighting": false,
		"has_sky_bent_normal": false,
		"has_directional_shadowing": false,
		"static_directional_light_key": "",
		"coefficient_domain": "ue_vlm_ambient_and_normalized_sh_v1",
		"source_revision": 1,
	}


func test_fsss_source_contract() -> void:
	var fsss_service_source := FileAccess.get_file_as_string(
		"res://addons/feng-fog/rendering/feng_fsss_gpu_service.gd")
	var fog_pass_source := FileAccess.get_file_as_string(
		"res://addons/feng-render-pipeline/passes/height_fog_pass.gd")
	var cloud_gpu_source := FileAccess.get_file_as_string(
		"res://addons/feng-cloud/feng_cloud_gpu.gd")
	var renderer_entry_source := FileAccess.get_file_as_string(
		"res://addons/feng-fog/rendering/feng_fog_renderer_entry.gd")
	require(fsss_service_source.contains("_failed_pipeline_sources")
		and fsss_service_source.contains("expanded_source.sha256_text()")
		and fsss_service_source.contains("_failed_pipeline_sources.clear()"),
		"FSSS shader compile failures are cached by expanded source and cleared with owned GPU resources")
	require(fsss_service_source.contains("cloud_composition.get(\"history_identity\"")
		and not fsss_service_source.contains("cloud_composition.get(\"source_revision\""),
		"FSSS history uses stable cloud identity while exact source revision remains a per-frame sidecar check")
	require(cloud_gpu_source.contains("\"history_identity\": history_identity")
		and fog_pass_source.contains("get_cloud_snapshot_source_signature")
		and fog_pass_source.contains("value[\"history_identity\"]"),
		"cloud sidecar validation keeps exact revision checks and publishes a separate stable history identity")
	require(renderer_entry_source.contains("func get_fsss_error() -> String")
		and fog_pass_source.contains("func _report_fsss_failure()")
		and fog_pass_source.contains("_report(\"FSSS output unavailable:"),
		"FSSS GPU failures are exposed and reported once without hiding enabled-path failures")
	# Mirrors the source/remainder identities used by the GPU source-generation
	# and final-composite passes. These cases catch SceneColor double-adds and
	# avoid divisions by a zero cloud or fog transmittance.
	var scene := Vector3(2.0, 1.0, 0.5)
	var lv := Vector3(0.2, 0.1, 0.05)
	var lh := Vector3(0.3, 0.2, 0.1)
	var tv := 0.6
	var th := 0.7
	var amount := 0.0
	var source := lv + tv * lh + tv * amount * (th * scene)
	var remainder := tv * (1.0 - amount) * th * scene
	require(source.is_equal_approx(lv + tv * lh)
		and (source + remainder).is_equal_approx(lv + tv * (lh + th * scene)),
		"A=0 must retain and blur fog radiance without injecting SceneColor, while the unblurred source/remainder reconstructs normal fog")
	var zero_fog_source := Vector3.ZERO
	var zero_fog_transmittance := 1.0
	var zero_fog_scene := Vector3(0.4, 0.7, 1.2)
	var zero_fog_amount := 0.0
	var zero_fog_output := zero_fog_source + zero_fog_transmittance \
			* (1.0 - zero_fog_amount) * zero_fog_scene
	require(zero_fog_output.is_equal_approx(zero_fog_scene),
		"Zero fog with zero SceneColor injection must preserve the input image")
	var fully_scattering_amount := 1.0
	var fully_scattering_source := lv + tv * lh \
			+ tv * fully_scattering_amount * (th * scene)
	var fully_scattering_remainder := tv * (1.0 - fully_scattering_amount) * th * scene
	require(fully_scattering_remainder.is_zero_approx()
		and (fully_scattering_source + fully_scattering_remainder).is_equal_approx(
				lv + tv * (lh + th * scene)),
		"A=1 must put all SceneColor into the filtered source while preserving the zero-blur composite")
	var opaque_volume_transmittance := 0.0
	var opaque_source := lv + opaque_volume_transmittance * lh
	var opaque_remainder := opaque_volume_transmittance * (1.0 - amount) * th * scene
	require(opaque_source.is_equal_approx(lv) and opaque_remainder.is_zero_approx(),
		"Opaque fog must remain finite without dividing by transmittance")
	var cloud_radiance := Vector3(0.6, 0.3, 0.1)
	var opaque_cloud_transmittance := 0.0
	var opaque_cloud_scene := cloud_radiance
	var cloud_base := cloud_radiance + opaque_cloud_transmittance * (lv + tv * lh)
	var cloud_residual := opaque_cloud_scene \
			- (cloud_radiance + opaque_cloud_transmittance * lh)
	var cloud_source := cloud_base + tv * amount * cloud_residual
	var cloud_remainder := tv * (1.0 - amount) * cloud_residual
	require(cloud_source.is_equal_approx(cloud_radiance)
		and cloud_remainder.is_zero_approx(),
		"Opaque cloud sidecars must stay stable without dividing by cloud transmittance")
	var zero_width_scene := Vector3(0.7, 0.2, 0.9)
	var zero_width_cloud_radiance := Vector3(0.4, 0.3, 0.1)
	var zero_width_cloud_transmittance := 0.0
	var zero_width_fog_source := Vector3.ZERO
	var zero_width_fog_transmittance := 1.0
	var zero_width_clip_result := zero_width_scene
	require(zero_width_fog_source.is_zero_approx()
		and is_equal_approx(zero_width_fog_transmittance, 1.0)
		and zero_width_clip_result.is_equal_approx(zero_width_scene)
		and zero_width_cloud_radiance.is_finite()
		and zero_width_cloud_transmittance == 0.0,
		"UE W<=0 clip must leave the existing scene unchanged even when a cloud sidecar is opaque")
	var raw_t := 0.5
	var scene_amount := 0.5
	var final_t := raw_t * (1.0 - scene_amount)
	var fog_coverage := 1.0 - raw_t
	var mip_coverage := 1.0 - final_t
	var depth_m := 80.0
	var expected_w := sqrt(0.375 * depth_m * depth_m * -log(raw_t))
	var incorrect_w := sqrt(0.375 * depth_m * depth_m * -log(final_t))
	require(is_equal_approx(final_t, 0.25)
		and is_equal_approx(fog_coverage, 0.5)
		and is_equal_approx(mip_coverage, 0.75)
		and expected_w < incorrect_w,
		"FSSS W uses raw fog T while mip coverage uses FinalT=T*(1-A), independently of cloud opacity")
	test_fsss_kernel_contract()


func test_temporal_depth_contract() -> void:
	var codec_source := FileAccess.get_file_as_string(
		"res://addons/feng-fog/rendering/feng_volumetric_fog_codec.gd")
	var service_source := FileAccess.get_file_as_string(
		"res://addons/feng-fog/rendering/feng_volumetric_fog_gpu_service.gd")
	var medium_source := FileAccess.get_file_as_string(
		"res://addons/feng-fog/rendering/shaders/volumetric_fog_medium.glslinc")
	var integrate_source := FileAccess.get_file_as_string(
		"res://addons/feng-fog/rendering/shaders/volumetric_fog_integrate.glslinc")
	var reproject_source := FileAccess.get_file_as_string(
		"res://addons/feng-fog/rendering/shaders/volumetric_fog_reproject.glslinc")
	var history_source := FileAccess.get_file_as_string(
		"res://addons/feng-fog/rendering/shaders/volumetric_fog_history.glslinc")
	var conservative_helper_source := FileAccess.get_file_as_string(
		"res://addons/feng-fog/rendering/shaders/volumetric_fog_conservative_depth.glslinc")
	var work_mask_source := FileAccess.get_file_as_string(
		"res://addons/feng-fog/rendering/shaders/volumetric_fog_work_mask.glslinc")
	var conservative_source := FileAccess.get_file_as_string(
		"res://addons/feng-fog/rendering/shaders/volumetric_fog_conservative_depth_compute.glslinc")
	require(codec_source.contains("1.0 if current_depth_valid else 0.0")
		and codec_source.contains("history_valid and previous_depth_valid")
		and service_source.contains("state.get(\"depth_history_valid\", false)"),
		"temporal depth validity must distinguish current depth from a valid previous depth history")
	require(service_source.contains('"depth_history": depth_history')
		and service_source.contains("_create_conservative_depth_texture")
		and conservative_source.contains("vec2(cell) - vec2(0.5)")
		and conservative_source.contains("vec2(cell) + vec2(1.5)")
		and conservative_source.contains("furthest_reverse_z = min(furthest_reverse_z"),
		"current and previous depth history must use one tiled 2D reverse-Z conservative depth field")
	require(conservative_helper_source.contains("feng_fixup_history_uv")
		and conservative_helper_source.contains("valid.w && valid.z")
		and conservative_helper_source.contains("valid.x && valid.y")
		and conservative_helper_source.contains("valid.w && valid.x")
		and conservative_helper_source.contains("valid.z && valid.y")
		and conservative_helper_source.contains("previous_slice < 0.0")
		and conservative_helper_source.contains("previous_slice >= float(grid.z)")
		and conservative_helper_source.contains("previous_depth_clip.z / previous_depth_clip.w")
		and history_source.contains("max(float(cell.z) - 0.5, 0.0)")
		and reproject_source.contains("max(float(cell.z) - 0.5, 0.0)")
		and reproject_source.contains("feng_volume_previous_grid_uv"),
		"history must use UE's ordered depth repair, near-biased conservative position, and raw slice bounds")
	require(not medium_source.contains("feng_fog_frame_jitter")
		and not integrate_source.contains("feng_fog_frame_jitter")
		and not reproject_source.contains("feng_fog_frame_jitter")
		and medium_source.contains("vec3 sample_offset = vec3(0.5)")
		and integrate_source.contains("vec2(cell_xy) + vec2(0.5)")
		and integrate_source.contains("feng_fog_depth_from_slice(0.0)")
		and integrate_source.contains("float(z) + 0.5"),
		"medium, history reprojection, and integration must keep UE fixed-center froxel positions")
	var depth_light_source := FileAccess.get_file_as_string(
		"res://addons/feng-fog/rendering/shaders/volumetric_fog_light.glslinc")
	var ray_generator_source := FileAccess.get_file_as_string(
		"res://addons/feng-fog/rendering/raytracing/fog_rt_ray_input_generator.gd")
	require(depth_light_source.contains("feng_fog_frame_jitter")
		and ray_generator_source.contains("p_sample_depth_offset"),
		"only lighting and matching RT ray input should use UE's shared XYZ Halton sample")
	var z_params := VolumetricFogCodec.grid_z_params(0.05, 0.0, 60.0, 64)
	var first_near_depth := VolumetricFogCodec.depth_from_z_slice(z_params, 0.0)
	var first_center_depth := VolumetricFogCodec.depth_from_z_slice(z_params, 0.5)
	require(first_center_depth > first_near_depth and first_near_depth > 0.0,
		"the first integrated slice must cover the positive interval from near plane to its center")
	var frame_zero_result := _integrate_uniform_fog(z_params, 12, 0.08, 0.2)
	var frame_one_result := _integrate_uniform_fog(z_params, 12, 0.08, 0.2)
	require(frame_zero_result.distance_to(frame_one_result) < 1.0e-8,
		"uniform-field integration must stay fixed when only the light-sampling frame index changes")
	var previous_scene_depths := [4.0, 0.0, 10.0, 8.0]
	var conservative_depth := INF
	for depth_m in previous_scene_depths:
		if depth_m > 0.0:
			conservative_depth = minf(conservative_depth, depth_m)
	require(is_equal_approx(conservative_depth, 4.0)
		and conservative_depth + 0.05 < 7.0,
		"the nearest valid depth in a reprojected 2x2 neighborhood rejects history behind a wall")
	var depth_constraint_source := FileAccess.get_file_as_string(
		"res://addons/feng-fog/rendering/shaders/volumetric_fog_depth_constraints.glslinc")
	require(depth_constraint_source.contains("current_depth_projection")
		and depth_constraint_source.contains("current_depth_inverse_projection")
		and depth_constraint_source.contains("scene_slice - 0.5")
		and depth_constraint_source.contains("return max(cell.z + sample_offset.z, 0.0);")
		and medium_source.contains("vec3 sample_offset = vec3(0.5)")
		and depth_light_source.contains("feng_fog_frame_jitter")
		and depth_light_source.contains("fog_frame.camera_position_orthographic.w > 0.5")
		and depth_light_source.contains("vec3(0.0, 0.0, -1.0)"),
		"UE depth constraint must map fixed medium and shared jittered-light samples through current TAA depth matrices")
	var near_surface_scene_slice := 0.1
	var near_surface_offset := 0.5 + (near_surface_scene_slice - 0.5 - 0.5)
	var constrained_near_slice := maxf(near_surface_offset, 0.0)
	require(near_surface_offset < 0.0 and constrained_near_slice == 0.0,
		"depth constraints may move the first jitter sample behind slice zero, but its sampled depth clamps to the near plane")
	require(history_source.contains("feng_volume_requested_sample_count(")
		and work_mask_source.contains("feng_volume_requested_sample_count(view_position")
		and work_mask_source.contains("history_work_mask.sample_count[index] = result")
		and depth_light_source.contains("history_work_mask.sample_count[froxel_index]")
		and depth_light_source.contains("accumulated_light / float(max(sample_count, 1))")
		and depth_light_source.contains("fog_lights.quality_control.y > 0.5")
		and depth_light_source.contains("max(emissive, vec3(0.0)) * scene_normalization"),
		"one fixed-center history work mask drives lighting samples while deterministic emissive is added once")
	var rt_bridge_source := FileAccess.get_file_as_string(
		"res://addons/feng-fog/rendering/fog_rt_volume_bridge.gd")
	require(service_source.contains("_current_depth_available(ctx, frame, depth_layer, rd)")
		and service_source.contains("FRPPassContext.OP_GBUFFER")
		and service_source.contains('frame.get("depth_prepass_enabled", false)')
		and rt_bridge_source.contains('"max_samples": sample_count'),
		"current-frame depth is enabled only after GBuffer completion and the generator receives its ABI max_samples field")
	require(rt_bridge_source.contains("rd.buffer_copy(visibility, _visibility_buffer")
		and depth_light_source.contains("(sample_index * uint(fog_lights.rt_layout.y) + light_slot) * froxel_count")
		and ray_generator_source.contains("p_work_mask_options")
		and rt_bridge_source.contains('"max_samples": sample_count'),
		"RT input and borrowed uint visibility results use the same sample-major work mask and persistent atlas")
	require(service_source.contains("if rt_enabled:")
		and depth_light_source.contains("feng_volume_requested_sample_count")
		and service_source.contains("_storage_buffer(17, _history_work_mask_buffer(state))")
		and service_source.contains("return mask if mask.is_valid() else _fallback_local_buffer")
		and not service_source.contains("if not rt_enabled and requested_samples > 1"),
		"only RT dispatches a work mask; non-RT uses inline history and still binds a valid neutral mask buffer")
	var light_extension_source := FileAccess.get_file_as_string(
		"res://addons/feng-fog/rendering/shaders/volumetric_fog_light.glslinc")
	var fog_component_source := FileAccess.get_file_as_string(
		"res://addons/feng-fog/feng_height_fog.gd")
	require(fog_component_source.contains("volumetric_fog_area_light_source_textures_enabled := false")
		and light_extension_source.contains("feng_volume_rect_barn_door_fade")
		and light_extension_source.contains("fog_lights.quality_control.z > 0.5")
		and light_extension_source.contains("directional_shadowing_enabled")
		and light_extension_source.contains("sky_visibility"),
		"UE's disabled-by-default RectLightTexture option, area barn doors, and sky/sun cloud visibility gates are consumed")


func test_conservative_depth_fixup() -> void:
	var log_z := VolumetricFogCodec.grid_z_params(0.05, 0.0, 60.0, 64)
	var first_cell_near_slice := maxf(0.0 - 0.5, 0.0)
	var second_cell_near_slice := maxf(1.0 - 0.5, 0.0)
	var volume_near := VolumetricFogCodec.depth_from_z_slice(log_z, 0.0)
	var first_cell_far := VolumetricFogCodec.depth_from_z_slice(log_z, 0.5)
	require(first_cell_near_slice == 0.0 and second_cell_near_slice == 0.5
		and is_equal_approx(VolumetricFogCodec.depth_from_z_slice(log_z, first_cell_near_slice), volume_near)
		and is_equal_approx(VolumetricFogCodec.depth_from_z_slice(log_z, second_cell_near_slice), first_cell_far),
		"UE conservative-depth probes use the near face max(cell.z - 0.5, 0), clamping the first slice to the volume near plane")
	var sky_values := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	var sky_min := VolumetricFogCodec.conservative_reverse_z_min(sky_values)
	var sky_fixup := VolumetricFogCodec.fixup_history_uv_from_gather(
			Vector2(0.42, 0.63), Vector2i(8, 8), sky_values, 0.35)
	require(sky_min == 0.0 and sky_fixup.valid and sky_fixup.choice == "all"
		and sky_fixup.uv.is_equal_approx(Vector2(0.42, 0.63)),
		"reverse-Z sky depth zero remains visible history and does not reject the whole neighborhood")
	var expected_by_mask := {
		0: "none", 1: "x", 2: "y", 3: "xy", 4: "z", 5: "x", 6: "zy",
		7: "xy", 8: "w", 9: "wx", 10: "y", 11: "xy", 12: "wz",
		13: "wz", 14: "wz", 15: "all",
	}
	for mask in 16:
		var depths := PackedFloat32Array()
		for bit in 4:
			depths.append(0.0 if (mask & (1 << bit)) != 0 else 0.8)
		var fixed := VolumetricFogCodec.fixup_history_uv_from_gather(
				Vector2(0.42, 0.63), Vector2i(8, 8), depths, 0.5)
		var expected_choice: String = expected_by_mask[mask]
		require(bool(fixed.valid) == (mask != 0) and fixed.choice == expected_choice
			and fixed.uv.is_finite(),
			"2x2 conservative history candidate mask %d follows UE order (got %s)" % [mask, fixed.choice])
	var surface_furthest := VolumetricFogCodec.conservative_reverse_z_min(
			PackedFloat32Array([0.9, 0.8, 0.95, 0.85]))
	var disocclusion := VolumetricFogCodec.fixup_history_uv_from_gather(
			Vector2(0.42, 0.63), Vector2i(8, 8),
			PackedFloat32Array([0.8, 0.8, 0.8, 0.0]), 0.5)
	require(is_equal_approx(surface_furthest, 0.8)
		and VolumetricFogCodec.conservative_depth_occludes(surface_furthest, 0.6, true)
		and not VolumetricFogCodec.conservative_depth_occludes(0.0, 0.6, true)
		and VolumetricFogCodec.conservative_history_sample_count(true, false, true,
				surface_furthest, 0.6, 4) == 0
		and disocclusion.valid and disocclusion.choice == "w"
		and VolumetricFogCodec.conservative_history_sample_count(true, true, false,
				0.0, 0.6, 4) == 1
		and VolumetricFogCodec.conservative_history_sample_count(false, false, false,
				0.0, 0.6, 4) == 4,
		"furthest reverse-Z depth skips fully occluded work and FixupHistoryUV recovers visible neighbors")


func test_volume_depth_range_contract() -> void:
	var normal_range := VolumetricFogCodec.has_valid_volume_depth_range(0.05, 0.0, 60.0)
	var zero_extent := VolumetricFogCodec.has_valid_volume_depth_range(0.05, 0.0, 0.0)
	var camera_past_far := VolumetricFogCodec.has_valid_volume_depth_range(61.0, 0.0, 60.0)
	var start_controls_near := VolumetricFogCodec.has_valid_volume_depth_range(1.0, 4.0, 5.0)
	require(normal_range and not zero_extent and not camera_past_far and start_controls_near,
		"zero extent and camera/start near planes at or beyond far produce no log-Z volume span")
	var service_source := FileAccess.get_file_as_string(
		"res://addons/feng-fog/rendering/feng_volumetric_fog_gpu_service.gd")
	var range_check_position := service_source.find("Codec.has_valid_volume_depth_range")
	var pipeline_setup_position := service_source.find("if not _ensure_pipelines(rd)")
	require(range_check_position >= 0 and pipeline_setup_position > range_check_position
		and service_source.contains("_release_state_for(buffers, rd)"),
		"invalid far ranges clear output and release prior state before allocating GPU resources")


func test_history_miss_supersampling() -> void:
	require(VolumetricFogCodec.normalize_history_miss_count(0) == 1
		and VolumetricFogCodec.normalize_history_miss_count(1) == 1
		and VolumetricFogCodec.normalize_history_miss_count(5) == 8
		and VolumetricFogCodec.normalize_history_miss_count(16) == 16,
		"history-miss author settings normalize to UE sample tiers")
	var inside_history := Vector3(0.5, 0.5, 0.5)
	var outside_history := Vector3(1.01, 0.5, 0.5)
	require(VolumetricFogCodec.history_miss_sample_count(false, inside_history) == 4
		and VolumetricFogCodec.history_miss_sample_count(true, inside_history) == 1
		and VolumetricFogCodec.history_miss_sample_count(true, outside_history) == 4,
		"UE history miss selects four samples for invalid/out-of-bounds history and one for a hit")
	require(VolumetricFogCodec.history_miss_sample_count(false, inside_history, 1) == 1
		and VolumetricFogCodec.history_miss_sample_count(false, inside_history, 5) == 8
		and VolumetricFogCodec.history_miss_sample_count(false, inside_history, 9) == 16,
		"history miss quality follows UE's 1/4/8/16 sample tiers")
	var frame_number := 37
	var offsets := VolumetricFogCodec.history_miss_sample_offsets(frame_number)
	var expected_offsets: Array[Vector3] = []
	for sample_index in 4:
		expected_offsets.append(VolumetricFogCodec.sample_offset(frame_number - sample_index))
	var all_in_cell := offsets.size() == 4
	var distinct_count := 0
	for sample_index in offsets.size():
		var offset := offsets[sample_index]
		all_in_cell = all_in_cell and offset.x >= 0.0 and offset.x < 1.0 \
				and offset.y >= 0.0 and offset.y < 1.0 and offset.z >= 0.0 and offset.z < 1.0
		if offset.distance_to(Vector3(0.5, 0.5, 0.5)) > 1.0e-5:
			distinct_count += 1
	require(all_in_cell and offsets == expected_offsets and distinct_count == 4,
		"history misses walk four distinct UE Halton XYZ offsets including wrapped prior frame indices")
	var wrapped_offsets := VolumetricFogCodec.history_miss_sample_offsets(0)
	var wrapped_expected: Array[Vector3] = [
		VolumetricFogCodec.sample_offset(0), VolumetricFogCodec.sample_offset(-1),
		VolumetricFogCodec.sample_offset(-2), VolumetricFogCodec.sample_offset(-3),
	]
	require(wrapped_offsets == wrapped_expected
		and VolumetricFogCodec.sample_offset(-1) == VolumetricFogCodec.sample_offset(1023),
		"the Halton frame counter wraps before masking just like UE's unsigned frame sequence")
	var centered_offsets := VolumetricFogCodec.history_miss_sample_offsets(frame_number, 4, false)
	var jitter_off_is_centered := centered_offsets.size() == 4
	for offset in centered_offsets:
		jitter_off_is_centered = jitter_off_is_centered and offset.is_equal_approx(Vector3(0.5, 0.5, 0.5))
	require(jitter_off_is_centered,
		"UE jitter disabled mode uses the voxel center for every requested sample")
	var bounded_medium := VolumetricFogCodec.normalize_volume_packet({
		"enabled": true, "albedo": Vector3(2.0, 0.5, -1.0), "emissive": Vector3(3.0, 0.0, 0.0),
	})
	require(bounded_medium.get("albedo") == Vector3(1.0, 0.5, 0.0)
		and bounded_medium.get("emissive") == Vector3(3.0, 0.0, 0.0),
		"global scattering albedo is UNorm-bounded while emissive remains HDR")


func test_quality_profiles() -> void:
	var medium := VolumetricFogCodec.normalize_volume_packet({"enabled": true})
	var high := VolumetricFogCodec.normalize_volume_packet({"enabled": true, "quality": 1})
	var cinematic := VolumetricFogCodec.normalize_volume_packet({"enabled": true, "quality": 2})
	var cinematic_override := VolumetricFogCodec.normalize_volume_packet({
		"enabled": true, "quality": 2, "history_miss_supersample_count": 4,
		"history_miss_supersample_override": true,
	})
	require(medium.froxel_pixel_size == 16 and medium.froxel_depth == 64
		and medium.history_miss_supersample_count == 4
		and high.froxel_pixel_size == 8 and high.froxel_depth == 128
		and high.history_miss_supersample_count == 4
		and cinematic.froxel_pixel_size == 4 and cinematic.froxel_depth == 128
		and cinematic.history_miss_supersample_count == 16
		and cinematic_override.history_miss_supersample_count == 4,
		"quality presets resolve matching froxel grids and automatic or explicit miss-sample counts")
	var packet := VolumetricFogCodec.make_sampling_packet(Vector3i(25, 17, 128), 2,
			0.0, 80.0, 0.05, 1.0, int(cinematic.froxel_pixel_size))
	require(packet.size() == VolumetricFogCodec.SAMPLE_PACKET_FLOATS
		and is_equal_approx(packet[3], 4.0)
		and int(packet[4]) == 25 and int(packet[6]) == 128,
		"sampling packet publishes the same dynamic XY pixel size and Z slices as the selected quality")
	var projection := Projection.create_perspective(70.0, 1.6, 0.05, 200.0)
	var frame := {
		"camera_transform": Transform3D.IDENTITY,
		"previous_camera_transform": Transform3D.IDENTITY,
		"inverse_projection_unjittered": projection.inverse(),
		"previous_projection_unjittered": projection,
		"projection": projection, "inverse_projection": projection.inverse(),
		"near_plane_m": 0.05, "far_plane_m": 200.0,
		"internal_size": Vector2i(100, 70), "eye_offset": Vector3.ZERO,
		"scene_normalization": 1.0, "view_index": 0,
	}
	var frame_ubo := VolumetricFogCodec.pack_frame_uniform(frame, {}, cinematic,
			Vector3i(25, 18, 128), 1, 1.0, true)
	require(frame_ubo.size() == VolumetricFogCodec.FRAME_UNIFORM_FLOATS
		and is_equal_approx(frame_ubo[143], 4.0),
		"the frame UBO uses the selected pixel footprint for depth/lighting and history reprojection")
	var service_source := FileAccess.get_file_as_string(
		"res://addons/feng-fog/rendering/feng_volumetric_fog_gpu_service.gd")
	require(service_source.contains("volume.get(\"froxel_pixel_size\"")
		and service_source.contains("volume.get(\"froxel_depth\"")
		and service_source.contains("state.froxel_depth = froxel_depth"),
		"the quality profile controls GPU grid allocation and history compatibility, not only UI metadata")


func test_projection_depth_contract() -> void:
	var unjittered := Projection.create_perspective(70.0, 1.6, 0.05, 200.0)
	var inverse_unjittered := unjittered.inverse()
	var jittered_a := _jitter_projection(unjittered, Vector2(0.08, -0.05))
	var jittered_b := _jitter_projection(unjittered, Vector2(-0.04, 0.07))
	var fixed_view_position := Vector3(1.2, 0.4, -7.0)
	var unjittered_uv := _project_uv(unjittered, fixed_view_position)
	var recovered_fixed_position := _unproject_device_depth(inverse_unjittered, unjittered_uv,
			_project_device_depth(unjittered, fixed_view_position))
	var fixed_view_position_again := recovered_fixed_position
	var depth_uv_a := _project_uv(jittered_a, fixed_view_position)
	var depth_uv_b := _project_uv(jittered_b, fixed_view_position)
	require(recovered_fixed_position.distance_to(fixed_view_position) < 0.0001
		and fixed_view_position.distance_to(fixed_view_position_again) < 0.0001
		and depth_uv_a.distance_to(depth_uv_b) > 0.01,
		"TAA jitter must move depth UV without moving fixed froxel position: unjittered=%s rec=%s uv=(%s,%s) delta=%s" % [
			unjittered_uv, recovered_fixed_position, depth_uv_a, depth_uv_b,
			depth_uv_a.distance_to(depth_uv_b)])
	var recovered_a := _unproject_device_depth(jittered_a.inverse(), depth_uv_a,
			_project_device_depth(jittered_a, fixed_view_position))
	var recovered_b := _unproject_device_depth(jittered_b.inverse(), depth_uv_b,
			_project_device_depth(jittered_b, fixed_view_position))
	require(recovered_a.distance_to(fixed_view_position) < 0.0001
		and recovered_b.distance_to(fixed_view_position) < 0.0001,
		"jittered depth reconstruction mismatch: a=%s b=%s original=%s err=(%s,%s)" % [
			recovered_a, recovered_b, fixed_view_position,
			recovered_a.distance_to(fixed_view_position), recovered_b.distance_to(fixed_view_position)])
	var frame := {
		"abi_version": 1, "valid": true, "frame_generation": 4, "camera_generation": 1,
		"view_index": 0, "view_count": 1, "internal_size": Vector2i(160, 90),
		"projection": jittered_a, "inverse_projection": jittered_a.inverse(),
		"previous_projection": jittered_b, "previous_inverse_projection": jittered_b.inverse(),
		"projection_unjittered": unjittered,
		"inverse_projection_unjittered": inverse_unjittered,
		"previous_projection_unjittered": unjittered,
		"camera_transform": Transform3D.IDENTITY,
		"previous_camera_transform": Transform3D.IDENTITY,
		"camera_origin": Vector3.ZERO, "near_plane_m": 0.05, "far_plane_m": 200.0,
		"pre_exposure": 1.0, "scene_normalization": 1.0,
	}
	var normalized := VolumetricFogCodec.normalize_frame_inputs(frame, 0)
	var volume := {
		"start_distance": 0.0, "far_distance": 60.0, "near_fade_in_distance": 0.0,
		"albedo": Vector3.ONE, "emissive": Vector3.ZERO,
		"extinction_scale": 1.0, "scattering_distribution": 0.2,
	}
	var packed := VolumetricFogCodec.pack_frame_uniform(normalized, {}, volume,
			Vector3i(10, 6, 64), 4, 1.0, false, 1.0, true, false)
	var frame_with_other_jitter: Dictionary = frame.duplicate()
	frame_with_other_jitter["projection"] = jittered_b
	frame_with_other_jitter["inverse_projection"] = jittered_b.inverse()
	var normalized_other_jitter := VolumetricFogCodec.normalize_frame_inputs(
			frame_with_other_jitter, 0)
	var packed_other_jitter := VolumetricFogCodec.pack_frame_uniform(normalized_other_jitter,
			{}, volume, Vector3i(10, 6, 64), 4, 1.0, false, 1.0, true, false)
	require(not normalized.is_empty() and packed.size() == VolumetricFogCodec.FRAME_UNIFORM_FLOATS,
		"frame codec must accept native jittered/unjittered matrices and pack the full depth-constrained UBO")
	if packed.size() == VolumetricFogCodec.FRAME_UNIFORM_FLOATS:
		var inverse_axis: Vector4 = inverse_unjittered[2]
		var jittered_axis: Vector4 = jittered_a[2]
		require(is_equal_approx(packed[8], inverse_axis.x)
			and is_equal_approx(packed[9], inverse_axis.y)
			and is_equal_approx(packed[64 + 8], jittered_axis.x)
			and is_equal_approx(packed[64 + 9], jittered_axis.y)
			and packed_other_jitter.size() == packed.size()
			and _float_arrays_equal_approx(packed.slice(0, 16), packed_other_jitter.slice(0, 16))
			and not _float_arrays_equal_approx(packed.slice(64, 80), packed_other_jitter.slice(64, 80)),
			"volume UBO must keep unjittered inverse projection separate from jittered depth projection")
	var light_direction := Vector3(0.2, -0.1, -1.0).normalized()
	var orthographic_ray_a := _phase_view_ray(Vector3(-4.0, 2.0, -9.0), true)
	var orthographic_ray_b := _phase_view_ray(Vector3(5.0, -3.0, -9.0), true)
	var orthographic_phase_a := _henyey_greenstein(0.5, light_direction.dot(orthographic_ray_a))
	var orthographic_phase_b := _henyey_greenstein(0.5, light_direction.dot(orthographic_ray_b))
	require(orthographic_ray_a == Vector3(0.0, 0.0, -1.0)
		and orthographic_ray_a == orthographic_ray_b
		and is_equal_approx(orthographic_phase_a, orthographic_phase_b),
		"orthographic view direction and volume phase must remain fixed across froxel XY positions")


func test_eye_offset_history_continuity() -> void:
	var service: RefCounted = VolumetricFogGPUService.new()
	var projection := Projection.create_perspective(70.0, 1.6, 0.05, 200.0)
	var prior_eye_offset := Vector3(0.25, -0.5, 0.75)
	var frame := {
		"camera_generation": 4,
		"environment_id": 12,
		"render_target_id": 19,
		"frame_generation": 101,
		"camera_origin": Vector3(0.5, 0.0, 0.0),
		"camera_transform": Transform3D(Basis.IDENTITY, Vector3(0.5, 0.0, 0.0)),
		"projection": projection,
		"projection_unjittered": projection,
		"eye_offset": prior_eye_offset,
	}
	var state := {
		"history_valid": true,
		"size": Vector2i(320, 180),
		"view_count": 1,
		"camera_generation": 4,
		"environment_id": 12,
		"render_target_id": 19,
		"froxel_pixel_size": 16,
		"froxel_depth": 64,
		"last_frame_generation": 100,
		"signature": "stable-sources",
		"camera_origin": Vector3.ZERO,
		"camera_basis": Basis.IDENTITY,
		"projection_unjittered": projection,
		"eye_offsets": [prior_eye_offset],
	}
	var volume := {"distance": 60.0, "froxel_pixel_size": 16, "froxel_depth": 64}
	var frames: Array[Dictionary] = [frame]
	var fixed_offset_after_camera_motion: bool = service._history_contiguous(
		state, frames, Vector2i(320, 180), 1, "stable-sources", volume)
	frame["eye_offset"] = prior_eye_offset + Vector3(0.001, 0.0, 0.0)
	frames[0] = frame
	var changed_offset_by_one_mm: bool = service._history_contiguous(
		state, frames, Vector2i(320, 180), 1, "stable-sources", volume)
	var missing_prior_view_offset := state.duplicate(true)
	missing_prior_view_offset["eye_offsets"] = []
	var missing_offset_frames: Array[Dictionary] = [frame]
	var missing_offset_state_is_rejected: bool = not service._history_contiguous(
		missing_prior_view_offset, missing_offset_frames, Vector2i(320, 180), 1,
		"stable-sources", volume)
	require(fixed_offset_after_camera_motion and not changed_offset_by_one_mm
		and missing_offset_state_is_rejected,
		"history may reproject ordinary camera motion, but a millimeter eye-offset change or missing prior-view offset invalidates it")
	var service_source := FileAccess.get_file_as_string(
		"res://addons/feng-fog/rendering/feng_volumetric_fog_gpu_service.gd")
	require(service_source.contains("previous_offset.distance_to(current_offset) > 1.0e-5"),
		"multiview history must compare stored and current 3D eye offsets at the 1e-5 meter tolerance")


func _jitter_projection(source: Projection, jitter: Vector2) -> Projection:
	var result := source
	var depth_column: Vector4 = result[2]
	depth_column.x += jitter.x
	depth_column.y += jitter.y
	result[2] = depth_column
	return result


func _project_uv(projection: Projection, view_position: Vector3) -> Vector2:
	var clip := projection * Vector4(view_position.x, view_position.y, view_position.z, 1.0)
	return Vector2(clip.x, clip.y) / maxf(clip.w, 1.0e-8) * 0.5 + Vector2(0.5, 0.5)


func _project_device_depth(projection: Projection, view_position: Vector3) -> float:
	var clip := projection * Vector4(view_position.x, view_position.y, view_position.z, 1.0)
	return clip.z / maxf(clip.w, 1.0e-8)


func _unproject_device_depth(inverse_projection: Projection, uv: Vector2,
		device_depth: float) -> Vector3:
	var clip_position := Vector4(uv.x * 2.0 - 1.0, uv.y * 2.0 - 1.0, device_depth, 1.0)
	var view_h := inverse_projection * clip_position
	return Vector3(view_h.x, view_h.y, view_h.z) / maxf(view_h.w, 1.0e-8)


func _phase_view_ray(view_position: Vector3, orthographic: bool) -> Vector3:
	return Vector3(0.0, 0.0, -1.0) if orthographic else view_position.normalized()


func _henyey_greenstein(g: float, cosine_theta: float) -> float:
	var clamped_g := clampf(g, -0.99, 0.99)
	var denominator := maxf(1.0 + clamped_g * clamped_g
			- 2.0 * clamped_g * clampf(cosine_theta, -1.0, 1.0), 1.0e-6)
	return (1.0 - clamped_g * clamped_g) \
			/ (4.0 * PI * denominator * sqrt(denominator))


func _float_arrays_equal_approx(left: PackedFloat32Array,
		right: PackedFloat32Array) -> bool:
	if left.size() != right.size():
		return false
	for index in left.size():
		if not is_equal_approx(left[index], right[index]):
			return false
	return true


func _integrate_uniform_fog(z_params: Vector3, slice_count: int,
		extinction: float, source_radiance: float) -> Vector2:
	var previous_depth := VolumetricFogCodec.depth_from_z_slice(z_params, 0.0)
	var transmittance := 1.0
	var radiance := 0.0
	for z in slice_count:
		var center_depth := VolumetricFogCodec.depth_from_z_slice(z_params, float(z) + 0.5)
		var step_length := center_depth - previous_depth
		var slice_transmittance := exp(-extinction * step_length)
		radiance += source_radiance * ((1.0 - slice_transmittance) / extinction) * transmittance
		transmittance *= slice_transmittance
		previous_depth = center_depth
	return Vector2(radiance, transmittance)


func test_fsss_kernel_contract() -> void:
	var filter_source := FileAccess.get_file_as_string(
		"res://addons/feng-fog/rendering/shaders/fsss_filter.glslinc")
	var downsample_source := FileAccess.get_file_as_string(
		"res://addons/feng-fog/rendering/shaders/fsss_downsample.glslinc")
	var upsample_source := FileAccess.get_file_as_string(
		"res://addons/feng-fog/rendering/shaders/fsss_upsample.glslinc")
	var sampling_source := FileAccess.get_file_as_string(
		"res://addons/feng-render-pipeline/library/height-fog/volumetric_fog_sampling.glslinc")
	var source_generation := FileAccess.get_file_as_string(
		"res://addons/feng-fog/rendering/shaders/fsss_reproject.glslinc")
	require(filter_source.contains("FSSS_SAMPLE_OFFSETS[9]")
		and filter_source.contains("FSSS_SAMPLE_WEIGHTS[9]")
		and filter_source.contains("MAX_EXPOSED_LUMINANCE = 10.0")
		and filter_source.contains("FSSS_SAMPLE_WEIGHTS[index]"),
		"FSSS filter must use UE's nine weighted bilinear samples and per-channel luminance cap")
	require(downsample_source.contains("vec2(-1.0, -1.0)")
		and downsample_source.contains("vec2(1.0, 1.0)"),
		"FSSS 4-tap downsample must use UE's one-source-texel diagonal offsets")
	require(upsample_source.contains("mix(current.rgb, coarser.rgb")
		and upsample_source.contains("upsample_control.values.x"),
		"FSSS upsample must use BlurControl to blend the next coarser level")
	require(FsssGPUService.mip_count_for_size(Vector2i(1, 1)) == 1
		and FsssGPUService.mip_count_for_size(Vector2i(8, 8)) == 4
		and FsssGPUService.mip_count_for_size(Vector2i(1024, 512)) == 11
		and FsssGPUService.mip_count_for_size(Vector2i(9, 5)) == 4,
		"FSSS pyramid must allocate a complete mip chain through 1x1 for square and rectangular targets")
	require(sampling_source.contains("float feng_fsss_blur_fade")
		and sampling_source.contains("clamp(feng_fsss_blur_width(transmittance, scene_depth_m), 0.0, 1.0)"),
		"FSSS final source must fade by saturate(W), matching UE's full-resolution composition")
	require(sampling_source.contains("sqrt(max(0.375 * scene_depth_m * scene_depth_m * optical_depth, 0.0))"),
		"FSSS W must use UE's simplified uniform-medium PSF for albedo 1 and g 0")
	require(sampling_source.contains("float feng_fsss_blur_mip(float fog_transmittance, float final_transmittance")
		and sampling_source.contains("1.0 - final_transmittance")
		and sampling_source.contains("feng_fsss_blur_width(fog_transmittance, scene_depth_m)"),
		"FSSS mip coverage must use FinalT while W continues using raw fog transmittance")
	require(source_generation.contains("combined_transmittance * (1.0 - amount)")
		and source_generation.contains("imageStore(fsss_depth_output, pixel, vec4(current_depth))"),
		"FSSS alpha must retain final transmittance while history depth stays in its own texture")
	require(source_generation.contains("fsss_apply_aerial_perspective(device_depth")
		and source_generation.contains("radiance * max(feng_volume_sampling.frame_control.y, 1.0e-8)")
		and source_generation.contains("fsss_frame.extent_depth.w < 0.5"),
		"Inline FSSS source must use the same pre-fog aerial-perspective scene domain as HeightFog")
	var inline_composite := FileAccess.get_file_as_string(
		"res://addons/feng-render-pipeline/library/height-fog/height_fog.glsl")
	var late_composite := FileAccess.get_file_as_string(
		"res://addons/feng-fog/rendering/shaders/volumetric_fog_composite.glslinc")
	require(inline_composite.contains("if (fsss_requested && !(fsss_width > 0.0))")
		and late_composite.contains("if (fsss_requested && !(fsss_width > 0.0))")
		and inline_composite.contains("imageStore(color_image, pixel, scene_color)")
		and late_composite.contains("imageStore(color_image, pixel, scene)"),
		"FSSS W<=0 must clip with a no-write result and preserve the existing inline or cloud-composited scene")
	var weights := [0.00366, 0.01465, 0.02564, 0.01465, 0.00366,
		0.01465, 0.05861, 0.09523, 0.05861, 0.01465,
		0.02564, 0.09523, 0.15018, 0.09523, 0.02564,
		0.01465, 0.05861, 0.09523, 0.05861, 0.01465,
		0.00366, 0.01465, 0.02564, 0.01465, 0.00366]
	var coordinate_offsets := [-2.0, -1.0, 0.0, 1.0, 2.0]
	var groups := [Vector4i(0, 1, 0, 1), Vector4i(2, 3, 0, 1), Vector4i(4, 4, 0, 1),
		Vector4i(0, 1, 2, 3), Vector4i(2, 3, 2, 3), Vector4i(4, 4, 2, 3),
		Vector4i(0, 1, 4, 4), Vector4i(2, 3, 4, 4), Vector4i(4, 4, 4, 4)]
	var expected_weights := [0.09157, 0.19413, 0.01831,
		0.19413, 0.39925, 0.04029, 0.01831, 0.04029, 0.00366]
	var expected_offsets := [Vector2(-1.1999563, -1.1999563), Vector2(0.3773760, -1.2075413),
		Vector2(2.0, -1.1998908), Vector2(-1.2075413, 0.3773760),
		Vector2(0.3853225, 0.3853225), Vector2(2.0, 0.3636138),
		Vector2(-1.1998908, 2.0), Vector2(0.3636138, 2.0), Vector2(2.0, 2.0)]
	for index in groups.size():
		var group: Vector4i = groups[index]
		var weight_sum := 0.0
		var weighted_offset := Vector2.ZERO
		for y in range(group.z, group.w + 1):
			for x in range(group.x, group.y + 1):
				var weight: float = weights[y * 5 + x]
				weight_sum += weight
				weighted_offset += Vector2(coordinate_offsets[x], coordinate_offsets[y]) * weight
		var centroid := weighted_offset / weight_sum
		require(is_equal_approx(weight_sum, expected_weights[index])
			and centroid.distance_to(expected_offsets[index]) < 0.0001,
			"UE Gaussian group %d must retain its bilinear centroid and weight" % index)
	var filtered_at_control_zero := Vector3(1.0, 0.0, 0.0)
	var filtered_coarser := Vector3(0.0, 0.0, 1.0)
	var filtered_at_control_one := filtered_at_control_zero.lerp(filtered_coarser, 1.0)
	require(not filtered_at_control_zero.is_equal_approx(filtered_at_control_one),
		"BlurControl 0 and 1 must produce different mip-chain values")
	var zero_width_fade := clampf(sqrt(maxf(0.375 * 0.0 * 0.0, 0.0)), 0.0, 1.0)
	var subpixel_width_fade := clampf(0.5, 0.0, 1.0)
	require(is_zero_approx(zero_width_fade) and is_equal_approx(subpixel_width_fade, 0.5),
		"UE's W fade must suppress a zero PSF width and preserve fractional subpixel width")
