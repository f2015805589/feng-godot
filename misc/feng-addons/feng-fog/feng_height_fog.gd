@tool
class_name FengHeightFog
extends Node3D
## Feng Height Fog — a port of Unreal's ExponentialHeightFogComponent.
##
## The node's world-space height is its global Y position (each fog layer's
## height offset is relative to it), and a world keeps the latest registered
## enabled node active. Extinction parameters and the default authored source
## follow Unreal's exponential height fog semantics.
## Density and falloff carry Unreal's authored units and are divided
## by ten for meters before upload (Unreal divides by 1000 in centimeters).
## While active, the runtime temporarily enables debanding on affected viewports
## so the directional fog gradient survives final 8-bit tone mapping.

const Runtime = preload("feng_fog_runtime.gd")
const VolumetricFogParameters = preload("feng_volumetric_fog_parameters.gd")
## Unreal stores FogDensity/FogHeightFalloff per 1000 units in a centimeter
## world; dividing by ten gives the same profile in a meter world.
const UNIT_SCALE := 0.1

@export_group("高度指数雾")
## Turns the component's fog on or off.
@export var enabled := true:
	set(value):
		enabled = value
		_publish()
## Global density factor. (Unreal: Fog Density)
@export_range(0.0, 0.05, 0.0005, "or_greater") var fog_density := 0.02:
	set(value):
		fog_density = maxf(value, 0.0)
		_publish()
## Unreal's authored Fog Inscattering Color is an independent scene-linear
## source. It is not multiplied by sunlight, converted from sRGB, or clamped.
## Black is the Unreal-compatible default authored source.
@export var fog_inscattering_color := Color.BLACK:
	set(value):
		fog_inscattering_color = value
		_publish()
## Height density factor; controls how the density increases as height
## decreases. Smaller values make the visible transition larger. (Unreal: Fog Height Falloff)
@export_range(0.001, 2.0, 0.001, "or_greater", "or_less") var fog_height_falloff := 0.2:
	set(value):
		fog_height_falloff = maxf(value, 0.0)
		_publish()
## Height offset of the primary fog layer, relative to the node's height. (Unreal: Fog Height Offset)
@export var fog_height_offset := 0.0:
	set(value):
		fog_height_offset = value
		_publish()

@export_subgroup("第二层雾")
## Secondary fog layer density; a second layer can be used to add fog at
## another height. (Unreal: Second Fog Data → Fog Density)
@export_range(0.0, 0.05, 0.0005, "or_greater") var second_fog_density := 0.0:
	set(value):
		second_fog_density = maxf(value, 0.0)
		_publish()
## Height density factor of the secondary fog layer. (Unreal: Second Fog Data → Fog Height Falloff)
@export_range(0.001, 2.0, 0.001, "or_greater", "or_less") var second_fog_height_falloff := 0.2:
	set(value):
		second_fog_height_falloff = maxf(value, 0.0)
		_publish()
## Height offset of the secondary fog layer, relative to the node's height. (Unreal: Second Fog Data → Fog Height Offset)
@export var second_fog_height_offset := 0.0:
	set(value):
		second_fog_height_offset = value
		_publish()

@export_subgroup("雾裁剪")
## Maximum opacity of the fog. 1 means the fog can become fully opaque at a
## distance and replace scene color completely; 0 means the fog is never
## factored in. (Unreal: Fog Max Opacity)
@export_range(0.0, 1.0, 0.01) var fog_max_opacity := 1.0:
	set(value):
		fog_max_opacity = clampf(value, 0.0, 1.0)
		_publish()
## Distance from the camera at which the fog starts, in meters. (Unreal: Start Distance)
@export_range(0.0, 5000.0, 1.0, "or_greater", "suffix:m") var start_distance := 0.0:
	set(value):
		start_distance = maxf(value, 0.0)
		_publish()
## Distance at which scene elements are no longer fogged; 0 disables the
## cutoff. Unreal uses it to keep the sky unfogged. (Unreal: Fog Cutoff Distance)
@export_range(0.0, 20000.0, 1.0, "or_greater", "suffix:m") var fog_cutoff_distance := 0.0:
	set(value):
		fog_cutoff_distance = maxf(value, 0.0)
		_publish()

@export_subgroup("定向内散射")
## The directional lobe follows the active Feng Sky atmosphere's primary sun;
## when none is available, it follows a visible directional light in this World3D.
## Controls the size of the directional inscattering cone, used to approximate
## inscattering from the sun off the ambient haze. (Unreal: Directional Inscattering Exponent)
@export_range(2.0, 64.0, 0.1) var directional_inscattering_exponent := 4.0:
	set(value):
		directional_inscattering_exponent = maxf(value, 0.0)
		_publish()
## Controls the distance from the viewer at which the directional inscattering
## starts, in meters. (Unreal: Directional Inscattering Start Distance)
@export_range(0.0, 5000.0, 1.0, "or_greater", "suffix:m") var directional_inscattering_start_distance := 100.0:
	set(value):
		directional_inscattering_start_distance = maxf(value, 0.0)
		_publish()
## Independent artist color multiplied by sun luminance, never by the base
## Fog Inscattering Color. Retains the original scene-linear RGB semantics.
## Black disables only this optional artist lobe. Matched atmosphere sunlight
## remains a separate physical directional source. (Unreal: Directional Inscattering Color)
@export var directional_inscattering_color := Color(0.0, 0.0, 0.0):
	set(value):
		directional_inscattering_color = value
		_publish()

@export_group("天空大气环境光")
## Linear RGB scale applied only to Feng Sky atmosphere ambient added to this
## fog. It does not tint the authored base source or directional lobe.
@export var sky_atmosphere_ambient_contribution_color_scale := Color.WHITE:
	set(value):
		sky_atmosphere_ambient_contribution_color_scale = value
		_publish()

@export_group("体积雾 (UE Volumetric Fog)")
## Enables UE-style volumetric fog parameters in the published snapshot.
## The renderer integration consumes this packet separately from height fog.
@export var volumetric_fog_enabled := false:
	set(value):
		volumetric_fog_enabled = value
		_publish()
## Henyey-Greenstein anisotropy: negative is backward scattering, zero is
## isotropic, positive is forward scattering. (Unreal: Scattering Distribution)
@export_range(-0.9, 0.9, 0.01, "or_greater", "or_less") var volumetric_fog_scattering_distribution := 0.2:
	set(value):
		volumetric_fog_scattering_distribution = value
		_publish()
## Authored in sRGB; the render snapshot decodes it to linear RGB like UE's
## FColor-to-FLinearColor conversion. (Unreal: Albedo)
@export var volumetric_fog_albedo := Color.WHITE:
	set(value):
		volumetric_fog_albedo = value
		_publish()
## Linear emitted-light density. The snapshot converts UE's per-centimeter
## scale to Godot's per-meter world. (Unreal: Emissive)
@export var volumetric_fog_emissive := Color.BLACK:
	set(value):
		volumetric_fog_emissive = value
		_publish()
## Scales extinction contributed by the existing height-fog medium.
## (Unreal: Extinction Scale)
@export_range(0.1, 10.0, 0.1, "or_greater") var volumetric_fog_extinction_scale := 1.0:
	set(value):
		volumetric_fog_extinction_scale = value
		_publish()
## Distance after Start Distance, in meters. UE's default is 6000 cm.
## (Unreal: Volumetric Fog Distance)
@export_range(10.0, 100.0, 1.0, "or_greater", "suffix:m") var volumetric_fog_distance := 60.0:
	set(value):
		volumetric_fog_distance = value
		_publish()
## The camera-to-froxel near range, in meters. This is separate from the
## analytic height-fog Start Distance. (Unreal: Start Distance)
@export_range(0.0, 50.0, 1.0, "or_greater", "suffix:m") var volumetric_fog_start_distance := 0.0:
	set(value):
		volumetric_fog_start_distance = value
		_publish()
## Fades integrated volumetric fog in over this distance after Start Distance.
## (Unreal: Near Fade In Distance)
@export_range(0.0, 10.0, 0.1, "or_greater", "suffix:m") var volumetric_fog_near_fade_in_distance := 0.0:
	set(value):
		volumetric_fog_near_fade_in_distance = value
		_publish()
## Scales optional volumetric-lightmap scattering. (Unreal: Static Lighting
## Scattering Intensity)
@export_range(0.0, 10.0, 0.1, "or_greater") var volumetric_fog_static_lighting_scattering_intensity := 1.0:
	set(value):
		volumetric_fog_static_lighting_scattering_intensity = value
		_publish()
## Replaces incoming light colors with this component's fog inscattering color.
## This is an advanced opt-in UE path.
@export var volumetric_fog_override_light_colors_with_fog_inscattering_colors := false:
	set(value):
		volumetric_fog_override_light_colors_with_fog_inscattering_colors = value
		_publish()

@export_subgroup("质量与高级路径")
## Froxel resolution presets match UE scalability: Medium 16x64, High 8x128,
## and Cinematic 4x128 (XY pixels per froxel by depth slices).
@export_enum("Medium", "High", "Cinematic") var volumetric_fog_quality := 0:
	set(value):
		volumetric_fog_quality = clampi(value, 0, 2)
		_publish()
## UE temporal history blend weight (r.VolumetricFog.HistoryWeight defaults to 0.9).
@export_range(0.0, 0.99, 0.01) var volumetric_fog_history_weight := 0.9:
	set(value):
		volumetric_fog_history_weight = value
		_publish()
## UE uses Halton frame jitter by default. Disabling it samples each froxel center.
@export var volumetric_fog_jitter_enabled := true:
	set(value):
		volumetric_fog_jitter_enabled = value
		_publish()
## Automatic follows the quality preset (4 samples on Medium/High, 16 on Cinematic).
## Selecting a count overrides only the history-miss supersampling level.
@export_enum("Automatic:0", "1 sample:1", "4 samples:4", "8 samples:8", "16 samples:16") \
	var volumetric_fog_history_miss_supersample_count := 0:
	set(value):
		volumetric_fog_history_miss_supersample_count = \
				VolumetricFogParameters.normalize_history_miss_override(value)
		_publish()
## Optional hardware shadow provider. Unsupported devices and scenes use the full raster path.
@export var volumetric_fog_ray_traced_shadows_enabled := false:
	set(value):
		volumetric_fog_ray_traced_shadows_enabled = value
		_publish()
## UE r.VolumetricFog.LightSoftFading defaults to zero. A positive value fades
## spot/rect light edges across this many projected froxel radii.
@export_range(0.0, 4.0, 0.1, "or_greater") var volumetric_fog_light_soft_fading := 0.0:
	set(value):
		volumetric_fog_light_soft_fading = maxf(value, 0.0)
		_publish()
## UE r.VolumetricFog.RectLightTexture defaults to disabled. Enable the area
## source atlas multiplier explicitly when matching authored emissive panels.
@export var volumetric_fog_area_light_source_textures_enabled := false:
	set(value):
		volumetric_fog_area_light_source_textures_enabled = value
		_publish()

@export_subgroup("静态体积照明")
## Optional baked probe volume. The supported resource stores volumetric SH9
## probes; ordinary surface LightmapGI textures are not interpreted as VLM data.
@export var baked_irradiance: Resource:
	set(value):
		baked_irradiance = value
		_publish()

@export_subgroup("屏幕空间多重散射 (FSSS, 实验性)")
## UE's separate 2D scene-color scattering approximation; it is independent
## from the 3D volumetric-fog packet. (Unreal: Enable Fog Screen Space Scattering)
@export var fsss_enabled := false:
	set(value):
		fsss_enabled = value
		_publish()
## Scales scene-color injection into the FSSS blur. (Unreal: Scene Color
## Scattering Amount Scale)
@export_range(0.0, 1.0, 0.01, "or_greater") var fsss_scene_color_scattering_amount_scale := 1.0:
	set(value):
		fsss_scene_color_scattering_amount_scale = value
		_publish()
## Exponent applied to FSSS scene-color injection. (Unreal: Scene Color
## Scattering Amount Power)
@export_range(0.01, 2.0, 0.01, "or_greater") var fsss_scene_color_scattering_amount_power := 1.0:
	set(value):
		fsss_scene_color_scattering_amount_power = value
		_publish()
## Scales the blurred mip selected for FSSS. (Unreal: Spread Scale)
@export_range(0.0, 1.0, 0.01, "or_greater") var fsss_spread_scale := 0.1:
	set(value):
		fsss_spread_scale = value
		_publish()
## Controls how strongly lower blurred mips feed sharper mips. (Unreal: Blur
## Control)
@export_range(0.0, 1.0, 0.01) var fsss_blur_control := 0.5:
	set(value):
		fsss_blur_control = value
		_publish()

func _enter_tree() -> void:
	set_notify_transform(true)
	Runtime.register(self)

func _exit_tree() -> void:
	Runtime.unregister(self)

func _process(_delta: float) -> void:
	Runtime.tick()

func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED:
		_publish()

## The camera-independent half of the pass's uniform block, in shader units.
func snapshot_fields() -> Dictionary:
	var height := global_position.y
	var ambient_scale := Vector3.ONE
	var authored_ambient_scale := sky_atmosphere_ambient_contribution_color_scale
	if is_finite(authored_ambient_scale.r) and is_finite(authored_ambient_scale.g) \
			and is_finite(authored_ambient_scale.b):
		ambient_scale = Vector3(sky_atmosphere_ambient_contribution_color_scale.r,
				sky_atmosphere_ambient_contribution_color_scale.g,
				sky_atmosphere_ambient_contribution_color_scale.b).max(Vector3.ZERO)
	var fields := {
		"fog_density": fog_density * UNIT_SCALE,
		"fog_height_falloff": fog_height_falloff * UNIT_SCALE,
		"fog_height": height + fog_height_offset,
		"second_fog_density": second_fog_density * UNIT_SCALE,
		"second_fog_height_falloff": second_fog_height_falloff * UNIT_SCALE,
		"second_fog_height": height + second_fog_height_offset,
		"fog_color": Vector3(fog_inscattering_color.r, fog_inscattering_color.g, fog_inscattering_color.b),
		# Kept separately because the runtime may add FengSky ambient to fog_color;
		# UE's optional volumetric color override uses the component-authored value.
		"artist_fog_inscattering_color": Vector3(fog_inscattering_color.r,
				fog_inscattering_color.g, fog_inscattering_color.b),
		"sky_atmosphere_ambient_contribution_color_scale": ambient_scale,
		"min_opacity": 1.0 - fog_max_opacity,
		"start_distance": start_distance,
		"cutoff_distance": fog_cutoff_distance,
		"sun_direction": Vector3.ZERO,
		"inscattering_color": Vector3(directional_inscattering_color.r,
				directional_inscattering_color.g, directional_inscattering_color.b),
		"artist_directional_inscattering_color": Vector3(directional_inscattering_color.r,
				directional_inscattering_color.g, directional_inscattering_color.b),
		"inscattering_start": directional_inscattering_start_distance,
		"inscattering_exponent": directional_inscattering_exponent,
		"volumetric_fog": VolumetricFogParameters.pack(
				volumetric_fog_enabled,
				volumetric_fog_scattering_distribution,
				volumetric_fog_albedo,
				volumetric_fog_emissive,
				volumetric_fog_extinction_scale,
				volumetric_fog_distance,
				volumetric_fog_start_distance,
				volumetric_fog_near_fade_in_distance,
				volumetric_fog_static_lighting_scattering_intensity,
				volumetric_fog_override_light_colors_with_fog_inscattering_colors,
				volumetric_fog_history_weight,
				volumetric_fog_history_miss_supersample_count,
				volumetric_fog_jitter_enabled,
				volumetric_fog_ray_traced_shadows_enabled,
				volumetric_fog_quality,
				volumetric_fog_light_soft_fading,
				volumetric_fog_area_light_source_textures_enabled),
		"baked_irradiance": baked_irradiance,
		"screen_space_scattering": VolumetricFogParameters.pack_screen_space_scattering(
				fsss_enabled,
				fsss_scene_color_scattering_amount_scale,
				fsss_scene_color_scattering_amount_power,
				fsss_spread_scale,
				fsss_blur_control),
	}
	return fields

func _publish() -> void:
	if is_inside_tree():
		Runtime.publish(self)

func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if fog_density <= 0.0 and second_fog_density <= 0.0:
		warnings.append("两层解析高度雾的密度均为零；已启用的体积雾或本地介质仍可独立生效。")
	return warnings
