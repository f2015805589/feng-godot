@tool
class_name FMagicGIPage
extends Resource
## One immutable streamed page. The manifest stores only this resource's path.

const Data = preload("feng_magic_gi_data.gd")

@export_storage var format_version := 1
@export_storage var generation := ""
@export_storage var page_key := ""
@export_storage var core_bounds := AABB()
@export_storage var support_bounds := AABB()
@export_storage var probe_count := 0
@export_storage var cpu_bytes := 0
@export_storage var gpu_bytes := 0
@export_storage var geometry_signature := 0
@export_storage var settings_signature := 0
@export_storage var data: Data

func is_valid(expected_generation := "", expected_key := "") -> bool:
	if format_version != 1 or generation.is_empty() or page_key.is_empty() \
			or (not expected_generation.is_empty() and generation != expected_generation) \
			or (not expected_key.is_empty() and page_key != expected_key) \
			or not _valid_bounds(core_bounds) or not _valid_bounds(support_bounds) \
			or not _contains(support_bounds, core_bounds) or data == null \
			or not data.is_valid() or data.probe_count() != probe_count:
		return false
	return cpu_bytes >= data.estimate_cpu_bytes() and gpu_bytes >= data.estimate_gpu_bytes()

static func _valid_bounds(bounds: AABB) -> bool:
	return bounds.position.is_finite() and bounds.size.is_finite() \
			and bounds.size.x > 0.0 and bounds.size.y > 0.0 and bounds.size.z > 0.0

static func _contains(outer: AABB, inner: AABB) -> bool:
	return outer.position.x <= inner.position.x and outer.position.y <= inner.position.y \
			and outer.position.z <= inner.position.z and outer.end.x >= inner.end.x \
			and outer.end.y >= inner.end.y and outer.end.z >= inner.end.z
