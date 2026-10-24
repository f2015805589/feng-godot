@tool
class_name FengLightmapData
extends Resource
## Saved result of the independent surface Monte Carlo lightmap baker.

@export var atlas_resolution: int = 0
@export var samples_per_texel: int = 0
@export var seed: int = 0
@export var surface_model: String = "piecewise-flat Lambertian diffuse"
@export var physical_light_units_enabled: bool = false
@export var backend_contract_version: int = 0
## Hash of actual collected geometry/material/light inputs. Empty legacy data
## cannot certify that current emission and lighting match the saved solution.
@export_storage var scene_transport_signature: String = ""
@export var environment_override: String = ""
@export var excluded_lights: PackedStringArray = PackedStringArray()
## Paths are relative to the FengLightmapVolume that owns this resource.
@export var mesh_relative_paths: Array[NodePath] = []
## Linear RGBAF atlas layers, persisted as CPU data so headless bakes are reloadable.
@export var radiance_layers: Array[PackedFloat32Array] = []
@export var sampled_mesh_count: int = 0 # Receiver meshes only; each has one output atlas layer.
@export var sampled_triangle_count: int = 0 # All traced receiver and transport-only triangles.
@export var receiver_triangle_count: int = 0
@export var transport_only_mesh_count: int = 0
@export var transport_only_triangle_count: int = 0
@export var transport_only_reasons: PackedStringArray = PackedStringArray()
@export var receiver_bounds_local: AABB = AABB()
@export var receiver_boundary_rule: String = ""
@export var skipped_zero_area_triangle_count: int = 0
@export var emitter_triangle_count: int = 0
@export var directional_light_count: int = 0
@export var area_light_count: int = 0
@export var bake_worker_count: int = 0
@export var covered_texel_count: int = 0
@export var path_count: int = 0
@export var average_path_bounces: float = 0.0
@export var rr_survivals: int = 0
@export var luminance_variance_layers: Array[PackedFloat32Array] = []
## Versioned display-only chart certificates. Empty means legacy/unknown, never
## single-chart. A certificate is used only if the current mesh input hash agrees.
@export_storage var display_chart_proofs: Array[Dictionary] = []
const DISPLAY_CHART_PROOF_VERSION := 1
## Display reconstruction only: copy nearest covered neighbors into empty gutter
## texels. This is biased texture reconstruction, not the unbiased raw estimator.
## Raw radiance/variance remain untouched. Zero displays the unmodified reference.
@export_range(0, 4, 1) var display_gutter_pixels: int = 1:
	set(value):
		if display_gutter_pixels == value:
			return
		display_gutter_pixels = clampi(value,0,4)
		invalidate_runtime_cache()


var _runtime_texture: Texture2DArray
var _single_chart_cache: Dictionary = {}


func invalidate_runtime_cache() -> void:
	_runtime_texture = null
	_single_chart_cache.clear()
	emit_changed()


func _display_rgba(raw: PackedFloat32Array, single_connected_chart: bool = false) -> PackedFloat32Array:
	if display_gutter_pixels == 0:
		return raw
	var result := raw.duplicate()
	var radius := display_gutter_pixels
	for y in atlas_resolution:
		for x in atlas_resolution:
			var pixel := (y * atlas_resolution + x) * 4
			if raw[pixel+3] > 0.0:
				continue
			var best_distance := 2147483647
			var source := -1
			var ambiguous := false
			for oy in range(-radius,radius+1):
				for ox in range(-radius,radius+1):
					var nx := x+ox
					var ny := y+oy
					if nx < 0 or ny < 0 or nx >= atlas_resolution or ny >= atlas_resolution:
						continue
					var candidate := (ny * atlas_resolution + nx) * 4
					# Read original coverage only; filled gutter pixels never seed
					# further propagation or alter covered samples.
					if raw[candidate+3] <= 0.0:
						continue
					var distance := ox*ox+oy*oy
					if distance < best_distance:
						best_distance = distance
						source = candidate
						ambiguous = false
					elif distance == best_distance:
						if raw[candidate] != raw[source] or raw[candidate+1] != raw[source+1] or raw[candidate+2] != raw[source+2]:
							ambiguous = true
			# An equal-distance tie inside a proven single UV chart may use the
			# deterministic first nearest sample. Leaving it black creates periodic
			# coverage holes on curved chart edges (notably SphereMesh's meridian).
			# Multi-chart or unknown topology retains the strict ambiguity guard.
			if source >= 0 and (not ambiguous or single_connected_chart):
				for channel in 4:
					result[pixel+channel] = raw[source+channel]
	return result


func _mesh_chart_signature(mesh: Mesh) -> String:
	if mesh == null:
		return ""
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(var_to_bytes([DISPLAY_CHART_PROOF_VERSION,mesh.get_surface_count()]))
	for surface in mesh.get_surface_count():
		var primitive: int = mesh.surface_get_primitive_type(surface) if mesh is ArrayMesh else Mesh.PRIMITIVE_TRIANGLES
		var arrays := mesh.surface_get_arrays(surface)
		if not arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array or not arrays[Mesh.ARRAY_TEX_UV2] is PackedVector2Array:
			return ""
		# Include complete packed buffers and their type/length headers. UV
		# connectivity depends on physical vertices as well as UV coordinates.
		hash.update(var_to_bytes([primitive,arrays[Mesh.ARRAY_VERTEX],arrays[Mesh.ARRAY_TEX_UV2],arrays[Mesh.ARRAY_INDEX]]))
	return hash.finish().hex_encode()


func create_display_chart_proof(mesh: Mesh) -> Dictionary:
	var signature := _mesh_chart_signature(mesh)
	if signature.is_empty():
		return {}
	# This is called before a new bake on its main-thread input snapshot. Clear
	# an older in-memory answer in case an editor modified this Mesh in place.
	_single_chart_cache.erase(mesh.get_instance_id())
	return {"version":DISPLAY_CHART_PROOF_VERSION,"mesh_signature":signature,
		"single_connected_chart":_mesh_has_single_uv_chart(mesh)}


func _display_chart_single_for_layer(mesh: Mesh, layer: int) -> bool:
	if mesh == null:
		return false
	if layer >= 0 and layer < display_chart_proofs.size():
		var proof: Dictionary = display_chart_proofs[layer]
		if typeof(proof.get("version")) == TYPE_INT and int(proof.get("version",-1)) == DISPLAY_CHART_PROOF_VERSION \
				and typeof(proof.get("single_connected_chart")) == TYPE_BOOL \
				and typeof(proof.get("mesh_signature")) == TYPE_STRING:
			var signature := _mesh_chart_signature(mesh)
			if not signature.is_empty() and signature == String(proof.mesh_signature):
				return bool(proof.single_connected_chart)
	# Legacy, malformed or stale metadata is never an implicit true. It may
	# use the existing one-time topology path, then the persistent texture cache.
	_single_chart_cache.erase(mesh.get_instance_id())
	return _mesh_has_single_uv_chart(mesh)


func _chart_root(parents: PackedInt32Array, node: int) -> int:
	while parents[node] != node:
		node = parents[node]
	return node


func _mesh_has_single_uv_chart(mesh: Mesh) -> bool:
	if mesh == null:
		return false
	var identity := mesh.get_instance_id()
	if _single_chart_cache.has(identity):
		return _single_chart_cache[identity]
	var vertices: Dictionary = {}
	var edges: Dictionary = {}
	var parents := PackedInt32Array()
	for surface in mesh.get_surface_count():
		if mesh is ArrayMesh and mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
			_single_chart_cache[identity] = false
			return false
		var arrays := mesh.surface_get_arrays(surface)
		if not arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array or not arrays[Mesh.ARRAY_TEX_UV2] is PackedVector2Array:
			_single_chart_cache[identity] = false
			return false
		var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var coordinates: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
		if positions.size() != coordinates.size():
			_single_chart_cache[identity] = false
			return false
		var vertex_ids := PackedInt32Array()
		vertex_ids.resize(positions.size())
		for vertex in positions.size():
			# UV equality alone must not join unrelated geometry whose charts
			# happen to touch. Require the same physical edge as well.
			var key := [positions[vertex], coordinates[vertex]]
			if not vertices.has(key):
				vertices[key] = vertices.size()
			vertex_ids[vertex] = vertices[key]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] is PackedInt32Array else PackedInt32Array()
		var count := positions.size() if indices.is_empty() else indices.size()
		if count % 3 != 0:
			_single_chart_cache[identity] = false
			return false
		for offset in range(0,count,3):
			var local := [offset,offset+1,offset+2] if indices.is_empty() else [indices[offset],indices[offset+1],indices[offset+2]]
			if local[0] < 0 or local[1] < 0 or local[2] < 0 or local[0] >= positions.size() or local[1] >= positions.size() or local[2] >= positions.size():
				_single_chart_cache[identity] = false
				return false
			if (positions[local[1]]-positions[local[0]]).cross(positions[local[2]]-positions[local[0]]).length_squared() == 0.0 or (coordinates[local[1]]-coordinates[local[0]]).cross(coordinates[local[2]]-coordinates[local[0]]) == 0.0:
				continue
			var triangle := parents.size()
			parents.append(triangle)
			for corner in 3:
				var a := vertex_ids[local[corner]]
				var b := vertex_ids[local[(corner+1)%3]]
				var key := Vector2i(mini(a,b),maxi(a,b))
				if edges.has(key):
					var first := _chart_root(parents,triangle)
					var second := _chart_root(parents,edges[key])
					parents[maxi(first,second)] = mini(first,second)
				else:
					edges[key] = triangle
	var single := not parents.is_empty()
	if single:
		var first := _chart_root(parents,0)
		for triangle in parents.size():
			if _chart_root(parents,triangle) != first:
				single = false
				break
	_single_chart_cache[identity] = single
	return single


func build_lightmap_gi_data(volume: Node3D, display: LightmapGI) -> LightmapGIData:
	if radiance_layers.size() != sampled_mesh_count or mesh_relative_paths.size() != sampled_mesh_count:
		push_error("FengLightmapData: atlas and mesh path counts do not match sampled_mesh_count.")
		return null
	var receivers: Array[MeshInstance3D] = []
	for path in mesh_relative_paths:
		var receiver := volume.get_node_or_null(path) as MeshInstance3D
		if receiver == null:
			push_error("FengLightmapData: mesh path %s no longer resolves from FengLightmapVolume." % path)
			return null
		receivers.append(receiver)
	if _runtime_texture == null:
		var images: Array[Image] = []
		for layer in radiance_layers.size():
			var rgba: PackedFloat32Array = radiance_layers[layer]
			if rgba.size() != atlas_resolution * atlas_resolution * 4:
				push_error("FengLightmapData: an RGBA layer has the wrong number of samples.")
				return null
			var image := Image.create_from_data(atlas_resolution, atlas_resolution, false, Image.FORMAT_RGBAF, _display_rgba(rgba, _display_chart_single_for_layer(receivers[layer].mesh,layer) if display_gutter_pixels > 0 else false).to_byte_array())
			if image.is_empty():
				push_error("FengLightmapData: could not reconstruct a linear RGBAF atlas layer.")
				return null
			images.append(image)
		var texture_array := Texture2DArray.new()
		var texture_error := texture_array.create_from_images(images)
		if texture_error != OK:
			push_error("FengLightmapData: Texture2DArray creation failed with Error %d." % texture_error)
			return null
		_runtime_texture = texture_array
	var gi_data := LightmapGIData.new()
	gi_data.set_uses_spherical_harmonics(false)
	# The lightmap instance is culled separately from its receiver meshes. A
	# texture-only atlas has no dynamic SH probes, but still needs the baked
	# receiver bounds: an empty AABB drops all lightmaps at oblique camera angles.
	var display_bounds := receiver_bounds_local
	if not display_bounds.has_volume():
		# Legacy resources may predate persisted bounds; derive once while binding.
		var to_display := display.global_transform.affine_inverse()
		for receiver in receivers:
			var receiver_bounds := (to_display * receiver.global_transform) * receiver.get_aabb()
			display_bounds = receiver_bounds if not display_bounds.has_volume() else display_bounds.merge(receiver_bounds)
	gi_data.set("probe_data", {"bounds": display_bounds, "interior": false,
		"points": PackedVector3Array(), "sh": PackedColorArray(),
		"tetrahedra": PackedInt32Array(), "bsp": PackedInt32Array(), "baked_exposure": 1.0})
	var textures: Array[TextureLayered] = [_runtime_texture]
	gi_data.set_lightmap_textures(textures)
	for mesh_index in sampled_mesh_count:
		gi_data.add_user(display.get_path_to(receivers[mesh_index]), Rect2(0.0, 0.0, 1.0, 1.0), mesh_index, -1)
	return gi_data
