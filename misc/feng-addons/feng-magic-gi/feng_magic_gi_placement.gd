@tool
class_name FMagicGIPlacement
extends RefCounted
## Decides which probes of a volume's grid are worth baking.
##
## A probe is live when it is not buried inside geometry AND has geometry
## within reach - the only probes a surface can ever trilinearly sample are
## the corners of its own cell, so probes floating far from everything can
## never contribute and are culled instead of baked. The grid itself stays
## dense: culling is expressed as a dense mask plus a slot remap, keeping the
## shader's index math unchanged.
##
## Two detectors run per probe, deliberately independent:
##  - Terrain3D nodes answer the buried/near-terrain tests through
##    `data.get_height` (NAN outside their regions), no colliders needed.
##  - every other shape answers through the physics space: a probe is buried
##    when a ray straight up exits through an upward-facing surface (a floor
##    above it) anywhere within the volume's own extent - that holds for
##    closed meshes and for terrain's surface-style heightfield alike - and
##    is near geometry when a coverage sphere touches any collider.
## With neither detector present the mask falls back to all-live: a volume in
## open sky still needs its probes to capture the ambient field.

## Detectors never consider a probe buried when it sits less than this fraction
## of the smallest cell spacing under the terrain surface.
const BURIED_DEPTH := 0.3
## A face counts as a floor above the probe when its normal is this close to up.
const FLOOR_NORMAL_Y := 0.6

## Axis-aligned cell spacing of the probe grid in world units.
static func cell_spacing(volume: FMagicGIVolume) -> Vector3:
	var scale := volume.global_transform.basis.get_scale().abs()
	return volume.cell_size() * scale

## Dense mask in bake index order: 1 = live probe, 0 = culled.
static func classify(volume: FMagicGIVolume) -> PackedByteArray:
	var positions := volume.probe_positions
	var mask := PackedByteArray()
	mask.resize(positions.size())
	if positions.is_empty() or not volume.is_inside_tree():
		return mask

	if volume.bake_coverage <= 0.0:
		mask.fill(1)
		return mask

	var spacing := cell_spacing(volume)
	var min_spacing := minf(spacing.x, minf(spacing.y, spacing.z))
	var reach := maxf(spacing.x, maxf(spacing.y, spacing.z)) * volume.bake_coverage
	var bury := min_spacing * BURIED_DEPTH
	# A probe is "inside geometry" only when a floor still exists above it
	# within the volume's own extent; deeper open space is a cave, not burial.
	var bury_reach := volume.size.length()

	var terrains := _find_terrains(volume)
	var space := volume.get_world_3d().direct_space_state
	var reach_query: PhysicsShapeQueryParameters3D = null
	if space != null:
		var reach_sphere := SphereShape3D.new()
		reach_sphere.radius = reach
		reach_query = PhysicsShapeQueryParameters3D.new()
		reach_query.shape = reach_sphere

	for i in positions.size():
		var pos := positions[i]
		var near := false
		var buried := false
		for terrain in terrains:
			var h: float = terrain.get("data").get_height(pos)
			if is_nan(h):
				continue
			if pos.y < h - bury:
				buried = true
				break
			if pos.y - h <= reach:
				near = true
		if not buried and space != null:
			# Ray up hits the first surface above: an upward-facing hit means a
			# floor over the probe, i.e. it sits in or below solid geometry.
			# A downward-facing hit is a ceiling/overhang - open space below it.
			var up_query := PhysicsRayQueryParameters3D.create(
					pos, pos + Vector3.UP * bury_reach)
			var hit := space.intersect_ray(up_query)
			if not hit.is_empty() and hit["normal"].y > FLOOR_NORMAL_Y:
				buried = true
		if buried:
			continue
		if not near and reach_query != null:
			reach_query.transform = Transform3D(Basis.IDENTITY, pos)
			near = not space.intersect_shape(reach_query, 1).is_empty()
		mask[i] = 1 if near else 0

	if mask.count(1) == 0:
		# Nothing detected geometry at all (no terrain, no colliders): bake the
		# whole grid so the volume still produces a usable ambient field.
		mask.fill(1)
	return mask

## Dense probe index -> slot in the sparse SH table, or -1 for culled probes.
static func build_slot_map(mask: PackedByteArray) -> PackedInt32Array:
	var slots := PackedInt32Array()
	slots.resize(mask.size())
	var slot := 0
	for i in mask.size():
		if mask[i] != 0:
			slots[i] = slot
			slot += 1
		else:
			slots[i] = -1
	return slots

static func live_count(mask: PackedByteArray) -> int:
	return mask.count(1)

## Terrain3D nodes sharing the volume's scene. Duck-typed by class name and the
## data resource so this addon keeps working when the terrain extension is off.
static func _find_terrains(volume: FMagicGIVolume) -> Array[Node]:
	var found: Array[Node] = []
	# The scene containing the volume: editor's edited scene, the runtime
	# current scene, or whatever subtree the volume was spawned into.
	var root: Node = volume
	while root.get_parent() != null and not (root.get_parent() is Viewport):
		root = root.get_parent()
	_collect_terrains(root, found)
	return found

static func _collect_terrains(node: Node, found: Array[Node]) -> void:
	if node.is_class("Terrain3D") and node.get("data") != null:
		found.append(node)
	for child in node.get_children():
		_collect_terrains(child, found)
