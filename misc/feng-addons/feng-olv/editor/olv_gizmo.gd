@tool
extends EditorNode3DGizmoPlugin
const Volume = preload("../feng_olv_volume.gd")
func _init() -> void:
	for item in [["indoor",Color(0.15,0.8,1)],["outdoor",Color(1,0.75,0.15)],["selected",Color.WHITE]]:
		create_handle_material(item[0])
		var material := get_material(item[0]) as StandardMaterial3D
		material.albedo_color = item[1]
		material.no_depth_test = true
	create_material("box",Color(1,1,1,0.75),false,true)
func _has_gizmo(node: Node3D) -> bool: return node is Volume
func _get_gizmo_name() -> String: return "OLV 标签编辑"
func _redraw(gizmo: EditorNode3DGizmo) -> void:
	gizmo.clear()
	var node := gizmo.get_node_3d() as FOLVVolume
	if node == null or not node.show_probes: return
	var source := node.get_probe_source()
	if source == null: return
	var inverse := node.global_transform.affine_inverse()
	var points := [PackedVector3Array(),PackedVector3Array(),PackedVector3Array()]
	var ids := [PackedInt32Array(),PackedInt32Array(),PackedInt32Array()]
	var selected := {}
	for index in node.selected_probes: selected[index] = true
	for index in source.probe_count:
		if not source.cell_is_valid(index): continue
		var bucket := 2 if selected.has(index) else 0 if node.probe_label(index) == 2 else 1
		points[bucket].append(inverse * source.cell_position(index))
		ids[bucket].append(index)
	for group in 3:
		if not points[group].is_empty():
			gizmo.add_handles(points[group],get_material(["indoor","outdoor","selected"][group],gizmo),ids[group])
	if node.edit_probes:
		var corners := PackedVector3Array()
		for z in [-1,1]:
			for y in [-1,1]:
				for x in [-1,1]: corners.append(node.batch_center+node.batch_size*Vector3(x,y,z)*0.5)
		var lines := PackedVector3Array()
		for edge in [Vector2i(0,1),Vector2i(0,2),Vector2i(0,4),Vector2i(1,3),Vector2i(1,5),Vector2i(2,3),Vector2i(2,6),Vector2i(3,7),Vector2i(4,5),Vector2i(4,6),Vector2i(5,7),Vector2i(6,7)]:
			lines.append(corners[edge.x]);lines.append(corners[edge.y])
		gizmo.add_lines(lines,get_material("box",gizmo))
func _get_handle_name(gizmo: EditorNode3DGizmo, handle_id: int, _secondary: bool) -> String:
	var node := gizmo.get_node_3d() as FOLVVolume
	return "Probe %d · %s" % [handle_id,"室内" if node.probe_label(handle_id) == 2 else "室外"]
