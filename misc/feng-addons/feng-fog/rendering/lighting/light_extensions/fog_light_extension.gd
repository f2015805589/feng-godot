@tool
class_name FFogLightExtension
extends Node
## Optional FRP-only per-light controls. This node is attached beside its
## Light3D and is resolved by RID; it never changes the Light3D resource.

const Registry = preload("fog_light_extension_registry.gd")
const Layout = preload("fog_light_extension_layout.gd")
const MAX_COOKIE_SPOT_ANGLE_DEGREES := 89.9

enum CookieMapping {
	AUTO,
	DIRECTIONAL_ORTHOGRAPHIC,
	SPOT_PERSPECTIVE,
	OMNI_DUAL_PARABOLOID,
	AREA_PLANE,
}

enum VolumetricShadowPolicy {
	INHERIT_NATIVE,
	DISABLED,
	HARDWARE_RT_OPT_IN,
}

signal extension_changed(light_rid: RID, revision: int)

@export_node_path("Light3D") var light_path := NodePath(".."):
	set(value):
		if light_path == value:
			return
		light_path = value
		_touch()
		if is_inside_tree():
			call_deferred("_refresh_registration")

@export_group("Light Function")
## A light-function cookie is disabled by default. A white neutral sample is
## used whenever this is disabled, missing, or unavailable in the RD cache.
@export var light_function_enabled := false:
	set(value):
		if light_function_enabled == value:
			return
		light_function_enabled = value
		_touch()

@export var light_function_texture: Texture2D:
	set(value):
		if light_function_texture == value:
			return
		_disconnect_texture_signal(light_function_texture)
		light_function_texture = value
		_connect_texture_signal(light_function_texture)
		_touch()

## Linear blend from neutral white (0) to the sampled linear cookie (1).
@export_range(0.0, 1.0, 0.01) var light_function_strength := 0.0:
	set(value):
		var normalized := clampf(value, 0.0, 1.0)
		if is_equal_approx(light_function_strength, normalized):
			return
		light_function_strength = normalized
		_touch()

## AUTO selects the projection matching the associated native light type.
@export_enum("Automatic", "Directional Orthographic", "Spot Perspective",
		"Omni Dual Paraboloid", "Area Plane") var cookie_mapping: int = CookieMapping.AUTO:
	set(value):
		if cookie_mapping == value:
			return
		cookie_mapping = value
		_touch()

## Zero uses the light's native range, except directional lights where it uses
## 100 m. Directional cookies treat this as the orthographic half-width.
@export_range(0.0, 10000.0, 0.1, "or_greater", "suffix:m") var mapping_range_m := 0.0:
	set(value):
		var normalized := maxf(value, 0.0)
		if is_equal_approx(mapping_range_m, normalized):
			return
		mapping_range_m = normalized
		_touch()

@export var mapping_scale := Vector2.ONE:
	set(value):
		if mapping_scale == value:
			return
		mapping_scale = value
		_touch()

@export var mapping_offset := Vector2.ZERO:
	set(value):
		if mapping_offset == value:
			return
		mapping_offset = value
		_touch()

@export var light_function_srgb := true:
	set(value):
		if light_function_srgb == value:
			return
		light_function_srgb = value
		_touch()

@export_group("Volumetric Shadows")
@export_enum("Inherit native shadow", "Disable volumetric shadow", "Request hardware RT")
var volumetric_shadow_policy: int = VolumetricShadowPolicy.INHERIT_NATIVE:
	set(value):
		if volumetric_shadow_policy == value:
			return
		volumetric_shadow_policy = value
		_touch()

@export_group("Baked Volumetric Lighting")
## Stable key used only to match this directional light with decoded static
## VLM direct-light/shadow data. It does not alter the 144-byte light record.
@export var static_lighting_key: StringName = &"":
	set(value):
		if static_lighting_key == value:
			return
		static_lighting_key = value
		_touch()

@export_group("Area Light Barn Doors")
## UE's shared four-sided barn-door angle; only used for AreaLight3D. UE clamps
## this to 0..88 degrees and defaults to 88 (effectively open).
@export_range(0.0, 88.0, 0.1, "suffix:°") var barn_door_angle_degrees := 88.0:
	set(value):
		var normalized := clampf(value, 0.0, 88.0)
		if is_equal_approx(barn_door_angle_degrees, normalized):
			return
		barn_door_angle_degrees = normalized
		_touch()

## UE authors this in centimeters; this addon stores and publishes meters.
@export_range(0.0, 10000.0, 0.1, "or_greater", "suffix:m") var barn_door_length_m := 0.2:
	set(value):
		var normalized := maxf(value, 0.0)
		if is_equal_approx(barn_door_length_m, normalized):
			return
		barn_door_length_m = normalized
		_touch()

@export_group("Capsule Source")
## Optional UE-style line-source length. This is explicit metadata and is not
## inferred from Light3D.size, which controls Godot's source/soft-shadow size.
@export_range(0.0, 10000.0, 0.01, "or_greater", "suffix:m") var source_length_m := 0.0:
	set(value):
		var normalized := maxf(value, 0.0)
		if is_equal_approx(source_length_m, normalized):
			return
		source_length_m = normalized
		_touch()

## The selected local axis is transformed by the light's orthonormal basis.
@export_enum("Local X", "Local Y", "Local Z") var capsule_axis_local: int = 1:
	set(value):
		var normalized := clampi(value, 0, 2)
		if capsule_axis_local == normalized:
			return
		capsule_axis_local = normalized
		_touch()

var _revision := 1
var _texture_revision := 1
var _registered_world_id := 0
var _registered_light_rid := RID()


func _enter_tree() -> void:
	_refresh_registration()


func _exit_tree() -> void:
	_unregister()


## Call after mutating the contents of an ImageTexture in place. Resource.changed
## is also observed when the source emits it.
func mark_light_function_texture_changed() -> void:
	_texture_revision += 1
	if _texture_revision <= 0:
		_texture_revision = 1
	_touch()


func get_target_light() -> Light3D:
	var target := get_node_or_null(light_path)
	return target as Light3D


## Main-thread only. The result contains only scalar/vector/transform values and
## RIDs; no Node or Resource reference is handed to a rendering callback.
func snapshot_for_light(p_expected_world_id: int, p_expected_light_rid: RID,
		p_native_kind: int) -> Dictionary:
	var light := get_target_light()
	if light == null or not light.is_inside_tree() or not p_expected_light_rid.is_valid():
		return {}
	var world := light.get_world_3d()
	if world == null or world.get_instance_id() != p_expected_world_id \
			or light.get_base() != p_expected_light_rid:
		return {}
	var mapping := _resolve_mapping(p_native_kind)
	var range_m := _resolve_mapping_range(light)
	var tan_half_spot := 0.0
	if light is SpotLight3D:
		tan_half_spot = _spot_angle_tangent_for_cookie((light as SpotLight3D).spot_angle)
	var half_area := Vector2.ZERO
	if light is AreaLight3D:
		half_area = (light as AreaLight3D).area_size * 0.5
	var light_transform := Transform3D(light.global_transform.basis.orthonormalized(),
			light.global_transform.origin)
	var transform := light_transform.affine_inverse()
	if not transform.is_finite() or absf(transform.basis.determinant()) <= 0.00000001:
		return {}
	var cookie_strength := light_function_strength if light_function_enabled else 0.0
	var cookie_rd_rid := RID()
	var cookie_resource_id := 0
	if cookie_strength > 0.0 and light_function_texture != null \
			and is_instance_valid(light_function_texture):
		cookie_resource_id = light_function_texture.get_instance_id()
		cookie_rd_rid = RenderingServer.texture_get_rd_texture(
				light_function_texture.get_rid(), light_function_srgb)
	return {
		"valid": true,
		"abi_version": Layout.ABI_VERSION,
		"world_id": p_expected_world_id,
		"light_rid": p_expected_light_rid,
		"native_kind": p_native_kind,
		"source_extension_id": get_instance_id(),
		"source_revision": _revision,
		"cookie_texture_rd_rid": cookie_rd_rid,
		"cookie_texture_resource_id": cookie_resource_id,
		"cookie_texture_revision": _texture_revision,
		"cookie_srgb": light_function_srgb,
		"cookie_strength": cookie_strength,
		"mapping_type": mapping,
		"mapping_range_m": range_m,
		"tan_half_spot_angle": tan_half_spot,
		"area_half_size_m": half_area,
		"mapping_scale": mapping_scale,
		"mapping_offset": mapping_offset,
		"world_to_light": transform,
		"barn_door_enabled": light is AreaLight3D and barn_door_length_m > 0.0 \
				and barn_door_angle_degrees < 88.0,
		"barn_door_cos_angle": cos(deg_to_rad(barn_door_angle_degrees)),
		"barn_door_length_m": barn_door_length_m,
		"source_length_m": source_length_m,
		"capsule_axis_local": capsule_axis_local,
		"shadow_policy": volumetric_shadow_policy,
		"static_lighting_key": String(static_lighting_key),
	}


## Godot's spot_angle is already the cone half-angle. Keep the perspective
## mapping finite at the 90-degree tangent pole; wider native cones use the
## broadest representable cookie projection.
static func _spot_angle_tangent_for_cookie(p_spot_angle_degrees: float) -> float:
	if not is_finite(p_spot_angle_degrees):
		return 0.0
	var safe_angle_degrees := clampf(p_spot_angle_degrees, 0.0,
			MAX_COOKIE_SPOT_ANGLE_DEGREES)
	var tangent := tan(deg_to_rad(safe_angle_degrees))
	return tangent if is_finite(tangent) and tangent >= 0.0 else 0.0


func _resolve_mapping(p_native_kind: int) -> int:
	if cookie_mapping != CookieMapping.AUTO:
		return cookie_mapping
	match p_native_kind:
		Layout.KIND_DIRECTIONAL:
			return CookieMapping.DIRECTIONAL_ORTHOGRAPHIC
		Layout.KIND_SPOT:
			return CookieMapping.SPOT_PERSPECTIVE
		Layout.KIND_OMNI:
			return CookieMapping.OMNI_DUAL_PARABOLOID
		Layout.KIND_AREA:
			return CookieMapping.AREA_PLANE
	return CookieMapping.AUTO


func _resolve_mapping_range(p_light: Light3D) -> float:
	if mapping_range_m > 0.0:
		return mapping_range_m
	if p_light is OmniLight3D:
		return (p_light as OmniLight3D).omni_range
	if p_light is SpotLight3D:
		return (p_light as SpotLight3D).spot_range
	if p_light is AreaLight3D:
		return (p_light as AreaLight3D).area_range
	return 100.0


func _refresh_registration() -> void:
	_unregister()
	var light := get_target_light()
	if light == null or not light.is_inside_tree():
		return
	var world := light.get_world_3d()
	var light_rid := light.get_base()
	if world == null or not light_rid.is_valid():
		return
	var world_id := world.get_instance_id()
	if Registry.register_extension(self, world_id, light_rid):
		_registered_world_id = world_id
		_registered_light_rid = light_rid


func _unregister() -> void:
	if _registered_world_id != 0 and _registered_light_rid.is_valid():
		Registry.unregister_extension(self, _registered_world_id, _registered_light_rid)
	_registered_world_id = 0
	_registered_light_rid = RID()


func _touch() -> void:
	_revision += 1
	if _revision <= 0:
		_revision = 1
	if is_inside_tree():
		var light := get_target_light()
		if light != null and light.is_inside_tree():
			var world := light.get_world_3d()
			if world != null:
				extension_changed.emit(light.get_base(), _revision)


func _connect_texture_signal(p_texture: Texture2D) -> void:
	if p_texture != null and is_instance_valid(p_texture) \
			and not p_texture.changed.is_connected(_on_texture_changed):
		p_texture.changed.connect(_on_texture_changed)


func _disconnect_texture_signal(p_texture: Texture2D) -> void:
	if p_texture != null and is_instance_valid(p_texture) \
			and p_texture.changed.is_connected(_on_texture_changed):
		p_texture.changed.disconnect(_on_texture_changed)


func _on_texture_changed() -> void:
	mark_light_function_texture_changed()

