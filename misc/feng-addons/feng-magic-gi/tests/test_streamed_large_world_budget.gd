extends SceneTree
## CPU-only regression for large-world IDs and bounded streamed geometry collection.

const Placement = preload("res://addons/feng-magic-gi/feng_magic_gi_placement.gd")
const Baker = preload("res://addons/feng-magic-gi/feng_magic_gi_baker.gd")
const PageContext = preload("res://addons/feng-magic-gi/feng_magic_gi_page_context.gd")
const Planner = preload("res://addons/feng-magic-gi/feng_magic_gi_page_planner.gd")
const Manifest = preload("res://addons/feng-magic-gi/feng_magic_gi_manifest.gd")

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
