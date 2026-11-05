@tool
class_name FMagicGIProbeExclusion
extends Node3D
## Child of a MagicGI volume. Only the intersecting region is excluded at bake time.
@export var enabled := true:
	set(value):
		enabled = value
		update_gizmos()
@export var size := Vector3.ONE:
	set(value):
		if not value.is_finite(): return
		size = value.abs().max(Vector3.ONE * 0.001)
		update_gizmos()

func _get_configuration_warnings() -> PackedStringArray:
	if get_parent() == null or not get_parent().has_method("uses_free_space_clv_bake"):
		return PackedStringArray(["请将排除区放在 MagicGI Volume 下；与父 Volume 相交的区域不生成 Probe。"])
	return PackedStringArray()

## World-to-unit-box snapshots contain no Nodes and are safe for bake workers.
static func capture(volume: Node3D) -> Array[Transform3D]:
	var result: Array[Transform3D] = []
	for child in volume.get_children():
		if not child is FMagicGIProbeExclusion or not child.enabled: continue
		var box: Transform3D = child.global_transform.scaled_local(child.size)
		if box.is_finite() and absf(box.basis.determinant()) > 1e-12:
			result.append(box.affine_inverse())
	return result

static func contains(point: Vector3, boxes: Array[Transform3D]) -> bool:
	for inverse in boxes:
		var local := (inverse * point).abs()
		if local.x <= 0.500001 and local.y <= 0.500001 and local.z <= 0.500001:
			return true
	return false
