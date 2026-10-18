@tool
class_name FMagicGISurfelSettings
extends Resource
## Bounded runtime controls for the Surfel MagicGI volume mode.

const MIN_SURFELS := 1024
const MAX_SURFELS := 262144
const MIN_UPDATES_PER_FRAME := 64
const MAX_UPDATES_PER_FRAME := 16384

@export_range(0.001, 8.0, 0.001, "or_greater", "suffix:m") var surfel_radius := 0.15:
	set(value):
		var next_value := clampf(value if is_finite(value) else 0.15, 0.001, 64.0)
		if surfel_radius == next_value:
			return
		surfel_radius = next_value
		emit_changed()

@export_range(MIN_SURFELS, MAX_SURFELS, 1024) var max_surfels := 65536:
	set(value):
		var next_value := clampi(value, MIN_SURFELS, MAX_SURFELS)
		if max_surfels == next_value:
			return
		max_surfels = next_value
		emit_changed()

@export_range(MIN_UPDATES_PER_FRAME, MAX_UPDATES_PER_FRAME, 64) var updates_per_frame := 2048:
	set(value):
		var next_value := clampi(value, MIN_UPDATES_PER_FRAME, MAX_UPDATES_PER_FRAME)
		if updates_per_frame == next_value:
			return
		updates_per_frame = next_value
		emit_changed()

@export_range(1, 32, 1) var rays_per_surfel := 4:
	set(value):
		var next_value := clampi(value, 1, 32)
		if rays_per_surfel == next_value:
			return
		rays_per_surfel = next_value
		emit_changed()

@export_range(0.1, 512.0, 0.1, "or_greater", "suffix:m") var max_ray_distance := 128.0:
	set(value):
		var next_value := clampf(value if is_finite(value) else 128.0, 0.1, 4096.0)
		if max_ray_distance == next_value:
			return
		max_ray_distance = next_value
		emit_changed()

@export_range(0.0, 0.99, 0.01) var history_weight := 0.9:
	set(value):
		var next_value := clampf(value if is_finite(value) else 0.9, 0.0, 0.99)
		if history_weight == next_value:
			return
		history_weight = next_value
		emit_changed()

@export_enum("NRD RELAX", "World Cache") var denoiser := 0:
	set(value):
		var next_value := clampi(value, 0, 1)
		if denoiser == next_value:
			return
		denoiser = next_value
		emit_changed()

@export var half_resolution := true:
	set(value):
		if half_resolution == value:
			return
		half_resolution = value
		emit_changed()

@export var probe_fallback_enabled := true:
	set(value):
		if probe_fallback_enabled == value:
			return
		probe_fallback_enabled = value
		emit_changed()

@export var adaptive_distribution_enabled := true:
	set(value):
		if adaptive_distribution_enabled == value:
			return
		adaptive_distribution_enabled = value
		emit_changed()

@export var ray_guiding_enabled := true:
	set(value):
		if ray_guiding_enabled == value:
			return
		ray_guiding_enabled = value
		emit_changed()

@export_range(0.25, 1.0, 0.05) var guide_cosine_floor := 0.5:
	set(value):
		var next_value := clampf(value if is_finite(value) else 0.5, 0.25, 1.0)
		if guide_cosine_floor == next_value:
			return
		guide_cosine_floor = next_value
		emit_changed()

@export_enum("Off", "Irradiance", "Coverage", "Age") var debug_view := 0:
	set(value):
		var next_value := clampi(value, 0, 3)
		if debug_view == next_value:
			return
		debug_view = next_value
		emit_changed()


func to_runtime_settings() -> Dictionary:
	return {
		"surfel_radius": surfel_radius,
		"max_surfels": max_surfels,
		"updates_per_frame": updates_per_frame,
		"rays_per_surfel": rays_per_surfel,
		"max_ray_distance": max_ray_distance,
		"history_weight": history_weight,
		"denoiser": denoiser,
		"half_resolution": half_resolution,
		"probe_fallback_enabled": probe_fallback_enabled,
		"adaptive_distribution_enabled": adaptive_distribution_enabled,
		"ray_guiding_enabled": ray_guiding_enabled,
		"guide_cosine_floor": guide_cosine_floor,
		"debug_view": debug_view,
	}
