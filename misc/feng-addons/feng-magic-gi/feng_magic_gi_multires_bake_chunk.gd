@tool
extends "feng_magic_gi_volume_source_chunk.gd"
## Transient bounded worker input for an independently traced multiresolution
## brick. Never serialized as a v1/v2 source page; only prepared bricks persist.
func _storage_version_is_valid() -> bool:
	return format_version == 3
