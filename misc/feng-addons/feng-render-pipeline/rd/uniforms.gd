@tool
extends RefCounted


static func uniform_buffer(binding: int, buffer: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	uniform.binding = binding
	uniform.add_id(buffer)
	return uniform


static func storage_buffer(binding: int, buffer: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = binding
	uniform.add_id(buffer)
	return uniform


static func sampled(binding: int, sampler: RID, texture: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform.binding = binding
	uniform.add_id(sampler)
	uniform.add_id(texture)
	return uniform


static func image(binding: int, texture: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = binding
	uniform.add_id(texture)
	return uniform


## std430 packing: a Projection is four vec4 columns, a Transform3D is three
## basis vec4s plus an origin vec4, in the order UBO blocks declare them.
static func append_projection(values: PackedFloat32Array, projection: Projection) -> void:
	for column in 4:
		var axis: Vector4 = projection[column]
		values.append_array(PackedFloat32Array([axis.x, axis.y, axis.z, axis.w]))


static func append_transform(values: PackedFloat32Array, transform: Transform3D) -> void:
	for axis in [transform.basis.x, transform.basis.y, transform.basis.z]:
		values.append_array(PackedFloat32Array([axis.x, axis.y, axis.z, 0.0]))
	values.append_array(PackedFloat32Array([
		transform.origin.x, transform.origin.y, transform.origin.z, 1.0,
	]))


## Byte form of the same std430 blocks, for callers that build a packet
## directly as PackedByteArray.
static func projection_bytes(projection: Projection) -> PackedByteArray:
	var values := PackedFloat32Array()
	append_projection(values, projection)
	return values.to_byte_array()


static func transform_bytes(transform: Transform3D) -> PackedByteArray:
	var values := PackedFloat32Array()
	append_transform(values, transform)
	return values.to_byte_array()
