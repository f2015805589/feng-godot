@tool
extends RefCounted
## Builds the live emissive atlas for an immutable page away from the main loop.

var data: Resource
var source_values := PackedFloat32Array()
var payload := PackedFloat32Array()
var image: Image
var valid := false

func configure(page_data: Resource, values: PackedFloat32Array) -> void:
	data = page_data
	source_values = values

func run() -> void:
	valid = false
	if data == null or not is_instance_valid(data) or not data.has_method("compose_emission"):
		return
	var result: PackedFloat32Array = data.call("compose_emission", source_values)
	var packed_image: Image = data.call("make_emission_atlas_image", result)
	if packed_image == null or packed_image.is_empty():
		return
	payload = result
	image = packed_image
	valid = true
