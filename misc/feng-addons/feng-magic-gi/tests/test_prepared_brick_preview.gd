extends SceneTree
const Brick = preload("../feng_magic_gi_prepared_transfer_brick.gd")
const Preview = preload("../feng_magic_gi_prepared_brick_preview.gd")
const Coordinator = preload("../feng_magic_gi_volume_preview.gd")
const CLVPreview = preload("../../feng-render-pipeline/passes/magic_gi_clv_editor_snapshot.gd")
const Viz = preload("../feng_magic_gi_viz.gd")
const Volume = preload("../feng_magic_gi_volume.gd")
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
	brick.operator_schema_version = 2
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
	brick.operators.resize(4 * 4 * 22)
	var row := 4 * 22
	brick.operators[row] = 2
	brick.operators[row + 1] = -2
	brick.operators[row + 12] = 3
	brick.operators[row + 16] = 4
	brick.operators[row + 17] = -4
	brick.operators[row + 19] = 6
	brick.operators[row + 20] = 0.5
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
	check(result.response_sh.size() == 12 and result.response_coefficient_count == 4 \
			and result.response_sh[0] == 70.0 \
			and result.response_sh[1] == -15.0 and result.response_sh[2] == 12.0, "signed transfer, primary sky and both emission families match shader indexing")
	check(result.source_kind == "prepared_brick", "prepared cells are labeled separately from original source probes")
	var filter_input := {"revision": 1, "layout_key": "sh2-filter",
		"positions": PackedVector3Array([Vector3.ZERO, Vector3.ONE]),
		"spacings": PackedFloat32Array([0.25, 0.5]), "lods": PackedInt32Array([0, 1]),
		"response_coefficient_count": 4,
		"response_sh": PackedFloat32Array()}
	for value in range(24): filter_input.response_sh.append(float(value))
	var filtered := Coordinator._filter_clv(991001, filter_input, 1)
	check(filtered.positions.size() == 1 and filtered.response_sh.size() == 12 \
			and filtered.response_coefficient_count == 4 and filtered.response_sh[0] == 12.0 \
			and filtered.response_sh[11] == 23.0,
		"CLV level filtering keeps the compact SH2 response and its coefficient metadata")
	filter_input.response_coefficient_count = 9
	filter_input.response_sh.clear()
	for value in range(54): filter_input.response_sh.append(float(value))
	filtered = Coordinator._filter_clv(991002, filter_input, 1)
	check(filtered.response_sh.is_empty() and filtered.response_coefficient_count == 0 \
			and not Viz._volume_sh_available(filtered),
		"legacy SH9 CLV fields are not misrepresented as a runtime-matching SH2 response")
	check(Preview.build(pages, lighting, sky, func(): return true).is_empty(), "worker cancellation never publishes partial output")
	_test_sh2_visual_layers()
	lighting[0] = NAN
	check(Preview.build(pages, lighting, sky).is_empty(), "nonfinite live input rejected")
	lighting[0] = 1
	var volume := FakeVolume.new()
	volume.bake_manifest = Manifest.new()
	var id := volume.get_instance_id()
	CLVPreview.set_request(-991003, true, true, 500, 123456)
	check(CLVPreview.has_request(-991003, 123456),
		"CLV editor request broker accepts signed negative instance IDs")
	CLVPreview.set_request(-991003, false)
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
	# Mode changes may share the same preview node, but source SH and the actual
	# resident CLV snapshot must stay isolated in the coordinator/cache.
	var transition_volume := FakeVolume.new()
	transition_volume.bake_manifest = Manifest.new()
	var transition_id := transition_volume.get_instance_id()
	var transition_page := _source_page()
	var transition_pages: Array = [{
		"free_space_volume_source": transition_page.free_space_volume_source,
		"cache_key": "transition-source-sh2",
		"emission_sources": PackedFloat32Array(),
	}]
	Coordinator.set_requested(transition_id, true)
	Coordinator.snapshot(transition_volume, transition_pages, lighting, sky, [])
	await _finish_jobs()
	var source_preview := Coordinator.snapshot(transition_volume, transition_pages, lighting, sky, [])
	check(source_preview.get("response_coefficient_count", 0) == 4
			and source_preview.get("source_kind", "") == "original_source_probe",
		"default source preview publishes four SH2 coefficients")
	transition_volume.display_probes_by_clv = true
	var pending_clv := Coordinator.snapshot(transition_volume, transition_pages, lighting, sky,
		[{"viewport_index": 0, "target_id": 123456}])
	check(not bool(pending_clv.get("current_available", false))
			and bool(pending_clv.get("display_by_clv", false))
			and CLVPreview.has_request(transition_id, 123456),
		"CLV mode cannot reuse the prior source-probe response")
	transition_volume.display_probes_by_clv = false
	var source_again := Coordinator.snapshot(transition_volume, transition_pages, lighting, sky, [])
	check(source_again.get("response_coefficient_count", 0) == 4
			and source_again.get("source_kind", "") == "original_source_probe"
			and not CLVPreview.has_requests(),
		"returning to source mode clears the CLV request and restores SH2 source data")
	Coordinator.set_requested(transition_id, false)
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

func _test_sh2_visual_layers() -> void:
	var volume: FMagicGIVolume = Volume.new()
	volume.show_probes = true
	volume.show_sh_probes = true
	volume.set("_layout_stale", false)
	var response := PackedFloat32Array([
		3.5449077, 1.0, 0.5, # c0 RGB
		0.2, -0.3, 0.4,      # c1 RGB
		-0.6, 0.7, -0.8,     # c2 RGB
		0.9, -1.0, 1.1,      # c3 RGB
	])
	var source_snapshot := {"volume_probe_preview": true, "current_available": true,
		"positions": PackedVector3Array([Vector3(0.03, 1.0, 2.0)]),
		"spacings": PackedFloat32Array([0.25]), "response_sh": response,
		"response_coefficient_count": 4,
		"response_sh_semantics": "raw_signed_world_incident_radiance_sh2_l0_l1_coefficient_major_rgb",
		"layout_key": "source-sh2-fixture", "revision": 1, "strength": 2.0,
		"editor_views": [{"origin": Vector3(0, 0, 3), "right": Vector3.RIGHT,
			"up": Vector3.UP, "back": Vector3.BACK, "projection_x": 1.0,
			"projection_y": 1.0, "orthogonal": false,
			"viewport_size": Vector2(1280, 720), "exposure_scale": 1.6}],
		"display_by_clv": false}
	var source_root := Viz.build(volume, source_snapshot)
	var probes := source_root.get_node("_Probes") as MultiMeshInstance3D
	var spheres := source_root.get_node("_Transport") as MultiMeshInstance3D
	var sphere_material := spheres.material_override as ShaderMaterial
	var source_texture := spheres.get_meta("volume_preview_texture") as ImageTexture
	check(probes != null and spheres != null and source_root.has_node("_Probes")
			and source_root.has_node("_Transport"),
		"both marker dots and SH spheres can be enabled together")
	check(source_texture != null and source_texture.get_width() == 4
			and sphere_material.get_shader_parameter("response_coefficient_count") == 4,
		"source dots and spheres share the SH2 coefficient layout")
	check(source_texture.get_image().get_pixel(3, 0).is_equal_approx(Color(0.9, -1.0, 1.1)),
		"SH2 sphere texture retains signed coefficients without preview-side mutation")
	check(sphere_material.get_shader_parameter("response_strength") == 2.0,
		"SH sphere applies the live volume strength exactly once")
	check(sphere_material.get_shader_parameter("preview_eye_scale") == Vector4(1.6, 1.0, 1.0, 1.0),
		"source SH2 sphere receives the selected viewport exposure scale")
	volume.show_probes = false
	Viz.rebuild(volume, source_root, source_snapshot)
	check(not source_root.has_node("_Probes") and source_root.has_node("_Transport"),
		"disabling source dots does not alter the SH sphere material/data")
	volume.show_probes = true
	volume.show_sh_probes = false
	Viz.rebuild(volume, source_root, source_snapshot)
	check(source_root.has_node("_Probes") and not source_root.has_node("_Transport"),
		"disabling SH spheres does not alter the probe marker data")
	var clv_snapshot: Dictionary = source_snapshot.duplicate(true)
	clv_snapshot["positions"] = PackedVector3Array([Vector3(10.0, 1.0, 2.0)])
	clv_snapshot["display_by_clv"] = true
	clv_snapshot["layout_key"] = "clv-sh2-fixture"
	clv_snapshot["clv_levels"] = [{"lod": 0, "bounds": AABB(Vector3.ZERO, Vector3.ONE * 20.0)}]
	volume.show_sh_probes = true
	var clv_root := Viz.build(volume, clv_snapshot)
	var clv_probes := clv_root.get_node("_Probes") as MultiMeshInstance3D
	var clv_spheres := clv_root.get_node("_Transport") as MultiMeshInstance3D
	var clv_texture := clv_spheres.get_meta("volume_preview_texture") as ImageTexture
	check(clv_probes != null and clv_root.has_node("_Transport") and clv_root.has_node("_CLVLevel0"),
		"CLV preview keeps its nominal resident-cell position and separate grid bounds")
	check(clv_texture.get_width() == 4
			and clv_texture.get_image().get_pixel(3, 0).is_equal_approx(
				source_texture.get_image().get_pixel(3, 0)),
		"source and CLV debug modes decode the same signed SH2 sample identically")
	var clv_material := clv_spheres.material_override as ShaderMaterial
	check(sphere_material != clv_material,
		"source and CLV SH2 visualization own separate materials")
	check(clv_material.get_shader_parameter("preview_eye_scale") ==
			sphere_material.get_shader_parameter("preview_eye_scale"),
		"simultaneous source/CLV visualization does not share or contaminate exposure uniforms")
	source_root.free()
	clv_root.free()
	volume.free()

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
