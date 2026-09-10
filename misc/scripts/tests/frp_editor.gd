@tool
extends EditorPlugin
## Executed by test_frp_pipeline.py in an isolated editor project.

const Renderer = preload("res://addons/feng-render-pipeline/renderer.gd")
const PipelinePlugin = preload("res://addons/feng-render-pipeline/editor_plugin.gd")

var pipeline_plugin: EditorPlugin

func _enter_tree() -> void:
	_run.call_deferred()

func _run() -> void:
	pipeline_plugin = PipelinePlugin.new()
	add_child(pipeline_plugin)
	var renderer := Renderer.new()
	var entries = renderer.passes.duplicate()
	for i in range(entries.size() - 1, -1, -1):
		if entries[i].stable_id == &"library:fxaa":
			entries.remove_at(i)
	renderer.passes = entries
	renderer.get_configuration_warnings()
	EditorInterface.edit_resource(renderer)
	await get_tree().process_frame
	await get_tree().process_frame
	assert(pipeline_plugin._find_selected_renderer() == renderer, "Inspector resource selection failed")
	var fxaa_menu_id := -1
	var names := {}
	for i in pipeline_plugin._library_entries.size():
		var entry = pipeline_plugin._library_entries[i]
		assert(not names.has(entry.label), "Library names must be distinct")
		names[entry.label] = true
		if entry.path.ends_with("fxaa/fxaa.tres"):
			fxaa_menu_id = i
	assert(fxaa_menu_id >= 0)
	var before := renderer.passes.size()
	pipeline_plugin._on_library_item(fxaa_menu_id)
	assert(renderer.passes.size() == before + 1, "Library menu did not add the pass")
	assert(not renderer._deleted_library.has("fxaa/fxaa.tres"))
	var history_manager := get_undo_redo()
	var history := history_manager.get_history_undo_redo(history_manager.get_object_history_id(renderer))
	history.undo()
	assert(renderer.passes.size() == before, "Undo re-added a deleted library pass")
	assert(renderer._deleted_library.has("fxaa/fxaa.tres"), "Undo lost the deletion marker")
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
