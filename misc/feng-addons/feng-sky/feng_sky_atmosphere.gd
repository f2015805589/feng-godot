@tool
class_name FengSkyAtmosphere
extends WorldEnvironment
## World-scoped atmosphere with Unreal Engine 5.8 authoring semantics.

const FengSkyParameters = preload("res://addons/feng-sky/feng_sky_parameters.gd")
const FengSkyMultiScatteringLut = preload("res://addons/feng-sky/feng_sky_multiscattering_lut.gd")
const FengSkyOpticalLut = preload("res://addons/feng-sky/feng_sky_optical_lut.gd")
const FengSkyRuntime = preload("res://addons/feng-sky/feng_sky_runtime.gd")
const FengSkyLightRegistry = preload("res://addons/feng-sky/feng_sky_light_registry.gd")
const NON_PHYSICAL_SUN_IRRADIANCE := PI
const MAX_SOLAR_IRRADIANCE := 10000000.0
const MAX_SKY_RADIANCE := 60000.0
const AMBIENT_ZENITH_STEP_DEG := 2.0
const RAYLEIGH_COEFFICIENT_BASIS := 0.0331
const MIE_SCATTERING_COEFFICIENT_BASIS := 0.003996
const MIE_ABSORPTION_COEFFICIENT_BASIS := 0.000444
const OTHER_ABSORPTION_COEFFICIENT_BASIS := 0.001881
# Exact released sources only. An edited/custom shader is never auto-upgraded.
const LEGACY_ATMOSPHERE_SHADER_SHA256 := [
	"c421870e65cb92a6db325cc6270fac8f906df016b0efe1a1007bd691cb644e6d", # aa96f5c
	"0e4f8b56bc26ca577c5dfbb4ddea18e1a8a6f9a8324185153f3dba9062916020", # 9d41bde
	"0f815fb7da56be15db13c180fa6a1de55d5f7383fe22764aa16c6f315ec166fb", # e002032f test-1 embedded default
	"fecd4d6c7e913134cd27efe95dafbc5876e61c262620368ff701aa534d47863e", # 76df24c released canonical
]

@export_storage var _owned_environment: Environment
var _owned_sky: Sky
var _atmosphere_sky: Sky
@export_storage var _custom_sky: Sky
@export_storage var _saved_non_atmosphere_background_intensity: float = 30000.0
@export_storage var _atmosphere_background_intensity_override := false
var _atmosphere_enabled := true
var _initializing := true
var _bound_world_id := 0
var _light_registry: FengSkyLightRegistry
var _ambient_cache: Dictionary = {}
var _ambient_cache_miss_count := 0
var _ambient_cache_evaluation_count := 0
var _ambient_last_compute_usec := 0
var _ambient_total_compute_usec := 0
var _last_atmosphere_signature: Dictionary = {}
var _last_material_signature: Array = []
var _last_material_settings_signature: Array = []
var _last_snapshot_signature: Array = []
var _last_rendering_snapshot_signature: Array = []
var _snapshot_worlds: Script
var _settings_dirty := true
var _settings_revision := 0
var _settings_sanitize_count := 0
var _checked_shader: Shader
var _reference_shader: Shader
var _reference_shader_revision := 0
var _shader_identity_dirty := true
var _shader_identity_matches := false
var _shader_identity_check_count := 0
var _optical_lut: ImageTexture
var _optical_lut_signature: Array = []
var _optical_lut_build_count := 0
var _multi_scattering_lut: ImageTexture
var _multi_scattering_image: Image
var _multi_scattering_signature: Array = []
var _multi_scattering_build_count := 0
var _last_planet_center_m := Vector3.INF
var _snapshot_publish_count := 0
var _material_update_count := 0

@export_group("Sky")
## New nodes use the integrated Earth-like model. Assigning a non-atmosphere Sky
## switches this off; older scenes containing another Sky keep that Sky intact.
@export var atmosphere_enabled: bool:
	get:
		return _atmosphere_enabled
	set(value):
		if value and not _atmosphere_enabled:
			_remember_current_background_intensity()
		_atmosphere_enabled = value
		if not _initializing:
			_apply_selected_sky()
			_refresh_world_binding()

## A replaceable, privately copied Sky. An assigned non-atmosphere resource is
## retained as the custom mode and is never rewritten by atmospheric settings.
@export var sky: Sky:
	get:
		return environment.sky if environment != null else null
	set(value):
		if environment == null:
			_ensure_private_environment()
		if _is_atmosphere_sky(value):
			if not _atmosphere_enabled:
				_remember_current_background_intensity()
			_atmosphere_sky = _make_local_sky(value)
			_atmosphere_enabled = true
		else:
			_custom_sky = _make_local_sky(value)
			_atmosphere_enabled = false
		_apply_selected_sky()
		_refresh_world_binding()

## Optional explicit sun. If empty, the first visible Sky-compatible directional
## light in this World3D is selected (Light Only lights are skipped).
@export var sun_light: DirectionalLight3D
## Optional second atmospheric light (for example the moon), matching UE index 1.
@export var secondary_sun_light: DirectionalLight3D
## UE-style source angle is the full angular diameter; zero disables the disk.
@export_range(0.0, 5.0, 0.001, "or_greater", "suffix:deg") var sun_source_angle_deg: float = 0.5357:
	set(value):
		sun_source_angle_deg = clampf(FengSkyParameters.finite_float(value, 0.5357), 0.0, 5.0)
		_settings_dirty = true
@export_range(0.0, 5.0, 0.001, "or_greater", "suffix:deg") var secondary_sun_source_angle_deg: float = 0.5357:
	set(value):
		secondary_sun_source_angle_deg = clampf(FengSkyParameters.finite_float(value, 0.5357), 0.0, 5.0)
		_settings_dirty = true
## Disk tint only. This does not change direct illuminance or atmospheric scattering.
@export_custom(PROPERTY_HINT_COLOR_NO_ALPHA, "") var sun_disk_color_scale: Color = Color.WHITE
@export_custom(PROPERTY_HINT_COLOR_NO_ALPHA, "") var secondary_sun_disk_color_scale: Color = Color.WHITE
## Deprecated radius aliases keep old .tscn and script semantics; saves use diameter fields.
@export_storage var sun_angular_radius_deg: float:
	get:
		return sun_source_angle_deg * 0.5
	set(value):
		sun_source_angle_deg = clampf(FengSkyParameters.finite_float(value, 0.26785), 0.0, 2.0) * 2.0
@export_storage var secondary_sun_angular_radius_deg: float:
	get:
		return secondary_sun_source_angle_deg * 0.5
	set(value):
		secondary_sun_source_angle_deg = clampf(FengSkyParameters.finite_float(value, 0.26785), 0.0, 2.0) * 2.0
## Publish atmosphere-derived ambient radiance to Feng Fog for this World3D.
@export var affect_height_fog: bool = true
@export_range(0.0, 1.0, 0.01, "or_greater") var height_fog_contribution: float = 1.0

enum TransformMode { PLANET_TOP_AT_ABSOLUTE_WORLD_ORIGIN, PLANET_TOP_AT_COMPONENT_TRANSFORM, PLANET_CENTER_AT_COMPONENT_TRANSFORM }

@export_group("Planet")
## WorldEnvironment is not spatial. Component Transform uses planet_origin
## in world metres, or planet_transform.global_position when explicitly linked.
@export_enum("Planet Top at Absolute World Origin", "Planet Top at Component Transform", "Planet Center at Component Transform") var transform_mode: int = 0:
	set(value):
		transform_mode = value
		_settings_dirty = true
@export var planet_origin: Vector3 = Vector3.ZERO:
	set(value):
		planet_origin = value
		_settings_dirty = true
@export var planet_transform: Node3D = null:
	set(value):
		planet_transform = value
		_settings_dirty = true
@export_range(1.0, 7000.0, 1.0, "or_greater", "suffix:km") var ground_radius: float = 6360.0:
	set(value):
		ground_radius = value
		_settings_dirty = true
@export_custom(PROPERTY_HINT_COLOR_NO_ALPHA, "") var ground_albedo: Variant = Color(0.4, 0.4, 0.4):
	set(value):
		ground_albedo = _author_color(value)
		_settings_dirty = true

@export_group("Atmosphere")
@export_range(1.0, 200.0, 0.1, "or_greater", "suffix:km") var atmosphere_height: float = 60.0:
	set(value):
		atmosphere_height = value
		_settings_dirty = true
@export_range(0.0, 2.0, 0.01, "or_greater") var multi_scattering_factor: float = 1.0:
	set(value):
		multi_scattering_factor = value
		_settings_dirty = true

@export_group("Atmosphere Rayleigh")
# Keep the legacy raw coefficient and multiplier fields as their original serialized
# storage. The editor views below normalize those values to UE's Color × coefficient scale.
@export_storage var rayleigh_scattering_scale: float = 1.0:
	set(value):
		rayleigh_scattering_scale = value
		_settings_dirty = true
@export_storage var rayleigh_scattering: Variant = Color(0.005802, 0.013558, 0.0331):
	set(value):
		rayleigh_scattering = _author_color(value)
		_settings_dirty = true
@export_range(0.0, 2.0, 0.000001, "or_greater") var rayleigh_scattering_coefficient_scale: float:
	get:
		return maxf(FengSkyParameters.finite_float(rayleigh_scattering_scale, 1.0), 0.0) * RAYLEIGH_COEFFICIENT_BASIS
	set(value):
		rayleigh_scattering_scale = maxf(FengSkyParameters.finite_float(value, RAYLEIGH_COEFFICIENT_BASIS), 0.0) / RAYLEIGH_COEFFICIENT_BASIS
		_settings_dirty = true
@export_custom(PROPERTY_HINT_COLOR_NO_ALPHA, "") var rayleigh_scattering_color: Color:
	get:
		return _normalized_coefficient_color(rayleigh_scattering, RAYLEIGH_COEFFICIENT_BASIS, FengSkyParameters.DEFAULT_RAYLEIGH_PER_KM)
	set(value):
		rayleigh_scattering = Vector3(value.r, value.g, value.b) * RAYLEIGH_COEFFICIENT_BASIS
		_settings_dirty = true
@export_range(0.01, 20.0, 0.01, "or_greater", "suffix:km") var rayleigh_exponential_distribution: float = 8.0:
	set(value):
		rayleigh_exponential_distribution = value
		_settings_dirty = true

@export_group("Atmosphere Mie")
@export_storage var mie_scattering_scale: float = 1.0:
	set(value):
		mie_scattering_scale = value
		_settings_dirty = true
@export_storage var mie_scattering: Variant = Color(0.003996, 0.003996, 0.003996):
	set(value):
		mie_scattering = _author_color(value)
		_settings_dirty = true
@export_range(0.0, 5.0, 0.000001, "or_greater") var mie_scattering_coefficient_scale: float:
	get:
		return maxf(FengSkyParameters.finite_float(mie_scattering_scale, 1.0), 0.0) * MIE_SCATTERING_COEFFICIENT_BASIS
	set(value):
		mie_scattering_scale = maxf(FengSkyParameters.finite_float(value, MIE_SCATTERING_COEFFICIENT_BASIS), 0.0) / MIE_SCATTERING_COEFFICIENT_BASIS
		_settings_dirty = true
@export_custom(PROPERTY_HINT_COLOR_NO_ALPHA, "") var mie_scattering_color: Color:
	get:
		return _normalized_coefficient_color(mie_scattering, MIE_SCATTERING_COEFFICIENT_BASIS, Vector3.ONE * MIE_SCATTERING_COEFFICIENT_BASIS)
	set(value):
		mie_scattering = Vector3(value.r, value.g, value.b) * MIE_SCATTERING_COEFFICIENT_BASIS
		_settings_dirty = true
@export_storage var mie_absorption_scale: float = 1.0:
	set(value):
		mie_absorption_scale = value
		_settings_dirty = true
@export_storage var mie_absorption: Variant = Color(0.000444, 0.000444, 0.000444):
	set(value):
		mie_absorption = _author_color(value)
		_settings_dirty = true
@export_range(0.0, 5.0, 0.000001, "or_greater") var mie_absorption_coefficient_scale: float:
	get:
		return maxf(FengSkyParameters.finite_float(mie_absorption_scale, 1.0), 0.0) * MIE_ABSORPTION_COEFFICIENT_BASIS
	set(value):
		mie_absorption_scale = maxf(FengSkyParameters.finite_float(value, MIE_ABSORPTION_COEFFICIENT_BASIS), 0.0) / MIE_ABSORPTION_COEFFICIENT_BASIS
		_settings_dirty = true
@export_custom(PROPERTY_HINT_COLOR_NO_ALPHA, "") var mie_absorption_color: Color:
	get:
		return _normalized_coefficient_color(mie_absorption, MIE_ABSORPTION_COEFFICIENT_BASIS, Vector3.ONE * MIE_ABSORPTION_COEFFICIENT_BASIS)
	set(value):
		mie_absorption = Vector3(value.r, value.g, value.b) * MIE_ABSORPTION_COEFFICIENT_BASIS
		_settings_dirty = true
@export_range(0.0, 0.999, 0.001) var mie_anisotropy: float = 0.8:
	set(value):
		mie_anisotropy = value
		_settings_dirty = true
@export_range(0.01, 10.0, 0.01, "or_greater", "suffix:km") var mie_exponential_distribution: float = 1.2:
	set(value):
		mie_exponential_distribution = value
		_settings_dirty = true

@export_group("Atmosphere Absorption")
## The UE 5.8 tent profile is zero at tip_altitude ± width and peaks at tip_value.
@export_storage var absorption_scale: float = 1.0:
	set(value):
		absorption_scale = value
		_settings_dirty = true
@export_storage var absorption: Variant = Color(0.000650, 0.001881, 0.000085):
	set(value):
		absorption = _author_color(value)
		_settings_dirty = true
@export_range(0.0, 0.2, 0.000001, "or_greater") var other_absorption_coefficient_scale: float:
	get:
		return maxf(FengSkyParameters.finite_float(absorption_scale, 1.0), 0.0) * OTHER_ABSORPTION_COEFFICIENT_BASIS
	set(value):
		absorption_scale = maxf(FengSkyParameters.finite_float(value, OTHER_ABSORPTION_COEFFICIENT_BASIS), 0.0) / OTHER_ABSORPTION_COEFFICIENT_BASIS
		_settings_dirty = true
@export_custom(PROPERTY_HINT_COLOR_NO_ALPHA, "") var other_absorption_color: Color:
	get:
		return _normalized_coefficient_color(absorption, OTHER_ABSORPTION_COEFFICIENT_BASIS, FengSkyParameters.DEFAULT_ABSORPTION_PER_KM)
	set(value):
		absorption = Vector3(value.r, value.g, value.b) * OTHER_ABSORPTION_COEFFICIENT_BASIS
		_settings_dirty = true
@export_subgroup("Tent", "absorption_")
@export_range(0.0, 60.0, 0.1, "or_greater", "suffix:km") var absorption_tip_altitude: float = 25.0:
	set(value):
		absorption_tip_altitude = value
		_settings_dirty = true
@export_range(0.0, 1.0, 0.01) var absorption_tip_value: float = 1.0:
	set(value):
		absorption_tip_value = value
		_settings_dirty = true
@export_range(0.0, 20.0, 0.1, "or_greater", "suffix:km") var absorption_width: float = 15.0:
	set(value):
		absorption_width = value
		_settings_dirty = true

@export_group("Art Direction")
## Sky-only gain; the combined gain below also applies to surface aerial perspective.
@export_custom(PROPERTY_HINT_COLOR_NO_ALPHA, "") var sky_luminance_factor: Variant = Color.WHITE:
	set(value):
		sky_luminance_factor = _author_color(value)
		_settings_dirty = true
@export_custom(PROPERTY_HINT_COLOR_NO_ALPHA, "") var sky_and_aerial_perspective_luminance_factor: Variant = Color.WHITE:
	set(value):
		sky_and_aerial_perspective_luminance_factor = _author_color(value)
		_settings_dirty = true
@export_range(0.0, 3.0, 0.01, "or_greater") var aerial_perspective_distance_scale: float = 1.0:
	set(value):
		aerial_perspective_distance_scale = value
		_settings_dirty = true
@export_range(0.001, 10.0, 0.01, "or_greater", "suffix:km") var aerial_perspective_start_depth: float = 0.1:
	set(value):
		aerial_perspective_start_depth = value
		_settings_dirty = true
@export_range(-90.0, 90.0, 0.1, "suffix:deg") var transmittance_min_light_elevation_angle: float = -90.0:
	set(value):
		transmittance_min_light_elevation_angle = value
		_settings_dirty = true

@export_group("Rendering")
## Enables Environment Glow/Bloom for the whole HDR scene. The renderer's Bloom pass must also be enabled.
@export var bloom_enabled := true:
	set(value):
		bloom_enabled = value
		_update_bloom_enabled()
@export_range(0.25, 8.0, 0.01, "or_greater") var trace_sample_count_scale: float = 1.0:
	set(value):
		trace_sample_count_scale = value
		_settings_dirty = true

# Read/write compatibility aliases load old .tscn fields and old scripts.
# Only canonical fields are stored on the next save; no duplicate authorities.
var planet_radius_km: float:
	get:
		return ground_radius
	set(value):
		ground_radius = value

var atmosphere_height_km: float:
	get:
		return atmosphere_height
	set(value):
		atmosphere_height = value

var rayleigh_scale_height_km: float:
	get:
		return rayleigh_exponential_distribution
	set(value):
		rayleigh_exponential_distribution = value

var mie_scale_height_km: float:
	get:
		return mie_exponential_distribution
	set(value):
		mie_exponential_distribution = value

var mie_asymmetry: float:
	get:
		return mie_anisotropy
	set(value):
		mie_anisotropy = value

var rayleigh_scattering_per_km: Vector3:
	get:
		return FengSkyParameters.finite_vector(rayleigh_scattering, FengSkyParameters.DEFAULT_RAYLEIGH_PER_KM) * rayleigh_scattering_scale
	set(value):
		rayleigh_scattering_scale = 1.0
		rayleigh_scattering = value

var mie_scattering_per_km: float:
	get:
		return FengSkyParameters.finite_vector(mie_scattering, Vector3.ONE * 0.003996).x * mie_scattering_scale
	set(value):
		mie_scattering_scale = 1.0
		mie_scattering = Vector3.ONE * value

var mie_extinction_per_km: float:
	get:
		return mie_scattering_per_km + FengSkyParameters.finite_vector(mie_absorption, Vector3.ONE * 0.000444).x * mie_absorption_scale
	set(value):
		mie_absorption_scale = 1.0
		mie_absorption = Vector3.ONE * maxf(value - mie_scattering_per_km, 0.0)

var planet_center_m: Vector3:
	get:
		return _resolved_planet_center()
	set(value):
		planet_transform = null
		planet_origin = value
		transform_mode = TransformMode.PLANET_CENTER_AT_COMPONENT_TRANSFORM


# Variant setters accept the previous Vector3 serialization while the inspector
# and new scene files expose actual Color controls like UE's LinearColor fields.
static func _author_color(value: Variant) -> Color:
	if value is Color:
		return value
	if value is Vector3:
		return Color(value.x, value.y, value.z, 1.0)
	return Color.WHITE


static func _normalized_coefficient_color(value: Variant, basis: float, fallback: Vector3) -> Color:
	var coefficient := FengSkyParameters.finite_vector(value, fallback) / basis
	return Color(coefficient.x, coefficient.y, coefficient.z, 1.0)


func _validate_property(property: Dictionary) -> void:
	if property["name"] in ["ground_albedo", "rayleigh_scattering", "mie_scattering", "mie_absorption", "absorption", "rayleigh_scattering_color", "mie_scattering_color", "mie_absorption_color", "other_absorption_color", "sun_disk_color_scale", "secondary_sun_disk_color_scale", "sky_luminance_factor", "sky_and_aerial_perspective_luminance_factor"]:
		property["type"] = TYPE_COLOR
	if property["name"] in [
		"rayleigh_scattering_coefficient_scale", "mie_scattering_coefficient_scale",
		"mie_absorption_coefficient_scale", "other_absorption_coefficient_scale",
		"rayleigh_scattering_color", "mie_scattering_color", "mie_absorption_color", "other_absorption_color",
		"sun_angular_radius_deg", "secondary_sun_angular_radius_deg",
	]:
		property["usage"] = int(property["usage"]) & ~PROPERTY_USAGE_STORAGE


var bottom_radius: float:
	get:
		return ground_radius
	set(value):
		ground_radius = value

var aerial_perspective_view_distance_scale: float:
	get:
		return aerial_perspective_distance_scale
	set(value):
		aerial_perspective_distance_scale = value

var other_absorption_scale: float:
	get:
		return absorption_scale
	set(value):
		absorption_scale = value

var other_absorption: Variant:
	get:
		return absorption
	set(value):
		absorption = value


func _init() -> void:
	var default_environment := Environment.new()
	default_environment.resource_local_to_scene = true
	_owned_environment = default_environment
	environment = default_environment
	_atmosphere_sky = _make_atmosphere_sky()
	_owned_sky = _atmosphere_sky
	environment.sky = _owned_sky
	environment.background_mode = Environment.BG_SKY
	_update_background_intensity_mode()
	_update_bloom_enabled()
	_initializing = false


func _enter_tree() -> void:
	_light_registry = FengSkyLightRegistry.attach(get_tree(), self) as FengSkyLightRegistry
	var route_path := "res://addons/feng-render-pipeline/passes/snapshot_worlds.gd"
	if ResourceLoader.exists(route_path):
		_snapshot_worlds = load(route_path) as Script
		_snapshot_worlds.call("scan", get_tree().root, self)
		get_tree().node_added.connect(_on_scene_node_added)
	_sync_environment()
	set_process(true)


func _ready() -> void:
	_sync_environment()
	_refresh_world_binding()


func _exit_tree() -> void:
	if _light_registry != null:
		_light_registry.detach(self)
		_light_registry = null
	if _snapshot_worlds != null:
		_snapshot_worlds.call("unregister_owner", self)
	if get_tree().node_added.is_connected(_on_scene_node_added):
		get_tree().node_added.disconnect(_on_scene_node_added)
	FengSkyRuntime.remove_rendering_snapshot(self, _bound_world_id)
	_last_rendering_snapshot_signature.clear()
	FengSkyRuntime.remove_snapshot(self, _bound_world_id)
	_bound_world_id = 0
	_last_snapshot_signature.clear()
	set_process(false)


func _on_scene_node_added(node: Node) -> void:
	if node is Viewport and _snapshot_worlds != null:
		_snapshot_worlds.call("register_viewport", node, self)


func _process(_delta: float) -> void:
	FengSkyRuntime.refresh_rendering_snapshots()
	# The inherited environment has no setter hook. Keep the editor workflow
	# compatible with direct Inspector edits while runtime values are polled only
	# to detect changes; the CPU atmosphere integration itself is cached.
	if environment != _owned_environment or (
		Engine.is_editor_hint()
		and environment != null
		and (environment.sky != _owned_sky or environment.background_mode != Environment.BG_SKY)
	):
		_sync_environment()
	_update_background_intensity_mode()
	_update_bloom_enabled()
	_refresh_atmosphere_cache()
	_refresh_world_binding()


func _sync_environment() -> void:
	_ensure_private_environment()
	_enforce_sky_background()
	_apply_selected_sky()


func _ensure_private_environment() -> void:
	if environment == null:
		var created := Environment.new()
		created.resource_local_to_scene = true
		_owned_environment = created
		_owned_sky = null
		environment = created
		_apply_selected_sky()
		return

	if environment == _owned_environment:
		if environment.sky != _owned_sky:
			if not _atmosphere_background_intensity_override:
				_remember_current_background_intensity()
			_adopt_sky(environment.sky)
		return

	var source := environment
	_saved_non_atmosphere_background_intensity = source.background_intensity
	var local_environment := source.duplicate(true) as Environment
	if local_environment == null:
		push_error("FengSkyAtmosphere could not duplicate its Environment resource.")
		local_environment = Environment.new()
	local_environment.resource_local_to_scene = true
	if source.sky != null:
		_adopt_sky(source.sky)
	_owned_environment = local_environment
	environment = local_environment
	_apply_selected_sky()


func _adopt_sky(source: Sky) -> void:
	if _is_atmosphere_sky(source):
		_atmosphere_sky = _make_local_sky(source)
		_atmosphere_enabled = true
	else:
		_custom_sky = _make_local_sky(source)
		_atmosphere_enabled = false


func _apply_selected_sky() -> void:
	if environment == null:
		return
	if _atmosphere_enabled:
		if _atmosphere_sky == null:
			_atmosphere_sky = _make_atmosphere_sky()
		_owned_sky = _atmosphere_sky
	else:
		if _custom_sky == null:
			_custom_sky = _make_legacy_default_sky()
		_owned_sky = _custom_sky
	environment.sky = _owned_sky
	_enforce_sky_background()
	_update_background_intensity_mode()
	_update_bloom_enabled()


func _update_bloom_enabled() -> void:
	# Only mutate this component's private Environment. A scene's shared source is
	# copied by _ensure_private_environment() before this setting is applied.
	if environment == null or environment != _owned_environment:
		return
	if environment.glow_enabled != bloom_enabled:
		environment.glow_enabled = bloom_enabled


func _update_background_intensity_mode() -> void:
	if environment == null:
		return
	if _has_selected_atmosphere_sky():
		if not _atmosphere_background_intensity_override:
			_remember_current_background_intensity()
			_atmosphere_background_intensity_override = true
		if not is_equal_approx(environment.background_intensity, 1.0):
			environment.background_intensity = 1.0
	elif _atmosphere_background_intensity_override:
		environment.background_intensity = _saved_non_atmosphere_background_intensity
		_atmosphere_background_intensity_override = false
	else:
		_remember_current_background_intensity()


func _remember_current_background_intensity() -> void:
	if environment != null and is_finite(environment.background_intensity):
		_saved_non_atmosphere_background_intensity = environment.background_intensity


func _enforce_sky_background() -> void:
	if environment != null and environment.background_mode != Environment.BG_SKY:
		environment.background_mode = Environment.BG_SKY


func _make_atmosphere_sky() -> Sky:
	var result := Sky.new()
	result.resource_local_to_scene = true
	result.process_mode = Sky.PROCESS_MODE_REALTIME
	var material := ShaderMaterial.new()
	material.resource_local_to_scene = true
	var shared_shader := FengSkyRuntime.atmosphere_shader()
	if shared_shader != null:
		var local_shader := shared_shader.duplicate(true) as Shader
		local_shader.resource_local_to_scene = true
		material.shader = local_shader
	else:
		push_error("FengSkyAtmosphere could not load its atmosphere shader.")
	result.sky_material = material
	return result


func _make_legacy_default_sky() -> Sky:
	var result := Sky.new()
	result.resource_local_to_scene = true
	var material := PhysicalSkyMaterial.new()
	material.resource_local_to_scene = true
	result.sky_material = material
	return result


func _make_local_sky(source: Sky) -> Sky:
	if source == null:
		return null

	var local_sky := source.duplicate(true) as Sky
	if local_sky == null:
		push_error("FengSkyAtmosphere could not duplicate its Sky resource.")
		return null
	local_sky.resource_local_to_scene = true

	var source_material := source.sky_material
	if source_material != null:
		var local_material := local_sky.sky_material
		if local_material == source_material:
			local_material = source_material.duplicate(true) as Material
			local_sky.sky_material = local_material
		if local_material == null:
			push_error("FengSkyAtmosphere could not duplicate its Sky material.")
			return local_sky
		local_material.resource_local_to_scene = true
		if local_material is ShaderMaterial and local_material.shader != null:
			var local_shader := local_material.shader.duplicate(true) as Shader
			if local_shader == null:
				push_error("FengSkyAtmosphere could not duplicate its Sky shader.")
				local_material.shader = null
			else:
				if _is_released_legacy_shader(local_shader.code):
					local_shader.code = FengSkyRuntime.atmosphere_shader_code()
				local_shader.resource_local_to_scene = true
				local_material.shader = local_shader

	return local_sky


static func _is_released_legacy_shader(code: String) -> bool:
	return LEGACY_ATMOSPHERE_SHADER_SHA256.has(code.replace("\r\n", "\n").sha256_text())

func _is_atmosphere_sky(candidate: Sky) -> bool:
	if candidate == null or not candidate.sky_material is ShaderMaterial:
		return false
	var material := candidate.sky_material as ShaderMaterial
	var shader := material.shader
	if shader != _checked_shader:
		if _checked_shader != null:
			_checked_shader.changed.disconnect(_invalidate_shader_identity)
		_checked_shader = shader
		if _checked_shader != null:
			_checked_shader.changed.connect(_invalidate_shader_identity)
		_invalidate_shader_identity()
	if _shader_identity_dirty:
		if _reference_shader == null:
			_reference_shader = FengSkyRuntime.atmosphere_shader()
			if _reference_shader != null:
				_reference_shader.changed.connect(_invalidate_reference_shader_identity)
		var matches_released_source := (candidate != _owned_sky or _reference_shader_revision == 0) and _is_released_legacy_shader(shader.code if shader != null else "")
		_shader_identity_matches = shader != null and _reference_shader != null and (shader.code == _reference_shader.code or matches_released_source)
		_shader_identity_dirty = false
		_shader_identity_check_count += 1
	return _shader_identity_matches


func _invalidate_reference_shader_identity() -> void:
	# The editor may hot-reload the original asset while private scene copies
	# stay alive. Its source is part of identity, just like the selected shader.
	_reference_shader_revision += 1
	_invalidate_shader_identity()


func _invalidate_shader_identity() -> void:
	_shader_identity_dirty = true
	_last_material_signature.clear()
	_last_material_settings_signature.clear()
	_last_snapshot_signature.clear()


func _has_selected_atmosphere_sky() -> bool:
	return (
		_atmosphere_enabled
		and environment != null
		and _owned_sky != null
		and environment.sky == _owned_sky
		and _is_atmosphere_sky(environment.sky)
	)


func _current_world() -> World3D:
	var viewport := get_viewport()
	return viewport.find_world_3d() if viewport != null else null


func _refresh_world_binding() -> void:
	var world := _current_world()
	var active := world != null and environment != null and world.get_environment() == environment
	if not active or not _has_selected_atmosphere_sky():
		_last_material_signature.clear()
		_last_snapshot_signature.clear()
		_last_rendering_snapshot_signature.clear()
		FengSkyRuntime.remove_snapshot(self, _bound_world_id)
		FengSkyRuntime.remove_rendering_snapshot(self, _bound_world_id)
		_bound_world_id = 0
		return

	var world_id := world.get_instance_id()
	if _bound_world_id != world_id:
		_last_snapshot_signature.clear()
		_last_rendering_snapshot_signature.clear()
		FengSkyRuntime.remove_snapshot(self, _bound_world_id)
		FengSkyRuntime.remove_rendering_snapshot(self, _bound_world_id)
		_bound_world_id = world_id

	var selected_sun := _resolve_sun(world)
	var secondary := secondary_sun_light if _sun_is_compatible(secondary_sun_light, world) else null
	if secondary == selected_sun:
		secondary = null # One light cannot contribute twice through the two slots.
	var source := _light_source(selected_sun)
	var second_source := _light_source(secondary)
	_update_sky_shader(source, second_source)
	var sky_gain := _background_energy_gain()
	var physical_units := _uses_physical_light_units()
	var signature: Array = [world_id, source, second_source, sky_gain, physical_units,
		_settings_revision, secondary_sun_source_angle_deg]
	var render_targets: Array = _snapshot_worlds.call("targets_for", world) if _snapshot_worlds != null else []
	var render_signature := signature + [render_targets]
	if render_signature != _last_rendering_snapshot_signature:
		FengSkyRuntime.publish_rendering_snapshot(self, world_id, {
			"settings": _atmosphere_settings(),
			"sun_light_rid": source["rid"], "sun_direction": source["direction"],
			"sun_color_linear": source["color"], "sun_irradiance": source["irradiance"],
			"secondary_sun_light_rid": second_source["rid"], "secondary_sun_direction": second_source["direction"],
			"secondary_sun_color_linear": second_source["color"], "secondary_sun_irradiance": second_source["irradiance"],
			"sky_gain": sky_gain, "render_targets": render_targets,
			"optical_column_lut": _optical_lut if FengSkyOpticalLut.supports_settings(_atmosphere_settings()) else null, "multi_scattering_lut": _multi_scattering_lut,
		})
		_last_rendering_snapshot_signature = render_signature
	if not affect_height_fog:
		_last_snapshot_signature.clear()
		FengSkyRuntime.remove_snapshot(self, _bound_world_id)
		return
	var fog_contribution := maxf(FengSkyParameters.finite_float(height_fog_contribution, 1.0), 0.0)
	var snapshot_signature := signature + [fog_contribution]
	if snapshot_signature == _last_snapshot_signature:
		return
	var ambient := Vector3.ZERO
	var ground_illuminance := Vector3.ZERO
	var secondary_ground_illuminance := Vector3.ZERO
	for light_source in [source, second_source]:
		var irradiance: float = light_source["irradiance"]
		var color: Vector3 = light_source["color"]
		if irradiance > 0.0 and color.length_squared() > 0.0:
			var cache := _ambient_entry_for_sun(light_source["direction"], light_source == source)
			ambient += (cache["ambient_unit_sun"] as Vector3) * irradiance * color * sky_gain
			if light_source == source:
				ground_illuminance = (cache["ground_transmittance"] as Vector3) * irradiance * color
			elif light_source == second_source:
				secondary_ground_illuminance = (cache["ground_transmittance"] as Vector3) * irradiance * color
	ambient = ambient.min(Vector3.ONE * MAX_SKY_RADIANCE)
	FengSkyRuntime.publish_snapshot(self, world_id, {
		"sun_light_id": source["id"], "sun_direction": source["direction"],
		"sun_ground_illuminance": _finite_nonnegative(ground_illuminance),
		"secondary_sun_light_id": second_source["id"],
		"secondary_sun_ground_illuminance": _finite_nonnegative(secondary_ground_illuminance),
		"sun_irradiance_unit": "lux" if physical_units else "frp_normalized",
		"ambient_radiance": _finite_nonnegative(ambient),
		"height_fog_contribution": fog_contribution,
	})
	_last_snapshot_signature = snapshot_signature
	_snapshot_publish_count += 1


func _light_source(light: DirectionalLight3D) -> Dictionary:
	if light == null:
		return {"direction": Vector3.UP, "color": Vector3.ZERO, "irradiance": 0.0, "id": 0, "rid": RID()}
	return {"direction": FengSkyRuntime.sanitize_sun_direction(light.global_transform.basis.z),
		"color": _sun_linear_color(light), "irradiance": _sun_irradiance(light),
		"id": light.get_instance_id(), "rid": light.get_base()}


func _feng_sky_rendering_is_active(world_id: int) -> bool:
	if not is_inside_tree() or not _has_selected_atmosphere_sky():
		_last_rendering_snapshot_signature.clear()
		return false
	var world := _current_world()
	var active := world != null and world.get_instance_id() == world_id and world.get_environment() == environment
	if not active:
		_last_rendering_snapshot_signature.clear()
	return active


func _feng_sky_runtime_is_active(world_id: int) -> bool:
	var active := affect_height_fog and _feng_sky_rendering_is_active(world_id)
	if not active:
		_last_snapshot_signature.clear()
	return active


func _resolve_sun(world: World3D) -> DirectionalLight3D:
	if sun_light != null:
		return sun_light if _sun_is_compatible(sun_light, world) else null
	return _light_registry.resolve(world, secondary_sun_light) if _light_registry != null else null


func _sun_is_compatible(candidate: DirectionalLight3D, world: World3D) -> bool:
	return FengSkyLightRegistry.compatible(candidate, world)


func _sun_linear_color(light: DirectionalLight3D) -> Vector3:
	var color := light.light_color.srgb_to_linear()
	if _uses_physical_light_units():
		color *= light.get_correlated_color().srgb_to_linear()
	return _finite_nonnegative(Vector3(color.r, color.g, color.b))


func _sun_irradiance(light: DirectionalLight3D) -> float:
	if light.light_negative or not is_finite(light.light_energy):
		return 0.0
	var renderer_irradiance := NON_PHYSICAL_SUN_IRRADIANCE
	if _uses_physical_light_units():
		if not is_finite(light.light_intensity_lux):
			return 0.0
		renderer_irradiance = maxf(light.light_intensity_lux, 0.0)
	# Keep the addon in the same normalized scale as FRP surface direct lighting
	# when physical units are off; the 10 MLux-equivalent ceiling bounds HDR work.
	return minf(renderer_irradiance * maxf(light.light_energy, 0.0), MAX_SOLAR_IRRADIANCE)


func _uses_physical_light_units() -> bool:
	return ProjectSettings.get_setting("rendering/lights_and_shadows/use_physical_light_units", false)


func _refresh_atmosphere_cache() -> void:
	var center := _resolved_planet_center()
	if center != _last_planet_center_m:
		_last_planet_center_m = center
		_settings_dirty = true
	if not _settings_dirty:
		return
	_settings_dirty = false
	_settings_sanitize_count += 1
	var signature := _sanitize_current_settings()
	if signature != _last_atmosphere_signature:
		_ambient_cache.clear()
		_last_atmosphere_signature = signature
		_settings_revision += 1


func _atmosphere_settings() -> Dictionary:
	_refresh_atmosphere_cache()
	return _last_atmosphere_signature


func _resolved_planet_center() -> Vector3:
	var radius := clampf(FengSkyParameters.finite_float(ground_radius, 6360.0), 1.0, 100000.0)
	if transform_mode == TransformMode.PLANET_TOP_AT_ABSOLUTE_WORLD_ORIGIN:
		return Vector3.DOWN * radius * 1000.0
	var origin := planet_origin
	if is_instance_valid(planet_transform) and planet_transform.is_inside_tree():
		origin = planet_transform.global_position
	origin = FengSkyParameters.finite_vector(origin, Vector3.ZERO)
	return origin - Vector3.UP * radius * 1000.0 if transform_mode == TransformMode.PLANET_TOP_AT_COMPONENT_TRANSFORM else origin


func _sanitize_current_settings() -> Dictionary:
	var width := clampf(FengSkyParameters.finite_float(absorption_width, 15.0), 0.0, 10000.0)
	var tip := FengSkyParameters.finite_float(absorption_tip_altitude, 25.0)
	var density := clampf(FengSkyParameters.finite_float(absorption_tip_value, 1.0), 0.0, 1.0)
	var profile_enabled := width > 0.0 and density > 0.0
	var slope := density / maxf(width, 0.001) if profile_enabled else 0.0
	var scattering := FengSkyParameters.coefficient(mie_scattering, Vector3.ONE * 0.003996) * maxf(FengSkyParameters.finite_float(mie_scattering_scale, 1.0), 0.0)
	var mie_absorption_coefficient := FengSkyParameters.coefficient(mie_absorption, Vector3.ONE * 0.000444) * maxf(FengSkyParameters.finite_float(mie_absorption_scale, 1.0), 0.0)
	return FengSkyParameters.sanitize_atmosphere_settings({
		"planet_radius_km": ground_radius,
		"atmosphere_height_km": atmosphere_height,
		"rayleigh_scale_height_km": rayleigh_exponential_distribution,
		"mie_scale_height_km": mie_exponential_distribution,
		"rayleigh_scattering_per_km": FengSkyParameters.coefficient(rayleigh_scattering, FengSkyParameters.DEFAULT_RAYLEIGH_PER_KM) * maxf(FengSkyParameters.finite_float(rayleigh_scattering_scale, 1.0), 0.0),
		"mie_scattering_coefficients": scattering,
		"mie_extinction_coefficients": scattering + mie_absorption_coefficient,
		"mie_asymmetry": mie_anisotropy,
		"absorption_extinction_per_km": FengSkyParameters.coefficient(absorption, FengSkyParameters.DEFAULT_ABSORPTION_PER_KM) * maxf(FengSkyParameters.finite_float(absorption_scale, 1.0), 0.0) if profile_enabled else Vector3.ZERO,
		"absorption_density_layer_width_km": tip,
		"absorption_layer0_linear_term": slope,
		"absorption_layer0_constant_term": density - tip * slope if profile_enabled else 0.0,
		"absorption_layer1_linear_term": -slope,
		"absorption_layer1_constant_term": density + tip * slope if profile_enabled else 0.0,
		"planet_center_m": _resolved_planet_center(),
		"ground_albedo": ground_albedo,
		"sun_angular_radius_deg": sun_source_angle_deg * 0.5,
		"multi_scattering_factor": multi_scattering_factor,
		"sky_luminance_factor": sky_and_aerial_perspective_luminance_factor,
		"sky_only_luminance_factor": sky_luminance_factor,
		"minimum_light_elevation_deg": transmittance_min_light_elevation_angle,
		"trace_sample_count_scale": trace_sample_count_scale,
		"aerial_perspective_view_distance_scale": aerial_perspective_distance_scale,
		"aerial_perspective_start_depth_km": aerial_perspective_start_depth,
	})


func _ambient_entry_for_sun(sun_direction: Vector3, include_multiple_scattering: bool = true) -> Dictionary:
	var up := _surface_up()
	var normalized_sun := sun_direction.normalized()
	var sun_elevation_cosine := up.dot(normalized_sun)
	var zenith_deg := rad_to_deg(acos(clampf(sun_elevation_cosine, -1.0, 1.0)))
	var position := clampf(zenith_deg / AMBIENT_ZENITH_STEP_DEG, 0.0, 180.0 / AMBIENT_ZENITH_STEP_DEG)
	var lower_bin := floori(position)
	var upper_bin := mini(lower_bin + 1, int(180.0 / AMBIENT_ZENITH_STEP_DEG))
	var blend := position - float(lower_bin)
	var lower := _ambient_cache_bin(lower_bin, up, include_multiple_scattering)
	var result := lower
	if upper_bin != lower_bin:
		var upper := _ambient_cache_bin(upper_bin, up, include_multiple_scattering)
		result = {
			"ambient_unit_sun": (lower["ambient_unit_sun"] as Vector3).lerp(upper["ambient_unit_sun"], blend),
			"ground_transmittance": (lower["ground_transmittance"] as Vector3).lerp(upper["ground_transmittance"], blend),
		}
	# Interpolation across the horizon must not leak direct light below it.
	# A nonnegative artist minimum explicitly requests a tangent/raised source.
	if sun_elevation_cosine < 0.0 and float(_atmosphere_settings()["minimum_light_elevation_deg"]) < 0.0:
		result = result.duplicate()
		result["ground_transmittance"] = Vector3.ZERO
	return result


func _ambient_cache_bin(zenith_bin: int, up: Vector3, include_multiple_scattering: bool = true) -> Dictionary:
	var key := Vector2i(zenith_bin, int(include_multiple_scattering))
	if _ambient_cache.has(key):
		return _ambient_cache[key]
	var zenith_rad := deg_to_rad(float(zenith_bin) * AMBIENT_ZENITH_STEP_DEG)
	var east := Vector3.RIGHT - up * up.dot(Vector3.RIGHT)
	if east.length_squared() < 0.001:
		east = Vector3.FORWARD - up * up.dot(Vector3.FORWARD)
	east = east.normalized()
	var representative_sun := (up * cos(zenith_rad) + east * sin(zenith_rad)).normalized()
	var compute_start_usec := Time.get_ticks_usec()
	var sample_settings := _atmosphere_settings()
	if not include_multiple_scattering:
		sample_settings = sample_settings.duplicate()
		sample_settings["multi_scattering_factor"] = 0.0
	var computed := FengSkyRuntime.compute_atmosphere_sample(sample_settings, representative_sun, 1.0, Vector3.ONE, _multi_scattering_image if include_multiple_scattering else null)
	_ambient_last_compute_usec = Time.get_ticks_usec() - compute_start_usec
	_ambient_total_compute_usec += _ambient_last_compute_usec
	_ambient_cache_miss_count += 1
	_ambient_cache_evaluation_count += int(computed["ambient_sample_count"])
	var entry := {
		"ambient_unit_sun": computed["ambient_unit_sun"],
		"ground_transmittance": computed["ground_transmittance"],
	}
	_ambient_cache[key] = entry
	return entry


func atmosphere_cache_stats() -> Dictionary:
	## Read-only counters for profiling cache misses without exposing mutable LUT data.
	return {
		"cached_sun_zenith_bins": _ambient_cache.size(),
		"cache_misses": _ambient_cache_miss_count,
		"evaluated_sky_directions": _ambient_cache_evaluation_count,
		"last_miss_usec": _ambient_last_compute_usec,
		"total_miss_usec": _ambient_total_compute_usec,
		"rays_per_miss": FengSkyRuntime.AMBIENT_SAMPLE_COUNT,
		"settings_sanitizations": _settings_sanitize_count,
		"shader_identity_checks": _shader_identity_check_count,
		"optical_lut_updates": _optical_lut_build_count,
		"multi_scattering_lut_updates": _multi_scattering_build_count,
		"snapshot_publications": _snapshot_publish_count,
		"material_updates": _material_update_count,
	}


func _surface_up() -> Vector3:
	var center: Vector3 = _atmosphere_settings()["planet_center_m"]
	var surface_origin := -center / 1000.0
	return surface_origin.normalized() if surface_origin.length_squared() > 0.001 else Vector3.UP


func _update_sky_shader(primary: Dictionary, secondary: Dictionary) -> void:
	if not _has_selected_atmosphere_sky():
		return
	var material := environment.sky.sky_material as ShaderMaterial
	var settings := _atmosphere_settings()
	var settings_signature: Array = [material.get_instance_id(), material.shader.get_instance_id(), _settings_revision]
	if settings_signature != _last_material_settings_signature:
		var lut_signature := FengSkyOpticalLut.geometry_signature(settings)
		var use_lut := FengSkyOpticalLut.supports_settings(settings)
		if use_lut and (_optical_lut == null or lut_signature != _optical_lut_signature):
			# A fresh private image/texture cannot be edited through another world.
			_optical_lut = ImageTexture.create_from_image(FengSkyOpticalLut.make_image(settings))
			_optical_lut.resource_local_to_scene = true
			_optical_lut_signature = lut_signature
			_optical_lut_build_count += 1
		var multi_signature := FengSkyMultiScatteringLut.signature(settings)
		if settings["multi_scattering_factor"] > 0.0 and (_multi_scattering_lut == null or multi_signature != _multi_scattering_signature):
			_multi_scattering_image = FengSkyMultiScatteringLut.make_image(settings)
			_multi_scattering_lut = ImageTexture.create_from_image(_multi_scattering_image)
			_multi_scattering_lut.resource_local_to_scene = true
			_multi_scattering_signature = multi_signature
			_multi_scattering_build_count += 1
		material.set_shader_parameter("multi_scattering_lut", _multi_scattering_lut)
		material.set_shader_parameter("use_multi_scattering_lut", settings["multi_scattering_factor"] > 0.0)
		for setting_name in settings:
			material.set_shader_parameter(setting_name, settings[setting_name])
		material.set_shader_parameter("optical_column_lut", _optical_lut)
		material.set_shader_parameter("use_optical_column_lut", use_lut)
		_last_material_settings_signature = settings_signature
	var sky_gain := _background_energy_gain()
	var primary_disk_scale := _disk_color_vector(sun_disk_color_scale)
	var secondary_disk_scale := _disk_color_vector(secondary_sun_disk_color_scale)
	var material_signature: Array = [material.get_instance_id(), material.shader.get_instance_id(),
		_settings_revision, primary["direction"], primary["color"], primary["irradiance"], sky_gain, secondary,
		secondary_sun_source_angle_deg, primary_disk_scale, secondary_disk_scale]
	if material_signature == _last_material_signature:
		return
	var sky_radiance_limit := 0.0
	if sky_gain > 0.0:
		sky_radiance_limit = MAX_SKY_RADIANCE / maxf(sky_gain, 0.000001)
	# _light_source() supplies the same normalized contract for both slots.
	material.set_shader_parameter("sun_direction", primary["direction"])
	material.set_shader_parameter("sun_color_linear", primary["color"])
	material.set_shader_parameter("sun_irradiance", primary["irradiance"])
	material.set_shader_parameter("sky_radiance_limit", sky_radiance_limit)
	material.set_shader_parameter("secondary_sun_direction", secondary["direction"])
	material.set_shader_parameter("secondary_sun_color_linear", secondary["color"])
	material.set_shader_parameter("secondary_sun_irradiance", secondary["irradiance"])
	material.set_shader_parameter("secondary_sun_angular_radius_deg", clampf(FengSkyParameters.finite_float(secondary_sun_source_angle_deg * 0.5, 0.26785), 0.0, 2.5))
	material.set_shader_parameter("sun_disk_color_scale", primary_disk_scale)
	material.set_shader_parameter("secondary_sun_disk_color_scale", secondary_disk_scale)
	_last_material_signature = material_signature
	_material_update_count += 1


func _finite_nonnegative(value: Vector3) -> Vector3:
	if not value.is_finite():
		return Vector3.ZERO
	return value.max(Vector3.ZERO)


func _disk_color_vector(value: Color) -> Vector3:
	return FengSkyParameters.finite_vector(Vector3(value.r, value.g, value.b), Vector3.ONE).clamp(Vector3.ZERO, Vector3.ONE * 100.0)


func _background_energy_gain() -> float:
	if environment == null or not is_finite(environment.background_energy_multiplier):
		return 0.0
	return maxf(environment.background_energy_multiplier, 0.0)


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if environment == null:
		warnings.append("FengSkyAtmosphere needs an Environment resource.")
	elif environment.sky == null:
		warnings.append("No Sky is assigned; the world background will use the Environment fallback color.")
	if not is_inside_tree():
		return warnings
	var world := _current_world()
	if world != null and environment != null and world.get_environment() != environment:
		warnings.append("Another WorldEnvironment is first in this World3D, so FengSkyAtmosphere does not affect it.")
	return warnings
