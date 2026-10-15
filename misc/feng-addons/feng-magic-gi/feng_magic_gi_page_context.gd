@tool
extends Node3D
## Temporary world-aligned sampling context used by the paged baker.
## It is internal to the scene tree, never owned/saved, and holds no geometry.

var size := Vector3.ONE
var probe_spacing := 1.0
var surface_offset := 0.03
var adaptive_placement := true
var minimum_probe_spacing := 0.25
var bake_distance := 32.0
var clv_cell_size := 0.5
var terrain_reflectance := 0.5
var fallback_material_reflectance := 0.5
var source_volume_transform := Transform3D.IDENTITY
var source_volume_size := Vector3.ONE
var page_core_bounds := AABB()
var page_support_bounds := AABB()
var streamed_page := true

func configure(source: Node, core_bounds: AABB, support_bounds: AABB,
		trace_distance: float) -> void:
	page_core_bounds = core_bounds
	page_support_bounds = support_bounds
	size = support_bounds.size
	probe_spacing = float(source.get("probe_spacing"))
	surface_offset = float(source.get("surface_offset"))
	adaptive_placement = bool(source.get("adaptive_placement"))
	minimum_probe_spacing = float(source.get("minimum_probe_spacing"))
	bake_distance = trace_distance
	clv_cell_size = float(source.get("clv_cell_size"))
	terrain_reflectance = float(source.get("terrain_reflectance"))
	fallback_material_reflectance = float(source.get("fallback_material_reflectance"))
	source_volume_transform = source.global_transform
	source_volume_size = source.get("size")
	set_as_top_level(true)
	global_transform = Transform3D(Basis.IDENTITY, support_bounds.position + support_bounds.size * 0.5)

func grid_dimensions() -> Vector3i:
	return Vector3i((size / maxf(probe_spacing, 0.1)).ceil()).max(Vector3i.ONE)

func cell_size() -> Vector3:
	return size / Vector3(grid_dimensions())

func world_to_grid_transform() -> Transform3D:
	var dimensions := Vector3(grid_dimensions())
	var scale := dimensions / size
	return Transform3D(Basis.from_scale(scale), -global_position * scale + dimensions * 0.5)
