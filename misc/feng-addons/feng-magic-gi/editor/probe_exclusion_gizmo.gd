@tool
extends EditorNode3DGizmoPlugin
const Exclusion = preload("../feng_magic_gi_probe_exclusion.gd")
func _init() -> void:
	create_material("enabled", Color(1.0,0.3,0.2))
	create_material("disabled", Color(0.5,0.5,0.5))
func _has_gizmo(node: Node3D) -> bool: return node is Exclusion
func _get_gizmo_name() -> String: return "MagicGI Probe 排除区"
func _redraw(gizmo: EditorNode3DGizmo) -> void:
	gizmo.clear()
	var node := gizmo.get_node_3d() as FMagicGIProbeExclusion
	var bounds := AABB(-node.size*0.5,node.size)
	var lines := PackedVector3Array()
	for edge in [Vector2i(0,1),Vector2i(0,2),Vector2i(0,4),Vector2i(1,3),Vector2i(1,5),Vector2i(2,3),Vector2i(2,6),Vector2i(3,7),Vector2i(4,5),Vector2i(4,6),Vector2i(5,7),Vector2i(6,7)]:
		lines.append(bounds.get_endpoint(edge.x))
		lines.append(bounds.get_endpoint(edge.y))
	gizmo.add_lines(lines,get_material("enabled" if node.enabled else "disabled",gizmo))
	gizmo.add_collision_segments(lines)
