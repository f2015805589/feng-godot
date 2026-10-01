@tool
extends RefCounted
## Pure, renderer-independent atmosphere parameter contract. Author controls are
## converted once by the component; every consumer receives these finite units.

const DEFAULT_RAYLEIGH_PER_KM := Vector3(0.005802, 0.013558, 0.0331)
const DEFAULT_PLANET_CENTER_M := Vector3(0.0, -6360000.0, 0.0)
const MAX_SCATTER_COEFFICIENT_PER_KM := 100.0
const DEFAULT_ABSORPTION_PER_KM := Vector3(0.000650, 0.001881, 0.000085)


static func finite_float(value: Variant, fallback: float) -> float:
	if not value is float and not value is int:
		return fallback
	var number := float(value)
	return number if is_finite(number) else fallback


static func finite_vector(value: Variant, fallback: Vector3) -> Vector3:
	var vector := fallback
	if value is Vector3:
		vector = value
	elif value is Color:
		vector = Vector3(value.r, value.g, value.b)
	return vector if vector.is_finite() else fallback


static func coefficient(value: Variant, fallback: Vector3) -> Vector3:
	return finite_vector(value, fallback).clamp(Vector3.ZERO, Vector3.ONE * MAX_SCATTER_COEFFICIENT_PER_KM)


static func sanitize_atmosphere_settings(settings: Dictionary) -> Dictionary:
	# Legacy dictionary inputs remain supported. Normalized RGB values take
	# precedence so absorbing/scattering colors cannot be collapsed to grey.
	var legacy_scatter := clampf(finite_float(settings.get("mie_scattering_per_km", 0.003996), 0.003996), 0.0, MAX_SCATTER_COEFFICIENT_PER_KM)
	var legacy_extinction := clampf(finite_float(settings.get("mie_extinction_per_km", 0.004440), 0.004440), legacy_scatter, MAX_SCATTER_COEFFICIENT_PER_KM)
	var mie_scatter := coefficient(settings.get("mie_scattering_coefficients", Vector3.ONE * legacy_scatter), Vector3.ONE * 0.003996)
	var mie_extinction := coefficient(settings.get("mie_extinction_coefficients", Vector3.ONE * legacy_extinction), Vector3.ONE * 0.004440).max(mie_scatter)
	return {
		"planet_radius_km": clampf(finite_float(settings.get("planet_radius_km", 6360.0), 6360.0), 1.0, 100000.0),
		"atmosphere_height_km": clampf(finite_float(settings.get("atmosphere_height_km", 60.0), 60.0), 0.1, 10000.0),
		"rayleigh_scale_height_km": clampf(finite_float(settings.get("rayleigh_scale_height_km", 8.0), 8.0), 0.001, 1000.0),
		"mie_scale_height_km": clampf(finite_float(settings.get("mie_scale_height_km", 1.2), 1.2), 0.001, 1000.0),
		"rayleigh_scattering_per_km": coefficient(settings.get("rayleigh_scattering_per_km", DEFAULT_RAYLEIGH_PER_KM), DEFAULT_RAYLEIGH_PER_KM),
		"mie_scattering_per_km": mie_scatter.x,
		"mie_extinction_per_km": mie_extinction.x,
		"mie_scattering_coefficients": mie_scatter,
		"mie_extinction_coefficients": mie_extinction,
		"mie_asymmetry": clampf(finite_float(settings.get("mie_asymmetry", 0.8), 0.8), 0.0, 0.999),
		"absorption_extinction_per_km": coefficient(settings.get("absorption_extinction_per_km", DEFAULT_ABSORPTION_PER_KM), DEFAULT_ABSORPTION_PER_KM),
		"absorption_density_layer_width_km": clampf(finite_float(settings.get("absorption_density_layer_width_km", 25.0), 25.0), 0.0, 10000.0),
		"absorption_layer0_linear_term": clampf(finite_float(settings.get("absorption_layer0_linear_term", 1.0 / 15.0), 1.0 / 15.0), -1000.0, 1000.0),
		"absorption_layer0_constant_term": clampf(finite_float(settings.get("absorption_layer0_constant_term", 1.0 - 25.0 * (1.0 / 15.0)), 1.0 - 25.0 * (1.0 / 15.0)), -1000000.0, 1000000.0),
		"absorption_layer1_linear_term": clampf(finite_float(settings.get("absorption_layer1_linear_term", -1.0 / 15.0), -1.0 / 15.0), -1000.0, 1000.0),
		"absorption_layer1_constant_term": clampf(finite_float(settings.get("absorption_layer1_constant_term", 1.0 + 25.0 * (1.0 / 15.0)), 1.0 + 25.0 * (1.0 / 15.0)), -1000000.0, 1000000.0),
		"planet_center_m": finite_vector(settings.get("planet_center_m", DEFAULT_PLANET_CENTER_M), DEFAULT_PLANET_CENTER_M),
		"ground_albedo": finite_vector(settings.get("ground_albedo", Vector3.ONE * 0.4), Vector3.ONE * 0.4).clamp(Vector3.ZERO, Vector3.ONE),
		"sun_angular_radius_deg": clampf(finite_float(settings.get("sun_angular_radius_deg", 0.26785), 0.26785), 0.0, 2.5),
		"multi_scattering_factor": clampf(finite_float(settings.get("multi_scattering_factor", 1.0), 1.0), 0.0, 100.0),
		"sky_luminance_factor": finite_vector(settings.get("sky_luminance_factor", Vector3.ONE), Vector3.ONE).clamp(Vector3.ZERO, Vector3.ONE * 100.0),
		"sky_only_luminance_factor": finite_vector(settings.get("sky_only_luminance_factor", Vector3.ONE), Vector3.ONE).clamp(Vector3.ZERO, Vector3.ONE * 100.0),
		"minimum_light_elevation_deg": clampf(finite_float(settings.get("minimum_light_elevation_deg", -90.0), -90.0), -90.0, 90.0),
		"trace_sample_count_scale": clampf(finite_float(settings.get("trace_sample_count_scale", 1.0), 1.0), 0.25, 8.0),
		"aerial_perspective_view_distance_scale": clampf(finite_float(settings.get("aerial_perspective_view_distance_scale", 1.0), 1.0), 0.0, 100.0),
		"aerial_perspective_start_depth_km": clampf(finite_float(settings.get("aerial_perspective_start_depth_km", 0.1), 0.1), 0.001, 10000.0),
	}
