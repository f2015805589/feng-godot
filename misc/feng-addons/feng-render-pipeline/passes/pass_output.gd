@tool
class_name FengPassOutput
extends Resource
## Declaration for a texture owned by a Feng pass.

enum Usage {
	SAMPLED = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT,
	STORAGE = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT,
	COLOR_ATTACHMENT = RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT,
}

@export var name: StringName = &""
@export var data_format: int = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
@export_flags("Sampled", "Storage", "Color Attachment") var usage: int = Usage.SAMPLED | Usage.STORAGE | Usage.COLOR_ATTACHMENT
## Size of the texture relative to the viewport's internal size.
@export var scale: Vector2 = Vector2.ONE

func get_scaled_size(internal_size: Vector2i) -> Vector2i:
	var width := maxi(1, ceili(float(internal_size.x) * maxf(scale.x, 0.0)))
	var height := maxi(1, ceili(float(internal_size.y) * maxf(scale.y, 0.0)))
	return Vector2i(width, height)

func get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if name == &"":
		warnings.append("Output texture name cannot be empty.")
	if data_format < 0 or data_format >= RenderingDevice.DATA_FORMAT_MAX:
		warnings.append("Output texture format is invalid.")
	if scale.x <= 0.0 or scale.y <= 0.0:
		warnings.append("Output scale must be positive on both axes.")
	if usage == 0:
		warnings.append("Output texture must request at least one usage flag.")
	return warnings
