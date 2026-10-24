extends SceneTree
## GPU acceptance harness for the actual white-box project scene.
## It never saves the scene or changes its authored lights/eye adaptation.

const SCENE_PATH := "res://box_test.tscn"
const OUTPUT_DIR := "res://captures/magicdawn_clv_prt_contract_20261023"
const GI_DEBUG_BUFFER := 6
const WARMUP_FRAMES := 180
const MAX_SPATIAL_FILL_FRAMES := 900
const IDLE_CHECK_FRAMES := 90
const EXPECTED_RESIDENT_CELLS := 3 * 16 * 16 * 16
const EXPECTED_RESIDENT_FACES := EXPECTED_RESIDENT_CELLS * 3
const DirectionalData = preload("res://addons/feng-magic-gi/feng_magic_gi_directional_data.gd")
const ProjectPipeline = preload("res://addons/feng-render-pipeline/project_pipeline.gd")

var checks := 0
var failures := 0
var scene: Node
var volume: Node
var camera: Camera3D
var sun: DirectionalLight3D
var sky_light: Node
var magic_pass: Resource
var debug_pass: Resource
var eye_pass: Resource
var original_camera_transform := Transform3D.IDENTITY
var original_sun_transform := Transform3D.IDENTITY
var original_sky_energy := 1.0
var original_debug_enabled := false
var original_debug_buffer := 0
var original_debug_display_mode := 0
var original_debug_exposure := 0.0
var original_profile_enabled := false
var restore_needed := false

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	get_root().size = Vector2i(1920, 1080)
	var report := {"scene": SCENE_PATH, "output_dir": OUTPUT_DIR,
		"eye_adaptation_modified": false, "scene_saved": false}
	if RenderingServer.get_current_rendering_method() != "frp":
		_check(false, "The actual acceptance scene must run with the FRP rendering method.")
		_finish(report, 2)
		return
	var compositor := ProjectPipeline.resolve()
	if compositor == null:
		_check(false, "ProjectPipeline.resolve() returned no compositor for the active FRP project.")
		_finish(report, 2)
		return
	var renderer: Resource = compositor.get("renderer") as Resource
	if renderer == null:
		_check(false, "The configured project compositor has no renderer resource.")
		_finish(report, 2)
		return
	var pass_list: Variant = renderer.get("passes")
	if not pass_list is Array:
		_check(false, "The configured renderer does not expose its authored pass list.")
		_finish(report, 2)
		return
	for pass_value in pass_list:
		if not pass_value is Resource:
			continue
		var pass_resource := pass_value as Resource
		match String(pass_resource.get("stable_id")):
			"library:magic_gi": magic_pass = pass_resource
			"library:debug_buffers": debug_pass = pass_resource
			"library:eye_adaptation": eye_pass = pass_resource
	if magic_pass == null or debug_pass == null or eye_pass == null:
		_check(false, "Configured renderer must contain Magic GI, Debug Buffers, and Eye Adaptation passes.")
		_finish(report, 2)
		return
	var packed := ResourceLoader.load(SCENE_PATH) as PackedScene
	if packed == null:
		_check(false, "Could not load the authored box_test.tscn main scene.")
		_finish(report, 2)
		return
	scene = packed.instantiate()
	if scene == null:
		_check(false, "Could not instantiate box_test.tscn.")
		_finish(report, 2)
		return
	get_root().add_child(scene)
	current_scene = scene
	volume = scene.find_child("MagicGIVolume", true, false)
	camera = scene.find_child("Camera3D", true, false) as Camera3D
	sun = scene.find_child("AtmosphereSun", true, false) as DirectionalLight3D
	sky_light = scene.find_child("SkyLight", true, false)
	if volume == null or camera == null or sun == null or sky_light == null:
		_check(false, "Authored scene is missing MagicGIVolume, Camera3D, AtmosphereSun, or SkyLight.")
		_finish(report, 2)
		return
	if not camera.current:
		_check(false, "The authored main-scene Camera3D is not current.")
		_finish(report, 2)
		return
	original_camera_transform = camera.global_transform
	original_sun_transform = sun.global_transform
	original_sky_energy = float(sky_light.get("radiance_energy"))
	original_debug_enabled = bool(debug_pass.get("enabled"))
	original_debug_buffer = int(debug_pass.get("buffer"))
	original_debug_display_mode = int(debug_pass.get("gi_display_mode"))
	original_debug_exposure = float(debug_pass.get("gi_exposure"))
	original_profile_enabled = bool(magic_pass.get("gpu_timestamp_profiling_enabled"))
	restore_needed = true
	var bake_data: Resource = volume.get("bake_data") as Resource
	var probe_count := int(bake_data.call("probe_count")) if bake_data != null else 0
	var source_count := int(bake_data.call("emitter_count")) if bake_data != null else 0
	var directional: Resource = bake_data.get("directional") if bake_data != null else null
	var transfer_valid := directional is DirectionalData \
			and bool((directional as DirectionalData).call("is_valid", probe_count, source_count))
	_check(int(volume.get("clv_cache_backend")) == 1,
		"Serialized backend 1 must remain selected for the main project scene.")
	_check(bool(volume.get("use_clv")) and is_equal_approx(float(volume.get("clv_cell_size")), 0.25),
		"The authored CLV cache must be enabled at the required 0.25 m spacing.")
	_check(transfer_valid,
		"Backend 1 requires a valid revision-1 data.directional TransferMatrix; baked_indirect_sh is not a substitute.")
	_check(bool(magic_pass.get("enabled")), "The authored Magic GI pass must be enabled.")
	_check(bool(magic_pass.get("native_clv_lighting_enabled")),
		"The saved renderer resource must enable the native layout9 CLV lighting path.")
	_check(int(magic_pass.get("_clv_internal_test_layout")) == 0,
		"The real project must use the authored production CLV layout, not a test-only layout override.")
	var configured_world_envs: Array[String] = []
	for node_value in get_root().find_children("*", "WorldEnvironment", true, false):
		var environment := node_value as WorldEnvironment
		if environment != null and environment.compositor == compositor:
			configured_world_envs.append(str(environment.get_path()))
	_check(not configured_world_envs.is_empty(),
		"The configured project compositor must be installed in the rendered world.")
	var initial_native_state: Dictionary = magic_pass.call("get_native_clv_lighting_state") \
			if magic_pass.has_method("get_native_clv_lighting_state") else {}
	report["authored_configuration"] = {
		"rendering_method": RenderingServer.get_current_rendering_method(),
		"compositor": compositor.resource_path,
		"world_environments": configured_world_envs,
		"backend": volume.get("clv_cache_backend"),
		"use_clv": volume.get("use_clv"),
		"clv_cell_size_m": volume.get("clv_cell_size"),
		"bake_path": bake_data.resource_path if bake_data != null else "",
		"probe_count": probe_count,
		"directional_revision": directional.get("revision") if directional != null else -1,
		"directional_transfer_valid": transfer_valid,
		"native_clv_lighting_enabled": magic_pass.get("native_clv_lighting_enabled"),
		"native_state_before_warmup": initial_native_state,
		"camera_pose_authored": camera.global_transform,
		"sun_rotation_authored": sun.global_rotation,
		"sky_radiance_energy_authored": original_sky_energy,
		"eye_adaptation_enabled": bool(eye_pass.call("is_enabled"))}
	_check(bool(eye_pass.call("is_enabled")), "Eye Adaptation must stay enabled during this runtime acceptance.")
	# The debug buffer isolates the final Magic GI contribution. Its output setting
	# is restored before exit; no lighting or exposure setting is changed.
	debug_pass.set("buffer", GI_DEBUG_BUFFER)
	debug_pass.set("gi_display_mode", 0)
	debug_pass.set("gi_exposure", 0.0)
	debug_pass.set("enabled", true)
	await _wait_frames(WARMUP_FRAMES)
	var baseline_state := _runtime_state()
	var baseline := _capture("01_baseline_magic_gi.png")
	var baseline_summary := _image_summary(baseline)
	report["baseline"] = {"state": baseline_state, "image": baseline_summary}
	_check(_state_is_resident_relight_complete(baseline_state),
		"The runtime must report a completed dispatch for every resident CLV face before dynamic checks.")
	_check(bool(baseline_summary.get("visible", false)),
		"The Magic GI debug viewport must show visible output from the authored box camera.")

	var original_rotation := sun.global_transform
	var before_light := baseline_state.duplicate(true)
	sun.global_rotation = sun.global_rotation + Vector3(0.0, 0.55, 0.0)
	var light_relight := await _wait_for_resident_relight(before_light)
	var light_image_next_frame := _capture("02_sun_direction_next_frame.png")
	var light_next_frame_delta := _image_delta(baseline, light_image_next_frame)
	await _wait_frames(120) # Let the enabled Eye Adaptation path settle before image comparison.
	var light_image := _capture("03_sun_direction_eye_adapted.png")
	var light_delta := _image_delta(baseline, light_image)
	var light_state := _runtime_state()
	var light_visual_changed := _image_changed(light_delta)
	var light_update_observed := int(light_state.get("lighting_revision", 0)) \
			> int(before_light.get("lighting_revision", 0)) \
			and int(light_state.get("relight_serial", 0)) \
			> int(before_light.get("relight_serial", 0))
	report["sun_direction_change"] = {"resident_relight": light_relight,
		"viewport_capture_after_relight_frames": 1,
		"next_frame_image": _image_summary(light_image_next_frame),
		"next_frame_delta": light_next_frame_delta,
		"visual_delta": light_delta, "runtime_state": light_state,
		"changed_image": light_visual_changed, "lighting_update": light_update_observed}
	_check(bool(light_relight.get("next_prepare_completed", false)) and light_update_observed,
		"A sun-direction change must relight every resident CLV face in the next prepare, without spreading lighting work across later frames.")
	_check(light_visual_changed,
		"The Magic GI contribution image must change after the sun direction changes.")
	_check(_image_changed(light_next_frame_delta),
		"The next rendered frame after the resident relight dispatch must already show its changed GI contribution.")
	sun.global_transform = original_rotation
	var restored_sun_relight := await _wait_for_resident_relight(light_state)
	await _wait_frames(120)
	var restored_sun_image := _capture("03_sun_direction_restored.png")
	var sun_restore_delta := _image_delta(baseline, restored_sun_image)
	_check(not _image_changed(sun_restore_delta),
		"Restoring the authored sun orientation must restore the baseline Magic GI output.")
	var restored_sun_state := _runtime_state()
	var before_sky := restored_sun_state.duplicate(true)
	sky_light.set("radiance_energy", original_sky_energy * 1.6 + 0.1)
	var sky_relight := await _wait_for_resident_relight(before_sky)
	var sky_image_next_frame := _capture("05_sky_radiance_next_frame.png")
	var sky_next_frame_delta := _image_delta(restored_sun_image, sky_image_next_frame)
	await _wait_frames(120)
	var sky_image := _capture("06_sky_radiance_eye_adapted.png")
	var sky_delta := _image_delta(restored_sun_image, sky_image)
	var sky_state := _runtime_state()
	var sky_visual_changed := _image_changed(sky_delta)
	var sky_update_observed := int(sky_state.get("lighting_revision", 0)) \
			> int(before_sky.get("lighting_revision", 0)) \
			and int(sky_state.get("relight_serial", 0)) \
			> int(before_sky.get("relight_serial", 0))
	report["sky_radiance_change"] = {"resident_relight": sky_relight,
		"viewport_capture_after_relight_frames": 1,
		"next_frame_image": _image_summary(sky_image_next_frame),
		"next_frame_delta": sky_next_frame_delta,
		"visual_delta": sky_delta, "runtime_state": sky_state,
		"changed_image": sky_visual_changed, "lighting_update": sky_update_observed}
	_check(bool(sky_relight.get("next_prepare_completed", false)) and sky_update_observed,
		"A Sky radiance/TOD input change must relight every resident CLV face in the next prepare.")
	_check(sky_visual_changed,
		"The Magic GI contribution image must change after FengSkyLight radiance changes.")
	_check(_image_changed(sky_next_frame_delta),
		"The next rendered frame after a Sky relight dispatch must show its changed GI contribution.")
	sky_light.set("radiance_energy", original_sky_energy)
	var restored_sky_relight := await _wait_for_resident_relight(sky_state)
	await _wait_frames(120)
	var restored_inputs_image := _capture("07_all_lighting_inputs_restored.png")
	var restored_inputs_delta := _image_delta(baseline, restored_inputs_image)
	_check(not _image_changed(restored_inputs_delta),
		"Restoring sun and Sky inputs must restore the baseline Magic GI output.")

	var idle_start := _runtime_state()
	await _wait_frames(IDLE_CHECK_FRAMES)
	var idle_end := _runtime_state()
	var idle_stable := int(idle_start.get("relight_serial", -1)) \
			== int(idle_end.get("relight_serial", -2)) \
			and int(idle_start.get("lighting_revision", -1)) \
			== int(idle_end.get("lighting_revision", -2)) \
			and not bool(idle_end.get("relight_pending", true)) \
			and not bool(idle_end.get("relight_scheduled_and_dispatched", true))
	report["restoration"] = {"sun_delta": sun_restore_delta,
		"all_inputs_delta": restored_inputs_delta,
		"image_capture_after_restore_frames": 120,
		"sun_relight": restored_sun_relight,
		"sky_relight": restored_sky_relight}
	report["steady_state"] = {"frames": IDLE_CHECK_FRAMES,
		"before": idle_start, "after": idle_end, "no_redundant_relight": idle_stable}
	_check(idle_stable,
		"Once current lighting converges, stationary frames must not dispatch redundant relight work.")

	var before_camera := idle_end.duplicate(true)
	camera.global_position += Vector3(0.5, 0.0, 0.0)
	var camera_convergence := await _wait_for_spatial_fill(before_camera)
	var camera_state := _runtime_state()
	report["camera_move"] = {"convergence": camera_convergence,
		"runtime_state": camera_state, "camera_position": camera.global_position}
	_check(bool(camera_convergence.get("fill_completed", false))
			and int(camera_state.get("relight_serial", 0)) == int(before_camera.get("relight_serial", 0)),
		"Moving the camera must queue and complete new spatial blocks separately, without a redundant lighting relight.")
	camera.global_transform = original_camera_transform
	var camera_restore := await _wait_for_spatial_fill(camera_state)
	report["camera_restore"] = camera_restore

	var final_state := _runtime_state()
	report["final_runtime_state"] = final_state
	report["final_camera_pose"] = camera.global_transform
	_check(_state_is_resident_relight_complete(final_state), "Restored scene inputs must finish resident relight before the timing capture.")
	var gpu_report := await _capture_gpu_timing()
	report["gpu_timing"] = gpu_report
	_check(int(gpu_report.get("unique_timestamp_frames", 0)) > 0,
		"The profiled Magic GI frame must yield readable RenderingDevice timestamps.")
	# Native Prepare includes the disjoint cache-production/relight/CLV intervals;
	# deferred lighting is a full PBR draw and is intentionally reported separately.
	# It must not be relabeled as GI-only time, since RD timestamps cannot isolate a
	# fragment subroutine inside that fused draw.
	report["total_gi_budget"] = {"target_ms": 0.5,
		"native_prepare_p95_ms": gpu_report.get("native_prepare_p95_ms", -1.0),
		"deferred_pbr_p95_ms_not_gi_only": gpu_report.get("deferred_pbr_p95_ms", -1.0),
		"conclusive_pixel_gi_cost": false,
		"note": "Native CLV pixel sampling is fused into the deferred PBR draw; that marker is not a GI-only measurement."}
	_finish(report, 0 if failures == 0 else 1)

func _runtime_state() -> Dictionary:
	if magic_pass == null or not magic_pass.has_method("get_magicdawn_runtime_state"):
		return {"status": "magicdawn_runtime_state_unavailable"}
	return magic_pass.call("get_magicdawn_runtime_state")

func _state_has_dispatched_clv(state: Dictionary) -> bool:
	return String(state.get("prt_model", "")) == "CLV_BLOCK_RELIGHT" \
			and String(state.get("sh_basis", "")).begins_with("real_orthonormal_degree2_coefficients9") \
			and int(state.get("source_probe_count", 0)) > 0 \
			and int(state.get("relight_serial", 0)) > 0

func _state_is_resident_relight_complete(state: Dictionary) -> bool:
	return _state_has_dispatched_clv(state) \
			and int(state.get("relight_lighting_revision", -1)) \
			>= int(state.get("lighting_revision", 0)) \
			and int(state.get("last_relight_cells", 0)) == EXPECTED_RESIDENT_CELLS \
			and int(state.get("last_relight_faces", 0)) == EXPECTED_RESIDENT_FACES \
			and not bool(state.get("relight_pending", true))

func _wait_for_resident_relight(previous: Dictionary) -> Dictionary:
	var old_revision := int(previous.get("lighting_revision", 0))
	var old_serial := int(previous.get("relight_serial", 0))
	var start_frame := Engine.get_process_frames()
	await RenderingServer.frame_post_draw
	var state := _runtime_state()
	var frames := Engine.get_process_frames() - start_frame
	var revision_advanced := int(state.get("lighting_revision", 0)) == old_revision + 1
	var serial_advanced := int(state.get("relight_serial", 0)) == old_serial + 1
	var dispatched_this_prepare := bool(state.get("relight_scheduled_and_dispatched", false))
	var resident_complete := int(state.get("last_relight_cells", 0)) == EXPECTED_RESIDENT_CELLS \
			and int(state.get("last_relight_faces", 0)) == EXPECTED_RESIDENT_FACES
	var revision_complete := int(state.get("relight_lighting_revision", -1)) \
			>= int(state.get("lighting_revision", 0))
	var pending := bool(state.get("relight_pending", true))
	return {"next_prepare_completed": revision_advanced and serial_advanced \
			and dispatched_this_prepare and resident_complete and revision_complete and not pending,
		"dispatch_frames_after_input": frames,
		"lighting_revision_advanced_once": revision_advanced,
		"relight_serial_advanced_once": serial_advanced,
		"dispatch_confirmed_this_prepare": dispatched_this_prepare,
		"resident_cells": state.get("last_relight_cells", 0),
		"resident_faces": state.get("last_relight_faces", 0),
		"expected_resident_cells": EXPECTED_RESIDENT_CELLS,
		"expected_resident_faces": EXPECTED_RESIDENT_FACES,
		"relight_lighting_revision": state.get("relight_lighting_revision", -1),
		"relight_pending": pending,
		"relight_scheduled_and_dispatched": state.get("relight_scheduled_and_dispatched", false),
		"last_relight_frame": state.get("last_relight_frame", -1), "state": state}

func _wait_for_spatial_fill(previous: Dictionary) -> Dictionary:
	var old_serial := int(previous.get("dispatch_serial", 0))
	var saw_geometry_dispatch := false
	var saw_geometry_queue := false
	for frame_index in MAX_SPATIAL_FILL_FRAMES:
		await RenderingServer.frame_post_draw
		var state := _runtime_state()
		var queued := int(state.get("geometry_pending_blocks", state.get("pending_blocks", 0)))
		if queued > 0:
			saw_geometry_queue = true
		if int(state.get("dispatch_serial", 0)) > old_serial \
				and int(state.get("last_dispatch_blocks", 0)) > 0:
			saw_geometry_dispatch = true
		if saw_geometry_dispatch and queued == 0:
			return {"fill_completed": true, "frames": frame_index + 1,
				"saw_geometry_queue": saw_geometry_queue,
				"dispatch_serial": state.get("dispatch_serial", -1),
				"last_dispatch_blocks": state.get("last_dispatch_blocks", 0),
				"geometry_pending_blocks": queued, "state": state}
	return {"fill_completed": false, "frames": MAX_SPATIAL_FILL_FRAMES,
		"saw_geometry_queue": saw_geometry_queue, "state": _runtime_state()}

func _capture_gpu_timing() -> Dictionary:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		return {"available": false, "error": "no_rendering_device"}
	magic_pass.set("gpu_timestamp_profiling_enabled", true)
	var samples: Array[Dictionary] = []
	var seen_frames: Dictionary = {}
	var start_usec := Time.get_ticks_usec()
	while Time.get_ticks_usec() - start_usec < 12000000 and samples.size() < 90:
		await RenderingServer.frame_post_draw
		var frame_id := int(rd.get_captured_timestamps_frame())
		if frame_id < 0 or seen_frames.has(frame_id):
			continue
		seen_frames[frame_id] = true
		var events: Array[Dictionary] = []
		for index in int(rd.get_captured_timestamps_count()):
			events.append({"name": rd.get_captured_timestamp_name(index),
				"gpu_ns": int(rd.get_captured_timestamp_gpu_time(index))})
		var prepare_ns := _timestamp_pair_ns(events,
			"Magic GI Pass Native Prepare Begin", "Magic GI Pass Native Prepare End")
		var deferred_ns := _timestamp_pair_ns(events,
			"Magic GI Deferred Lighting Begin", "Magic GI Deferred Lighting End")
		if prepare_ns >= 0 or deferred_ns >= 0:
			samples.append({"frame": frame_id, "native_prepare_ns": prepare_ns,
				"deferred_pbr_ns": deferred_ns, "events": events})
	magic_pass.set("gpu_timestamp_profiling_enabled", original_profile_enabled)
	await RenderingServer.frame_post_draw
	return {"available": not samples.is_empty(),
		"unique_timestamp_frames": seen_frames.size(),
		"sample_count": samples.size(),
		"native_prepare_p95_ms": _percentile_ms(samples, "native_prepare_ns", 0.95),
		"deferred_pbr_p95_ms": _percentile_ms(samples, "deferred_pbr_ns", 0.95),
		"samples": samples}

func _timestamp_pair_ns(events: Array[Dictionary], begin_name: String, end_name: String) -> int:
	var begin_ns := -1
	for event in events:
		var name := String(event.get("name", ""))
		var stamp := int(event.get("gpu_ns", -1))
		if begin_ns < 0 and name == begin_name:
			begin_ns = stamp
		elif begin_ns >= 0 and name == end_name and stamp >= begin_ns:
			return stamp - begin_ns
	return -1

func _percentile_ms(samples: Array[Dictionary], key: String, percentile: float) -> float:
	var values: Array[float] = []
	for sample in samples:
		var value := int(sample.get(key, -1))
		if value >= 0:
			values.append(float(value))
	if values.is_empty():
		return -1.0
	values.sort()
	var index := clampi(int(ceil(float(values.size()) * percentile)) - 1, 0, values.size() - 1)
	return values[index] / 1000000.0

func _capture(name: String) -> Image:
	var absolute_dir := ProjectSettings.globalize_path(OUTPUT_DIR)
	DirAccess.make_dir_recursive_absolute(absolute_dir)
	var image := get_root().get_viewport().get_texture().get_image()
	if image == null or image.is_empty():
		_check(false, "Viewport capture returned an empty image: " + name)
		return Image.new()
	var path := OUTPUT_DIR.path_join(name)
	var err := image.save_png(ProjectSettings.globalize_path(path))
	_check(err == OK, "Could not save capture %s: %s" % [path, error_string(err)])
	print("[MAGICDAWN_CLV_PRT] IMAGE path=", path, " size=", image.get_size(),
		" result=", error_string(err) if err != OK else "OK")
	return image

func _image_summary(image: Image) -> Dictionary:
	if image == null or image.is_empty():
		return {"valid": false, "visible": false}
	var step_x := maxi(1, image.get_width() / 64)
	var step_y := maxi(1, image.get_height() / 36)
	var count := 0
	var visible_count := 0
	var total_luma := 0.0
	for y in range(0, image.get_height(), step_y):
		for x in range(0, image.get_width(), step_x):
			var c := image.get_pixel(x, y)
			var luma := c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722
			total_luma += luma
			if luma > 0.025:
				visible_count += 1
			count += 1
	return {"valid": true, "size": image.get_size(),
		"mean_luma": total_luma / maxf(1.0, float(count)),
		"visible_fraction": float(visible_count) / maxf(1.0, float(count)),
		"visible": visible_count > count / 100}

func _image_delta(first: Image, second: Image) -> Dictionary:
	if first == null or second == null or first.is_empty() or second.is_empty() \
			or first.get_size() != second.get_size():
		return {"valid": false, "mean_abs_rgb": INF, "fraction_gt_0_01": 0.0}
	var step_x := maxi(1, first.get_width() / 64)
	var step_y := maxi(1, first.get_height() / 36)
	var sum_delta := 0.0
	var changed := 0
	var count := 0
	for y in range(0, first.get_height(), step_y):
		for x in range(0, first.get_width(), step_x):
			var a := first.get_pixel(x, y)
			var b := second.get_pixel(x, y)
			var delta := (absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)) / 3.0
			sum_delta += delta
			if delta > 0.01:
				changed += 1
			count += 1
	return {"valid": true, "samples": count,
		"mean_abs_rgb": sum_delta / maxf(1.0, float(count)),
		"fraction_gt_0_01": float(changed) / maxf(1.0, float(count))}

func _image_changed(delta: Dictionary) -> bool:
	return bool(delta.get("valid", false)) \
			and float(delta.get("mean_abs_rgb", 0.0)) > 0.003 \
			and float(delta.get("fraction_gt_0_01", 0.0)) > 0.01

func _wait_frames(count: int) -> void:
	for _index in count:
		await RenderingServer.frame_post_draw

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("[MAGICDAWN_CLV_PRT] " + message)

func _restore_runtime_values() -> void:
	if not restore_needed:
		return
	if is_instance_valid(camera):
		camera.global_transform = original_camera_transform
	if is_instance_valid(sun):
		sun.global_transform = original_sun_transform
	if is_instance_valid(sky_light):
		sky_light.set("radiance_energy", original_sky_energy)
	if is_instance_valid(debug_pass):
		debug_pass.set("enabled", original_debug_enabled)
		debug_pass.set("buffer", original_debug_buffer)
		debug_pass.set("gi_display_mode", original_debug_display_mode)
		debug_pass.set("gi_exposure", original_debug_exposure)
	if is_instance_valid(magic_pass):
		magic_pass.set("gpu_timestamp_profiling_enabled", original_profile_enabled)
	restore_needed = false

func _finish(report: Dictionary, requested_exit_code: int) -> void:
	_restore_runtime_values()
	report["checks"] = checks
	report["failures"] = failures
	print("[MAGICDAWN_CLV_PRT] REPORT ", JSON.stringify(report))
	print("[MAGICDAWN_CLV_PRT] COMPLETE checks=", checks, " failures=", failures)
	quit(requested_exit_code if failures == 0 else 1)
