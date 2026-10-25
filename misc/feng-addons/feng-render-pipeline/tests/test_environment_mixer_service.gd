extends SceneTree
## Regression coverage for environment-card discovery and create-only defaults.

const ServiceScript = preload("res://addons/feng-render-pipeline/editor/environment_mixer_service.gd")
const WindowScript = preload("res://addons/feng-render-pipeline/editor/environment_mixer_window.gd")
const BuiltinPassScript = preload("res://addons/feng-render-pipeline/passes/builtin_pass.gd")

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
	var window := WindowScript.new()
	for kind in probes:
		var object: Object = probes[kind]
		require(window._component_kind(object) == kind,
				"discovery and inspector filtering must share the component definition for %s" % kind)
		if kind == "DirectionalLight3D":
			# The target path is conditionally exposed after reserving an object slot.
			object.set("directional_shadow_object_shadow_enabled", true)
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
	window.free()


func _test_directional_shadow_defaults_and_roundtrip() -> void:
	var light := DirectionalLight3D.new()
	var contract_probe := DirectionalLight3D.new()
	contract_probe.set("directional_shadow_object_shadow_enabled", true)
	var property_info_by_name: Dictionary = {}
	for property_info in contract_probe.get_property_list():
		property_info_by_name[String(property_info.get("name", ""))] = property_info

	var required_properties := [
		"directional_shadow_mode",
		"directional_shadow_object_shadow_enabled",
		"directional_shadow_object_shadow_target",
	]
	var complete_contract := true
	for property_name in required_properties:
		var property_info: Variant = property_info_by_name.get(property_name)
		var has_editor_and_storage := property_info != null \
				and (int(property_info.get("usage", 0)) & PROPERTY_USAGE_EDITOR) != 0 \
				and (int(property_info.get("usage", 0)) & PROPERTY_USAGE_STORAGE) != 0
		require(has_editor_and_storage,
				"DirectionalLight3D.%s must be editable and serialized" % property_name)
		complete_contract = complete_contract and has_editor_and_storage
	contract_probe.free()
	if not complete_contract:
		light.free()
		return

	var target_info: Dictionary = property_info_by_name["directional_shadow_object_shadow_target"]
	require(int(target_info.get("hint", -1)) == PROPERTY_HINT_NODE_PATH_VALID_TYPES
			and String(target_info.get("hint_string", "")).contains("Node3D"),
			"the reserved object-shadow target must select a Node3D scene path")
	var mode_info: Dictionary = property_info_by_name["directional_shadow_mode"]
	var mode_hint := String(mode_info.get("hint_string", ""))
	require(int(mode_info.get("hint", -1)) == PROPERTY_HINT_ENUM
			and mode_hint.contains("PSSM 2 Splits (Average):1")
			and mode_hint.contains("PSSM 4 Splits (Slow):2")
			and mode_hint.contains("PSSM 3 Splits:3"),
			"the Inspector enum must expose PSSM 3 while retaining the serialized PSSM 2/4 values")
	require(int(light.get("directional_shadow_mode")) == DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
			and not bool(light.get("directional_shadow_object_shadow_enabled"))
			and NodePath(light.get("directional_shadow_object_shadow_target")) == NodePath(""),
			"new directional lights must default to four CSM splits with object reservation off and no target")
	require(int(ProjectSettings.get_setting("rendering/frp/shadows/directional_shadow/cascade_size", 0)) == 4096,
			"FRP must default to 4096 pixels for each directional shadow slot")
	require(int(ProjectSettings.get_setting("rendering/lights_and_shadows/directional_shadow/size", 0)) == 4096,
			"the legacy total-atlas setting must retain its independent default for non-FRP renderers")

	var root := Node3D.new()
	root.name = "ShadowRoundtripRoot"
	get_root().add_child(root)
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	root.add_child(sun)
	sun.owner = root
	var role_root := Node3D.new()
	role_root.name = "CharacterRoot"
	root.add_child(role_root)
	role_root.owner = root
	var body := MeshInstance3D.new()
	body.name = "Body"
	body.mesh = SphereMesh.new()
	role_root.add_child(body)
	body.owner = root

	sun.set("directional_shadow_mode", 3)
	sun.set("directional_shadow_object_shadow_enabled", true)
	sun.set("directional_shadow_object_shadow_target", NodePath("../CharacterRoot"))
	sun.light_angular_distance = 0.5
	sun.shadow_blur = 1.25

	var packed := PackedScene.new()
	var pack_error := packed.pack(root)
	require(pack_error == OK, "directional shadow configuration fixture must pack as a scene")
	if pack_error != OK:
		root.free()
		light.free()
		return

	var scene_path := "user://frp_directional_shadow_roundtrip_%d.tscn" % OS.get_process_id()
	var save_error := ResourceSaver.save(packed, scene_path)
	require(save_error == OK, "directional shadow configuration must save with its scene")
	if save_error == OK:
		var loaded := ResourceLoader.load(scene_path, "", ResourceLoader.CACHE_MODE_IGNORE)
		require(loaded is PackedScene, "directional shadow scene must reload as a PackedScene")
		if loaded is PackedScene:
			var restored_root: Node3D = loaded.instantiate() as Node3D
			var restored_sun := restored_root.get_node("Sun") as DirectionalLight3D
			var restored_role_root := restored_root.get_node("CharacterRoot") as Node3D
			var restored_target := NodePath(restored_sun.get("directional_shadow_object_shadow_target"))
			require(int(restored_sun.get("directional_shadow_mode")) == 3
					and bool(restored_sun.get("directional_shadow_object_shadow_enabled"))
					and restored_target == restored_sun.get_path_to(restored_role_root)
					and restored_sun.get_node_or_null(restored_target) == restored_role_root
					and restored_role_root.get_node_or_null("Body") is MeshInstance3D,
				"PSSM 3+object mode and the multi-mesh role-root NodePath must survive scene serialization")
			require(is_equal_approx(restored_sun.light_angular_distance, 0.5)
					and is_equal_approx(restored_sun.shadow_blur, 1.25),
				"PCSS angular size and blur parameters must survive scene serialization")
			restored_root.free()
		DirAccess.remove_absolute(ProjectSettings.globalize_path(scene_path))

	root.free()
	light.free()


func _test_frp_shadow_resolution_setting_storage() -> void:
	const setting_name := "rendering/frp/shadows/directional_shadow/cascade_size"
	if not ProjectSettings.has_setting(setting_name):
		require(false, "FRP must register its per-slot directional-shadow resolution setting")
		return

	var property_info: Dictionary = {}
	for candidate in ProjectSettings.get_property_list():
		if String(candidate.get("name", "")) == setting_name:
			property_info = candidate
			break
	require(not property_info.is_empty()
				and (int(property_info.get("usage", 0)) & PROPERTY_USAGE_EDITOR) != 0
				and (int(property_info.get("usage", 0)) & PROPERTY_USAGE_STORAGE) != 0,
				"FRP per-slot resolution must be visible in Project Settings and persist in project config")
	require(int(property_info.get("type", -1)) == TYPE_INT
			and int(property_info.get("hint", -1)) == PROPERTY_HINT_RANGE
			and String(property_info.get("hint_string", "")).begins_with("256,8192,1"),
			"FRP per-slot resolution must be an integer setting with the documented 256–8192 range")
	require(int(ProjectSettings.get_setting(setting_name, 0)) == 4096,
			"FRP per-slot resolution must default to 4096 pixels")

	var previous_value: Variant = ProjectSettings.get_setting(setting_name)
	var previous_legacy_value: Variant = ProjectSettings.get_setting(
			"rendering/lights_and_shadows/directional_shadow/size", 0)
	# Preserve the arbitrary integer from Project Settings; FRP rounds 3000 up
	# to a 4096-pixel active slot when it reads the value for rendering.
	ProjectSettings.set_setting(setting_name, 3000)
	require(ProjectSettings.get_setting("rendering/lights_and_shadows/directional_shadow/size", 0)
			== previous_legacy_value,
			"changing FRP per-slot resolution must not change the legacy non-FRP atlas setting")
	var config_path := "user://frp_shadow_resolution_%d.godot" % OS.get_process_id()
	var save_error: Error = ProjectSettings.save_custom(config_path)
	ProjectSettings.set_setting(setting_name, previous_value)
	require(save_error == OK, "the FRP cascade-size override must save to a project config")
	if save_error == OK:
		var saved_config := ConfigFile.new()
		var load_error: Error = saved_config.load(config_path)
		require(load_error == OK
				and int(saved_config.get_value("rendering", "frp/shadows/directional_shadow/cascade_size", 0)) == 3000,
				"the entered FRP cascade-size value must round-trip through project config serialization")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(config_path))


func _test_directional_shadow_mixer_controls() -> void:
	var window = WindowScript.new()
	var detail_picker := OptionButton.new()
	detail_picker.add_item("Minimal", WindowScript.DETAIL_MINIMAL)
	detail_picker.add_item("Normal", WindowScript.DETAIL_NORMAL)
	detail_picker.add_item("Normal + Advanced", WindowScript.DETAIL_NORMAL_ADVANCED)
	window.set("_detail_mode_picker", detail_picker)

	var sun := DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.set("directional_shadow_object_shadow_enabled", true)
	for detail_mode in [WindowScript.DETAIL_MINIMAL, WindowScript.DETAIL_NORMAL, WindowScript.DETAIL_NORMAL_ADVANCED]:
		detail_picker.select(detail_mode)
		var filtered: PackedStringArray = window.call("_visible_properties_for", sun)
		for property_name in WindowScript.DIRECTIONAL_SHADOW_PROPERTIES:
			require(not filtered.has(String(property_name)),
					"mixer detail mode %d must leave %s in the renderer Shadow Pass" % [detail_mode, property_name])
		for property_name in ["rotation", "light_color", "sky_mode"]:
			require(filtered.has(property_name),
					"mixer detail mode %d must retain normal sun control %s" % [detail_mode, property_name])
		require(filtered.has("light_energy") or filtered.has("light_intensity_lux"),
				"mixer detail mode %d must retain a light intensity control" % detail_mode)

	if not Engine.is_editor_hint():
		sun.free()
		detail_picker.free()
		window.free()
		return

	var sun_card: Control = window.call("_create_component_card", {
		"id": &"atmosphere_sun", "label": "Atmosphere Sun",
	}, WindowScript.CARD_WIDTH, 1.0)
	require(sun_card.find_child("ActorPicker_atmosphere_sun", true, false) is OptionButton
			and sun_card.find_child("Details_atmosphere_sun", true, false) is EditorInspector,
			"the sun card must retain its scene-light picker and normal environment inspector")
	for removed_control in ["DirectionalShadowSection", "DirectionalShadowSlotResolution", "DirectionalCsmProperties", "DirectionalPcssProperties", "DirectionalSoftShadowQuality"]:
		require(sun_card.find_child(removed_control, true, false) == null,
				"the environment mixer must not expose a second shadow configuration control: %s" % removed_control)
	sun_card.free()

	sun.set("directional_shadow_object_shadow_enabled", false)
	var target_visible := false
	for property_info in sun.get_property_list():
		if String(property_info.get("name", "")) == "directional_shadow_object_shadow_target":
			target_visible = (int(property_info.get("usage", 0)) & PROPERTY_USAGE_EDITOR) != 0
	var frp := RenderingServer.get_current_rendering_method() == "frp"
	require(target_visible == frp, "FRP must allow choosing a target before reserving its slot in Shadow Pass")

	sun.set("directional_shadow_object_shadow_enabled", true)
	target_visible = false
	for property_info in sun.get_property_list():
		if String(property_info.get("name", "")) == "directional_shadow_object_shadow_target":
			target_visible = (int(property_info.get("usage", 0)) & PROPERTY_USAGE_EDITOR) != 0
	require(target_visible, "enabling the reservation must expose the Node3D target selector")

	sun.set("directional_shadow_mode", 0)
	var conditional_fields_hidden := true
	for property_info in sun.get_property_list():
		var property_name := String(property_info.get("name", ""))
		if property_name == "directional_shadow_object_shadow_enabled":
			conditional_fields_hidden = conditional_fields_hidden \
					and (int(property_info.get("usage", 0)) & PROPERTY_USAGE_EDITOR) == 0
		elif property_name == "directional_shadow_object_shadow_target":
			conditional_fields_hidden = conditional_fields_hidden \
					and (((int(property_info.get("usage", 0)) & PROPERTY_USAGE_EDITOR) != 0) == frp)
	require(conditional_fields_hidden,
			"Orthogonal mode hides native reservation while FRP keeps the pass's target assignable")

	sun.free()
	detail_picker.free()
	window.free()


func _test_renderer_shadow_stage_schedule() -> void:
	var active_compositor_path := "res://render/box_compositor.tres"
	if not ResourceLoader.exists(active_compositor_path):
		return
	var compositor: Resource = ResourceLoader.load(active_compositor_path)
	require(compositor != null and compositor.get("renderer") is Resource,
			"the test project's actual FRP compositor must reference its renderer resource")
	if compositor == null or not (compositor.get("renderer") is Resource):
		return
	var project_renderer: Resource = compositor.get("renderer")
	var passes: Array = project_renderer.get("passes")
	var shadow_index := -1
	var lighting_index := -1
	var shadow_provider_count := 0
	for index in passes.size():
		var pass_entry: Variant = passes[index]
		if not (pass_entry is BuiltinPassScript):
			continue
		if pass_entry.native_id == 0:
			shadow_provider_count += 1
			if pass_entry.is_enabled():
				shadow_index = index
		elif pass_entry.native_id == 3 and pass_entry.is_enabled():
			lighting_index = index
	require(shadow_index >= 0 and lighting_index > shadow_index,
			"the actual test-project renderer must schedule enabled Shadow Precompute before Lighting")
	require(shadow_provider_count == 1,
			"the actual renderer must contain one real Shadow Precompute entry, without a duplicate shadow pass")


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


func _test_stopped_service_refresh() -> void:
	var service := ServiceScript.new()
	get_root().add_child(service)
	var notifications := [0]
	service.snapshot_changed.connect(func(_snapshot): notifications[0] += 1)
	service._schedule_refresh()
	service.stop()
	service.stop()
	await process_frame
	require(notifications[0] == 0 and service._snapshot_cache.is_empty(),
			"a queued refresh must not revive a stopped service or emit stale scene state")
	service.free()


func _test_module_visibility() -> void:
	var environment_window = WindowScript.new()
	require(environment_window.call("_initial_size_for_host", Vector2i(1600, 1000)) == Vector2i(1440, 900),
			"the first popup should use 90% of a wide host instead of a fixed narrow size")
	require(environment_window.call("_initial_size_for_host", Vector2i(1000, 700)) == Vector2i(900, 630),
			"the first popup should keep the 90% cap on a smaller host")
	var panels: Dictionary = {}
	for definition in ServiceScript.COMPONENTS:
		var component_id: StringName = definition.id
		var panel := PanelContainer.new()
		panels[component_id] = panel
		environment_window._columns[component_id] = {"panel": panel}
		require(panel.visible, "%s is visible when the window opens" % String(component_id))
	for definition in ServiceScript.COMPONENTS:
		var component_id: StringName = definition.id
		environment_window.call("_set_module_visible", component_id, component_id == &"height_fog")
	var visible_ids: Array[StringName] = []
	for definition in ServiceScript.COMPONENTS:
		var component_id: StringName = definition.id
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
	print("Environment Mixer test context: Engine.is_editor_hint=%s" % Engine.is_editor_hint())
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
	_test_directional_shadow_defaults_and_roundtrip()
	_test_frp_shadow_resolution_setting_storage()
	_test_directional_shadow_mixer_controls()
	_test_renderer_shadow_stage_schedule()
	_test_freed_node_references()
	await _test_stopped_service_refresh()
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
