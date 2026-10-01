extends SceneTree
## Run with physical units enabled and disabled in project.godot before startup.
## These CPU snapshot tests do not require a graphics device or exposure setup.

const FengHeightFog = preload("res://addons/feng-fog/feng_height_fog.gd")
const FengFogRuntime = preload("res://addons/feng-fog/feng_fog_runtime.gd")
const FengSkyRuntime = preload("res://addons/feng-sky/feng_sky_runtime.gd")
const INV_FOUR_PI := 1.0 / (4.0 * PI)

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


func linear_rgb(color: Color) -> Vector3:
	var linear := color.srgb_to_linear()
	return Vector3(linear.r, linear.g, linear.b)


func sun_irradiance(sun: DirectionalLight3D, physical: bool) -> Vector3:
	var color := linear_rgb(sun.light_color)
	if physical:
		color *= linear_rgb(sun.get_correlated_color())
	var energy := sun.light_energy * (sun.light_intensity_lux if physical else PI)
	return color * energy


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


func publish_sky(provider: SkyProvider, sun_id: int, ambient: Vector3,
		ground: Vector3, contribution: float = 1.0, affect_fog: bool = true) -> void:
	FengSkyRuntime.publish_snapshot(provider, provider.world_id, {
		"ambient_radiance": ambient,
		"height_fog_contribution": contribution,
		"sun_light_id": sun_id,
		"sun_ground_illuminance": ground,
		"affect_height_fog": affect_fog,
	})


func run() -> void:
	var physical := bool(ProjectSettings.get_setting(
		"rendering/lights_and_shadows/use_physical_light_units", false))
	var viewport_a := make_viewport()
	var viewport_b := make_viewport()
	var sun := DirectionalLight3D.new()
	sun.light_color = Color(0.9, 0.6, 0.4)
	sun.light_temperature = 7000.0
	sun.light_intensity_lux = 6.0
	viewport_a.add_child(sun)
	var fog := FengHeightFog.new()
	fog.sun_light = sun
	viewport_a.add_child(fog)
	var unlit_fog := FengHeightFog.new()
	viewport_b.add_child(unlit_fog)
	var world_a_id := viewport_a.world_3d.get_instance_id()
	var world_b_id := viewport_b.world_3d.get_instance_id()

	require(fog.fog_color_mode == FengHeightFog.ColorMode.LIT
		and fog.fog_inscattering_color == Color.WHITE
		and fog.sky_atmosphere_ambient_contribution_color_scale == Color.WHITE,
		"new fog must default to lit white and neutral sky-ambient scale")
	var unlit := snapshot_for(unlit_fog)
	require_vec(unlit.get("fog_color", Vector3.INF), Vector3.ZERO, "no sky or sun must not emit")
	require_vec(unlit.get("inscattering_color", Vector3.INF), Vector3.ZERO, "no sun must disable its lobe")
	require(float(unlit.get("fog_density", 0.0)) > 0.0
		and float(unlit.get("inscattering_start", 0.0)) < 0.0,
		"unlit fog must retain extinction while disabling the sun lobe")

	fog.fog_inscattering_color = Color(0.65, 0.4, 0.2)
	fog.directional_inscattering_color = Color(0.3, 0.5, 0.8)
	var albedo := linear_rgb(fog.fog_inscattering_color)
	var tint := Vector3(0.3, 0.5, 0.8)
	var low := snapshot_for(fog)
	var low_sun := sun_irradiance(sun, physical)
	require_vec(low.get("fog_albedo", Vector3.INF), albedo, "material color must be converted from sRGB once")
	require_vec(low.get("fog_color", Vector3.INF), albedo * low_sun * INV_FOUR_PI,
		"sun-only lit source must be RGB irradiance times albedo and isotropic phase")
	require_vec(low.get("inscattering_color", Vector3.INF), tint * low_sun.dot(Vector3(0.2126, 0.7152, 0.0722)),
		"sun lobe must keep its independent artist color and original sun-luminance scaling")

	sun.light_intensity_lux = 60000.0
	var high := snapshot_for(fog)
	var lux_ratio := 10000.0 if physical else 1.0
	require_vec(high.get("fog_color", Vector3.INF), (low["fog_color"] as Vector3) * lux_ratio,
		"6 to 60000 lux must scale the source linearly only with physical units")
	require_vec(high.get("inscattering_color", Vector3.INF), (low["inscattering_color"] as Vector3) * lux_ratio,
		"6 to 60000 lux must preserve directional color ratios")
	sun.light_energy = 2.0
	var doubled := snapshot_for(fog)
	require_vec(doubled.get("fog_color", Vector3.INF), (high["fog_color"] as Vector3) * 2.0,
		"artist light energy must scale the base source exactly once")
	require_vec(doubled.get("inscattering_color", Vector3.INF), (high["inscattering_color"] as Vector3) * 2.0,
		"artist light energy must scale the lobe exactly once")
	sun.light_energy = 1.0
	var raw_sun := sun_irradiance(sun, physical)

	fog.fog_inscattering_color = Color.BLACK
	var black := snapshot_for(fog)
	require_vec(black.get("fog_color", Vector3.INF), Vector3.ZERO, "black albedo must absorb at 60000 lux")
	require_vec(black.get("inscattering_color", Vector3.INF), high["inscattering_color"], "black base must not disable the independent sun lobe")
	fog.fog_inscattering_color = Color(2.0, -1.0, 0.5)
	require_vec(fog.snapshot_fields().get("fog_albedo", Vector3.INF), Vector3(1.0, 0.0, 0.21404114),
		"lit material albedo must clamp to 0..1 before sRGB conversion")
	fog.fog_inscattering_color = Color(0.65, 0.4, 0.2)
	sun.visible = false
	var hidden := snapshot_for(fog)
	require_vec(hidden.get("fog_color", Vector3.INF), Vector3.ZERO, "hidden sun must not illuminate fog")
	require_vec(hidden.get("inscattering_color", Vector3.INF), Vector3.ZERO, "hidden sun must not retain its lobe")
	sun.visible = true
	sun.light_negative = true
	var negative := snapshot_for(fog)
	require_vec(negative.get("fog_color", Vector3.INF), Vector3.ZERO, "negative light must not create negative lit scattering")
	require_vec(negative.get("inscattering_color", Vector3.INF), -high["inscattering_color"],
		"negative light must retain the original signed artist-lobe behavior")
	sun.light_negative = false

	var provider_a := SkyProvider.new()
	provider_a.world_id = world_a_id
	var provider_b := SkyProvider.new()
	provider_b.world_id = world_b_id
	var ambient := Vector3(2.0, 4.0, 8.0)
	var ground := Vector3(3.0, 5.0, 7.0)
	publish_sky(provider_a, sun.get_instance_id(), ambient, ground, 0.25)
	var matched := snapshot_for(fog)
	require_vec(matched.get("fog_color", Vector3.INF), albedo * (ambient * 0.25 + raw_sun * INV_FOUR_PI),
		"matching atmosphere must not apply transmission absent from scene surface lighting")
	require_vec(matched.get("inscattering_color", Vector3.INF), tint * raw_sun.dot(Vector3(0.2126, 0.7152, 0.0722)),
		"matching atmosphere must not change the independent lobe")
	var ambient_color_scale := Vector3(0.25, 0.5, 2.0)
	fog.sky_atmosphere_ambient_contribution_color_scale = Color(0.25, 0.5, 2.0)
	var color_scaled_ambient := snapshot_for(fog)
	require_vec(color_scaled_ambient.get("fog_color", Vector3.INF),
		albedo * (ambient * 0.25 * ambient_color_scale + raw_sun * INV_FOUR_PI),
		"sky atmosphere RGB scale must tint only sky ambient and leave author base/sun source alone")
	require_vec(color_scaled_ambient.get("inscattering_color", Vector3.INF), matched["inscattering_color"],
		"sky atmosphere RGB scale must not affect the independent directional lobe")
	fog.sky_atmosphere_ambient_contribution_color_scale = Color.WHITE
	require_vec(snapshot_for(unlit_fog).get("fog_color", Vector3.INF), Vector3.ZERO,
		"world A sky must not leak into world B")
	publish_sky(provider_b, 0, Vector3(11.0, 13.0, 17.0), Vector3.ZERO)
	require_vec(snapshot_for(unlit_fog).get("fog_color", Vector3.INF), Vector3(11.0, 13.0, 17.0),
		"sky alone must illuminate white fog without a selected sun")
	require_vec(snapshot_for(fog).get("fog_color", Vector3.INF), matched["fog_color"],
		"publishing another world's sky must leave this world unchanged")

	publish_sky(provider_a, 0, ambient, ground)
	var mismatched := snapshot_for(fog)
	require_vec(mismatched.get("fog_color", Vector3.INF), albedo * (ambient + raw_sun * INV_FOUR_PI),
		"a different atmosphere sun must not attenuate the selected fog light")
	require_vec(mismatched.get("inscattering_color", Vector3.INF), tint * raw_sun.dot(Vector3(0.2126, 0.7152, 0.0722)),
		"a different atmosphere sun must not replace the lobe irradiance")
	publish_sky(provider_a, sun.get_instance_id(), ambient, ground, 0.0)
	require_vec(snapshot_for(fog).get("fog_color", Vector3.INF), albedo * raw_sun * INV_FOUR_PI,
		"zero sky contribution must suppress only ambient, retaining the selected scene light")
	publish_sky(provider_a, sun.get_instance_id(), ambient, ground, 1.0, false)
	require_vec(snapshot_for(fog).get("fog_color", Vector3.INF), albedo * raw_sun * INV_FOUR_PI,
		"disabled sky-to-fog must remove ambient without changing direct light")


	# Regression: the user's horizontal sun has zero atmospheric ground
	# irradiance. This must not erase the white fog body or its orange lobe.
	publish_sky(provider_a, sun.get_instance_id(), ambient, Vector3.ZERO)
	fog.fog_inscattering_color = Color.WHITE
	var horizon := snapshot_for(fog)
	require_vec(horizon.get("fog_color", Vector3.INF), ambient + raw_sun * INV_FOUR_PI,
		"zero horizon ground irradiance must retain the white direct-scattering body")
	require_vec(horizon.get("inscattering_color", Vector3.INF), high["inscattering_color"],
		"changing base color to white must not recolor the artist lobe")
	fog.directional_inscattering_color = Color.BLACK
	require_vec(snapshot_for(fog).get("fog_color", Vector3.INF), horizon["fog_color"],
		"disabling the directional lobe must leave the base body unchanged")
	require_vec(snapshot_for(fog).get("inscattering_color", Vector3.INF), Vector3.ZERO,
		"black directional color must disable only the artist lobe")
	fog.fog_inscattering_color = Color(0.65, 0.4, 0.2)
	fog.directional_inscattering_color = Color(0.3, 0.5, 0.8)
	publish_sky(provider_a, sun.get_instance_id(), ambient, ground, 0.25)
	fog.fog_color_mode = FengHeightFog.ColorMode.LEGACY_RADIANCE
	var legacy := snapshot_for(fog)
	var authored := Vector3(0.65, 0.4, 0.2)
	var authored_tint := Vector3(0.3, 0.5, 0.8)
	var luminance := raw_sun.dot(Vector3(0.2126, 0.7152, 0.0722))
	fog.sky_atmosphere_ambient_contribution_color_scale = Color(0.25, 0.5, 2.0)
	var scaled_legacy := snapshot_for(fog)
	require_vec(scaled_legacy.get("fog_color", Vector3.INF), authored + ambient * 0.25 * ambient_color_scale,
		"sky atmosphere RGB scale must affect only the legacy mode's ambient contribution")
	require_vec(scaled_legacy.get("inscattering_color", Vector3.INF), authored_tint * luminance,
		"sky atmosphere RGB scale must not tint the legacy directional lobe")
	fog.sky_atmosphere_ambient_contribution_color_scale = Color.WHITE
	require(not legacy.has("fog_albedo"), "legacy snapshots must not be treated as material albedo")
	require_vec(legacy.get("fog_color", Vector3.INF), authored + ambient * 0.25,
		"legacy source must remain raw authored RGB plus untinted sky")
	require_vec(legacy.get("inscattering_color", Vector3.INF), authored_tint * luminance,
		"legacy lobe must use raw artist tint and unattenuated sun luminance")
	FengSkyRuntime.remove_snapshot(provider_a, world_a_id)
	sun.visible = false
	require_vec(snapshot_for(fog).get("fog_color", Vector3.INF), authored,
		"legacy source must remain visible without any incident light")
	FengSkyRuntime.remove_snapshot(provider_b, world_b_id)
	viewport_a.free()
	viewport_b.free()
	if _failures == 0:
		print("PASS lit fog physical_units=", physical, " checks=", _checks)
	else:
		print("feng_fog lit tests failed: ", _failures, " / ", _checks)
	quit(1 if _failures > 0 else 0)
