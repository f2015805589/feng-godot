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
@export_range(0.001, 2.0, 0.001, "or_greater") var fog_height_falloff := 0.2:
	set(value):
		fog_height_falloff = maxf(value, 0.001)
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
@export_range(0.001, 2.0, 0.001, "or_greater") var second_fog_height_falloff := 0.2:
	set(value):
		second_fog_height_falloff = maxf(value, 0.001)
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
		"sky_atmosphere_ambient_contribution_color_scale": ambient_scale,
		"min_opacity": 1.0 - fog_max_opacity,
		"start_distance": start_distance,
		"cutoff_distance": fog_cutoff_distance,
		"sun_direction": Vector3.ZERO,
		"inscattering_color": Vector3(directional_inscattering_color.r,
				directional_inscattering_color.g, directional_inscattering_color.b),
		"inscattering_start": directional_inscattering_start_distance,
		"inscattering_exponent": directional_inscattering_exponent,
	}
	return fields

func _publish() -> void:
	if is_inside_tree():
		Runtime.publish(self)

func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if fog_density <= 0.0 and second_fog_density <= 0.0:
		warnings.append("两层雾的密度都为零，Feng Height Fog 不会改变画面。")
	return warnings
