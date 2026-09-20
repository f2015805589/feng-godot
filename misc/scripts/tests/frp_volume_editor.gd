@tool
extends EditorPlugin
## Editor regression for the FRP Volume module inspector.
##
## The test is copied into an isolated editor project by the FRP test runner.  It
## deliberately uses the addon's editor plugin, then exercises the registered
## inspector through EditorInterface as well as its undoable helper actions.

const Renderer = preload("res://addons/feng-render-pipeline/renderer.gd")
const PipelinePlugin = preload("res://addons/feng-render-pipeline/editor_plugin.gd")
const CompositorScript = preload("res://addons/feng-render-pipeline/compositor.gd")
const Volume = preload("res://addons/feng-render-pipeline/volume/feng_volume.gd")
const Profile = preload("res://addons/feng-render-pipeline/volume/feng_volume_profile.gd")
const Module = preload("res://addons/feng-render-pipeline/volume/feng_volume_module.gd")
const Inspector = preload("res://addons/feng-render-pipeline/editor/volume_inspector_plugin.gd")

var pipeline_plugin: EditorPlugin
var inspector: Inspector


func _enter_tree() -> void:
	_run.call_deferred()


func _run() -> void:
	# This mirrors the existing editor test: the test project does not enable the
	# addon itself, so load it as a child EditorPlugin before using its inspector.
	pipeline_plugin = PipelinePlugin.new()
	add_child(pipeline_plugin)
	await get_tree().process_frame
	await get_tree().process_frame
	inspector = pipeline_plugin._volume_inspector_plugin as Inspector
	assert(inspector != null, "the FRP editor plugin did not register the Volume inspector")

	var renderer := Renderer.new()
	var source = _find_taa_source(renderer)
	assert(source != null, "the renderer did not expose Temporal AA as a Volume module")
	var authored: Dictionary = renderer.get_authored_pass_parameters()
	var source_key: Variant = source.get_parameter_key()
	assert(authored.has(source_key), "authored pass parameters are not keyed by the module source")

	var profile := Profile.new()
	var profile_key := profile.get_instance_id()
	# The picker is editor-only state.  Deliver the same event as the resource
	# picker; the profile must not gain a renderer property.
	inspector._on_renderer_picked(renderer, profile, profile_key)
	assert(inspector.resolve_renderer(profile, profile_key) == renderer,
			"the explicitly picked renderer was not used for an independent profile")
	assert(_property_exists(profile, "modules") and not _property_exists(profile, "renderer"),
			"the independent renderer choice leaked into the runtime profile schema")

	EditorInterface.inspect_object(profile)
	await _settle_inspector()
	var picker := EditorInterface.get_inspector().find_child("FengVolumeRendererPicker", true, false) as EditorResourcePicker
	assert(picker != null and picker.get_base_type() == "FengRenderer",
			"the profile inspector did not provide a Renderer resource picker")
	var add_button := EditorInterface.get_inspector().find_child("FengVolumeAddModule", true, false) as MenuButton
	assert(add_button != null, "the profile inspector did not provide an Add Module button")

	# Select a module through the actual popup.  The popup contains only author
	# declared candidates, so no per-field override checkbox can be introduced.
	var menu_index := _menu_index_for_source(add_button.get_popup(), source)
	assert(menu_index >= 0, "the pass-author-declared module was missing from the Add menu")
	add_button.get_popup().id_pressed.emit(menu_index)
	await _settle_inspector()
	assert(profile.modules.size() == 1, "Add Module did not append a profile module")
	var module: Module = profile.modules[0]
	assert(module.pass_source == source, "the selected module did not retain its pass source")
	assert(module.get_parameter_key() == source_key, "module identity changed while being added")
	assert(_has_dynamic_parameter(module, "jitter_phases"),
			"module dynamic fields did not come from the pass Resource")
	assert(not _has_dynamic_parameter(module, "override"),
			"the inspector added a forbidden per-parameter override field")

	# The same source cannot be selected twice.  Calling the public helper directly
	# also covers a stale popup or another editor integration invoking the action.
	assert(inspector.add_module(profile, source, renderer) == module,
			"duplicate module selection created a second module")
	assert(profile.modules.size() == 1, "duplicate module selection changed the profile")

	var undo := get_undo_redo()
	var profile_history := undo.get_history_undo_redo(undo.get_object_history_id(profile))
	assert(profile_history != null, "adding a Volume module did not create an undo history")
	profile_history.undo()
	assert(profile.modules.is_empty(), "undo did not remove the selected Volume module")
	profile_history.redo()
	assert(profile.modules.size() == 1, "redo did not restore the selected Volume module")

	# A stale/missing source remains visible as an explicit warning in the profile
	# inspector rather than silently producing an inert module.
	var missing := Module.new()
	profile.modules = [missing]
	EditorInterface.inspect_object(profile)
	await _settle_inspector()
	var missing_label: Variant = _find_label_containing(EditorInterface.get_inspector(), "Missing pass source")
	assert(missing_label != null, "a module with no source did not produce an explicit inspector warning")
	profile.modules = [module]

	# A Volume with no profile can create one through an undoable editor action.
	var volume := Volume.new()
	add_child(volume)
	EditorInterface.inspect_object(volume)
	await _settle_inspector()
	var create_button := EditorInterface.get_inspector().find_child("FengVolumeCreateProfile", true, false) as Button
	assert(create_button != null, "an empty Volume did not offer profile creation")
	create_button.pressed.emit()
	await _settle_inspector()
	assert(volume.profile != null, "Create Volume Profile did not assign a profile")
	var volume_profile = volume.profile
	var volume_history := undo.get_history_undo_redo(undo.get_object_history_id(volume))
	assert(volume_history != null, "profile creation did not create an undo history")
	volume_history.undo()
	assert(volume.profile == null, "undo did not clear the created Volume profile")
	volume_history.redo()
	assert(volume.profile == volume_profile, "redo did not restore the created Volume profile")

	# Resolve the renderer from a scene compositor object as the scene-side source
	# used by the inspector.  This does not write anything into the profile.
	var scene_renderer := Renderer.new()
	var compositor := CompositorScript.new()
	compositor.renderer = scene_renderer
	assert(inspector._renderer_from_compositor(compositor) == scene_renderer,
			"scene compositor renderer resolution failed")
	_test_renderer_override_lifetime()

	EditorInterface.inspect_object(null)
	volume.queue_free()
	await get_tree().process_frame
	await _run_editor_preview_regression()

	print("PASS FRP Volume inspector module selection, dynamic schema, source warnings and undo/redo")
	print("PASS FRP editor viewport Volume preview, live parameter changes, disable and leaving restore authored values")
	get_tree().quit()


func _find_taa_source(p_renderer):
	for source in p_renderer.get_volume_modules():
		if source != null and source.get_parameter_key() is int and int(source.get_parameter_key()) == 6:
			return source
	return null


func _menu_index_for_source(p_menu: PopupMenu, p_source) -> int:
	var wanted := String(p_source.resource_name)
	if wanted.is_empty():
		wanted = str(p_source.get_parameter_key())
	for index in p_menu.item_count:
		if p_menu.get_item_text(index) == wanted:
			return index
	return -1


func _has_dynamic_parameter(p_module: Module, p_name: String) -> bool:
	for property in p_module.get_property_list():
		if String(property.get("name", "")) == "parameters/" + p_name:
			return true
	return false


func _property_exists(p_object: Object, p_name: String) -> bool:
	for property in p_object.get_property_list():
		if String(property.get("name", "")) == p_name:
			return true
	return false


func _find_label_containing(p_root: Node, p_text: String):
	if p_root is Label and String(p_root.text).contains(p_text):
		return p_root
	for child in p_root.get_children():
		var found = _find_label_containing(child, p_text)
		if found != null:
			return found
	return null


func _settle_inspector() -> void:
	await get_tree().process_frame
	await get_tree().process_frame


func _test_renderer_override_lifetime() -> void:
	var owner := Profile.new()
	var selected := Renderer.new()
	var profile_key: int = owner.get_instance_id()
	var selected_ref: WeakRef = weakref(selected)
	var owner_ref: WeakRef = weakref(owner)

	inspector._on_renderer_picked(selected, owner, profile_key)
	assert(inspector.resolve_renderer(owner, profile_key) == selected,
			"a picked Renderer must remain available while its profile is alive")
	var entry: Dictionary = inspector._renderer_overrides[profile_key]
	var stored_owner: Variant = entry.get("owner", null)
	assert(stored_owner is WeakRef and stored_owner.get_ref() == owner,
			"the inspector override must reference its owner weakly")
	# The map intentionally owns the selected resource. Release this local copy
	# before checking that the map, and later pruning, control its lifetime.
	entry = {}
	selected = null
	assert(selected_ref.get_ref() != null,
			"the selected Renderer was released before its profile owner")

	owner = null
	inspector._prune_renderer_overrides()
	assert(owner_ref.get_ref() == null, "the inspector owner should be releasable")
	assert(not inspector._renderer_overrides.has(profile_key),
			"deleted profile overrides must be pruned on inspector events")
	assert(selected_ref.get_ref() == null,
			"pruning a deleted profile must release its selected Renderer")


## Exercise the real editor adapter.  EditorInterface's Scene view camera is not
## the edited scene's Camera3D, so this deliberately creates an edited scene with
## only a WorldEnvironment source and lets editor/volume_preview.gd attach its
## transient per-camera FengCompositor.
func _run_editor_preview_regression() -> void:
	var existing_root := EditorInterface.get_edited_scene_root()
	if existing_root != null:
		# The isolated editor test normally has no scene.  Do not silently put the
		# fixture under a pre-existing scene if a runner opened one for diagnostics.
		assert(EditorInterface.close_scene() == OK, "could not close the pre-existing editor scene")
		await get_tree().process_frame

	EditorInterface.set_main_screen_editor("3D")
	var scene_root := Node3D.new()
	scene_root.name = "FengVolumeEditorPreviewScene"
	EditorInterface.add_root_node(scene_root)

	var renderer := Renderer.new()
	var source = _find_taa_source(renderer)
	assert(source != null, "editor preview fixture could not find the TAA Volume source")
	for entry in renderer.passes:
		if entry != null and entry.get_parameter_key() is int and int(entry.get_parameter_key()) == 6:
			entry.enabled = true

	var source_compositor := CompositorScript.new()
	source_compositor.renderer = renderer
	var world := WorldEnvironment.new()
	world.name = "FengVolumeEditorPreviewWorld"
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.compositor = source_compositor
	scene_root.add_child(world)
	world.owner = scene_root
	await get_tree().process_frame
	var viewport := EditorInterface.get_editor_viewport_3d(0)
	assert(viewport != null, "the editor 3D viewport was not available for Volume preview")
	var camera: Camera3D = viewport.get_camera_3d()
	assert(camera != null, "the editor 3D viewport has no preview camera")
	# Capture the camera's real compositor before adding a Volume.  The adapter
	# installs its transient compositor on the next editor frame.
	var original_camera_compositor: Compositor = camera.compositor
	if original_camera_compositor != null:
		camera.compositor = null

	var profile := Profile.new()
	var authored: Dictionary = renderer.get_authored_pass_parameters()
	var module := Module.from_pass(source, authored.get(source.get_parameter_key(), {}))
	module.set("parameters/jitter_phases", 3)
	profile.modules = [module]
	var volume := Volume.new()
	volume.name = "FengVolumeEditorPreviewVolume"
	volume.profile = profile
	volume.unbound = false
	volume.enabled = true
	scene_root.add_child(volume)
	volume.owner = scene_root
	volume.global_position = camera.global_position + Vector3(10000.0, 0.0, 0.0)
	await _settle_editor_preview()
	var camera_transform := camera.global_transform
	for i in 50:
		pipeline_plugin._volume_preview._process(0.0)
	assert(camera.compositor == null and pipeline_plugin._volume_preview._views.is_empty(),
			"an out-of-range Volume must not attach preview compositors or allocate pipeline copies")
	assert(camera.global_transform == camera_transform, "an out-of-range Volume changed the editor camera")
	volume.unbound = true

	await _settle_editor_preview()
	# The adapter should use the world compositor as its source and leave the
	# camera's original compositor recoverable when the preview is removed.
	var preview = FengWorldCompositor.active_compositor(viewport, camera)
	assert(preview is CompositorScript and preview != source_compositor,
			"the editor Volume adapter did not attach an independent FengCompositor")
	var source_key: Variant = source.get_parameter_key()
	_assert_preview_parameter(preview, source_key, 3, "initial editor Volume value")
	assert(source_compositor.get_volume_parameters().is_empty(),
			"editor preview Volume state leaked into the scene WorldEnvironment compositor")

	# Editing a module Resource is the same operation the dynamic Resource
	# inspector performs.  The next editor frame must carry it into the preview
	# compositor without requiring a pipeline rebuild or a restart.
	module.set("parameters/jitter_phases", 7)
	await _settle_editor_preview()
	preview = FengWorldCompositor.active_compositor(viewport, camera)
	_assert_preview_parameter(preview, source_key, 7, "live editor Volume value")

	# The module's author-declared Enabled is an actual effect override. A static
	# silhouette gives visible jitter, so checking dictionaries alone cannot pass.
	var sphere := MeshInstance3D.new()
	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = 0.45
	sphere_mesh.height = 0.9
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color.WHITE
	sphere_mesh.material = material
	sphere.mesh = sphere_mesh
	scene_root.add_child(sphere)
	sphere.global_position = camera.global_transform * Vector3(0.0, 0.0, -3.0)
	module.set("parameters/jitter_phases", 16)
	module.set("parameters/enabled", false)
	var off_a := await _preview_frame(viewport)
	var off_b := await _preview_frame(viewport)
	assert(_changed_pixels(off_a, off_b) == 0, "Volume TAA off still jitters the editor viewport")
	assert(camera.compositor.get_volume_pass_states().get(6) == false,
			"Volume TAA off disappeared instead of overriding the global switch")
	module.set("parameters/enabled", true)
	var on_a := await _preview_frame(viewport)
	var on_b := await _preview_frame(viewport)
	assert(_changed_pixels(off_b, on_a) > 0 and _changed_pixels(on_a, on_b) > 0,
			"Volume TAA re-enable did not restore temporal rendering in the editor")
	# The user's already-saved module has enabled=false, with no values.enabled.
	module.values.erase("enabled")
	module.enabled = false
	var legacy_off_a := await _preview_frame(viewport)
	var legacy_off_b := await _preview_frame(viewport)
	assert(_changed_pixels(legacy_off_a, legacy_off_b) == 0,
			"saved legacy module Enabled=false must disable the TAA effect")
	assert(source.enabled and renderer.get_authored_pass_parameters()[source_key].enabled,
			"Volume effect switching mutated the authored pipeline")
	module.set("parameters/enabled", true)
	module.set("parameters/jitter_phases", 7)
	sphere.queue_free()
	await _settle_editor_preview()
	print("PASS editor Volume TAA off freezes GPU frames, on resumes jitter, legacy off remains an override")

	# Disabled volumes remain in the scene, so the adapter may retain its transient
	# camera compositor, but the effective parameter snapshot must return to the
	# authored value and the source compositor must stay untouched.
	volume.enabled = false
	await _settle_editor_preview()
	preview = FengWorldCompositor.active_compositor(viewport, camera)
	_assert_preview_parameter_empty(preview, source_key, "disabled editor Volume")
	_assert_preview_authored_phase(preview, source_key, 16, "disabled editor Volume")
	assert(source_compositor.get_volume_parameters().is_empty(),
			"disabling the editor Volume did not clear its source compositor")

	# Re-enter with a finite volume, then move the box away from the editor camera.
	# This covers the path that previously never saw an editor camera at all.
	volume.enabled = true
	volume.unbound = false
	volume.size = Vector3.ONE
	volume.global_position = camera.global_position
	await _settle_editor_preview()
	preview = FengWorldCompositor.active_compositor(viewport, camera)
	_assert_preview_parameter(preview, source_key, 7, "finite editor Volume inside")
	volume.global_position = camera.global_position + Vector3(10000.0, 0.0, 0.0)
	await _settle_editor_preview()
	preview = FengWorldCompositor.active_compositor(viewport, camera)
	_assert_preview_parameter_empty(preview, source_key, "finite editor Volume outside")
	_assert_preview_authored_phase(preview, source_key, 16, "finite editor Volume outside")
	assert(source_compositor.get_volume_parameters().is_empty(),
			"leaving the editor Volume changed the authored WorldEnvironment compositor")

	# Observe actual editor viewport pixels, not just the parameter dictionaries.
	var tint := load("res://addons/feng-render-pipeline/library/tint/tint.tres").duplicate(true) as FengShaderPass
	tint.parameters = Vector4.ONE
	var entries: Array[FengPass] = renderer.passes.duplicate()
	for index in entries.size():
		if entries[index] is FengBuiltinPass and entries[index].native_id == 7:
			entries.insert(index, tint)
			break
	renderer.passes = entries
	world.environment.background_color = Color(0.3, 0.3, 0.3)
	var tint_module := Module.from_pass(tint)
	tint_module.set("parameters/parameters", Vector4(0.1, 1.0, 1.0, 1.0))
	profile.modules = [tint_module]
	volume.enabled = false
	await _settle_editor_preview()
	var before := _preview_pixel(viewport)
	volume.enabled = true
	volume.unbound = true
	await _settle_editor_preview()
	var during := _preview_pixel(viewport)
	assert(before.r > 0.1 and during.r < before.r * 0.6,
			"editor Volume tint did not reach GPU pixels: %s -> %s" % [before, during])
	tint_module.set("parameters/parameters", Vector4(1.0, 0.1, 1.0, 1.0))
	await _settle_editor_preview()
	var edited := _preview_pixel(viewport)
	assert(edited.r > during.r * 1.5 and edited.g < before.g * 0.6,
			"editing a Volume parameter did not update editor GPU pixels: %s -> %s" % [during, edited])
	volume.enabled = false
	await _settle_editor_preview()
	var restored := _preview_pixel(viewport)
	assert(absf(before.r - restored.r) < 0.01 and absf(before.g - restored.g) < 0.01,
			"disabling editor Volume did not restore GPU pixels: %s -> %s" % [before, restored])
	print("PASS editor Volume GPU tint updates and restores: %s -> %s -> %s -> %s" % [before, during, edited, restored])

	# Mark the temporary scene clean so close_scene cannot open an interactive
	# save prompt in the headless editor runner.
	EditorInterface.save_scene_as("user://frp_volume_editor_preview.tscn", false)
	await get_tree().process_frame
	volume.queue_free()
	await _settle_editor_preview()
	assert(camera.compositor == null, "removing the last Volume did not restore the editor camera compositor")
	camera.compositor = original_camera_compositor
	world.queue_free()
	await get_tree().process_frame
	assert(EditorInterface.close_scene() == OK, "could not close the editor Volume preview fixture")
	await get_tree().process_frame


func _assert_preview_parameter(p_preview, p_key: Variant, p_expected: int, p_context: String) -> void:
	assert(p_preview is CompositorScript, "%s has no FengCompositor" % p_context)
	var parameters: Dictionary = p_preview.get_volume_parameters()
	assert(parameters.has(p_key), "%s did not carry the Volume key" % p_context)
	var values: Variant = parameters[p_key]
	assert(values is Dictionary and int(values.get("jitter_phases", -1)) == p_expected,
			"%s expected jitter_phases=%d, got %s" % [p_context, p_expected, str(values)])


func _assert_preview_parameter_empty(p_preview, p_key: Variant, p_context: String) -> void:
	assert(p_preview is CompositorScript, "%s lost its preview compositor" % p_context)
	var parameters: Dictionary = p_preview.get_volume_parameters()
	assert(not parameters.has(p_key), "%s still carries a Volume override: %s" % [p_context, str(parameters)])


func _assert_preview_authored_phase(p_preview, p_key: Variant, p_expected: int, p_context: String) -> void:
	assert(p_preview is CompositorScript and p_preview.renderer != null,
			"%s has no authored preview renderer" % p_context)
	var parameters: Dictionary = p_preview.renderer.get_pass_parameters()
	var values: Variant = parameters.get(p_key, {})
	assert(values is Dictionary and int(values.get("jitter_phases", -1)) == p_expected,
			"%s expected authored jitter_phases=%d, got %s" % [p_context, p_expected, str(values)])


func _settle_editor_preview() -> void:
	for i in 8:
		await get_tree().process_frame
		# An idle editor intentionally stops drawing after the preview fast path.
		# Request a test frame explicitly rather than depending on needless churn.
		RenderingServer.force_draw(false)


func _preview_pixel(p_viewport: SubViewport) -> Color:
	var image := p_viewport.get_texture().get_image()
	assert(image != null and not image.is_empty(), "editor viewport produced no GPU image")
	return image.get_pixel(image.get_width() * 3 / 4, image.get_height() / 4)


func _preview_frame(p_viewport: SubViewport) -> Image:
	await _settle_editor_preview()
	return p_viewport.get_texture().get_image()

func _changed_pixels(a: Image, b: Image) -> int:
	var count := 0
	for y in a.get_height():
		for x in a.get_width():
			var pa := a.get_pixel(x, y)
			var pb := b.get_pixel(x, y)
			if maxf(maxf(absf(pa.r - pb.r), absf(pa.g - pb.g)), absf(pa.b - pb.b)) > 0.01:
				count += 1
	return count
