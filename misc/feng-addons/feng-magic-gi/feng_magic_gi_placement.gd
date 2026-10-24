@tool
class_name FMagicGIPlacement
extends RefCounted
## Physics-independent surface sampling and the offline PRT triangle BVH.

const Data = preload("feng_magic_gi_data.gd")
const SceneTracker = preload("feng_magic_gi_scene_tracker.gd")
const EmitterBakeSet = preload("feng_magic_gi_emitter_bake_set.gd")
const ProbeLayout = preload("feng_magic_gi_probe_layout.gd")
const MaterialSampler = preload("feng_magic_gi_material_sampler.gd")
const AdaptiveLayout = preload("feng_magic_gi_adaptive_layout.gd")
const TraceScene = preload("feng_magic_gi_trace_scene.gd")
const MAX_PROBES := 65536
const MAX_GEOMETRY_TRIANGLES := 250000
const MAX_TERRAIN_CELLS := 500000
const MAX_SAMPLE_CANDIDATES := 2000000
const MAX_STAGED_ARBITRATION_CELLS := MAX_PROBES
const MAX_STAGED_CANDIDATE_RECORDS := MAX_STAGED_ARBITRATION_CELLS \
		* ProbeLayout.MAX_DOMAINS_PER_ARBITRATION_CELL * ProbeLayout.CANDIDATES_PER_DOMAIN
const MAX_REFINEMENT_CELL_VISITS := 2000000
const MAX_TRIANGLE_STEPS := 512
const MAX_OCCLUSION_TRIANGLES := 250000
const OCCLUSION_MAX_CROSSINGS := 256
const OCCLUSION_WELD_EPSILON := 0.00001
const FLOAT32_EPSILON := 0.00000011920928955078125
const TRIANGLE_SEGMENT_DETERMINANT_EPSILON := 0.00001
const REVERSE_VERIFY_DETERMINANT_SAFETY := 4.0
const REVERSE_VERIFY_MAX_SPACING_RATIO := 0.25
const MIN_PROBE_OFFSET_SPACING_RATIO := 0.002
const BASE_PROBE_OFFSET_SPACING_RATIO := 0.025
# Probe centers may be offset at most half a base cell from their surface anchors.
# Actual offsets are further reduced or rejected by BVH, owner-side,
# volume-boundary, and solid checks.
const MAX_PROBE_OFFSET_SPACING_RATIO := 0.5
const OCCLUSION_GRID_AXIS := 8
const BROADPHASE_EPSILON := SceneTracker.BROADPHASE_EPSILON
const REFRESH_MAIN_SLICE_USEC := 2500
const REFRESH_WORKER_CHECK_INTERVAL := 128

class RefreshCancellation:
	extends RefCounted
	var _mutex := Mutex.new()
	var _cancelled := false

	func cancel() -> void:
		_mutex.lock()
		_cancelled = true
		_mutex.unlock()

	func is_cancelled() -> bool:
		_mutex.lock()
		var result := _cancelled
		_mutex.unlock()
		return result

## A SceneTree-owned coordinator keeps capture, task reaping and completion alive
## when the Volume leaves the tree or is freed during Refresh.
class AsyncRefreshCoordinator:
	extends Node
	signal completed(success: bool)
	var _placement
	var _volume_ref: WeakRef
	var _for_bake := false
	var _build_bvh := false
	var _is_current := Callable()
	var _progress := Callable()
	var _collection_bounds := AABB()
	var _finished := Callable()
	var _completion_owner: RefCounted

	func begin(placement, volume: Node3D, for_bake: bool, build_bvh: bool,
			is_current: Callable, progress: Callable, collection_bounds: AABB,
			finished: Callable, completion_owner: RefCounted) -> void:
		name = "FMagicGIAsyncRefresh"
		process_mode = Node.PROCESS_MODE_ALWAYS
		_placement = placement
		_volume_ref = weakref(volume)
		_for_bake = for_bake
		_build_bvh = build_bvh
		_is_current = is_current
		_progress = progress
		_collection_bounds = collection_bounds
		_finished = finished
		_completion_owner = completion_owner
		call_deferred("_run")

	func cancel() -> void:
		if _placement != null and is_instance_valid(_placement):
			_placement.call("cancel_async_refresh")

	func _run() -> void:
		var volume = _volume_ref.get_ref() if _volume_ref != null else null
		var success := false
		if is_instance_valid(volume) and _placement != null \
				and is_instance_valid(_placement):
			success = await _placement.collect_async(volume, _for_bake,
					_build_bvh, _is_current, _progress, _collection_bounds, _finished)
		elif _finished.is_valid():
			_finished.call(false)
		completed.emit(success)
		_placement = null
		_volume_ref = null
		_is_current = Callable()
		_progress = Callable()
		_finished = Callable()
		_completion_owner = null
		queue_free()

var faces := PackedVector3Array()
var reflectance := PackedVector3Array()
var material_sampler := MaterialSampler.new()
var face_materials := PackedInt32Array()
var face_uv := PackedVector2Array()
var face_uv2 := PackedVector2Array()
var face_emitter_indices := PackedInt32Array()
var _triangle_material := -1
var face_source_ids := PackedInt64Array()
var face_surface_indices := PackedInt32Array()
var face_domain_sources := PackedStringArray()
var emitters := EmitterBakeSet.new()
var bvh: TriangleMesh
var trace_scene: RefCounted
var positions := PackedVector3Array()
var surface_positions := PackedVector3Array()
var normals := PackedVector3Array()
var probe_spacings := PackedFloat32Array()
var stable_probe_ids := PackedInt64Array()
var scene_signature := 0
var error_message := ""
var warning_message := ""
var bvh_ready := false

var _world_candidate_cells: Dictionary = {}
var _staged_arbitration_cell_count := 0
var _staged_anchor_index: Dictionary = {}
var _staged_anchor_index_count := 0
var _cell_counts: Dictionary = {}
var _occlusion_volumes: Array[Dictionary] = []
var _occlusion_cells: Dictionary = {}
var _source_volume_indices: Dictionary = {}
var _face_outward_signs: Dictionary = {}
var _volume: Node3D
var _volume_size := Vector3.ONE
var _volume_transform := Transform3D.IDENTITY
var _source_volume_transform := Transform3D.IDENTITY
var _source_volume_size := Vector3.ONE
var _adaptive_placement := false
var _preferred_offset_value := 0.03
var _fallback_reflectance := 0.5
var _terrain_reflectance := 0.5
var _bake_distance := 1.0
var _streamed_page := false
var _world: World3D
var _collect_emission := false
var _world_bounds: AABB
var _bake_world_bounds: AABB
var _inverse := Transform3D.IDENTITY
var _dimensions := Vector3i.ONE
var _probe_spacing := 1.0
var _active_candidate_spacing := 1.0
var _arbitration_spacing := 1.0
var _material_cache: Dictionary = {}
var _candidate_count := 0
var _coarse_valid_candidate_count := 0
var _refined_valid_candidate_count := 0
var _refinement_cell_count := 0
var _refinement_cell_visit_count := 0
var _canonical_candidate_count := 0
var _fallback_candidate_count := 0
var _fallback_triangle_count := 0
var _fallback_candidate_reservations := 0
var _terrain_work := 0
var _triangle_reflectance: Vector3
var _triangle_emitter_index := -1
var _triangle_source_id := 0
var _triangle_surface_index := -1
var _triangle_domain_source := ""
var _sample_source_id := 0
var _sample_surface_index := -1
var _sample_domain_source := ""
var _sample_face_index := -1
var _domain_source_cache: Dictionary = {}
var _fallback_triangle_vertices := PackedVector3Array()
var _fallback_triangle_normals := PackedVector3Array()
var _fallback_triangle_source_ids := PackedInt64Array()
var _fallback_triangle_surface_indices := PackedInt32Array()
var _fallback_triangle_face_indices := PackedInt32Array()
var _fallback_triangle_domain_indices := PackedInt32Array()
var _interned_domain_sources := PackedStringArray()
var _interned_domain_source_indices: Dictionary = {}
var _valid_candidate_count := 0
var _staged_candidate_count := 0
var _bounded_candidate_pruned_count := 0
var rejected_no_safe_offset_count := 0
var rejected_inside_or_indeterminate_center_count := 0
# Preserve the old aggregate diagnostic for the repository's existing harnesses.
var rejected_occluded_count: int:
	get:
		return rejected_no_safe_offset_count + rejected_inside_or_indeterminate_center_count
var rejected_duplicate_count := 0
var rejected_center_outside_count := 0
var rejected_foreign_surface_center_count := 0
var rejected_owner_connection_count := 0
var rejected_owner_connection_empty_count := 0
var rejected_owner_connection_mismatch_count := 0
var owner_connection_raw_anchor_count := 0
var rejected_owner_backside_center_count := 0
var rejected_center_clearance_count := 0
var rejected_ambiguous_side_count := 0
var rejected_center_overlap_count := 0
var rejected_world_cell_competition_count := 0
var rejected_lookup_capacity_count := 0
var rejected_arbitration_cell_limit_count := 0
var adjusted_center_count := 0
var _scene_root: Node
var _async_worker_result := false
var _refresh_cancel_token: RefCounted
var _async_capture_guards: Array[Dictionary] = []
var _source_volume_instance_id := 0

func collect(volume: Node3D, for_bake := false, build_bvh := true,
		collect_emission := false, sample_geometry := true,
		collection_bounds := AABB()) -> bool:
	_refresh_cancel_token = null
	if not _begin_collect(volume, for_bake, collect_emission, sample_geometry,
			collection_bounds):
		return false
	_scene_root = SceneTracker.scene_root(volume)
	_collect_node(_scene_root)
	if not error_message.is_empty():
		return false
	if not _build_geometry_trace_data(volume):
		return false
	if not sample_geometry:
		return true
	return _sample_current_geometry(build_bvh)

## Main-thread resource capture is split into short time slices. Once the scene
## data is immutable, BVH construction and layout sampling run on a worker.
func collect_async(volume: Node3D, for_bake: bool, build_bvh: bool,
		is_current: Callable, progress: Callable = Callable(),
		collection_bounds := AABB(), finished: Callable = Callable()) -> bool:
	# A RefCounted coroutine does not itself guarantee that the receiver stays
	# alive when its Node owner is freed. Keep the worker coordinator until its
	# task has completed and been joined below.
	var lifetime_hold: RefCounted = self
	var result: bool = await _collect_async_impl(volume, for_bake, build_bvh,
			is_current, progress, collection_bounds)
	if finished.is_valid():
		finished.call(result)
	if lifetime_hold == self:
		return result
	return false

func _collect_async_impl(volume: Node3D, for_bake: bool, build_bvh: bool,
		is_current: Callable, progress: Callable,
		collection_bounds: AABB) -> bool:
	_refresh_cancel_token = RefreshCancellation.new()
	if not _begin_collect(volume, for_bake, false, true, collection_bounds):
		_refresh_cancel_token = null
		return false
	_scene_root = SceneTracker.scene_root(volume)
	var tree: SceneTree = volume.get_tree()
	if not is_instance_valid(tree):
		return _abort_async_refresh()
	var stack: Array[Node] = [_scene_root]
	var slice_started := Time.get_ticks_usec()
	var visited := 0
	while not stack.is_empty():
		if not _refresh_owner_is_current(volume, is_current):
			return _abort_async_refresh()
		var node: Node = stack.pop_back()
		if not is_instance_valid(node) or not node.is_inside_tree() \
				or node.is_queued_for_deletion() \
				or SceneTracker.scene_root(node) != _scene_root:
			continue
		var node_id := node.get_instance_id()
		var node_path := node.get_path()
		if SceneTracker.should_skip_world_boundary(node, _scene_root, _world):
			continue
		if node is MeshInstance3D and node.mesh != null and node.is_visible_in_tree():
			if not await _collect_mesh_async(node, volume, tree, is_current, progress, slice_started):
				return _abort_async_refresh()
			slice_started = Time.get_ticks_usec()
		elif node.is_class("Terrain3D") and node.get("data") != null and node.is_visible_in_tree():
			if not await _collect_terrain_async(node, volume, tree, is_current, progress, slice_started):
				return _abort_async_refresh()
			slice_started = Time.get_ticks_usec()
		var children := node.get_children()
		for child_index in range(children.size() - 1, -1, -1):
			stack.append(children[child_index])
			visited += 1
			if child_index % 64 == 0 and Time.get_ticks_usec() - slice_started >= REFRESH_MAIN_SLICE_USEC:
				slice_started = await _yield_refresh_slice(volume, tree, is_current,
						progress, "Capturing scene", visited, children.size(), slice_started)
				if slice_started < 0 or not _scene_node_is_current(node, node_id,
						node_path, volume, is_current):
					return _abort_async_refresh()
		visited += 1
		slice_started = await _yield_refresh_slice(volume, tree, is_current,
				progress, "Capturing scene", visited, -1, slice_started)
		if slice_started < 0 or not _scene_node_is_current(node, node_id,
				node_path, volume, is_current):
			return _abort_async_refresh()
	if not error_message.is_empty() or not _async_capture_inputs_current():
		if error_message.is_empty():
			error_message = "Surface refresh was superseded."
		_refresh_cancel_token = null
		return false
	if not await _run_refresh_worker(volume, tree, is_current, progress,
			"Building geometry and placing probes", build_bvh):
		_refresh_cancel_token = null
		return false
	var result: bool = _async_worker_result \
			and _refresh_request_is_current(volume, is_current) \
			and _async_capture_inputs_current()
	_refresh_cancel_token = null
	return result

func cancel_async_refresh() -> void:
	_request_refresh_cancel()

func async_capture_is_current(volume: Node3D, is_current: Callable) -> bool:
	return _refresh_request_is_current(volume, is_current) \
			and _async_capture_inputs_current()

func _abort_async_refresh() -> bool:
	_request_refresh_cancel()
	if error_message.is_empty():
		error_message = "Surface refresh was superseded."
	_refresh_cancel_token = null
	return false

func _request_refresh_cancel() -> void:
	if _refresh_cancel_token != null and is_instance_valid(_refresh_cancel_token):
		_refresh_cancel_token.call("cancel")

func _refresh_cancelled() -> bool:
	return _refresh_cancel_token != null and is_instance_valid(_refresh_cancel_token) \
			and bool(_refresh_cancel_token.call("is_cancelled"))

func _refresh_owner_is_current(volume: Variant, is_current: Callable) -> bool:
	if not is_instance_valid(volume) or not volume.is_inside_tree() \
			or volume.is_queued_for_deletion() \
			or volume.get_instance_id() != _source_volume_instance_id \
			or volume.global_transform != _source_volume_transform \
			or volume.size != _source_volume_size \
			or not is_current.is_valid():
		return false
	return bool(is_current.call())

func _refresh_request_is_current(volume: Variant, is_current: Callable) -> bool:
	return _refresh_owner_is_current(volume, is_current) and _async_capture_inputs_current()

func _scene_node_is_current(node: Variant, node_id: int, node_path: NodePath,
		volume: Variant, is_current: Callable) -> bool:
	if not _refresh_owner_is_current(volume, is_current) \
			or not is_instance_valid(node):
		return false
	return node.get_instance_id() == node_id and node.is_inside_tree() \
			and not node.is_queued_for_deletion() and node.get_path() == node_path \
			and SceneTracker.scene_root(node) == _scene_root

func _async_capture_inputs_current() -> bool:
	for capture in _async_capture_guards:
		if String(capture.get("kind", "")) == "mesh":
			if not _mesh_capture_guard_current(capture):
				return false
		elif String(capture.get("kind", "")) == "terrain":
			if not _terrain_capture_guard_current(capture):
				return false
	return true

func _mesh_capture_guard_current(capture: Dictionary) -> bool:
	var node: Variant = capture.get("node")
	var mesh: Variant = capture.get("mesh")
	if not is_instance_valid(node) or not is_instance_valid(mesh):
		return false
	if not node is MeshInstance3D or not mesh is Mesh:
		return false
	var mesh_node := node as MeshInstance3D
	var source_mesh := mesh as Mesh
	return mesh_node.get_instance_id() == int(capture.get("node_id", 0)) \
			and mesh_node.is_inside_tree() and not mesh_node.is_queued_for_deletion() \
			and mesh_node.mesh == source_mesh \
			and source_mesh.get_instance_id() == int(capture.get("mesh_id", 0)) \
			and mesh_node.global_transform == capture.get("transform", Transform3D.IDENTITY) \
			and mesh_node.get_path() == capture.get("path", NodePath()) \
			and mesh_node.is_visible_in_tree() \
			and SceneTracker.scene_root(mesh_node) == _scene_root \
			and SceneTracker.resource_revision(source_mesh) == int(capture.get("revision", -1))

func _terrain_capture_guard_current(capture: Dictionary) -> bool:
	var terrain: Variant = capture.get("node")
	var data: Variant = capture.get("data")
	if not is_instance_valid(terrain) or not is_instance_valid(data) \
			or not terrain is Node3D:
		return false
	var terrain_node := terrain as Node3D
	return terrain_node.get_instance_id() == int(capture.get("node_id", 0)) \
			and terrain_node.is_inside_tree() and not terrain_node.is_queued_for_deletion() \
			and terrain_node.get("data") == data \
			and terrain_node.global_transform == capture.get("transform", Transform3D.IDENTITY) \
			and terrain_node.get_path() == capture.get("path", NodePath()) \
			and terrain_node.is_visible_in_tree() \
			and SceneTracker.scene_root(terrain_node) == _scene_root \
			and float(terrain_node.get("vertex_spacing")) == float(capture.get("vertex_spacing", 0.0)) \
			and SceneTracker.resource_revision(data) == int(capture.get("revision", -1))

func _yield_refresh_slice(volume: Variant, tree: SceneTree, is_current: Callable,
		progress: Callable, phase: String, completed: int, total: int,
		slice_started: int) -> int:
	if Time.get_ticks_usec() - slice_started < REFRESH_MAIN_SLICE_USEC:
		return slice_started
	if not _refresh_request_is_current(volume, is_current) or not is_instance_valid(tree):
		_request_refresh_cancel()
		error_message = "Surface refresh was superseded."
		return -1
	if progress.is_valid():
		progress.call(phase, completed, total)
	await tree.process_frame
	if is_instance_valid(tree) and _refresh_request_is_current(volume, is_current):
		return Time.get_ticks_usec()
	error_message = "Surface refresh was superseded."
	return -1

func _run_refresh_worker(volume: Variant, tree: SceneTree, is_current: Callable,
		progress: Callable, phase: String, build_bvh: bool) -> bool:
	_async_worker_result = false
	var cancellation := _refresh_cancel_token
	var task_id := WorkerThreadPool.add_task(
			Callable(self, "_worker_build_and_sample").bind(build_bvh, cancellation), false,
			"Magic GI Surface Layout")
	if task_id < 0:
		error_message = "Could not start the background surface-layout task."
		return false
	var cancellation_requested := false
	while not WorkerThreadPool.is_task_completed(task_id):
		if cancellation.is_cancelled():
			cancellation_requested = true
		elif not cancellation_requested and not _refresh_request_is_current(volume, is_current):
			cancellation.cancel()
			cancellation_requested = true
			if progress.is_valid():
				progress.call("Cancelling superseded surface refresh", -1, -1)
		elif not cancellation_requested and progress.is_valid():
			progress.call(phase, -1, -1)
		await tree.process_frame
	WorkerThreadPool.wait_for_task_completion(task_id)
	var current := _refresh_request_is_current(volume, is_current)
	if not current:
		cancellation.cancel()
	_refresh_cancel_token = null
	return current and not cancellation.is_cancelled()

func _worker_build_and_sample(build_bvh: bool, cancellation: RefCounted) -> void:
	if cancellation.is_cancelled():
		return
	if not faces.is_empty():
		# TriangleMesh construction is a single non-interruptible native call. It
		# stays on this worker; cancellation is checked as soon as it returns.
		bvh = TriangleMesh.new()
		bvh_ready = bvh.create_from_faces(faces)
		if cancellation.is_cancelled():
			return
		if not bvh_ready:
			error_message = "Godot could not create the static PRT triangle BVH."
			return
	trace_scene = TraceScene.new()
	if not trace_scene.initialize_snapshot(self, _inverse, _volume_size,
			_probe_spacing, _preferred_offset_value, cancellation):
		return
	var ready_solids: Array[Dictionary] = []
	for solid_index in _occlusion_volumes.size():
		if cancellation.is_cancelled():
			return
		var solid: Dictionary = _occlusion_volumes[solid_index]
		var solid_bvh := TriangleMesh.new()
		var solid_ready := solid_bvh.create_from_faces(solid["faces"])
		if cancellation.is_cancelled():
			return
		if not solid_ready:
			continue
		solid["bvh"] = solid_bvh
		ready_solids.append(solid)
	_occlusion_volumes = ready_solids
	_source_volume_indices.clear()
	for solid_index in _occlusion_volumes.size():
		if cancellation.is_cancelled():
			return
		_source_volume_indices[int(_occlusion_volumes[solid_index]["instance_id"])] = solid_index
	if not _build_occlusion_broadphase():
		return
	if cancellation.is_cancelled():
		return
	_async_worker_result = _sample_current_geometry(build_bvh)

func _collect_mesh_async(node: MeshInstance3D, volume: Node3D, tree: SceneTree,
		is_current: Callable, progress: Callable, slice_started: int) -> bool:
	if not is_instance_valid(node) or not node.is_inside_tree() \
			or node.is_queued_for_deletion() or node.mesh == null:
		error_message = "Surface refresh was superseded."
		return false
	var mesh: Mesh = node.mesh
	SceneTracker.watch_resource(mesh)
	var captured_transform := node.global_transform
	var captured_path := node.get_path()
	var captured_revision := SceneTracker.resource_revision(mesh)
	var capture_guard := {"kind": "mesh", "node": node,
		"node_id": node.get_instance_id(), "mesh": mesh,
		"mesh_id": mesh.get_instance_id(), "transform": captured_transform,
		"path": captured_path, "revision": captured_revision}
	_async_capture_guards.append(capture_guard)
	if not _mesh_capture_guard_current(capture_guard):
		error_message = "Surface refresh was superseded."
		return false
	var mesh_world_box: AABB = captured_transform * mesh.get_aabb()
	if not mesh_world_box.grow(BROADPHASE_EPSILON).intersects(_bake_world_bounds.grow(BROADPHASE_EPSILON)):
		return true
	if not await _register_occlusion_volume_async(node, mesh, mesh_world_box,
			captured_transform, captured_path, captured_revision,
			volume, tree, is_current, progress, slice_started):
		return false
	if not _mesh_capture_inputs_current(node, mesh, captured_transform,
			captured_path, captured_revision, volume, is_current):
		error_message = "Surface refresh was superseded."
		return false
	if mesh is PrimitiveMesh:
		var arrays: Array = mesh.get_mesh_arrays()
		if not arrays.is_empty() and arrays[Mesh.ARRAY_VERTEX] != null:
			return await _collect_surface_triangles_async(node, mesh,
					captured_transform, captured_path, captured_revision, 0, arrays, mesh,
					volume, tree, is_current, progress, slice_started)
		return await _collect_faces_only_mesh_async(node, mesh,
			captured_transform, captured_path, captured_revision, volume, tree,
			is_current, progress, slice_started)
	if not mesh is ArrayMesh:
		if mesh.get_surface_count() > 1:
			error_message = "Non-ArrayMesh resources with multiple material surfaces cannot provide per-face reflectance."
			return false
		return await _collect_faces_only_mesh_async(node, mesh,
			captured_transform, captured_path, captured_revision, volume, tree,
			is_current, progress, slice_started)
	for surface in mesh.get_surface_count():
		if not _mesh_capture_inputs_current(node, mesh, captured_transform,
				captured_path, captured_revision, volume, is_current):
			error_message = "Surface refresh was superseded."
			return false
		if mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var arrays := mesh.surface_get_arrays(surface)
		if not await _collect_surface_triangles_async(node, mesh,
				captured_transform, captured_path, captured_revision, surface, arrays, null,
				volume, tree, is_current, progress, slice_started):
			return false
		slice_started = Time.get_ticks_usec()
	return true

func _collect_faces_only_mesh_async(node: MeshInstance3D, mesh: Mesh,
		captured_transform: Transform3D, captured_path: NodePath,
		captured_revision: int, volume: Node3D, tree: SceneTree, is_current: Callable,
		progress: Callable, slice_started: int) -> bool:
	if not _mesh_capture_inputs_current(node, mesh, captured_transform,
			captured_path, captured_revision, volume, is_current):
		error_message = "Surface refresh was superseded."
		return false
	var primitive_faces: PackedVector3Array = mesh.get_faces()
	if primitive_faces.is_empty():
		return true
	_triangle_source_id = node.get_instance_id()
	_triangle_surface_index = 0
	_triangle_domain_source = _mesh_domain_source(node, mesh)
	if not _prepare_surface(node, 0):
		return error_message.is_empty()
	if _triangle_emitter_index >= 0:
		error_message = "An emissive mesh without CPU-accessible UV arrays cannot be baked as an area source."
		return false
	for i in range(0, primitive_faces.size() - 2, 3):
		var a: Vector3 = captured_transform * primitive_faces[i]
		var b: Vector3 = captured_transform * primitive_faces[i + 1]
		var c: Vector3 = captured_transform * primitive_faces[i + 2]
		if not _triangle(a, b, c):
			return false
		if i % 96 == 0:
			slice_started = await _yield_refresh_slice(volume, tree, is_current,
					progress, "Capturing mesh triangles", i / 3, primitive_faces.size() / 3,
					slice_started)
			if slice_started < 0:
				return false
			if not _mesh_capture_inputs_current(node, mesh, captured_transform,
					captured_path, captured_revision, volume, is_current):
				error_message = "Surface refresh was superseded."
				return false
	return true

func _collect_surface_triangles_async(node: MeshInstance3D, source_mesh: Mesh,
		captured_transform: Transform3D, captured_path: NodePath,
		captured_revision: int, surface: int, arrays: Array,
		primitive_mesh: PrimitiveMesh, volume: Node3D, tree: SceneTree,
		is_current: Callable, progress: Callable, slice_started: int) -> bool:
	if not _mesh_capture_inputs_current(node, source_mesh, captured_transform,
			captured_path, captured_revision, volume, is_current):
		error_message = "Surface refresh was superseded."
		return false
	if arrays.is_empty() or arrays[Mesh.ARRAY_VERTEX] == null:
		return true
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	var uv1: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if arrays.size() > Mesh.ARRAY_TEX_UV and arrays[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
	var uv2: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2] if arrays.size() > Mesh.ARRAY_TEX_UV2 and arrays[Mesh.ARRAY_TEX_UV2] != null else PackedVector2Array()
	var count := indices.size() if not indices.is_empty() else vertices.size()
	var snapped_faces: PackedVector3Array
	if primitive_mesh != null:
		snapped_faces = primitive_mesh.get_faces()
		if count % 3 != 0 or snapped_faces.size() != count:
			error_message = "PrimitiveMesh face positions and array UV indices disagree; refusing unstable surface data."
			return false
	_triangle_source_id = node.get_instance_id()
	_triangle_surface_index = surface
	_triangle_domain_source = _mesh_domain_source(node, source_mesh)
	if not _prepare_surface(node, surface, uv1, uv2, vertices.size()):
		return error_message.is_empty()
	for i in range(0, count - 2, 3):
		var ia := indices[i] if not indices.is_empty() else i
		var ib := indices[i + 1] if not indices.is_empty() else i + 1
		var ic := indices[i + 2] if not indices.is_empty() else i + 2
		var a: Vector3 = captured_transform * (snapped_faces[i] if primitive_mesh != null else vertices[ia])
		var b: Vector3 = captured_transform * (snapped_faces[i + 1] if primitive_mesh != null else vertices[ib])
		var c: Vector3 = captured_transform * (snapped_faces[i + 2] if primitive_mesh != null else vertices[ic])
		var ta := uv1[ia] if uv1.size() == vertices.size() else Vector2.ZERO
		var tb := uv1[ib] if uv1.size() == vertices.size() else Vector2.ZERO
		var tc := uv1[ic] if uv1.size() == vertices.size() else Vector2.ZERO
		var t2a := uv2[ia] if uv2.size() == vertices.size() else Vector2.ZERO
		var t2b := uv2[ib] if uv2.size() == vertices.size() else Vector2.ZERO
		var t2c := uv2[ic] if uv2.size() == vertices.size() else Vector2.ZERO
		if not _triangle(a, b, c, ta, tb, tc, t2a, t2b, t2c):
			return false
		if i % 96 == 0:
			slice_started = await _yield_refresh_slice(volume, tree, is_current,
					progress, "Capturing mesh triangles", i / 3, count / 3,
					slice_started)
			if slice_started < 0:
				return false
			if not _mesh_capture_inputs_current(node, source_mesh, captured_transform,
					captured_path, captured_revision, volume, is_current):
				error_message = "Surface refresh was superseded."
				return false
	return true

func _mesh_capture_inputs_current(node: Variant, mesh: Variant,
		captured_transform: Transform3D, captured_path: NodePath,
		captured_revision: int, volume: Variant, is_current: Callable) -> bool:
	if not _refresh_owner_is_current(volume, is_current) \
			or not is_instance_valid(node) or not is_instance_valid(mesh):
		return false
	return node.is_inside_tree() and not node.is_queued_for_deletion() \
			and node.mesh == mesh and node.global_transform == captured_transform \
			and node.get_path() == captured_path and node.is_visible_in_tree() \
			and SceneTracker.scene_root(node) == _scene_root \
			and SceneTracker.resource_revision(mesh) == captured_revision

func _register_occlusion_volume_async(node: MeshInstance3D, mesh: Mesh,
		mesh_world_box: AABB, captured_transform: Transform3D,
		captured_path: NodePath, captured_revision: int,
		volume: Node3D, tree: SceneTree,
		is_current: Callable, progress: Callable, slice_started: int) -> bool:
	if not _mesh_capture_inputs_current(node, mesh, captured_transform,
			captured_path, captured_revision, volume, is_current):
		error_message = "Surface refresh was superseded."
		return false
	var placement_box := _world_bounds.grow(_preferred_offset_value + BROADPHASE_EPSILON)
	if not mesh_world_box.grow(BROADPHASE_EPSILON).intersects(placement_box) \
			or _mesh_has_transparent_surface(node, mesh):
		return true
	var local_faces: PackedVector3Array = mesh.get_faces()
	if local_faces.size() < 12 or local_faces.size() % 3 != 0 \
			or local_faces.size() / 3 > MAX_OCCLUSION_TRIANGLES:
		return true
	if not await _mesh_faces_are_watertight_async(local_faces, volume, tree,
			is_current, progress, slice_started):
		return error_message.is_empty()
	if not _mesh_capture_inputs_current(node, mesh, captured_transform,
			captured_path, captured_revision, volume, is_current):
		error_message = "Surface refresh was superseded."
		return false
	var world_faces := PackedVector3Array()
	world_faces.resize(local_faces.size())
	for index in local_faces.size():
		world_faces[index] = captured_transform * local_faces[index]
		if index % 192 == 0:
			slice_started = await _yield_refresh_slice(volume, tree, is_current,
					progress, "Capturing occlusion geometry", index / 3,
					local_faces.size() / 3, slice_started)
		if slice_started < 0:
			return false
		if index % 192 == 0 and not _mesh_capture_inputs_current(node, mesh,
				captured_transform, captured_path, captured_revision, volume, is_current):
			error_message = "Surface refresh was superseded."
			return false
	var instance_id := node.get_instance_id()
	var solid_index := _occlusion_volumes.size()
	_occlusion_volumes.append({"instance_id": instance_id,
		"world_aabb": mesh_world_box, "faces": world_faces})
	_source_volume_indices[instance_id] = solid_index
	return true

func _mesh_faces_are_watertight_async(local_faces: PackedVector3Array,
		volume: Node3D, tree: SceneTree, is_current: Callable,
		progress: Callable, slice_started: int) -> bool:
	var vertex_ids: Dictionary = {}
	var edge_counts: Dictionary = {}
	for face_offset in range(0, local_faces.size(), 3):
		var triangle_ids := PackedInt32Array()
		for corner in 3:
			var point: Vector3 = local_faces[face_offset + corner]
			var vertex_key := Vector3i(roundi(point.x / OCCLUSION_WELD_EPSILON),
				roundi(point.y / OCCLUSION_WELD_EPSILON), roundi(point.z / OCCLUSION_WELD_EPSILON))
			if not vertex_ids.has(vertex_key):
				vertex_ids[vertex_key] = vertex_ids.size()
			triangle_ids.append(int(vertex_ids[vertex_key]))
		var skip_face := triangle_ids[0] == triangle_ids[1] \
				or triangle_ids[1] == triangle_ids[2] or triangle_ids[2] == triangle_ids[0]
		if not skip_face:
			var a: Vector3 = local_faces[face_offset]
			var b: Vector3 = local_faces[face_offset + 1]
			var c: Vector3 = local_faces[face_offset + 2]
			var face_normal := (c - a).cross(b - a).normalized()
			skip_face = face_normal.length_squared() < 0.5
		if not skip_face:
			for edge_index in 3:
				var first := triangle_ids[edge_index]
				var second := triangle_ids[(edge_index + 1) % 3]
				var low := mini(first, second)
				var high := maxi(first, second)
				var edge_key: int = (low << 32) | high
				edge_counts[edge_key] = int(edge_counts.get(edge_key, 0)) + 1
		if face_offset % 192 == 0:
			slice_started = await _yield_refresh_slice(volume, tree, is_current,
					progress, "Checking closed-mesh edges", face_offset / 3,
					local_faces.size() / 3, slice_started)
		if slice_started < 0:
			return false
	if edge_counts.is_empty():
		return false
	for count in edge_counts.values():
		if int(count) != 2:
			return false
	return true

func _collect_terrain_async(terrain: Node3D, volume: Node3D, tree: SceneTree,
		is_current: Callable, progress: Callable, slice_started: int) -> bool:
	if not is_instance_valid(terrain) or not terrain.is_inside_tree() \
			or terrain.is_queued_for_deletion():
		error_message = "Surface refresh was superseded."
		return false
	_triangle_emitter_index = -1
	_triangle_material = -1
	_triangle_source_id = terrain.get_instance_id()
	_triangle_surface_index = -1
	_triangle_domain_source = _terrain_domain_source(terrain)
	var data = terrain.get("data")
	if data == null or not (data is Object):
		error_message = "Terrain3D data is unavailable during surface refresh."
		return false
	var terrain_transform := terrain.global_transform
	var terrain_path := terrain.get_path()
	var terrain_id := terrain.get_instance_id()
	var terrain_vertex_spacing := float(terrain.get("vertex_spacing"))
	SceneTracker.watch_object(data)
	var terrain_revision := SceneTracker.resource_revision(data)
	_async_capture_guards.append({"kind": "terrain", "node": terrain,
		"node_id": terrain_id, "data": data, "transform": terrain_transform,
		"path": terrain_path, "vertex_spacing": terrain_vertex_spacing,
		"revision": terrain_revision})
	if not data.has_method("get_surface_height"):
		error_message = "Terrain3D data is missing get_surface_height(); refusing raw height sampling."
		return false
	var box := _bake_world_bounds
	var step := _probe_spacing
	var vertex_spacing: float = terrain_vertex_spacing
	if _streamed_page:
		step = maxf(vertex_spacing, 0.25)
	else:
		step = minf(step, maxf(vertex_spacing, 0.25))
	var start := Vector2(floor(box.position.x / step) * step, floor(box.position.z / step) * step)
	var end := box.end
	var nx := ceili((end.x - start.x) / step) + 1
	var nz := ceili((end.z - start.y) / step) + 1
	_terrain_work += nx * nz
	if nx <= 1 or nz <= 1 or _terrain_work > MAX_TERRAIN_CELLS:
		error_message = "Terrain sampling exceeds the 500,000-cell work limit; increase Probe Spacing or reduce Bake Distance."
		return false
	var heights := PackedFloat32Array()
	heights.resize(nx * nz)
	for z in nz:
		for x in nx:
			heights[z * nx + x] = data.call("get_surface_height",
					Vector3(start.x + x * step, 0.0, start.y + z * step))
			if x % 32 == 0:
				slice_started = await _yield_refresh_slice(volume, tree, is_current,
						progress, "Capturing terrain heights", z * nx + x,
						nx * nz, slice_started)
				if slice_started < 0 or not _terrain_capture_guard_current({
						"node": terrain, "node_id": terrain_id, "data": data,
						"transform": terrain_transform, "path": terrain_path,
						"vertex_spacing": terrain_vertex_spacing,
						"revision": terrain_revision}):
					return false
	var color := Vector3.ONE * _terrain_reflectance
	for z in nz - 1:
		for x in nx - 1:
			var h00 := heights[z * nx + x]
			var h10 := heights[z * nx + x + 1]
			var h01 := heights[(z + 1) * nx + x]
			var h11 := heights[(z + 1) * nx + x + 1]
			if is_finite(h00) and is_finite(h10) and is_finite(h01) and is_finite(h11):
				var a := Vector3(start.x + x * step, h00, start.y + z * step)
				var b := Vector3(start.x + (x + 1) * step, h10, start.y + z * step)
				var c := Vector3(start.x + x * step, h01, start.y + (z + 1) * step)
				var d := Vector3(start.x + (x + 1) * step, h11, start.y + (z + 1) * step)
				_triangle_reflectance = color
				if not _triangle(a, b, c) or not _triangle(b, d, c):
					return false
			if x % 32 == 0:
				slice_started = await _yield_refresh_slice(volume, tree, is_current,
						progress, "Building terrain triangles", z * nx + x,
						nx * nz, slice_started)
				if slice_started < 0 or not _terrain_capture_guard_current({
						"node": terrain, "node_id": terrain_id, "data": data,
						"transform": terrain_transform, "path": terrain_path,
						"vertex_spacing": terrain_vertex_spacing,
						"revision": terrain_revision}):
					return false
	return true

func _begin_collect(volume: Node3D, for_bake: bool, collect_emission: bool,
		sample_geometry: bool, collection_bounds: AABB) -> bool:
	_volume = volume
	_source_volume_instance_id = volume.get_instance_id()
	_async_capture_guards.clear()
	_streamed_page = _has_true_boolean_property(volume, &"streamed_page")
	_world = volume.get_world_3d()
	_collect_emission = collect_emission
	emitters = EmitterBakeSet.new()
	_volume_size = volume.size
	_volume_transform = volume.global_transform
	_source_volume_transform = volume.global_transform
	_source_volume_size = volume.size
	_adaptive_placement = volume.adaptive_placement
	_fallback_reflectance = float(volume.get("fallback_material_reflectance"))
	_terrain_reflectance = float(volume.get("terrain_reflectance"))
	_bake_distance = float(volume.get("bake_distance"))
	_inverse = volume.global_transform.affine_inverse()
	_dimensions = volume.grid_dimensions() if sample_geometry else Vector3i.ONE
	_probe_spacing = maxf(float(volume.get("probe_spacing")), 0.1)
	_active_candidate_spacing = _probe_spacing
	_arbitration_spacing = minf(_probe_spacing, volume.minimum_probe_spacing) \
			if volume.adaptive_placement else _probe_spacing
	error_message = ""
	warning_message = ""
	_world_bounds = volume.global_transform * AABB(-volume.size * 0.5, volume.size)
	# Preview must include geometry that can intersect the short surface-offset
	# segment, even before a bake exists. Bake collection already has the wider
	# ray-tracing bounds and therefore also contains this local occupancy region.
	var max_probe_offset := _preferred_probe_offset(volume)
	_preferred_offset_value = max_probe_offset
	_bake_world_bounds = collection_bounds if _valid_bounds(collection_bounds) else \
		(_world_bounds.grow(volume.bake_distance) if for_bake \
		else _world_bounds.grow(max_probe_offset + BROADPHASE_EPSILON))
	faces.clear()
	reflectance.clear()
	material_sampler = MaterialSampler.new()
	face_materials.clear()
	face_uv.clear()
	face_uv2.clear()
	face_emitter_indices.clear()
	face_source_ids.clear()
	face_surface_indices.clear()
	face_domain_sources.clear()
	positions.clear()
	surface_positions.clear()
	normals.clear()
	probe_spacings.clear()
	stable_probe_ids.clear()
	_clear_staged_candidate_storage()
	_cell_counts.clear()
	_occlusion_volumes.clear()
	_occlusion_cells.clear()
	_source_volume_indices.clear()
	_face_outward_signs.clear()
	_material_cache.clear()
	_candidate_count = 0
	_coarse_valid_candidate_count = 0
	_refined_valid_candidate_count = 0
	_refinement_cell_count = 0
	_refinement_cell_visit_count = 0
	_terrain_work = 0
	_triangle_emitter_index = -1
	_triangle_source_id = 0
	_triangle_surface_index = -1
	_triangle_domain_source = ""
	_sample_source_id = 0
	_sample_surface_index = -1
	_sample_domain_source = ""
	_sample_face_index = -1
	_domain_source_cache.clear()
	_fallback_triangle_vertices.clear()
	_fallback_triangle_normals.clear()
	_fallback_triangle_source_ids.clear()
	_fallback_triangle_surface_indices.clear()
	_fallback_triangle_face_indices.clear()
	_fallback_triangle_domain_indices.clear()
	_interned_domain_sources.clear()
	_interned_domain_source_indices.clear()
	_valid_candidate_count = 0
	_staged_candidate_count = 0
	_bounded_candidate_pruned_count = 0
	_canonical_candidate_count = 0
	_fallback_candidate_count = 0
	_fallback_triangle_count = 0
	_fallback_candidate_reservations = 0
	rejected_no_safe_offset_count = 0
	rejected_inside_or_indeterminate_center_count = 0
	rejected_duplicate_count = 0
	rejected_center_outside_count = 0
	rejected_foreign_surface_center_count = 0
	rejected_owner_connection_count = 0
	rejected_owner_connection_empty_count = 0
	rejected_owner_connection_mismatch_count = 0
	owner_connection_raw_anchor_count = 0
	rejected_owner_backside_center_count = 0
	rejected_center_clearance_count = 0
	rejected_ambiguous_side_count = 0
	rejected_center_overlap_count = 0
	rejected_world_cell_competition_count = 0
	rejected_lookup_capacity_count = 0
	rejected_arbitration_cell_limit_count = 0
	adjusted_center_count = 0
	bvh = null
	trace_scene = null
	bvh_ready = false
	if sample_geometry and (_dimensions.x <= 0 or _dimensions.y <= 0 or _dimensions.z <= 0 \
			or _dimensions.x > Data.MAX_GRID_AXIS or _dimensions.y > Data.MAX_GRID_AXIS \
			or _dimensions.z > Data.MAX_GRID_AXIS):
		error_message = "Lookup grid exceeds the supported 64 cells per axis."
		return false
	return true

func _build_geometry_trace_data(volume: Node3D) -> bool:
	# Build once after all faces are collected. Placement filtering and the baker
	# then share this same accelerated geometry instead of scanning triangles per
	# sample. Preview also needs it to match the bake's accepted sample layout.
	if not faces.is_empty():
		bvh = TriangleMesh.new()
		bvh_ready = bvh.create_from_faces(faces)
		if not bvh_ready:
			error_message = "Godot could not create the static PRT triangle BVH."
			return false
	trace_scene = TraceScene.new()
	trace_scene.initialize(self, volume, _preferred_offset_value)
	return _build_occlusion_broadphase()

## Reuses a management-block geometry/BVH collection to bake one page. The
## collector bounds already include the complete multi-bounce trace radius.
func sample_streamed_page(volume: Node3D, build_bvh := true) -> bool:
	if bvh == null or not bvh_ready:
		error_message = "A streamed page requires a collected immutable geometry BVH."
		return false
	_volume = volume
	_world = volume.get_world_3d()
	_volume_size = volume.size
	_volume_transform = volume.global_transform
	_source_volume_transform = volume.get("source_volume_transform") if _has_true_boolean_property(volume, &"streamed_page") else volume.global_transform
	_source_volume_size = volume.get("source_volume_size") if _has_true_boolean_property(volume, &"streamed_page") else volume.size
	_adaptive_placement = volume.adaptive_placement
	_fallback_reflectance = float(volume.get("fallback_material_reflectance"))
	_terrain_reflectance = float(volume.get("terrain_reflectance"))
	_bake_distance = float(volume.get("bake_distance"))
	_inverse = volume.global_transform.affine_inverse()
	_dimensions = volume.grid_dimensions()
	_probe_spacing = maxf(float(volume.get("probe_spacing")), 0.1)
	_active_candidate_spacing = _probe_spacing
	_arbitration_spacing = minf(_probe_spacing, volume.minimum_probe_spacing) \
			if volume.adaptive_placement else _probe_spacing
	_world_bounds = volume.global_transform * AABB(-volume.size * 0.5, volume.size)
	_preferred_offset_value = _preferred_probe_offset(volume)
	_collect_emission = true
	trace_scene = TraceScene.new()
	trace_scene.initialize(self, volume, _preferred_offset_value)
	_reset_page_sampling_state()
	if not _build_occlusion_broadphase():
		return false
	if _dimensions.x <= 0 or _dimensions.y <= 0 or _dimensions.z <= 0 \
			or _dimensions.x > Data.MAX_GRID_AXIS or _dimensions.y > Data.MAX_GRID_AXIS \
			or _dimensions.z > Data.MAX_GRID_AXIS:
		error_message = "Lookup grid exceeds the supported 64 cells per axis."
		return false
	return _sample_current_geometry(build_bvh)

func _sample_current_geometry(build_bvh: bool) -> bool:
	if _refresh_cancelled() or not _sample_collected_geometry():
		positions.clear()
		surface_positions.clear()
		normals.clear()
		_clear_staged_candidate_storage()
		return false
	if _refresh_cancelled():
		_clear_staged_candidate_storage()
		return false
	_coarse_valid_candidate_count = _valid_candidate_count
	if _adaptive_placement:
		var refinement_result: Dictionary = AdaptiveLayout.mark_refinement_cells(
				_world_candidate_cells, Callable(self, "trace_geometry"), trace_scene,
				_world_bounds, _probe_spacing, _arbitration_spacing,
				Callable(_refresh_cancel_token, "is_cancelled") if _refresh_cancel_token != null else Callable())
		if _refresh_cancelled() or bool(refinement_result.get("cancelled", false)):
			_clear_staged_candidate_storage()
			return false
		var refinement_cells: Dictionary = refinement_result["cells"]
		_refinement_cell_count = refinement_cells.size()
		var refinement_error := String(refinement_result["error"])
		if not refinement_error.is_empty():
			error_message = refinement_error
		if not error_message.is_empty() or not _sample_refined_geometry(refinement_cells) \
				or _refresh_cancelled():
			positions.clear()
			surface_positions.clear()
			normals.clear()
			_clear_staged_candidate_storage()
			return false
		_refined_valid_candidate_count = _valid_candidate_count - _coarse_valid_candidate_count
	if _refresh_cancelled() or not _finalize_world_candidates():
		positions.clear()
		surface_positions.clear()
		normals.clear()
		_clear_staged_candidate_storage()
		return false
	_clear_staged_candidate_storage()
	if _refresh_cancelled():
		return false
	if not build_bvh:
		bvh = null
		bvh_ready = false
	if rejected_no_safe_offset_count > 0 or rejected_inside_or_indeterminate_center_count > 0 \
			or rejected_foreign_surface_center_count > 0 \
			or rejected_ambiguous_side_count > 0 or rejected_lookup_capacity_count > 0:
		warning_message = "Placed %d probes; rejected %d candidates with no safe offset, %d centers inside or indeterminate, %d centers without a clear source-face connection (%d on the back side), %d centers outside the volume, and %d candidates at lookup-cell capacity; skipped %d clipped triangles with unproven outward side." % [
			positions.size(), rejected_no_safe_offset_count,
			rejected_inside_or_indeterminate_center_count,
			rejected_foreign_surface_center_count, rejected_owner_backside_center_count,
			rejected_center_outside_count,
			rejected_lookup_capacity_count, rejected_ambiguous_side_count]
	scene_signature = hash([faces, reflectance, surface_positions, positions, normals,
		ProbeLayout.PLACEMENT_LAYOUT_REVISION])
	if not material_sampler.records.is_empty():
		scene_signature = hash([scene_signature, face_uv, material_sampler.fingerprint()])
	return not _refresh_cancelled()

func _clear_staged_candidate_storage() -> void:
	_world_candidate_cells.clear()
	_staged_arbitration_cell_count = 0
	_staged_anchor_index.clear()
	_staged_anchor_index_count = 0

func _reset_page_sampling_state() -> void:
	positions.clear()
	surface_positions.clear()
	normals.clear()
	probe_spacings.clear()
	stable_probe_ids.clear()
	_clear_staged_candidate_storage()
	_cell_counts.clear()
	_fallback_triangle_vertices.clear()
	_fallback_triangle_normals.clear()
	_fallback_triangle_source_ids.clear()
	_fallback_triangle_surface_indices.clear()
	_fallback_triangle_face_indices.clear()
	_fallback_triangle_domain_indices.clear()
	_interned_domain_sources.clear()
	_interned_domain_source_indices.clear()
	_candidate_count = 0
	_coarse_valid_candidate_count = 0
	_refined_valid_candidate_count = 0
	_refinement_cell_count = 0
	_refinement_cell_visit_count = 0
	_valid_candidate_count = 0
	_staged_candidate_count = 0
	_bounded_candidate_pruned_count = 0
	_canonical_candidate_count = 0
	_fallback_candidate_count = 0
	_fallback_triangle_count = 0
	_fallback_candidate_reservations = 0
	rejected_no_safe_offset_count = 0
	rejected_inside_or_indeterminate_center_count = 0
	rejected_duplicate_count = 0
	rejected_center_outside_count = 0
	rejected_foreign_surface_center_count = 0
	rejected_owner_connection_count = 0
	rejected_owner_connection_empty_count = 0
	rejected_owner_connection_mismatch_count = 0
	owner_connection_raw_anchor_count = 0
	rejected_owner_backside_center_count = 0
	rejected_center_clearance_count = 0
	rejected_ambiguous_side_count = 0
	rejected_center_overlap_count = 0
	rejected_world_cell_competition_count = 0
	rejected_lookup_capacity_count = 0
	rejected_arbitration_cell_limit_count = 0
	adjusted_center_count = 0
	error_message = ""
	warning_message = ""
	bvh_ready = bvh != null

func _valid_bounds(bounds: AABB) -> bool:
	return bounds.position.is_finite() and bounds.size.is_finite() \
			and bounds.size.x > 0.0 and bounds.size.y > 0.0 and bounds.size.z > 0.0

func _sample_collected_geometry() -> bool:
	_active_candidate_spacing = _probe_spacing
	if _refresh_cancelled() or not _sample_geometry_triangles(false, {}):
		_clear_fallback_triangle_queue()
		return false
	if _refresh_cancelled() or not _sample_fallback_triangles():
		return false
	return true

func _sample_refined_geometry(refinement_cells: Dictionary) -> bool:
	if refinement_cells.is_empty():
		return true
	_active_candidate_spacing = _arbitration_spacing
	var sampled := _sample_geometry_triangles(true, refinement_cells)
	_active_candidate_spacing = _probe_spacing
	return sampled

func _sample_geometry_triangles(refined: bool,
		refinement_cells: Dictionary) -> bool:
	for face_offset in range(0, faces.size(), 3):
		if face_offset % (REFRESH_WORKER_CHECK_INTERVAL * 3) == 0 and _refresh_cancelled():
			return false
		var source_face_index := int(face_offset / 3)
		_sample_source_id = int(face_source_ids[source_face_index])
		_sample_surface_index = int(face_surface_indices[source_face_index])
		_sample_domain_source = String(face_domain_sources[source_face_index])
		_sample_face_index = source_face_index
		var a: Vector3 = faces[face_offset]
		var b: Vector3 = faces[face_offset + 1]
		var c: Vector3 = faces[face_offset + 2]
		var polygon := [_inverse * a, _inverse * b, _inverse * c]
		polygon = _clip_polygon(polygon, 0, -_volume_size.x * 0.5, true)
		polygon = _clip_polygon(polygon, 0, _volume_size.x * 0.5, false)
		polygon = _clip_polygon(polygon, 1, -_volume_size.y * 0.5, true)
		polygon = _clip_polygon(polygon, 1, _volume_size.y * 0.5, false)
		polygon = _clip_polygon(polygon, 2, -_volume_size.z * 0.5, true)
		polygon = _clip_polygon(polygon, 2, _volume_size.z * 0.5, false)
		if polygon.size() < 3:
			continue
		var root: Vector3 = polygon[0]
		for i in range(1, polygon.size() - 1):
			var p0: Vector3 = _volume_transform * root
			var p1: Vector3 = _volume_transform * polygon[i]
			var p2: Vector3 = _volume_transform * polygon[i + 1]
			var clipped_normal := (p2 - p0).cross(p1 - p0).normalized()
			if clipped_normal.length_squared() < 0.5:
				continue
			var source_normal_sign := _source_face_outward_sign(
					_sample_source_id, source_face_index, p0, p1, p2, clipped_normal)
			if source_normal_sign == 0.0:
				if not refined:
					rejected_ambiguous_side_count += 1
				continue
			clipped_normal *= source_normal_sign
			var sampled := _sample_triangle_in_refinement_cells(p0, p1, p2,
					clipped_normal, source_face_index, refinement_cells) if refined \
					else _sample_triangle(p0, p1, p2, clipped_normal, source_face_index)
			if not sampled:
				return false
	return true

func _sample_triangle_in_refinement_cells(a: Vector3, b: Vector3, c: Vector3,
		normal: Vector3, owner_face_index: int, refinement_cells: Dictionary) -> bool:
	var triangle_centroid := (a + b + c) / 3.0
	if not _world_point_coordinates_are_supported(a) \
			or not _world_point_coordinates_are_supported(b) \
			or not _world_point_coordinates_are_supported(c):
		error_message = "Probe centers exceed the supported signed world-cell coordinate range."
		return false
	var dominant_axis := _dominant_normal_axis(normal)
	var projected_axes := _projected_axes(dominant_axis)
	var axis_u := projected_axes.x
	var axis_v := projected_axes.y
	var dominant_normal := normal[dominant_axis]
	if absf(dominant_normal) < 0.000001:
		return true
	var minimum := a.min(b).min(c)
	var maximum := a.max(b).max(c)
	var cell_min := Vector3i((minimum / _probe_spacing).floor())
	var cell_max := Vector3i((maximum / _probe_spacing).floor())
	var low_u := minf(a[axis_u], minf(b[axis_u], c[axis_u]))
	var high_u := maxf(a[axis_u], maxf(b[axis_u], c[axis_u]))
	var low_v := minf(a[axis_v], minf(b[axis_v], c[axis_v]))
	var high_v := maxf(a[axis_v], maxf(b[axis_v], c[axis_v]))
	var generated := 0
	var cell_count_x: int = int(cell_max.x) - int(cell_min.x) + 1
	var cell_count_y: int = int(cell_max.y) - int(cell_min.y) + 1
	var cell_count_z: int = int(cell_max.z) - int(cell_min.z) + 1
	var bounds_cell_count := 1
	var bounds_exceeds_budget := false
	for extent in [cell_count_x, cell_count_y, cell_count_z]:
		if extent <= 0 or extent > MAX_REFINEMENT_CELL_VISITS \
				or bounds_cell_count * extent > MAX_REFINEMENT_CELL_VISITS:
			bounds_exceeds_budget = true
			break
		bounds_cell_count *= extent
	var scan_marked_cells := bounds_exceeds_budget \
			or bounds_cell_count > refinement_cells.size()
	var scan_count := refinement_cells.size() if scan_marked_cells else bounds_cell_count
	if scan_count > MAX_REFINEMENT_CELL_VISITS - _refinement_cell_visit_count:
		error_message = "Adaptive triangle-to-feature matching exceeds its bounded cell-query budget."
		return false
	if scan_marked_cells:
		var checked_cells := 0
		for cell_value in refinement_cells:
			checked_cells += 1
			if checked_cells % REFRESH_WORKER_CHECK_INTERVAL == 0 and _refresh_cancelled():
				return false
			_refinement_cell_visit_count += 1
			var world_cell: Vector3i = cell_value
			if world_cell.x < cell_min.x or world_cell.x > cell_max.x \
					or world_cell.y < cell_min.y or world_cell.y > cell_max.y \
					or world_cell.z < cell_min.z or world_cell.z > cell_max.z:
				continue
			var cell_generated := _sample_refinement_cell(a, b, c, normal,
					triangle_centroid, owner_face_index, world_cell, axis_u, axis_v,
					dominant_axis, dominant_normal, low_u, high_u, low_v, high_v)
			if cell_generated < 0:
				return false
			generated += cell_generated
	else:
		var checked_cells := 0
		for z in range(cell_min.z, cell_max.z + 1):
			for y in range(cell_min.y, cell_max.y + 1):
				for x in range(cell_min.x, cell_max.x + 1):
					checked_cells += 1
					if checked_cells % REFRESH_WORKER_CHECK_INTERVAL == 0 and _refresh_cancelled():
						return false
					_refinement_cell_visit_count += 1
					var world_cell := Vector3i(x, y, z)
					if not refinement_cells.has(world_cell):
						continue
					var cell_generated := _sample_refinement_cell(a, b, c, normal,
							triangle_centroid, owner_face_index, world_cell, axis_u, axis_v,
							dominant_axis, dominant_normal, low_u, high_u, low_v, high_v)
					if cell_generated < 0:
						return false
					generated += cell_generated
	# Preserve tiny isolated geometry that has no centered min-spacing sample.
	var area := (b - a).cross(c - a).length() * 0.5
	if generated == 0 and area <= _active_candidate_spacing * _active_candidate_spacing * 0.25 \
			and refinement_cells.has(ProbeLayout.world_cell(triangle_centroid, _probe_spacing)):
		_candidate_count += 1
		if _candidate_count > MAX_SAMPLE_CANDIDATES:
			error_message = "Adaptive surface refinement exceeds the 2,000,000-candidate work budget."
			return false
		_fallback_candidate_count += 1
		_add_surface(triangle_centroid, normal, triangle_centroid, owner_face_index, false,
				a, b, c)
		if not error_message.is_empty():
			return false
	return true

func _sample_refinement_cell(a: Vector3, b: Vector3, c: Vector3,
		normal: Vector3, triangle_centroid: Vector3, owner_face_index: int,
		world_cell: Vector3i, axis_u: int, axis_v: int, dominant_axis: int,
		dominant_normal: float, low_u: float, high_u: float,
		low_v: float, high_v: float) -> int:
	var cell_low_u := maxf(low_u, float(world_cell[axis_u]) * _probe_spacing)
	var cell_high_u := minf(high_u, float(world_cell[axis_u] + 1) * _probe_spacing)
	var cell_low_v := maxf(low_v, float(world_cell[axis_v]) * _probe_spacing)
	var cell_high_v := minf(high_v, float(world_cell[axis_v] + 1) * _probe_spacing)
	var first_u := ceili(cell_low_u / _active_candidate_spacing - 0.5 - 0.000001)
	var last_u := floori(cell_high_u / _active_candidate_spacing - 0.5 + 0.000001)
	var first_v := ceili(cell_low_v / _active_candidate_spacing - 0.5 - 0.000001)
	var last_v := floori(cell_high_v / _active_candidate_spacing - 0.5 + 0.000001)
	var generated := 0
	var checked_candidates := 0
	for fine_v in range(first_v, last_v + 1):
		for fine_u in range(first_u, last_u + 1):
			checked_candidates += 1
			if checked_candidates % REFRESH_WORKER_CHECK_INTERVAL == 0 and _refresh_cancelled():
				return -1
			_candidate_count += 1
			if _candidate_count > MAX_SAMPLE_CANDIDATES:
				error_message = "Adaptive surface refinement exceeds the 2,000,000-candidate work budget."
				return -1
			var point := Vector3.ZERO
			point[axis_u] = (float(fine_u) + 0.5) * _active_candidate_spacing
			point[axis_v] = (float(fine_v) + 0.5) * _active_candidate_spacing
			point[dominant_axis] = a[dominant_axis] - (
				normal[axis_u] * (point[axis_u] - a[axis_u])
					+ normal[axis_v] * (point[axis_v] - a[axis_v])) / dominant_normal
			if ProbeLayout.world_cell(point, _probe_spacing) != world_cell \
					or not _point_is_in_triangle(point, a, b, c):
				continue
			generated += 1
			_canonical_candidate_count += 1
			_add_surface(point, normal, triangle_centroid, owner_face_index, true,
					a, b, c)
			if not error_message.is_empty():
				return -1
	return generated

func _collect_node(node: Node) -> void:
	if not error_message.is_empty():
		return
	# A nested SubViewport with its own World3D is a hard scene boundary. Geometry
	# and sources from it must not leak into another world's transport.
	if SceneTracker.should_skip_world_boundary(node, _scene_root, _world):
		return
	if node is MeshInstance3D and node.mesh != null and node.is_visible_in_tree():
		_collect_mesh(node)
	elif node.is_class("Terrain3D") and node.get("data") != null and node.is_visible_in_tree():
		_collect_terrain(node)
	for child in node.get_children():
		_collect_node(child)
		if not error_message.is_empty():
			return

func _collect_mesh(node: MeshInstance3D) -> void:
	var mesh: Mesh = node.mesh
	var mesh_world_box: AABB = node.global_transform * mesh.get_aabb()
	if not mesh_world_box.grow(BROADPHASE_EPSILON).intersects(_bake_world_bounds.grow(BROADPHASE_EPSILON)):
		return
	_register_occlusion_volume(node, mesh, mesh_world_box)
	if mesh is PrimitiveMesh:
		var arrays: Array = mesh.get_mesh_arrays()
		if not arrays.is_empty() and arrays[Mesh.ARRAY_VERTEX] != null:
			_collect_surface_triangles(node, 0, arrays, mesh)
			return
		_collect_faces_only_mesh(node, mesh)
		return
	if not mesh is ArrayMesh:
		if mesh.get_surface_count() > 1:
			error_message = "Non-ArrayMesh resources with multiple material surfaces cannot provide per-face reflectance."
			return
		_collect_faces_only_mesh(node, mesh)
		return
	for surface in mesh.get_surface_count():
		if mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var arrays := mesh.surface_get_arrays(surface)
		_collect_surface_triangles(node, surface, arrays)
		if not error_message.is_empty():
			return

func _register_occlusion_volume(node: MeshInstance3D, mesh: Mesh, mesh_world_box: AABB) -> void:
	var instance_id := node.get_instance_id()
	var placement_box := _world_bounds.grow(_preferred_offset_value + BROADPHASE_EPSILON)
	if not mesh_world_box.grow(BROADPHASE_EPSILON).intersects(placement_box):
		return
	if _mesh_has_transparent_surface(node, mesh):
		return # Transparent faces are omitted from the static BVH, so they cannot define occupied volume.
	var local_faces: PackedVector3Array = mesh.get_faces()
	if local_faces.size() < 12 or local_faces.size() % 3 != 0 \
			or local_faces.size() / 3 > MAX_OCCLUSION_TRIANGLES:
		return
	if not _mesh_faces_are_watertight(local_faces):
		return # Open meshes and terrain are not interpreted as solid volumes.
	var world_faces := PackedVector3Array()
	world_faces.resize(local_faces.size())
	for index in local_faces.size():
		world_faces[index] = node.global_transform * local_faces[index]
	var mesh_bvh := TriangleMesh.new()
	if not mesh_bvh.create_from_faces(world_faces):
		return
	var solid_index := _occlusion_volumes.size()
	_occlusion_volumes.append({
		"instance_id": instance_id,
		"world_aabb": mesh_world_box,
		"bvh": mesh_bvh,
		"faces": world_faces,
	})
	_source_volume_indices[instance_id] = solid_index

func _mesh_has_transparent_surface(node: MeshInstance3D, mesh: Mesh) -> bool:
	for surface in mesh.get_surface_count():
		var material: Material = node.get_active_material(surface)
		if material is BaseMaterial3D \
				and material.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
			return true
	return false

func _mesh_faces_are_watertight(local_faces: PackedVector3Array) -> bool:
	var vertex_ids: Dictionary = {}
	var edge_counts: Dictionary = {}
	for face_offset in range(0, local_faces.size(), 3):
		var triangle_ids := PackedInt32Array()
		for corner in 3:
			var point: Vector3 = local_faces[face_offset + corner]
			var vertex_key := Vector3i(
					roundi(point.x / OCCLUSION_WELD_EPSILON),
					roundi(point.y / OCCLUSION_WELD_EPSILON),
					roundi(point.z / OCCLUSION_WELD_EPSILON))
			if not vertex_ids.has(vertex_key):
				vertex_ids[vertex_key] = vertex_ids.size()
			triangle_ids.append(int(vertex_ids[vertex_key]))
		var skip_face := triangle_ids[0] == triangle_ids[1] \
				or triangle_ids[1] == triangle_ids[2] or triangle_ids[2] == triangle_ids[0]
		if not skip_face:
			var a: Vector3 = local_faces[face_offset]
			var b: Vector3 = local_faces[face_offset + 1]
			var c: Vector3 = local_faces[face_offset + 2]
			var face_normal := (c - a).cross(b - a).normalized()
			skip_face = face_normal.length_squared() < 0.5
		if not skip_face:
			for edge_index in 3:
				var first := triangle_ids[edge_index]
				var second := triangle_ids[(edge_index + 1) % 3]
				var low := mini(first, second)
				var high := maxi(first, second)
				var edge_key: int = (low << 32) | high
				edge_counts[edge_key] = int(edge_counts.get(edge_key, 0)) + 1
	if edge_counts.is_empty():
		return false
	for count in edge_counts.values():
		if int(count) != 2:
			return false # Boundary and non-manifold edges are not closed solids.
	return true

func _collect_faces_only_mesh(node: MeshInstance3D, mesh: Mesh) -> void:
	var primitive_faces: PackedVector3Array = mesh.get_faces()
	if primitive_faces.is_empty():
		return
	_triangle_source_id = node.get_instance_id()
	_triangle_surface_index = 0
	_triangle_domain_source = _mesh_domain_source(node, mesh)
	if not _prepare_surface(node, 0):
		return
	if _triangle_emitter_index >= 0:
		error_message = "An emissive mesh without CPU-accessible UV arrays cannot be baked as an area source."
		return
	for i in range(0, primitive_faces.size() - 2, 3):
		var a: Vector3 = node.global_transform * primitive_faces[i]
		var b: Vector3 = node.global_transform * primitive_faces[i + 1]
		var c: Vector3 = node.global_transform * primitive_faces[i + 2]
		if not _triangle(a, b, c):
			return

func _collect_surface_triangles(node: MeshInstance3D, surface: int, arrays: Array,
		primitive_mesh: PrimitiveMesh = null) -> void:
	if arrays.is_empty() or arrays[Mesh.ARRAY_VERTEX] == null:
		return
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	var uv1: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if arrays.size() > Mesh.ARRAY_TEX_UV and arrays[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
	var uv2: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2] if arrays.size() > Mesh.ARRAY_TEX_UV2 and arrays[Mesh.ARRAY_TEX_UV2] != null else PackedVector2Array()
	var count := indices.size() if not indices.is_empty() else vertices.size()
	var snapped_faces: PackedVector3Array
	if primitive_mesh != null:
		snapped_faces = primitive_mesh.get_faces()
		if count % 3 != 0 or snapped_faces.size() != count:
			error_message = "PrimitiveMesh face positions and array UV indices disagree; refusing unstable surface data."
			return
	_triangle_source_id = node.get_instance_id()
	_triangle_surface_index = surface
	_triangle_domain_source = _mesh_domain_source(node, node.mesh)
	if not _prepare_surface(node, surface, uv1, uv2, vertices.size()):
		return
	for i in range(0, count - 2, 3):
		var ia := indices[i] if not indices.is_empty() else i
		var ib := indices[i + 1] if not indices.is_empty() else i + 1
		var ic := indices[i + 2] if not indices.is_empty() else i + 2
		# PrimitiveMesh.get_faces() snaps positions through TriangleMesh; preserve
		# that legacy geometry order while taking UVs from the matching arrays.
		var a: Vector3 = node.global_transform * (snapped_faces[i] if primitive_mesh != null else vertices[ia])
		var b: Vector3 = node.global_transform * (snapped_faces[i + 1] if primitive_mesh != null else vertices[ib])
		var c: Vector3 = node.global_transform * (snapped_faces[i + 2] if primitive_mesh != null else vertices[ic])
		var ta := uv1[ia] if uv1.size() == vertices.size() else Vector2.ZERO
		var tb := uv1[ib] if uv1.size() == vertices.size() else Vector2.ZERO
		var tc := uv1[ic] if uv1.size() == vertices.size() else Vector2.ZERO
		var t2a := uv2[ia] if uv2.size() == vertices.size() else Vector2.ZERO
		var t2b := uv2[ib] if uv2.size() == vertices.size() else Vector2.ZERO
		var t2c := uv2[ic] if uv2.size() == vertices.size() else Vector2.ZERO
		if not _triangle(a, b, c, ta, tb, tc, t2a, t2b, t2c):
			return

func _prepare_surface(node: MeshInstance3D, surface: int,
		uv1 := PackedVector2Array(), uv2 := PackedVector2Array(), vertex_count := 0) -> bool:
	_triangle_emitter_index = -1
	var material := node.get_active_material(surface)
	_triangle_material = -1
	if material is BaseMaterial3D:
		_triangle_material = material_sampler.register(material, vertex_count > 0 and uv1.size() == vertex_count)
		if not material_sampler.error_message.is_empty():
			error_message = material_sampler.error_message
			return false
	if material is BaseMaterial3D and material.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
		if _collect_emission and material.emission_enabled:
			error_message = "Transparent emissive surfaces are not supported by the static area-source baker."
		return false # Transparent surfaces cannot be represented by this opaque PRT bake.
	_triangle_reflectance = _material_reflectance(material)
	if _collect_emission and material is BaseMaterial3D and material.emission_enabled:
		_triangle_emitter_index = emitters.register_surface(
				_scene_root, node, surface, material, uv1, uv2, vertex_count)
		if not emitters.error_message.is_empty():
			error_message = emitters.error_message
			return false
	return true

func _material_reflectance(material: Material) -> Vector3:
	if material != null and _material_cache.has(material):
		return _material_cache[material]
	var color: Vector3 = Vector3.ONE * _fallback_reflectance
	if material is BaseMaterial3D:
		var linear: Color = material.albedo_color.srgb_to_linear()
		color = Vector3(linear.r, linear.g, linear.b) * (1.0 - material.metallic)
	elif material is ShaderMaterial:
		push_warning("FMagicGI: ShaderMaterial reflectance is not evaluated offline; using Fallback Material Reflectance.")
	if material != null:
		_material_cache[material] = color
	return color

func _has_true_boolean_property(object: Object, property_name: StringName) -> bool:
	if object == null:
		return false
	for property_info in object.get_property_list():
		if StringName(property_info.get("name", "")) != property_name:
			continue
		var property_value: Variant = object.get(property_name)
		return property_value is bool and property_value
	return false

func _collect_terrain(terrain: Node3D) -> void:
	_triangle_emitter_index = -1
	_triangle_material = -1
	_triangle_source_id = terrain.get_instance_id()
	_triangle_surface_index = -1
	_triangle_domain_source = _terrain_domain_source(terrain)
	var data = terrain.get("data")
	if not data.has_method("get_surface_height"):
		error_message = "Terrain3D data is missing get_surface_height(); refusing raw height sampling."
		return
	var box := _bake_world_bounds
	var step: float = _probe_spacing
	var vertex_spacing: float = terrain.get("vertex_spacing")
	if _streamed_page:
		# Terrain3D height sampling cannot recover sub-vertex detail. A streamed
		# page collector uses the authored source resolution, then independently
		# places probes at the requested (possibly finer) spacing.
		step = maxf(vertex_spacing, 0.25)
	else:
		step = minf(step, maxf(vertex_spacing, 0.25))
	var start := Vector2(floor(box.position.x / step) * step, floor(box.position.z / step) * step)
	var end := box.end
	var nx := ceili((end.x - start.x) / step) + 1
	var nz := ceili((end.z - start.y) / step) + 1
	_terrain_work += nx * nz
	if nx <= 1 or nz <= 1 or _terrain_work > MAX_TERRAIN_CELLS:
		error_message = "Terrain sampling exceeds the 500,000-cell work limit; increase Probe Spacing or reduce Bake Distance."
		return
	var heights := PackedFloat32Array()
	heights.resize(nx * nz)
	for z in nz:
		for x in nx:
			var query := Vector3(start.x + x * step, 0.0, start.y + z * step)
			heights[z * nx + x] = data.call("get_surface_height", query)
	var color: Vector3 = Vector3.ONE * _terrain_reflectance
	for z in nz - 1:
		for x in nx - 1:
			var h00: float = heights[z * nx + x]
			var h10: float = heights[z * nx + x + 1]
			var h01: float = heights[(z + 1) * nx + x]
			var h11: float = heights[(z + 1) * nx + x + 1]
			# get_surface_height returns NaN over holes (including interpolation
			# footprints touching a hole), so no triangles bridge missing terrain.
			if not is_finite(h00) or not is_finite(h10) or not is_finite(h01) or not is_finite(h11):
				continue
			var a := Vector3(start.x + x * step, h00, start.y + z * step)
			var b := Vector3(start.x + (x + 1) * step, h10, start.y + z * step)
			var c := Vector3(start.x + x * step, h01, start.y + (z + 1) * step)
			var d := Vector3(start.x + (x + 1) * step, h11, start.y + (z + 1) * step)
			_triangle_reflectance = color
			if not _triangle(a, b, c) or not _triangle(b, d, c):
				return

func _triangle(a: Vector3, b: Vector3, c: Vector3,
		uv1_a := Vector2.ZERO, uv1_b := Vector2.ZERO, uv1_c := Vector2.ZERO,
		uv2_a := Vector2.ZERO, uv2_b := Vector2.ZERO, uv2_c := Vector2.ZERO) -> bool:
	var triangle_box := AABB(a, Vector3.ZERO).expand(b).expand(c)
	if not triangle_box.grow(BROADPHASE_EPSILON).intersects(_bake_world_bounds.grow(BROADPHASE_EPSILON)):
		return true
	var normal := (c - a).cross(b - a).normalized() # Godot triangle surfaces use clockwise front faces.
	if normal.length_squared() < 0.5:
		return true
	if reflectance.size() >= MAX_GEOMETRY_TRIANGLES:
		error_message = "PRT geometry exceeds the 250,000-triangle sampling/signature budget."
		return false
	faces.append_array([a, b, c])
	reflectance.append(_triangle_reflectance)
	face_materials.append(_triangle_material)
	face_uv.append_array([uv1_a, uv1_b, uv1_c])
	face_uv2.append_array([uv2_a, uv2_b, uv2_c])
	face_source_ids.append(_triangle_source_id)
	face_surface_indices.append(_triangle_surface_index)
	face_domain_sources.append(_triangle_domain_source)
	var face_emitter_index := -1
	if _triangle_emitter_index >= 0 and emitters.append_triangle(_triangle_emitter_index, a, b, c,
			uv1_a, uv1_b, uv1_c, uv2_a, uv2_b, uv2_c, face_emitter_indices.size()):
		face_emitter_index = _triangle_emitter_index
	face_emitter_indices.append(face_emitter_index)
	return true

func _sample_triangle(a: Vector3, b: Vector3, c: Vector3, normal: Vector3,
		owner_face_index: int) -> bool:
	if not _world_point_coordinates_are_supported(a) \
			or not _world_point_coordinates_are_supported(b) \
			or not _world_point_coordinates_are_supported(c):
		error_message = "Probe centers exceed the supported signed world-cell coordinate range."
		return false
	var triangle_centroid := (a + b + c) / 3.0
	var longest := maxf(a.distance_to(b), maxf(a.distance_to(c), b.distance_to(c)))
	var steps := _triangle_fallback_steps(longest)
	if steps > MAX_TRIANGLE_STEPS:
		error_message = "A clipped surface triangle exceeds the sampling budget; increase Probe Spacing."
		return false
	var dominant_axis := _dominant_normal_axis(normal)
	var projected_axes := _projected_axes(dominant_axis)
	var axis_u := projected_axes.x
	var axis_v := projected_axes.y
	var low_u := minf(a[axis_u], minf(b[axis_u], c[axis_u]))
	var high_u := maxf(a[axis_u], maxf(b[axis_u], c[axis_u]))
	var low_v := minf(a[axis_v], minf(b[axis_v], c[axis_v]))
	var high_v := maxf(a[axis_v], maxf(b[axis_v], c[axis_v]))
	var first_u := ceili(low_u / _active_candidate_spacing - 0.5 - 0.000001)
	var last_u := floori(high_u / _active_candidate_spacing - 0.5 + 0.000001)
	var first_v := ceili(low_v / _active_candidate_spacing - 0.5 - 0.000001)
	var last_v := floori(high_v / _active_candidate_spacing - 0.5 + 0.000001)
	var canonical_points_inside := 0
	var dominant_normal := normal[dominant_axis]
	var checked_candidates := 0
	if absf(dominant_normal) > 0.000001 and first_u <= last_u and first_v <= last_v:
		for cell_v in range(first_v, last_v + 1):
			for cell_u in range(first_u, last_u + 1):
				checked_candidates += 1
				if checked_candidates % REFRESH_WORKER_CHECK_INTERVAL == 0 and _refresh_cancelled():
					return false
				_candidate_count += 1
				if _candidate_count > MAX_SAMPLE_CANDIDATES:
					error_message = "Surface sampling exceeds the 2,000,000-candidate work budget."
					return false
				var point := Vector3.ZERO
				point[axis_u] = (float(cell_u) + 0.5) * _active_candidate_spacing
				point[axis_v] = (float(cell_v) + 0.5) * _active_candidate_spacing
				point[dominant_axis] = a[dominant_axis] - (
					normal[axis_u] * (point[axis_u] - a[axis_u])
						+ normal[axis_v] * (point[axis_v] - a[axis_v])) / dominant_normal
				if not _point_is_in_triangle(point, a, b, c):
					continue
				canonical_points_inside += 1
				_canonical_candidate_count += 1
				_add_surface(point, normal, triangle_centroid, owner_face_index, true,
						a, b, c)
				if not error_message.is_empty():
					return false
		# Raw barycentric samples are delayed until all canonical grid candidates
		# have been staged, so a fine tessellation cannot consume their budget or
		# bounded per-cell slots before a later triangle contributes the grid point.
	if canonical_points_inside == 0:
		return _queue_fallback_triangle(a, b, c, normal, owner_face_index, steps)
	return true

func _triangle_fallback_steps(longest: float) -> int:
	# Retain the bounded barycentric lattice only for triangles without a
	# canonical projected grid point. Large faces use a half-spacing fallback.
	var candidate_step := _active_candidate_spacing
	if longest > _active_candidate_spacing * 8.0:
		candidate_step = maxf(0.05, _active_candidate_spacing * 0.5)
	return maxi(1, ceili(longest / candidate_step))

func _queue_fallback_triangle(a: Vector3, b: Vector3, c: Vector3, normal: Vector3,
		owner_face_index: int, steps: int) -> bool:
	var fallback_point_count := int((steps + 1) * (steps + 2) / 2)
	if steps == 1:
		fallback_point_count += 1
	if _candidate_count + _fallback_candidate_reservations + fallback_point_count \
			> MAX_SAMPLE_CANDIDATES:
		error_message = "Surface sampling exceeds the 2,000,000-candidate work budget."
		return false
	var source_index := int(_interned_domain_source_indices.get(_sample_domain_source, -1))
	if source_index < 0:
		source_index = _interned_domain_sources.size()
		_interned_domain_sources.append(_sample_domain_source)
		_interned_domain_source_indices[_sample_domain_source] = source_index
	_fallback_triangle_vertices.append_array([a, b, c])
	_fallback_triangle_normals.append(normal)
	_fallback_triangle_source_ids.append(_sample_source_id)
	_fallback_triangle_surface_indices.append(_sample_surface_index)
	_fallback_triangle_face_indices.append(owner_face_index)
	_fallback_triangle_domain_indices.append(source_index)
	_fallback_candidate_reservations += fallback_point_count
	_fallback_triangle_count += 1
	return true

func _sample_fallback_triangles() -> bool:
	for triangle_index in _fallback_triangle_normals.size():
		if triangle_index % REFRESH_WORKER_CHECK_INTERVAL == 0 and _refresh_cancelled():
			return false
		var vector_index := triangle_index * 3
		var a: Vector3 = _fallback_triangle_vertices[vector_index]
		var b: Vector3 = _fallback_triangle_vertices[vector_index + 1]
		var c: Vector3 = _fallback_triangle_vertices[vector_index + 2]
		var normal: Vector3 = _fallback_triangle_normals[triangle_index]
		_sample_source_id = int(_fallback_triangle_source_ids[triangle_index])
		_sample_surface_index = int(_fallback_triangle_surface_indices[triangle_index])
		_sample_face_index = int(_fallback_triangle_face_indices[triangle_index])
		_sample_domain_source = _interned_domain_sources[
				_fallback_triangle_domain_indices[triangle_index]]
		var steps := _triangle_fallback_steps(maxf(a.distance_to(b),
				maxf(a.distance_to(c), b.distance_to(c))))
		_fallback_candidate_reservations -= int((steps + 1) * (steps + 2) / 2)
		if steps == 1:
			_fallback_candidate_reservations -= 1
		if not _sample_triangle_fallback(a, b, c, normal, _sample_face_index, steps):
			_clear_fallback_triangle_queue()
			return false
	_clear_fallback_triangle_queue()
	return true

func _clear_fallback_triangle_queue() -> void:
	_fallback_triangle_vertices.clear()
	_fallback_triangle_normals.clear()
	_fallback_triangle_source_ids.clear()
	_fallback_triangle_surface_indices.clear()
	_fallback_triangle_face_indices.clear()
	_fallback_triangle_domain_indices.clear()
	_interned_domain_sources.clear()
	_interned_domain_source_indices.clear()
	_fallback_candidate_reservations = 0

func _sample_triangle_fallback(a: Vector3, b: Vector3, c: Vector3,
		normal: Vector3, owner_face_index: int, steps: int) -> bool:
	var triangle_centroid := (a + b + c) / 3.0
	var accepted_before := _valid_candidate_count
	var checked_candidates := 0
	for u in steps + 1:
		for v in steps + 1 - u:
			checked_candidates += 1
			if checked_candidates % REFRESH_WORKER_CHECK_INTERVAL == 0 and _refresh_cancelled():
				return false
			_candidate_count += 1
			if _candidate_count > MAX_SAMPLE_CANDIDATES:
				error_message = "Surface sampling exceeds the 2,000,000-candidate work budget."
				return false
			_fallback_candidate_count += 1
			var point := a + (b - a) * (float(u) / steps) \
					+ (c - a) * (float(v) / steps)
			if _adaptive_placement:
				var estimated_center := point + normal * _preferred_offset_value
				var estimated_arbitration_cell := ProbeLayout.world_cell(
						estimated_center, _arbitration_spacing)
				var domain_key := _candidate_domain_key(normal, triangle_centroid)
				if _has_staged_candidate_for_arbitration_cell(
						domain_key, estimated_arbitration_cell):
					continue
			_add_surface(point, normal, triangle_centroid, owner_face_index, false,
					a, b, c)
			if not error_message.is_empty():
				return false
	# Retain the small-triangle centroid rescue, but only after all canonical grid
	# opportunities and the bounded raw fallback have been considered.
	if steps == 1 and _valid_candidate_count == accepted_before:
		var estimated_center := triangle_centroid + normal * _preferred_offset_value
		var estimated_arbitration_cell := ProbeLayout.world_cell(
				estimated_center, _arbitration_spacing)
		var domain_key := _candidate_domain_key(normal, triangle_centroid)
		if not _adaptive_placement \
				or not _has_staged_candidate_for_arbitration_cell(
					domain_key, estimated_arbitration_cell):
			_candidate_count += 1
			if _candidate_count > MAX_SAMPLE_CANDIDATES:
				error_message = "Surface sampling exceeds the 2,000,000-candidate work budget."
				return false
			_fallback_candidate_count += 1
			_add_surface(triangle_centroid, normal, triangle_centroid, owner_face_index, false,
					a, b, c)
			if not error_message.is_empty():
				return false
	return true

func _has_staged_candidate_for_arbitration_cell(domain_key: String,
		arbitration_cell: Vector3i) -> bool:
	var parent_cell := _arbitration_parent_cell(arbitration_cell)
	var parent_bucket: Dictionary = _world_candidate_cells.get(parent_cell, {})
	var arbitration_cells: Dictionary = parent_bucket.get("arbitration_cells", {})
	var cell_bucket: Dictionary = arbitration_cells.get(arbitration_cell, {})
	var domains: Dictionary = cell_bucket.get("domains", {})
	return domains.has(domain_key) and not domains[domain_key]["candidates"].is_empty()

func _arbitration_parent_cell(arbitration_cell: Vector3i) -> Vector3i:
	var arbitration_center := ProbeLayout.world_cell_center(
			arbitration_cell, _arbitration_spacing)
	return ProbeLayout.world_cell(arbitration_center, _probe_spacing)

func _dominant_normal_axis(normal: Vector3) -> int:
	var axis := 0
	if absf(normal.y) > absf(normal.x):
		axis = 1
	if absf(normal.z) > absf(normal[axis]):
		axis = 2
	return axis

func _projected_axes(dominant_axis: int) -> Vector2i:
	if dominant_axis == 0:
		return Vector2i(1, 2)
	if dominant_axis == 1:
		return Vector2i(0, 2)
	return Vector2i(0, 1)

func _point_is_in_triangle(point: Vector3, a: Vector3, b: Vector3, c: Vector3) -> bool:
	var edge_a := b - a
	var edge_b := c - a
	var relative := point - a
	var dot_aa := edge_a.dot(edge_a)
	var dot_ab := edge_a.dot(edge_b)
	var dot_bb := edge_b.dot(edge_b)
	var dot_ra := relative.dot(edge_a)
	var dot_rb := relative.dot(edge_b)
	var denominator := dot_aa * dot_bb - dot_ab * dot_ab
	if denominator <= 0.000000000001 * maxf(1.0, dot_aa * dot_bb):
		return false
	var bary_a := (dot_bb * dot_ra - dot_ab * dot_rb) / denominator
	var bary_b := (dot_aa * dot_rb - dot_ab * dot_ra) / denominator
	return bary_a >= -0.000001 and bary_b >= -0.000001 \
			and bary_a + bary_b <= 1.000001

func _center_has_owner_surface_connection(surface: Vector3, normal: Vector3,
		center: Vector3, owner_face_index: int) -> bool:
	var result := _owner_surface_connection_result(surface, normal, center, owner_face_index)
	return result == -2 or result >= 0

func _owner_surface_connection_result(surface: Vector3, normal: Vector3,
		center: Vector3, owner_face_index: int) -> int:
	if not bvh_ready:
		return -2
	if owner_face_index < 0 or owner_face_index * 3 + 2 >= faces.size():
		return -3
	var offset := (center - surface).dot(normal)
	if offset <= 0.0:
		return -3
	# TriangleMesh snaps BVH vertices to 1e-4 world units. Extend both ends of
	# this proof segment beyond the center/anchor so that quantization does not
	# turn a valid owner-face connection into an empty or neighboring-face hit.
	# This only proves the source connection; it does not move the probe center
	# or relax the separate foreign-surface clearance test.
	var epsilon := maxf(0.0002, _probe_spacing * 0.00001)
	var hit := bvh.intersect_segment(center + normal * epsilon,
			surface - normal * epsilon)
	if hit.is_empty():
		return -1
	var hit_face := int(hit.get("face_index", -1))
	if hit_face == owner_face_index \
			or _face_is_same_coplanar_surface(hit_face, owner_face_index, surface, normal):
		return hit_face
	return -4

func _center_is_on_owner_front_side(center: Vector3, normal: Vector3,
		owner_face_index: int) -> bool:
	if owner_face_index < 0 or owner_face_index * 3 + 2 >= faces.size():
		return false
	var a: Vector3 = faces[owner_face_index * 3]
	var b: Vector3 = faces[owner_face_index * 3 + 1]
	var c: Vector3 = faces[owner_face_index * 3 + 2]
	var raw_normal := (c - a).cross(b - a).normalized()
	var alignment := raw_normal.dot(normal)
	if raw_normal.length_squared() < 0.5 or absf(alignment) < 0.999:
		return false
	if alignment < 0.0:
		raw_normal = -raw_normal
	return (center - a).dot(raw_normal) > 0.0

func _surface_is_on_owner_face(surface: Vector3, owner_face_index: int,
		sample_a: Vector3, sample_b: Vector3, sample_c: Vector3) -> bool:
	if owner_face_index < 0 or owner_face_index * 3 + 2 >= faces.size():
		return false
	var a: Vector3 = faces[owner_face_index * 3]
	var b: Vector3 = faces[owner_face_index * 3 + 1]
	var c: Vector3 = faces[owner_face_index * 3 + 2]
	var face_normal := (c - a).cross(b - a).normalized()
	if face_normal.length_squared() < 0.5:
		return false
	var sample_normal := (sample_c - sample_a).cross(sample_b - sample_a).normalized()
	if sample_normal.length_squared() < 0.5 or absf(face_normal.dot(sample_normal)) < 0.9999:
		return false
	# Clipping transforms world vertices into Volume-local coordinates and back.
	# At large translations this can offset the clipped triangle's plane from the
	# original world face by a few float ulps. Bound that measured discrepancy
	# from this exact source-derived triangle; reject if it is too large relative
	# to probe spacing to remain a safe ownership proof.
	var sample_plane_deviation := maxf(
			absf(face_normal.dot(sample_a - a)),
			maxf(absf(face_normal.dot(sample_b - a)),
					absf(face_normal.dot(sample_c - a))))
	var plane_tolerance := sample_plane_deviation + maxf(0.0002, _probe_spacing * 0.00001)
	if plane_tolerance > _probe_spacing * 0.01:
		return false
	var plane_residual := absf(face_normal.dot(surface - a))
	if plane_residual > plane_tolerance:
		return false
	if not _point_is_in_triangle(surface, a, b, c):
		return false
	return true

func _center_has_foreign_surface_clearance(surface: Vector3, normal: Vector3,
		center: Vector3, owner_face_index: int) -> bool:
	# A valid owner-face connection does not prove that the probe center is clear
	# of another perpendicular/open surface. Probe six short, centered segments
	# around the center and reject any nearby finite BVH face outside the owner
	# coplanar continuation. This is deliberately bounded to the existing spacing
	# clearance scale; it does not infer infinite planes or move the probe.
	var clearance := maxf(0.000001, _probe_spacing * MIN_PROBE_OFFSET_SPACING_RATIO)
	var axes := [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
	for axis_value in axes:
		var axis: Vector3 = axis_value
		var hit := bvh.intersect_segment(center - axis * clearance,
				center + axis * clearance)
		if not hit.is_empty():
			var hit_face := int(hit.get("face_index", -1))
			if hit_face != owner_face_index \
					and not _face_is_same_coplanar_surface(hit_face, owner_face_index, surface, normal):
				return false
		# Cast the same segment in reverse too. If an owner/coplanar face is
		# first from one endpoint, this lets a nearer foreign face win from the
		# other side of the center.
		hit = bvh.intersect_segment(center + axis * clearance,
				center - axis * clearance)
		if not hit.is_empty():
			var reverse_hit_face := int(hit.get("face_index", -1))
			if reverse_hit_face != owner_face_index \
					and not _face_is_same_coplanar_surface(reverse_hit_face, owner_face_index, surface, normal):
				return false
	return true

func _face_is_same_coplanar_surface(hit_face_index: int, owner_face_index: int,
		surface: Vector3, owner_normal: Vector3) -> bool:
	if hit_face_index < 0 or hit_face_index * 3 + 2 >= faces.size() \
			or owner_face_index < 0 or owner_face_index * 3 + 2 >= faces.size():
		return false
	var hit_a: Vector3 = faces[hit_face_index * 3]
	var hit_b: Vector3 = faces[hit_face_index * 3 + 1]
	var hit_c: Vector3 = faces[hit_face_index * 3 + 2]
	var authored_normal := (hit_c - hit_a).cross(hit_b - hit_a).normalized()
	if _face_outward_signs.has(hit_face_index):
		authored_normal *= float(_face_outward_signs[hit_face_index])
	if authored_normal.length_squared() < 0.5 \
			or absf(authored_normal.dot(owner_normal)) < 0.999:
		return false
	var plane_tolerance := maxf(0.0002, _probe_spacing * 0.0001)
	return absf(owner_normal.dot(hit_a - surface)) <= plane_tolerance

func _add_surface(surface: Vector3, normal: Vector3, triangle_centroid: Vector3,
		owner_face_index: int, canonical: bool,
		sample_a: Vector3, sample_b: Vector3, sample_c: Vector3) -> void:
	if _streamed_page:
		var source_local := _source_volume_transform.affine_inverse() * surface
		var source_half := _source_volume_size * 0.5
		var source_epsilon := maxf(0.0001, _probe_spacing * 0.0001)
		if source_local.x < -source_half.x - source_epsilon \
				or source_local.x > source_half.x + source_epsilon \
				or source_local.y < -source_half.y - source_epsilon \
				or source_local.y > source_half.y + source_epsilon \
				or source_local.z < -source_half.z - source_epsilon \
				or source_local.z > source_half.z + source_epsilon:
			return
	var local := _inverse * surface
	var epsilon := maxf(0.0001, _probe_spacing * 0.0001)
	if local.x < -_volume_size.x * 0.5 - epsilon or local.x > _volume_size.x * 0.5 + epsilon \
			or local.y < -_volume_size.y * 0.5 - epsilon or local.y > _volume_size.y * 0.5 + epsilon \
			or local.z < -_volume_size.z * 0.5 - epsilon or local.z > _volume_size.z * 0.5 + epsilon:
		return
	var domain_key := _candidate_domain_key(normal, triangle_centroid)
	var stable_probe_id := _stable_probe_id(surface, normal)
	# Triangle meshes commonly repeat the same vertex on adjacent faces. Drop
	# only a near-identical anchor already retained for the same signed domain,
	# before running the more expensive offset and closed-solid tests.
	var estimated_center := surface + normal * _preferred_offset_value
	if not _world_point_coordinates_are_supported(estimated_center):
		error_message = "Probe centers exceed the supported signed world-cell coordinate range."
		return
	if _has_staged_anchor_duplicate(surface, domain_key):
		rejected_duplicate_count += 1
		return
	var actual_offset := _safe_probe_offset(surface, normal, _preferred_offset_value)
	if actual_offset <= 0.0:
		rejected_no_safe_offset_count += 1
		return
	var probe_center: Vector3 = surface + normal * actual_offset
	if not _world_point_coordinates_are_supported(probe_center):
		error_message = "Probe centers exceed the supported signed world-cell coordinate range."
		return
	var center_local := _inverse * probe_center
	if center_local.x < -_volume_size.x * 0.5 - epsilon \
			or center_local.x > _volume_size.x * 0.5 + epsilon \
			or center_local.y < -_volume_size.y * 0.5 - epsilon \
			or center_local.y > _volume_size.y * 0.5 + epsilon \
			or center_local.z < -_volume_size.z * 0.5 - epsilon \
			or center_local.z > _volume_size.z * 0.5 + epsilon:
		rejected_center_outside_count += 1
		return
	if not _center_is_on_owner_front_side(probe_center, normal, owner_face_index):
		rejected_owner_backside_center_count += 1
		rejected_foreign_surface_center_count += 1
		return
	var owner_connection_result := _owner_surface_connection_result(surface, normal,
			probe_center, owner_face_index)
	if owner_connection_result == -1 and _surface_is_on_owner_face(
			surface, owner_face_index, sample_a, sample_b, sample_c):
		# Empty BVH hit means the same segment found no foreign blocker. The raw
		# owner face plus this clipped-triangle containment prove the source side.
		owner_connection_raw_anchor_count += 1
		owner_connection_result = owner_face_index
	if owner_connection_result != -2 and owner_connection_result < 0:
		rejected_owner_connection_count += 1
		if owner_connection_result == -1:
			rejected_owner_connection_empty_count += 1
		else:
			rejected_owner_connection_mismatch_count += 1
		rejected_foreign_surface_center_count += 1
		return
	if not _center_has_foreign_surface_clearance(surface, normal, probe_center,
			owner_face_index):
		rejected_center_clearance_count += 1
		rejected_foreign_surface_center_count += 1
		return
	var grid: Vector3 = (local + _volume_size * 0.5) / _volume_size * Vector3(_dimensions)
	var cell := Data.cell_coordinates(grid, _dimensions)
	if cell.x < 0:
		error_message = "A sampled surface escaped the PRT lookup grid."
		return
	var cell_key := cell.x + cell.y * _dimensions.x + cell.z * _dimensions.x * _dimensions.y
	if _probe_center_is_inside_solid(probe_center):
		rejected_inside_or_indeterminate_center_count += 1
		return
	var world_cell := ProbeLayout.world_cell(probe_center, _probe_spacing)
	var arbitration_cell := ProbeLayout.world_cell(probe_center, _arbitration_spacing)
	var arbitration_key := _world_spacing_cell_key(probe_center, _arbitration_spacing)
	var arbitration_center := _world_spacing_cell_center(probe_center, _arbitration_spacing)
	_valid_candidate_count += 1
	var candidate := {
		"surface": surface,
		"center": probe_center,
		"normal": normal,
		"lookup_cell": cell_key,
		"domain": domain_key,
		"canonical": canonical,
		"face_index": owner_face_index,
		"world_cell": world_cell,
		"arbitration_cell": arbitration_cell,
		"stable_id": stable_probe_id,
		"arbitration_key": arbitration_key,
		"spacing": _active_candidate_spacing,
		"score": probe_center.distance_squared_to(
				arbitration_center),
	}
	_stage_world_candidate(_arbitration_parent_cell(arbitration_cell),
			domain_key, candidate)

func _candidate_capacity_per_domain() -> int:
	return ProbeLayout.CANDIDATES_PER_DOMAIN

func _world_spacing_cell_key(point: Vector3, spacing: float) -> String:
	var scaled := point / spacing
	return "%d,%d,%d" % [floori(scaled.x), floori(scaled.y), floori(scaled.z)]

func _world_spacing_cell_center(point: Vector3, spacing: float) -> Vector3:
	var lower := (point / spacing).floor() * spacing
	return lower + Vector3.ONE * spacing * 0.5

func _stage_world_candidate(parent_world_cell: Vector3i, domain_key: String,
		candidate: Dictionary) -> void:
	var coarse_bucket: Dictionary = _world_candidate_cells.get(parent_world_cell, {})
	var arbitration_cells: Dictionary = coarse_bucket.get("arbitration_cells", {})
	var arbitration_cell: Vector3i = candidate["arbitration_cell"]
	var cell_bucket: Dictionary = arbitration_cells.get(arbitration_cell, {})
	if cell_bucket.is_empty():
		if _staged_arbitration_cell_count >= MAX_STAGED_ARBITRATION_CELLS:
			rejected_arbitration_cell_limit_count += 1
			error_message = "Surface staging exceeds the 65,536 arbitration-cell limit. Increase Probe Spacing or reduce the volume."
			return
		cell_bucket = {"domains": {}}
		_staged_arbitration_cell_count += 1
	var domains: Dictionary = cell_bucket["domains"]
	var candidate_rank := ProbeLayout.world_cell_rank(domain_key, arbitration_cell)
	if domains.has(domain_key):
		var domain_bucket: Dictionary = domains[domain_key]
		var candidates: Array = domain_bucket["candidates"]
		var previous_candidates: Array = candidates.duplicate()
		candidates.append(candidate)
		candidates.sort_custom(Callable(self, "_candidate_less"))
		var capacity := _candidate_capacity_per_domain()
		if candidates.size() > capacity:
			candidates.resize(capacity)
		for previous_candidate in previous_candidates:
			if not candidates.has(previous_candidate):
				_unindex_staged_anchor(previous_candidate)
		_staged_candidate_count += candidates.size() - previous_candidates.size()
		if _staged_candidate_count > MAX_STAGED_CANDIDATE_RECORDS:
			error_message = "World-space probe candidate staging exceeds its bounded record limit."
		domain_bucket["canonical"] = bool(domain_bucket.get("canonical", false)) \
				or bool(candidate["canonical"])
		domain_bucket["candidates"] = candidates
		domains[domain_key] = domain_bucket
		cell_bucket["domains"] = domains
		arbitration_cells[arbitration_cell] = cell_bucket
		coarse_bucket["arbitration_cells"] = arbitration_cells
		_world_candidate_cells[parent_world_cell] = coarse_bucket
		if candidates.has(candidate):
			_index_staged_anchor(candidate)
		return
	if domains.size() >= ProbeLayout.MAX_DOMAINS_PER_ARBITRATION_CELL:
		var worst_key := ""
		var worst_rank := -1
		var worst_is_canonical := true
		for existing_key in domains:
			var existing_bucket: Dictionary = domains[existing_key]
			var existing_rank := int(existing_bucket["rank"])
			var existing_is_canonical := bool(existing_bucket.get("canonical", false))
			if worst_key.is_empty() \
					or (not existing_is_canonical and worst_is_canonical) \
					or (existing_is_canonical == worst_is_canonical \
					and (existing_rank > worst_rank \
					or (existing_rank == worst_rank and String(existing_key) > worst_key))):
				worst_key = String(existing_key)
				worst_rank = existing_rank
				worst_is_canonical = existing_is_canonical
		var candidate_is_canonical := bool(candidate["canonical"])
		if (not candidate_is_canonical and worst_is_canonical) \
				or (candidate_is_canonical == worst_is_canonical \
				and (candidate_rank > worst_rank \
				or (candidate_rank == worst_rank and domain_key >= worst_key))):
			return
		var evicted: Dictionary = domains[worst_key]
		var evicted_candidates: Array = evicted["candidates"]
		for evicted_candidate in evicted_candidates:
			_unindex_staged_anchor(evicted_candidate)
		_staged_candidate_count -= evicted_candidates.size()
		domains.erase(worst_key)
	var new_domain := {"rank": candidate_rank, "canonical": bool(candidate["canonical"]),
			"candidates": [candidate]}
	domains[domain_key] = new_domain
	_staged_candidate_count += 1
	if _staged_candidate_count > MAX_STAGED_CANDIDATE_RECORDS:
		error_message = "World-space probe candidate staging exceeds its bounded record limit."
	cell_bucket["domains"] = domains
	arbitration_cells[arbitration_cell] = cell_bucket
	coarse_bucket["arbitration_cells"] = arbitration_cells
	_world_candidate_cells[parent_world_cell] = coarse_bucket
	_index_staged_anchor(candidate)

func _anchor_index_cell(point: Vector3) -> PackedInt64Array:
	var anchor_epsilon := maxf(0.000001, _probe_spacing * 0.000001)
	return PackedInt64Array([
		floori(point.x / anchor_epsilon),
		floori(point.y / anchor_epsilon),
		floori(point.z / anchor_epsilon),
	])

func _anchor_index_key(domain_key: String, cell: PackedInt64Array,
		delta: Vector3i = Vector3i.ZERO) -> String:
	return domain_key + "\u001e%d,%d,%d" % [
		int(cell[0]) + delta.x, int(cell[1]) + delta.y, int(cell[2]) + delta.z]

func _has_staged_anchor_duplicate(surface: Vector3, domain_key: String) -> bool:
	var cell := _anchor_index_cell(surface)
	var anchor_epsilon := maxf(0.000001, _probe_spacing * 0.000001)
	var epsilon_squared := anchor_epsilon * anchor_epsilon
	for dz in range(-1, 2):
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var key := _anchor_index_key(domain_key, cell, Vector3i(dx, dy, dz))
				for existing_surface in _staged_anchor_index.get(key, []):
					if existing_surface.distance_squared_to(surface) <= epsilon_squared:
						return true
	return false

func _index_staged_anchor(candidate: Dictionary) -> void:
	var surface: Vector3 = candidate["surface"]
	var domain_key := String(candidate["domain"])
	var key := _anchor_index_key(domain_key, _anchor_index_cell(surface))
	var anchors: Array = _staged_anchor_index.get(key, [])
	var anchor_epsilon := maxf(0.000001, _probe_spacing * 0.000001)
	var epsilon_squared := anchor_epsilon * anchor_epsilon
	for existing_surface in anchors:
		if existing_surface.distance_squared_to(surface) <= epsilon_squared:
			return
	if _staged_anchor_index_count >= MAX_STAGED_CANDIDATE_RECORDS:
		error_message = "Surface anchor lookup exceeds the bounded candidate-record limit."
		return
	anchors.append(surface)
	_staged_anchor_index[key] = anchors
	_staged_anchor_index_count += 1

func _unindex_staged_anchor(candidate: Dictionary) -> void:
	var surface: Vector3 = candidate["surface"]
	var domain_key := String(candidate["domain"])
	var key := _anchor_index_key(domain_key, _anchor_index_cell(surface))
	if not _staged_anchor_index.has(key):
		return
	var anchors: Array = _staged_anchor_index[key]
	for index in anchors.size():
		if anchors[index] == surface:
			anchors.remove_at(index)
			_staged_anchor_index_count -= 1
			break
	if anchors.is_empty():
		_staged_anchor_index.erase(key)
	else:
		_staged_anchor_index[key] = anchors

func _candidate_domain_key(normal: Vector3, triangle_centroid: Vector3) -> String:
	var normal_bin := Vector3i(roundi(normal.x * 20.0), roundi(normal.y * 20.0),
			roundi(normal.z * 20.0))
	var plane_quantum := maxf(_probe_spacing * 0.05, 0.001)
	var plane_bin := roundi(normal.dot(triangle_centroid) / plane_quantum)
	return "%s\u001f%d\u001f%d,%d,%d\u001f%d" % [
		_sample_domain_source, _sample_surface_index, normal_bin.x, normal_bin.y,
		normal_bin.z, plane_bin]

func _stable_probe_id(surface: Vector3, normal: Vector3) -> int:
	# This identity is independent of page traversal/output order. Quantization is
	# far below placement spacing and removes only clipping roundoff at page edges.
	# Use signed 64-bit triples: Vector3i saturates/wraps after about 21.5 km at
	# this quantum, making otherwise distinct large-world probes share an ID.
	var quantum := maxf(0.00001, _probe_spacing * 0.00001)
	var surface_bin := PackedInt64Array([
		roundi(surface.x / quantum), roundi(surface.y / quantum), roundi(surface.z / quantum)])
	var normal_bin := PackedInt64Array([
		roundi(normal.x * 100000.0), roundi(normal.y * 100000.0), roundi(normal.z * 100000.0)])
	var identity_parts := [_sample_domain_source, _sample_surface_index, surface_bin, normal_bin]
	var low := int(hash(identity_parts)) & 0xffffffff
	var high := int(hash([identity_parts, "stable-probe-high"])) & 0xffffffff
	var identity := (high << 32) | low
	return identity if identity != 0 else 1

func _candidate_less(a: Dictionary, b: Dictionary) -> bool:
	var canonical_a := bool(a["canonical"])
	var canonical_b := bool(b["canonical"])
	if canonical_a != canonical_b:
		return canonical_a
	var spacing_a := float(a.get("spacing", _probe_spacing))
	var spacing_b := float(b.get("spacing", _probe_spacing))
	if spacing_a != spacing_b:
		return spacing_a < spacing_b
	var score_a := float(a["score"])
	var score_b := float(b["score"])
	if score_a != score_b:
		return score_a < score_b
	var surface_a: Vector3 = a["surface"]
	var surface_b: Vector3 = b["surface"]
	if surface_a.x != surface_b.x:
		return surface_a.x < surface_b.x
	if surface_a.y != surface_b.y:
		return surface_a.y < surface_b.y
	if surface_a.z != surface_b.z:
		return surface_a.z < surface_b.z
	var normal_a: Vector3 = a["normal"]
	var normal_b: Vector3 = b["normal"]
	if normal_a.x != normal_b.x:
		return normal_a.x < normal_b.x
	if normal_a.y != normal_b.y:
		return normal_a.y < normal_b.y
	return normal_a.z < normal_b.z

## Choose each arbitration cell locally, then apply a deterministic symmetric
## separation rule. Page-global acceptance ratios cannot change shared-cell winners.
func _finalize_world_candidates() -> bool:
	_bounded_candidate_pruned_count = maxi(0, _valid_candidate_count - _staged_candidate_count)
	var candidates_by_phase := [{}, {}]
	var staged_by_world_cell: Dictionary = {}
	var checked_candidates := 0
	for cell_value in _world_candidate_cells:
		if checked_candidates % REFRESH_WORKER_CHECK_INTERVAL == 0 and _refresh_cancelled():
			return false
		var coarse_bucket: Dictionary = _world_candidate_cells[cell_value]
		var arbitration_cells: Dictionary = coarse_bucket.get("arbitration_cells", {})
		for arbitration_cell_value in arbitration_cells:
			if checked_candidates % REFRESH_WORKER_CHECK_INTERVAL == 0 and _refresh_cancelled():
				return false
			var cell_bucket: Dictionary = arbitration_cells[arbitration_cell_value]
			var domains: Dictionary = cell_bucket["domains"]
			for domain_key in domains:
				if checked_candidates % REFRESH_WORKER_CHECK_INTERVAL == 0 and _refresh_cancelled():
					return false
				var domain_bucket: Dictionary = domains[domain_key]
				for candidate in domain_bucket["candidates"]:
					checked_candidates += 1
					if checked_candidates % REFRESH_WORKER_CHECK_INTERVAL == 0 and _refresh_cancelled():
						return false
					var base_world_cell: Vector3i = candidate.get("world_cell", Vector3i.ZERO)
					staged_by_world_cell[base_world_cell] = \
							int(staged_by_world_cell.get(base_world_cell, 0)) + 1
					var arbitration_key := String(candidate.get("arbitration_key",
							_world_spacing_cell_key(candidate["center"], _arbitration_spacing)))
					var phase_index := 0 if bool(candidate["canonical"]) else 1
					var phase_candidates: Dictionary = candidates_by_phase[phase_index]
					var cell_candidates: Array = phase_candidates.get(arbitration_key, [])
					cell_candidates.append(candidate)
					phase_candidates[arbitration_key] = cell_candidates
					candidates_by_phase[phase_index] = phase_candidates

	var spacing_blocked_cells: Dictionary = {}
	var lookup_blocked_cells: Dictionary = {}
	var accepted_cells: Dictionary = {}
	var accepted_base_cells: Dictionary = {}
	var canonical_options := _select_local_cell_winners(candidates_by_phase[0])
	if _refresh_cancelled():
		return false
	var canonical_survivors := _local_priority_survivors(canonical_options, [],
			spacing_blocked_cells)
	if _refresh_cancelled():
		return false
	if not _commit_priority_winners(canonical_survivors, accepted_cells,
			accepted_base_cells, lookup_blocked_cells):
		return false

	var fallback_options := _select_local_cell_winners(candidates_by_phase[1])
	if _refresh_cancelled():
		return false
	var fallback_available: Array[Dictionary] = []
	for option in fallback_options:
		if _refresh_cancelled():
			return false
		var candidate: Dictionary = option["candidate"]
		if accepted_cells.has(String(candidate["arbitration_key"])):
			continue
		fallback_available.append(option)
	var fallback_survivors := _local_priority_survivors(fallback_available,
			canonical_survivors, spacing_blocked_cells)
	if _refresh_cancelled():
		return false
	if not _commit_priority_winners(fallback_survivors, accepted_cells,
			accepted_base_cells, lookup_blocked_cells):
		return false

	var checked_cells := 0
	for cell_value in staged_by_world_cell:
		checked_cells += 1
		if checked_cells % REFRESH_WORKER_CHECK_INTERVAL == 0 and _refresh_cancelled():
			return false
		var base_world_cell: Vector3i = cell_value
		var staged_for_cell := int(staged_by_world_cell[base_world_cell])
		var accepted_in_cell := int(accepted_base_cells.get(base_world_cell, 0))
		if accepted_in_cell > 0:
			rejected_world_cell_competition_count += maxi(0, staged_for_cell - accepted_in_cell)
		else:
			rejected_world_cell_competition_count += staged_for_cell
			if spacing_blocked_cells.has(base_world_cell):
				rejected_center_overlap_count += 1
			if lookup_blocked_cells.has(base_world_cell):
				rejected_lookup_capacity_count += 1
	return true

func _select_local_cell_winners(candidates_by_cell: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var checked_cells := 0
	for arbitration_key_value in candidates_by_cell:
		checked_cells += 1
		if checked_cells % REFRESH_WORKER_CHECK_INTERVAL == 0 and _refresh_cancelled():
			return []
		var arbitration_key := String(arbitration_key_value)
		var candidates: Array = candidates_by_cell[arbitration_key]
		var candidates_by_group: Dictionary = {}
		for candidate in candidates:
			var group_key := _coverage_group_key(candidate)
			var group_candidates: Array = candidates_by_group.get(group_key, [])
			group_candidates.append(candidate)
			candidates_by_group[group_key] = group_candidates
		var options: Array[Dictionary] = []
		for group_key_value in candidates_by_group:
			if _refresh_cancelled():
				return []
			var group_key := String(group_key_value)
			var group_candidates: Array = candidates_by_group[group_key]
			group_candidates.sort_custom(Callable(self, "_candidate_less"))
			var candidate: Dictionary = group_candidates[0]
			var arbitration_cell: Vector3i = candidate.get("arbitration_cell", Vector3i.ZERO)
			options.append({
				"candidate": candidate,
				"group": group_key,
				"rank": ProbeLayout.world_cell_rank(group_key, arbitration_cell),
				"arbitration_key": arbitration_key,
			})
		options.sort_custom(Callable(self, "_coverage_group_option_less"))
		if not options.is_empty():
			result.append(options[0])
	return result

func _coverage_group_key(candidate: Dictionary) -> String:
	# Keep source and material-surface identity, but collapse tessellation-driven
	# normal microbins to six signed principal directions for coverage fairness.
	var domain_parts := String(candidate.get("domain", "")).split("\u001f")
	var source_surface := String(candidate.get("domain", ""))
	if domain_parts.size() >= 2:
		source_surface = String(domain_parts[0]) + "\u001f" + String(domain_parts[1])
	var normal: Vector3 = candidate.get("normal", Vector3.UP)
	var axis := _dominant_normal_axis(normal)
	var sign := "+" if normal[axis] >= 0.0 else "-"
	return "%s\u001faxis=%d%s" % [source_surface, axis, sign]

func _coverage_group_option_less(a: Dictionary, b: Dictionary) -> bool:
	var rank_a := int(a["rank"])
	var rank_b := int(b["rank"])
	if rank_a != rank_b:
		return rank_a < rank_b
	return String(a["group"]) < String(b["group"])

func _priority_record_less(a: Dictionary, b: Dictionary) -> bool:
	var candidate_a: Dictionary = a["candidate"]
	var candidate_b: Dictionary = b["candidate"]
	var canonical_a := bool(candidate_a.get("canonical", false))
	var canonical_b := bool(candidate_b.get("canonical", false))
	if canonical_a != canonical_b:
		return canonical_a
	var spacing_a := float(candidate_a.get("spacing", _probe_spacing))
	var spacing_b := float(candidate_b.get("spacing", _probe_spacing))
	if spacing_a != spacing_b:
		return spacing_a < spacing_b
	var rank_a := int(a["rank"])
	var rank_b := int(b["rank"])
	if rank_a != rank_b:
		return rank_a < rank_b
	var cell_a: Vector3i = candidate_a.get("arbitration_cell", Vector3i.ZERO)
	var cell_b: Vector3i = candidate_b.get("arbitration_cell", Vector3i.ZERO)
	if cell_a.x != cell_b.x:
		return cell_a.x < cell_b.x
	if cell_a.y != cell_b.y:
		return cell_a.y < cell_b.y
	if cell_a.z != cell_b.z:
		return cell_a.z < cell_b.z
	var group_a := String(a["group"])
	var group_b := String(b["group"])
	if group_a != group_b:
		return group_a < group_b
	return int(candidate_a.get("stable_id", 0)) < int(candidate_b.get("stable_id", 0))

func _candidate_records_conflict(a: Dictionary, b: Dictionary) -> bool:
	var candidate_a: Dictionary = a["candidate"]
	var candidate_b: Dictionary = b["candidate"]
	var spacing_a := float(candidate_a.get("spacing", _probe_spacing))
	var spacing_b := float(candidate_b.get("spacing", _probe_spacing))
	var average_spacing := 0.5 * (spacing_a + spacing_b)
	var minimum_distance := maxf(0.0, average_spacing -
			maxf(0.000001, average_spacing * 0.000001))
	var center_a: Vector3 = candidate_a["center"]
	var center_b: Vector3 = candidate_b["center"]
	if center_a.distance_squared_to(center_b) >= minimum_distance * minimum_distance:
		return false
	# Separation is a free-space coverage rule. A probe behind a solid wall or
	# floor cannot cover this sample and must not evict it merely by proximity.
	# Keep the same per-cell budget and spacing for mutually visible candidates.
	if bvh_ready and not bvh.intersect_segment(center_a, center_b).is_empty():
		return false
	return true

func _local_priority_survivors(winners: Array[Dictionary],
		fixed_winners: Array[Dictionary],
		spacing_blocked_cells: Dictionary) -> Array[Dictionary]:
	var winners_by_base_cell: Dictionary = {}
	for winner in winners:
		if _refresh_cancelled():
			return []
		var candidate: Dictionary = winner["candidate"]
		var base_cell: Vector3i = candidate.get("world_cell", Vector3i.ZERO)
		var bucket: Array = winners_by_base_cell.get(base_cell, [])
		bucket.append(winner)
		winners_by_base_cell[base_cell] = bucket
	var fixed_by_base_cell: Dictionary = {}
	for fixed_winner in fixed_winners:
		if _refresh_cancelled():
			return []
		var fixed_candidate: Dictionary = fixed_winner["candidate"]
		var fixed_base_cell: Vector3i = fixed_candidate.get("world_cell", Vector3i.ZERO)
		var fixed_bucket: Array = fixed_by_base_cell.get(fixed_base_cell, [])
		fixed_bucket.append(fixed_winner)
		fixed_by_base_cell[fixed_base_cell] = fixed_bucket

	var survivors: Array[Dictionary] = []
	var checked_winners := 0
	for winner in winners:
		checked_winners += 1
		if checked_winners % REFRESH_WORKER_CHECK_INTERVAL == 0 and _refresh_cancelled():
			return []
		var candidate: Dictionary = winner["candidate"]
		var arbitration_key := String(candidate["arbitration_key"])
		var base_cell: Vector3i = candidate.get("world_cell", Vector3i.ZERO)
		var blocked := false
		# Accepted spacing never exceeds base spacing, so a conflict can only
		# occur in the same or an adjacent base-world cell on each axis.
		for dz in range(-1, 2):
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					var neighbor_cell := base_cell + Vector3i(dx, dy, dz)
					for fixed_value in fixed_by_base_cell.get(neighbor_cell, []):
						var fixed_winner: Dictionary = fixed_value
						var fixed_candidate: Dictionary = fixed_winner["candidate"]
						if String(fixed_candidate["arbitration_key"]) == arbitration_key:
							continue
						if _candidate_records_conflict(winner, fixed_winner):
							blocked = true
							break
					if blocked:
						break
					for other_value in winners_by_base_cell.get(neighbor_cell, []):
						var other: Dictionary = other_value
						var other_candidate: Dictionary = other["candidate"]
						if String(other_candidate["arbitration_key"]) == arbitration_key:
							continue
						if _priority_record_less(other, winner) \
								and _candidate_records_conflict(winner, other):
							blocked = true
							break
					if blocked:
						break
				if blocked:
					break
			if blocked:
				break
		if blocked:
			spacing_blocked_cells[base_cell] = true
		else:
			survivors.append(winner)
	return survivors

func _commit_priority_winners(winners: Array[Dictionary],
		accepted_cells: Dictionary, accepted_base_cells: Dictionary,
		lookup_blocked_cells: Dictionary) -> bool:
	var ordered := winners.duplicate()
	ordered.sort_custom(Callable(self, "_priority_record_less"))
	for winner in ordered:
		if _refresh_cancelled():
			return false
		var candidate: Dictionary = winner["candidate"]
		var arbitration_key := String(candidate["arbitration_key"])
		if accepted_cells.has(arbitration_key):
			continue
		var lookup_cell := int(candidate["lookup_cell"])
		if not _adaptive_placement \
				and int(_cell_counts.get(lookup_cell, 0)) >= Data.CELL_CAPACITY:
			var blocked_base_cell: Vector3i = candidate.get("world_cell", Vector3i.ZERO)
			lookup_blocked_cells[blocked_base_cell] = true
			continue
		if positions.size() >= MAX_PROBES:
			error_message = "Surface sampling exceeds the 65,536-probe limit; increase Probe Spacing or reduce the volume."
			return false
		var center: Vector3 = candidate["center"]
		var spacing := float(candidate.get("spacing", _probe_spacing))
		var base_world_cell: Vector3i = candidate.get("world_cell", Vector3i.ZERO)
		positions.append(center)
		surface_positions.append(candidate["surface"])
		normals.append(candidate["normal"])
		stable_probe_ids.append(int(candidate.get("stable_id", 0)))
		if _adaptive_placement:
			probe_spacings.append(spacing)
		_cell_counts[lookup_cell] = int(_cell_counts.get(lookup_cell, 0)) + 1
		accepted_cells[arbitration_key] = true
		accepted_base_cells[base_world_cell] = int(accepted_base_cells.get(base_world_cell, 0)) + 1
	return true

func _world_point_coordinates_are_supported(point: Vector3) -> bool:
	const MAX_SAFE_CELL_COORDINATE := 2147483000.0
	var base_scaled := point / _probe_spacing
	var arbitration_scaled := point / _arbitration_spacing
	return base_scaled.is_finite() and arbitration_scaled.is_finite() \
			and absf(base_scaled.x) < MAX_SAFE_CELL_COORDINATE \
			and absf(base_scaled.y) < MAX_SAFE_CELL_COORDINATE \
			and absf(base_scaled.z) < MAX_SAFE_CELL_COORDINATE \
			and absf(arbitration_scaled.x) < MAX_SAFE_CELL_COORDINATE \
			and absf(arbitration_scaled.y) < MAX_SAFE_CELL_COORDINATE \
			and absf(arbitration_scaled.z) < MAX_SAFE_CELL_COORDINATE

func _mesh_domain_source(node: MeshInstance3D, mesh: Mesh) -> String:
	var instance_id := node.get_instance_id()
	if _domain_source_cache.has(instance_id):
		return String(_domain_source_cache[instance_id])
	var values := _transform_domain_values(node.global_transform)
	var local_bounds := mesh.get_aabb()
	# Use the same canonical face extent as the collector. PrimitiveMesh.get_aabb()
	# describes its analytic surface, while get_faces() snaps generated triangles;
	# a canonical ArrayMesh made from those faces must keep the same domain key.
	var local_faces: PackedVector3Array = mesh.get_faces()
	if not local_faces.is_empty():
		var minimum := local_faces[0]
		var maximum := local_faces[0]
		for point in local_faces:
			minimum = minimum.min(point)
			maximum = maximum.max(point)
		local_bounds = AABB(minimum, maximum - minimum)
	values = _append_quantized_vector(values, local_bounds.position)
	values = _append_quantized_vector(values, local_bounds.size)
	var identity := "mesh:%s" % _stable_domain_hash(values)
	_domain_source_cache[instance_id] = identity
	return identity

func _terrain_domain_source(terrain: Node3D) -> String:
	var instance_id := terrain.get_instance_id()
	if _domain_source_cache.has(instance_id):
		return String(_domain_source_cache[instance_id])
	var values := _transform_domain_values(terrain.global_transform)
	if _streamed_page:
		var data: Object = terrain.get("data")
		var locations: Array = data.call("get_region_locations") \
				if data != null and data.has_method("get_region_locations") else []
		locations.sort_custom(func(a: Variant, b: Variant) -> bool:
			var va := Vector2i(a)
			var vb := Vector2i(b)
			return va.x < vb.x if va.x != vb.x else va.y < vb.y)
		values.append_array([terrain.get("region_size"), locations])
	else:
		values = _append_quantized_vector(values, _world_bounds.position)
		values = _append_quantized_vector(values, _world_bounds.size)
	values.append(roundi(float(terrain.get("vertex_spacing")) * 100000.0))
	var identity := "terrain:%s" % _stable_domain_hash(values)
	_domain_source_cache[instance_id] = identity
	return identity

func _transform_domain_values(transform: Transform3D) -> PackedInt64Array:
	var values := PackedInt64Array()
	values = _append_quantized_vector(values, transform.basis.x)
	values = _append_quantized_vector(values, transform.basis.y)
	values = _append_quantized_vector(values, transform.basis.z)
	values = _append_quantized_vector(values, transform.origin)
	return values

func _append_quantized_vector(values: PackedInt64Array, vector: Vector3) -> PackedInt64Array:
	const QUANTIZATION := 100000.0
	var result := values
	result.append(roundi(vector.x * QUANTIZATION))
	result.append(roundi(vector.y * QUANTIZATION))
	result.append(roundi(vector.z * QUANTIZATION))
	return result

func _stable_domain_hash(values: PackedInt64Array) -> String:
	# Geometry domain identity must survive scene re-instantiation; runtime IDs and
	# node paths are used only to cache this value, never to derive its contents.
	var low: int = 2166136261
	var high: int = 2246822519
	for value in values:
		for shift in range(0, 64, 8):
			var byte_value := (int(value) >> shift) & 0xff
			low = int((low ^ byte_value) * 16777619) & 0xffffffff
			high = int((high ^ (byte_value ^ 0x5b)) * 16777619) & 0xffffffff
	return "%08x%08x" % [low, high]

static func _preferred_probe_offset(volume: Node3D) -> float:
	var spacing := maxf(float(volume.get("probe_spacing")), 0.1)
	var lower := spacing * MIN_PROBE_OFFSET_SPACING_RATIO
	var upper := spacing * MAX_PROBE_OFFSET_SPACING_RATIO
	return clampf(maxf(float(volume.get("surface_offset")),
			spacing * BASE_PROBE_OFFSET_SPACING_RATIO), lower, upper)

func _source_face_outward_sign(source_id: int, face_index: int,
		a: Vector3, b: Vector3, c: Vector3, authored_normal: Vector3) -> float:
	if _face_outward_signs.has(face_index):
		return float(_face_outward_signs[face_index])
	if not _source_volume_indices.has(source_id):
		_face_outward_signs[face_index] = 1.0
		return 1.0 # Open meshes retain their authored face direction.
	var solid: Dictionary = _occlusion_volumes[int(_source_volume_indices[source_id])]
	var bounds: AABB = solid.world_aabb
	var scale := maxf(bounds.size.x, maxf(bounds.size.y, bounds.size.z))
	var longest_edge := maxf(a.distance_to(b), maxf(b.distance_to(c), c.distance_to(a)))
	var cross_length := (c - a).cross(b - a).length()
	if longest_edge <= 0.00000001 or cross_length <= 0.00000001:
		_face_outward_signs[face_index] = 0.0
		return 0.0
	var altitude := cross_length / longest_edge
	var max_distance := minf(scale * 0.001, altitude * 0.1)
	var test_distance := maxf(0.0000001, scale * 0.000001)
	if max_distance < test_distance:
		_face_outward_signs[face_index] = 0.0
		return 0.0
	var center := (a + b + c) / 3.0
	var test_distances := [test_distance, minf(max_distance, test_distance * 4.0),
			minf(max_distance, test_distance * 16.0), max_distance]
	for distance in test_distances:
		var offset := authored_normal * float(distance)
		var positive_side := _point_inside_closed_mesh_state(center + offset, bounds,
				solid.bvh, solid.faces)
		var negative_side := _point_inside_closed_mesh_state(center - offset, bounds,
				solid.bvh, solid.faces)
		if positive_side == 0 and negative_side == 1:
			_face_outward_signs[face_index] = 1.0
			return 1.0
		if positive_side == 1 and negative_side == 0:
			_face_outward_signs[face_index] = -1.0
			return -1.0
	_face_outward_signs[face_index] = 0.0
	return 0.0

func _safe_probe_offset(surface: Vector3, normal: Vector3, preferred: float) -> float:
	if normal.length_squared() < 0.5 or not is_finite(preferred) or preferred <= 0.0:
		return 0.0
	var safe_offset := preferred
	var ray_epsilon := maxf(0.00001, minf(preferred * 0.1,
			_probe_spacing * 0.0005))
	if bvh_ready:
		var hit := bvh.intersect_segment(surface + normal * ray_epsilon,
				surface + normal * preferred)
		if not hit.is_empty():
			var hit_distance: float = (hit.position - surface).dot(normal)
			safe_offset = minf(safe_offset, (hit_distance - ray_epsilon) * 0.45)
	# Keep the center inside the oriented volume even when the surface lies on a
	# boundary. The inverse-basis direction accounts for nonuniform volume scale.
	var local_surface := _inverse * surface
	var local_direction := _inverse.basis * normal
	var half_size: Vector3 = _volume_size * 0.5
	var local_boundary_epsilon := maxf(0.00001, _probe_spacing * 0.00001)
	for axis in 3:
		var direction_component := local_direction[axis]
		if absf(direction_component) < 0.000001:
			continue
		var boundary := half_size[axis] if direction_component > 0.0 else -half_size[axis]
		var distance_to_boundary := (boundary - local_surface[axis]) / direction_component
		if distance_to_boundary >= 0.0:
			safe_offset = minf(safe_offset,
					distance_to_boundary - local_boundary_epsilon / absf(direction_component))
	var minimum_clearance := maxf(ray_epsilon * 2.0,
			_probe_spacing * MIN_PROBE_OFFSET_SPACING_RATIO)
	return safe_offset if safe_offset >= minimum_clearance else 0.0

func _build_occlusion_broadphase() -> bool:
	_occlusion_cells.clear()
	if _occlusion_volumes.is_empty():
		return not _refresh_cancelled()
	var grid_scale := Vector3(OCCLUSION_GRID_AXIS, OCCLUSION_GRID_AXIS, OCCLUSION_GRID_AXIS)
	var local_volume := AABB(-_volume_size * 0.5, _volume_size)
	var cell_work := 0
	for solid_index in _occlusion_volumes.size():
		if _refresh_cancelled():
			return false
		var solid: Dictionary = _occlusion_volumes[solid_index]
		var world_box: AABB = solid.world_aabb
		var local_box := AABB(_inverse * world_box.get_endpoint(0), Vector3.ZERO)
		for corner_index in range(1, 8):
			local_box = local_box.expand(_inverse * world_box.get_endpoint(corner_index))
		local_box = local_box.grow(maxf(0.00001, _probe_spacing * 0.00001))
		if not local_box.intersects(local_volume):
			continue
		var clipped_min := local_box.position.max(local_volume.position)
		var clipped_max := local_box.end.min(local_volume.end)
		var cell_min := Vector3i(((clipped_min - local_volume.position) / _volume_size * grid_scale).floor()) \
				.clamp(Vector3i.ZERO, Vector3i.ONE * (OCCLUSION_GRID_AXIS - 1))
		var cell_max := Vector3i(((clipped_max - local_volume.position) / _volume_size * grid_scale).floor()) \
				.clamp(Vector3i.ZERO, Vector3i.ONE * (OCCLUSION_GRID_AXIS - 1))
		for z in range(cell_min.z, cell_max.z + 1):
			for y in range(cell_min.y, cell_max.y + 1):
				for x in range(cell_min.x, cell_max.x + 1):
					cell_work += 1
					if cell_work % REFRESH_WORKER_CHECK_INTERVAL == 0 \
							and _refresh_cancelled():
						return false
					var key := x + y * OCCLUSION_GRID_AXIS + z * OCCLUSION_GRID_AXIS * OCCLUSION_GRID_AXIS
					var solids: Array = _occlusion_cells.get(key, [])
					solids.append(solid_index)
					_occlusion_cells[key] = solids
	return not _refresh_cancelled()

func _probe_center_is_inside_solid(point: Vector3) -> bool:
	var local := _inverse * point
	var normalized: Vector3 = (local + _volume_size * 0.5) / _volume_size
	var broad_cell := Vector3i((normalized * float(OCCLUSION_GRID_AXIS)).floor()).clamp(
			Vector3i.ZERO, Vector3i.ONE * (OCCLUSION_GRID_AXIS - 1))
	var key := broad_cell.x + broad_cell.y * OCCLUSION_GRID_AXIS \
			+ broad_cell.z * OCCLUSION_GRID_AXIS * OCCLUSION_GRID_AXIS
	for solid_index in _occlusion_cells.get(key, []):
		var solid: Dictionary = _occlusion_volumes[solid_index]
		var solid_box: AABB = solid.world_aabb
		if solid_box.grow(maxf(0.000001, solid_box.size.length() * 0.000001)).has_point(point):
			if _point_inside_closed_mesh_state(point, solid_box,
					solid.bvh, solid.faces) != 0:
				return true # Ambiguous containment is unsafe for probe placement.
	return false

func _point_inside_closed_mesh_state(point: Vector3, bounds: AABB, mesh_bvh: TriangleMesh,
		mesh_faces: PackedVector3Array = PackedVector3Array()) -> int:
	var directions := [
		Vector3(1.0, 0.371, 0.529).normalized(),
		Vector3(-0.291, 1.0, 0.417).normalized(),
		Vector3(0.613, -0.337, 1.0).normalized(),
		Vector3(-1.0, 0.743, 0.263).normalized(),
		Vector3(0.229, -1.0, 0.811).normalized(),
	]
	var scale := maxf(bounds.size.length(), 0.000001)
	var ray_length := scale * 1.5 + 0.000001
	var boundary_epsilon := maxf(0.00000001, scale * 0.0000001)
	var max_advance := maxf(_probe_spacing * 0.005, scale * 0.0001)
	var valid_rays := 0
	var inside_votes := 0
	for direction in directions:
		var crossings := _ray_crossing_count(point, direction, ray_length,
				boundary_epsilon, max_advance, mesh_bvh, mesh_faces)
		if crossings < 0:
			continue # A ray landed on the boundary; let the other directions decide.
		valid_rays += 1
		if crossings % 2 == 1:
			inside_votes += 1
	if valid_rays < 3:
		return -1
	if inside_votes >= 3:
		return 1
	if valid_rays - inside_votes >= 3:
		return 0
	return -1

func _ray_crossing_count(origin: Vector3, direction: Vector3, ray_length: float,
		boundary_epsilon: float, max_advance: float, mesh_bvh: TriangleMesh,
		mesh_faces: PackedVector3Array) -> int:
	var ray_end := origin + direction * ray_length
	var ray_start := origin
	var crossings := 0
	for _hit_index in OCCLUSION_MAX_CROSSINGS:
		var hit: Dictionary = mesh_bvh.intersect_segment(ray_start, ray_end)
		if hit.is_empty():
			return crossings
		var hit_position: Vector3 = hit["position"]
		var hit_normal: Vector3 = hit["normal"]
		var hit_face := int(hit.get("face_index", -1))
		var along_ray := (hit_position - origin).dot(direction)
		if along_ray <= boundary_epsilon * 4.0:
			return -1 # The query lies on or too close to this mesh boundary.
		# At large world coordinates the nominal geometric epsilon can be smaller
		# than one representable Vector3 step. Find the smallest bounded advance
		# that changes coordinates and demonstrably passes the hit plane.
		var world_magnitude := maxf(absf(hit_position.x), maxf(absf(hit_position.y),
				absf(hit_position.z)))
		var advance_distance := maxf(boundary_epsilon, world_magnitude * FLOAT32_EPSILON)
		var crossed_hit_plane := false
		while advance_distance <= max_advance:
			var candidate_start := hit_position + direction * advance_distance
			var movement := candidate_start - hit_position
			var plane_step := movement.dot(hit_normal)
			if movement.dot(direction) > 0.0 \
					and absf(plane_step) >= boundary_epsilon \
					and plane_step * hit_normal.dot(direction) > 0.0:
				ray_start = candidate_start
				crossed_hit_plane = true
				break
			advance_distance *= 2.0
		if not crossed_hit_plane:
			return -1
		# Geometry3D compares the unnormalised segment determinant against the
		# absolute CMP_EPSILON=1e-5. A fixed tiny interval falls below that threshold
		# on small curved facets, so size this local confirmation segment from the
		# hit triangle's projected area while keeping it bounded.
		if hit_face < 0 or hit_face * 3 + 2 >= mesh_faces.size():
			return -1
		var face_a: Vector3 = mesh_faces[hit_face * 3]
		var face_b: Vector3 = mesh_faces[hit_face * 3 + 1]
		var face_c: Vector3 = mesh_faces[hit_face * 3 + 2]
		var projected_cross := absf((face_b - face_a).cross(face_c - face_a).dot(direction))
		if not is_finite(projected_cross) or projected_cross <= 0.0:
			return -1
		var required_segment_length := REVERSE_VERIFY_DETERMINANT_SAFETY \
				* TRIANGLE_SEGMENT_DETERMINANT_EPSILON / projected_cross
		var max_reverse_span := maxf(_probe_spacing * REVERSE_VERIFY_MAX_SPACING_RATIO,
				_probe_spacing * 0.0001)
		if not is_finite(required_segment_length) \
				or required_segment_length > max_reverse_span + max_advance:
			return -1
		# Ensure the crossing parameter t=advance/segment_length stays above
		# segment_intersects_triangle's CMP_EPSILON as the adaptive segment grows.
		var verify_advance := maxf(advance_distance,
				required_segment_length * TRIANGLE_SEGMENT_DETERMINANT_EPSILON * 2.0)
		var verify_crossed_plane := false
		while verify_advance <= max_advance:
			var verify_start := hit_position + direction * verify_advance
			var verify_movement := verify_start - hit_position
			var verify_plane_step := verify_movement.dot(hit_normal)
			if verify_movement.dot(direction) > 0.0 \
					and absf(verify_plane_step) >= boundary_epsilon \
					and verify_plane_step * hit_normal.dot(direction) > 0.0:
				ray_start = verify_start
				verify_crossed_plane = true
				break
			verify_advance *= 2.0
		if not verify_crossed_plane:
			return -1
		var verify_span := maxf(_probe_spacing * 0.0001,
				required_segment_length - verify_advance)
		if verify_span > max_reverse_span:
			return -1
		var verify_total_length := verify_advance + verify_span
		var reverse_hit_parameter := verify_advance / verify_total_length
		if not is_finite(verify_total_length) or verify_total_length <= 0.0 \
				or not is_finite(reverse_hit_parameter) \
				or reverse_hit_parameter <= TRIANGLE_SEGMENT_DETERMINANT_EPSILON \
				or reverse_hit_parameter >= 1.0:
			return -1
		var reverse_end := hit_position - direction * verify_span
		var reverse_hit := mesh_bvh.intersect_segment(ray_start, reverse_end)
		if reverse_hit.is_empty():
			return -1
		var reverse_face := int(reverse_hit.get("face_index", -1))
		if reverse_face != hit_face and not _mesh_faces_share_coplanar_crossing(
				mesh_faces, hit_face, reverse_face, hit_position):
			return -1
		crossings += 1
		if ray_start.distance_squared_to(ray_end) <= verify_advance * verify_advance:
			return crossings
	return -1 # Avoid pathological work on malformed/intersecting topology.

func _mesh_faces_share_coplanar_crossing(mesh_faces: PackedVector3Array,
		first_face: int, second_face: int, point: Vector3) -> bool:
	if first_face < 0 or second_face < 0 \
			or first_face * 3 + 2 >= mesh_faces.size() \
			or second_face * 3 + 2 >= mesh_faces.size():
		return false
	var first_a: Vector3 = mesh_faces[first_face * 3]
	var first_b: Vector3 = mesh_faces[first_face * 3 + 1]
	var first_c: Vector3 = mesh_faces[first_face * 3 + 2]
	var second_a: Vector3 = mesh_faces[second_face * 3]
	var second_b: Vector3 = mesh_faces[second_face * 3 + 1]
	var second_c: Vector3 = mesh_faces[second_face * 3 + 2]
	var first_normal := (first_c - first_a).cross(first_b - first_a).normalized()
	var second_normal := (second_c - second_a).cross(second_b - second_a).normalized()
	if first_normal.length_squared() < 0.5 or second_normal.length_squared() < 0.5 \
			or absf(first_normal.dot(second_normal)) < 0.9999:
		return false
	# Plane proximity alone is not enough at large world coordinates: a ULP-sized
	# parallel shell can fall inside the floating-point plane tolerance. Continuation
	# between distinct faces requires a real shared geometric edge in the source BVH
	# face data, using the same absolute weld tolerance as occlusion topology.
	var first_vertices := PackedVector3Array([first_a, first_b, first_c])
	var second_vertices := PackedVector3Array([second_a, second_b, second_c])
	var weld_distance_squared := OCCLUSION_WELD_EPSILON * OCCLUSION_WELD_EPSILON
	var shares_edge := false
	for first_i in 3:
		for first_j in range(first_i + 1, 3):
			for second_i in 3:
				for second_j in range(second_i + 1, 3):
					var same_order := first_vertices[first_i].distance_squared_to(
							second_vertices[second_i]) < weld_distance_squared \
							and first_vertices[first_j].distance_squared_to(
							second_vertices[second_j]) < weld_distance_squared
					var reverse_order := first_vertices[first_i].distance_squared_to(
							second_vertices[second_j]) < weld_distance_squared \
							and first_vertices[first_j].distance_squared_to(
							second_vertices[second_i]) < weld_distance_squared
					if same_order or reverse_order:
						shares_edge = true
						break
			if shares_edge:
				break
		if shares_edge:
			break
	if not shares_edge:
		return false
	var magnitude := maxf(absf(point.x), maxf(absf(point.y), absf(point.z)))
	var tolerance := maxf(0.0002, magnitude * FLOAT32_EPSILON * 2.0)
	if tolerance > _probe_spacing * 0.02:
		return false
	return absf(first_normal.dot(second_a - first_a)) <= tolerance \
			and absf(first_normal.dot(point - first_a)) <= tolerance \
			and absf(second_normal.dot(point - second_a)) <= tolerance

func _clip_polygon(polygon: Array, axis: int, boundary: float, keep_greater: bool) -> Array:
	var output: Array = []
	if polygon.is_empty():
		return output
	var previous: Vector3 = polygon[polygon.size() - 1]
	var previous_distance := previous[axis] - boundary
	var previous_inside := previous_distance >= -0.000001 if keep_greater else previous_distance <= 0.000001
	for current_value in polygon:
		var current: Vector3 = current_value
		var current_distance := current[axis] - boundary
		var current_inside := current_distance >= -0.000001 if keep_greater else current_distance <= 0.000001
		if current_inside != previous_inside:
			var denominator := previous[axis] - current[axis]
			if absf(denominator) > 0.0000001:
				var t := (previous[axis] - boundary) / denominator
				output.append(previous.lerp(current, t))
		if current_inside:
			output.append(current)
		previous = current
		previous_inside = current_inside
	return output

func trace(origin: Vector3, direction: Vector3, max_distance: float) -> Dictionary:
	return trace_scene.trace(origin, direction, max_distance) if bvh_ready and trace_scene != null else {}

func trace_geometry(origin: Vector3, direction: Vector3,
		max_distance: float) -> Dictionary:
	if not bvh_ready or trace_scene == null:
		return {}
	return trace_scene.trace_geometry(origin, direction, max_distance)

func trace_path(origin: Vector3, direction: Vector3, max_distance: float,
		start_face_index := -1) -> Dictionary:
	return trace_scene.trace_path(origin, direction, max_distance, start_face_index) if bvh_ready and trace_scene != null else {}

func trace_emitter_connection(origin: Vector3, direction: Vector3, max_distance: float,
		start_face_index := -1) -> Dictionary:
	return trace_scene.trace_emitter_connection(origin, direction, max_distance, start_face_index) if bvh_ready and trace_scene != null else {}

func safe_surface_offset(surface: Vector3, normal: Vector3) -> float:
	return trace_scene.safe_surface_offset(surface, normal) if trace_scene != null else 0.0

## Conservative free-space bake classification. A true result includes both a
## proven closed-mesh interior and an ambiguous boundary/containment query.
func point_is_inside_or_ambiguous_solid(point: Vector3) -> bool:
	return _probe_center_is_inside_solid(point)
