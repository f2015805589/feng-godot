@tool
class_name FMagicGIVolume
extends Node3D
## Places a regular grid of GI probes inside a box and owns their baked SH data.
##
## Probe layout: `probe_dims` probes per axis spanning `size`, edge probes
## included, so probe (i,j,k) sits at local position
## (i/(dims.x-1)-0.5, j/(dims.y-1)-0.5, k/(dims.z-1)-0.5) * size.
## The box is centered on the node and moves with its transform, so the baked
## light follows the volume.
##
## Baking runs in the editor (the "Bake Probes" inspector button, or `bake()`):
## each probe captures a small cubemap of the surrounding scene and projects it
## onto 9 spherical-harmonic coefficients per channel. The FRP "Magic GI" pass
## picks the result up through FMagicGIRuntime.

const Runtime = preload("feng_magic_gi_runtime.gd")
const Baker = preload("feng_magic_gi_baker.gd")
const Viz = preload("feng_magic_gi_viz.gd")
const Data = preload("feng_magic_gi_data.gd")

static var _bake_counter := 0

## Box extents around the node's origin, in local space.
@export var size := Vector3(10.0, 10.0, 10.0):
	set(value):
		size = value
		_rebuild_probes()
		Runtime.publish(self)
## Probes per axis. Set an axis to 1 for a flat single-probe layer.
@export var probe_dims := Vector3i(4, 4, 4):
	set(value):
		probe_dims = value.clampi(1, 64)
		_rebuild_probes()
		# Re-dimming invalidates the current bake (has_bake() checks dims), so the
		# runtime is republished: the stale field must stop feeding the pipeline.
		Runtime.publish(self)
## Cubemap edge length in pixels captured per probe face at bake time.
@export var bake_resolution := 32:
	set(value):
		bake_resolution = clampi(value, 8, 512)
## Probe culling reach, in cell spacings: bake keeps only probes within this
## distance of geometry and drops probes buried in terrain or inside
## colliders. 0 bakes the full grid.
@export var bake_coverage := 1.5:
	set(value):
		bake_coverage = maxf(value, 0.0)
## Extra intensity applied to the indirect light this volume contributes.
@export var gi_strength := 1.0:
	set(value):
		gi_strength = value
		Runtime.publish(self)
## Draw a small sphere at every probe position.
@export var show_probes := true:
	set(value):
		show_probes = value
		_refresh_viz()
## Reconstruct each probe's SH as a colored radial mesh. Capped at
## MAX_SH_VIZ_PROBES probes; a dense volume keeps its sphere markers.
@export var show_sh_probes := false:
	set(value):
		show_sh_probes = value
		_refresh_viz()
## Off volumes keep their bake but stop feeding the pipeline.
@export var enabled := true:
	set(value):
		enabled = value
		Runtime.publish(self)
## The most recent bake; assigned by bake(), persisted with the scene.
@export var bake_data: Data:
	set(value):
		bake_data = value
		_refresh_viz()
		Runtime.publish(self)

## World-space probe positions in bake order (index = ix + iy*dims.x + iz*dims.x*dims.y).
var probe_positions := PackedVector3Array()

var _viz: Node3D
var _viz_queued := false
var _baking := false

func _enter_tree() -> void:
	set_notify_transform(true)
	Runtime.register(self)
	_rebuild_probes()

func _exit_tree() -> void:
	Runtime.unregister(self)

## A bake counts only while it still describes the current probe grid: resizing
## or re-dimming after baking leaves a valid resource that no longer applies,
## so callers must not sample it as if it were this volume's field.
func has_bake() -> bool:
	return bake_data != null and bake_data.fits(probe_dims)

func probe_count() -> int:
	return probe_positions.size()

## Editor bake: captures the scene into every probe and stores the SH table.
## Callable from GDScript too (it awaits frames, so call it without awaiting if
## fire-and-forget). Returns true when a bake actually ran.
func bake() -> bool:
	if not is_inside_tree() or _baking:
		return false
	_baking = true
	# The probe captures render this world too; the debug meshes would bake
	# themselves into the field, so the viz is hidden for the run.
	var viz_was_visible := false
	if _viz != null:
		viz_was_visible = _viz.visible
		_viz.visible = false
	var baker := Baker.new()
	var data := await baker.bake_volume(self)
	if _viz != null:
		_viz.visible = viz_was_visible
	_baking = false
	if data == null:
		_refresh_viz()
		return false
	_bake_counter += 1
	data.bake_version = _bake_counter
	bake_data = data
	return true

func _rebuild_probes() -> void:
	probe_positions.clear()
	if not is_inside_tree():
		return
	var dims := probe_dims
	var count := dims.x * dims.y * dims.z
	probe_positions.resize(count)
	var index := 0
	for iz in dims.z:
		for iy in dims.y:
			for ix in dims.x:
				var local := Vector3(
					_axis_frac(ix, dims.x) * size.x,
					_axis_frac(iy, dims.y) * size.y,
					_axis_frac(iz, dims.z) * size.z)
				probe_positions[index] = global_transform * local
				index += 1
	_refresh_viz()

static func _axis_frac(i: int, axis_dims: int) -> float:
	if axis_dims <= 1:
		return 0.0
	return float(i) / float(axis_dims - 1) - 0.5

## Probe spacing in volume-local units (edge probes span `size`, so the grid
## has dims-1 cells per axis). Multiply by the world scale for world units.
func cell_size() -> Vector3:
	var dims := probe_dims
	return Vector3(
			size.x / maxf(dims.x - 1.0, 1.0),
			size.y / maxf(dims.y - 1.0, 1.0),
			size.z / maxf(dims.z - 1.0, 1.0))

## The transform the shader uses: world -> probe-grid index space.
func world_to_grid_transform() -> Transform3D:
	var dims := Vector3(probe_dims)
	var scale := Vector3(
			maxf(dims.x - 1.0, 1.0) / maxf(size.x, 0.001),
			maxf(dims.y - 1.0, 1.0) / maxf(size.y, 0.001),
			maxf(dims.z - 1.0, 1.0) / maxf(size.z, 0.001))
	var local_to_grid := Transform3D(Basis.from_scale(scale), scale * (size * 0.5))
	return local_to_grid * global_transform.affine_inverse()

func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED:
		# Probe positions are stored in world space; keep them (and the baked
		# field's transform) glued to the volume.
		_rebuild_probes()
		if has_bake():
			bake_data.volume_transform = global_transform
			bake_data.world_to_grid = world_to_grid_transform()
			Runtime.publish(self)

## Viz rebuilds are deferred and coalesced: transform notifications and
## property edits can fire many times a frame while dragging the volume, and
## each rebuild is O(probes).
func _refresh_viz() -> void:
	if _viz_queued or not is_inside_tree() or not Engine.is_editor_hint():
		return
	_viz_queued = true
	call_deferred("_apply_viz")

func _apply_viz() -> void:
	_viz_queued = false
	if not is_inside_tree() or not Engine.is_editor_hint() or _baking:
		return
	if _viz == null:
		_viz = Viz.build(self)
		add_child(_viz, false, INTERNAL_MODE_BACK)
	else:
		Viz.rebuild(self, _viz)
