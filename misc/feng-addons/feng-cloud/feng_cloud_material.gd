@tool
class_name FengCloudMaterial
extends Resource
## Editable density and lighting inputs for FengVolumetricCloud.
##
## This resource is a data contract for the Feng cloud renderer. Texture and
## material inputs are user-replaceable. Preserved UE source packages live under
## resources/ue58/source; validated native texture resources live under
## resources/ue58/converted.

const DEFAULT_SHAPE_DENSITY_TEXTURE_PATH := "res://addons/feng-cloud/resources/ue58/converted/VT_PerlinWorley_Balanced_UE58.res"
const DEFAULT_LAYOUT_PATTERN_TEXTURE_PATH := "res://addons/feng-cloud/resources/ue58/converted/T_CloudPattern_UE58_Runtime256.res"
const DEFAULT_LAYOUT_CLOUD_MASK_TEXTURE_PATH := "res://addons/feng-cloud/resources/ue58/converted/T_CloudMask_UE58.res"
const DEFAULT_LAYOUT_HEIGHT_PROFILE_TEXTURE_PATH := "res://addons/feng-cloud/resources/ue58/converted/T_Profile_08_UE58.res"
const DEFAULT_MATERIAL_RESOURCE_PATH := "res://addons/feng-cloud/resources/feng_cloud_default_material.tres"
const DEFAULT_UE58_KERNEL_SOURCE_PATH := "res://addons/feng-cloud/resources/ue58/material/feng_cloud_ue58_default_kernel.glslinc"
const BUILTIN_ONLY_PROPERTIES := [
	"detail_density_texture", "weather_texture", "curl_noise_texture",
	"curl_uv_scale", "curl_strength", "density_scale", "coverage",
	"detail_uv_scale", "detail_strength", "weather_uv_scale", "weather_strength",
	"conservative_density", "detail_enabled", "extinction_per_km",
	"albedo_linear", "emission_per_km",
]

static var _cached_ue58_kernel_source := ""
static var _ue58_kernel_source_last_probe_msec := -1000


static func create_default() -> FengCloudMaterial:
	var default_material: FengCloudMaterial
	var source := ResourceLoader.load(DEFAULT_MATERIAL_RESOURCE_PATH, "Resource") as FengCloudMaterial
	if source != null:
		default_material = source.duplicate() as FengCloudMaterial
		if default_material != null:
			default_material._revision = 1
			default_material._watched_textures.clear()
			for texture in [default_material.shape_density_texture, default_material.detail_density_texture,
					default_material.weather_texture, default_material.curl_noise_texture,
					default_material.layout_pattern_texture, default_material.layout_cloud_mask_texture,
					default_material.layout_height_profile_texture]:
				default_material._watch_texture(texture)
			if default_material.shape_density_texture == null or default_material.layout_pattern_texture == null \
					or default_material.layout_cloud_mask_texture == null or default_material.layout_height_profile_texture == null:
				push_error("FengCloudMaterial default resource is missing a required UE 5.8 texture input.")
			return default_material
	default_material = FengCloudMaterial.new()
	default_material.shape_density_texture = ResourceLoader.load(DEFAULT_SHAPE_DENSITY_TEXTURE_PATH, "Texture3D") as Texture3D
	default_material.layout_pattern_texture = ResourceLoader.load(DEFAULT_LAYOUT_PATTERN_TEXTURE_PATH, "Texture2D") as Texture2D
	default_material.layout_cloud_mask_texture = ResourceLoader.load(DEFAULT_LAYOUT_CLOUD_MASK_TEXTURE_PATH, "Texture2D") as Texture2D
	default_material.layout_height_profile_texture = ResourceLoader.load(DEFAULT_LAYOUT_HEIGHT_PROFILE_TEXTURE_PATH, "Texture2D") as Texture2D
	default_material.kernel_layout = "UE 5.8 Default"
	if default_material.shape_density_texture == null or default_material.layout_pattern_texture == null \
			or default_material.layout_cloud_mask_texture == null or default_material.layout_height_profile_texture == null:
		push_error("FengCloudMaterial could not load one or more UE 5.8 default texture resources.")
	return default_material

var _revision := 1
var _watched_textures: Dictionary = {} # resource instance id -> {weak: WeakRef, count: int}

@export_group("Density Sources")
@export var shape_density_texture: Texture3D:
	set(value):
		if shape_density_texture == value:
			return
		_unwatch_texture(shape_density_texture)
		shape_density_texture = value
		_watch_texture(shape_density_texture)
		_touch()
@export var detail_density_texture: Texture3D:
	set(value):
		if detail_density_texture == value:
			return
		_unwatch_texture(detail_density_texture)
		detail_density_texture = value
		_watch_texture(detail_density_texture)
		_touch()
@export var weather_texture: Texture2D:
	set(value):
		if weather_texture == value:
			return
		_unwatch_texture(weather_texture)
		weather_texture = value
		_watch_texture(weather_texture)
		_touch()
@export var curl_noise_texture: Texture3D:
	set(value):
		if curl_noise_texture == value:
			return
		_unwatch_texture(curl_noise_texture)
		curl_noise_texture = value
		_watch_texture(curl_noise_texture)
		_touch()
@export var layout_pattern_texture: Texture2D:
	set(value):
		if layout_pattern_texture == value:
			return
		_unwatch_texture(layout_pattern_texture)
		layout_pattern_texture = value
		_watch_texture(layout_pattern_texture)
		_touch()
@export var layout_cloud_mask_texture: Texture2D:
	set(value):
		if layout_cloud_mask_texture == value:
			return
		_unwatch_texture(layout_cloud_mask_texture)
		layout_cloud_mask_texture = value
		_watch_texture(layout_cloud_mask_texture)
		_touch()
@export var layout_height_profile_texture: Texture2D:
	set(value):
		if layout_height_profile_texture == value:
			return
		_unwatch_texture(layout_height_profile_texture)
		layout_height_profile_texture = value
		_watch_texture(layout_height_profile_texture)
		_touch()
## Selects the stock density input layout. UE 5.8 Default requires all three
## layout textures; the renderer reports a configuration error if one is absent.
@export_enum("Built-in", "UE 5.8 Default") var kernel_layout := "Built-in":
	set(value):
		if kernel_layout == value:
			return
		kernel_layout = value
		notify_property_list_changed()
		_touch()
@export var curl_uv_scale := Vector3.ONE:
	set(value):
		curl_uv_scale = _finite_vector(value, Vector3.ONE).max(Vector3.ZERO)
		_touch()
@export_range(0.0, 4.0, 0.01, "or_greater") var curl_strength := 1.0:
	set(value):
		curl_strength = maxf(_finite(value, 1.0), 0.0)
		_touch()

@export_range(0.0, 16.0, 0.01, "or_greater") var density_scale := 1.0:
	set(value):
		density_scale = maxf(_finite(value, 0.0), 0.0)
		_touch()
@export_range(0.0, 1.0, 0.001) var coverage := 0.5:
	set(value):
		coverage = clampf(_finite(value, 0.5), 0.0, 1.0)
		_touch()
@export var shape_uv_scale := Vector3.ONE:
	set(value):
		shape_uv_scale = _finite_vector(value, Vector3.ONE).max(Vector3.ZERO)
		_touch()
@export var detail_uv_scale := Vector3.ONE:
	set(value):
		detail_uv_scale = _finite_vector(value, Vector3.ONE).max(Vector3.ZERO)
		_touch()
@export_range(0.0, 4.0, 0.01, "or_greater") var detail_strength := 1.0:
	set(value):
		detail_strength = maxf(_finite(value, 1.0), 0.0)
		_touch()
@export var weather_uv_scale := Vector2.ONE:
	set(value):
		weather_uv_scale = value if value.is_finite() else Vector2.ONE
		_touch()
@export_range(0.0, 16.0, 0.01, "or_greater") var weather_strength := 1.0:
	set(value):
		weather_strength = maxf(_finite(value, 1.0), 0.0)
		_touch()
@export_range(0.0, 1.0, 0.001) var conservative_density := 1.0:
	set(value):
		conservative_density = clampf(_finite(value, 1.0), 0.0, 1.0)
		_touch()
@export var wind_offset_km := Vector3.ZERO:
	set(value):
		wind_offset_km = _finite_vector(value, Vector3.ZERO)
		_touch()
@export var detail_enabled := true:
	set(value):
		detail_enabled = value
		_touch()
## Optional GLSL snippet compiled into the cloud material kernel. Empty uses
## the built-in kernel for Built-in layout and the packaged UE 5.8 graph kernel
## for UE 5.8 Default layout.
@export_multiline var kernel_source := "":
	set(value):
		if kernel_source == value:
			return
		kernel_source = value
		_touch()

@export_group("Volume Appearance")
## RGB extinction coefficient per kilometre. It remains a three-channel value
## so colored absorption is not silently reduced to a scalar.
@export var extinction_per_km := Vector3.ONE:
	set(value):
		extinction_per_km = _finite_vector(value, Vector3.ONE).max(Vector3.ZERO)
		_touch()
@export_custom(PROPERTY_HINT_COLOR_NO_ALPHA, "") var albedo_linear := Color(0.9, 0.9, 0.9):
	set(value):
		albedo_linear = _finite_color(value, Color(0.9, 0.9, 0.9))
		_touch()
@export var emission_per_km := Vector3.ZERO:
	set(value):
		emission_per_km = _finite_vector(value, Vector3.ZERO).max(Vector3.ZERO)
		_touch()

@export_group("Advanced Material Output")
## UE's Advanced Material Output defaults are isotropic: G, G2, and blend are 0.
@export_range(-0.99, 0.99, 0.001) var phase_g := 0.0:
	set(value):
		phase_g = clampf(_finite(value, 0.0), -0.99, 0.99)
		_touch()
@export_range(-0.99, 0.99, 0.001) var phase_g2 := 0.0:
	set(value):
		phase_g2 = clampf(_finite(value, 0.0), -0.99, 0.99)
		_touch()
@export_range(0.0, 1.0, 0.001) var phase_blend := 0.0:
	set(value):
		phase_blend = clampf(_finite(value, 0.0), 0.0, 1.0)
		_touch()
@export var per_sample_phase := false:
	set(value):
		per_sample_phase = value
		_touch()
@export_range(0, 2, 1) var multi_scattering_octaves := 0:
	set(value):
		multi_scattering_octaves = clampi(value, 0, 2)
		_touch()
@export_range(0.0, 4.0, 0.01, "or_greater") var multi_scattering_contribution := 0.5:
	set(value):
		multi_scattering_contribution = maxf(_finite(value, 0.5), 0.0)
		_touch()
@export_range(0.0, 1.0, 0.001) var multi_scattering_occlusion := 0.5:
	set(value):
		multi_scattering_occlusion = clampf(_finite(value, 0.5), 0.0, 1.0)
		_touch()
@export_range(-1.0, 1.0, 0.001) var multi_scattering_eccentricity := 0.5:
	set(value):
		multi_scattering_eccentricity = clampf(_finite(value, 0.5), -1.0, 1.0)
		_touch()
@export var ground_contribution := false:
	set(value):
		ground_contribution = value
		_touch()
@export var grayscale := false:
	set(value):
		grayscale = value
		_touch()
@export var raymarch_volume_shadow := true:
	set(value):
		raymarch_volume_shadow = value
		_touch()
@export var clamp_multi_scattering := true:
	set(value):
		clamp_multi_scattering = value
		_touch()
@export var ambient_occlusion_override := false:
	set(value):
		ambient_occlusion_override = value
		_touch()
@export_range(0.0, 1.0, 0.001) var ambient_occlusion_strength := 1.0:
	set(value):
		ambient_occlusion_strength = clampf(_finite(value, 1.0), 0.0, 1.0)
		_touch()


func has_density_source() -> bool:
	if kernel_layout == "UE 5.8 Default":
		# The UE graph has its own density and material outputs. Generic density,
		# extinction, albedo and emission fields do not gate that path.
		return not _effective_kernel_source().strip_edges().is_empty() \
				and shape_density_texture != null \
				and layout_pattern_texture != null \
				and layout_cloud_mask_texture != null \
				and layout_height_profile_texture != null
	# Extinction can be zero while emissive cloud media still contributes light.
	# Conservative density is a raymarch bound, not a switch for publishing the
	# medium; do not unregister an emissive volume when extinction is zero.
	var has_positive_extinction := extinction_per_km.x > 0.0 or extinction_per_km.y > 0.0 or extinction_per_km.z > 0.0
	var has_scattering_source := shape_density_texture != null or not kernel_source.strip_edges().is_empty()
	var has_scattering_medium := has_scattering_source and density_scale > 0.0 and has_positive_extinction
	var has_emission := emission_per_km.x > 0.0 or emission_per_km.y > 0.0 or emission_per_km.z > 0.0
	return has_scattering_medium or has_emission


func get_revision() -> int:
	return _revision


func rendering_snapshot() -> Dictionary:
	var resolved_kernel_source := _effective_kernel_source()
	return {
		"revision": _revision,
		"shape_density_texture": shape_density_texture,
		"detail_density_texture": detail_density_texture,
		"weather_texture": weather_texture,
		"curl_noise_texture": curl_noise_texture,
		"layout_pattern_texture": layout_pattern_texture,
		"layout_cloud_mask_texture": layout_cloud_mask_texture,
		"layout_height_profile_texture": layout_height_profile_texture,
		"kernel_layout": "ue58_default" if kernel_layout == "UE 5.8 Default" else "builtin",
		"density_scale": density_scale,
		"coverage": coverage,
		"shape_uv_scale": shape_uv_scale,
		"detail_uv_scale": detail_uv_scale,
		"detail_strength": detail_strength,
		"weather_uv_scale": weather_uv_scale,
		"weather_strength": weather_strength,
		"conservative_density": conservative_density,
		"wind_offset_km": wind_offset_km,
		"detail_enabled": detail_enabled,
		"kernel_source": resolved_kernel_source,
		"extinction_per_km": extinction_per_km,
		"albedo_linear": Vector3(albedo_linear.r, albedo_linear.g, albedo_linear.b),
		"emission_per_km": emission_per_km,
		"phase_g": phase_g,
		"phase_g2": phase_g2,
		"phase_blend": phase_blend,
		"per_sample_phase": per_sample_phase,
		"multi_scattering_octaves": multi_scattering_octaves,
		"multi_scattering_contribution": multi_scattering_contribution,
		"multi_scattering_occlusion": multi_scattering_occlusion,
		"multi_scattering_eccentricity": multi_scattering_eccentricity,
		"ground_contribution": ground_contribution,
		"grayscale": grayscale,
		"raymarch_volume_shadow": raymarch_volume_shadow,
		"clamp_multi_scattering": clamp_multi_scattering,
		"ambient_occlusion_override": ambient_occlusion_override,
		"ambient_occlusion_strength": ambient_occlusion_strength,
		"curl_uv_scale": curl_uv_scale,
		"curl_strength": curl_strength,
	}


func _validate_property(property: Dictionary) -> void:
	if kernel_layout != "UE 5.8 Default":
		return
	# These generic inputs have no consumer in the specialized UE graph kernel.
	# Keep their stored values intact so switching back to Built-in restores them.
	if str(property.get("name", "")) in BUILTIN_ONLY_PROPERTIES:
		property["usage"] = int(property.get("usage", 0)) & ~PROPERTY_USAGE_EDITOR


func _effective_kernel_source() -> String:
	if not kernel_source.strip_edges().is_empty():
		return kernel_source
	if kernel_layout != "UE 5.8 Default":
		return ""
	if not _cached_ue58_kernel_source.is_empty():
		return _cached_ue58_kernel_source
	var now_msec := Time.get_ticks_msec()
	if now_msec - _ue58_kernel_source_last_probe_msec < 1000:
		return _cached_ue58_kernel_source
	_ue58_kernel_source_last_probe_msec = now_msec
	if not FileAccess.file_exists(DEFAULT_UE58_KERNEL_SOURCE_PATH):
		return _cached_ue58_kernel_source
	var file := FileAccess.open(DEFAULT_UE58_KERNEL_SOURCE_PATH, FileAccess.READ)
	if file == null:
		return _cached_ue58_kernel_source
	var source := file.get_as_text()
	if not source.strip_edges().is_empty():
		_cached_ue58_kernel_source = source
	return _cached_ue58_kernel_source


func _watch_texture(texture: Resource) -> void:
	if texture == null:
		return
	var id := texture.get_instance_id()
	var entry: Dictionary = _watched_textures.get(id, {})
	entry["weak"] = weakref(texture)
	entry["count"] = int(entry.get("count", 0)) + 1
	_watched_textures[id] = entry
	if int(entry["count"]) == 1 and not texture.changed.is_connected(_on_input_texture_changed):
		texture.changed.connect(_on_input_texture_changed)


func _unwatch_texture(texture: Resource) -> void:
	if texture == null:
		return
	var id := texture.get_instance_id()
	if not _watched_textures.has(id):
		return
	var entry: Dictionary = _watched_textures[id]
	var count := int(entry.get("count", 0)) - 1
	if count <= 0:
		var reference: WeakRef = entry.get("weak")
		var watched: Resource = reference.get_ref() if reference != null else null
		if watched != null and is_instance_valid(watched) and watched.changed.is_connected(_on_input_texture_changed):
			watched.changed.disconnect(_on_input_texture_changed)
		_watched_textures.erase(id)
	else:
		entry["count"] = count
		_watched_textures[id] = entry


func _on_input_texture_changed() -> void:
	_touch()


func _touch() -> void:
	_revision = 1 if _revision >= 2147483646 else _revision + 1
	emit_changed()


static func _finite(value: float, fallback: float) -> float:
	return value if is_finite(value) else fallback


static func _finite_vector(value: Vector3, fallback: Vector3) -> Vector3:
	return value if value.is_finite() else fallback


static func _finite_color(value: Color, fallback: Color) -> Color:
	if not is_finite(value.r) or not is_finite(value.g) or not is_finite(value.b):
		return fallback
	return Color(value.r, value.g, value.b, 1.0)
