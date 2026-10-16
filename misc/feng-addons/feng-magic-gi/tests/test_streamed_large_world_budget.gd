extends SceneTree
## CPU-only regression for large-world IDs and bounded streamed geometry collection.

const Placement = preload("res://addons/feng-magic-gi/feng_magic_gi_placement.gd")
const Baker = preload("res://addons/feng-magic-gi/feng_magic_gi_baker.gd")
const PageContext = preload("res://addons/feng-magic-gi/feng_magic_gi_page_context.gd")
const Planner = preload("res://addons/feng-magic-gi/feng_magic_gi_page_planner.gd")
const Manifest = preload("res://addons/feng-magic-gi/feng_magic_gi_manifest.gd")
const ProbeLayout = preload("res://addons/feng-magic-gi/feng_magic_gi_probe_layout.gd")
const Visibility = preload("res://addons/feng-magic-gi/feng_magic_gi_visibility.gd")

class CancelDuringSpacingPlacement:
	extends "res://addons/feng-magic-gi/feng_magic_gi_placement.gd"
	var exclusion_checks := 0

	func _candidate_records_conflict(a: Dictionary, b: Dictionary) -> bool:
		exclusion_checks += 1
		var conflicts: bool = super._candidate_records_conflict(a, b)
		if exclusion_checks == 1:
			_request_refresh_cancel()
		return conflicts

var checks := 0
var failures := 0

func require(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var placement_script: Script = load("res://addons/feng-magic-gi/feng_magic_gi_placement.gd")
	var baker_script: Script = load("res://addons/feng-magic-gi/feng_magic_gi_baker.gd")
	var context_script: Script = load("res://addons/feng-magic-gi/feng_magic_gi_page_context.gd")
	var planner_script: Script = load("res://addons/feng-magic-gi/feng_magic_gi_page_planner.gd")
	var manifest_script: Script = load("res://addons/feng-magic-gi/feng_magic_gi_manifest.gd")
	require(placement_script != null and placement_script.can_instantiate(),
			"Placement script must parse before budget checks run.")
	require(baker_script != null and baker_script.can_instantiate(),
			"Baker script must parse before fallback checks run.")
	require(context_script != null and context_script.can_instantiate(),
			"PageContext script must parse before collection runs.")
	require(planner_script != null and planner_script.can_instantiate(),
			"Page planner script must parse before page checks run.")
	require(manifest_script != null and manifest_script.can_instantiate(),
			"Manifest script must parse before influence metadata checks run.")
	if failures > 0:
		print("MAGIC_GI_STREAMED_LARGE_WORLD checks=", checks, " failures=", failures)
		quit(1)
		return
	_test_large_world_probe_ids()
	_test_local_layout_arbitration()
	_test_chunk_rebake_influence_bounds()
	_test_512m_plane_page_collection()
	print("MAGIC_GI_STREAMED_LARGE_WORLD checks=", checks, " failures=", failures)
	quit(1 if failures else 0)

func _test_large_world_probe_ids() -> void:
	var placement := Placement.new()
	placement._sample_domain_source = "large-world-id-fixture"
	placement._sample_surface_index = 0
	placement._probe_spacing = 1.0
	var first := placement._stable_probe_id(Vector3(30000.0, 0.0, 0.0), Vector3.UP)
	# These X values differ by 2^32 * 1e-5 metres. Vector3i quantization used
	# to wrap them to the same signed 32-bit coordinate.
	var second := placement._stable_probe_id(Vector3(-12949.67296, 0.0, 0.0), Vector3.UP)
	require(first != second,
			"Large-world surface coordinates must retain distinct 64-bit quantized IDs.")

func _test_local_layout_arbitration() -> void:
	var contact_cell := Vector3i(-6, 0, -5)
	var floor_candidate := _layout_candidate(Vector3(-1.375, 0.047502, -1.125),
			Vector3.UP, "mesh:contact-floor\u001f0\u001f0,20,0\u001f0", true, 1101)
	var sphere_candidate := _layout_candidate(Vector3(-1.365103, 0.047239, -1.120908),
			Vector3(0.330, -0.934, 0.136), "mesh:contact-sphere\u001f0\u001f7,-19,3\u001f0", true, 2202)
	require(ProbeLayout.world_cell(floor_candidate["center"], 0.25) == contact_cell
			and ProbeLayout.world_cell(sphere_candidate["center"], 0.25) == contact_cell,
			"the owner/halo fixture must put competing contact surfaces in one arbitration cell")
	var owner := _placement_with_candidates([floor_candidate, sphere_candidate])
	var halo_candidates: Array[Dictionary] = [floor_candidate.duplicate(true), sphere_candidate.duplicate(true)]
	for index in 48:
		var normal := Vector3(0.04 * float(index % 5), -1.0,
				0.03 * float(index % 7)).normalized()
		halo_candidates.append(_layout_candidate(Vector3(4.0 + float(index), 0.2, 0.1),
				normal, "mesh:contact-sphere\u001f0\u001f%d,-20,%d\u001f%d" % [index, index % 7, index],
				true, 3000 + index))
	var halo := _placement_with_candidates(halo_candidates)
	require(owner._finalize_world_candidates() and halo._finalize_world_candidates(),
			"both page-local candidate sets must finalize")
	var owner_contact_ids := _stable_ids_in_cell(owner, contact_cell, 0.25)
	var halo_contact_ids := _stable_ids_in_cell(halo, contact_cell, 0.25)
	require(owner_contact_ids.size() == 1 and owner_contact_ids == halo_contact_ids,
			"extra support-page domains must not change a shared world-cell winner")
	require(_has_unique_fine_cells(owner, 0.25) and _has_unique_fine_cells(halo, 0.25),
			"final output must still contain at most one probe per world arbitration cell")

	var close_a := _layout_candidate(Vector3(0.999995, 0.1, 0.1), Vector3.UP,
			"mesh:spacing-a\u001f0\u001f0,20,0\u001f0", true, 4101)
	var close_b := _layout_candidate(Vector3(1.000005, 0.1, 0.1), Vector3.UP,
			"mesh:spacing-b\u001f0\u001f0,20,0\u001f0", true, 4102)
	var spacing_candidates: Array[Dictionary] = [close_a, close_b]
	var spacing_forward := _placement_with_candidates(spacing_candidates)
	var spacing_reverse := _placement_with_candidates([close_b, close_a])
	require(spacing_forward._finalize_world_candidates()
			and spacing_reverse._finalize_world_candidates(),
			"minimum-spacing candidates must finalize in either input order")
	require(spacing_forward.positions.size() == 1 and spacing_reverse.positions.size() == 1
			and spacing_forward.stable_probe_ids == spacing_reverse.stable_probe_ids,
			"symmetric local priority must enforce minimum spacing independent of insertion order")
	var cancel_a := _layout_candidate(Vector3(0.249, 0.1, 0.1), Vector3.UP,
			"mesh:cancel-a\u001f0\u001f0,20,0\u001f0", true, 4201)
	var cancel_b := _layout_candidate(Vector3(0.251, 0.1, 0.1), Vector3.UP,
			"mesh:cancel-b\u001f0\u001f0,20,0\u001f0", true, 4202)
	var cancel_layout := CancelDuringSpacingPlacement.new()
	cancel_layout._adaptive_placement = true
	cancel_layout._probe_spacing = 1.0
	cancel_layout._arbitration_spacing = 0.25
	cancel_layout._valid_candidate_count = 2
	for candidate in [cancel_a, cancel_b]:
		cancel_layout._stage_world_candidate(
				cancel_layout._arbitration_parent_cell(candidate["arbitration_cell"]),
					String(candidate["domain"]), candidate)
	cancel_layout._refresh_cancel_token = Placement.RefreshCancellation.new()
	var cancelled_during_exclusion := not cancel_layout._finalize_world_candidates()
	require(cancelled_during_exclusion and cancel_layout.exclusion_checks > 0
			and cancel_layout.positions.is_empty() and cancel_layout.surface_positions.is_empty()
			and cancel_layout.normals.is_empty(),
			"cancellation reached local spacing exclusion without publishing partial probes")
	cancel_layout._clear_staged_candidate_storage()

	var canonical := _layout_candidate(Vector3(2.03, 0.1, 0.1), Vector3.UP,
			"mesh:canonical\u001f0\u001f0,20,0\u001f0", true, 5101)
	var same_cell_fallback := _layout_candidate(Vector3(2.20, 0.1, 0.1), Vector3.UP,
			"mesh:fallback-overlap\u001f0\u001f0,20,0\u001f0", false, 5102)
	var fallback_only := _layout_candidate(Vector3(3.1, 0.1, 0.1), Vector3.UP,
			"mesh:fallback-open\u001f0\u001f0,20,0\u001f0", false, 5103)
	var fallback_layout := _placement_with_candidates(
			[canonical, same_cell_fallback, fallback_only])
	require(fallback_layout._finalize_world_candidates()
			and fallback_layout.stable_probe_ids.has(5101)
			and not fallback_layout.stable_probe_ids.has(5102)
			and fallback_layout.stable_probe_ids.has(5103),
			"fallback must fill open cells while preserving canonical winners")

	var wall_faces := PackedVector3Array([
		Vector3(0, -1, -1), Vector3(0, 1, -1), Vector3(0, 1, 1),
		Vector3(0, -1, -1), Vector3(0, 1, 1), Vector3(0, -1, 1)])
	var wall_bvh := Visibility.build(wall_faces)
	var left_side := _layout_candidate(Vector3(-0.15, 0.2, 0.0), Vector3.LEFT,
			"mesh:thin-wall\u001f0\u001f-20,0,0\u001f0", true, 6101)
	var right_side := _layout_candidate(Vector3(0.15, 0.2, 0.0), Vector3.RIGHT,
			"mesh:thin-wall\u001f0\u001f20,0,0\u001f0", true, 6102)
	var wall_layout := _placement_with_candidates([left_side, right_side])
	require(Visibility.segment_blocked(wall_bvh.nodes, wall_bvh.triangles,
			left_side["center"], right_side["center"]),
			"the thin-wall control must still block cross-side visibility")
	require(wall_layout._finalize_world_candidates()
			and wall_layout.stable_probe_ids.has(6101)
			and wall_layout.stable_probe_ids.has(6102),
			"separated surface candidates on both wall sides must remain distinct")

	var narrow_spacing := Placement.new()
	narrow_spacing._probe_spacing = 1.0
	narrow_spacing._arbitration_spacing = 0.1
	require(not narrow_spacing._world_point_coordinates_are_supported(
			Vector3(214748300.0, 0.0, 0.0)),
			"fine-cell coordinates must be range-checked before signed Vector3i conversion")
	require(Placement.MAX_STAGED_ARBITRATION_CELLS == Placement.MAX_PROBES,
			"local arbitration must retain the existing global staged-cell hard limit")

func _placement_with_candidates(candidates: Array[Dictionary]) -> Placement:
	var placement := Placement.new()
	placement._adaptive_placement = true
	placement._probe_spacing = 1.0
	placement._arbitration_spacing = 0.25
	for candidate in candidates:
		placement._valid_candidate_count += 1
		placement._stage_world_candidate(
				placement._arbitration_parent_cell(candidate["arbitration_cell"]),
				String(candidate["domain"]), candidate)
	return placement

func _layout_candidate(center: Vector3, normal: Vector3, domain: String,
		canonical: bool, stable_id: int) -> Dictionary:
	var probe_spacing := 1.0
	var arbitration_spacing := 0.25
	var arbitration_cell := ProbeLayout.world_cell(center, arbitration_spacing)
	return {
		"surface": center - normal.normalized() * 0.03,
		"center": center,
		"normal": normal.normalized(),
		"lookup_cell": 0,
		"domain": domain,
		"canonical": canonical,
		"face_index": 0,
		"world_cell": ProbeLayout.world_cell(center, probe_spacing),
		"arbitration_cell": arbitration_cell,
		"stable_id": stable_id,
		"arbitration_key": "%d,%d,%d" % [arbitration_cell.x, arbitration_cell.y, arbitration_cell.z],
		"spacing": arbitration_spacing,
		"score": 0.0,
	}

func _stable_ids_in_cell(placement: Placement, cell: Vector3i,
		spacing: float) -> PackedInt64Array:
	var result := PackedInt64Array()
	for index in placement.positions.size():
		if ProbeLayout.world_cell(placement.positions[index], spacing) == cell:
			result.append(placement.stable_probe_ids[index])
	return result

func _has_unique_fine_cells(placement: Placement, spacing: float) -> bool:
	var seen: Dictionary = {}
	for position in placement.positions:
		var cell := ProbeLayout.world_cell(position, spacing)
		var key := "%d,%d,%d" % [cell.x, cell.y, cell.z]
		if seen.has(key):
			return false
		seen[key] = true
	return true

func _test_chunk_rebake_influence_bounds() -> void:
	var core := AABB(Vector3.ZERO, Vector3(32.0, 32.0, 32.0))
	var support := Planner.support_bounds(core, 1.0, 0.25, 0.5)
	var trace_radius := 96.0 # Three path segments at 32m bake distance.
	var influence := Planner.influence_bounds(core, 1.0, 0.25, 0.5, 32.0, 2)
	var selected_chunk := AABB(Vector3(128.0, -96.0, 0.0), Vector3(512.0, 224.0, 512.0))
	require(not Planner.intersects_half_open(support, selected_chunk),
			"Fixture must isolate a page whose support ends before the edited chunk.")
	require(Baker._page_influence_intersects_chunk(influence, selected_chunk),
			"A neighboring page influenced by a chunk edit must be selected for rebake.")
	var old_entry := {"support_bounds": support, "influence_bounds": influence}
	var saved_influence := Baker._old_entry_influence_bounds(old_entry, trace_radius)
	require(saved_influence == influence,
			"Partial rebake must honor the exact influence bounds saved by the old page record.")
	var prerelase_entry := {"support_bounds": support}
	var derived_old_influence := Baker._old_entry_influence_bounds(prerelase_entry, trace_radius)
	require(Baker._page_influence_intersects_chunk(derived_old_influence, selected_chunk),
			"Older page records without influence metadata must conservatively use current trace reach.")
	var unaffected_chunk := AABB(Vector3(640.0, -96.0, 0.0), Vector3(512.0, 224.0, 512.0))
	require(not Baker._page_influence_intersects_chunk(influence, unaffected_chunk),
			"Partial rebake must leave pages outside the recorded trace influence untouched.")

	var manifest := Manifest.new()
	manifest.generation = "influence_fixture"
	manifest.world_bounds = core
	manifest.page_entries = [{
		"page_key": "0,0/0,0,0",
		"core_bounds": core,
		"support_bounds": support,
		"influence_bounds": influence,
		"empty": true,
		"resource_path": "",
	}]
	manifest.configure(manifest.page_entries)
	require(manifest.is_valid(), "Manifest v2 must validate influence metadata for each page.")
	require(manifest.get_page_metadata("0,0/0,0,0").get("influence_bounds", AABB()) == influence,
			"The immutable manifest index must preserve each page's saved influence extent.")

func _test_512m_plane_page_collection() -> void:
	var test_root := Node3D.new()
	test_root.name = "StreamedLargeWorldFixture"
	root.add_child(test_root)
	var context := PageContext.new()
	context.name = "PageContext"
	context.size = Vector3(512.0, 32.0, 512.0)
	context.probe_spacing = 1.0
	context.minimum_probe_spacing = 0.25
	context.adaptive_placement = true
	context.bake_distance = 96.0
	context.clv_cell_size = 0.5
	test_root.add_child(context)
	var mesh_instance := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(512.0, 512.0)
	plane.subdivide_width = 511
	plane.subdivide_depth = 511
	mesh_instance.mesh = plane
	mesh_instance.position.y = 0.0
	test_root.add_child(mesh_instance)

	var planner_pages := Planner.core_pages(
			AABB(Vector3(-256.0, -16.0, -256.0), Vector3(512.0, 32.0, 512.0)),
			512.0, 32.0)
	require(planner_pages.size() == 256,
			"A 512m management chunk should plan sparse 32m cores, not one dense block.")

	var full_chunk := AABB(Vector3(-256.0, -128.0, -256.0), Vector3(512.0, 256.0, 512.0))
	var block_collector := Placement.new()
	var whole_block_ok := block_collector.collect(context, true, true, false, false, full_chunk)
	require(not whole_block_ok and block_collector.error_message.contains("250,000-triangle"),
			"A 512m / 1m high-triangle block must hit the existing geometry cap explicitly.")
	require(block_collector.reflectance.size() == Placement.MAX_GEOMETRY_TRIANGLES,
			"The whole-block collector must stop at, not exceed, the fixed geometry cap.")
	var baker := Baker.new()
	require(baker._is_page_collection_budget_error(block_collector.error_message),
			"The baker must recognize the block BVH cap and route to page-local collection.")

	var core := AABB(Vector3(-16.0, -16.0, -16.0), Vector3(32.0, 32.0, 32.0))
	var support := Planner.support_bounds(core, 1.0, 0.25, 0.5)
	context.size = support.size
	context.global_transform = Transform3D(Basis.IDENTITY, support.position + support.size * 0.5)
	var page_trace_bounds := support.grow(96.0)
	var page_collector := Placement.new()
	var page_ok := page_collector.collect(context, true, true, false, false, page_trace_bounds)
	require(page_ok,
			"A 32m page plus the full 3-bounce trace range must collect within the same triangle cap: %s" % page_collector.error_message)
	require(page_collector.bvh_ready and page_collector.faces.size() / 3 > 50000
			and page_collector.faces.size() / 3 < Placement.MAX_GEOMETRY_TRIANGLES,
			"Page-local collection must build a substantial but bounded BVH for the 512m source.")
	var batch_core := AABB(Vector3(-32.0, -16.0, -32.0), Vector3(64.0, 32.0, 64.0))
	var batch_support := Planner.support_bounds(batch_core, 1.0, 0.25, 0.5)
	context.size = batch_support.size
	context.global_transform = Transform3D(Basis.IDENTITY,
			batch_support.position + batch_support.size * 0.5)
	var batch_trace_bounds := batch_support.grow(96.0)
	var batch_collector := Placement.new()
	var batch_ok := batch_collector.collect(context, true, true, false, false, batch_trace_bounds)
	require(batch_ok and batch_collector.bvh_ready,
			"The baker's bounded 64m geometry batch must collect without attempting a 512m block BVH: %s" % batch_collector.error_message)
	require(batch_collector.faces.size() / 3 > page_collector.faces.size() / 3
			and batch_collector.faces.size() / 3 < Placement.MAX_GEOMETRY_TRIANGLES,
			"A bounded multi-page batch must exercise substantial geometry below the unchanged hard cap.")
	print("STREAMED_PLANE whole_block_triangles=", block_collector.reflectance.size(),
			" whole_block_reason=", block_collector.error_message,
			" page_trace_extent=", page_trace_bounds.size,
			" page_triangles=", page_collector.faces.size() / 3,
			" batch_trace_extent=", batch_trace_bounds.size,
			" batch_triangles=", batch_collector.faces.size() / 3,
			" page_bvh=", page_collector.bvh_ready)
	test_root.queue_free()
