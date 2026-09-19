extends Node
## The project's FRP pipeline, installed into the world that is being rendered.
##
## A viewport renders the FRP schedule of the compositor on its camera, else the one on
## its world (a WorldEnvironment), else nothing. The editor's free-look camera and the
## running game are different cameras, so a Compositor hung on the game's Camera3D
## reaches only one of the two - and a Renderer resource that is merely created or
## selected reaches neither. This node closes that gap with the mechanism the engine
## already has: a WorldEnvironment carrying the project's Compositor, added to whichever
## tree renders. It is the runtime half of one project setting, next to the renderer it
## belongs to:
##
##     Project Settings > Rendering > Renderer > Compositor
##
## The editor plugin only offers that row while FRP is the project's rendering method (see
## editor_plugin.gd). The editor plugin installs the same thing into the editor's own tree,
## so the Scene view and the running game are the same renderer, switched on in the same
## place. A scene that brings its own compositor keeps it: this node steps aside while
## another WorldEnvironment in the same world provides one, and takes the world back when
## that compositor is gone.
##
## Registered as an autoload by the editor plugin (see editor_plugin.gd); it is a no-op
## while the setting is empty. It is deliberately not a tool script: the editor's own
## tree is the editor plugin's job, so exactly one installer runs per tree.

const CompositorScript = preload("compositor.gd")

## Project setting that names the pipeline: a FengCompositor resource, or a bare
## FengRenderer, which is wrapped in a FengCompositor on the fly. It sits in the renderer
## section, next to `rendering/renderer/rendering_method`.
const SETTING := "rendering/renderer/compositor"
const NODE_NAME := "FengProjectPipeline"

# Resolving the setting means loading a resource, and both trees (the editor and the
# game) ask for it repeatedly (every settings change, every WorldEnvironment change), so
# the loaded pipeline is kept between calls and only reloaded when the path changes.
static var _cached_path := ""
static var _cached_compositor: Compositor = null
static var _warned_unresolved := false

var _installed: WorldEnvironment = null


func _ready() -> void:
	# The setting is edited in a Project Settings dialog that is usually the running
	# editor, and scenes can add their own WorldEnvironment at any time, so the world is
	# re-checked when either happens.
	ProjectSettings.settings_changed.connect(_sync)
	# Not deferred: node_removed hands over the node being freed, so the type has to be
	# read while it still exists. The work itself is deferred either way, so no tree is
	# modified from inside another node's tree notification.
	get_tree().node_added.connect(_on_node_added)
	get_tree().node_removed.connect(_on_node_removed)
	_sync()


func _exit_tree() -> void:
	if ProjectSettings.settings_changed.is_connected(_sync):
		ProjectSettings.settings_changed.disconnect(_sync)
	if get_tree() != null:
		if get_tree().node_added.is_connected(_on_node_added):
			get_tree().node_added.disconnect(_on_node_added)
		if get_tree().node_removed.is_connected(_on_node_removed):
			get_tree().node_removed.disconnect(_on_node_removed)
	clear(_installed)
	_installed = null


func _on_node_added(p_node) -> void:
	if p_node is WorldEnvironment:
		_sync.call_deferred()


func _on_node_removed(p_node) -> void:
	if is_instance_valid(p_node) and p_node is WorldEnvironment:
		_sync.call_deferred()


func _sync() -> void:
	_installed = install(self, _installed)


# Static API, shared with the editor plugin: the plugin runs the same install into the
# editor's tree instead of the game's.

## Puts the project's pipeline into the world `p_host` renders, and returns the
## WorldEnvironment carrying it: the node that was passed in when it is already
## installed, a new one when it had to be added, and null when the project names no
## pipeline or a scene-authored compositor owns that world. `p_current` is the node the
## caller kept from the previous call.
static func install(p_host: Node, p_current: WorldEnvironment) -> WorldEnvironment:
	if p_host == null or not p_host.is_inside_tree():
		return p_current
	var desired := resolve()
	if desired != null and _world_has_another_compositor(p_host, p_current):
		desired = null
	if desired == null:
		clear(p_current)
		return null
	var node := p_current
	if node == null or not is_instance_valid(node):
		node = WorldEnvironment.new()
		node.name = NODE_NAME
		p_host.add_child(node)
	if node.compositor != desired:
		node.compositor = desired
	return node


## Detaches and frees the WorldEnvironment this module installed. Clearing the
## compositor first is what hands the world back to its own WorldEnvironment.
static func clear(p_node: WorldEnvironment) -> void:
	if p_node == null or not is_instance_valid(p_node):
		return
	p_node.compositor = null
	p_node.queue_free()


## The Compositor the project setting names, or null when the project has none: an empty
## setting, a project that no longer renders with FRP, or a path that does not load.
static func resolve() -> Compositor:
	var path := String(ProjectSettings.get_setting(SETTING, "")).strip_edges()
	if path.is_empty():
		return null
	# The schedule is FRP's own: a project that switched rendering method (or fell back to
	# another renderer) keeps the setting, but must not push an FRP pipeline into it. The
	# active method is asked for, not the project setting, because the command line and
	# the engine's fallbacks can override it.
	if RenderingServer.get_current_rendering_method() != "frp":
		return null
	if path.begins_with("uid://"):
		var resolved := resolve_path(path)
		if resolved.is_empty():
			if not _warned_unresolved:
				_warned_unresolved = true
				push_warning("FengProjectPipeline: '%s' is a UID this session cannot resolve (the editor's UID cache does not know it yet); pick the file again or restart the editor." % path)
			return null
		path = resolved
	if path == _cached_path and _cached_compositor != null:
		return _cached_compositor
	_cached_path = path
	_cached_compositor = null
	if not ResourceLoader.exists(path):
		return null
	var resource := ResourceLoader.load(path)
	if resource is Compositor:
		_cached_compositor = resource
	elif resource != null and resource.get("passes") != null:
		# A pipeline resource on its own (a FengRenderer) is wrapped: the engine reads a
		# schedule from a Compositor, and this is the wrapper the inspector shows too.
		var wrapper = CompositorScript.new()
		wrapper.renderer = resource
		_cached_compositor = wrapper
	return _cached_compositor


## A resource path with a `uid://` reference resolved to the path behind it, or an empty
## string when the reference cannot be resolved. The file picker can store a UID instead
## of a path, so a settings value has to be resolved before it is loaded.
static func resolve_path(p_value: String) -> String:
	var value := p_value.strip_edges()
	if not value.begins_with("uid://"):
		return value
	# The cache check comes first on purpose: asking for an unknown uid's path is logged
	# as an engine error, and a uid the cache does not know is not usable either way.
	var uid := ResourceUID.text_to_id(value)
	if uid == ResourceUID.INVALID_ID or not ResourceUID.has_id(uid):
		return ""
	return ResourceUID.get_id_path(uid)


## Whether a stored value names `p_path`. Accepts the `*uid://...` form an autoload is
## written as. A uid the cache cannot resolve yet - the editor writes one the moment the
## value is created, while the cache is filled by its own file scan - is compared the
## other way round: a path knows its own uid.
static func names(p_value: String, p_path: String) -> bool:
	var value := p_value.strip_edges()
	if value.begins_with("*"):
		value = value.substr(1)
	if value == p_path or value == p_path.get_file():
		return true
	if not value.begins_with("uid://"):
		return false
	return ResourceUID.path_to_uid(p_path) == value


## Whether another WorldEnvironment provides a compositor for the world `p_host` renders.
##
## The engine decides a world's compositor through the `_world_compositor_<scenario>`
## group: whichever member is first in it provides the compositor for the whole world, so
## any other member with a compositor is an author's compositor for that world.
static func _world_has_another_compositor(p_host: Node, p_current: WorldEnvironment) -> bool:
	var world := p_host.get_viewport().find_world_3d()
	if world == null:
		return false
	var group := "_world_compositor_" + str(world.get_scenario().get_id())
	for node in p_host.get_tree().get_nodes_in_group(group):
		if node == p_current:
			continue
		if node is WorldEnvironment and (node as WorldEnvironment).compositor != null:
			return true
	return false
