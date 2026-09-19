@tool
extends EditorPlugin
## Adds an "Add Pass from Library" menu for FengRenderer resources.
##
## FengRenderer and FengCompositor are resources, so the inspector's edited
## object is the source of truth. Scene selection is deliberately not used:
## either resource can be nested in a scene or edited as a standalone .tres.

const Renderer = preload("renderer.gd")
const ProjectPipeline = preload("project_pipeline.gd")

const PIPELINE_AUTOLOAD := "FengProjectPipeline"


const FengRendererInspectorPlugin = preload("editor/renderer_inspector_plugin.gd")
const FengVolumeInspectorPlugin = preload("editor/volume_inspector_plugin.gd")
const FengVolumeGizmoPlugin = preload("volume/feng_volume_gizmo.gd")
const VolumePreview = preload("editor/volume_preview.gd")
const PassLibraryController = preload("editor/pass_library_controller.gd")


var _inspector_plugin
var _volume_inspector_plugin
var _volume_gizmo_plugin
var _volume_preview: Node
var _library_controller
var _project_pipeline: WorldEnvironment = null

## Compatibility views for existing editor integrations and regression tests. The
## Library state itself lives in PassLibraryController.
var _menu: PopupMenu:
	get:
		return _library_controller.get_menu() if is_instance_valid(_library_controller) else null
var _library_entries:
	get:
		return _library_controller.get_library_entries() if is_instance_valid(_library_controller) else []

func _enter_tree() -> void:
	_volume_preview = VolumePreview.new()
	add_child(_volume_preview)
	_volume_gizmo_plugin = FengVolumeGizmoPlugin.new()
	add_node_3d_gizmo_plugin(_volume_gizmo_plugin)

	_inspector_plugin = FengRendererInspectorPlugin.new(Renderer)
	add_inspector_plugin(_inspector_plugin)
	_volume_inspector_plugin = FengVolumeInspectorPlugin.new(self)
	add_inspector_plugin(_volume_inspector_plugin)

	_library_controller = PassLibraryController.new(self)
	add_child(_library_controller)
	_library_controller.setup()

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
	if is_instance_valid(_volume_preview):
		_volume_preview.free()
		_volume_preview = null
	if _volume_inspector_plugin != null:
		remove_inspector_plugin(_volume_inspector_plugin)
		_volume_inspector_plugin = null
	if _volume_gizmo_plugin != null:
		remove_node_3d_gizmo_plugin(_volume_gizmo_plugin)
		_volume_gizmo_plugin = null
	if _inspector_plugin != null:
		remove_inspector_plugin(_inspector_plugin)
		_inspector_plugin = null
	if is_instance_valid(_library_controller):
		_library_controller.shutdown()
		_library_controller.free()
		_library_controller = null
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
	if is_instance_valid(_library_controller):
		_library_controller.refresh_library()

func _add_library_entry(path: String, manifest: Dictionary) -> void:
	# Kept as a compatibility entry point for editor integrations that refreshed
	# individual entries in older versions; all actual work is controller-owned.
	if is_instance_valid(_library_controller):
		_library_controller._add_library_entry(path, manifest)

func _make_unique_library_label(base: String, path: String) -> String:
	return _library_controller._make_unique_library_label(base, path) if is_instance_valid(_library_controller) else base

func _library_label_exists(label: String) -> bool:
	return _library_controller._library_label_exists(label) if is_instance_valid(_library_controller) else false

func _on_library_item(id: int) -> void:
	if is_instance_valid(_library_controller):
		_library_controller.on_library_item(id)

## Move an authored pass using the same whole-array transaction as the library
## menu. This is used by editor controls and keeps reordering undoable even
## when a renderer contains library metadata or tombstones.
func move_pass(renderer, from_index: int, to_index: int) -> void:
	if is_instance_valid(_library_controller):
		_library_controller.move_pass(renderer, from_index, to_index)

func _find_selected_renderer():
	return _library_controller.find_selected_renderer() if is_instance_valid(_library_controller) else null

func _get_edited_object():
	return _library_controller.get_edited_object() if is_instance_valid(_library_controller) else null

func _refresh_inspector() -> void:
	if is_instance_valid(_library_controller):
		_library_controller.refresh_inspector()
