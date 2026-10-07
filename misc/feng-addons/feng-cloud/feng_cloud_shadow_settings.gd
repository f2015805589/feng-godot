@tool
class_name FengCloudShadowSettings
extends Resource
## Per-sun cloud-shadow map settings. Distances are in kilometres.

var _revision := 1

@export_range(1.0, 10000.0, 1.0, "or_greater", "suffix:km") var extent_km := 150.0:
	set(value):
		extent_km = maxf(_finite(value, 150.0), 1.0)
		_touch()
@export_range(0.25, 8.0, 0.01, "or_greater") var resolution_scale := 1.0:
	set(value):
		resolution_scale = clampf(_finite(value, 1.0), 0.25, 8.0)
		_touch()
@export_range(0.25, 8.0, 0.01, "or_greater") var ray_sample_count_scale := 1.0:
	set(value):
		ray_sample_count_scale = clampf(_finite(value, 1.0), 0.25, 8.0)
		_touch()
@export_range(0.0, 1.0, 0.001) var producer_strength := 1.0:
	set(value):
		producer_strength = clampf(_finite(value, 1.0), 0.0, 1.0)
		_touch()
@export_range(0.0, 1.0, 0.001) var surface_strength := 1.0:
	set(value):
		surface_strength = clampf(_finite(value, 1.0), 0.0, 1.0)
		_touch()
@export_range(0.0, 1.0, 0.001) var atmosphere_strength := 1.0:
	set(value):
		atmosphere_strength = clampf(_finite(value, 1.0), 0.0, 1.0)
		_touch()
@export_range(-10.0, 10.0, 0.001, "or_greater", "or_less", "suffix:km") var depth_bias_km := 0.0:
	set(value):
		depth_bias_km = _finite(value, 0.0)
		_touch()
@export_range(0.0, 1000.0, 0.1, "or_greater", "suffix:km") var snap_length_km := 20.0:
	set(value):
		snap_length_km = maxf(_finite(value, 20.0), 0.0)
		_touch()
@export_range(0, 4, 1) var spatial_filtering := 1:
	set(value):
		spatial_filtering = clampi(value, 0, 4)
		_touch()
@export var snap_to_pixel_grid := true:
	set(value):
		snap_to_pixel_grid = value
		_touch()
@export_range(1.0, 4.0, 0.01) var horizon_sample_multiplier := 2.0:
	set(value):
		horizon_sample_multiplier = clampf(_finite(value, 2.0), 1.0, 4.0)
		_touch()


static func create_default() -> FengCloudShadowSettings:
	return FengCloudShadowSettings.new()


func get_revision() -> int:
	return _revision


func rendering_snapshot() -> Dictionary:
	return {
		"extent_km": extent_km,
		"resolution": mini(int(round(512.0 * resolution_scale)), 2048),
		"sample_count": clampf(16.0 * ray_sample_count_scale, 4.0, 128.0),
		"producer_strength": producer_strength,
		"surface_strength": surface_strength,
		"atmosphere_strength": atmosphere_strength,
		"depth_bias_km": depth_bias_km,
		"snap_length_km": snap_length_km,
		"spatial_filtering": spatial_filtering,
		"snap_to_pixel_grid": snap_to_pixel_grid,
		"horizon_sample_multiplier": horizon_sample_multiplier,
	}


func _touch() -> void:
	_revision = 1 if _revision >= 2147483646 else _revision + 1
	emit_changed()


static func _finite(value: float, fallback: float) -> float:
	return value if is_finite(value) else fallback
