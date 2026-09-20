@tool
extends Node
## Editor cameras are not the edited scene's current Camera3D. Give each view
## its own transient compositor so camera positions never share Volume state.
## No editor API or preview resources are needed by the runtime evaluator.

const VolumeRuntime = preload("../volume/volume_runtime.gd")
const VolumeMetrics = preload("../volume/volume_metrics.gd")

var _views: Dictionary = {}

func _process(_delta: float) -> void:
	var started := Time.get_ticks_usec()
	_update_preview()
	VolumeMetrics.record(1, Time.get_ticks_usec() - started)

func _update_preview() -> void:
	var root := EditorInterface.get_edited_scene_root()
	var volumes := VolumeRuntime.get_scene_volumes(root)
	var current: Array = []
	if not volumes.is_empty():
		for index in range(4):
			var viewport := EditorInterface.get_editor_viewport_3d(index)
			# Hidden editor views need no parameter evaluation or GPU effect copies.
			if viewport == null or (viewport.get_parent() is CanvasItem and not viewport.get_parent().is_visible_in_tree()):
				continue
			var camera := viewport.get_camera_3d()
			if camera == null:
				continue
			var id := camera.get_instance_id()
			var state: Dictionary = _views.get(id, {})
			if not state.is_empty() and state.scene_id != root.get_instance_id():
				_restore(id)
				state = {}
			var view_volumes: Array = []
			for volume in volumes:
				if volume.get_world_3d() == viewport.find_world_3d() and volume.influence_at(camera.global_position) > 0.0:
					view_volumes.append(volume)
			if view_volumes.is_empty():
				if not state.is_empty():
					_detach(state)
					current.append(id)
				continue
			var original: Compositor = camera.compositor
			if not state.is_empty() and original == state.preview:
				original = state.original
			var source: Compositor = original if original != null else FengWorldCompositor.world_compositor(viewport)
			if not source is FengCompositor:
				continue
			if state.is_empty():
				state = {"camera": weakref(camera), "original": original, "preview": FengCompositor.new(),
						"scene_id": root.get_instance_id(), "attached": false}
				_views[id] = state
			elif camera.compositor != state.preview and camera.compositor != state.original:
				# Another editor tool changed the camera; restore that new source later.
				state.original = original
			var preview: FengCompositor = state.preview
			preview.renderer = source.renderer
			VolumeRuntime.evaluate_camera(view_volumes, camera, preview)
			if camera.compositor != preview:
				camera.compositor = preview
			state.attached = true
			current.append(id)
	for id in _views.keys():
		if not current.has(id):
			_restore(id)

func _detach(state: Dictionary) -> void:
	if not state.attached:
		return
	var camera = state.camera.get_ref()
	if is_instance_valid(camera) and camera.compositor == state.preview:
		camera.compositor = state.original
	state.preview.set_volume_parameters({}, {})
	VolumeRuntime.forget_camera(state.preview)
	state.attached = false

func _restore(p_id: int) -> void:
	var state: Dictionary = _views[p_id]
	_detach(state)
	VolumeRuntime.forget_camera(state.preview)
	_views.erase(p_id)

func _exit_tree() -> void:
	for id in _views.keys():
		_restore(id)
