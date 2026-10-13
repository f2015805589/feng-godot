@tool
class_name FMagicGIViz
extends RefCounted
## Builds the editor visualization under a FMagicGIVolume.
##
## Three layers, all children of one `_FMagicGIViz` node (kept out of the scene
## file by adding it as an internal child):
##   _Box    - line mesh of the volume's box.
##   _Probes - one cell-relative MultiMesh sphere per surface sample. Its RGB
##             shows the current complete GI response; blue marks exact zero.
##   _Transport - radial unit-source angular transport, including primary sky
##                visibility and secondary transfer. Emission has no direction.
const ProbeLayout = preload("feng_magic_gi_probe_layout.gd")
const Preview = preload("feng_magic_gi_preview.gd")
const PreviewShader = preload("feng_magic_gi_preview.gdshader")
const MAX_SH_VIZ_PROBES := 256
const SH_VIZ_SIDES := 12   # rings and sectors of the reconstruction mesh
const PROBE_GIZMO_CELL_RATIO := ProbeLayout.MARKER_RADIUS_CELL_RATIO
const ZERO_RESPONSE_COLOR := Color(0.08, 0.55, 0.95)
const ZERO_TRANSPORT_COLOR := Color(0.55, 0.55, 0.55)
const UNAVAILABLE_COLOR := Color(0.35, 0.35, 0.35)

static func build(volume: FMagicGIVolume, preview_snapshot: Dictionary = {}) -> Node3D:
	var root := Node3D.new()
	root.name = "_FMagicGIViz"
	rebuild(volume, root, preview_snapshot)
	return root

static func rebuild(volume: FMagicGIVolume, root: Node3D, preview_snapshot: Dictionary = {}) -> void:
	for child in root.get_children():
		child.queue_free()
		root.remove_child(child)
	_build_box(volume, root)
	if volume.show_probes:
		_build_probes(volume, root, preview_snapshot)
	if volume.show_sh_probes and _can_show_sh(preview_snapshot):
		_build_sh(volume, root, preview_snapshot)

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
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(instance)

static func _cell_extent(volume: FMagicGIVolume) -> float:
	var cell := volume.cell_size()
	return minf(cell.x, minf(cell.y, cell.z))

static func _probe_gizmo_radius(volume: FMagicGIVolume) -> float:
	# Keep the established scene-scaled editor marker. It can overlap nearby
	# surfaces; all visualization meshes explicitly stay out of shadow maps.
	return ProbeLayout.marker_radius(volume.cell_size())

static func _probe_color_state(preview_snapshot: Dictionary, index: int) -> Dictionary:
	if not bool(preview_snapshot.get("data_valid", false)) \
			or not bool(preview_snapshot.get("layout_matches", false)) \
			or not bool(preview_snapshot.get("current_available", false)):
		return {"color": UNAVAILABLE_COLOR, "compensate": true}
	var data := preview_snapshot.get("data") as FMagicGIData
	if data == null or index < 0 or index >= data.probe_count():
		return {"color": UNAVAILABLE_COLOR, "compensate": true}
	var response := Preview.probe_response(data, index,
			preview_snapshot.get("lighting", PackedFloat32Array()),
			preview_snapshot.get("sky_lighting", PackedFloat32Array()),
			preview_snapshot.get("emission_payload", PackedFloat32Array()),
			float(preview_snapshot.get("strength", 1.0)))
	if response == Vector3.ZERO:
		return {"color": ZERO_RESPONSE_COLOR, "compensate": true}
	return {"color": Color(response.x, response.y, response.z), "compensate": false}

static func _new_preview_material(preview_snapshot: Dictionary, unit_transport := false) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = PreviewShader
	material.set_shader_parameter("preview_unit_transport", unit_transport)
	_set_preview_view_parameters(material, preview_snapshot.get("editor_views", []))
	return material

static func _set_preview_view_parameters(material: ShaderMaterial, editor_views: Array) -> void:
	if material == null:
		return
	var uniforms := _preview_view_uniforms(editor_views)
	for parameter in uniforms.keys():
		material.set_shader_parameter(parameter, uniforms[parameter])

static func _preview_view_uniforms(editor_views: Array) -> Dictionary:
	var origins := PackedVector4Array()
	var rights := PackedVector4Array()
	var ups := PackedVector4Array()
	var backs := PackedVector4Array()
	var projections := PackedVector4Array()
	var sizes := PackedVector4Array()
	var scales := [1.0, 1.0, 1.0, 1.0]
	for index in 4:
		if index >= editor_views.size():
			origins.append(Vector4.ZERO)
			rights.append(Vector4.ZERO)
			ups.append(Vector4.ZERO)
			backs.append(Vector4.ZERO)
			projections.append(Vector4.ZERO)
			sizes.append(Vector4.ZERO)
			continue
		var view: Dictionary = editor_views[index]
		var origin: Vector3 = view.get("origin", Vector3.ZERO)
		var right: Vector3 = view.get("right", Vector3.RIGHT)
		var up: Vector3 = view.get("up", Vector3.UP)
		var back: Vector3 = view.get("back", Vector3.BACK)
		var size: Vector2 = view.get("viewport_size", Vector2.ZERO)
		origins.append(Vector4(origin.x, origin.y, origin.z, 1.0))
		rights.append(Vector4(right.x, right.y, right.z, 0.0))
		ups.append(Vector4(up.x, up.y, up.z, 0.0))
		backs.append(Vector4(back.x, back.y, back.z, 0.0))
		projections.append(Vector4(float(view.get("projection_x", 0.0)),
				float(view.get("projection_y", 0.0)),
				1.0 if bool(view.get("orthogonal", false)) else 0.0,
				size.x / maxf(size.y, 1.0)))
		sizes.append(Vector4(size.x, size.y, 0.0, 0.0))
		scales[index] = float(view.get("exposure_scale", 1.0))
	return {
		"preview_camera_origin": origins,
		"preview_camera_right": rights,
		"preview_camera_up": ups,
		"preview_camera_back": backs,
		"preview_camera_projection": projections,
		"preview_camera_size": sizes,
		"preview_eye_scale": Vector4(scales[0], scales[1], scales[2], scales[3]),
	}

static func _build_probes(volume: FMagicGIVolume, root: Node3D, preview_snapshot: Dictionary) -> void:
	var count := volume.probe_count()
	if count == 0:
		return
	var sphere := SphereMesh.new()
	sphere.radius = _probe_gizmo_radius(volume)
	sphere.height = sphere.radius * 2.0
	var preview_material := _new_preview_material(preview_snapshot)
	sphere.material = preview_material
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = sphere
	mm.instance_count = count
	var inverse_volume_transform: Transform3D = volume.global_transform.affine_inverse()
	for i in count:
		# probe_positions is world space; the viz node is a volume child, so
		# convert through the inverse transform.
		var local: Vector3 = inverse_volume_transform * volume.probe_positions[i]
		var density_scale := 1.0
		if volume.adaptive_placement and volume.probe_spacings.size() == count:
			# The same marker-to-spacing ratio represents the selected local density.
			# Placement checks the larger physical footprint before accepting a point.
			density_scale = volume.probe_spacings[i] / volume.probe_spacing
		mm.set_instance_transform(i, Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * density_scale), local))
		var color_state := _probe_color_state(preview_snapshot, i)
		mm.set_instance_color(i, color_state["color"])
		mm.set_instance_custom_data(i, Color(1.0 if color_state["compensate"] else 0.0, 0.0, 0.0, 1.0))
	var node := MultiMeshInstance3D.new()
	node.name = "_Probes"
	node.multimesh = mm
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(node)

## Updates data-dependent preview geometry without rebuilding its layout or box.
static func update_preview(volume: FMagicGIVolume, root: Node3D, preview_snapshot: Dictionary) -> void:
	if volume.show_probes:
		var probe_node := root.get_node_or_null("_Probes") as MultiMeshInstance3D
		if probe_node != null and probe_node.multimesh != null:
			var mm := probe_node.multimesh
			for index in mini(volume.probe_count(), mm.instance_count):
				var color_state := _probe_color_state(preview_snapshot, index)
				mm.set_instance_color(index, color_state["color"])
				mm.set_instance_custom_data(index,
						Color(1.0 if color_state["compensate"] else 0.0, 0.0, 0.0, 1.0))
	if not volume.show_sh_probes:
		return
	var holder := root.get_node_or_null("_Transport") as Node3D
	if not _can_show_sh(preview_snapshot):
		if holder != null:
			_clear_holder(holder)
		return
	if holder == null:
		_build_sh(volume, root, preview_snapshot)
		return
	var data := preview_snapshot.get("data") as FMagicGIData
	var key := _sh_data_key(data)
	if String(holder.get_meta("preview_data_key", "")) == key:
		return
	_clear_holder(holder)
	_populate_sh(volume, holder, data, -1, preview_snapshot)
	holder.set_meta("preview_data_key", key)

## Updates only per-view shader parameters. Camera motion and exposure readback
## do not rebuild marker instances or the SH reconstruction meshes.
static func update_preview_exposure(_volume: FMagicGIVolume, root: Node3D,
		preview_snapshot: Dictionary) -> void:
	var probe_node := root.get_node_or_null("_Probes") as MultiMeshInstance3D
	if probe_node != null and probe_node.multimesh != null:
		var sphere := probe_node.multimesh.mesh as SphereMesh
		var material: ShaderMaterial = null
		if sphere != null:
			material = sphere.material as ShaderMaterial
		_set_preview_view_parameters(material, preview_snapshot.get("editor_views", []))
	var holder := root.get_node_or_null("_Transport") as Node3D
	if holder != null and holder.get_child_count() > 0:
		var mesh_instance := holder.get_child(0) as MeshInstance3D
		if mesh_instance != null:
			_set_preview_view_parameters(mesh_instance.material_override as ShaderMaterial,
					preview_snapshot.get("editor_views", []))

static func _can_show_sh(preview_snapshot: Dictionary) -> bool:
	return bool(preview_snapshot.get("data_valid", false)) \
			and bool(preview_snapshot.get("layout_matches", false)) \
			and preview_snapshot.get("data") is FMagicGIData

static func _build_sh(volume: FMagicGIVolume, root: Node3D, preview_snapshot: Dictionary) -> void:
	var holder := Node3D.new()
	holder.name = "_Transport"
	holder.set_meta("preview_data_key", _sh_data_key(preview_snapshot.get("data") as FMagicGIData))
	root.add_child(holder)
	_populate_sh(volume, holder, preview_snapshot.get("data") as FMagicGIData, -1, preview_snapshot)

static func _populate_sh(volume: FMagicGIVolume, holder: Node3D, data: FMagicGIData,
		count: int = -1, preview_snapshot: Dictionary = {}) -> void:
	if data == null:
		return
	if count < 0:
		count = mini(volume.probe_count(), MAX_SH_VIZ_PROBES)
	var radius := _cell_extent(volume) * 0.45
	var plot_basis := volume.global_basis.orthonormalized()
	var material := _new_preview_material(preview_snapshot, true)
	for i in count:
		var local_radius := radius
		if volume.adaptive_placement and volume.probe_spacings.size() == count:
			local_radius *= volume.probe_spacings[i] / volume.probe_spacing
		var mesh := _sh_mesh(data, i, local_radius, plot_basis)
		var node := MeshInstance3D.new()
		node.mesh = mesh
		var local: Vector3 = volume.global_transform.affine_inverse() * volume.probe_positions[i]
		node.position = local
		node.material_override = material
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		holder.add_child(node)

static func _clear_holder(holder: Node3D) -> void:
	for child in holder.get_children():
		holder.remove_child(child)
		child.queue_free()
	holder.remove_meta("preview_data_key")

static func _sh_data_key(data: FMagicGIData) -> String:
	return "%d:%d" % [data.get_instance_id(), data.bake_version] if data != null else ""

static func _sh_mesh(data: FMagicGIData, probe_index: int, radius: float,
		local_to_world: Basis) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var rings := SH_VIZ_SIDES
	var sectors := SH_VIZ_SIDES * 2
	var scale := 0.0
	# Normalize by this probe's strongest lobe. RGB ratios retain its response hue.
	for ring in rings + 1:
		for sector in sectors:
			var dir := _ring_dir(ring, rings, sector, sectors)
			var world_dir := (local_to_world * dir).normalized()
			scale = maxf(scale, Preview.unit_source_response(data, probe_index, world_dir).length())
	var zero_response := scale <= 0.0
	if zero_response:
		scale = 1.0
	for ring in rings + 1:
		for sector in sectors:
			var dir := _ring_dir(ring, rings, sector, sectors)
			var world_dir := (local_to_world * dir).normalized()
			var response := Preview.unit_source_response(data, probe_index, world_dir)
			var magnitude := response.length() / scale if not zero_response else 0.0
			verts.append(dir * (radius * (0.25 + 0.75 * magnitude)))
			colors.append(ZERO_TRANSPORT_COLOR if zero_response else Color(response.x, response.y, response.z) / scale)
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
