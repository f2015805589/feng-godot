@tool
class_name FengVolumetricFogVolume
extends Node3D
## World-scoped local medium consumed by Feng Fog's FRP compute service.
## This declared material model is intentionally independent of FogMaterial's
## built-in Environment renderer and does not interpret arbitrary ShaderMaterial.

const Runtime = preload("feng_fog_runtime.gd")

enum Shape {
	BOX,
	ELLIPSOID,
	CYLINDER,
	CONE,
	WORLD,
}

@export var enabled := true:
	set(value):
		enabled = value
		_publish()

@export var shape: Shape = Shape.BOX:
	set(value):
		shape = value
		_publish()

## Local-space full dimensions, in meters. Node transform scale also applies.
@export var size_m := Vector3(10.0, 10.0, 10.0):
	set(value):
		size_m = value
		_publish()

## Extinction coefficient in inverse meters before the material scale.
@export_range(0.0, 10.0, 0.01, "or_greater") var density_per_m := 0.1:
	set(value):
		density_per_m = value
		_publish()

## Linear scattering albedo for this volume's independent medium contribution.
## The renderer clamps the channels to [0, 1], matching UE's UNorm8 payload.
@export var albedo := Color.WHITE:
	set(value):
		albedo = value
		_publish()

## Independent linear HDR emitted source per meter. It is not multiplied by density.
@export var emissive_per_m := Color.BLACK:
	set(value):
		emissive_per_m = value
		_publish()

@export_range(0.0, 10.0, 0.01, "or_greater") var extinction_scale := 1.0:
	set(value):
		extinction_scale = value
		_publish()

## Optional local-up exponential density decrease. Zero means uniform density.
@export_range(0.0, 10.0, 0.01, "or_greater") var height_falloff_per_m := 0.0:
	set(value):
		height_falloff_per_m = value
		_publish()

## Softens the shape boundary in local meters; zero gives a hard boundary.
@export_range(0.0, 20.0, 0.01, "or_greater", "suffix:m") var edge_fade_m := 0.0:
	set(value):
		edge_fade_m = value
		_publish()

## Optional 3D scalar density/noise texture. The red channel multiplies density.
@export var density_texture: Texture3D:
	set(value):
		density_texture = value
		_publish()


func _enter_tree() -> void:
	set_notify_transform(true)
	Runtime.register_volume(self)


func _exit_tree() -> void:
	Runtime.unregister_volume(self)


func _process(_delta: float) -> void:
	Runtime.tick()


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED:
		_publish()


func snapshot_fields() -> Dictionary:
	var safe_size := size_m.abs()
	if not safe_size.is_finite():
		safe_size = Vector3(10.0, 10.0, 10.0)
	var safe_albedo := _linear_albedo(albedo, Color.WHITE)
	var safe_emissive := _linear_emissive(emissive_per_m, Color.BLACK)
	var safe_transform := global_transform
	if not safe_transform.is_finite():
		safe_transform = Transform3D.IDENTITY
	return {
		"volume_id": get_instance_id(),
		"enabled": enabled,
		"shape": int(shape),
		"transform": safe_transform,
		"size_m": safe_size.max(Vector3(0.001, 0.001, 0.001)),
		"density_per_m": _finite_clamp(density_per_m, 0.0, 10000.0, 0.1),
		"albedo": Vector3(safe_albedo.r, safe_albedo.g, safe_albedo.b).clamp(Vector3.ZERO, Vector3.ONE),
		"emissive_per_m": Vector3(safe_emissive.r, safe_emissive.g, safe_emissive.b),
		"extinction_scale": _finite_clamp(extinction_scale, 0.0, 10000.0, 1.0),
		"height_falloff_per_m": _finite_clamp(height_falloff_per_m, 0.0, 1000.0, 0.0),
		"edge_fade_m": _finite_clamp(edge_fade_m, 0.0, 10000.0, 0.0),
		"density_texture": density_texture,
	}


func _publish() -> void:
	if is_inside_tree():
		Runtime.publish_volume(self)


func _linear_albedo(value: Color, fallback: Color) -> Color:
	if not is_finite(value.r) or not is_finite(value.g) or not is_finite(value.b):
		return fallback
	return Color(clampf(value.r, 0.0, 1.0), clampf(value.g, 0.0, 1.0),
			clampf(value.b, 0.0, 1.0), 1.0)


func _linear_emissive(value: Color, fallback: Color) -> Color:
	if not is_finite(value.r) or not is_finite(value.g) or not is_finite(value.b):
		return fallback
	# Keep authored HDR values while bounding them to the half-float range used by
	# the medium and integrated scattering textures.
	return Color(clampf(value.r, 0.0, 65504.0), clampf(value.g, 0.0, 65504.0),
			clampf(value.b, 0.0, 65504.0), 1.0)


func _finite_clamp(value: float, minimum: float, maximum: float, fallback: float) -> float:
	return clampf(value, minimum, maximum) if is_finite(value) else fallback
