@tool
extends RefCounted
## Bounded world-cell storage and clipmap metadata for the live Surfel fallback.

const PROBE_COUNT := 3 * 8 * 8 * 8
const RECORD_BYTES := 176
const CONFIG_BYTES := 80
const CLIP_LEVELS := 3
const CLIP_SIZE := 8

var rd: RenderingDevice
var error := ""
var records := RID()
var config := RID()
var _owned: Array[RID] = []


func initialize(device: RenderingDevice) -> bool:
	if device == null:
		return _fail("Probe field RenderingDevice is unavailable")
	if rd == device and records.is_valid() and config.is_valid():
		return true
	release()
	rd = device
	error = ""
	records = rd.storage_buffer_create(PROBE_COUNT * RECORD_BYTES)
	config = rd.uniform_buffer_create(CONFIG_BYTES)
	_owned = [records, config]
	for rid in _owned:
		if not rid.is_valid():
			release()
			return _fail("Probe field bounded storage allocation failed")
	if rd.buffer_clear(records, 0, PROBE_COUNT * RECORD_BYTES) != OK:
		release()
		return _fail("Probe field initialization failed")
	return true


## Centers each level on the camera clamped to this volume. The cell tags use
## absolute world cells, while the fixed slot index is a modulo-8 torus.
func configure(owner_transform: Transform3D, owner_size: Vector3,
		camera_transform: Transform3D, surfel_radius: float,
		configured_updates: int, effective_updates: int, probe_ray_budget: int,
		rays_per_surfel: int, enabled: bool) -> bool:
	if rd == null or not records.is_valid() or not config.is_valid():
		return _fail("Probe field resources are unavailable")
	if not owner_size.is_finite() or owner_size.x <= 0.0 or owner_size.y <= 0.0 or owner_size.z <= 0.0 \
			or not owner_transform.origin.is_finite() \
			or not owner_transform.basis.x.is_finite() \
			or not owner_transform.basis.y.is_finite() \
			or not owner_transform.basis.z.is_finite() \
			or not camera_transform.origin.is_finite():
		return _fail("Probe field volume bounds are invalid")
	var determinant := owner_transform.basis.determinant()
	if not is_finite(determinant) or absf(determinant) <= 1.0e-10:
		return _fail("Probe field volume transform is singular")
	var local_camera := owner_transform.affine_inverse() * camera_transform.origin
	var half_size := owner_size * 0.5
	local_camera = Vector3(
		clampf(local_camera.x, -half_size.x, half_size.x),
		clampf(local_camera.y, -half_size.y, half_size.y),
		clampf(local_camera.z, -half_size.z, half_size.z))
	var camera_center := owner_transform * local_camera
	var basis := owner_transform.basis
	var world_extent_x := absf(basis.x.x) * owner_size.x + absf(basis.y.x) * owner_size.y + absf(basis.z.x) * owner_size.z
	var world_extent_y := absf(basis.x.y) * owner_size.x + absf(basis.y.y) * owner_size.y + absf(basis.z.y) * owner_size.z
	var world_extent_z := absf(basis.x.z) * owner_size.x + absf(basis.y.z) * owner_size.y + absf(basis.z.z) * owner_size.z
	var world_extent := maxf(world_extent_x, maxf(world_extent_y, world_extent_z))
	var world_origin := owner_transform.origin
	var world_min := world_origin - Vector3(world_extent_x, world_extent_y, world_extent_z) * 0.5
	var world_max := world_origin + Vector3(world_extent_x, world_extent_y, world_extent_z) * 0.5
	var base_spacing := maxf(maxf(surfel_radius * 2.0, 0.25), world_extent / 32.0)
	if not is_finite(base_spacing) or base_spacing <= 0.0:
		return _fail("Probe field spacing is invalid")
	var starts := PackedInt32Array()
	for level in CLIP_LEVELS:
		var spacing := base_spacing * float(1 << level)
		var half_span := spacing * float(CLIP_SIZE) * 0.5
		var level_center := Vector3(
			_clamp_clip_center(camera_center.x, world_min.x, world_max.x, half_span),
			_clamp_clip_center(camera_center.y, world_min.y, world_max.y, half_span),
			_clamp_clip_center(camera_center.z, world_min.z, world_max.z, half_span))
		var center_cell := Vector3i(_world_cell(level_center.x, spacing),
			_world_cell(level_center.y, spacing), _world_cell(level_center.z, spacing))
		var start := center_cell - Vector3i(4, 4, 4)
		starts.append_array(PackedInt32Array([start.x, start.y, start.z, level]))
	var bytes := starts.to_byte_array()
	bytes.append_array(PackedFloat32Array([
		base_spacing, base_spacing * 2.0, base_spacing * 4.0, 0.0]).to_byte_array())
	var budget := PackedInt32Array([
		maxi(configured_updates, 1), maxi(effective_updates, 1),
		maxi(probe_ray_budget, 0) if enabled else 0, maxi(rays_per_surfel, 1)])
	bytes.append_array(budget.to_byte_array())
	if bytes.size() != CONFIG_BYTES or rd.buffer_update(config, 0, bytes.size(), bytes) != OK:
		return _fail("Probe field clipmap configuration upload failed")
	return true


func get_all_rids() -> Array[RID]:
	return _owned.duplicate()


func get_byte_count() -> int:
	return PROBE_COUNT * RECORD_BYTES + CONFIG_BYTES


func release() -> void:
	if rd != null:
		for index in range(_owned.size() - 1, -1, -1):
			var rid := _owned[index]
			if rid.is_valid():
				rd.free_rid(rid)
	_owned.clear()
	records = RID()
	config = RID()
	rd = null


func _world_cell(position: float, spacing: float) -> int:
	var value := floor(position / spacing)
	return int(clampf(value, -1000000000.0, 1000000000.0))


func _clamp_clip_center(camera_axis: float, world_min_axis: float,
		world_max_axis: float, half_span: float) -> float:
	if world_max_axis - world_min_axis <= half_span * 2.0:
		return (world_min_axis + world_max_axis) * 0.5
	return clampf(camera_axis, world_min_axis + half_span, world_max_axis - half_span)


func _fail(reason: String) -> bool:
	error = reason
	return false

