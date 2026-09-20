@tool
class_name FengVolumeInspectorPlugin
extends EditorInspectorPlugin
## Inspector integration for FRP Volume profiles.
##
## A profile stores the selected modules and their values.  The renderer used to
## populate the Add menu is deliberately kept in this editor-only plugin state;
## it is never written into FengVolumeProfile, so a profile remains usable when
## it is moved to another scene or project.

const Renderer = preload("../renderer.gd")
const CompositorScript = preload("../compositor.gd")
const ProjectPipeline = preload("../project_pipeline.gd")
const Volume = preload("../volume/feng_volume.gd")
const Profile = preload("../volume/feng_volume_profile.gd")
const Module = preload("../volume/feng_volume_module.gd")

var editor_plugin: EditorPlugin

## A renderer picked in this inspector is a browsing aid only.  The key is the
## edited profile (or the Volume while it has no profile), not the Resource
## itself, so this state cannot leak into a saved runtime resource. Each entry
## keeps the selected resource alive while its edited owner is alive, while the
## owner WeakRef lets inspector events discard entries for deleted profiles.
var _renderer_overrides: Dictionary = {}


func _init(p_editor_plugin: EditorPlugin = null) -> void:
	editor_plugin = p_editor_plugin


func _can_handle(p_object: Object) -> bool:
	return _is_volume(p_object) or _is_profile(p_object)


func _is_volume(p_object: Object) -> bool:
	return p_object != null and is_instance_valid(p_object) and p_object is Volume


func _is_profile(p_object: Object) -> bool:
	return p_object != null and is_instance_valid(p_object) and p_object is Profile


func _parse_property(
		p_object: Object,
		p_type: Variant.Type,
		p_name: String,
		p_hint_type: PropertyHint,
		p_hint_string: String,
		p_usage_flags: int,
		p_wide: bool) -> bool:
	# The raw Array editor would allow a user to construct an empty module and
	# assign arbitrary resources.  Module selection belongs to the renderer's
	# author-owned schema, so the custom list below is the only entry point.
	if _is_profile(p_object) and p_name == "modules":
		return true
	return false


func _parse_begin(p_object: Object) -> void:
	if not _can_handle(p_object):
		return
	_prune_renderer_overrides()

	var panel := VBoxContainer.new()
	panel.name = "FengVolumeModuleInspector"
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_constant_override("separation", 4)

	var heading := Label.new()
	heading.text = "FRP Volume modules"
	heading.tooltip_text = "Pass code decides which parameters a Volume module exposes."
	panel.add_child(heading)

	var profile = p_object if _is_profile(p_object) else p_object.get("profile")
	var profile_key := _profile_key(p_object, profile)
	var renderer = _renderer_for(p_object, profile_key)

	var renderer_row := HBoxContainer.new()
	renderer_row.name = "FengVolumeRendererSource"
	renderer_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var renderer_label := Label.new()
	renderer_label.text = "Renderer source"
	renderer_label.tooltip_text = "Used only by this inspector to discover authored Volume modules."
	renderer_label.custom_minimum_size.x = 120.0
	renderer_row.add_child(renderer_label)
	var picker := EditorResourcePicker.new()
	picker.name = "FengVolumeRendererPicker"
	picker.set_base_type("FengRenderer")
	picker.set_edited_resource(renderer if renderer is Renderer else null)
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker.tooltip_text = "Pick a FengRenderer for an independent profile; this choice is not saved in the profile."
	var override_owner: Object = profile if profile != null and is_instance_valid(profile) else p_object
	picker.resource_changed.connect(_on_renderer_picked.bind(p_object, profile_key, override_owner))
	renderer_row.add_child(picker)
	panel.add_child(renderer_row)

	if _is_volume(p_object) and profile == null:
		var missing_profile := Label.new()
		missing_profile.name = "FengVolumeMissingProfile"
		missing_profile.text = "This Volume has no profile."
		missing_profile.add_theme_color_override("font_color", Color(1.0, 0.76, 0.34))
		panel.add_child(missing_profile)
		var create_profile := Button.new()
		create_profile.name = "FengVolumeCreateProfile"
		create_profile.text = "Create Volume Profile"
		create_profile.tooltip_text = "Create a profile with an undoable editor action."
		create_profile.pressed.connect(_create_profile.bind(p_object))
		create_profile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		panel.add_child(create_profile)
		add_custom_control(panel)
		return

	if profile == null:
		# This is only reachable for a malformed/subclassed object.  Keep the
		# inspector useful without attempting to mutate it implicitly.
		var unavailable := Label.new()
		unavailable.text = "Volume profile is unavailable."
		unavailable.add_theme_color_override("font_color", Color(1.0, 0.76, 0.34))
		panel.add_child(unavailable)
		add_custom_control(panel)
		return

	if _is_volume(p_object):
		var edit_profile := Button.new()
		edit_profile.name = "FengVolumeEditProfile"
		edit_profile.text = "Edit Volume Profile"
		edit_profile.tooltip_text = "Inspect the profile resource and its selected modules."
		edit_profile.pressed.connect(_inspect_object.bind(profile))
		edit_profile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		panel.add_child(edit_profile)

	if renderer == null:
		var no_renderer := Label.new()
		no_renderer.name = "FengVolumeNoRenderer"
		no_renderer.text = "No FengRenderer found in the current camera/world or project pipeline. Pick one above."
		no_renderer.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		no_renderer.add_theme_color_override("font_color", Color(1.0, 0.76, 0.34))
		panel.add_child(no_renderer)

	var candidates: Array = _volume_modules(renderer)
	var add_row := HBoxContainer.new()
	add_row.name = "FengVolumeAddModuleRow"
	add_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var add_label := Label.new()
	add_label.text = "Selected modules"
	add_label.custom_minimum_size.x = 120.0
	add_row.add_child(add_label)
	var add_button := MenuButton.new()
	add_button.name = "FengVolumeAddModule"
	add_button.text = "Add Module"
	add_button.tooltip_text = "Select a pass module declared by the renderer."
	add_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var popup := add_button.get_popup()
	popup.name = "FengVolumeModuleMenu"
	var existing_keys := _module_keys(profile)
	var menu_sources: Array = []
	for source in candidates:
		if source == null or not source.has_method("get_parameter_key"):
			continue
		var key: Variant = source.get_parameter_key()
		if existing_keys.has(key):
			continue
		var menu_id := menu_sources.size()
		menu_sources.append(source)
		popup.add_item(_source_label(source), menu_id)
	if menu_sources.is_empty():
		if renderer == null:
			popup.add_item("Pick a renderer first")
		else:
			popup.add_item("No unselected Volume modules")
		popup.set_item_disabled(0, true)
	else:
		popup.id_pressed.connect(_on_module_menu_pressed.bind(profile, menu_sources, p_object))
	add_row.add_child(add_button)
	panel.add_child(add_row)

	var modules: Array = profile.modules
	if modules.is_empty():
		var empty := Label.new()
		empty.name = "FengVolumeNoModules"
		empty.text = "No modules selected."
		empty.modulate = Color(0.75, 0.75, 0.75)
		panel.add_child(empty)
	else:
		var available_keys := {}
		for source in candidates:
			if source != null and source.has_method("get_parameter_key"):
				available_keys[source.get_parameter_key()] = true
		for module in modules:
			_add_module_row(panel, profile, module, available_keys, p_object)

	add_custom_control(panel)


func _add_module_row(p_panel: VBoxContainer, p_profile: Profile, p_module, p_available_keys: Dictionary, p_edited: Object) -> void:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var label := Label.new()
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var source = p_module.pass_source if p_module != null and p_module is Module else null
	if source == null:
		label.text = "Missing pass source"
		label.tooltip_text = "This module cannot resolve its authored FengPass. Remove it or restore the pass."
		label.add_theme_color_override("font_color", Color(1.0, 0.35, 0.35))
	elif not p_available_keys.has(source.get_parameter_key()):
		label.text = "%s (source unavailable)" % _source_label(source)
		label.tooltip_text = "The current renderer no longer declares this pass as a Volume module."
		label.add_theme_color_override("font_color", Color(1.0, 0.76, 0.34))
	else:
		label.text = _source_label(source)
	if p_module != null and p_module is Module and p_module.get_parameters().get("enabled", true) == false:
		label.text += " (effect off)"
	row.add_child(label)

	if p_module != null and p_module is Module:
		var edit := Button.new()
		edit.name = "FengVolumeEditModule"
		edit.text = "Edit"
		edit.tooltip_text = "Edit pass-author-declared parameters. Enabled controls the effect; remove the module to restore pipeline settings."
		edit.pressed.connect(_inspect_object.bind(p_module))
		row.add_child(edit)
	var remove := Button.new()
	remove.name = "FengVolumeRemoveModule"
	remove.text = "Remove"
	remove.tooltip_text = "Remove this module with undo support."
	remove.pressed.connect(remove_module.bind(p_profile, p_module, p_edited))
	row.add_child(remove)
	p_panel.add_child(row)


func _source_label(p_source) -> String:
	if p_source == null:
		return "Missing pass source"
	var name := String(p_source.resource_name).strip_edges() if p_source is Resource else ""
	if name.is_empty() and p_source.has_method("get_parameter_key"):
		name = str(p_source.get_parameter_key())
	return name if not name.is_empty() else "FRP pass"


func _volume_modules(p_renderer) -> Array:
	if p_renderer == null or not is_instance_valid(p_renderer) or not p_renderer.has_method("get_volume_modules"):
		return []
	var result: Array = []
	for source in p_renderer.get_volume_modules():
		if source != null and source.has_method("get_volume_parameter_list") and not source.get_volume_parameter_list().is_empty():
			result.append(source)
	return result


func _module_keys(p_profile) -> Dictionary:
	var result := {}
	if p_profile == null:
		return result
	for module in p_profile.modules:
		if module != null and module is Module and module.pass_source != null:
			result[module.get_parameter_key()] = true
	return result


func _profile_key(p_object: Object, p_profile) -> int:
	if p_profile != null and is_instance_valid(p_profile):
		return p_profile.get_instance_id()
	return p_object.get_instance_id() if p_object != null else 0


func _on_renderer_picked(p_resource: Resource, p_object: Object, p_profile_key: int, p_owner: Object = null) -> void:
	_prune_renderer_overrides()
	if p_resource is Renderer:
		var owner := p_owner if p_owner != null else p_object
		_renderer_overrides[p_profile_key] = {
			"renderer": p_resource,
			"owner": weakref(owner) if owner != null and is_instance_valid(owner) else null,
		}
	else:
		_renderer_overrides.erase(p_profile_key)
	_refresh_object(p_object)


func _prune_renderer_overrides() -> void:
	# This runs only while the inspector is rebuilding or a picker changes. The
	# render path never touches this table, so cleanup cannot become a per-frame
	# scan of editor history.
	for key in _renderer_overrides.keys():
		var entry: Variant = _renderer_overrides[key]
		if not entry is Dictionary:
			_renderer_overrides.erase(key)
			continue
		var owner_ref: Variant = entry.get("owner", null)
		if not owner_ref is WeakRef or owner_ref.get_ref() == null:
			_renderer_overrides.erase(key)


## Resolve the renderer with the same priority users see in the editor: current
## scene camera, scene world, then the project pipeline.  A picked renderer is
## checked first because it is an explicit request for an independent profile.
func resolve_renderer(p_object: Object, p_profile_key: int = 0):
	return _renderer_for(p_object, p_profile_key)


func _renderer_for(p_object: Object, p_profile_key: int = 0):
	var picked = _renderer_override(p_profile_key)
	if picked is Renderer:
		return picked

	var scene_renderer = _scene_renderer(p_object)
	if scene_renderer != null:
		return scene_renderer

	var project_compositor = ProjectPipeline.resolve()
	return _renderer_from_compositor(project_compositor)


func _renderer_override(p_profile_key: int):
	var entry: Variant = _renderer_overrides.get(p_profile_key, null)
	if entry is Dictionary:
		var owner_ref: Variant = entry.get("owner", null)
		if not owner_ref is WeakRef or owner_ref.get_ref() == null:
			_renderer_overrides.erase(p_profile_key)
			return null
		var renderer: Variant = entry.get("renderer", null)
		return renderer if renderer is Renderer and is_instance_valid(renderer) else null
	if entry != null:
		_renderer_overrides.erase(p_profile_key)
	return null


func _scene_renderer(p_object: Object):
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null and p_object is Node and p_object.is_inside_tree():
		root = p_object.get_tree().edited_scene_root
	if root == null:
		return null

	# A current scene Camera3D is the most specific source.  Check the selected
	# object's camera ancestry first for sub-scenes that contain their own camera.
	if p_object is Node:
		var ancestor = p_object
		while ancestor != null:
			if ancestor is Camera3D and ancestor.current:
				var renderer = _renderer_from_compositor(ancestor.get("compositor"))
				if renderer != null:
					return renderer
			ancestor = ancestor.get_parent()

	var cameras := root.find_children("*", "Camera3D", true, false)
	if root is Camera3D:
		cameras.push_front(root)
	for camera in cameras:
		if not camera.current:
			continue
		var renderer = _renderer_from_compositor(camera.get("compositor"))
		if renderer != null:
			return renderer

	# If no camera is current, a scene camera with an explicit compositor is
	# still a better source than a global project setting.
	for camera in cameras:
		var renderer = _renderer_from_compositor(camera.get("compositor"))
		if renderer != null:
			return renderer

	var environments := root.find_children("*", "WorldEnvironment", true, false)
	if root is WorldEnvironment:
		environments.push_front(root)
	for environment in environments:
		var renderer = _renderer_from_compositor(environment.get("compositor"))
		if renderer != null:
			return renderer
	return null


func _renderer_from_compositor(p_compositor):
	if p_compositor == null or not is_instance_valid(p_compositor):
		return null
	var renderer = p_compositor.get("renderer") if p_compositor.has_method("get") else null
	return renderer if renderer is Renderer else null


func _create_profile(p_volume: Object):
	if not _is_volume(p_volume) or p_volume.profile != null:
		return p_volume.profile if _is_volume(p_volume) else null
	var profile := Profile.new()
	profile.resource_name = "Volume Profile"
	_commit_property(p_volume, &"profile", profile, null, "Create FRP Volume Profile")
	_refresh_object(p_volume)
	return profile


## Public for the editor test and for a future dock: add one author-declared
## module through the same transaction as the Inspector button.
func add_module(p_profile: Object, p_source, p_renderer = null):
	if not _is_profile(p_profile) or p_source == null or not p_source.has_method("get_parameter_key"):
		return null
	var key: Variant = p_source.get_parameter_key()
	for existing in p_profile.modules:
		if existing != null and existing is Module and typeof(existing.get_parameter_key()) == typeof(key) and existing.get_parameter_key() == key:
			return existing

	var authored := {}
	var renderer = p_renderer if p_renderer is Renderer else null
	if renderer != null and renderer.has_method("get_authored_pass_parameters"):
		var all: Dictionary = renderer.get_authored_pass_parameters()
		var value: Variant = all.get(key, {})
		if value is Dictionary:
			authored = value
	var module = Module.from_pass(p_source, authored)
	var next: Array = p_profile.modules.duplicate()
	next.append(module)
	_commit_property(p_profile, &"modules", next, p_profile.modules.duplicate(), "Add FRP Volume Module")
	_refresh_object(p_profile)
	return module


func _on_module_menu_pressed(p_index: int, p_profile: Object, p_sources: Array, p_edited: Object) -> void:
	if p_index < 0 or p_index >= p_sources.size():
		return
	var profile_key := _profile_key(p_edited, p_profile)
	add_module(p_profile, p_sources[p_index], _renderer_for(p_edited, profile_key))
	_refresh_object(p_edited)


func remove_module(p_profile: Object, p_module, p_edited: Object = null) -> void:
	if not _is_profile(p_profile) or p_module == null:
		return
	var old: Array = p_profile.modules.duplicate()
	if not old.has(p_module):
		return
	var next := old.duplicate()
	next.erase(p_module)
	_commit_property(p_profile, &"modules", next, old, "Remove FRP Volume Module")
	_refresh_object(p_edited if p_edited != null else p_profile)


func _commit_property(p_object: Object, p_property: StringName, p_do_value, p_undo_value, p_action: String) -> void:
	var undo = editor_plugin.get_undo_redo() if editor_plugin != null and is_instance_valid(editor_plugin) else null
	if undo == null:
		p_object.set(p_property, p_do_value)
		return
	undo.create_action(p_action, UndoRedo.MERGE_DISABLE, p_object)
	undo.add_do_property(p_object, p_property, p_do_value)
	undo.add_undo_property(p_object, p_property, p_undo_value)
	# Property Variants retain Resources already. add_*_reference would attempt
	# to assign a new subresource to its own history instead of the edited owner.
	undo.add_do_method(p_object, "notify_property_list_changed")
	undo.add_undo_method(p_object, "notify_property_list_changed")
	if p_object is Resource:
		undo.add_do_method(p_object, "emit_changed")
		undo.add_undo_method(p_object, "emit_changed")
	undo.commit_action()


func _inspect_object(p_object: Object) -> void:
	if p_object != null and is_instance_valid(p_object):
		EditorInterface.inspect_object(p_object)


func _refresh_object(p_object: Object) -> void:
	if p_object == null or not is_instance_valid(p_object):
		return
	p_object.notify_property_list_changed()
	if p_object is Resource:
		p_object.emit_changed()
	var inspector := EditorInterface.get_inspector()
	if inspector != null and inspector.get_edited_object() == p_object:
		EditorInterface.inspect_object(p_object)
