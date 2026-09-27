@tool
class_name FMagicGIViz
extends RefCounted
## Builds the editor visualization under a FMagicGIVolume.
##
## Three layers, all children of one `_FMagicGIViz` node (kept out of the scene
## file by adding it as an internal child):
##   _Box    - line mesh of the volume's box.
##   _Probes - one MultiMesh sphere per surface sample, tinted by its response
##             to a unit directional source from world +Y; gray before a bake.
##   _Transport - radial visualization of geometry transport response, not
##                stored or current light radiance. Capped at 256 samples.
const MAX_SH_VIZ_PROBES := 256
const SH_VIZ_SIDES := 12   # rings and sectors of the reconstruction mesh

static func build(volume: FMagicGIVolume) -> Node3D:
	var root := Node3D.new()
	root.name = "_FMagicGIViz"
	rebuild(volume, root)
	return root

static func rebuild(volume: FMagicGIVolume, root: Node3D) -> void:
	for child in root.get_children():
		child.queue_free()
		root.remove_child(child)
	_build_box(volume, root)
	if volume.show_probes:
		_build_probes(volume, root)
	if volume.show_sh_probes and volume.has_bake():
		_build_sh(volume, root)

static func _build_box(volume: FMagicGIVolume, root: Node3D) -> void:
	var h: Vector3 = volume.size * 0.5
	var corners := [
		Vector3(-h.x, -h.y, -h.z), Vector3(h.x, -h.y, -h.z),
		Vector3(h.x, -h.y, h.z), Vector3(-h.x, -h.y, h.z),
		Vector3(-h.x, h.y, -h.z), Vector3(h.x, h.y, -h.z),
		Vector3(h.x, h.y, h.z), Vector3(-h.x, h.y, h.z)]
	var edges := [0, 1, 1, 2, 2, 3, 3, 0, 4, 5, 5, 6, 6, 7, 7, 4, 0, 4, 1, 5, 2, 6, 3, 7]
	var mesh := ArrayMesh.new()
	var verts := PackedVector3Array()
	for e in edges:
		verts.append(corners[e])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.2, 0.9, 0.7)
	var instance := MeshInstance3D.new()
	instance.name = "_Box"
	instance.mesh = mesh
	instance.material_override = material
	root.add_child(instance)

static func _cell_extent(volume: FMagicGIVolume) -> float:
	var cell := volume.cell_size()
	return minf(cell.x, minf(cell.y, cell.z))

static func _build_probes(volume: FMagicGIVolume, root: Node3D) -> void:
	var count := volume.probe_count()
	if count == 0:
		return
	var sphere := SphereMesh.new()
	sphere.radius = _cell_extent(volume) * 0.12
	sphere.height = sphere.radius * 2.0
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	sphere.material = material
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = sphere
	mm.instance_count = count
	var data := volume.bake_data if volume.has_bake() else null
	for i in count:
		# probe_positions is world space; the viz node is a volume child, so
		# convert through the inverse transform.
		var local: Vector3 = volume.global_transform.affine_inverse() * volume.probe_positions[i]
		var color := Color(0.35, 0.35, 0.35)
		if data != null:
			color = data.transport_preview_color(i)
		var scale_basis := Basis.IDENTITY
		mm.set_instance_transform(i, Transform3D(scale_basis, local))
		mm.set_instance_color(i, color)
	var node := MultiMeshInstance3D.new()
	node.name = "_Probes"
	node.multimesh = mm
	root.add_child(node)

static func _build_sh(volume: FMagicGIVolume, root: Node3D) -> void:
	var data := volume.bake_data
	var count := mini(volume.probe_count(), MAX_SH_VIZ_PROBES)
	var radius := _cell_extent(volume) * 0.45
	var plot_basis := volume.global_basis.orthonormalized()
	var holder := Node3D.new()
	holder.name = "_Transport"
	root.add_child(holder)
	for i in count:
		var mesh := _sh_mesh(data, i, radius, plot_basis)
		var node := MeshInstance3D.new()
		node.mesh = mesh
		var local: Vector3 = volume.global_transform.affine_inverse() * volume.probe_positions[i]
		node.position = local
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.vertex_color_use_as_albedo = true
		node.material_override = material
		holder.add_child(node)

## Radial transfer plot: vertex at direction d sits at d * |T(d)| * radius_scale;
## vertex color shows the positive RGB response to a unit directional source.
static func _sh_mesh(data: FMagicGIData, probe_index: int, radius: float,
		local_to_world: Basis) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var rings := SH_VIZ_SIDES
	var sectors := SH_VIZ_SIDES * 2
	var scale := 0.0
	# Normalize by the strongest lobe so shapes compare across probes.
	for ring in rings + 1:
		for sector in sectors:
			var dir := _ring_dir(ring, rings, sector, sectors)
			var world_dir := (local_to_world * dir).normalized()
			scale = maxf(scale, data.transport_response(probe_index, world_dir).length())
	if scale <= 0.0:
		scale = 1.0
	for ring in rings + 1:
		for sector in sectors:
			var dir := _ring_dir(ring, rings, sector, sectors)
			var world_dir := (local_to_world * dir).normalized()
			var response := data.transport_response(probe_index, world_dir)
			var magnitude := response.length() / scale
			verts.append(dir * (radius * (0.25 + 0.75 * magnitude)))
			colors.append(Color(maxf(response.x, 0.0), maxf(response.y, 0.0), maxf(response.z, 0.0)) / scale)
	for ring in rings:
		for sector in sectors:
			var a := ring * sectors + sector
			var b := ring * sectors + (sector + 1) % sectors
			var c := (ring + 1) * sectors + sector
			var d := (ring + 1) * sectors + (sector + 1) % sectors
			indices.append_array([a, c, b, b, c, d])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

static func _ring_dir(ring: int, rings: int, sector: int, sectors: int) -> Vector3:
	var phi := PI * float(ring) / float(rings)
	var theta := TAU * float(sector) / float(sectors)
	return Vector3(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta))
