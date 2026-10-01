extends RefCounted
## Pure math and error propagation shared by the packer and headless tests.


static func alignment_basis(normal: Vector3) -> Basis:
	if not normal.is_finite():
		return Basis.IDENTITY
	var magnitude := normal.abs()[normal.abs().max_axis_index()]
	if magnitude == 0.0:
		return Basis.IDENTITY
	var direction := (normal / magnitude).normalized()
	var sine := sqrt(float(direction.x) * direction.x + float(direction.y) * direction.y)
	if sine <= 0.000000000001:
		return Basis.IDENTITY if direction.z >= 0.0 else Basis(Vector3.RIGHT, PI)
	# This basis maps +Z onto the average normal. The packer's existing
	# `pixel * basis` applies its inverse, taking that normal back onto +Z.
	# atan2 avoids the Rodrigues 1/(1 + cosine) singularity at the -Z pole.
	var axis := Vector3(-direction.y / sine, direction.x / sine, 0.0)
	return Basis(axis, atan2(sine, direction.z))


static func save_pair(save_png: Callable, save_import: Callable) -> Error:
	var png_error: Error = save_png.call()
	if png_error != OK:
		return png_error
	return save_import.call()
