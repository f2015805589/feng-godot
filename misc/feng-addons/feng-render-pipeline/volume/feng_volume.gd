@tool
class_name FengVolume
extends Node3D
## A box that overrides FRP pass parameters while the active camera is inside it.
##
## The volumes in a viewport are resolved once per frame, lowest priority first, each
## one blended in by its weight, and the result is pushed to the camera's
## FengCompositor. The compositor hands it to the renderer, which layers it over the
## parameters the pass scripts and the entries author, so a volume is the runtime
## override (see FengVolumeProfile).
##
## The box is centered on the node and sized by `size` in the node's local space, so
## rotating or scaling the node moves the region with it.

const Profile = preload("feng_volume_profile.gd")
const Resolver = preload("volume_resolver.gd")
const Runtime = preload("volume_runtime.gd")

## The parameters this volume applies. Without one the volume does nothing.
@export var profile: Profile
## Box extents around the node's origin, in local space.
@export var size := Vector3(10.0, 10.0, 10.0):
	set(value):
		size = value
		_queue_gizmo_redraw()
## Ignore `size`: an unbound volume affects every camera, like an Unreal post process
## volume with "Unbound" ticked. Use it for a global default.
@export var unbound := false:
	set(value):
		unbound = value
		_queue_gizmo_redraw()
## Fade the volume in over this distance inside its edges: 0 applies it at full weight
## everywhere inside, otherwise the weight ramps from nothing at the edge to `weight`
## `blend_distance` in. This is Unreal's blend radius.
@export var blend_distance := 0.0:
	set(value):
		blend_distance = value
		_queue_gizmo_redraw()
## Volumes are applied in ascending priority, so the highest one wins where they
## overlap. Equal priorities keep scene order.
@export var priority := 0
## How much of this volume is blended in: 0 ignores it, 1 applies it fully. Numeric
## values are interpolated by this, other values are taken from a weight of 0.5 up.
@export_range(0.0, 1.0, 0.01) var weight := 1.0
## Off volumes stay in the scene and stop affecting cameras.
@export var enabled := true

func _enter_tree() -> void:
	Runtime.register(self)

func _exit_tree() -> void:
	Runtime.unregister(self)

func _process(_delta: float) -> void:
	Runtime.tick()

## Cheap spatial/profile key; schema reflection stays out of stationary frames.
func evaluation_key() -> Array:
	return [get_instance_id(), global_transform, size, unbound, blend_distance, priority,
			weight, enabled, profile.evaluation_key() if profile != null else null]

## True when p_point (world space) is inside this volume's box.
func contains_point(p_point: Vector3) -> bool:
	if unbound:
		return true
	if size.x <= 0.0 or size.y <= 0.0 or size.z <= 0.0:
		return false
	var local := global_transform.affine_inverse() * p_point
	return absf(local.x) <= size.x * 0.5 and absf(local.y) <= size.y * 0.5 and absf(local.z) <= size.z * 0.5

## Local-space size of the finite box's influence-0 boundary. The runtime influence
## reaches zero at these faces and is zero outside them.
func get_influence_zero_size() -> Vector3:
	return size if size.x > 0.0 and size.y > 0.0 and size.z > 0.0 else Vector3.ZERO

## Local-space size of the box where the normalized influence reaches 1. The runtime
## fade is measured inward from the influence-0 faces, so each axis is inset by twice
## `blend_distance`. If the fade is wider than an axis, no influence-1 box exists on
## that axis and the corresponding extent collapses to zero.
func get_influence_one_size() -> Vector3:
	var zero_size := get_influence_zero_size()
	if zero_size == Vector3.ZERO:
		return Vector3.ZERO
	var inset := maxf(blend_distance, 0.0) * 2.0
	return Vector3(
		maxf(zero_size.x - inset, 0.0),
		maxf(zero_size.y - inset, 0.0),
		maxf(zero_size.z - inset, 0.0)
	)

func _queue_gizmo_redraw() -> void:
	if Engine.is_editor_hint() and is_inside_tree():
		update_gizmos()

## How strongly this volume affects a camera at p_point: 0 outside, `weight` deep
## inside, and a ramp over `blend_distance` near the edges.
func influence_at(p_point: Vector3) -> float:
	if not enabled or profile == null or weight <= 0.0:
		return 0.0
	if unbound:
		return weight
	if size.x <= 0.0 or size.y <= 0.0 or size.z <= 0.0:
		return 0.0
	var local := global_transform.affine_inverse() * p_point
	var half := size * 0.5
	# Signed distance to the nearest face: negative inside, positive outside.
	var distance_to_face := maxf(maxf(absf(local.x) - half.x, absf(local.y) - half.y), absf(local.z) - half.z)
	if distance_to_face > 0.0:
		return 0.0
	if blend_distance <= 0.0:
		return weight
	return weight * clampf(-distance_to_face / blend_distance, 0.0, 1.0)

## Resolves the override for one camera position: the volumes affecting it, blended in
## order. `p_base` is what the renderer authored, used as the starting value for
## numeric blending, and only the resulting overrides are returned so the renderer can
## tell volume values apart from authored ones.
static func resolve_overrides(p_volumes: Array, p_base: Dictionary, p_point: Vector3, p_schema: Dictionary = {}, p_aliases: Dictionary = {}) -> Dictionary:
	return Resolver.parameters(p_volumes, p_base, p_point, p_schema, p_aliases)

static func resolve_pass_states(p_volumes: Array, p_point: Vector3) -> Dictionary:
	return Resolver.pass_states(p_volumes, p_point)

## Compatibility entry points. Registration and camera lifecycle belong to the
## runtime service; the node owns only its authored region and spatial influence.
static func evaluate_all() -> void:
	Runtime.evaluate_all()

static func evaluate_camera(p_volumes: Array, p_camera: Camera3D, p_compositor: FengCompositor) -> void:
	Runtime.evaluate_camera(p_volumes, p_camera, p_compositor)

static func get_scene_volumes(p_root: Node) -> Array:
	return Runtime.get_scene_volumes(p_root)
