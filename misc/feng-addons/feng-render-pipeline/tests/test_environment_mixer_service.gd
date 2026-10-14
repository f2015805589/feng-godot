extends SceneTree
## Regression coverage for environment-card discovery and create-only defaults.

const ServiceScript = preload("res://addons/feng-render-pipeline/editor/environment_mixer_service.gd")
const WindowScript = preload("res://addons/feng-render-pipeline/editor/environment_mixer_window.gd")

var checks := 0
var failures := 0


func _initialize() -> void:
	call_deferred("run")


func require(p_condition: bool, p_message: String) -> void:
	checks += 1
	if not p_condition:
		failures += 1
		push_error(p_message)


func _test_minimal_property_names() -> void:
	var probes: Dictionary = {
		"DirectionalLight3D": DirectionalLight3D.new(),
		"FengSkyLight": load("res://addons/feng-sky/feng_sky_light.gd").new(),
		"FengSkyAtmosphere": load("res://addons/feng-sky/feng_sky_atmosphere.gd").new(),
		"FengVolumetricCloud": load("res://addons/feng-cloud/feng_volumetric_cloud.gd").new(),
		"FengHeightFog": load("res://addons/feng-fog/feng_height_fog.gd").new(),
	}
	for kind in probes:
		var object: Object = probes[kind]
		var available: Dictionary = {}
		for property_info in object.get_property_list():
			if int(property_info.get("usage", 0)) & PROPERTY_USAGE_EDITOR:
				available[String(property_info.get("name", ""))] = true
		var missing: PackedStringArray = PackedStringArray()
		for property_name in WindowScript.MINIMAL_PROPERTIES.get(kind, []):
			if not available.has(String(property_name)):
				missing.append(String(property_name))
		require(missing.is_empty(), "%s Minimal controls must match real editable properties: %s" % [kind, ", ".join(missing)])
		object.free()


func _test_freed_node_references() -> void:
	var service = ServiceScript.new()
	var environment_window = WindowScript.new()
	var old_root := Node.new()
	var component := Node.new()
	old_root.add_child(component)
	service._scene_root_ref = weakref(old_root)
	service._snapshot_cache = {
		"has_scene": true,
		"scene_root": old_root,
		"components": {&"atmosphere_sun": [{"node": component}]},
	}
	require(not service.call("_snapshot_cache_needs_refresh", old_root),
			"a current snapshot with live root and component references should remain cached")

	component.free()
	require(service.call("_snapshot_cache_needs_refresh", old_root),
			"a cached row whose component was freed must force a rescan before consumers receive it")
	require(environment_window.call("_valid_node", component) == null,
			"the window must reject a freed node reference before assigning it to a typed Node")

	var switched_root := Node.new()
	service._scene_root_ref = weakref(switched_root)
	require(service.call("_snapshot_cache_needs_refresh", switched_root),
			"switching scenes must invalidate a snapshot still rooted in the previous scene")

	var expired_root_ref := weakref(old_root)
	old_root.free()
	service._scene_root_ref = expired_root_ref
	require(service.call("_snapshot_cache_needs_refresh", null),
			"an empty edited scene must clear a snapshot whose weak root reference expired")
	service._snapshot_cache = {"has_scene": false, "scene_root": null, "components": {&"atmosphere_sun": []}}
	service._scene_root_ref = null
	require(not service.call("_snapshot_cache_needs_refresh", null),
			"an already-empty snapshot should stay cached while no scene is open")

	switched_root.free()
	environment_window.free()
	service.free()


func _test_module_visibility() -> void:
	var environment_window = WindowScript.new()
	require(environment_window.call("_initial_size_for_host", Vector2i(1600, 1000)) == Vector2i(1440, 900),
			"the first popup should use 90% of a wide host instead of a fixed narrow size")
	require(environment_window.call("_initial_size_for_host", Vector2i(1000, 700)) == Vector2i(900, 630),
			"the first popup should keep the 90% cap on a smaller host")
	var panels: Dictionary = {}
	for component_id in WindowScript.MODULE_IDS:
		var panel := PanelContainer.new()
		panels[component_id] = panel
		environment_window._columns[component_id] = {"panel": panel}
		require(panel.visible, "%s is visible when the window opens" % String(component_id))
	for component_id in WindowScript.MODULE_IDS:
		environment_window.call("_set_module_visible", component_id, component_id == &"height_fog")
	var visible_ids: Array[StringName] = []
	for component_id in WindowScript.MODULE_IDS:
		if panels[component_id].visible:
			visible_ids.append(component_id)
	require(visible_ids == [&"height_fog"], "module visibility can isolate the Height Fog card without changing other modules")
	environment_window.call("_set_module_visible", &"height_fog", true)
	for panel in panels.values():
		panel.free()
	environment_window.free()


func _test_card_flow_geometry() -> void:
	var host := Control.new()
	get_root().add_child(host)
	var flow := HFlowContainer.new()
	flow.size = Vector2(1200, 900)
	flow.add_theme_constant_override("h_separation", 10)
	host.add_child(flow)
	var cards: Array[PanelContainer] = []
	for index in 5:
		var card := PanelContainer.new()
		card.custom_minimum_size = Vector2(320, 260)
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.size_flags_stretch_ratio = 1.0
		flow.add_child(card)
		cards.append(card)
	await process_frame
	var wide_rows: Dictionary = {}
	for card in cards:
		var row_y := roundi(card.position.y)
		wide_rows[row_y] = int(wide_rows.get(row_y, 0)) + 1
	var wide_counts: Array = wide_rows.values()
	wide_counts.sort()
	require(wide_counts == [2, 3], "five equal-stretch cards fit in two rows on a wide host")
	for row in wide_rows:
		var row_widths: Array[float] = []
		for card in cards:
			if roundi(card.position.y) == row:
				row_widths.append(card.size.x)
		if row_widths.size() > 1:
			for width in row_widths:
				require(is_equal_approx(width, row_widths[0]), "cards in one row share available width equally")

	host.size = Vector2(900, 700)
	flow.size = Vector2(900, 700)
	await process_frame
	var narrow_rows: Dictionary = {}
	for card in cards:
		var row_y := roundi(card.position.y)
		narrow_rows[row_y] = int(narrow_rows.get(row_y, 0)) + 1
	var narrow_counts: Array = narrow_rows.values()
	narrow_counts.sort()
	require(narrow_counts == [1, 2, 2], "the card layout wraps safely on a smaller host")
	for index in cards.size() - 1:
		cards[index].hide()
	flow.size = Vector2(1200, 700)
	host.size = flow.size
	await process_frame
	require(cards[4].visible and is_equal_approx(cards[4].size.x, flow.size.x),
			"the Height Fog card fills the row when it is the only visible module")
	host.free()


func run() -> void:
	var service = ServiceScript.new()
	var definitions: Array[Dictionary] = service.get_component_definitions()
	var expected_ids: Array[StringName] = [
		&"atmosphere_sun", &"sky_light", &"sky_atmosphere", &"volumetric_cloud", &"height_fog",
	]
	var actual_ids: Array[StringName] = []
	for definition in definitions:
		actual_ids.append(definition["id"])
	require(actual_ids == expected_ids, "the mixer must expose exactly the five approved environment categories")
	require(not actual_ids.has(&"magic_gi") and not actual_ids.has(&"rtgi")
			and not actual_ids.has(&"reflect_probe"), "GI and reflection actors must stay outside the environment mixer")
	_test_minimal_property_names()
	_test_freed_node_references()
	_test_module_visibility()
	await _test_card_flow_geometry()

	var root := Node3D.new()
	var atmospheric_sun := DirectionalLight3D.new()
	atmospheric_sun.name = "AtmosphereSun"
	atmospheric_sun.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_AND_SKY
	root.add_child(atmospheric_sun)
	var scene_only_light := DirectionalLight3D.new()
	scene_only_light.name = "SceneOnlyLight"
	scene_only_light.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	root.add_child(scene_only_light)
	var sun_definition: Dictionary = definitions[0]
	var compatible_suns: Array[Node] = service.call("_find_component_nodes", root, sun_definition)
	require(compatible_suns == [atmospheric_sun], "atmospheric-only filtering must exclude Light Only directionals")
	service._atmospheric_only = false
	var all_suns: Array[Node] = service.call("_find_component_nodes", root, sun_definition)
	require(all_suns.size() == 2 and all_suns.has(scene_only_light),
			"disabling the atmospheric-only filter must make scene-only directionals selectable")
	service._atmospheric_only = true
	var preferred_sun := DirectionalLight3D.new()
	preferred_sun.name = "PreferredSun"
	root.add_child(preferred_sun)
	var secondary_sun := DirectionalLight3D.new()
	secondary_sun.name = "SecondarySun"
	root.add_child(secondary_sun)
	var atmosphere_script := load("res://addons/feng-sky/feng_sky_atmosphere.gd") as Script
	var atmosphere: WorldEnvironment
	if atmosphere_script != null:
		atmosphere = atmosphere_script.new() as WorldEnvironment
	if atmosphere != null:
		root.add_child(atmosphere)
		atmosphere.set("sun_light", preferred_sun)
		atmosphere.set("secondary_sun_light", secondary_sun)
	var linked_suns: Array[Node] = service.call("_find_component_nodes", root, sun_definition)
	require(atmosphere != null and linked_suns.size() == 2
			and linked_suns[0] == preferred_sun and not linked_suns.has(secondary_sun),
			"the linked primary sun must sort first and explicit secondary suns must be excluded")

	var sun_defaults := DirectionalLight3D.new()
	service.call("_apply_creation_defaults", sun_defaults, &"atmosphere_sun", root)
	require(is_equal_approx(sun_defaults.light_intensity_lux, 100000.0)
			and sun_defaults.shadow_enabled
			and sun_defaults.rotation_degrees.is_equal_approx(Vector3(-45.0, 0.0, 0.0))
			and sun_defaults.transform.basis.z.y > 0.0,
			"new atmosphere suns must use the explicit physical-light preset and face an upward sky")

	var atmosphere_without_override := WorldEnvironment.new()
	service.call("_apply_creation_defaults", atmosphere_without_override, &"sky_atmosphere", root)
	var physical_attributes := atmosphere_without_override.camera_attributes as CameraAttributesPhysical
	require(physical_attributes != null, "a new atmosphere should provide balanced local physical exposure when the scene has no override")
	if physical_attributes != null:
		require(is_equal_approx(physical_attributes.exposure_aperture, 16.0)
				and is_equal_approx(physical_attributes.exposure_shutter_speed, 100.0)
				and is_equal_approx(physical_attributes.exposure_sensitivity, 100.0)
				and physical_attributes.resource_local_to_scene,
				"the new-scene camera exposure preset must remain local and use f/16, 1/100, ISO 100")

	var camera_root := Node3D.new()
	var camera := Camera3D.new()
	camera.attributes = CameraAttributesPhysical.new()
	camera_root.add_child(camera)
	var atmosphere_with_camera_override := WorldEnvironment.new()
	service.call("_apply_creation_defaults", atmosphere_with_camera_override, &"sky_atmosphere", camera_root)
	require(atmosphere_with_camera_override.camera_attributes == null,
			"creating a new atmosphere must leave an existing camera exposure override in control")

	var environment_root := Node3D.new()
	var existing_world_environment := WorldEnvironment.new()
	existing_world_environment.camera_attributes = CameraAttributesPhysical.new()
	environment_root.add_child(existing_world_environment)
	var atmosphere_with_world_override := WorldEnvironment.new()
	service.call("_apply_creation_defaults", atmosphere_with_world_override, &"sky_atmosphere", environment_root)
	require(atmosphere_with_world_override.camera_attributes == null,
			"creating an atmosphere must not supersede an existing WorldEnvironment camera override")

	var incomplete_rows := {&"atmosphere_sun": [{"node": atmospheric_sun}]}
	var missing: Array[StringName] = service.call("_missing_component_ids", incomplete_rows)
	require(missing == [&"sky_light", &"sky_atmosphere", &"volumetric_cloud", &"height_fog"],
			"create-missing must enumerate only absent categories and never duplicate an existing category")

	var environment_window = WindowScript.new()
	require(environment_window is Window, "the mixer must remain an independent Window rather than reparenting the main Inspector")
	environment_window.free()

	service.free()
	root.free()
	camera_root.free()
	environment_root.free()
	if atmosphere != null and is_instance_valid(atmosphere):
		atmosphere.free()
	sun_defaults.free()
	atmosphere_without_override.free()
	atmosphere_with_camera_override.free()
	atmosphere_with_world_override.free()
	print("Environment Mixer service: %d checks, %d failures" % [checks, failures])
	quit(1 if failures > 0 else 0)
