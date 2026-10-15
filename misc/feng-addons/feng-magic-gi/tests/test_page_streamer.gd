extends SceneTree
## Exercise the production resource-load, validation, CPU-pack and publication path.

const Data = preload("res://addons/feng-magic-gi/feng_magic_gi_data.gd")
const DirectionalData = preload("res://addons/feng-magic-gi/feng_magic_gi_directional_data.gd")
const Page = preload("res://addons/feng-magic-gi/feng_magic_gi_page.gd")
const Manifest = preload("res://addons/feng-magic-gi/feng_magic_gi_manifest.gd")
const Streamer = preload("res://addons/feng-magic-gi/feng_magic_gi_page_streamer.gd")
const Runtime = preload("res://addons/feng-magic-gi/feng_magic_gi_runtime.gd")
const Volume = preload("res://addons/feng-magic-gi/feng_magic_gi_volume.gd")
const Viz = preload("res://addons/feng-magic-gi/feng_magic_gi_viz.gd")
const Visibility = preload("res://addons/feng-magic-gi/feng_magic_gi_visibility.gd")

var _checks := 0
var _failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var volume := Volume.new()
	volume.show_probes = false
	root.add_child(volume)
	var data := _make_data()
	_check(data.is_valid(), "synthetic page uses the production v6 Data validator")
	var page := Page.new()
	page.generation = "stream-test-generation"
	page.page_key = "0,0/0,0,0"
	page.core_bounds = AABB(Vector3.ZERO, Vector3.ONE)
	page.support_bounds = page.core_bounds.grow(0.5)
	page.probe_count = data.probe_count()
	page.gpu_bytes = data.estimate_gpu_bytes()
	page.cpu_bytes = data.estimate_cpu_bytes() + page.gpu_bytes
	page.data = data
	_check(page.is_valid(page.generation, page.page_key), "page wrapper validates bounds, version, and memory metadata")

	var output := "user://magic_gi_streamer_test_%d" % Time.get_ticks_usec()
	var absolute_output := ProjectSettings.globalize_path(output)
	_check(DirAccess.make_dir_recursive_absolute(absolute_output) == OK,
		"test page output is isolated in the test project's user directory")
	var page_path := output.path_join("page.res")
	page.cpu_bytes = 20 * 1024 * 1024
	page.gpu_bytes = 40 * 1024 * 1024
	var save_error := ResourceSaver.save(page, page_path, ResourceSaver.FLAG_COMPRESS)
	_check(save_error == OK, "page wrapper and Data payload save as an immutable resource")
	var content_hash := FileAccess.get_sha256(ProjectSettings.globalize_path(page_path))
	_check(not content_hash.is_empty(), "page content hash is available before manifest publication")
	var second_page := Page.new()
	second_page.generation = page.generation
	second_page.page_key = "0,0/1,0,0"
	second_page.core_bounds = AABB(Vector3(1.0, 0.0, 0.0), Vector3.ONE)
	second_page.support_bounds = second_page.core_bounds.grow(0.5)
	second_page.probe_count = data.probe_count()
	second_page.gpu_bytes = page.gpu_bytes
	second_page.cpu_bytes = page.cpu_bytes
	second_page.data = data
	var second_path := output.path_join("page_second.res")
	_check(ResourceSaver.save(second_page, second_path, ResourceSaver.FLAG_COMPRESS) == OK,
		"a second nearby immutable page is available for residency-pressure checks")
	var second_hash := FileAccess.get_sha256(ProjectSettings.globalize_path(second_path))
	var manifest := Manifest.new()
	manifest.manifest_key = output.path_join("manifest.res")
	manifest.generation = page.generation
	manifest.world_bounds = AABB(Vector3.ZERO, Vector3(2.0, 1.0, 1.0))
	manifest.management_block_size = 512.0
	manifest.page_core_size = 32.0
	manifest.configure([{
		"page_key": page.page_key,
		"page_generation": page.generation,
		"core_bounds": page.core_bounds,
		"support_bounds": page.support_bounds,
		"influence_bounds": page.support_bounds.grow(1.0),
		"probe_count": page.probe_count,
		"cpu_bytes": page.cpu_bytes,
		"gpu_bytes": page.gpu_bytes,
		"version": data.bake_version,
		"resource_path": page_path,
		"content_hash": content_hash,
		"empty": false,
	}, {
		"page_key": second_page.page_key,
		"page_generation": second_page.generation,
		"core_bounds": second_page.core_bounds,
		"support_bounds": second_page.support_bounds,
		"influence_bounds": second_page.support_bounds.grow(1.0),
		"probe_count": second_page.probe_count,
		"cpu_bytes": second_page.cpu_bytes,
		"gpu_bytes": second_page.gpu_bytes,
		"version": data.bake_version,
		"resource_path": second_path,
		"content_hash": second_hash,
		"empty": false,
	}])
	_check(manifest.is_valid(), "manifest indexes the saved page without embedding it")

	volume.bake_manifest = manifest
	var streamer := Streamer.new()
	streamer.set_manifest(manifest)
	var requested_bounds := AABB(Vector3(0.0, 0.0, 0.0), Vector3(2.0, 1.0, 1.0))
	streamer.request_view(101, 0, Vector3(0.5, 0.5, 0.5), requested_bounds, Time.get_ticks_msec())
	streamer.refresh(volume, Time.get_ticks_msec())
	_check(streamer.has_active_pages() and streamer.pending_pages().size() == 2,
		"both requested nonempty cores are explicitly pending while their resources load")
	_check(streamer.ready_pages(PackedFloat32Array(), PackedFloat32Array()).is_empty(),
		"a page is not published before worker validation and packing complete")
	var ready := false
	var started := Time.get_ticks_msec()
	for frame in 600:
		var frame_time := Time.get_ticks_msec()
		streamer.request_view(101, 0, Vector3(0.5, 0.5, 0.5), requested_bounds, frame_time)
		streamer.refresh(volume, frame_time)
		if streamer.ready_pages(PackedFloat32Array(), PackedFloat32Array()).size() == 2:
			ready = true
			break
		if Time.get_ticks_msec() - started > 15000:
			break
		await process_frame
	_check(ready, "bounded async load and worker packing eventually publish both ready pages")
	var failure_status := streamer.status()
	var failure_pending := streamer.pending_pages()
	if not ready:
		print("STREAMER_FAILURE status=", failure_status, " pending=", failure_pending)
	if ready:
		var descriptor: Dictionary = streamer.ready_pages(PackedFloat32Array(), PackedFloat32Array())[0]
		var upload: Dictionary = descriptor.get("render_upload", {})
		_check(descriptor.get("data") is Data and int(descriptor.get("version", 0)) == data.bake_version,
			"ready descriptor carries the immutable Data and stable bake version")
		_check(String(descriptor.get("identity", "")).contains(page.generation)
			and int(descriptor.get("revision", -1)) == data.bake_version,
			"page cache identity and revision exclude dynamic emission revisions")
		_check(upload.get("directional_transfer_bytes", PackedByteArray()).size() == 243 * 4
			and upload.get("directional_sky_bytes", PackedByteArray()).size() == 81 * 4
			and upload.get("normal_bytes", PackedByteArray()).size() == 16,
			"prepacked directional arrays and float4 normals are ready before RenderingDevice upload")
		_check(descriptor.get("emission_image") is Image
			and descriptor.emission_image.get_size() == Vector2i(32, 1)
			and int(descriptor.get("emission_revision", -1)) > 0,
			"dynamic emission starts with a stable atlas extent and independent revision")
		_check(streamer.pending_pages().is_empty() and streamer.resident_cpu_bytes() <= volume.cpu_resident_budget_bytes
			and streamer.resident_gpu_bytes() <= volume.gpu_resident_budget_bytes,
			"published residency respects page and aggregate CPU/GPU budgets")
		volume.cpu_resident_budget_mib = 32
		volume.gpu_resident_budget_mib = 64
		streamer.request_view(101, 0, Vector3(0.5, 0.5, 0.5), requested_bounds, Time.get_ticks_msec())
		streamer.refresh(volume, Time.get_ticks_msec())
		var budget_ready := streamer.ready_pages(PackedFloat32Array(), PackedFloat32Array())
		var budget_pending := streamer.pending_page_keys()
		_check(budget_ready.size() == 1 and String(budget_ready[0].page_key) == page.page_key
			and budget_pending.has(second_page.page_key),
			"shrinking budgets evicts the farther page, retains nearby residency, and reports backpressure")
		var pressure_status := streamer.status()
		_check(int(pressure_status.get("cpu_committed_bytes", 0)) <= volume.cpu_resident_budget_bytes
			and int(pressure_status.get("gpu_committed_bytes", 0)) <= volume.gpu_resident_budget_bytes,
			"resident plus in-flight/prepared/emission memory is reported inside the reduced budget")
		var preview_volume := Volume.new()
		preview_volume.show_probes = true
		root.add_child(preview_volume)
		var preview_snapshot := {
			"streamed": true,
			"data_valid": true,
			"current_available": false,
			"pages": [descriptor],
			"page_layout_key": "stream-test-generation/page-0",
			"total_pages": 4,
			"streaming_status": {"resident_pages": 1, "loading_pages": 2},
		}
		var preview_root := Viz.build(preview_volume, preview_snapshot)
		var preview_probes := preview_root.get_node_or_null("_Probes") as MultiMeshInstance3D
		var stream_label := preview_root.get_node_or_null("_StreamStatus") as Label3D
		_check(preview_probes != null and preview_probes.multimesh.instance_count == data.probe_count(),
			"streamed preview draws only resident page probes")
		_check(stream_label != null and stream_label.text.contains("1 / 4")
			and stream_label.text.contains("loading 2"),
			"streamed preview reports total, resident, and loading page counts")
		preview_root.free()
		preview_volume.free()
		_check(_check_runtime_snapshot_contract(volume),
			"runtime publishes streamed page metadata and budget aliases")
	streamer.deactivate()
	_check(streamer.ready_pages(PackedFloat32Array(), PackedFloat32Array()).is_empty()
			and streamer.resident_page_count() == 0,
		"inactive views release CPU page residency")
	var retired_streamer := Streamer.new()
	retired_streamer.set_manifest(manifest)
	retired_streamer.request_view(202, 0, Vector3(0.5, 0.5, 0.5), requested_bounds, Time.get_ticks_msec())
	retired_streamer.refresh(volume, Time.get_ticks_msec())
	_check(retired_streamer.inflight_count() > 0,
		"retirement fixture starts a real asynchronous page load")
	var delayed_task := WorkerThreadPool.add_task(Callable(self, "_retirement_delay"), false,
		"Magic GI retirement test")
	retired_streamer._emission_tasks[delayed_task] = {"transient_cpu_bytes": 64}
	Runtime._retire_streamer(retired_streamer)
	var was_queued := Runtime._retired_streamers.has(retired_streamer)
	var drained := retired_streamer.is_drained()
	for frame in 30:
		if not Runtime._retired_streamers.has(retired_streamer):
			drained = retired_streamer.is_drained()
			break
		await create_timer(0.025).timeout
	_check(was_queued and drained and not Runtime._retired_streamers.has(retired_streamer),
		"unregistered streamers keep loading handles until completed jobs and ResourceLoader results drain")
	volume.free()
	print("MAGIC_GI_PAGE_STREAMER checks=%d failures=%d elapsed_ms=%d" % [
		_checks, _failures, Time.get_ticks_msec() - started if ready else -1])
	quit(1 if _failures > 0 else 0)

func _make_data() -> FMagicGIData:
	var data: FMagicGIData = Data.new()
	data.format_version = Data.FORMAT_VERSION
	data.grid_dims = Vector3i.ONE
	data.volume_transform = Transform3D.IDENTITY
	data.world_to_grid = Transform3D.IDENTITY
	data.volume_size = Vector3.ONE
	data.spacing = 1.0
	data.adaptive_placement = false
	data.surface_offset = 0.03
	data.bake_samples = 1
	data.bake_bounces = 1
	data.bake_distance = 1.0
	data.terrain_reflectance = 0.5
	data.material_reflectance = 0.5
	data.bake_version = 1
	data.positions = PackedVector3Array([Vector3(0.5, 0.53, 0.5)])
	data.surface_positions = PackedVector3Array([Vector3(0.5, 0.5, 0.5)])
	data.normals = PackedVector3Array([Vector3.UP])
	data.transfer.resize(27)
	data.transfer.fill(0.0)
	data.primary_sky_visibility.resize(9)
	data.primary_sky_visibility.fill(0.0)
	data.visibility_moments.resize(Data.VISIBILITY_TEXELS_PER_PROBE * Data.VISIBILITY_MOMENT_CHANNELS)
	data.visibility_moments.fill(0.0)
	data.directional = DirectionalData.new()
	data.directional.allocate(1, 0)
	var visibility := Visibility.build(PackedVector3Array([
		Vector3(-1, 0, -1), Vector3(1, 0, -1), Vector3(0, 0, 1)]))
	data.visibility_nodes = visibility.nodes
	data.visibility_triangles = visibility.triangles
	data.build_cell_indices()
	return data

func _check_runtime_snapshot_contract(volume: FMagicGIVolume) -> bool:
	Runtime.publish(volume)
	Runtime._publish()
	for snapshot in Runtime.snapshots():
		if int(snapshot.get("volume_id", -1)) != volume.get_instance_id():
			continue
		var budget: Dictionary = snapshot.get("streaming_budget", {})
		var has_contract: bool = bool(snapshot.get("streamed", false)) \
				and snapshot.get("manifest") == volume.bake_manifest \
				and snapshot.has("pages") and snapshot.has("pending_pages") \
				and snapshot.has("pending_page_keys") \
				and snapshot.get("owner_transform", Transform3D.IDENTITY).is_finite() \
				and snapshot.get("owner_size", Vector3.ZERO) == volume.size \
				and budget.get("gpu_bytes", 0) == budget.get("gpu_resident_bytes", -1) \
				and budget.get("upload_bytes_per_frame", 0) > 0 \
				and budget.get("max_inflight", 0) > 0
		return has_contract
	return false

func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: " + message)
	else:
		_failures += 1
		push_error("FAIL: " + message)

func _retirement_delay() -> void:
	OS.delay_msec(120)
