@tool
extends "feng_magic_gi_volume_source_chunk.gd"
## Transient bounded worker input for an independently traced multiresolution
## brick. Never serialized as a v1/v2 source page; only prepared bricks persist.
func _storage_version_is_valid() -> bool:
	return format_version == 3

func _spacing_is_valid() -> bool:
	if not is_finite(spacing_m): return false
	for level in 10:
		if spacing_m == 0.25 * float(1 << level): return true
	return false
