@tool
extends EditorPlugin
## Adds an "Add Pass from Library" menu for FengRenderer resources.
##
## FengRenderer and FengCompositor are resources, so the inspector's edited
## object is the source of truth. Scene selection is deliberately not used:
## either resource can be nested in a scene or edited as a standalone .tres.

const Renderer = preload("renderer.gd")
const CompositorScript = preload("compositor.gd")
const PassBase = preload("passes/pass_base.gd")
const ProjectPipeline = preload("project_pipeline.gd")
const LibraryManager = preload("pipeline/library_manager.gd")

const PIPELINE_AUTOLOAD := "FengProjectPipeline"


const FengRendererInspectorPlugin = preload("editor/renderer_inspector_plugin.gd")


var _menu: PopupMenu
var _inspector_plugin
var _library_entries: Array[Dictionary] = []
var _project_pipeline: WorldEnvironment = null

func _enter_tree() -> void:
	_inspector_plugin = FengRendererInspectorPlugin.new(Renderer)
	add_inspector_plugin(_inspector_plugin)

	# add_tool_submenu_item() reparents popup into the editor tool menu and
	# requires it to be parentless; adding it as a child first trips the
	# ERR_FAIL_COND in EditorNode::add_tool_submenu_item.
	if _menu != null:
		if _menu.get_parent() != null:
			_menu.get_parent().remove_child(_menu)
		_menu.free()
	_menu = PopupMenu.new()
	_menu.name = "FengRenderPipeline"
	_menu.id_pressed.connect(_on_library_item)
	add_tool_submenu_item("Add Pass from Library", _menu)
	_refresh_library()

	_register_project_pipeline_setting()
	_ensure_pipeline_autoload()
	ProjectSettings.settings_changed.connect(_on_project_settings_changed)
	if get_tree() != null:
		# A scene brings its own WorldEnvironment later than this plugin loads, and
		# removing it has to hand the world back, so watch for both. Not deferred:
		# node_removed hands over the node being freed, so its type has to be read while
		# it still exists; the work is deferred instead, which also keeps this plugin out
		# of another node's tree notification.
		get_tree().node_added.connect(_on_editor_node_added)
		get_tree().node_removed.connect(_on_editor_node_removed)
	# Deferred: the editor tree may not resolve this plugin's world yet.
	_sync_project_pipeline.call_deferred()

func _exit_tree() -> void:
	if _inspector_plugin != null:
		remove_inspector_plugin(_inspector_plugin)
		_inspector_plugin = null
	if _menu != null:
		# The menu is parented to the editor tool menu, not to this plugin.
		# remove_tool_menu_item() detaches and deletes it; queue_free() alone
		# would leave a dangling submenu entry behind.
		remove_tool_menu_item("Add Pass from Library")
		_menu = null
	_detach_project_pipeline()
	# The autoload is deliberately left in place: _exit_tree also runs when the editor
	# shuts down, and rewriting project.godot on every exit would be churn for a node that
	# does nothing while the setting is empty. Removing it is one line in project.godot.

## The project's pipeline is a project setting that sits next to the renderer it belongs to
## (Rendering > Renderer > Compositor) rather than a node per scene, because only a
## world-level compositor reaches both the Scene view and the running game: they use
## different cameras, and the game's camera is not the one the editor renders with.
##
## The row is basic, so it is visible without "Advanced Settings", and it is only offered
## while FRP is the project's rendering method: an internal setting is stored but not
## shown, so the value survives a switch to another renderer without leaving a dead row in
## the dialog.
func _register_project_pipeline_setting() -> void:
	if not ProjectSettings.has_setting(ProjectPipeline.SETTING):
		ProjectSettings.set_setting(ProjectPipeline.SETTING, "")
		ProjectSettings.set_initial_value(ProjectPipeline.SETTING, "")
	ProjectSettings.set_as_basic(ProjectPipeline.SETTING, true)
	ProjectSettings.add_property_info({
		"name": ProjectPipeline.SETTING,
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_FILE,
		"hint_string": "*.tres,*.res",
	})
	_sync_project_pipeline_setting()

## Whether the project renders with FRP. The project setting is read, not the running
## renderer: this decides what the dialog offers, and the project setting is both what the
## user edits there and what the next start uses.
func _project_renders_with_frp() -> bool:
	return String(ProjectSettings.get_setting("rendering/renderer/rendering_method", "forward_plus")) == "frp"

## Offers the compositor row only for the renderer that reads it.
func _sync_project_pipeline_setting() -> void:
	ProjectSettings.set_as_internal(ProjectPipeline.SETTING, not _project_renders_with_frp())

## The editor half of the project pipeline runs here; a running game needs a node of its
## own, which is what the autoload is. Enabling the plugin adds it, disabling removes it,
## and the value is only written when it does not already point at this script - the
## editor stores autoloads as "*" + a UID, while a hand-written project.godot names the
## path, so both forms are resolved before they are compared.
func _ensure_pipeline_autoload() -> void:
	var path := FengAddonLayout.pipeline_autoload_path()
	var existing := String(ProjectSettings.get_setting("autoload/" + PIPELINE_AUTOLOAD, ""))
	if existing.begins_with("*") and ProjectPipeline.names(existing, path):
		return
	add_autoload_singleton(PIPELINE_AUTOLOAD, path)

func _on_project_settings_changed() -> void:
	# The rendering method is one of the settings that can change here, and it decides
	# whether the compositor row is offered at all.
	_sync_project_pipeline_setting()
	_sync_project_pipeline()

func _on_editor_node_added(p_node) -> void:
	if p_node is WorldEnvironment:
		_sync_project_pipeline.call_deferred()

func _on_editor_node_removed(p_node) -> void:
	if is_instance_valid(p_node) and p_node is WorldEnvironment:
		_sync_project_pipeline.call_deferred()

## Keeps the editor's own world in sync with the setting, so the Scene view renders the
## same pipeline the game does.
func _sync_project_pipeline() -> void:
	_project_pipeline = ProjectPipeline.install(self, _project_pipeline)

func _detach_project_pipeline() -> void:
	if ProjectSettings.settings_changed.is_connected(_on_project_settings_changed):
		ProjectSettings.settings_changed.disconnect(_on_project_settings_changed)
	if get_tree() != null:
		if get_tree().node_added.is_connected(_on_editor_node_added):
			get_tree().node_added.disconnect(_on_editor_node_added)
		if get_tree().node_removed.is_connected(_on_editor_node_removed):
			get_tree().node_removed.disconnect(_on_editor_node_removed)
	ProjectPipeline.clear(_project_pipeline)
	_project_pipeline = null

func _refresh_library() -> void:
	if _menu == null:
		return
	_menu.clear()
	_library_entries.clear()
	var lib_dir := FengAddonLayout.library_dir()

	# The manifest is the canonical order and gives entries a stable identity.
	# Scan afterward so a locally added template is still available before the
	# next manifest update.
	var manifest_paths := {}
	for manifest in LibraryManager.DEFAULT_LIBRARY_ENTRIES:
		var path := lib_dir + "/" + String(manifest["path"])
		manifest_paths[path] = true
		if ResourceLoader.exists(path):
			_add_library_entry(path, manifest)

	var directories: Array[String] = []
	var root := DirAccess.open(lib_dir)
	if root == null:
		return
	root.list_dir_begin()
	var directory_name := root.get_next()
	while directory_name != "":
		if root.current_is_dir() and not directory_name.begins_with("."):
			directories.append(directory_name)
		directory_name = root.get_next()
	root.list_dir_end()
	directories.sort()

	for directory in directories:
		var sub := DirAccess.open(lib_dir + "/" + directory)
		if sub == null:
			continue
		var files: Array[String] = []
		sub.list_dir_begin()
		var file_name := sub.get_next()
		while file_name != "":
			if not sub.current_is_dir() and file_name.ends_with(".tres"):
				files.append(file_name)
			file_name = sub.get_next()
		sub.list_dir_end()
		files.sort()
		for file in files:
			var path := lib_dir + "/%s/%s" % [directory, file]
			if not manifest_paths.has(path):
				_add_library_entry(path, {})

func _add_library_entry(path: String, manifest: Dictionary) -> void:
	var template = load(path)
	if template == null or not template is PassBase:
		return

	var label := ""
	if template is Resource:
		label = String(template.resource_name).strip_edges()
	if label == "" and not manifest.is_empty():
		label = String(manifest.get("name", "")).strip_edges()
	if label == "":
		label = path.get_file().get_basename().replace("_", " ").capitalize()
	label = _make_unique_library_label(label, path)

	var menu_id := _library_entries.size()
	_library_entries.append({"path": path, "manifest": manifest, "label": label})
	_menu.add_item(label, menu_id)
	_menu.set_item_tooltip(menu_id, path)

func _make_unique_library_label(base: String, path: String) -> String:
	var label := base
	if not _library_label_exists(label):
		return label
	var directory := path.get_base_dir().get_file().replace("_", " ").capitalize()
	var file_stem := path.get_file().get_basename().replace("_", " ").capitalize()
	var suffix := directory if directory != "" else file_stem
	label = "%s (%s)" % [base, suffix]
	var ordinal := 2
	while _library_label_exists(label):
		label = "%s (%s %d)" % [base, file_stem, ordinal]
		ordinal += 1
	return label

func _library_label_exists(label: String) -> bool:
	for entry in _library_entries:
		if entry.get("label", "") == label:
			return true
	return false

func _on_library_item(id: int) -> void:
	if id < 0 or id >= _library_entries.size():
		return
	var renderer = _find_selected_renderer()
	if renderer == null:
		push_error("FengRenderPipeline: edit a FengRenderer or FengCompositor resource in the inspector first.")
		return

	var path: String = _library_entries[id]["path"]
	var template = load(path)
	if template == null or not template is PassBase:
		push_error("FengRenderPipeline: cannot load library template %s" % path)
		return
	var instance = template.duplicate(true) as PassBase
	var manifest: Variant = LibraryManager.manifest_for_path(path)
	if manifest != null:
		LibraryManager.configure_library_pass(instance, manifest)

	var current: Array = renderer.passes.duplicate()
	var next: Array = current.duplicate()
	next.insert(LibraryManager.calculate_insert_index(current, instance.stable_id), instance)
	var metadata := _metadata_after_library_add(renderer, path)
	_record_renderer_change(renderer, next, "Add FRP Pass from Library", metadata)
	_refresh_inspector()

## Move an authored pass using the same whole-array transaction as the library
## menu. This is used by editor controls and keeps reordering undoable even
## when a renderer contains library metadata or tombstones.
func move_pass(renderer, from_index: int, to_index: int) -> void:
	if renderer == null:
		return
	var current: Array = renderer.passes.duplicate()
	if from_index < 0 or from_index >= current.size() or to_index < 0 or to_index >= current.size() or from_index == to_index:
		return
	var next: Array = current.duplicate()
	var moved = next.pop_at(from_index)
	next.insert(to_index, moved)
	_record_renderer_change(renderer, next, "Move FRP Pass", _snapshot_renderer_metadata(renderer))
	_refresh_inspector()

func _record_renderer_change(renderer, next_passes: Array, action_name: String, next_metadata: Dictionary) -> void:
	var old_passes: Array = renderer.passes.duplicate()
	var old_metadata := _snapshot_renderer_metadata(renderer)
	var undo_redo = get_undo_redo()
	if undo_redo == null:
		renderer.passes = next_passes
		_apply_renderer_metadata(renderer, next_metadata)
		renderer.emit_changed()
		return

	# The renderer is the custom context, so the editor associates nested
	# resource edits with the renderer rather than the selected scene object.
	undo_redo.create_action(action_name, UndoRedo.MERGE_DISABLE, renderer)
	undo_redo.add_do_property(renderer, "passes", next_passes)
	undo_redo.add_undo_property(renderer, "passes", old_passes)
	for property_name in Renderer.PERSISTED_STATE_FIELDS:
		undo_redo.add_do_property(renderer, property_name, next_metadata[property_name])
		undo_redo.add_undo_property(renderer, property_name, old_metadata[property_name])
	# Metadata is exported storage and its setter does not necessarily emit a
	# Resource.changed notification. Explicit notifications keep inspector,
	# compositor synchronization, and scene/resource save state current on both
	# sides of the undo action.
	undo_redo.add_do_method(renderer, "emit_changed")
	undo_redo.add_undo_method(renderer, "emit_changed")
	undo_redo.commit_action()

func _snapshot_renderer_metadata(renderer) -> Dictionary:
	var metadata := {}
	for property_name in Renderer.PERSISTED_STATE_FIELDS:
		var value = renderer.get(property_name)
		metadata[property_name] = value.duplicate() if value is Array else value
	return metadata

func _apply_renderer_metadata(renderer, metadata: Dictionary) -> void:
	for property_name in Renderer.PERSISTED_STATE_FIELDS:
		renderer.set(property_name, metadata[property_name])

## The state the pipeline has to carry once a library entry was inserted: the entry is
## recorded as present and its tombstone, if it had one, is lifted. It is computed on the
## snapshot rather than on the renderer, because the same values have to be written by
## the undo action.
func _metadata_after_library_add(renderer, path: String) -> Dictionary:
	var metadata := _snapshot_renderer_metadata(renderer)
	var manifest: Variant = LibraryManager.manifest_for_path(path)
	var synced_paths: Array = metadata["_synced_library"]
	var synced_ids: Array = metadata["_synced_library_ids"]
	var deleted_paths: Array = metadata["_deleted_library"]
	var deleted_ids: Array = metadata["_deleted_library_ids"]
	if manifest != null:
		LibraryManager.mark_synced(manifest, synced_paths, synced_ids, deleted_paths, deleted_ids)
	else:
		_append_unique(synced_paths, LibraryManager.normalize_library_path(path))
	metadata["_synced_library"] = synced_paths
	metadata["_synced_library_ids"] = synced_ids
	metadata["_deleted_library"] = deleted_paths
	metadata["_deleted_library_ids"] = deleted_ids
	return metadata

func _append_unique(values: Array, value: String) -> void:
	if value != "" and not values.has(value):
		values.append(value)

func _find_selected_renderer():
	var edited = _get_edited_object()
	if edited == null:
		return null
	var script = edited.get_script()
	if script == Renderer:
		return edited
	if script == CompositorScript:
		return edited.renderer
	return null

func _get_edited_object():
	var inspector := EditorInterface.get_inspector()
	return inspector.get_edited_object() if inspector != null else null

func _refresh_inspector() -> void:
	var inspector := EditorInterface.get_inspector()
	if inspector != null:
		var edited = inspector.get_edited_object()
		if edited != null:
			edited.notify_property_list_changed()
