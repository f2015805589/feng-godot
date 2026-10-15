extends SceneTree

const Stream = preload("../passes/magic_gi_page_stream.gd")
const Residency = preload("../passes/magic_gi_page_residency.gd")
const PageUpload = preload("../passes/magic_gi_page_upload.gd")
const DirectionalCache = preload("../passes/magic_gi_directional_cache.gd")
const Clipmap = preload("../passes/magic_gi_clv_cache.gd")
const MagicGIPass = preload("../passes/magic_gi_pass.gd")
const ApplyShader: RDShaderFile = preload("../library/magic-gi/magic_gi_apply.glsl")
const PendingShader: RDShaderFile = preload("../library/magic-gi/magic_gi_pending_page.glsl")

class MinimalPageData extends Resource:
	var grid_dims := Vector3i.ONE
	var spacing := 1.0
	var format_version := 6
	var bake_version := 3
	var directional: Resource

	func probe_count() -> int:
		return 1

class MinimalDirectionalData extends Resource:
	var probe_count := 1
	var source_count := 1
	var transfer := PackedFloat32Array([0.25, 0.5, 0.75, 1.0])
	var sky := PackedFloat32Array([1.0, 0.75, 0.5, 0.25])
	var emission := PackedFloat32Array([0.125, 0.25, 0.5, 1.0])

var failures := 0
var checks := 0

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	check(RenderingServer.get_rendering_device() == null,
		"page scheduler and rollback tests run without a RenderingDevice/GPU")
	for shader_file in [ApplyShader, PendingShader]:
		var spirv: RDShaderSPIRV = shader_file.get_spirv()
		check(spirv != null and not spirv.bytecode_compute.is_empty()
				and spirv.compile_error_compute.is_empty() and shader_file.base_error.is_empty(),
			"streamed and pending shaders compile to SPIR-V in the CPU importer")
	var west := {"page_key": "west", "core_bounds": AABB(Vector3(0, 0, 0), Vector3(32, 32, 32)),
		"support_bounds": AABB(Vector3(-2, -2, -2), Vector3(36, 36, 36))}
	var east := {"page_key": "east", "core_bounds": AABB(Vector3(32, 0, 0), Vector3(32, 32, 32)),
		"support_bounds": AABB(Vector3(30, -2, -2), Vector3(36, 36, 36))}
	var pages: Array[Dictionary] = [east, west]
	check(Stream.owner_index(pages, Vector3(4, 4, 4)) == 1,
		"a point inside a page core must have that page as sole owner")
	check(Stream.owner_index(pages, Vector3(32, 4, 4)) == 0,
		"the shared edge must be half-open and owned by the eastern page")
	check(Stream.owner_index(pages, Vector3(68, 4, 4)) == -1,
		"support halos cannot acquire ownership outside all cores")
	check(Stream.owner_index(pages, Vector3(32, 32, 32)) == -1,
		"the upper corner of a half-open page is outside its core")
	var owner_pass := MagicGIPass.new()
	var shared_page := {"page_key": "0_0_0", "version": 4, "identity": "same"}
	var first_world := {"world_id": 3, "volume_id": 9, "manifest_key": "shared",
		"generation": "generation-a"}
	var second_world := first_world.duplicate()
	second_world["world_id"] = 4
	check(owner_pass._stream_cache_namespace(first_world)
			!= owner_pass._stream_cache_namespace(second_world)
			and Stream.stable_version_key(owner_pass._stream_cache_namespace(first_world), shared_page)
			!= Stream.stable_version_key(owner_pass._stream_cache_namespace(second_world), shared_page)
			and owner_pass._stream_owner_page_key(first_world, shared_page)
			!= owner_pass._stream_owner_page_key(second_world, shared_page)
			and owner_pass._stream_page_epoch(first_world, shared_page, 5)
			!= owner_pass._stream_page_epoch(second_world, shared_page, 5),
		"same-manifest pages, mutable lighting and CLV epochs are namespaced per World and Volume")
	check(floor(-0.01 / Stream.MANAGER_BLOCK_XZ) == -1
			and floor(0.0 / Stream.MANAGER_BLOCK_XZ) == 0
			and floor(512.0 / Stream.MANAGER_BLOCK_XZ) == 1,
		"manager block addressing must remain world-origin aligned for negative and positive coordinates")

	var projection := Projection.IDENTITY
	var projected := Stream.project_core(AABB(Vector3(-0.5, 0.2, -0.5), Vector3(1.0, 0.6, 1.0)),
		projection, Vector3(10, 10, 10), Vector2i(100, 100))
	check(bool(projected.get("visible", false))
			and projected.get("rect", Rect2i()) == Rect2i(Vector2i(25, 60), Vector2i(50, 30)),
		"a page uses the same unflipped NDC y convention as the GI shader")
	var projected_pages := owner_pass._project_streamed_pages(pages, projection,
		Vector3(10, 10, 10), Vector2i(100, 100), Transform3D.IDENTITY,
		AABB(Vector3(-8, -8, -8), Vector3(16, 16, 16)))
	for page in pages:
		var page_key: String = page.page_key
		var cached_projection: Dictionary = projected_pages[page_key]
		var reference_projection: Dictionary = Stream.project_core(page.core_bounds,
			projection, Vector3(10, 10, 10), Vector2i(100, 100), Transform3D.IDENTITY)
		check(cached_projection.projection == reference_projection
				and cached_projection.cache_near == owner_pass._aabb_intersects(
					page.core_bounds, AABB(Vector3(-8, -8, -8), Vector3(16, 16, 16))),
			"the shared per-view page projection packet preserves the existing screen and CLV tests")
		check(Stream.gpu_relevant(page.core_bounds, cached_projection.projection,
				AABB(Vector3(-8, -8, -8), Vector3(16, 16, 16)))
				== (bool(cached_projection.projection.get("visible", false))
					or bool(cached_projection.cache_near)),
			"cached visibility and prefetch flags preserve the existing GPU-demand predicate")
	var translated_camera := Transform3D(Basis.IDENTITY, Vector3(1, 0, 0))
	var translated_world_to_view := translated_camera.affine_inverse()
	var translated_projection := Stream.project_core(
		AABB(Vector3(1.2, 0.2, 0.0), Vector3(0.4, 0.4, 1.0)), Projection.IDENTITY,
		translated_camera.origin, Vector2i(100, 100), translated_world_to_view)
	var translated_rect: Rect2i = translated_projection.get("rect", Rect2i())
	check(translated_rect.position.x <= 60 and translated_rect.position.y <= 60
			and translated_rect.end.x >= 80 and translated_rect.end.y >= 80,
		"CPU screen bounds transform world-space page corners into camera view space without omitting covered pixels")
	var camera_inside := Stream.project_core(AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2)),
		projection, Vector3.ZERO, Vector2i(100, 80))
	check(bool(camera_inside.get("full_view", false))
			and camera_inside.get("rect", Rect2i()).size == Vector2i(100, 80),
		"a camera inside a page must use the necessary full-view dispatch")
	var behind := Stream.project_core(AABB(Vector3(3, 0, 0), Vector3.ONE),
		projection, Vector3.ZERO, Vector2i(100, 100))
	check(not bool(behind.get("visible", false)), "a wholly outside projected page does not dispatch")
	var perspective := Projection.create_perspective(90.0, 1.0, 0.1, 100.0)
	var all_behind := Stream.project_core(AABB(Vector3(-0.5, -0.5, 1.0), Vector3.ONE),
		perspective, Vector3.ZERO, Vector2i(100, 100))
	check(not bool(all_behind.get("visible", false)),
		"a page with all corners behind the camera is skipped instead of owning the full screen")
	var near_crossing := Stream.project_core(
		AABB(Vector3(-0.5, -0.5, -0.05), Vector3(1.0, 1.0, 0.25)),
		perspective, Vector3.ZERO, Vector2i(100, 100))
	check(bool(near_crossing.get("full_view", false)),
		"only a page crossing the camera near plane requires conservative full-view dispatch")
	var cache_prefetch_bounds := AABB(Vector3(-16, -16, -16), Vector3(32, 32, 32))
	check(not Stream.gpu_relevant(AABB(Vector3(80, 80, 80), Vector3.ONE), behind,
			cache_prefetch_bounds)
			and Stream.gpu_relevant(AABB(Vector3(8, 8, 8), Vector3.ONE), behind,
				cache_prefetch_bounds),
		"offscreen CPU-ready pages outside the current CLV window do not enter GPU residency")
	var rotated_owner := Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(4, 5, 6))
	check(Stream.obb_contains(rotated_owner, Vector3(2, 4, 6), Vector3(4, 5, 6))
			and not Stream.obb_contains(rotated_owner, Vector3(2, 4, 6), Vector3(8, 5, 6)),
		"the original rotated volume OBB constrains pixel ownership after page AABB selection")

	var residents := Residency.new()
	residents.begin_frame(40, 128 * 1024 * 1024, 16 * 1024 * 1024, 12 * 1024 * 1024)
	var first := residents.admit("v/page-a", "page-a", 64 * 1024 * 1024)
	check(bool(first.get("admitted", false)), "a page inside the GPU budget is admitted")
	residents.mark_ready("v/page-a")
	residents.begin_frame(41, 128 * 1024 * 1024, 16 * 1024 * 1024, 12 * 1024 * 1024)
	var second := residents.admit("v/page-b", "page-b", 64 * 1024 * 1024)
	check(bool(second.get("admitted", false)) and second.get("evicted", PackedStringArray()).has("v/page-a"),
		"byte-budget admission evicts the least recently used inactive page")
	check(residents.resident_bytes() == 64 * 1024 * 1024,
		"resident-byte accounting includes the page resources")
	check(not residents.account_upload(16 * 1024 * 1024 + 1),
		"one indivisible upload larger than the frame budget is rejected")
	check(residents.account_upload(8 * 1024 * 1024)
			and residents.account_upload(8 * 1024 * 1024)
			and not residents.account_upload(1),
		"all texture uploads share one strict per-frame byte budget")
	residents.begin_frame(41, 96 * 1024 * 1024, 8 * 1024 * 1024, 12 * 1024 * 1024)
	check(residents.upload_bytes_this_frame() == 16 * 1024 * 1024
			and residents.effective_gpu_budget_bytes() == 84 * 1024 * 1024,
		"additional views cannot reset upload usage and the tightest snapshot budget applies")
	residents.begin_frame(42, 128 * 1024 * 1024, 16 * 1024 * 1024, 12 * 1024 * 1024)
	var too_large := residents.admit("v/too-large", "too-large", 120 * 1024 * 1024)
	check(not bool(too_large.get("admitted", false)),
		"a single page cannot consume the global reserve needed by CLV and shared resources")

	var shrinking := Residency.new()
	shrinking.begin_frame(70, 100, 80, 0, 8)
	check(bool(shrinking.admit("a", "a", 40).get("admitted", false))
			and bool(shrinking.admit("b", "b", 40).get("admitted", false)),
		"two pages fit before a runtime budget reduction")
	var same_frame_evictions := shrinking.begin_frame(70, 60, 40, 0, 8)
	check(same_frame_evictions.is_empty() and shrinking.resident_bytes() == 80
			and shrinking.over_budget_bytes() == 20,
		"a mid-frame shrink protects already active views and reports bounded backpressure")
	check(not bool(shrinking.admit("c", "c", 1).get("admitted", false)),
		"new allocations are rejected while active pages alone exceed the shrunken budget")
	var next_frame_evictions := shrinking.begin_frame(71, 60, 40, 0, 8)
	check(next_frame_evictions.size() == 1 and shrinking.resident_bytes() == 40
			and shrinking.over_budget_bytes() == 0,
		"the next frame returns the inactive LRU page for RID release and trims physical residency")
	var after_trim := shrinking.admit("c", "c", 20)
	check(bool(after_trim.get("admitted", false)) and shrinking.resident_bytes() == 60,
		"admission resumes once the ledger has trimmed to the new total budget")
	var multiview := Residency.new()
	multiview.begin_frame(90, 100, 100, 0, 8)
	multiview.admit("left", "left", 40)
	multiview.mark_ready("left")
	multiview.admit("right", "right", 40)
	multiview.mark_ready("right")
	var active_union_evictions := multiview.begin_frame(91, 60, 60, 0, 8,
		PackedStringArray(["left", "right"]))
	check(active_union_evictions.is_empty() and multiview.resident_bytes() == 80
			and multiview.over_budget_bytes() == 20,
		"same-target active views retain their resident union and apply backpressure when it exceeds budget")
	var inactive_view_evictions := multiview.begin_frame(92, 60, 60, 0, 8)
	check(inactive_view_evictions.size() == 1 and multiview.resident_bytes() == 40,
		"pages from expired views become evictable on the next frame")
	var turning_view := Residency.new()
	turning_view.begin_frame(93, 100, 100, 0, 8)
	turning_view.admit("rear", "rear", 60)
	turning_view.mark_ready("rear")
	turning_view.begin_frame(94, 100, 100, 0, 8, PackedStringArray(["front"]))
	var front_admission := turning_view.admit("front", "front", 60)
	check(bool(front_admission.get("admitted", false))
			and front_admission.get("evicted", PackedStringArray()).has("rear"),
		"turning the view transfers GPU residency to the new visible window rather than pinning old pages")

	var failed_upload := PageUpload.new()
	check(not failed_upload.begin(null, {"data": null}, "failed"),
		"invalid page creation fails before touching a RenderingDevice")
	check(failed_upload.failed() and not failed_upload.has_pending_allocations()
			and not failed_upload.has_pending_uploads() and failed_upload.owned_rids().is_empty(),
		"a failed allocation transaction has no stuck pending work or leaked temporary RIDs")
	var staged_upload := PageUpload.new()
	staged_upload._allocation_tasks = [
		{"kind": "buffer", "name": "transfer", "size": 4},
		{"kind": "buffer", "name": "primary_sky", "size": 4},
		{"kind": "buffer", "name": "geometry", "size": 4},
	]
	# Model one frame that has allocated exactly two resources. The next upload
	# task is valid but its allocation belongs to the following frame.
	staged_upload._allocation_index = 2
	staged_upload._upload_tasks = [{"kind": "buffer", "name": "geometry",
		"bytes": PackedByteArray([0, 0, 0, 0])}]
	var staged_consumed := staged_upload.upload_step(null, 4)
	check(staged_consumed == 0 and not staged_upload.failed()
			and staged_upload._allocation_index == 2 and staged_upload._upload_index == 0
			and staged_upload._upload_offset == 0 and staged_upload.has_pending_allocations()
			and staged_upload.has_pending_uploads(),
		"after the two-allocation frame cap, upload waits at the first unallocated RID without spending frame bytes")
	staged_upload._allocation_index = staged_upload._allocation_tasks.size()
	staged_upload._allocation_tasks.clear()
	check(staged_upload.upload_step(null, 4) == -1 and staged_upload.failed()
			and not staged_upload.has_pending_allocations() and not staged_upload.has_pending_uploads()
			and staged_upload.owned_rids().is_empty(),
		"an exhausted allocation queue with a missing RID fails and rolls back instead of waiting forever")
	var invalid_rid_upload := PageUpload.new()
	invalid_rid_upload.cache["geometry"] = RID()
	invalid_rid_upload._upload_tasks = [{"kind": "buffer", "name": "geometry",
		"bytes": PackedByteArray([0, 0, 0, 0])}]
	check(invalid_rid_upload.upload_step(null, 4) == -1 and invalid_rid_upload.failed()
			and invalid_rid_upload.owned_rids().is_empty(),
		"an already-present but invalid RID fails immediately instead of being treated as pending")
	var published_transfer := Image.create(1, 1, false, Image.FORMAT_RGBAF)
	var published_bundle := {
		"transfer_image": published_transfer,
		"primary_sky_image": Image.create(1, 1, false, Image.FORMAT_RGBAF),
		"geometry_image": Image.create(1, 1, false, Image.FORMAT_RGBAF),
		"visibility_moment_image": Image.create(1, 1, false, Image.FORMAT_RGF),
		"emission_image": Image.create(1, 1, false, Image.FORMAT_RGBAF),
		"visibility_node_bytes": PackedByteArray().duplicate(),
		"visibility_triangle_bytes": PackedByteArray().duplicate(),
		"index_bytes": PackedByteArray(),
		"index_entries": PackedByteArray([0, 0, 0, 0]),
		"marker": "resident-bundle",
	}
	published_bundle.visibility_node_bytes.resize(32)
	published_bundle.visibility_triangle_bytes.resize(48)
	published_bundle.index_bytes.resize(32)
	var published_bundle_size := published_bundle.size()
	var published_nodes: PackedByteArray = published_bundle.visibility_node_bytes
	var published_triangles: PackedByteArray = published_bundle.visibility_triangle_bytes
	var published_indices: PackedByteArray = published_bundle.index_bytes
	var page_descriptor := {"data": MinimalPageData.new(), "render_upload": published_bundle,
		"support_bounds": AABB(Vector3.ZERO, Vector3.ONE)}
	var descriptor_uploader := PageUpload.new()
	check(descriptor_uploader.begin(null, page_descriptor, "descriptor"),
		"a minimally valid prepacked page can enter staged upload without a RenderingDevice")
	descriptor_uploader._upload_index = descriptor_uploader._upload_tasks.size()
	check(descriptor_uploader.upload_step(null, 0) == 0
			and not descriptor_uploader._upload.has("marker")
			and published_bundle.size() == published_bundle_size
			and published_bundle.get("marker", "") == "resident-bundle"
			and published_bundle.visibility_node_bytes == published_nodes
			and published_bundle.visibility_triangle_bytes == published_triangles
			and published_bundle.index_bytes == published_indices
			and published_bundle.transfer_image == published_transfer,
		"completing surface uploads clears only the uploader's shallow bundle copy")
	var failed_descriptor_uploader := PageUpload.new()
	check(failed_descriptor_uploader.begin(null, page_descriptor, "descriptor-failure"),
		"the same immutable descriptor can start a second view's independent upload")
	failed_descriptor_uploader._fail("simulated allocation failure")
	check(failed_descriptor_uploader.failed() and published_bundle.size() == published_bundle_size
			and published_bundle.get("marker", "") == "resident-bundle"
			and published_bundle.visibility_node_bytes == published_nodes
			and published_bundle.visibility_triangle_bytes == published_triangles
			and published_bundle.index_bytes == published_indices,
		"failed upload cleanup cannot clear the shared resident descriptor bundle")
	var directional_data := MinimalPageData.new()
	directional_data.directional = MinimalDirectionalData.new()
	published_bundle["directional_transfer_bytes"] = PackedByteArray([1, 2, 3, 4])
	published_bundle["directional_sky_bytes"] = PackedByteArray([5, 6, 7, 8])
	published_bundle["directional_emission_bytes"] = PackedByteArray([9, 10, 11, 12])
	published_bundle["normal_bytes"] = PackedByteArray([13, 14, 15, 16])
	var late_allocation_page := page_descriptor.duplicate(false)
	late_allocation_page["data"] = directional_data
	var late_allocation_upload := PageUpload.new()
	check(late_allocation_upload.begin(null, late_allocation_page, "late-directional"),
		"a directional page can stage with surface and directional bundles present")
	late_allocation_upload._allocation_index = late_allocation_upload._allocation_tasks.size() - 1
	late_allocation_upload._upload_index = late_allocation_upload._upload_tasks.size()
	var last_base_allocation: Dictionary = late_allocation_upload._allocation_tasks[
		late_allocation_upload._allocation_index]
	check(late_allocation_upload.upload_step(null, 0) == 0
			and late_allocation_upload._upload.has("directional_transfer_bytes")
			and late_allocation_upload._allocation_index < late_allocation_upload._allocation_tasks.size()
			and last_base_allocation.get("name", "") == "probe_lighting"
			and not late_allocation_upload.is_ready(),
		"when one allocation remains, completed surface uploads retain bytes needed by a later directional begin")
	var late_directional: RefCounted = DirectionalCache.new()
	check(late_directional.begin_create(null, directional_data, late_allocation_upload._upload)
			and late_directional._payloads.get("transfer") == published_bundle.directional_transfer_bytes
			and late_directional.has_pending_allocations() and not late_directional.is_ready(),
		"DirectionalCache captures the prepacked payload after the last surface allocation")
	late_allocation_upload._directional_upload = late_directional
	late_allocation_upload._directional_started = true
	check(late_allocation_upload.upload_step(null, 0) == 0
			and late_allocation_upload._upload.is_empty()
			and late_directional._payloads.get("transfer") == published_bundle.directional_transfer_bytes,
		"the local bundle can be released after directional staging owns the packed payload")
	var failed_residency := Residency.new()
	failed_residency.begin_frame(80, 100, 80, 0, 8)
	failed_residency.admit("failed", "failed", 40)
	var failed_pass := MagicGIPass.new()
	failed_pass._page_residency = failed_residency
	failed_pass._page_uploads["failed"] = failed_upload
	failed_pass._rollback_failed_stream_page("failed", 4, null)
	check(failed_residency.resident_bytes() == 0 and failed_residency.entry("failed").is_empty()
			and not failed_pass._page_uploads.has("failed")
			and not failed_upload.has_pending_allocations() and not failed_upload.has_pending_uploads()
			and failed_pass._stream_page_failed_for_revision("failed", 4)
			and not failed_pass._stream_page_failed_for_revision("failed", 5),
		"failed page setup frees partial work, rolls back its reservation and waits for a new revision")
	var bounded_failures := MagicGIPass.new()
	for failed_index in 520:
		bounded_failures._remember_failed_stream_page_revision(
			"world/volume/page-%d" % failed_index, failed_index)
	check(bounded_failures._page_failed_versions.size() == MagicGIPass.MAX_FAILED_STREAM_PAGE_REVISIONS
			and bounded_failures._stream_page_failed_for_revision("world/volume/page-519", 519),
		"failure metadata stays bounded while retaining the most recent immutable page revision")
	var fallback_pass := MagicGIPass.new()
	var fallback_ledger := Residency.new()
	fallback_ledger.begin_frame(100, 128, 128, 0, 8)
	fallback_ledger.admit("manifest/page/1/old", "page", 32)
	fallback_ledger.mark_ready("manifest/page/1/old")
	fallback_pass._page_residency = fallback_ledger
	var stable_core := AABB(Vector3.ZERO, Vector3.ONE * 32.0)
	var old_descriptor := {"page_key": "page", "core_bounds": stable_core,
		"identity": "old", "version": 1}
	var fallback_snapshot := {"world_id": 3, "volume_id": 7}
	fallback_pass._bake_resources["manifest/page/1/old"] = {
		"identity": "old", "page_revision": 1, "published_page": old_descriptor}
	fallback_pass._page_ready_by_key[fallback_pass._stream_owner_page_key(
		fallback_snapshot, old_descriptor)] = "manifest/page/1/old"
	var next_descriptor := {"page_key": "page", "core_bounds": stable_core,
		"identity": "new", "version": 2}
	var previous_page: Dictionary = fallback_pass._stream_page_fallback(
		fallback_snapshot, next_descriptor, "manifest/page/2/new")
	check(previous_page.get("identity", "") == "old"
			and previous_page.get("_cache_key", "") == "manifest/page/1/old",
		"a same-owner, same-core old page remains renderable while its new immutable revision uploads")
	check(fallback_pass._stream_page_fallback(fallback_snapshot, old_descriptor,
		"manifest/page/1/old").get("identity", "") == "old",
		"an emissive-texture-only wait can retain the exact same static page revision")
	var moved_descriptor := next_descriptor.duplicate()
	moved_descriptor["core_bounds"] = AABB(Vector3(32, 0, 0), Vector3.ONE * 32.0)
	check(fallback_pass._stream_page_fallback(fallback_snapshot, moved_descriptor,
		"manifest/page/2/new").is_empty(),
		"old page fallback cannot claim ownership after its core moves")
	var other_volume := fallback_snapshot.duplicate()
	other_volume["volume_id"] = 8
	check(fallback_pass._stream_page_fallback(other_volume, next_descriptor,
		"manifest/page/2/new").is_empty(),
		"a different volume cannot reuse a same-named page's cached fallback")

	var clv := Clipmap.new()
	clv.queue_updates(Vector3.ZERO, 1.0, 3)
	clv._pending.clear()
	clv._pending_set.clear()
	clv._cursor = 0
	var boundary_core := AABB(Vector3.ZERO, Vector3.ONE)
	check(clv.queue_page_revision("boundary", boundary_core, 1.0, 7) == 1
			and clv._pending == [Vector4i(0, 0, 0, 0)],
		"page enqueue uses half-open cell-center bounds at the exact core boundary")
	clv._pending.clear()
	clv._pending_set.clear()
	clv._page_epochs.clear()
	var offset_core := AABB(Vector3(-0.25, -1.25, 0.75), Vector3(2.0, 3.5, 1.25))
	var reported_added: int = clv.queue_page_revision("offset", offset_core, 1.0, 8)
	var expected_cells: Dictionary = {}
	var actual_cells: Dictionary = {}
	for level in Clipmap.LEVELS:
		var step := float(1 << level)
		var origin: Vector3i = clv._origins[level]
		var end := origin + Vector3i.ONE * Clipmap.RESOLUTION
		for z in range(origin.z, end.z):
			for y in range(origin.y, end.y):
				for x in range(origin.x, end.x):
					var center := (Vector3(x, y, z) + Vector3.ONE * 0.5) * step
					if center.x >= offset_core.position.x and center.y >= offset_core.position.y \
							and center.z >= offset_core.position.z \
							and center.x < offset_core.end.x and center.y < offset_core.end.y \
							and center.z < offset_core.end.z:
						expected_cells[Vector4i(x, y, z, level)] = true
	for cell in clv._pending:
		actual_cells[cell] = true
	check(reported_added == expected_cells.size() and actual_cells == expected_cells,
		"bounded integer intersection matches brute-force half-open centers for offset bounds")
	clv._pending.clear()
	clv._pending_set.clear()
	clv._page_epochs.clear()
	for i in 257:
		clv.queue_page_revision("page-%d" % i, boundary_core, 1.0, i)
	check(clv._page_epochs.size() == Clipmap.MAX_PAGE_EPOCHS,
		"page epoch bookkeeping remains bounded during long-running page churn")
	clv.retain_page_epochs(PackedStringArray(["page-256"]))
	check(clv._page_epochs.size() == 1 and clv._page_epochs.has("page-256"),
		"resident page epoch retention prunes inactive page metadata")

	var legacy_pages := Stream.normalize_streamed_snapshot({"streamed": false,
		"data": Resource.new(), "pages": []})
	check(legacy_pages.is_empty(), "legacy snapshots stay on their unchanged single-data path")

	print("MAGIC_GI_PAGE_STREAM checks=%d failures=%d" % [checks, failures])
	quit(1 if failures > 0 else 0)
