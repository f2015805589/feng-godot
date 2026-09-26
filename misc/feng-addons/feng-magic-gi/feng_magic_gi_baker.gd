@tool
class_name FMagicGIBaker
extends RefCounted
## Captures the scene around each probe and projects it onto SH3.
##
## For every probe a shared SubViewport renders the six cube faces of a 90-degree
## pinhole camera, the face images are integrated against the SH basis on the CPU
## and normalized by the captured solid angle (a uniform sky must reproduce the
## analytic c0 = 4*pi*Y00). This is classic PRT probe baking - Sloan et al. 2002
## for the projection, Ramamoorthi & Hanrahan 2001 for the cosine convolution the
## shader applies at apply time.

const Data = preload("feng_magic_gi_data.gd")

const FACE_DIRS: Array[Vector3] = [
	Vector3.RIGHT, Vector3.LEFT, Vector3.UP, Vector3.DOWN, Vector3.FORWARD, Vector3.BACK]
const FACE_UPS: Array[Vector3] = [
	Vector3.DOWN, Vector3.DOWN, Vector3.FORWARD, Vector3.BACK, Vector3.DOWN, Vector3.DOWN]
# Probe captures render the same world as the scene - the debug meshes the volume
# shows would otherwise bake themselves into the probes, so the volume hides them.
const FOUR_PI := 12.56637061435917295385

## Y_l,m in bake order. Index 0..8, l<=2 (Sloan's convention):
## Y0, Y1-1(y), Y10(z), Y11(x), Y2-2(xy), Y2-1(yz), Y20(3z2-1), Y21(xz), Y22(x2-y2).
static func sh_basis(dir: Vector3) -> PackedFloat32Array:
	var c := PackedFloat32Array()
	c.resize(9)
	c[0] = 0.2820947918
	c[1] = 0.4886025119 * dir.y
	c[2] = 0.4886025119 * dir.z
	c[3] = 0.4886025119 * dir.x
	c[4] = 1.0925484306 * dir.x * dir.y
	c[5] = 1.0925484306 * dir.y * dir.z
	c[6] = 0.3153915653 * (3.0 * dir.z * dir.z - 1.0)
	c[7] = 1.0925484306 * dir.x * dir.z
	c[8] = 0.5462742153 * (dir.x * dir.x - dir.y * dir.y)
	return c

## Runs the whole bake. Awaits frames internally; returns null when the volume
## left the tree mid-bake.
func bake_volume(volume: FMagicGIVolume) -> Data:
	var positions := volume.probe_positions
	if positions.is_empty():
		volume._rebuild_probes()
		positions = volume.probe_positions
	if positions.is_empty() or not volume.is_inside_tree():
		return null
	var size := volume.bake_resolution
	var vp := SubViewport.new()
	vp.name = "_FMagicGIBakeViewport"
	vp.size = Vector2i(size, size)
	vp.world_3d = volume.get_world_3d()
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	vp.handle_input_locally = false
	var cam := Camera3D.new()
	cam.fov = 90.0
	cam.near = 0.05
	cam.current = true
	vp.add_child(cam)
	volume.add_sibling(vp)
	# The probe debug meshes live in the same world the bake sees.
	var viz_was_visible := true
	if volume._viz != null:
		viz_was_visible = volume._viz.visible
		volume._viz.visible = false

	# Pixel (s,t) of a 90-degree pinhole camera looks along basis * (u, -v, -1),
	# and its solid angle on that plane is du*dv / (1+u^2+v^2)^1.5.
	var weights := PackedFloat32Array()
	for s in size:
		for t in size:
			var u := 2.0 * (s + 0.5) / size - 1.0
			var v := 2.0 * (t + 0.5) / size - 1.0
			weights.append(4.0 / (size * size) / pow(1.0 + u * u + v * v, 1.5))

	var data := Data.new()
	data.grid_dims = volume.probe_dims
	data.volume_transform = volume.global_transform
	data.world_to_grid = volume.world_to_grid_transform()
	var count := positions.size()
	data.sh = PackedFloat32Array()
	data.sh.resize(count * 27)

	for probe_index in count:
		var probe_pos: Vector3 = positions[probe_index]
		var coeffs := PackedFloat32Array()
		coeffs.resize(27)
		for face in 6:
			cam.global_transform = Transform3D(Basis.IDENTITY, probe_pos).looking_at(
					probe_pos + FACE_DIRS[face], FACE_UPS[face])
			var basis_now := cam.global_transform.basis
			# The SH is stored in the volume's local frame so a moved or rotated
			# volume drags its baked field along rigidly.
			var world_to_local_basis := volume.global_transform.basis.inverse()
			vp.render_target_update_mode = SubViewport.UPDATE_ONCE
			await RenderingServer.frame_post_draw
			var image := vp.get_texture().get_image()
			if image == null:
				continue
			image.convert(Image.FORMAT_RGBAF)
			var pixels := image.get_data().to_float32_array()
			for s in size:
				for t in size:
					var pi := t * size + s
					var dir := (world_to_local_basis * basis_now * Vector3(
							2.0 * (s + 0.5) / size - 1.0,
							-(2.0 * (t + 0.5) / size - 1.0),
							-1.0)).normalized()
					var w: float = weights[pi]
					var y := sh_basis(dir)
					var rgb := Vector3(pixels[pi * 4], pixels[pi * 4 + 1], pixels[pi * 4 + 2])
					for k in 9:
						var c := w * y[k]
						coeffs[k * 3] += rgb.x * c
						coeffs[k * 3 + 1] += rgb.y * c
						coeffs[k * 3 + 2] += rgb.z * c
		# Renormalize to a full sphere so texel-size / border error cannot dim the sky.
		var total_w := 0.0
		for w in weights:
			total_w += w
		var norm := FOUR_PI / (total_w * 6.0)
		for k in 27:
			data.sh[probe_index * 27 + k] = coeffs[k] * norm

	vp.queue_free()
	if volume._viz != null:
		volume._viz.visible = viz_was_visible
	return data
