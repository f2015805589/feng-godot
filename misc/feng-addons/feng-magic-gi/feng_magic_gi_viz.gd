@tool
class_name FMagicGIViz
extends RefCounted
## Builds the editor visualization under a FMagicGIVolume.
##
## Debug layers under one `_FMagicGIViz` node (kept out of the scene
## file by adding it as an internal child):
##   _Box    - line mesh of the volume's box.
##   _Probes - one cell-relative MultiMesh sphere per surface sample. Its RGB
##             shows the current complete GI response; blue marks exact zero.
##   _Transport - legacy radial unit-source transport, or live irradiance SH
##                spheres for free-space source probes and resident CLV cells.
##   _CLVLevelN - current cascade bounds, present only in CLV display mode.
const ProbeLayout = preload("feng_magic_gi_probe_layout.gd")
const Preview = preload("feng_magic_gi_preview.gd")
const PreviewShader = preload("feng_magic_gi_preview.gdshader")
const VolumeSHPreviewShader = preload("feng_magic_gi_volume_sh_preview.gdshader")
const OverlayShader = preload("feng_magic_gi_overlay.gdshader")
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
	root.set_meta("_layout_stale", volume.is_layout_stale())
	_build_box(volume, root)
	_update_stream_status(volume, root, preview_snapshot)
	root.set_meta("volume_probe_preview", bool(preview_snapshot.get("volume_probe_preview", false)))
	if bool(preview_snapshot.get("volume_probe_preview", false)):
		_build_volume_preview(volume, root, preview_snapshot)
		set_layout_stale(root, volume.is_layout_stale())
		return
	if volume.show_probes:
		_build_probes(volume, root, preview_snapshot)
	if volume.show_sh_probes and _can_show_sh(preview_snapshot):
		_build_sh(volume, root, preview_snapshot)
	set_layout_stale(root, volume.is_layout_stale())

## Resizes only the local box mesh. Baked probe positions remain world-anchored.
static func update_box(volume: FMagicGIVolume, root: Node3D) -> void:
	if root == null or not is_instance_valid(root):
		return
	var old_box := root.get_node_or_null("_Box")
	if old_box != null:
		root.remove_child(old_box)
		old_box.queue_free()
	_build_box(volume, root)

## One uniform change updates stale tint without touching probe instance arrays.
static func set_layout_stale(root: Node3D, stale: bool) -> void:
	if root == null or not is_instance_valid(root):
		return
	root.set_meta("_layout_stale", stale)
	var probe_node := root.get_node_or_null("_Probes") as MultiMeshInstance3D
	if probe_node != null and probe_node.multimesh != null:
		var sphere := probe_node.multimesh.mesh as SphereMesh
		var probe_material := sphere.material as ShaderMaterial if sphere != null else null
		if probe_material != null:
			probe_material.set_shader_parameter("preview_layout_stale", stale)
	var holder := root.get_node_or_null("_Transport") as Node3D
	var volume_sh := holder as MultiMeshInstance3D
	if volume_sh != null:
		var material := volume_sh.material_override as ShaderMaterial
		if material != null:
			material.set_shader_parameter("preview_layout_stale", stale)
	if holder != null and not holder.get_children().is_empty():
		var first_probe := holder.get_child(0) as MeshInstance3D
		var transport_material := first_probe.material_override as ShaderMaterial if first_probe != null else null
		if transport_material != null:
			transport_material.set_shader_parameter("preview_layout_stale", stale)

static func _track_preview_material(root: Node3D, material: ShaderMaterial) -> void:
	if root == null or material == null:
		return
	material.set_shader_parameter("preview_layout_stale",
			bool(root.get_meta("_layout_stale", false)))

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
	instance.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	root.add_child(instance)

static func _cell_extent(volume: FMagicGIVolume) -> float:
	var cell := volume.cell_size()
	return minf(cell.x, minf(cell.y, cell.z))

static func _probe_gizmo_radius(volume: FMagicGIVolume) -> float:
	# Keep the established scene-scaled editor marker. It can overlap nearby
	# surfaces; all visualization meshes explicitly stay out of shadow maps.
	return ProbeLayout.marker_radius(volume.cell_size())

## Candidate points are a separate world-anchored layer. They never reuse saved
## page/data indices, so an old SH preview remains paired with its old probes.
static func build_candidate_layout_node(volume: FMagicGIVolume,
		positions: PackedVector3Array, spacings: PackedFloat32Array,
		layout_current: bool, revision: int) -> Node3D:
	var count := positions.size()
	if count <= 0 or not is_instance_valid(volume) or not volume.is_inside_tree():
		return null
	var sphere := SphereMesh.new()
	sphere.radius = _probe_gizmo_radius(volume)
	sphere.height = sphere.radius * 2.0
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.12, 0.95, 0.76, 0.82) if layout_current else Color(0.58, 0.62, 0.62, 0.65)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sphere.material = material
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = sphere
	mm.instance_count = count
	var basis: Basis = volume.global_transform.basis
	var tree := volume.get_tree()
	var slice_started := Time.get_ticks_usec()
	for index in count:
		var density_scale := 1.0
		if volume.adaptive_placement and spacings.size() == count:
			density_scale = spacings[index] / volume.probe_spacing
		mm.set_instance_transform(index, Transform3D(
				basis * Basis.IDENTITY.scaled(Vector3.ONE * density_scale), positions[index]))
		if Time.get_ticks_usec() - slice_started >= 2500:
			if not is_instance_valid(tree) or not volume.is_inside_tree():
				return null
			await tree.process_frame
			slice_started = Time.get_ticks_usec()
	var node := MultiMeshInstance3D.new()
	node.name = "_CandidateProbes"
	node.top_level = true
	node.multimesh = mm
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	node.set_meta("candidate_layout_revision", revision)
	node.set_meta("candidate_layout_current", layout_current)
	return node

static func install_candidate_layout(root: Node3D, node: Node3D, revision: int) -> void:
	if root == null or not is_instance_valid(root):
		return
	clear_candidate_layout(root)
	if node == null or not is_instance_valid(node):
		return
	root.add_child(node)
	node.set_meta("candidate_layout_revision", revision)

static func clear_candidate_layout(root: Node3D) -> void:
	if root == null or not is_instance_valid(root):
		return
	var old := root.get_node_or_null("_CandidateProbes")
	if old != null:
		root.remove_child(old)
		old.queue_free()

static func set_candidate_layout_current(root: Node3D, layout_current: bool) -> void:
	if root == null or not is_instance_valid(root):
		return
	var node := root.get_node_or_null("_CandidateProbes") as MultiMeshInstance3D
	if node == null or node.multimesh == null:
		return
	var sphere := node.multimesh.mesh as SphereMesh
	var material := sphere.material as StandardMaterial3D if sphere != null else null
	if material == null:
		return
	material.albedo_color = Color(0.12, 0.95, 0.76, 0.82) if layout_current else Color(0.58, 0.62, 0.62, 0.65)
	node.set_meta("candidate_layout_current", layout_current)

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

static func _streamed_probe_color_state(preview_snapshot: Dictionary,
		page: Dictionary, index: int) -> Dictionary:
	if not bool(preview_snapshot.get("data_valid", false)) \
			or not bool(preview_snapshot.get("current_available", false)):
		return {"color": UNAVAILABLE_COLOR, "compensate": true}
	var data := page.get("data") as FMagicGIData
	if data == null or index < 0 or index >= data.probe_count():
		return {"color": UNAVAILABLE_COLOR, "compensate": true}
	var lighting: PackedFloat32Array = page.get("lighting", PackedFloat32Array())
	var sky_lighting: PackedFloat32Array = page.get("sky_lighting", PackedFloat32Array())
	var emission_payload: PackedFloat32Array = page.get("emission_payload", PackedFloat32Array())
	var response := data.evaluate(index, lighting, sky_lighting)
	if emission_payload.size() == data.probe_count() * 3:
		var base := index * 3
		response += Vector3(emission_payload[base], emission_payload[base + 1],
				emission_payload[base + 2])
	response *= float(preview_snapshot.get("strength", 1.0))
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
	var streamed := bool(preview_snapshot.get("streamed", false))
	if not streamed and volume.candidate_probe_count() > 0 and not volume.has_bake():
		return # Candidate points are built in bounded main-thread slices below.
	var pages: Array = preview_snapshot.get("pages", [])
	var count := 0
	if streamed:
		for page in pages:
			var data := page.get("data") as FMagicGIData
			if data != null:
				count += data.probe_count()
	else:
		count = volume.probe_count()
	if count == 0:
		return
	var sphere := SphereMesh.new()
	sphere.radius = _probe_gizmo_radius(volume)
	sphere.height = sphere.radius * 2.0
	var preview_material := _new_preview_material(preview_snapshot)
	_track_preview_material(root, preview_material)
	sphere.material = preview_material
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = sphere
	mm.instance_count = count
	var instance_basis: Basis = volume.global_transform.basis
	var output_index := 0
	if streamed:
		for page in pages:
			var data := page.get("data") as FMagicGIData
			if data == null:
				continue
			for probe in data.probe_count():
				var density_scale := _probe_density_scale(data, probe, volume.probe_spacing)
				mm.set_instance_transform(output_index, Transform3D(
						instance_basis * Basis.IDENTITY.scaled(Vector3.ONE * density_scale),
						data.positions[probe]))
				var color_state := _streamed_probe_color_state(preview_snapshot, page, probe)
				mm.set_instance_color(output_index, color_state["color"])
				mm.set_instance_custom_data(output_index,
						Color(1.0 if color_state["compensate"] else 0.0, 0.0, 0.0, 1.0))
				output_index += 1
	else:
		for i in count:
			# The marker node is top-level so baked world anchors do not follow a
			# moved Volume. Keep its original scene-scaled radius/orientation.
			var density_scale := 1.0
			if volume.adaptive_placement and volume.probe_spacings.size() == count:
				# Keep the established marker-to-spacing ratio for local density.
				density_scale = volume.probe_spacings[i] / volume.probe_spacing
			mm.set_instance_transform(i, Transform3D(
					instance_basis * Basis.IDENTITY.scaled(Vector3.ONE * density_scale),
					volume.probe_positions[i]))
			var color_state := _probe_color_state(preview_snapshot, i)
			mm.set_instance_color(i, color_state["color"])
			mm.set_instance_custom_data(i,
					Color(1.0 if color_state["compensate"] else 0.0, 0.0, 0.0, 1.0))
	var node := MultiMeshInstance3D.new()
	node.name = "_Probes"
	node.top_level = true
	node.multimesh = mm
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	if streamed:
		node.set_meta("page_layout_key", String(preview_snapshot.get("page_layout_key", "")))
	root.add_child(node)

static func _probe_density_scale(data: FMagicGIData, index: int, fallback_spacing: float) -> float:
	if data.adaptive_placement and data.probe_spacings.size() == data.probe_count():
		return data.probe_spacings[index] / maxf(fallback_spacing, 0.1)
	return data.spacing / maxf(fallback_spacing, 0.1)

## Updates data-dependent preview geometry without rebuilding its layout or box.
static func update_preview(volume: FMagicGIVolume, root: Node3D, preview_snapshot: Dictionary) -> void:
	if bool(preview_snapshot.get("volume_probe_preview", false)):
		_update_volume_preview(volume, root, preview_snapshot)
		return
	if bool(root.get_meta("volume_probe_preview", false)):
		rebuild(volume, root, preview_snapshot)
		return
	_update_stream_status(volume, root, preview_snapshot)
	if volume.show_probes:
		var probe_node := root.get_node_or_null("_Probes") as MultiMeshInstance3D
		var streamed := bool(preview_snapshot.get("streamed", false))
		if streamed and (probe_node == null \
				or String(probe_node.get_meta("page_layout_key", "")) \
				!= String(preview_snapshot.get("page_layout_key", ""))):
			if probe_node != null:
				root.remove_child(probe_node)
				probe_node.queue_free()
			_build_probes(volume, root, preview_snapshot)
			probe_node = root.get_node_or_null("_Probes") as MultiMeshInstance3D
		if probe_node != null and probe_node.multimesh != null:
			var mm := probe_node.multimesh
			if streamed:
				var output_index := 0
				for page in preview_snapshot.get("pages", []):
					var data := page.get("data") as FMagicGIData
					if data == null:
						continue
					for probe in data.probe_count():
						if output_index >= mm.instance_count:
							break
						var color_state := _streamed_probe_color_state(preview_snapshot, page, probe)
						mm.set_instance_color(output_index, color_state["color"])
						mm.set_instance_custom_data(output_index,
								Color(1.0 if color_state["compensate"] else 0.0, 0.0, 0.0, 1.0))
						output_index += 1
			else:
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
	var key := _preview_sh_key(preview_snapshot)
	if String(holder.get_meta("preview_data_key", "")) == key:
		return
	_clear_holder(holder)
	_populate_sh_pages(volume, holder, preview_snapshot)
	holder.set_meta("preview_data_key", key)

## Updates only per-view shader parameters. Camera motion and exposure readback
## do not rebuild marker instances or the SH reconstruction meshes.
static func update_preview_exposure(_volume: FMagicGIVolume, root: Node3D,
		preview_snapshot: Dictionary) -> void:
	for lod in 4:
		var bounds_node := root.get_node_or_null("_CLVLevel%d" % lod) as MeshInstance3D
		if bounds_node != null:
			_set_preview_view_parameters(bounds_node.material_override as ShaderMaterial,
					preview_snapshot.get("editor_views", []))
	var probe_node := root.get_node_or_null("_Probes") as MultiMeshInstance3D
	if probe_node != null and probe_node.multimesh != null:
		var sphere := probe_node.multimesh.mesh as SphereMesh
		var material: ShaderMaterial = null
		if sphere != null:
			material = sphere.material as ShaderMaterial
		_set_preview_view_parameters(material, preview_snapshot.get("editor_views", []))
	var holder := root.get_node_or_null("_Transport") as Node3D
	if holder != null:
		if holder is MultiMeshInstance3D:
			_set_preview_view_parameters((holder as MultiMeshInstance3D).material_override as ShaderMaterial,
					preview_snapshot.get("editor_views", []))
		for child in holder.get_children():
			var mesh_instance := child as MeshInstance3D
			if mesh_instance != null:
				_set_preview_view_parameters(mesh_instance.material_override as ShaderMaterial,
						preview_snapshot.get("editor_views", []))

static func _can_show_sh(preview_snapshot: Dictionary) -> bool:
	if bool(preview_snapshot.get("streamed", false)):
		for page in preview_snapshot.get("pages", []):
			if page.get("data") is FMagicGIData:
				return true
		return false
	return bool(preview_snapshot.get("data_valid", false)) \
			and bool(preview_snapshot.get("layout_matches", false)) \
			and preview_snapshot.get("data") is FMagicGIData

static func _build_sh(volume: FMagicGIVolume, root: Node3D, preview_snapshot: Dictionary) -> void:
	var holder := Node3D.new()
	holder.name = "_Transport"
	holder.top_level = true
	holder.set_meta("preview_data_key", _preview_sh_key(preview_snapshot))
	root.add_child(holder)
	_populate_sh_pages(volume, holder, preview_snapshot)

static func _populate_sh_pages(volume: FMagicGIVolume, holder: Node3D,
		preview_snapshot: Dictionary) -> void:
	if bool(preview_snapshot.get("streamed", false)):
		var remaining := MAX_SH_VIZ_PROBES
		for page in preview_snapshot.get("pages", []):
			var data := page.get("data") as FMagicGIData
			if data == null or remaining <= 0:
				continue
			var count := mini(data.probe_count(), remaining)
			_populate_sh(volume, holder, data, count, preview_snapshot)
			remaining -= count
	else:
		_populate_sh(volume, holder, preview_snapshot.get("data") as FMagicGIData,
				-1, preview_snapshot)

static func _populate_sh(volume: FMagicGIVolume, holder: Node3D, data: FMagicGIData,
		count: int = -1, preview_snapshot: Dictionary = {}) -> void:
	if data == null:
		return
	if count < 0:
		count = mini(data.probe_count(), MAX_SH_VIZ_PROBES)
	var radius := _cell_extent(volume) * 0.45
	var world_basis := volume.global_transform.basis
	var plot_basis := world_basis.orthonormalized()
	var material := _new_preview_material(preview_snapshot, true)
	_track_preview_material(holder.get_parent() as Node3D, material)
	for i in count:
		var local_radius := radius
		local_radius *= _probe_density_scale(data, i, volume.probe_spacing)
		var mesh := _sh_mesh(data, i, local_radius, plot_basis, world_basis)
		var node := MeshInstance3D.new()
		node.mesh = mesh
		node.position = data.positions[i]
		node.material_override = material
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		holder.add_child(node)

static func _clear_holder(holder: Node3D) -> void:
	for child in holder.get_children():
		holder.remove_child(child)
		child.queue_free()
	holder.remove_meta("preview_data_key")

static func _sh_data_key(data: FMagicGIData) -> String:
	return "%d:%d" % [data.get_instance_id(), data.bake_version] if data != null else ""

static func _preview_sh_key(preview_snapshot: Dictionary) -> String:
	if not bool(preview_snapshot.get("streamed", false)):
		return _sh_data_key(preview_snapshot.get("data") as FMagicGIData)
	return String(preview_snapshot.get("page_layout_key", ""))

static func _update_stream_status(volume: FMagicGIVolume, root: Node3D,
		preview_snapshot: Dictionary) -> void:
	var label := root.get_node_or_null("_StreamStatus") as Label3D
	var volume_preview := bool(preview_snapshot.get("volume_probe_preview", false))
	# Source/CLV counts and level legends belong in the Inspector. A world-space
	# label can cover an entire room at close range and also changes the exposure.
	if not bool(preview_snapshot.get("streamed", false)) or volume_preview:
		if label != null:
			root.remove_child(label)
			label.queue_free()
		return
	if label == null:
		label = Label3D.new()
		label.name = "_StreamStatus"
		label.font_size = 32
		label.pixel_size = 0.01
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		label.modulate = Color(0.7, 1.0, 0.8, 1.0)
		label.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		label.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(label)
	label.no_depth_test = true
	var status: Dictionary = preview_snapshot.get("streaming_status", {})
	label.text = "Magic GI pages: %d / %d  ·  loading %d" % [
		int(status.get("resident_pages", 0)), int(preview_snapshot.get("total_pages", 0)),
		int(status.get("loading_pages", 0))]
	label.position = Vector3(0.0, volume.size.y * 0.5, 0.0)

static func _sh_mesh(data: FMagicGIData, probe_index: int, radius: float,
		local_to_world: Basis, world_basis: Basis = Basis.IDENTITY) -> ArrayMesh:
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
			verts.append(world_basis * dir * (radius * (0.25 + 0.75 * magnitude)))
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

## The free-space backend publishes live SH independently of the old surface
## FMagicGIData resources. These positions are the actual resident source/CLV
## samples in world space, including each cascade's cell size.
static func _build_volume_preview(volume: FMagicGIVolume, root: Node3D,
		preview_snapshot: Dictionary) -> void:
	root.set_meta("volume_preview_layout_key", String(preview_snapshot.get("layout_key", "")))
	var positions: PackedVector3Array = preview_snapshot.get("positions", PackedVector3Array())
	root.set_meta("volume_preview_count", positions.size())
	if volume.show_probes and not positions.is_empty():
		var sphere := SphereMesh.new()
		sphere.radius = 1.0
		sphere.height = 2.0
		sphere.radial_segments = 8
		sphere.rings = 4
		var material := _new_preview_material(preview_snapshot)
		_track_preview_material(root, material)
		sphere.material = material
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = sphere
		mm.instance_count = positions.size()
		for index in positions.size():
			var radius := _volume_probe_spacing(preview_snapshot, index, volume.probe_spacing) * PROBE_GIZMO_CELL_RATIO
			mm.set_instance_transform(index, Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * radius), positions[index]))
		var node := MultiMeshInstance3D.new()
		node.name = "_Probes"
		node.top_level = true
		node.multimesh = mm
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		root.add_child(node)
		_update_volume_probe_colors(mm, preview_snapshot)
	if volume.show_sh_probes and _volume_sh_available(preview_snapshot):
		_build_volume_sh(volume, root, preview_snapshot)
	if bool(preview_snapshot.get("display_by_clv", false)) and (volume.show_probes or volume.show_sh_probes):
		_build_clv_bounds(root, preview_snapshot)

static func _volume_probe_spacing(preview_snapshot: Dictionary, index: int, fallback: float) -> float:
	var spacings: PackedFloat32Array = preview_snapshot.get("spacings", PackedFloat32Array())
	return maxf(spacings[index], 0.001) if index < spacings.size() else maxf(fallback, 0.001)

static func _volume_sh_available(preview_snapshot: Dictionary) -> bool:
	var positions: PackedVector3Array = preview_snapshot.get("positions", PackedVector3Array())
	var response_sh: PackedFloat32Array = preview_snapshot.get("response_sh", PackedFloat32Array())
	return bool(preview_snapshot.get("current_available", false)) and not positions.is_empty() \
			and response_sh.size() == positions.size() * 27

static func _update_volume_probe_colors(mm: MultiMesh, preview_snapshot: Dictionary) -> void:
	var available := _volume_sh_available(preview_snapshot)
	var response_sh: PackedFloat32Array = preview_snapshot.get("response_sh", PackedFloat32Array())
	var strength := float(preview_snapshot.get("strength", 1.0))
	for index in mm.instance_count:
		var color := UNAVAILABLE_COLOR
		var compensate := true
		if available:
			var offset := index * 27
			var mean := Vector3(response_sh[offset], response_sh[offset + 1], response_sh[offset + 2]) * (0.2820947918 * strength)
			if mean.is_finite():
				mean = mean.max(Vector3.ZERO)
				color = ZERO_RESPONSE_COLOR if mean.length_squared() < 1e-16 else Color(mean.x, mean.y, mean.z)
				compensate = mean.length_squared() < 1e-16
		mm.set_instance_color(index, color)
		mm.set_instance_custom_data(index, Color(1.0 if compensate else 0.0, 0.0, 0.0, 1.0))

static func _build_volume_sh(volume: FMagicGIVolume, root: Node3D,
		preview_snapshot: Dictionary) -> void:
	var positions: PackedVector3Array = preview_snapshot.get("positions", PackedVector3Array())
	var count := mini(positions.size(), MAX_SH_VIZ_PROBES)
	if count <= 0:
		return
	var indices := PackedInt32Array()
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = SH_VIZ_SIDES * 2
	sphere.rings = SH_VIZ_SIDES
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = sphere
	mm.instance_count = count
	for row in count:
		# Cover the whole resident set rather than taking only the first page.
		var index := mini(int(floor(float(row) * positions.size() / count)), positions.size() - 1)
		indices.append(index)
		var radius := _volume_probe_spacing(preview_snapshot, index, volume.probe_spacing) * 0.38
		mm.set_instance_transform(row, Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * radius), positions[index]))
		mm.set_instance_custom_data(row, Color(0.0, float(row), 0.0, 1.0))
	var material := ShaderMaterial.new()
	material.shader = VolumeSHPreviewShader
	_track_preview_material(root, material)
	_set_preview_view_parameters(material, preview_snapshot.get("editor_views", []))
	var node := MultiMeshInstance3D.new()
	node.name = "_Transport"
	node.top_level = true
	node.multimesh = mm
	node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	node.set_meta("volume_preview_indices", indices)
	root.add_child(node)
	_update_volume_sh_texture(node, preview_snapshot)

static func _update_volume_sh_texture(node: MultiMeshInstance3D, preview_snapshot: Dictionary) -> void:
	var indices: PackedInt32Array = node.get_meta("volume_preview_indices", PackedInt32Array())
	if indices.is_empty():
		return
	var response_sh: PackedFloat32Array = preview_snapshot.get("response_sh", PackedFloat32Array())
	var packed := PackedFloat32Array()
	packed.resize(indices.size() * 27)
	for row in indices.size():
		var source := indices[row] * 27
		if source + 27 > response_sh.size():
			return
		for coefficient in 27:
			packed[row * 27 + coefficient] = response_sh[source + coefficient]
	var image := Image.create_from_data(9, indices.size(), false, Image.FORMAT_RGBF, packed.to_byte_array())
	var texture: ImageTexture = node.get_meta("volume_preview_texture") if node.has_meta("volume_preview_texture") else null
	if texture == null:
		texture = ImageTexture.create_from_image(image)
		node.set_meta("volume_preview_texture", texture)
	else:
		texture.update(image)
	var material := node.material_override as ShaderMaterial
	material.set_shader_parameter("response_sh", texture)
	material.set_shader_parameter("response_strength", float(preview_snapshot.get("strength", 1.0)))
	_set_preview_view_parameters(material, preview_snapshot.get("editor_views", []))
	node.set_meta("volume_preview_revision", int(preview_snapshot.get("revision", 0)))

static func _update_volume_preview(volume: FMagicGIVolume, root: Node3D,
		preview_snapshot: Dictionary) -> void:
	var positions: PackedVector3Array = preview_snapshot.get("positions", PackedVector3Array())
	if not bool(root.get_meta("volume_probe_preview", false)) \
			or String(root.get_meta("volume_preview_layout_key", "")) != String(preview_snapshot.get("layout_key", "")) \
			or int(root.get_meta("volume_preview_count", -1)) != positions.size():
		rebuild(volume, root, preview_snapshot)
		return
	_update_stream_status(volume, root, preview_snapshot)
	var probes := root.get_node_or_null("_Probes") as MultiMeshInstance3D
	if volume.show_probes and probes != null:
		_update_volume_probe_colors(probes.multimesh, preview_snapshot)
	var sh := root.get_node_or_null("_Transport") as MultiMeshInstance3D
	if not volume.show_sh_probes or not _volume_sh_available(preview_snapshot):
		if sh != null:
			root.remove_child(sh)
			sh.queue_free()
		return
	if sh == null:
		_build_volume_sh(volume, root, preview_snapshot)
	elif int(sh.get_meta("volume_preview_revision", -1)) != int(preview_snapshot.get("revision", 0)):
		_update_volume_sh_texture(sh, preview_snapshot)

static func _build_clv_bounds(root: Node3D, preview_snapshot: Dictionary) -> void:
	var colors := [Color(0.15, 0.85, 1.0), Color(0.25, 1.0, 0.4), Color(1.0, 0.68, 0.1), Color(1.0, 0.3, 0.75),
		Color(0.65, 0.4, 1.0), Color(0.25, 0.5, 1.0), Color(1.0, 0.25, 0.2),
		Color(0.75, 1.0, 0.2), Color(1.0, 0.95, 0.8), Color(1.0, 0.6, 0.4)]
	var selected := int(preview_snapshot.get("selected_clv_level", -1))
	for level: Dictionary in preview_snapshot.get("clv_levels", []):
		var lod := int(level.get("lod", 0))
		if selected >= 0 and lod != selected:
			continue
		var bounds: AABB = level.get("bounds", level.get("clip_bounds_world", AABB()))
		if not bounds.has_volume():
			continue
		var vertices := PackedVector3Array()
		for edge in [0, 1, 1, 3, 3, 2, 2, 0, 4, 5, 5, 7, 7, 6, 6, 4, 0, 4, 1, 5, 2, 6, 3, 7]:
			vertices.append(bounds.get_endpoint(edge))
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
		var material := ShaderMaterial.new()
		material.shader = OverlayShader
		material.set_shader_parameter("overlay_color", colors[clampi(lod, 0, 9)])
		_set_preview_view_parameters(material, preview_snapshot.get("editor_views", []))
		var node := MeshInstance3D.new()
		node.name = "_CLVLevel%d" % lod
		node.top_level = true
		node.mesh = mesh
		node.material_override = material
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		root.add_child(node)
