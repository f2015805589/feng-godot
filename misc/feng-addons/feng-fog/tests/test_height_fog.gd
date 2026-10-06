extends SceneTree
## CPU-only contracts for Feng's Unreal 5.8 exponential height fog path.

const FengHeightFog = preload("res://addons/feng-fog/feng_height_fog.gd")
const FengFogRuntime = preload("res://addons/feng-fog/feng_fog_runtime.gd")
const FengSkyRuntime = preload("res://addons/feng-sky/feng_sky_runtime.gd")
const LUMA := Vector3(0.2126, 0.7152, 0.0722)

class SkyProvider extends RefCounted:
	var world_id: int
	var active := true

	func _feng_sky_runtime_is_active(candidate_world_id: int) -> bool:
		return active and candidate_world_id == world_id

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

	FengSkyRuntime.remove_snapshot(provider_a, world_a_id)
	FengSkyRuntime.remove_snapshot(provider_b, world_b_id)
	viewport_a.free()
	viewport_b.free()
	viewport_c.free()
	if _failures == 0:
		print("PASS Unreal height fog physical_units=", physical, " checks=", _checks)
	else:
		print("Feng Unreal height fog tests failed: ", _failures, " / ", _checks)
	quit(1 if _failures > 0 else 0)
