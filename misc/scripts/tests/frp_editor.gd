@tool
extends EditorPlugin
## Executed by test_frp_pipeline.py in an isolated editor project.

const Renderer = preload("res://addons/feng-render-pipeline/renderer.gd")
const PipelinePlugin = preload("res://addons/feng-render-pipeline/editor_plugin.gd")
const ProjectPipeline = preload("res://addons/feng-render-pipeline/project_pipeline.gd")

var pipeline_plugin: EditorPlugin

func _enter_tree() -> void:
	_run.call_deferred()

func _run() -> void:
	pipeline_plugin = PipelinePlugin.new()
	add_child(pipeline_plugin)
	var renderer := Renderer.new()
	# A fresh renderer is the nine passes, and Color Grade is the one library entry it
	# seeds; the other templates reach it only through the Library menu.
	assert(renderer.passes.size() == 9, "a fresh renderer must list the nine passes, got %d" % renderer.passes.size())
	var entries = renderer.passes.duplicate()
	var removed_seeded := false
	for i in range(entries.size() - 1, -1, -1):
		if entries[i].stable_id == &"library:color_grade":
			entries.remove_at(i)
			removed_seeded = true
	assert(removed_seeded, "the fresh renderer does not carry the seeded Color Grade pass")
	renderer.passes = entries
	renderer.get_configuration_warnings()
	EditorInterface.edit_resource(renderer)
	await get_tree().process_frame
	await get_tree().process_frame
	assert(pipeline_plugin._find_selected_renderer() == renderer, "Inspector resource selection failed")

	# The project pipeline is a project setting that sits next to the renderer it belongs to
	# (Rendering > Renderer > Compositor) rather than a node per scene, because the Scene
	# view and the running game use different cameras: only a world-level compositor
	# reaches both. The plugin registers the setting with a file picker, registers the
	# autoload the game installs it with, and installs the same pipeline into the editor's
	# own world.
	var pipeline_setting := "rendering/renderer/compositor"
	assert(ProjectSettings.has_setting(pipeline_setting), "the plugin did not register the project pipeline setting next to the rendering method")
	var setting_info: Dictionary = {}
	for property in ProjectSettings.get_property_list():
		if String(property.get("name", "")) == pipeline_setting:
			setting_info = property
	assert(int(setting_info.get("hint", -1)) == PROPERTY_HINT_FILE, "the project pipeline setting has no file picker")
	assert(String(setting_info.get("hint_string", "")).contains("*.tres"), "the project pipeline file picker does not accept pipeline resources")
	# Basic rows are offered without "Advanced Settings", and an editor row exists only for
	# the renderer that reads it: switching the project away from FRP hides the setting and
	# keeps its value.
	var setting_usage := int(setting_info.get("usage", 0))
	assert((setting_usage & PROPERTY_USAGE_EDITOR) != 0, "the project pipeline setting is not offered while FRP is the rendering method")
	assert((setting_usage & PROPERTY_USAGE_EDITOR_BASIC_SETTING) != 0, "the project pipeline setting is hidden behind the Advanced Settings toggle")
	ProjectSettings.set_setting("rendering/renderer/rendering_method", "forward_plus")
	await get_tree().process_frame
	await get_tree().process_frame
	setting_info = {}
	for property in ProjectSettings.get_property_list():
		if String(property.get("name", "")) == pipeline_setting:
			setting_info = property
	assert((int(setting_info.get("usage", 0)) & PROPERTY_USAGE_EDITOR) == 0, "the project pipeline setting is still offered for another renderer")
	ProjectSettings.set_setting("rendering/renderer/rendering_method", "frp")
	await get_tree().process_frame
	await get_tree().process_frame
	setting_info = {}
	for property in ProjectSettings.get_property_list():
		if String(property.get("name", "")) == pipeline_setting:
			setting_info = property
	assert((int(setting_info.get("usage", 0)) & PROPERTY_USAGE_EDITOR) != 0, "the project pipeline setting did not come back with FRP")
	var autoload_value := String(ProjectSettings.get_setting("autoload/FengProjectPipeline", ""))
	# The editor writes "*" + a UID; a hand-written project.godot names the path, so the
	# value is compared against the script it has to point at, both ways round.
	assert(autoload_value.begins_with("*"), "the autoload a running game installs the pipeline with is not a singleton: '%s'" % autoload_value)
	assert(ProjectPipeline.names(autoload_value, "res://addons/feng-render-pipeline/project_pipeline.gd"), "the plugin registered the wrong autoload script: '%s'" % autoload_value)
	var pipeline_fixture := "user://frp_editor_project_pipeline.tres"
	assert(ResourceSaver.save(renderer, pipeline_fixture) == OK, "could not write the project pipeline fixture")
	ProjectSettings.set_setting(pipeline_setting, pipeline_fixture)
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	var installed := get_tree().root.find_children("FengProjectPipeline", "WorldEnvironment", true, false)
	assert(installed.size() == 1, "the editor did not install the project pipeline, got %d nodes" % installed.size())
	EditorInterface.set_main_screen_editor("3D")
	await get_tree().process_frame
	var editor_view := EditorInterface.get_editor_viewport_3d(0)
	assert(editor_view != null, "the editor's 3D viewport is not available to check against")
	assert(editor_view.find_world_3d() == installed[0].get_viewport().find_world_3d(), "the Scene view does not render the world the project pipeline is installed in")
	ProjectSettings.set_setting(pipeline_setting, "")
	await get_tree().process_frame
	await get_tree().process_frame
	assert(get_tree().root.find_children("FengProjectPipeline", "WorldEnvironment", true, false).is_empty(), "clearing the setting left the project pipeline installed")

	var color_grade_menu_id := -1
	var names := {}
	for i in pipeline_plugin._library_entries.size():
		var entry = pipeline_plugin._library_entries[i]
		assert(not names.has(entry.label), "Library names must be distinct")
		names[entry.label] = true
		if entry.path.ends_with("color-grade/color_grade.tres"):
			color_grade_menu_id = i
	assert(color_grade_menu_id >= 0)
	var before := renderer.passes.size()
	pipeline_plugin._on_library_item(color_grade_menu_id)
	assert(renderer.passes.size() == before + 1, "Library menu did not add the pass")
	assert(not renderer._deleted_library.has("color-grade/color_grade.tres"))
	var history_manager := get_undo_redo()
	var history := history_manager.get_history_undo_redo(history_manager.get_object_history_id(renderer))
	history.undo()
	assert(renderer.passes.size() == before, "Undo re-added a deleted library pass")
	assert(renderer._deleted_library.has("color-grade/color_grade.tres"), "Undo lost the deletion marker")
	history.redo()
	assert(renderer.passes.size() == before + 1, "Redo failed to restore the library pass")
	var original = renderer.passes.duplicate()
	pipeline_plugin.move_pass(renderer, 7, 3)
	assert(renderer.passes[3] == original[7], "Editor move did not reorder the list")
	history.undo()
	assert(renderer.passes == original, "Undo did not restore pass order")
	await get_tree().process_frame
	print("PASS FRP editor resource selection, names, add, move, undo and redo")
	get_tree().quit()
