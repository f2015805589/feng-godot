@tool
extends "res://addons/feng-idweight-terrain/src/editor_plugin.gd"

var probe_root: Node3D
var probe_viewport: SubViewport
var probe_camera: Camera3D
var probe_terrain: Terrain3D
var _finished: bool = false

func _enter_tree() -> void:
	super._enter_tree()
	call_deferred("_watchdog")
	call_deferred("_run_probe")

# A script error inside the probe aborts the coroutine without reaching either
# quit(), which used to burn the runner's full 180s timeout with no diagnosis.
func _watchdog() -> void:
	await get_tree().create_timer(120.0).timeout
	if not _finished:
		_fail("watchdog: probe did not finish within 120s")

func _wait_frames(count: int) -> void:
	for _i in count:
		await get_tree().process_frame

func _texture(color: Color) -> ImageTexture:
	var image := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	image.fill(color)
	return ImageTexture.create_from_image(image)

func _fail(message: String) -> void:
	if _finished:
		return
	_finished = true
	push_error("EDITOR_INPUT_REGRESSION: " + message)
	get_tree().quit(1)

func _run_probe() -> void:
	await _wait_frames(4)

	# Keep the test world separate from the editor's scene and viewport. The
	# production callback only requires a Camera3D parented by a SubViewport.
	var container := SubViewportContainer.new()
	# The orthographic camera is aligned to the actual viewport mouse ray below.
	container.size = Vector2(1024, 1024)
	probe_viewport = SubViewport.new()
	probe_viewport.size = Vector2i(1024, 1024)
	probe_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	container.add_child(probe_viewport)
	get_tree().root.add_child(container)

	probe_root = Node3D.new()
	probe_viewport.add_child(probe_root)
	probe_terrain = Terrain3D.new()
	probe_terrain.region_size = 64
	probe_terrain.free_editor_textures = false
	probe_terrain.assets = Terrain3DAssets.new()
	for id in 2:
		var asset := Terrain3DTextureAsset.new()
		asset.id = id
		asset.albedo_texture = _texture(Color.RED if id == 0 else Color.GREEN)
		asset.normal_texture = _texture(Color(0.5, 0.5, 1.0))
		probe_terrain.assets.set_texture_asset(id, asset)
	probe_root.add_child(probe_terrain)
	probe_terrain.data.add_region_blank(Vector2i.ZERO)

	probe_camera = Camera3D.new()
	probe_camera.position = Vector3(32, 40, 32)
	probe_camera.rotation_degrees = Vector3(-55, 0, 0)
	probe_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	probe_camera.size = 60
	probe_camera.current = true
	probe_viewport.add_child(probe_camera)
	probe_terrain.set_camera(probe_camera)

	await _wait_frames(8)
	_edit(probe_terrain)
	debug = 0
	await _wait_frames(4)

	# None is the first toolbar entry and the safe default. It must suppress
	# brush settings and leave the native editor outside every editing tool.
	var none_button: Button = ui.toolbar.get_button("None")
	if none_button == null or not none_button.button_pressed or \
		ui._selected_tool != Terrain3DEditor.TOOL_MAX or \
		ui._selected_operation != Terrain3DEditor.OP_MAX or \
		editor.get_tool() != Terrain3DEditor.TOOL_MAX or \
		editor.get_operation() != Terrain3DEditor.OP_MAX or \
		ui.tool_settings.select_brush_button.visible:
		_fail("None toolbar entry was not the safe default: button=%s tool=%s op=%s brush_visible=%s" %
			[none_button and none_button.button_pressed, editor.get_tool(), editor.get_operation(),
			ui.tool_settings.select_brush_button.visible])
		return
	# Re-entering the node editor must preserve None rather than restoring a
	# brush or region operation.
	_edit(null)
	await _wait_frames(2)
	_edit(probe_terrain)
	await _wait_frames(4)
	if not _require_none_state("selection re-entry"):
		return
	var none_before: Color = probe_terrain.data.get_surface_maps()[0].get_pixel(32, 32)
	var none_press := InputEventMouseButton.new()
	none_press.button_index = MOUSE_BUTTON_LEFT
	none_press.pressed = true
	none_press.position = probe_viewport.get_mouse_position()
	var none_result := _forward_3d_gui_input(probe_camera, none_press)
	var none_after: Color = probe_terrain.data.get_surface_maps()[0].get_pixel(32, 32)
	if none_result != AFTER_GUI_INPUT_PASS or editor.is_operating() or none_after != none_before:
		_fail("None accepted a terrain edit input: result=%s operating=%s before=%s after=%s" %
			[none_result, editor.is_operating(), none_before, none_after])
		return

	# The button-to-pair-field mapping is asserted by
	# editor_pairroles.gd (Terrain3DAssetDock.role_writes_overlay_field) and the
	# packed encoding of the pair fields by the press below, so this probe does not
	# also drive the dock: the dock rebuilds its entry list asynchronously and a
	# captured entry can be freed before the handler is called.

	# Aim the actual viewport mouse ray at the center of the test region while
	# retaining an oblique direction, so this exercise does not use the
	# get_height shortcut for a straight-down camera.
	var aim_mouse := probe_viewport.get_mouse_position()
	var aim_direction := probe_camera.project_ray_normal(aim_mouse)
	var aim_origin := probe_camera.project_ray_origin(aim_mouse)
	var desired_origin := Vector3(32, 0, 32) - aim_direction * 50.0
	probe_camera.global_position += desired_origin - aim_origin

	ui.toolbar.change_tool("PaintTexture")
	await _wait_frames(2)
	var brush_data: Dictionary = ui.brush_data.duplicate()
	brush_data["asset_id"] = 1
	brush_data["pair_overlay_id"] = 1
	brush_data["pair_background_id"] = 0
	brush_data["pair_weight_level"] = 8
	var brush := Image.create(16, 16, false, Image.FORMAT_RF)
	brush.fill(Color.WHITE)
	brush_data["brush"] = [brush, ImageTexture.create_from_image(brush)]
	brush_data["size"] = 20.0
	brush_data["strength"] = 100.0
	brush_data["mouse_pressure"] = 1.0
	editor.set_brush_data(brush_data)
	# Inspect the texel under the callback's resolved mouse_global_position
	# rather than assuming the viewport center.
	var before := probe_terrain.data.get_surface_maps()[0].get_pixel(32, 32)

	# The first GPU picking read can be the clear value. A real left press must
	# still start and paint the operation through the CPU fallback.
	var initial_hit := probe_terrain.get_intersection(probe_camera.project_ray_origin(probe_viewport.get_mouse_position()), probe_camera.project_ray_normal(probe_viewport.get_mouse_position()), true)
	if initial_hit.z < 3.4e38:
		_fail("fixture must exercise an empty first GPU pick")
		return
	print("INITIAL_GPU_HIT=", initial_hit)
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = probe_viewport.get_mouse_position()
	var press_result := _forward_3d_gui_input(probe_camera, press)
	var paint_x := clampi(floori(mouse_global_position.x), 0, 63)
	var paint_z := clampi(floori(mouse_global_position.z), 0, 63)
	var after_press := probe_terrain.data.get_surface_maps()[0].get_pixel(paint_x, paint_z)
	var packed := roundi(after_press.r * 65535.0)
	if press_result != AFTER_GUI_INPUT_STOP or not editor.is_operating() or \
		((packed >> 11) & 31) != 1 or ((packed >> 6) & 31) != 0:
		_fail("first press did not paint overlay ID 1: result=%s operating=%s pos=%s packed=0x%04x before=%s after=%s" % [press_result, editor.is_operating(), mouse_global_position, packed, before, after_press])
		return
	await _wait_frames(2)
	var gpu_surface: Image = RenderingServer.texture_2d_layer_get(probe_terrain.data.get_surface_maps_rid(), 0)
	var gpu_packed := roundi(gpu_surface.get_pixel(paint_x, paint_z).r * 65535.0)
	if ((gpu_packed >> 11) & 31) != 1 or ((gpu_packed >> 6) & 31) != 0:
		_fail("first press R16 map was not uploaded to GPU: cpu=0x%04x gpu=0x%04x pos=(%s,%s)" % [packed, gpu_packed, paint_x, paint_z])
		return

	# Release outside the terrain. It must close the operation without needing a
	# valid hit, so an undo snapshot cannot leak into the next stroke.
	probe_camera.position = Vector3(1000, 40, 1000)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = Vector2(50, 50)
	var release_result := _forward_3d_gui_input(probe_camera, release)
	if release_result != AFTER_GUI_INPUT_STOP or editor.is_operating():
		_fail("release did not close operation outside terrain: result=%s operating=%s" % [release_result, editor.is_operating()])
		return

	# A right press remains available to the editor's camera navigation and does
	# not start a paint operation.
	var right_press := InputEventMouseButton.new()
	right_press.button_index = MOUSE_BUTTON_RIGHT
	right_press.pressed = true
	right_press.position = probe_viewport.get_mouse_position()
	var right_result := _forward_3d_gui_input(probe_camera, right_press)
	if right_result == AFTER_GUI_INPUT_STOP or editor.is_operating():
		_fail("right press was consumed as a paint stroke: result=%s operating=%s" % [right_result, editor.is_operating()])
		return

	_finished = true
	print("PASS editor brush first GPU miss -> CPU fallback -> R16 CPU/GPU ID 1 -> outside release -> right navigation")
	get_tree().quit(0)


func _require_none_state(p_context: String) -> bool:
	if ui._selected_tool == Terrain3DEditor.TOOL_MAX and \
		ui._selected_operation == Terrain3DEditor.OP_MAX and \
		editor.get_tool() == Terrain3DEditor.TOOL_MAX and \
		editor.get_operation() == Terrain3DEditor.OP_MAX:
		return true
	_fail("None state was lost during %s: selected=%s/%s active=%s/%s" %
		[ p_context, ui._selected_tool, ui._selected_operation,
		editor.get_tool(), editor.get_operation() ])
	return false
