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

## The parameters this volume applies. Without one the volume does nothing.
@export var profile: Profile
## Box extents around the node's origin, in local space.
@export var size := Vector3(10.0, 10.0, 10.0)
## Ignore `size`: an unbound volume affects every camera, like an Unreal post process
## volume with "Unbound" ticked. Use it for a global default.
@export var unbound := false
## Fade the volume in over this distance inside its edges: 0 applies it at full weight
## everywhere inside, otherwise the weight ramps from nothing at the edge to `weight`
## `blend_distance` in. This is Unreal's blend radius.
@export var blend_distance := 0.0
## Volumes are applied in ascending priority, so the highest one wins where they
## overlap. Equal priorities keep scene order.
@export var priority := 0
## How much of this volume is blended in: 0 ignores it, 1 applies it fully. Numeric
## values are interpolated by this, other values are taken from a weight of 0.5 up.
@export_range(0.0, 1.0, 0.01) var weight := 1.0
## Off volumes stay in the scene and stop affecting cameras.
@export var enabled := true

static var _volumes: Array[FengVolume] = []
static var _last_frame := -1
## Compositors this system has pushed overrides to, as weak references, so a volume
## that disappears can clear what it applied to the frames it affected.
static var _pushed: Array = []

func _enter_tree() -> void:
	if not _volumes.has(self):
		_volumes.append(self)

func _exit_tree() -> void:
	_volumes.erase(self)
	# The last volume may just have left: clear whatever it was overriding without
	# waiting for another volume's _process.
	evaluate_all()

func _process(_delta: float) -> void:
	# One evaluation per frame, whichever volume ticks first.
	var frame := Engine.get_process_frames()
	if _last_frame == frame:
		return
	_last_frame = frame
	evaluate_all()

## True when p_point (world space) is inside this volume's box.
func contains_point(p_point: Vector3) -> bool:
	if unbound:
		return true
	if size.x <= 0.0 or size.y <= 0.0 or size.z <= 0.0:
		return false
	var local := global_transform.affine_inverse() * p_point
	return absf(local.x) <= size.x * 0.5 and absf(local.y) <= size.y * 0.5 and absf(local.z) <= size.z * 0.5

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
static func resolve_overrides(p_volumes: Array, p_base: Dictionary, p_point: Vector3) -> Dictionary:
	var ordered := p_volumes.duplicate()
	ordered.sort_custom(func(a, b): return a.priority < b.priority)
	var overrides := {}
	for volume in ordered:
		var blend: float = volume.influence_at(p_point)
		if blend <= 0.0:
			continue
		for pass_id in volume.profile.pass_parameters:
			var values: Variant = volume.profile.pass_parameters[pass_id]
			if values == null or not values is Dictionary:
				continue
			var target: Dictionary = overrides.get(int(pass_id), {})
			for key in values:
				var new_value: Variant = values[key]
				var previous: Variant = target.get(key, null)
				if previous == null:
					var base_values: Variant = p_base.get(int(pass_id), {})
					if base_values is Dictionary:
						previous = base_values.get(key, null)
				if previous != null and _is_number(previous) and _is_number(new_value) and blend < 1.0:
					target[key] = lerpf(float(previous), float(new_value), blend)
				elif blend >= 0.5 or previous == null:
					target[key] = new_value
			overrides[int(pass_id)] = target
	return overrides

static func _is_number(value: Variant) -> bool:
	return value is int or value is float

## Resolves the pass states a camera's volumes switch on or off, in the same order and
## with the same weights as resolve_overrides. A state cannot be interpolated, so a
## volume applies it from half influence up.
static func resolve_pass_states(p_volumes: Array, p_point: Vector3) -> Dictionary:
	var ordered := p_volumes.duplicate()
	ordered.sort_custom(func(a, b): return a.priority < b.priority)
	var states := {}
	for volume in ordered:
		if volume.influence_at(p_point) < 0.5:
			continue
		for pass_id in volume.profile.disabled_passes:
			states[int(pass_id)] = false
		for pass_id in volume.profile.enabled_passes:
			states[int(pass_id)] = true
	return states

## Pushes the resolved overrides of every viewport that has volumes and a camera
## using a FengCompositor, and clears the compositors whose volumes are gone.
static func evaluate_all() -> void:
	if _volumes.is_empty() and _pushed.is_empty():
		return
	var viewports := {}
	for volume in _volumes:
		if not volume.enabled or volume.profile == null or not volume.is_inside_tree() or volume.weight <= 0.0:
			continue
		var viewport := volume.get_viewport()
		if viewport == null:
			continue
		if not viewports.has(viewport):
			viewports[viewport] = []
		viewports[viewport].append(volume)

	var current: Array = []
	for viewport in viewports:
		var camera: Camera3D = viewport.get_camera_3d()
		if camera == null:
			continue
		var compositor = camera.get("compositor")
		if compositor == null or not compositor.has_method("set_volume_parameters"):
			continue
		current.append(weakref(compositor))
		var base := {}
		var renderer = compositor.get("renderer")
		if renderer != null and renderer.has_method("get_authored_pass_parameters"):
			base = renderer.call("get_authored_pass_parameters")
		compositor.call("set_volume_parameters", resolve_overrides(viewports[viewport], base, camera.global_position), resolve_pass_states(viewports[viewport], camera.global_position))

	for reference in _pushed:
		var compositor = reference.get_ref() if reference is WeakRef else reference
		if compositor == null:
			continue
		var still_used := false
		for active in current:
			if active.get_ref() == compositor:
				still_used = true
				break
		if not still_used:
			compositor.call("set_volume_parameters", {}, {})
	_pushed = current
