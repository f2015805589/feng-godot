@tool
extends Control
## GPU-projected editor points. Canvas colors bypass scene exposure and GI.
const Volume = preload("../feng_olv_volume.gd")
const POINT_SHADER = preload("olv_probe_overlay.gdshader")
var node: FOLVVolume
var camera: Camera3D
var points: MultiMesh
var _camera_transform := Transform3D()
var _camera_projection := Projection()
var _display_size := Vector2.ZERO
var _box_key := ""
var _points_key := ""
var _box := Control.new()

static func make_points(view: Dictionary, selection: PackedInt32Array) -> MultiMesh:
	var positions: PackedVector3Array = view.get("positions",PackedVector3Array())
	var indices: PackedInt32Array = view.get("indices",PackedInt32Array())
	var labels: PackedByteArray = view.get("labels",PackedByteArray())
	if indices.is_empty(): return null
	var selected := {}
	for index in selection: selected[index] = true
	var order := PackedInt32Array()
	# Selected rings are drawn last, so other points cannot hide them.
	for i in indices.size():
		if not selected.has(indices[i]): order.append(i)
	for i in indices.size():
		if selected.has(indices[i]): order.append(i)
	var buffer := PackedFloat32Array()
	buffer.resize(indices.size()*16)
	var palette := [Volume.probe_display_color(0),Volume.probe_display_color(1),Volume.probe_display_color(2)]
	for slot in order.size():
		var i := order[slot]
		var offset := slot*16
		var color: Color = palette[labels[i]]
		buffer[offset] = 1.0
		buffer[offset+5] = 1.0
		buffer[offset+8] = color.r
		buffer[offset+9] = color.g
		buffer[offset+10] = color.b
		buffer[offset+11] = 1.0
		buffer[offset+12] = positions[i].x
		buffer[offset+13] = positions[i].y
		buffer[offset+14] = positions[i].z
		buffer[offset+15] = 1.0 if selected.has(indices[i]) else 0.0
	var mesh := QuadMesh.new()
	mesh.size = Vector2(2,2)
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_2D
	multimesh.use_colors = true
	multimesh.use_custom_data = true
	multimesh.mesh = mesh
	multimesh.instance_count = indices.size()
	multimesh.buffer = buffer
	# Positions are projected in the shader, outside the ordinary mesh AABB.
	multimesh.custom_aabb = AABB(Vector3(-100000,-100000,-1),Vector3(200000,200000,2))
	return multimesh

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	material = ShaderMaterial.new()
	material.shader = POINT_SHADER

func _ready() -> void:
	_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_box)
	_box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_box.draw.connect(_draw_batch_box)

func _process(_delta: float) -> void:
	if not is_instance_valid(node) or not is_instance_valid(camera):
		hide()
		return
	visible = node.show_probes and EditorInterface.get_selection().get_selected_nodes().has(node)
	if not visible: return
	var view := node.get_visible_probe_view(camera)
	var points_key := str([view.get("key",""),hash(node.selected_probes)])
	if points_key != _points_key:
		_points_key = points_key
		points = make_points(view,node.selected_probes)
		queue_redraw()
	var transform := camera.get_camera_transform()
	var projection := camera.get_camera_projection()
	var box_key := str([node.show_batch_box,node.batch_center,node.batch_size,node.global_transform])
	if transform != _camera_transform or projection != _camera_projection or size != _display_size or box_key != _box_key:
		_camera_transform = transform
		_camera_projection = projection
		_display_size = size
		_box_key = box_key
		material.set_shader_parameter("world_to_clip",projection*Projection(transform.affine_inverse()))
		material.set_shader_parameter("viewport_size",size)
		queue_redraw()
		_box.queue_redraw()

func _draw() -> void:
	if points != null and points.instance_count > 0: draw_multimesh(points,null)

func _draw_batch_box() -> void:
	if not is_instance_valid(node) or not is_instance_valid(camera) or not node.show_batch_box: return
	var corners := PackedVector3Array()
	for z in [-1,1]:
		for y in [-1,1]:
			for x in [-1,1]: corners.append(node.global_transform*(node.batch_center+node.batch_size*Vector3(x,y,z)*0.5))
	for edge in [Vector2i(0,1),Vector2i(0,2),Vector2i(0,4),Vector2i(1,3),Vector2i(1,5),Vector2i(2,3),Vector2i(2,6),Vector2i(3,7),Vector2i(4,5),Vector2i(4,6),Vector2i(5,7),Vector2i(6,7)]:
		if camera.is_position_behind(corners[edge.x]) or camera.is_position_behind(corners[edge.y]): continue
		_box.draw_line(camera.unproject_position(corners[edge.x]),camera.unproject_position(corners[edge.y]),Color.WHITE,1.0,true)
