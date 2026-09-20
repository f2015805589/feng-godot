@tool
extends RefCounted
## Registration, viewport routing and override lifetime. Depends on the Volume
## spatial/profile protocol, not its concrete node class or editor APIs.

const Metrics = preload("volume_metrics.gd")
const Evaluator = preload("volume_evaluator.gd")

static var _volumes: Array[Node3D] = []
static var _last_frame := -1
static var _pushed: Dictionary = {}
static var _samples: Dictionary = {}

static func register(volume: Node3D) -> void:
	if not _volumes.has(volume):
		_volumes.append(volume)
		Metrics.acquire()

static func unregister(volume: Node3D) -> void:
	var registered := _volumes.has(volume)
	_volumes.erase(volume)
	# Clear the last contribution even when no Volume remains to tick next frame.
	evaluate_all()
	if registered:
		Metrics.release()

static func tick() -> void:
	if Engine.is_editor_hint():
		return
	var frame := Engine.get_process_frames()
	if _last_frame != frame:
		_last_frame = frame
		evaluate_all()

static func get_scene_volumes(root: Node) -> Array:
	var result: Array = []
	if not is_instance_valid(root):
		return result
	for volume in _volumes:
		if is_instance_valid(volume) and volume.is_inside_tree() and (volume == root or root.is_ancestor_of(volume)):
			result.append(volume)
	return result

static func evaluate_all() -> void:
	var started := Time.get_ticks_usec()
	_evaluate_all()
	Metrics.record(0, Time.get_ticks_usec() - started)

static func _evaluate_all() -> void:
	# Editor camera discovery and transient compositor ownership are provided by
	# editor/volume_preview.gd. They never enter the runtime viewport registry.
	if Engine.is_editor_hint() or (_volumes.is_empty() and _pushed.is_empty()):
		return
	var viewports := {}
	for volume in _volumes:
		if not is_instance_valid(volume) or not volume.is_inside_tree() or not volume.enabled or volume.profile == null or volume.weight <= 0.0:
			continue
		var viewport := volume.get_viewport()
		if viewport != null:
			if not viewports.has(viewport):
				viewports[viewport] = []
			viewports[viewport].append(volume)
	var current := {}
	for viewport in viewports:
		var camera: Camera3D = viewport.get_camera_3d()
		if camera == null:
			continue
		var compositor := FengWorldCompositor.active_compositor(viewport, camera)
		if not compositor is FengCompositor:
			continue
		current[compositor.get_instance_id()] = weakref(compositor)
		evaluate_camera(viewports[viewport], camera, compositor)
	for id in _pushed:
		if not current.has(id):
			var compositor = _pushed[id].get_ref()
			if compositor is FengCompositor:
				compositor.set_volume_parameters({}, {})
			_samples.erase(id)
	_pushed = current

static func evaluate_camera(volumes: Array, camera: Camera3D, compositor: FengCompositor) -> bool:
	var id := compositor.get_instance_id()
	var view: Dictionary = _samples.get(id, {})
	if view.is_empty():
		view = {"compositor": weakref(compositor), "evaluator": Evaluator.new()}
		_samples[id] = view
	var evaluator = view.evaluator
	var resolved: Dictionary = evaluator.evaluate(volumes, camera.global_position, compositor.renderer)
	if resolved.is_empty():
		return false
	# Weak ownership avoids retaining removed cameras/resources. Keep this scan
	# off the unchanged hot path; a new or changed view is enough to amortize it.
	for old_id in _samples.keys():
		if _samples[old_id].compositor.get_ref() == null:
			_samples.erase(old_id)
	compositor.set_volume_parameters(resolved.parameters, resolved.pass_states)
	return true

static func forget_camera(compositor: FengCompositor) -> void:
	_samples.erase(compositor.get_instance_id())
