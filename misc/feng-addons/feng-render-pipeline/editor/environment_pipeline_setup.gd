@tool
extends RefCounted
## Creation-time dependencies for the Environment Mixer. Never runs per frame.

const Renderer = preload("../renderer.gd")
const CompositorScript = preload("../compositor.gd")
const ProjectPipeline = preload("../project_pipeline.gd")
const Library = preload("../pipeline/library_manager.gd")

const REQUIRED_PASSES := {
	&"sky_atmosphere": [&"library:height_fog"], # Aerial perspective also uses this pass.
	&"height_fog": [&"library:height_fog"],
	&"volumetric_cloud": [&"library:cloud_shadow", &"library:volumetric_cloud",
		&"library:height_fog", &"library:cloud_trace"],
}

static func prepare(scene_root: Node, created: Array[Node], component_ids: Array) -> Dictionary:
	var result := {"bindings": [], "edits": []}
	if ProjectSettings.get_setting("rendering/renderer/rendering_method", "") != "frp":
		return result
	var required: Array[StringName] = []
	for component_id in component_ids:
		for pass_id in REQUIRED_PASSES.get(component_id, []):
			if not required.has(pass_id):
				required.append(pass_id)
	if required.is_empty():
		return result

	var compositors: Array[Compositor] = []
	var world_has_compositor := false
	var environment_host: WorldEnvironment
	var pending: Array[Node] = [scene_root]
	pending.append_array(created)
	var cursor := 0
	while cursor < pending.size():
		var node := pending[cursor]
		cursor += 1
		if node is SubViewport:
			continue
		if node is WorldEnvironment:
			environment_host = node
			world_has_compositor = world_has_compositor or node.compositor != null
		if node is WorldEnvironment or node is Camera3D:
			var compositor: Compositor = node.compositor
			if compositor != null and not compositors.has(compositor):
				compositors.append(compositor)
		pending.append_array(node.get_children(false))
	if not world_has_compositor:
		var project_compositor := ProjectPipeline.resolve()
		if project_compositor != null:
			if not compositors.has(project_compositor):
				compositors.append(project_compositor)
		else:
			# A scene without a project pipeline still needs the cloud/fog passes.
			# Store its default pipeline in the scene, so undo/save remain ordinary
			# scene operations and no extra project assets are silently created.
			if environment_host == null:
				environment_host = WorldEnvironment.new()
				environment_host.name = "EnvironmentPipeline"
				created.append(environment_host)
			var compositor := CompositorScript.new()
			compositor.renderer = Renderer.new()
			result.bindings.append({"node": environment_host, "compositor": compositor})
			compositors.append(compositor)

	var visited: Array[Resource] = []
	for compositor in compositors:
		if not compositor is CompositorScript or compositor.renderer == null \
				or visited.has(compositor.renderer):
			continue
		visited.append(compositor.renderer)
		var edit := plan_passes(compositor.renderer, required)
		if not edit.is_empty():
			result.edits.append(edit)
	return result

static func plan_passes(renderer: Renderer, required: Array[StringName]) -> Dictionary:
	var previous := renderer.passes.duplicate()
	var next := previous.duplicate()
	var old_metadata := {}
	var metadata := {}
	for property_name in Renderer.PERSISTED_STATE_FIELDS:
		var value: Variant = renderer.get(property_name)
		old_metadata[property_name] = value.duplicate() if value is Array else value
		metadata[property_name] = value.duplicate() if value is Array else value
	var enable: Array[Resource] = []
	for pass_id in required:
		var manifest: Variant = Library.manifest_entry(pass_id)
		if manifest == null:
			continue
		var entry: Variant = Library.find_matching_library_pass(next, manifest)
		if entry == null:
			var template: Variant = Library.load_template(manifest)
			if template == null:
				continue
			entry = template.duplicate(true)
			Library.configure_library_pass(entry, manifest)
			entry.enabled = true
			next.insert(Library.calculate_insert_index(next, pass_id), entry)
			Library.mark_synced(manifest, metadata._synced_library, metadata._synced_library_ids,
					metadata._deleted_library, metadata._deleted_library_ids)
		elif not entry.enabled:
			enable.append(entry)
	if enable.is_empty() and next == previous:
		return {}
	return {"renderer": renderer, "previous": previous, "next": next,
		"enable": enable, "old_metadata": old_metadata, "metadata": metadata}

static func record(undo_redo: Object, setup: Dictionary) -> void:
	for binding in setup.bindings:
		undo_redo.add_do_property(binding.node, "compositor", binding.compositor)
		undo_redo.add_undo_property(binding.node, "compositor", binding.node.compositor)
	for edit in setup.edits:
		undo_redo.add_do_property(edit.renderer, "passes", edit.next)
		undo_redo.add_undo_property(edit.renderer, "passes", edit.previous)
		for property_name in Renderer.PERSISTED_STATE_FIELDS:
			undo_redo.add_do_property(edit.renderer, property_name, edit.metadata[property_name])
			undo_redo.add_undo_property(edit.renderer, property_name, edit.old_metadata[property_name])
		for entry in edit.enable:
			undo_redo.add_do_property(entry, "enabled", true)
			undo_redo.add_undo_property(entry, "enabled", false)
		undo_redo.add_do_method(edit.renderer, "emit_changed")
		undo_redo.add_undo_method(edit.renderer, "emit_changed")
