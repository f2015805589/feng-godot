@tool
extends Node
## The editor's cursor decal.
##
## Owns every shader parameter that draws the brush cursor: the cursor quad itself,
## its brush/reticle texture, the two gradient markers, the fade-out after the mouse
## stops, and the region directory preview the region tool overlays on the terrain
## material. Nothing here decides *which* tool is active - the host `Terrain3DUI`
## keeps owning tool, brush and pointer state, and this node turns that state into
## one `update_decal()` pass.
##
## `ui.gd` creates this as a child and forwards `update_decal()` / `hide_decal()` /
## `set_decal_rotation()`, because the editor plugin and `Terrain3DEditor` reach the
## decal through the UI node.

# Cursor colours per tool and operation. See docs/ for the role colours.
const COLOR_RAISE := Color(1., 1., 1.) # White
const COLOR_LOWER := Color(0.2, 0.2, 0.2) # Dark gray
const COLOR_SMOOTH := Color(0.5, 0.0, 0.2) # Dark Red
const COLOR_AVERAGE := Color(0.6, 0.1, 0.3) # Neutral purple
const COLOR_LIFT := Color(1.0, 0.6, 0.0) # Bright orange
const COLOR_FLATTEN := Color(0.0, 0.6, 1.0) # Cyan
const COLOR_HEIGHT := Color(0.0, 0.8, 0.8) # Brighter cyan
const COLOR_SLOPE := Color(1.0, 1.0, 0.0) # Bright yellow
const COLOR_PAINT := Color(0.0, 0.5, 0.0) # Dark green
const COLOR_SPRAY := Color(0.4, 0.8, 0.4) # Lighter green
const COLOR_UNSPRAY := Color(0.5, 0.2, 0.5) # Neutral purple
const COLOR_WET := Color(0.4, 0.6, 1.0) # Light blue
const COLOR_DRY := Color(0.6, 0.4, 0.0) # Warm brown
const COLOR_AUTOSHADER := Color(0.36, 0.2, 0.09) # Chocolate
const COLOR_HOLES := Color(0.1, 0.1, 0.1) # Near-black
const COLOR_NAVIGATION := Color(0.5, 0.2, 0.5) # Purple
const COLOR_INSTANCE := Color(0.863, 0.08, 0.235) # Crimson
const COLOR_UNINSTANCE := Color(0.2, 0.9, 0.6) # Cyan-green
const COLOR_PICK := Color.WHITE

var plugin: EditorPlugin # Actually Terrain3DEditorPlugin, but Godot still has CRC errors
# The UI node that owns tool, brush and pointer state. Untyped on purpose: the
# decal reads the host's script fields, which a `Node` annotation cannot express.
var host: Node

# 3 Editor decals: 0 = cursor, 1 = slope point1, 2 = slope point2
var mat_rid: RID
var editor_brush_texture_rid: RID = RID()
var editor_decal_position: Array[Vector2] = [Vector2(), Vector2(), Vector2()]
var editor_decal_rotation: Array[float] = [0., 0., 0.]
var editor_decal_size: Array[float] = [0., 0., 0.]
var editor_decal_color: Array[Color] = [Color(), Color(), Color()]
var editor_decal_visible: Array[bool] = [false, false, false]
var editor_decal_part: Array[bool] = [true, true] # Decal[0] cursor components: brush, reticle
var editor_decal_timer: Timer
# The region tool draws a flat quad, so it samples a 1x1 white brush texture.
var region_texture: ImageTexture
# The shader samples the chunk -> layer directory as a texture, not a uniform int
# array. The region tool preview writes a negative "dummy" slot for the hovered
# chunk, which needs its own texture: the directory Terrain3DData owns must stay
# pristine. Reused so a mouse move costs one 64 KB texel update, not an allocation.
var region_preview_texture: ImageTexture
var editor_decal_fade: float :
	set(value):
		editor_decal_fade = value
		if editor_decal_color.size() > 0:
			editor_decal_color[0].a = value
			if is_shader_valid():
				RenderingServer.material_set_param(mat_rid, "_editor_decal_color", editor_decal_color)
				if value < 0.001:
					restore_region_directory()


func setup(p_plugin: EditorPlugin, p_host: Node) -> void:
	plugin = p_plugin
	host = p_host
	var image: Image = Image.create_empty(1, 1, false, Image.FORMAT_R8)
	image.fill(Color.WHITE)
	region_texture = ImageTexture.create_from_image(image)
	editor_decal_timer = Timer.new()
	editor_decal_timer.wait_time = .5
	editor_decal_timer.one_shot = true
	editor_decal_timer.timeout.connect(func():
		get_tree().create_tween().tween_property(self, "editor_decal_fade", 0.0, 0.15))
	add_child(editor_decal_timer)


# Points the material back at the live directory. Used whenever the preview stops.
func restore_region_directory() -> void:
	if is_shader_valid():
		RenderingServer.material_set_param(mat_rid, "_region_map", plugin.terrain.data.get_region_directory_rid())


# Binds a region map to the material. `p_preview` builds a separate texture for the
# editor's dummy-slot preview; otherwise the live directory is bound directly.
func set_region_directory(r_map: PackedInt32Array, p_preview: bool) -> void:
	if not is_shader_valid():
		return
	if not p_preview:
		restore_region_directory()
		return
	var image: Image = plugin.terrain.data.region_map_to_image(r_map)
	if image == null:
		return
	if region_preview_texture == null:
		region_preview_texture = ImageTexture.create_from_image(image)
	else:
		region_preview_texture.update(image)
	RenderingServer.material_set_param(mat_rid, "_region_map", region_preview_texture.get_rid())


func update_decal() -> void:
	if not plugin.terrain or not plugin.viewport or host.brush_data.size() <= 3:
		return
	
	# If not a state that should show the decal, hide everything and return
	mat_rid = plugin.terrain.material.get_material_rid() # Used in hide_decal() and below
	if plugin.editor and plugin.editor.get_tool() == Terrain3DEditor.TOOL_MAX:
		hide_decal()
		return
	if not host.visible or \
		plugin._input_mode == -1 or \
		# After moving camera, wait for mouse cursor to update before revealing
		# See https://github.com/godotengine/godot/issues/70098
		Time.get_ticks_msec() - plugin.rmb_release_time <= 100:
			hide_decal()
			return
	
	# Only show decal if in viewport or toolbars
	var viewport_rect := Rect2(Vector2.ZERO, Vector2(plugin.viewport.size))
	if not (viewport_rect.has_point(plugin.mouse_viewport_position) && plugin.mouse_in_main):
		return
	
	reset_decal_arrays()
	editor_decal_position[0] = Vector2(plugin.mouse_global_position.x, plugin.mouse_global_position.z)
	editor_decal_visible = [true, false, false] # Show cursor by default
	editor_decal_part = [true, true] # Show brush and reticle by default
	editor_decal_timer.start()
	
	## Region Operations
	# Only the region tool needs the map, and get_region_map() copies the whole
	# REGION_MAP_SIZE squared array (64 KB at 128x128), so keep it out of the
	# mouse-motion path for every other tool.
	var preview_r_map := PackedInt32Array()
	var preview_dummy := false
	if plugin.editor.get_tool() == Terrain3DEditor.REGION:
		var r_map: PackedInt32Array = plugin.terrain.data.get_region_map()
		preview_r_map = r_map
		var r_size: float = float(plugin.terrain.get_region_size()) * plugin.terrain.get_vertex_spacing()
		var map_size: int = plugin.terrain.data.REGION_MAP_SIZE
		var half_r_size: float = r_size * 0.5
		var pos: Vector2 = (Vector2(plugin.mouse_global_position.x, plugin.mouse_global_position.z) +
			Vector2(half_r_size, half_r_size)).snappedf(r_size) - Vector2(half_r_size, half_r_size)
		editor_brush_texture_rid = region_texture.get_rid()
		editor_decal_position[0] = pos
		editor_decal_size[0] = r_size
		editor_decal_rotation[0] = 0.0
		editor_decal_part[1] = false # Disable reticle
		
		var loc: Vector2i = plugin.terrain.data.get_region_location(plugin.mouse_global_position)
		loc += Vector2i(map_size / 2, map_size / 2)
		if !(loc.x < 0 or loc.x > map_size - 1 or loc.y < 0 or loc.y > map_size - 1):
			var index: int = clampi(loc.y * map_size + loc.x, 0, map_size * map_size - 1)
			if plugin.terrain.material.get_world_background() == Terrain3DMaterial.WorldBackground.NONE:
				if r_map[index] == 0 and host.active_operation == Terrain3DEditor.ADD:
					r_map[index] = -index - 1
					preview_dummy = true

			match host.active_operation:
				Terrain3DEditor.ADD:
					if r_map[index] <= 0:
						editor_decal_color[0] = Color.WHITE
						editor_decal_color[0].a = 0.25
					else:
						hide_decal()
				
				Terrain3DEditor.SUBTRACT:
					if r_map[index] > 0:
						editor_decal_color[0] = Color.WHITE * .15
						editor_decal_color[0].a = 0.75
					else:
						hide_decal()
		else:
			hide_decal()

	## Picking
	elif host.picking != Terrain3DEditor.TOOL_MAX:
		editor_decal_part[0] = false # Hide brush
		editor_decal_size[0] = plugin.terrain.get_vertex_spacing()
		editor_decal_color[0] = COLOR_PICK
		editor_decal_color[0].a = 1.0

	## Brushing Operations
	else:
		editor_brush_texture_rid = host.brush_data["brush"][1].get_rid()
		editor_decal_size[0] = maxf(host.brush_data["size"], .5)
		if host.brush_data["align_to_view"]:
			var cam: Camera3D = plugin.terrain.get_camera();
			if (cam):
				editor_decal_rotation[0] = cam.rotation.y
			else:
				editor_decal_rotation[0] = 0.
		match plugin.editor.get_tool():
			Terrain3DEditor.SCULPT:
				match host.active_operation:
					Terrain3DEditor.ADD:
						if plugin.modifier_alt:
							editor_decal_color[0] = COLOR_LIFT
							editor_decal_color[0].a = clamp(host.brush_data["strength"], .2, .5)
						else:
							editor_decal_color[0] = COLOR_RAISE
							editor_decal_color[0].a = clamp(host.brush_data["strength"], .25, .5)
					Terrain3DEditor.SUBTRACT:
						if plugin.modifier_alt:
							editor_decal_color[0] = COLOR_FLATTEN
							editor_decal_color[0].a = clamp(host.brush_data["strength"], .25, .5) + .1
						else:
							editor_decal_color[0] = COLOR_LOWER
							editor_decal_color[0].a = clamp(host.brush_data["strength"], .2, .5) + .25
					Terrain3DEditor.AVERAGE:
						editor_decal_color[0] = COLOR_SMOOTH
						editor_decal_color[0].a = clamp(host.brush_data["strength"], .2, .5) + .25
					Terrain3DEditor.GRADIENT:
						editor_decal_color[0] = COLOR_SLOPE
						editor_decal_color[0].a = clamp(host.brush_data["strength"], .2, .4)
			Terrain3DEditor.HEIGHT:
				editor_decal_color[0] = COLOR_HEIGHT
				editor_decal_color[0].a = clamp(host.brush_data["strength"], .2, .5) + .25
			Terrain3DEditor.TEXTURE:
				if plugin._input_mode == 1:
					editor_decal_part[0] = false # Hide brush
				if plugin.modifier_shift:
					editor_decal_color[0] = COLOR_AVERAGE
					editor_decal_color[0].a = clamp(host.brush_data["strength"], .2, .5) + .25
				else:
					match host.active_operation:
						Terrain3DEditor.REPLACE:
							editor_decal_color[0] = COLOR_PAINT
							editor_decal_color[0].a = .6
						Terrain3DEditor.SUBTRACT:
							editor_decal_color[0] = COLOR_UNSPRAY
							editor_decal_color[0].a = clamp(host.brush_data["strength"], .2, .5) + .1
						Terrain3DEditor.ADD:
							editor_decal_color[0] = COLOR_SPRAY
							editor_decal_color[0].a = clamp(host.brush_data["strength"], .15, .4)
			Terrain3DEditor.COLOR:
				if plugin.modifier_shift:
					editor_decal_color[0] = COLOR_AVERAGE
					editor_decal_color[0].a = clamp(host.brush_data["strength"], .2, .5) + .25
				elif plugin.modifier_ctrl:
					editor_decal_color[0] = Color.WHITE
					editor_decal_color[0].a = clamp(host.brush_data["strength"], .2, .5)
				else:
					editor_decal_color[0] = host.brush_data["color"].srgb_to_linear()
					editor_decal_color[0].a *= clamp(host.brush_data["strength"], .3, .5)
			Terrain3DEditor.ROUGHNESS:
				if plugin._input_mode == 1:
					editor_decal_part[0] = false # Hide brush
				if plugin.modifier_shift:
					editor_decal_color[0] = COLOR_AVERAGE
					editor_decal_color[0].a = clamp(host.brush_data["strength"], .2, .5) + .25
				elif plugin.modifier_ctrl:
					editor_decal_color[0] = COLOR_DRY
					editor_decal_color[0].a = clamp(host.brush_data["strength"], .2, .5) + .1
				else:
					editor_decal_color[0] = COLOR_WET
					editor_decal_color[0].a = clamp(host.brush_data["strength"], .2, .5) + .1
			Terrain3DEditor.AUTOSHADER:
				editor_decal_color[0] = COLOR_AUTOSHADER
				editor_decal_color[0].a = .6
			Terrain3DEditor.HOLES:
				editor_decal_color[0] = COLOR_HOLES
				editor_decal_color[0].a = .75
			Terrain3DEditor.NAVIGATION:
				editor_decal_color[0] = COLOR_NAVIGATION
				editor_decal_color[0].a = .80
			Terrain3DEditor.INSTANCER:
				editor_decal_part[0] = false # Hide brush
				if plugin.modifier_ctrl:
					editor_decal_color[0] = COLOR_UNINSTANCE
					editor_decal_color[0].a = .75
				else:
					editor_decal_color[0] = COLOR_INSTANCE
					editor_decal_color[0].a = .75
	
	if plugin.editor.get_tool() != Terrain3DEditor.REGION and not host.brush_data["show_brush_texture"]:
		editor_decal_part[0] = false # Hide brush
	
	if host.active_operation == Terrain3DEditor.GRADIENT:
		var point1: Vector3 = host.brush_data["gradient_points"][0]
		if point1 != Vector3.ZERO:
			editor_decal_color[1] = COLOR_SLOPE
			editor_decal_size[1] = 0.25
			editor_decal_visible[1] = true
			editor_decal_position[1] = Vector2(point1.x, point1.z)
		var point2: Vector3 = host.brush_data["gradient_points"][1]
		if point2 != Vector3.ZERO:
			editor_decal_color[2] = COLOR_SLOPE
			editor_decal_size[2] = 0.25
			editor_decal_visible[2] = true
			editor_decal_position[2] = Vector2(point2.x, point2.z)
	
	if RenderingServer.get_current_rendering_method().contains("gl_compatibility"):
		for i in editor_decal_color.size():
			editor_decal_color[i].a = maxf(0.1, editor_decal_color[i].a - .25)
	
	editor_decal_fade = editor_decal_color[0].a
	# Update Shader params
	if is_shader_valid():
		RenderingServer.material_set_param(mat_rid, "_editor_brush_texture", editor_brush_texture_rid)
		RenderingServer.material_set_param(mat_rid, "_editor_decal_position", editor_decal_position)
		RenderingServer.material_set_param(mat_rid, "_editor_decal_rotation", editor_decal_rotation)
		RenderingServer.material_set_param(mat_rid, "_editor_decal_size", editor_decal_size)
		RenderingServer.material_set_param(mat_rid, "_editor_decal_color", editor_decal_color)
		RenderingServer.material_set_param(mat_rid, "_editor_decal_visible", editor_decal_visible)
		RenderingServer.material_set_param(mat_rid, "_editor_decal_part", editor_decal_part)
		set_region_directory(preview_r_map, preview_dummy)


func is_shader_valid() -> bool:
	# As long as the compiled shader contains at least 1 uniform, we can use it to check
	# if the shader compilation has failed, as this will then return an empty dictionary.
	if not plugin.terrain:
		return false
	var params = RenderingServer.get_shader_parameter_list(plugin.terrain.material.get_shader_rid())
	if params.is_empty():
		return false
	else:
		return true


func hide_decal() -> void:
	editor_decal_visible = [false, false, false]
	if not mat_rid.is_valid():
		return
	if is_shader_valid():
		RenderingServer.material_set_param(mat_rid, "_editor_decal_visible", editor_decal_visible)
		restore_region_directory()


# These array sizes are reset to 0 when closing scenes for some unknown reason, so check and reset
func reset_decal_arrays() -> void:
	if editor_decal_color.size() < 3:
		editor_brush_texture_rid = RID()
		editor_decal_position = [Vector2(), Vector2(), Vector2()]
		editor_decal_rotation = [0., 0., 0.]
		editor_decal_size = [0., 0., 0.]
		editor_decal_color = [Color(), Color(), Color()]
		editor_decal_visible = [false, false, false]
		editor_decal_part = [true, true]


func set_decal_rotation(p_rot: float) -> void:
	editor_decal_rotation[0] = p_rot
	if is_shader_valid():
		RenderingServer.material_set_param(mat_rid, "_editor_decal_rotation", editor_decal_rotation)
