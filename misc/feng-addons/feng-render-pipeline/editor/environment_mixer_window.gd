@tool
extends Window
## Floating Environment Light Mixer. Each card edits real scene objects with
## EditorInspector; the mode selector only filters this window's visible rows.

const MINIMUM_SIZE := Vector2i(900, 600)
const CARD_WIDTH := 320.0
const CARD_MIN_HEIGHT := 260.0
const Service = preload("environment_mixer_service.gd")
const DETAIL_MINIMAL := 0
const DETAIL_NORMAL := 1
const DETAIL_NORMAL_ADVANCED := 2
# Directional shadow configuration belongs to the renderer's Shadow Pass.
const DIRECTIONAL_SHADOW_PROPERTIES: Array[StringName] = [
	&"shadow_enabled", &"directional_shadow_mode",
	&"directional_shadow_object_shadow_enabled", &"directional_shadow_object_shadow_target",
	&"directional_shadow_split_1", &"directional_shadow_split_2", &"directional_shadow_split_3",
	&"directional_shadow_blend_splits", &"directional_shadow_fade_start",
	&"directional_shadow_max_distance", &"directional_shadow_pancake_size",
	&"light_angular_distance", &"shadow_blur",
	&"shadow_bias", &"shadow_normal_bias", &"shadow_reverse_cull_face",
	&"shadow_transmittance_bias", &"shadow_opacity", &"shadow_caster_mask", &"distance_fade_shadow",
]

const MINIMAL_PROPERTIES := {
	"DirectionalLight3D": [
		"rotation", "light_color", "light_energy", "light_intensity_lux",
		"light_temperature", "sky_mode",
	],
	"FengSkyLight": [
		"position", "rotation", "enabled", "source_mode", "radiance_energy", "realtime_capture",
		"capture_sky", "source_sky", "cubemap", "volumetric_scattering_intensity",
	],
	"FengSkyAtmosphere": [
		"atmosphere_enabled", "sun_light", "ground_radius", "ground_albedo", "atmosphere_height",
		"sun_source_angle_deg", "multi_scattering_factor", "rayleigh_scattering_color",
		"mie_scattering_color", "mie_anisotropy", "other_absorption_color", "sky_luminance_factor",
		"sky_and_aerial_perspective_luminance_factor", "height_fog_contribution",
		"aerial_perspective_distance_scale", "aerial_perspective_start_depth",
	],
	"FengVolumetricCloud": [
		"position", "rotation", "enabled", "cloud_material", "planet_source", "planet_radius_km",
		"layer_bottom_altitude_km", "layer_height_km", "primary_sun", "secondary_sun",
		"tracing_start_distance_from_camera_km", "tracing_start_max_distance_km",
		"tracing_max_distance_mode", "tracing_max_distance_km", "ground_albedo_linear",
	],
	"FengHeightFog": [
		"position", "enabled", "fog_density", "fog_inscattering_color", "fog_height_falloff",
		"fog_height_offset", "fog_max_opacity", "volumetric_fog_enabled", "volumetric_fog_albedo",
		"volumetric_fog_distance", "directional_inscattering_exponent",
		"directional_inscattering_color", "directional_inscattering_start_distance",
		"start_distance", "fog_cutoff_distance",
	],
}

const ADVANCED_PROPERTIES: Array[StringName] = [
	&"capture_interval", &"capture_resolution", &"capture_distance", &"cull_mask",
	&"capture_shadows", &"capture_anchor", &"capture_offset", &"bake_data", &"bake_path",
	&"priority", &"volumetric_scattering_intensity", &"trace_sample_count_scale",
	&"secondary_sun_light", &"secondary_sun_source_angle_deg", &"secondary_sun_disk_color_scale",
	&"secondary_sun_angular_radius_deg", &"volumetric_fog_quality", &"volumetric_fog_history_weight",
	&"volumetric_fog_jitter_enabled", &"volumetric_fog_history_miss_supersample_count",
	&"volumetric_fog_ray_traced_shadows_enabled", &"volumetric_fog_light_soft_fading",
	&"volumetric_fog_area_light_source_textures_enabled",
	&"volumetric_fog_override_light_colors_with_fog_inscattering_colors", &"baked_irradiance",
	&"fsss_enabled", &"fsss_scene_color_scattering_amount_scale",
	&"fsss_scene_color_scattering_amount_power", &"fsss_spread_scale", &"fsss_blur_control",
	&"sky_ao_enabled", &"sky_ao_extent_km", &"sky_ao_resolution_scale", &"sky_ao_strength",
	&"sky_ao_aperture", &"sky_ao_sample_count", &"sky_ao_snap_length_km",
	&"secondary_sun", &"secondary_sun_cloud_shadow_settings",
	&"secondary_sun_cast_shadows_on_clouds", &"secondary_sun_cast_cloud_shadows",
]

const ADVANCED_GROUPS: Array[String] = [
	"quality & advanced", "质量与高级路径", "静态体积照明", "屏幕空间多重散射",
	"cloud shadowing", "cloud sky ao", "baked radiance",
]

var _service: Service
var _header_status: Label
var _scene_status: Label
var _create_environment_button: Button
var _atmospheric_only_check: CheckButton
var _detail_mode_picker: OptionButton
var _module_visibility_button: MenuButton
var _module_visibility_menu: PopupMenu
var _scroll_content: HFlowContainer
var _columns: Dictionary = {}
var _visible_modules: Dictionary = {}
var _has_been_popped := false


func setup(p_service: Service) -> void:
	if _service != null and is_instance_valid(_service) \
			and _service.snapshot_changed.is_connected(_on_snapshot_changed):
		_service.snapshot_changed.disconnect(_on_snapshot_changed)
	_service = p_service
	if _service != null and not _service.snapshot_changed.is_connected(_on_snapshot_changed):
		_service.snapshot_changed.connect(_on_snapshot_changed)
	_build_ui()
	if not close_requested.is_connected(_on_close_requested):
		close_requested.connect(_on_close_requested)
	if not about_to_popup.is_connected(_on_about_to_popup):
		about_to_popup.connect(_on_about_to_popup)
	if _service != null:
		_on_snapshot_changed(_service.get_snapshot())


func popup_in_host(p_host_size: Vector2i) -> void:
	var cap := Vector2i(maxi(1, floori(p_host_size.x * 0.9)), maxi(1, floori(p_host_size.y * 0.9)))
	min_size = Vector2i(mini(MINIMUM_SIZE.x, cap.x), mini(MINIMUM_SIZE.y, cap.y))
	if not _has_been_popped:
		size = _initial_size_for_host(p_host_size)
		_has_been_popped = true
	else:
		size = Vector2i(mini(size.x, cap.x), mini(size.y, cap.y)).max(min_size)
	popup_centered_clamped(size, 0.95)


func _initial_size_for_host(p_host_size: Vector2i) -> Vector2i:
	var cap := Vector2i(maxi(1, floori(p_host_size.x * 0.9)), maxi(1, floori(p_host_size.y * 0.9)))
	var popup_minimum := Vector2i(mini(MINIMUM_SIZE.x, cap.x), mini(MINIMUM_SIZE.y, cap.y))
	return cap.max(popup_minimum)


func _build_ui() -> void:
	title = "环境光混合器"
	min_size = MINIMUM_SIZE
	size = MINIMUM_SIZE
	transient = true
	visible = false
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_columns.clear()

	var outer := VBoxContainer.new()
	outer.name = "EnvironmentMixerRoot"
	outer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	outer.add_theme_constant_override("separation", 8)
	add_child(outer)

	var title_label := Label.new()
	title_label.text = "环境光混合器"
	title_label.add_theme_font_size_override("font_size", 20)
	outer.add_child(title_label)

	var controls := HFlowContainer.new()
	controls.name = "EnvironmentMixerControls"
	controls.add_theme_constant_override("h_separation", 8)
	controls.add_theme_constant_override("v_separation", 6)
	controls.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outer.add_child(controls)
	_atmospheric_only_check = CheckButton.new()
	_atmospheric_only_check.name = "AtmosphericLightsOnly"
	_atmospheric_only_check.text = "仅显示大气光源"
	_atmospheric_only_check.button_pressed = true
	_atmospheric_only_check.tooltip_text = "只显示可参与天空大气照明的太阳光源。"
	_atmospheric_only_check.toggled.connect(_on_atmospheric_only_toggled)
	controls.add_child(_atmospheric_only_check)
	var detail_label := Label.new()
	detail_label.text = "详情："
	controls.add_child(detail_label)
	_detail_mode_picker = OptionButton.new()
	_detail_mode_picker.name = "EnvironmentMixerDetailMode"
	_detail_mode_picker.add_item("最简", 0)
	_detail_mode_picker.add_item("普通", 1)
	_detail_mode_picker.add_item("普通 + 高级", 2)
	_detail_mode_picker.select(0)
	_detail_mode_picker.tooltip_text = "切换显示的参数详细程度。"
	_detail_mode_picker.item_selected.connect(_on_detail_mode_selected)
	controls.add_child(_detail_mode_picker)
	_module_visibility_button = MenuButton.new()
	_module_visibility_button.name = "EnvironmentMixerModuleVisibility"
	_module_visibility_button.text = "显示模块（5/5）"
	_module_visibility_button.tooltip_text = "选择要显示的环境组件卡片。"
	_module_visibility_button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_module_visibility_menu = _module_visibility_button.get_popup()
	_module_visibility_menu.id_pressed.connect(_on_module_visibility_pressed)
	controls.add_child(_module_visibility_button)
	_create_environment_button = Button.new()
	_create_environment_button.name = "CreateEnvironmentOrMissingComponents"
	_create_environment_button.text = "创建缺失组件"
	_create_environment_button.tooltip_text = "只补当前场景缺少的类别，不改写已有灯光、天空、相机或曝光。"
	_create_environment_button.pressed.connect(_on_create_environment_pressed)
	controls.add_child(_create_environment_button)
	if _service != null:
		var definitions: Array[Dictionary] = _service.get_component_definitions()
		for index in definitions.size():
			var definition: Dictionary = definitions[index]
			var component_id: StringName = definition["id"]
			_module_visibility_menu.add_check_item(String(definition["label"]), index)
			_module_visibility_menu.set_item_metadata(index, component_id)
			_module_visibility_menu.set_item_checked(index, _visible_modules.get(component_id, true))
			var create_button := Button.new()
			create_button.name = "Create_%s" % String(component_id)
			create_button.text = "+ %s" % String(definition["short_label"])
			create_button.tooltip_text = "添加缺少的%s实例。" % String(definition["label"])
			create_button.pressed.connect(_on_add_component_pressed.bind(component_id))
			controls.add_child(create_button)
	_update_module_visibility_button_text()

	_scene_status = Label.new()
	_scene_status.name = "EnvironmentMixerSceneStatus"
	_scene_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	outer.add_child(_scene_status)
	_header_status = Label.new()
	_header_status.name = "EnvironmentMixerStatus"
	_header_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_header_status.add_theme_color_override("font_color", Color(0.72, 0.78, 0.84))
	outer.add_child(_header_status)

	var scroll := ScrollContainer.new()
	scroll.name = "EnvironmentMixerCardsScroll"
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	outer.add_child(scroll)
	_scroll_content = HFlowContainer.new()
	_scroll_content.name = "EnvironmentMixerCards"
	_scroll_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll_content.add_theme_constant_override("h_separation", 10)
	_scroll_content.add_theme_constant_override("v_separation", 10)
	scroll.add_child(_scroll_content)

	if _service == null:
		return
	var editor_scale := EditorInterface.get_editor_scale()
	var card_width := CARD_WIDTH * editor_scale
	for definition in _service.get_component_definitions():
		_scroll_content.add_child(_create_component_card(definition, card_width, editor_scale))


func _create_component_card(p_definition: Dictionary, p_card_width: float, p_editor_scale: float) -> Control:
	var component_id: StringName = p_definition["id"]
	var panel := PanelContainer.new()
	panel.name = "EnvironmentMixer_%s" % String(component_id)
	panel.custom_minimum_size = Vector2(p_card_width, CARD_MIN_HEIGHT * p_editor_scale)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_stretch_ratio = 1.0
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.visible = _visible_modules.get(component_id, true)
	var column := VBoxContainer.new()
	column.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 6)
	panel.add_child(column)

	var label := Label.new()
	label.text = String(p_definition["label"])
	label.add_theme_font_size_override("font_size", 16)
	column.add_child(label)

	var actor_label := Label.new()
	actor_label.text = "场景实例"
	column.add_child(actor_label)
	var actor_picker := OptionButton.new()
	actor_picker.name = "ActorPicker_%s" % String(component_id)
	actor_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actor_picker.fit_to_longest_item = false
	actor_picker.item_selected.connect(_on_actor_selected.bind(component_id))
	column.add_child(actor_picker)

	var empty_label := Label.new()
	empty_label.text = "当前场景没有此组件。"
	empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	empty_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(empty_label)

	var inspector := EditorInspector.create_default_inspector()
	inspector.name = "Details_%s" % String(component_id)
	inspector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inspector.size_flags_vertical = Control.SIZE_EXPAND_FILL
	inspector.hide()
	column.add_child(inspector)

	_columns[component_id] = {
		"definition": p_definition,
		"panel": panel,
		"actor_picker": actor_picker,
		"empty_label": empty_label,
		"inspector": inspector,
		"nodes": [],
		"active": null,
	}
	return panel


func _on_snapshot_changed(p_snapshot: Dictionary) -> void:
	var root := _valid_node(p_snapshot.get("scene_root"))
	if root == null:
		_scene_status.text = "未打开场景。创建环境场景以开始。"
		_header_status.text = ""
		_create_environment_button.text = "创建环境场景"
		_create_environment_button.disabled = false
	else:
		_scene_status.text = "当前场景：%s" % String(root.name)
		var missing: Array = p_snapshot.get("missing_ids", [])
		if missing.is_empty():
			_header_status.text = "环境组件已齐全。在卡片中选择场景对象并调整参数。"
			_create_environment_button.text = "环境组件已齐全"
			_create_environment_button.disabled = true
		else:
			_header_status.text = "在卡片中选择场景对象并调整参数。"
			_create_environment_button.text = "创建缺失组件（%d）" % missing.size()
			_create_environment_button.disabled = false

	var components: Dictionary = p_snapshot.get("components", {})
	for component_id in _columns:
		var state: Dictionary = _columns[component_id]
		var rows: Array = components[component_id]
		var previous := _valid_node(state.active)
		var nodes: Array[Node] = []
		var paths: Array[String] = []
		for row in rows:
			var node := _valid_node(row.node)
			if node == null:
				continue
			nodes.append(node)
			paths.append(String(row.path))
		state["nodes"] = nodes
		var picker: OptionButton = state.actor_picker
		picker.clear()
		picker.add_item("选择一个实例" if not nodes.is_empty() else "无实例")
		for index in nodes.size():
			picker.add_item(String(nodes[index].name))
			picker.set_item_tooltip(index + 1, paths[index])
		var active_index := nodes.find(previous)
		if active_index < 0 and not nodes.is_empty():
			active_index = 0
		picker.select(active_index + 1)
		state["active"] = nodes[active_index] if active_index >= 0 else null
		var panel: Control = state.panel
		panel.visible = _visible_modules.get(component_id, true)
		var add_button := _find_create_button(component_id)
		if add_button != null:
			add_button.visible = root != null and nodes.is_empty()
			add_button.disabled = root == null
		_update_card_details(state)


func _valid_node(p_value: Variant) -> Node:
	if not is_instance_valid(p_value) or not (p_value is Node):
		return null
	return p_value as Node


func _find_create_button(p_component_id: StringName) -> Button:
	var button := find_child("Create_%s" % String(p_component_id), true, false)
	return button as Button


func _update_card_details(p_state: Dictionary, p_rebuild := false) -> void:
	var active := _valid_node(p_state.active)
	p_state["active"] = active
	var empty_label: Label = p_state.empty_label
	var inspector: EditorInspector = p_state.inspector
	if active != null:
		empty_label.hide()
		inspector.show()
		inspector.set_visible_properties(_visible_properties_for(active))
		if p_rebuild or inspector.get_edited_object() != active:
			inspector.edit(null)
			inspector.edit(active)
	else:
		inspector.edit(null)
		inspector.hide()
		empty_label.show()


func _on_actor_selected(p_index: int, p_component_id: StringName) -> void:
	if not _columns.has(p_component_id):
		return
	var state: Dictionary = _columns[p_component_id]
	var nodes: Array = state.nodes
	var selected_node: Variant = nodes[p_index - 1] if p_index > 0 and p_index <= nodes.size() else null
	state["active"] = _valid_node(selected_node)
	_update_card_details(state)
	_update_filter_context()


func _on_module_visibility_pressed(p_id: int) -> void:
	if not is_instance_valid(_module_visibility_menu):
		return
	var index := _module_visibility_menu.get_item_index(p_id)
	if index < 0:
		return
	var component_id: Variant = _module_visibility_menu.get_item_metadata(index)
	if not (component_id is StringName) or not _columns.has(component_id):
		return
	_set_module_visible(component_id, not bool(_visible_modules.get(component_id, true)))


func _set_module_visible(p_component_id: StringName, p_visible: bool) -> void:
	if not _columns.has(p_component_id):
		return
	_visible_modules[p_component_id] = p_visible
	var panel: Control = _columns[p_component_id].panel
	panel.visible = p_visible
	if is_instance_valid(_module_visibility_menu):
		for index in _module_visibility_menu.item_count:
			if _module_visibility_menu.get_item_metadata(index) == p_component_id:
				_module_visibility_menu.set_item_checked(index, p_visible)
				break
	_update_module_visibility_button_text()


func _update_module_visibility_button_text() -> void:
	var visible_count := 0
	for definition in Service.COMPONENTS:
		if _visible_modules.get(definition.id, true):
			visible_count += 1
	if is_instance_valid(_module_visibility_button):
		_module_visibility_button.text = "显示模块（%d/%d）" % [visible_count, Service.COMPONENTS.size()]


func _on_add_component_pressed(p_component_id: StringName) -> void:
	if _service == null or not is_instance_valid(_service):
		return
	_service.create_missing_component(p_component_id)


func _on_create_environment_pressed() -> void:
	if _service == null or not is_instance_valid(_service):
		return
	if _service.get_scene_root() == null:
		_service.create_environment_scene()
	else:
		var snapshot: Dictionary = _service.get_snapshot()
		_service.create_missing_components(snapshot.get("missing_ids", []))


func _on_atmospheric_only_toggled(p_enabled: bool) -> void:
	if _service != null and is_instance_valid(_service):
		_service.set_atmospheric_only(p_enabled)


func _on_detail_mode_selected(_index: int) -> void:
	_update_filter_context(true)


func _update_filter_context(p_rebuild := false) -> void:
	for state in _columns.values():
		_update_card_details(state, p_rebuild)


func _visible_properties_for(p_object: Object) -> PackedStringArray:
	var level := _detail_mode_picker.get_selected_id()
	if p_object == null or not is_instance_valid(p_object):
		return PackedStringArray()
	var kind := _component_kind(p_object)
	var minimal: Array = MINIMAL_PROPERTIES.get(kind, [])
	var visible := PackedStringArray()
	var active_category := ""
	var active_group := ""
	var active_subgroup := ""
	for property_info in p_object.get_property_list():
		var usage: int = property_info.get("usage", 0)
		if usage & PROPERTY_USAGE_CATEGORY:
			active_category = String(property_info.get("name", ""))
			active_group = ""
			active_subgroup = ""
			continue
		if usage & PROPERTY_USAGE_GROUP:
			active_group = String(property_info.get("name", ""))
			active_subgroup = ""
			continue
		if usage & PROPERTY_USAGE_SUBGROUP:
			active_subgroup = String(property_info.get("name", ""))
			continue
		if (usage & PROPERTY_USAGE_EDITOR) == 0:
			continue
		var property_name := StringName(property_info.get("name", ""))
		if kind == "DirectionalLight3D" and DIRECTIONAL_SHADOW_PROPERTIES.has(property_name):
			continue
		if level == DETAIL_NORMAL_ADVANCED:
			visible.append(String(property_name))
			continue
		if level == DETAIL_MINIMAL:
			if minimal.has(String(property_name)):
				visible.append(String(property_name))
			continue
		if ADVANCED_PROPERTIES.has(property_name):
			continue
		var group_name := (active_category + " " + active_group + " " + active_subgroup).to_lower()
		var is_advanced_group := false
		for advanced_group in ADVANCED_GROUPS:
			if group_name.contains(advanced_group):
				is_advanced_group = true
				break
		if not is_advanced_group:
			visible.append(String(property_name))
	return visible


func _component_kind(p_object: Object) -> String:
	var definition := Service.component_definition(p_object)
	return definition.get("native_class", definition.get("global_class", ""))


func _on_about_to_popup() -> void:
	if _service != null and is_instance_valid(_service):
		_service.refresh()


func _on_close_requested() -> void:
	hide()
