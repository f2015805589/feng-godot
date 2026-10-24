extends SceneTree
const Brick = preload("../feng_magic_gi_prepared_transfer_brick.gd")
const Preview = preload("../feng_magic_gi_prepared_brick_preview.gd")
const Coordinator = preload("../feng_magic_gi_volume_preview.gd")
const Chunk = preload("../feng_magic_gi_volume_source_chunk.gd")
const Page = preload("../feng_magic_gi_page.gd")
const Manifest = preload("../feng_magic_gi_manifest.gd")
class FakeVolume:
	extends RefCounted
	var display_probes_by_clv := false
	var probe_clv_view := 0
	var probe_clv_level := -1
	var bake_manifest: Resource
var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("run")

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(message)

func run() -> void:
	var brick := Brick.new()
	brick.dimensions = Vector3i(4, 1, 1)
	brick.core_cell_origin = Vector3i(1, 0, 0)
	brick.core_dimensions = Vector3i(2, 1, 1)
	brick.probe_count = 4
	brick.source_size_m = Vector3.ONE
	brick.domain_bounds_world = AABB(Vector3.ONE * -0.5, Vector3.ONE)
	brick.emitter_count = 1
	brick.emitter_ids = PackedStringArray(["e"])
	brick.emitter_static_signatures = PackedInt64Array([5])
	brick.directional_source_signature = "test"
	brick.validity = PackedByteArray([1, 1, 0, 1])
	brick.operators.resize(4 * 9 * 42)
	var row := 9 * 42
	brick.operators[row] = 2
	brick.operators[row + 1] = -2
	brick.operators[row + 27] = 3
	brick.operators[row + 36] = 4
	brick.operators[row + 37] = -4
	brick.operators[row + 39] = 6
	brick.operators[row + 40] = 0.5
	var lighting := PackedFloat32Array()
	lighting.resize(27)
	lighting[0] = 1
	lighting[1] = 2
	var sky := PackedFloat32Array()
	sky.resize(27)
	sky[0] = 2
	sky[1] = 3
	sky[2] = 4
	var pages := [{"prepared_transfer_brick": brick, "emission_sources": PackedFloat32Array([5, 6, 7, 7, 8, 9])}]
	var result := Preview.build(pages, lighting, sky)
	check(bool(result.get("current_available", false)), "prepared preview computes live SH")
	check(result.positions == PackedVector3Array([Vector3(0.25, 0, 0)]), "only valid core cells appear; halo is not duplicated")
	check(result.response_sh.size() == 27 and result.response_sh[0] == 70.0 \
			and result.response_sh[1] == -15.0 and result.response_sh[2] == 12.0, "signed transfer, primary sky and both emission families match shader indexing")
	check(result.source_kind == "prepared_brick", "prepared cells are labeled separately from original source probes")
	check(Preview.build(pages, lighting, sky, func(): return true).is_empty(), "worker cancellation never publishes partial output")
	lighting[0] = NAN
	check(Preview.build(pages, lighting, sky).is_empty(), "nonfinite live input rejected")
	lighting[0] = 1
	var volume := FakeVolume.new()
	volume.bake_manifest = Manifest.new()
	var id := volume.get_instance_id()
	check(Coordinator.snapshot(volume, pages, lighting, sky, []).is_empty(), "debug disabled performs no work")
	Coordinator.set_requested(id, true)
	Coordinator.snapshot(volume, pages, lighting, sky, [])
	await _finish_jobs()
	result = Coordinator.snapshot(volume, pages, lighting, sky, [])
	check(result.get("source_kind", "") == "prepared_brick", "coordinator falls back to resident prepared pages")
	Coordinator.set_requested(id, false)
	check(not Coordinator._cached.has(id) and not Coordinator._debug_sources.has(id), "disable releases cached preview and diagnostic source")
	var page := _source_page()
	var path := "res://Temp/preview_source_" + str(Time.get_ticks_usec()) + ".res"
	check(ResourceSaver.save(page, path, ResourceSaver.FLAG_COMPRESS) == OK, "diagnostic source fixture saves")
	volume.bake_manifest.prepared_debug_source_path = path
	Coordinator.set_requested(id, true)
	Coordinator.snapshot(volume, [], lighting, sky, [])
	check(Coordinator._debug_loads.has(id) and not Coordinator._debug_sources.has(id), "original source is requested asynchronously only after source debug is enabled")
	for frame in 200:
		await process_frame
		Coordinator._poll_debug_loads()
		if not Coordinator._debug_loads.has(id): break
	check(Coordinator._debug_sources.has(id), "asynchronous diagnostic page completes")
	Coordinator.snapshot(volume, [], lighting, sky, [])
	await _finish_jobs()
	result = Coordinator.snapshot(volume, [], lighting, sky, [])
	check(result.get("source_kind", "") == "original_source_probe", "migration shows actual original source points")
	Coordinator.set_requested(id, false)
	check(not Coordinator._debug_sources.has(id), "closing debug releases the loaded raw source page")
	Coordinator.set_requested(id, true)
	Coordinator.snapshot(volume, [], lighting, sky, [])
	Coordinator.set_requested(id, false)
	for frame in 200:
		await process_frame
		Coordinator._poll_debug_loads()
		if not Coordinator._debug_loads.has(id): break
	check(not Coordinator._debug_sources.has(id) and not Coordinator._debug_loads.has(id), "close during loading drains request without late publication")
	await _finish_jobs()
	print("MAGIC_GI_PREPARED_BRICK_PREVIEW checks=", checks, " failures=", failures)
	quit(1 if failures else 0)

func _finish_jobs() -> void:
	for frame in 200:
		await process_frame
		Coordinator._poll_jobs()
		if Coordinator._jobs.is_empty(): return

func _source_page() -> Page:
	var chunk := Chunk.new()
	chunk.allocate(Vector3i.ONE, PackedStringArray())
	chunk.source_size_m = Vector3.ONE * 0.25
	chunk.source_transform_world = Transform3D(Basis.IDENTITY, Vector3.ONE * 0.125)
	chunk.source_bounds_world = AABB(Vector3.ZERO, Vector3.ONE * 0.25)
	chunk.domain_bounds_world = chunk.source_bounds_world
	chunk.origin_world = Vector3.ONE * 0.125
	chunk.validity[0] = 1
	chunk.trace_distance_m = 2
	chunk.bake_samples = 1
	chunk.bake_bounces = 1
	chunk.moment_rays = 256
	for texel in 64:
		chunk.receiver_visibility_moments[texel * 2] = 1
		chunk.receiver_visibility_moments[texel * 2 + 1] = 1
	chunk.directional_source_signature = chunk.make_directional_source_signature()
	var page := Page.new()
	page.generation = "debug"
	page.page_key = "source"
	page.core_bounds = chunk.domain_bounds_world
	page.support_bounds = chunk.domain_bounds_world
	page.probe_count = 1
	page.cpu_bytes = chunk.estimated_cpu_resident_bytes()
	page.gpu_bytes = chunk.estimated_gpu_payload_bytes()
	page.free_space_volume_source = chunk
	return page
