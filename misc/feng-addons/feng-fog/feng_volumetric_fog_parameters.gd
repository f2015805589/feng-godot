@tool
extends RefCounted
## Converts the Height Fog component's authored UE values into a safe,
## renderer-facing volumetric-fog packet. Distances use the Godot meter world.

const DEFAULT_SCATTERING_DISTRIBUTION := 0.2
const DEFAULT_EXTINCTION_SCALE := 1.0
const DEFAULT_DISTANCE_M := 60.0
const DEFAULT_STATIC_LIGHTING_SCATTERING_INTENSITY := 1.0
const DEFAULT_HISTORY_WEIGHT := 0.9
const DEFAULT_HISTORY_MISS_SUPERSAMPLE_COUNT := 0 # Zero follows the quality preset.
const QUALITY_MEDIUM := 0
const QUALITY_HIGH := 1
const QUALITY_CINEMATIC := 2
const MAX_RENDER_VALUE := 1.0e10
## UE first scales emissive by 1e-4 per centimeter. Converting its coefficient
## to a meter-based ray integral multiplies that by 100 cm/m, yielding 0.01.
const UE_EMISSIVE_PER_CM_TO_PER_M := 0.01


static func _safe_nonnegative(value: float, fallback: float) -> float:
	if not is_finite(value):
		return fallback
	return clampf(value, 0.0, MAX_RENDER_VALUE)


static func _valid_rgb(color: Color) -> bool:
	return is_finite(color.r) and is_finite(color.g) and is_finite(color.b)


static func _safe_emissive(color: Color) -> Vector3:
	if not _valid_rgb(color):
		return Vector3.ZERO
	return Vector3(
		_safe_nonnegative(color.r, 0.0),
		_safe_nonnegative(color.g, 0.0),
		_safe_nonnegative(color.b, 0.0)) * UE_EMISSIVE_PER_CM_TO_PER_M


static func _safe_albedo(color: Color) -> Vector3:
	if not _valid_rgb(color):
		color = Color.WHITE
	var srgb := Color(clampf(color.r, 0.0, 1.0),
			clampf(color.g, 0.0, 1.0), clampf(color.b, 0.0, 1.0))
	var linear := srgb.srgb_to_linear()
	return Vector3(linear.r, linear.g, linear.b)


static func pack(
		enabled: bool,
		scattering_distribution: float,
		albedo: Color,
		emissive: Color,
		extinction_scale: float,
		distance_m: float,
		start_distance_m: float,
		near_fade_in_distance_m: float,
		static_lighting_scattering_intensity: float,
		override_light_colors_with_fog_inscattering_colors: bool,
		history_weight: float = DEFAULT_HISTORY_WEIGHT,
		history_miss_supersample_count: int = DEFAULT_HISTORY_MISS_SUPERSAMPLE_COUNT,
		jitter_enabled: bool = true,
		ray_traced_shadows_enabled: bool = false,
		quality: int = QUALITY_MEDIUM,
		light_soft_fading: float = 0.0,
		area_light_source_textures_enabled: bool = false) -> Dictionary:
	var quality_settings := quality_profile(quality)
	var miss_override := normalize_history_miss_override(history_miss_supersample_count)
	var resolved_miss_count := int(quality_settings.history_miss_default) \
			if miss_override == 0 else normalize_history_miss_count(miss_override)
	return {
		"enabled": enabled,
		# UE clamps g to [-0.99, 0.99] before building the view parameters.
		"scattering_distribution": clampf(
			scattering_distribution if is_finite(scattering_distribution) else DEFAULT_SCATTERING_DISTRIBUTION,
			-0.99, 0.99),
		# Component Color values are sRGB, matching UE's FColor property.
		"albedo": _safe_albedo(albedo),
		# UE component emissive is linear and gets clamped nonnegative.
		"emissive": _safe_emissive(emissive),
		"extinction_scale": _safe_nonnegative(extinction_scale, DEFAULT_EXTINCTION_SCALE),
		# VolumetricFogDistance is the extent after StartDistance; the renderer
		# derives the far limit from their sum.
		"distance": _safe_nonnegative(distance_m, DEFAULT_DISTANCE_M),
		"start_distance": _safe_nonnegative(start_distance_m, 0.0),
		"near_fade_in_distance": _safe_nonnegative(near_fade_in_distance_m, 0.0),
		"static_lighting_scattering_intensity": _safe_nonnegative(
			static_lighting_scattering_intensity,
			DEFAULT_STATIC_LIGHTING_SCATTERING_INTENSITY),
		"override_light_colors_with_fog_inscattering_colors":
			override_light_colors_with_fog_inscattering_colors,
		"history_weight": clampf(history_weight if is_finite(history_weight)
				else DEFAULT_HISTORY_WEIGHT, 0.0, 0.99),
		"quality": int(quality_settings.quality),
		"froxel_pixel_size": int(quality_settings.froxel_pixel_size),
		"froxel_depth": int(quality_settings.froxel_depth),
		"history_miss_supersample_count": resolved_miss_count,
		"history_miss_supersample_override": miss_override > 0,
		"jitter_enabled": jitter_enabled,
		"ray_traced_shadows_enabled": ray_traced_shadows_enabled,
		# UE r.VolumetricFog.LightSoftFading defaults to zero; positive values
		# scale spot/rect edge fades by the froxel footprint.
		"light_soft_fading": _safe_nonnegative(light_soft_fading, 0.0),
		# UE r.VolumetricFog.RectLightTexture also defaults to zero.
		"area_light_source_textures_enabled": area_light_source_textures_enabled,
	}


static func normalize_history_miss_count(value: int) -> int:
	if value <= 1:
		return 1
	if value <= 4:
		return 4
	if value <= 8:
		return 8
	return 16


static func normalize_history_miss_override(value: int) -> int:
	if value <= 0:
		return 0
	return normalize_history_miss_count(value)


static func normalize_quality(value: int) -> int:
	return clampi(value, QUALITY_MEDIUM, QUALITY_CINEMATIC)


static func quality_profile(value: int) -> Dictionary:
	match normalize_quality(value):
		QUALITY_HIGH:
			return {"quality": QUALITY_HIGH, "froxel_pixel_size": 8,
				"froxel_depth": 128, "history_miss_default": 4}
		QUALITY_CINEMATIC:
			return {"quality": QUALITY_CINEMATIC, "froxel_pixel_size": 4,
				"froxel_depth": 128, "history_miss_default": 16}
		_:
			return {"quality": QUALITY_MEDIUM, "froxel_pixel_size": 16,
				"froxel_depth": 64, "history_miss_default": 4}


static func pack_screen_space_scattering(
		enabled: bool,
		scene_color_scattering_amount_scale: float,
		scene_color_scattering_amount_power: float,
		spread_scale: float,
		blur_control: float) -> Dictionary:
	return {
		"enabled": enabled,
		"scene_color_scattering_amount_scale": _safe_nonnegative(
			scene_color_scattering_amount_scale, 1.0),
		"scene_color_scattering_amount_power": _safe_nonnegative(
			scene_color_scattering_amount_power, 1.0),
		"spread_scale": _safe_nonnegative(spread_scale, 0.1),
		"blur_control": clampf(
			_safe_nonnegative(blur_control, 0.5), 0.0, 1.0),
	}
