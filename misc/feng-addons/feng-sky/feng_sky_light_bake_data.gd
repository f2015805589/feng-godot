@tool
class_name FengSkyLightBakeData
extends Resource
## Persistent radiance captured for a FengSkyLight.
## RGB stores raw scene-linear radiance in world axes, without camera exposure,
## pre-exposure, or a FengSkyLight radiance-energy multiplier.

const FORMAT_VERSION := 1

@export_storage var format_version := FORMAT_VERSION
@export var radiance: Cubemap
## Capture origin in world-space metres.
@export var capture_position := Vector3.ZERO
@export var capture_resolution := 128
@export var source_description := ""

func is_valid() -> bool:
	if format_version != FORMAT_VERSION or radiance == null:
		return false
	if radiance.get_layered_type() != TextureLayered.LAYERED_TYPE_CUBEMAP:
		return false
	if radiance.get_layers() != 6:
		return false
	var width := radiance.get_width()
	return width > 0 and radiance.get_height() == width and capture_position.is_finite()
