@tool
class_name FengSkyLightCubemapAdapter
extends RefCounted
## Radiance helpers shared by scene captures and specified Cubemap resources.

const SH_Y00 := 0.2820947918


static func project_world_linear_panorama(image: Image, local_to_world: Basis,
		energy: float) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	result.resize(27)
	if image == null or image.is_empty() or image.get_width() <= 0 or image.get_height() <= 0:
		return result
	var safe_energy := energy if is_finite(energy) else 0.0
	safe_energy = maxf(safe_energy, 0.0)
	var rotation := local_to_world.orthonormalized()
	var width := image.get_width()
	var height := image.get_height()
	var total_solid_angle := 0.0
	for y in height:
		var theta := PI * (float(y) + 0.5) / float(height)
		var row_weight := sin(theta) * PI * TAU / float(width * height)
		total_solid_angle += row_weight * float(width)
		for x in width:
			var phi := TAU * (float(x) + 0.5) / float(width)
			# Matches Godot SkyRD's equirectangular direction used by Sky baking.
			var local_direction := Vector3(
					-sin(phi) * sin(theta),
					cos(theta),
					-cos(phi) * sin(theta))
			var world_direction := (rotation * local_direction).normalized()
			var basis := _sh_basis(world_direction)
			var color := image.get_pixel(x, y)
			for coefficient in 9:
				var weight := basis[coefficient] * row_weight * safe_energy
				for channel in 3:
					var radiance: float = float(color[channel])
					if is_finite(radiance):
						result[coefficient * 3 + channel] += radiance * weight
	if total_solid_angle > 0.0:
		var normalization := 4.0 * PI / total_solid_angle
		for index in 27:
			result[index] *= normalization
	return result


static func _sh_basis(direction: Vector3) -> PackedFloat32Array:
	var basis := PackedFloat32Array()
	basis.resize(9)
	basis[0] = SH_Y00
	basis[1] = 0.4886025119 * direction.y
	basis[2] = 0.4886025119 * direction.z
	basis[3] = 0.4886025119 * direction.x
	basis[4] = 1.0925484306 * direction.x * direction.y
	basis[5] = 1.0925484306 * direction.y * direction.z
	basis[6] = 0.3153915653 * (3.0 * direction.z * direction.z - 1.0)
	basis[7] = 1.0925484306 * direction.x * direction.z
	basis[8] = 0.5462742153 * (direction.x * direction.x - direction.y * direction.y)
	return basis
