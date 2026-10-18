@tool
extends RefCounted
## GPU morph/skin stage used by the ray tracing scene snapshot.
## The output vertex RID is shared with the BLAS build input and trace SSBO.
const U = preload("res://addons/feng-render-pipeline/rd/uniforms.gd")
const SHADER_PATH := "res://addons/feng-raytracing/shaders/gi_scene_deform.glslinc"
const VERTEX_FLOATS := 8
const VERTEX_BYTES := VERTEX_FLOATS * 4
const SKIN_WORDS_PER_VERTEX := 16
const META_WORDS_PER_SLOT := 16

var rd: RenderingDevice
var owned: Array[RID] = []
var source_vertices := RID()
var skin_data := RID()
var blend_data := RID()
var state_data := RID()
var surface_meta := RID()
var shader := RID()
var pipeline := RID()
var uniform_set := RID()
var output_vertices := RID()
var surface_offsets: Dictionary = {}
var surface_signatures: Dictionary = {}
var last_updated_slots: Array[int] = []
var error := ""

func _keep(rid: RID) -> RID:
	if rid.is_valid():
		owned.append(rid)
	return rid

func initialize(device: RenderingDevice, source_bytes: PackedByteArray, output: RID,
		scene_rows: Array, slot_count: int) -> bool:
	release()
	if device == null or not output.is_valid() or source_bytes.is_empty():
		error = "RTGI deformation input is unavailable"
		return false
	rd = device
	output_vertices = output
	var skin_bytes := PackedByteArray()
	var blend_values := PackedFloat32Array()
	var state_values := PackedFloat32Array()
	var meta_words := PackedInt32Array()
	meta_words.resize(maxi(slot_count, 1) * META_WORDS_PER_SLOT)
	for row in scene_rows:
		var deformation: Dictionary = row.get("deformation", {})
		if not bool(row.get("deforming", false)):
			continue
		var slot := int(row.get("slot", -1))
		var vertex_count := int(row.get("vertex_count", 0))
		var vertex_base := int(row.get("vertex_base_byte", 0)) / VERTEX_BYTES
		if slot < 0 or slot >= slot_count or vertex_count <= 0 or vertex_base < 0:
			error = "RTGI deformation surface range is invalid"
			release()
			return false
		var skin_base := skin_bytes.size() / 4
		var bones_per_vertex := int(deformation.get("bones_per_vertex", 4))
		var bone_indices: PackedInt32Array = deformation.get("bones", PackedInt32Array())
		var bone_weights: PackedFloat32Array = deformation.get("weights", PackedFloat32Array())
		var skinned := bool(deformation.get("skinned", false))
		if skinned and (bones_per_vertex not in [4, 8]
				or bone_indices.size() != vertex_count * bones_per_vertex
				or bone_weights.size() != bone_indices.size()):
			error = "RTGI skin attribute data is malformed"
			release()
			return false
		for vertex_index in vertex_count:
			var skin_offset := skin_bytes.size()
			skin_bytes.resize(skin_offset + SKIN_WORDS_PER_VERTEX * 4)
			for influence in 8:
				var source_index := vertex_index * bones_per_vertex + influence
				var bone_index := int(bone_indices[source_index]) \
						if skinned and influence < bones_per_vertex else 0
				if bone_index < 0:
					error = "RTGI skin bone index is negative"
					release()
					return false
				skin_bytes.encode_u32(skin_offset + influence * 4, bone_index)
			for influence in 8:
				var source_index := vertex_index * bones_per_vertex + influence
				var bone_weight := float(bone_weights[source_index]) \
						if skinned and influence < bones_per_vertex else 0.0
				if not is_finite(bone_weight) or bone_weight < 0.0:
					error = "RTGI skin weight is nonfinite or negative"
					release()
					return false
				skin_bytes.encode_float(skin_offset + (8 + influence) * 4, bone_weight)
		var blend_base := blend_values.size()
		var blend_shapes: Array = deformation.get("blend_shapes", [])
		if blend_shapes.size() != int(deformation.get("blend_shape_count", blend_shapes.size())):
			error = "RTGI blend-shape count changed after snapshot"
			release()
			return false
		for shape in blend_shapes:
			var shape_vertices: PackedVector3Array = shape.get("vertices", PackedVector3Array())
			var shape_normals: PackedVector3Array = shape.get("normals", PackedVector3Array())
			if shape_vertices.size() != vertex_count or shape_normals.size() != vertex_count:
				error = "RTGI blend-shape attributes are malformed"
				release()
				return false
			for vertex_index in vertex_count:
				var position: Vector3 = shape_vertices[vertex_index]
				var normal: Vector3 = shape_normals[vertex_index]
				if not position.is_finite() or not normal.is_finite():
					error = "RTGI blend-shape source contains nonfinite vertex data"
					release()
					return false
				blend_values.append_array(PackedFloat32Array([position.x, position.y, position.z,
					normal.x, normal.y, normal.z]))
		var state_base := state_values.size()
		var blend_weights: PackedFloat32Array = deformation.get("blend_weights", PackedFloat32Array())
		for blend_weight in blend_weights:
			if not is_finite(blend_weight):
				error = "RTGI blend-shape weight is nonfinite"
				release()
				return false
		state_values.append_array(blend_weights)
		var palette: PackedFloat32Array = deformation.get("bone_palette", PackedFloat32Array())
		if skinned and (palette.is_empty() or palette.size() % 16 != 0):
			error = "RTGI skin palette is malformed"
			release()
			return false
		for palette_value in palette:
			if not is_finite(palette_value):
				error = "RTGI skin palette contains nonfinite values"
				release()
				return false
		state_values.append_array(palette)
		var meta := slot * META_WORDS_PER_SLOT
		meta_words[meta + 0] = vertex_base
		meta_words[meta + 1] = vertex_count
		meta_words[meta + 2] = skin_base
		meta_words[meta + 3] = blend_base
		meta_words[meta + 4] = blend_shapes.size()
		meta_words[meta + 5] = state_base
		meta_words[meta + 6] = state_base + blend_weights.size()
		meta_words[meta + 7] = palette.size() / 16
		meta_words[meta + 8] = bones_per_vertex
		meta_words[meta + 9] = int(deformation.get("blend_shape_mode", Mesh.BLEND_SHAPE_MODE_RELATIVE))
		meta_words[meta + 10] = (1 if skinned else 0) | (2 if not blend_shapes.is_empty() else 0)
		meta_words[meta + 11] = state_values.size() - state_base
		surface_offsets[slot] = {"vertex_base": vertex_base, "vertex_count": vertex_count,
			"state_offset": state_base * 4, "state_size": (blend_weights.size() + palette.size()) * 4}
	var safe_skin := skin_bytes if not skin_bytes.is_empty() else PackedByteArray([0, 0, 0, 0])
	var safe_blend := blend_values.to_byte_array() if not blend_values.is_empty() else PackedByteArray([0, 0, 0, 0])
	var safe_state := state_values.to_byte_array() if not state_values.is_empty() else PackedByteArray([0, 0, 0, 0])
	var safe_meta := meta_words.to_byte_array()
	source_vertices = _keep(rd.storage_buffer_create(source_bytes.size(), source_bytes))
	skin_data = _keep(rd.storage_buffer_create(safe_skin.size(), safe_skin))
	blend_data = _keep(rd.storage_buffer_create(safe_blend.size(), safe_blend))
	state_data = _keep(rd.storage_buffer_create(safe_state.size(), safe_state))
	surface_meta = _keep(rd.storage_buffer_create(safe_meta.size(), safe_meta))
	if not source_vertices.is_valid() or not skin_data.is_valid() or not blend_data.is_valid() \
			or not state_data.is_valid() or not surface_meta.is_valid():
		error = "RTGI deformation storage allocation failed"
		release()
		return false
	var source := RDShaderSource.new()
	source.source_compute = FileAccess.get_file_as_string(SHADER_PATH)
	if source.source_compute.is_empty():
		error = "RTGI deformation shader source is missing"
		release()
		return false
	var spirv := rd.shader_compile_spirv_from_source(source)
	if not spirv.compile_error_compute.is_empty():
		error = spirv.compile_error_compute
		release()
		return false
	shader = _keep(rd.shader_create_from_spirv(spirv, "FengRTGISceneDeform"))
	if not shader.is_valid():
		error = "RTGI deformation shader creation failed"
		release()
		return false
	pipeline = _keep(rd.compute_pipeline_create(shader))
	if not pipeline.is_valid():
		error = "RTGI deformation pipeline creation failed"
		release()
		return false
	var uniforms: Array[RDUniform] = [
		U.storage_buffer(0, source_vertices), U.storage_buffer(1, output_vertices),
		U.storage_buffer(2, skin_data), U.storage_buffer(3, blend_data),
		U.storage_buffer(4, state_data), U.storage_buffer(5, surface_meta)]
	uniform_set = _keep(rd.uniform_set_create(uniforms, shader, 0))
	if not uniform_set.is_valid():
		error = "RTGI deformation uniform set creation failed"
		release()
		return false
	return true

func update_surfaces(rows: Array) -> bool:
	last_updated_slots.clear()
	if not output_vertices.is_valid() or not uniform_set.is_valid():
		return surface_offsets.is_empty()
	var updates: Array[Dictionary] = []
	var next_signatures: Dictionary = {}
	for row in rows:
		var slot := int(row.get("slot", -1))
		if not surface_offsets.has(slot):
			continue
		var deformation: Dictionary = row.get("deformation", {})
		var signature := _deformation_signature(deformation)
		if surface_signatures.has(slot) and int(surface_signatures[slot]) == signature:
			continue
		var blend_weights: PackedFloat32Array = deformation.get("blend_weights", PackedFloat32Array())
		var palette: PackedFloat32Array = deformation.get("bone_palette", PackedFloat32Array())
		var state_bytes := PackedFloat32Array()
		state_bytes.append_array(blend_weights)
		state_bytes.append_array(palette)
		var region: Dictionary = surface_offsets[slot]
		if state_bytes.size() * 4 != int(region.state_size):
			error = "RTGI deformation state layout changed without scene rebuild"
			return false
		if not state_bytes.is_empty() and rd.buffer_update(state_data, int(region.state_offset),
				state_bytes.size() * 4, state_bytes.to_byte_array()) != OK:
			error = "RTGI deformation state upload failed"
			return false
		updates.append({"slot": slot, "region": region})
		next_signatures[slot] = signature
	if updates.is_empty():
		return true
	var list := rd.compute_list_begin()
	if list < 0:
		error = "RTGI deformation compute list could not begin"
		return false
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	for update in updates:
		var region: Dictionary = update.region
		var push := PackedInt32Array([int(region.vertex_base), int(region.vertex_count),
			int(update.slot), 0]).to_byte_array()
		rd.compute_list_set_push_constant(list, push, 16)
		rd.compute_list_dispatch(list, int((int(region.vertex_count) + 63) / 64), 1, 1)
	rd.compute_list_end()
	# Dispatches write disjoint vertex ranges. Publishing their signatures only after
	# successful list submission lets a failed begin retry the same pose next frame.
	for update in updates:
		var updated_slot := int(update.slot)
		surface_signatures[updated_slot] = int(next_signatures[updated_slot])
		last_updated_slots.append(updated_slot)
	return true

func all_rids() -> Array[RID]:
	return owned.duplicate()

func release() -> void:
	if rd != null:
		var releasing := owned.duplicate()
		releasing.reverse()
		for rid in releasing:
			if rid.is_valid():
				rd.free_rid(rid)
	owned.clear()
	output_vertices = RID()
	source_vertices = RID()
	skin_data = RID()
	blend_data = RID()
	state_data = RID()
	surface_meta = RID()
	shader = RID()
	pipeline = RID()
	uniform_set = RID()
	surface_offsets.clear()
	surface_signatures.clear()
	last_updated_slots.clear()
	if rd != null:
		rd = null

func _deformation_signature(deformation: Dictionary) -> int:
	return int(hash([deformation.get("blend_weights", PackedFloat32Array()),
		deformation.get("bone_palette", PackedFloat32Array())]))
