@tool
extends RefCounted
## Packs the declared local-medium value snapshots into a fixed GPU ABI.

const MAX_VOLUMES := 16
const RECORD_FLOATS := 32 # Eight vec4s per volume.
const BUFFER_BYTES := 16 + MAX_VOLUMES * RECORD_FLOATS * 4
const SHAPE_BOX := 0
const SHAPE_ELLIPSOID := 1
const SHAPE_CYLINDER := 2
const SHAPE_CONE := 3
const SHAPE_WORLD := 4


static func pack(values: Variant) -> Dictionary:
	var batches: Array[Dictionary] = []
	var records := PackedFloat32Array()
	var textures: Array[RID] = []
	var batch_entry_count := 0
	var batch_index := 0
	var signature: Array = []
	var accepted := 0
	if values is Array:
		for value in values:
			if not value is Dictionary or not bool(value.get("enabled", false)):
				continue
			var transform: Variant = value.get("transform", Transform3D.IDENTITY)
			var size: Variant = value.get("size_m", Vector3.ONE)
			if not transform is Transform3D or not transform.is_finite() \
					or not size is Vector3 or not size.is_finite():
				continue
			var basis: Basis = transform.basis
			if absf(basis.determinant()) <= 1.0e-8:
				continue
			var inverse: Transform3D = transform.affine_inverse()
			var extents: Vector3 = size.abs() * 0.5
			if minf(extents.x, minf(extents.y, extents.z)) <= 1.0e-5:
				continue
			var density := _finite(value.get("density_per_m", 0.0), 0.0, 10000.0)
			var height_falloff := _finite(value.get("height_falloff_per_m", 0.0), 0.0, 1000.0)
			var edge_fade := _finite(value.get("edge_fade_m", 0.0), 0.0, 10000.0)
			var extinction_scale := _finite(value.get("extinction_scale", 1.0), 0.0, 10000.0)
			var raw_albedo: Vector3 = _vector3(value.get("albedo", Vector3.ONE), Vector3.ONE)
			var albedo := raw_albedo.clamp(Vector3.ZERO, Vector3.ONE)
			var emissive: Vector3 = _vector3(value.get("emissive_per_m", Vector3.ZERO), Vector3.ZERO).clamp(
				Vector3.ZERO, Vector3(65504.0, 65504.0, 65504.0))
			var shape := clampi(int(value.get("shape", SHAPE_BOX)), SHAPE_BOX, SHAPE_WORLD)
			var texture := value.get("density_texture") as Texture3D
			var texture_rid := RenderingServer.texture_get_rd_texture(texture.get_rid()) \
					if texture != null and texture.get_rid().is_valid() else RID()
			var noise_index := batch_entry_count if texture_rid.is_valid() else -1
			_append_vec4(records, inverse.basis.x, 0.0)
			_append_vec4(records, inverse.basis.y, 0.0)
			_append_vec4(records, inverse.basis.z, 0.0)
			_append_vec4(records, inverse.origin, 1.0)
			records.append_array(PackedFloat32Array([density, height_falloff, edge_fade, float(shape)]))
			records.append_array(PackedFloat32Array([extents.x, extents.y, extents.z, float(noise_index)]))
			records.append_array(PackedFloat32Array([albedo.x, albedo.y, albedo.z, extinction_scale]))
			records.append_array(PackedFloat32Array([emissive.x, emissive.y, emissive.z, 0.0]))
			textures.append(texture_rid)
			signature.append([
				int(value.get("volume_id", 0)), shape, transform, extents, density,
				height_falloff, edge_fade, albedo, emissive, extinction_scale,
				texture.get_instance_id() if texture != null else 0,
			])
			accepted += 1
			batch_entry_count += 1
			if batch_entry_count == MAX_VOLUMES:
				batches.append(_finish_batch(records, textures, batch_entry_count, batch_index))
				batch_index += 1
				batch_entry_count = 0
				records = PackedFloat32Array()
				textures = []
	if batch_entry_count > 0:
		batches.append(_finish_batch(records, textures, batch_entry_count, batch_index))
	if batches.is_empty():
		# Batch zero also writes the global height medium and emissive base.
		# Keep this valid no-media batch so local and global media share one path.
		batches.append(_finish_batch(PackedFloat32Array(), [], 0, 0))
	var first_batch: Dictionary = batches[0]
	return {
		"count": accepted,
		"batch_count": batches.size(),
		"batches": batches,
		"bytes": first_batch.bytes,
		"textures": first_batch.textures,
		"signature": signature,
		"overflow_count": 0,
	}


static func _finish_batch(records: PackedFloat32Array, textures: Array[RID],
		entry_count: int, batch_index: int) -> Dictionary:
	while records.size() < MAX_VOLUMES * RECORD_FLOATS:
		records.append(0.0)
	var data := PackedInt32Array([entry_count, batch_index, 0, 0]).to_byte_array()
	data.append_array(records.to_byte_array())
	while textures.size() < MAX_VOLUMES:
		textures.append(RID())
	return {
		"index": batch_index,
		"count": entry_count,
		"bytes": data,
		"textures": textures,
	}


static func _append_vec4(values: PackedFloat32Array, vector: Vector3, w: float) -> void:
	values.append_array(PackedFloat32Array([vector.x, vector.y, vector.z, w]))


static func _vector3(value: Variant, fallback: Vector3) -> Vector3:
	return value if value is Vector3 and value.is_finite() else fallback


static func _finite(value: Variant, minimum: float, maximum: float) -> float:
	if not (value is float or value is int) or not is_finite(float(value)):
		return minimum
	return clampf(float(value), minimum, maximum)
