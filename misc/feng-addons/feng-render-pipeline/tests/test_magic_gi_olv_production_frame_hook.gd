extends SceneTree

const SCENE_PATH := "res://box_test.tscn"
const ProjectPipeline = preload("res://addons/feng-render-pipeline/project_pipeline.gd")
const MAX_FRAMES := 180

var magic_pass: Resource
var active_frames := 0
var frame_reports: Array[Dictionary] = []
var timestamp_samples: Array[Dictionary] = []
var last_report_text := ""

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var report := {"scene": SCENE_PATH, "scene_saved": false,
		"scene_resource_modified": false, "rendering_method": RenderingServer.get_current_rendering_method()}
	if RenderingServer.get_current_rendering_method() != "frp":
		_finish(report, 2, "project_is_not_using_frp")
		return
	var compositor := ProjectPipeline.resolve()
	var renderer: Resource = compositor.get("renderer") if compositor != null else null
	var passes_value: Variant = renderer.get("passes") if renderer != null else null
	if not passes_value is Array:
		_finish(report, 2, "configured_renderer_pass_list_missing")
		return
	for pass_value in passes_value:
		if pass_value is Resource and String(pass_value.get("stable_id")) == "library:magic_gi":
			magic_pass = pass_value
			break
	if magic_pass == null or not magic_pass.has_method("get_magicdawn_runtime_state"):
		_finish(report, 2, "magic_gi_pass_or_runtime_state_missing")
		return
	var packed := ResourceLoader.load(SCENE_PATH) as PackedScene
	if packed == null:
		_finish(report, 2, "box_test_scene_load_failed")
		return
	var scene := packed.instantiate()
	if scene == null:
		_finish(report, 2, "box_test_scene_instantiate_failed")
		return
	get_root().add_child(scene)
	current_scene = scene
	var camera := scene.find_child("Camera3D", true, false) as Camera3D
	var volume := scene.find_child("MagicGIVolume", true, false)
	if camera == null or volume == null or not camera.current:
		_finish(report, 2, "authored_camera_or_magic_gi_volume_missing")
		return
	var manifest: Resource = volume.get("bake_manifest") as Resource
	if manifest == null:
		_finish(report, 2, "scene_manifest_missing")
		return
	var label_set: Resource = manifest.get("prepared_olv_label_set") as Resource
	report["manifest_prepared_olv_filter_enabled"] = bool(manifest.get("prepared_olv_filter_enabled"))
	report["manifest_label_set_hash"] = String(label_set.get("labels_hash")) if label_set != null else ""
	report["manifest_label_set_valid"] = bool(label_set.call("validate").get("ok", false)) \
			if label_set != null and label_set.has_method("validate") else false
	report["profile_frames"] = MAX_FRAMES
	magic_pass.set("gpu_timestamp_profiling_enabled", true)
	for frame_index in MAX_FRAMES:
		await RenderingServer.frame_post_draw
		var state: Dictionary = magic_pass.call("get_magicdawn_runtime_state")
		var dynamic_value: Variant = state.get("dynamic_volume", {})
		var dynamic_state: Dictionary = dynamic_value if dynamic_value is Dictionary else {}
		var current := _frame_summary(frame_index, dynamic_state)
		var current_text := JSON.stringify(current, "", true, true)
		if frame_index % 15 == 0 or current_text != last_report_text:
			print("OLV_FRAME " + current_text)
			frame_reports.append(current)
		last_report_text = current_text
		if bool(current.get("olv_renderer_active", false)):
			active_frames += 1
		if frame_index >= 45:
			_capture_gpu_timestamps()
		if active_frames >= 5 and frame_index >= 75:
			break
	magic_pass.set("gpu_timestamp_profiling_enabled", false)
	var final_state: Dictionary = magic_pass.call("get_magicdawn_runtime_state")
	var final_dynamic_value: Variant = final_state.get("dynamic_volume", {})
	var final_dynamic: Dictionary = final_dynamic_value if final_dynamic_value is Dictionary else {}
	report["final_frame_state"] = _frame_summary(-1, final_dynamic)
	report["active_frame_count"] = active_frames
	report["native_prepare_timestamp_summary"] = _timestamp_summary("native_prepare_ns")
	report["deferred_pbr_timestamp_summary_not_gi_only"] = _timestamp_summary("deferred_pbr_ns")
	report["gpu_timestamp_sample_count"] = timestamp_samples.size()
	report["gpu_timestamp_samples"] = timestamp_samples
	report["resident_olv_atlas_readback"] = _read_resident_olv_atlas()
	report["runtime_state"] = final_state
	print("OLV_REPORT " + JSON.stringify(report, "", true, true))
	var active := bool(final_dynamic.get("olv_input_present", false)) \
			and bool(final_dynamic.get("olv_renderer_active", false)) \
			and int(final_dynamic.get("olv_publication_token", 0)) > 0
	quit(0 if active else 3)

func _frame_summary(frame_index: int, dynamic_state: Dictionary) -> Dictionary:
	var cache_value: Variant = dynamic_state.get("cache", {})
	var cache: Dictionary = cache_value if cache_value is Dictionary else {}
	return {"sample_frame": frame_index,
		"engine_frame": int(dynamic_state.get("olv_frame", -1)),
		"frame_token": int(dynamic_state.get("olv_frame_token", -1)),
		"publication_token": int(dynamic_state.get("olv_publication_token", 0)),
		"lease_current": bool(dynamic_state.get("lease_current", false)),
		"olv_input_present": bool(dynamic_state.get("olv_input_present", false)),
		"olv_renderer_active": bool(dynamic_state.get("olv_renderer_active", false)),
		"published_layout_version": int(dynamic_state.get("olv_layout_version", 0)),
		"dynamic_status": String(dynamic_state.get("status", "")),
		"fallback_reason": String(dynamic_state.get("fallback_reason", "")),
		"olv_requested": bool(dynamic_state.get("olv_requested", false)),
		"cache_layout_version": int(cache.get("layout_version", 0)),
		"cache_olv_enabled": bool(cache.get("olv_enabled", false)),
		"cache_olv_labels_hash": String(cache.get("olv_labels_hash", "")),
		"label_atlas_upload_count": int(cache.get("olv_atlas_upload_count", 0)),
		"label_atlas_uploaded_bytes": int(cache.get("olv_atlas_uploaded_bytes", 0)),
		"loaded_bricks": int(cache.get("loaded_bricks", 0)),
		"resident_olv_cells": int(cache.get("valid_resident_cells", 0))}

func _capture_gpu_timestamps() -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		return
	var frame_id := int(rd.get_captured_timestamps_frame())
	if frame_id < 0:
		return
	for sample in timestamp_samples:
		if int(sample.get("frame", -2)) == frame_id:
			return
	var events: Array[Dictionary] = []
	for index in int(rd.get_captured_timestamps_count()):
		events.append({"name": rd.get_captured_timestamp_name(index),
			"gpu_ns": int(rd.get_captured_timestamp_gpu_time(index))})
	var prepare_ns := _timestamp_pair_ns(events,
		"Magic GI Pass Native Prepare Begin", "Magic GI Pass Native Prepare End")
	var deferred_ns := _timestamp_pair_ns(events,
		"Magic GI Deferred Lighting Begin", "Magic GI Deferred Lighting End")
	if prepare_ns >= 0 or deferred_ns >= 0:
		timestamp_samples.append({"frame": frame_id,
			"native_prepare_ns": prepare_ns, "deferred_pbr_ns": deferred_ns})

func _timestamp_pair_ns(events: Array[Dictionary], begin_name: String, end_name: String) -> int:
	var begin_ns := -1
	for event in events:
		var name := String(event.get("name", ""))
		var value := int(event.get("gpu_ns", -1))
		if name == begin_name:
			begin_ns = value
		elif name == end_name and begin_ns >= 0 and value >= begin_ns:
			return value - begin_ns
	return -1

func _timestamp_summary(key: String) -> Dictionary:
	var values: Array[int] = []
	for sample in timestamp_samples:
		var value := int(sample.get(key, -1))
		if value >= 0:
			values.append(value)
	values.sort()
	if values.is_empty():
		return {"sample_count": 0, "median_ms": -1.0, "p95_ms": -1.0}
	return {"sample_count": values.size(),
		"median_ms": float(values[int(floor(float(values.size() - 1) * 0.50))]) / 1000000.0,
		"p95_ms": float(values[int(floor(float(values.size() - 1) * 0.95))]) / 1000000.0}

func _read_resident_olv_atlas() -> Dictionary:
	var cache_value: Variant = magic_pass.get("_dynamic_volume_cache")
	if not cache_value is Object or not cache_value.has_method("get_olv_binding"):
		return {"available": false, "reason": "production_cache_or_olv_api_missing"}
	var cache: Object = cache_value
	var binding_value: Variant = cache.call("get_olv_binding")
	if not binding_value is Dictionary:
		return {"available": false, "reason": "production_cache_binding_missing"}
	var binding: Dictionary = binding_value
	var atlas: RID = binding.get("label_atlas", RID())
	var parameters: RID = binding.get("label_parameters", RID())
	if not bool(binding.get("enabled", false)) or not atlas.is_valid() or not parameters.is_valid():
		return {"available": false, "reason": "production_olv_binding_not_enabled"}
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		return {"available": false, "reason": "main_rendering_device_missing"}
	# Main RenderingDevice readback itself flushes/stalls the draw graph. The
	# explicit submit()/sync() APIs are reserved for local RenderingDevices.
	var metadata := rd.buffer_get_data(parameters, 0, 32).to_int32_array()
	if metadata.size() != 8:
		return {"available": false, "reason": "olv_metadata_readback_size_mismatch",
			"metadata_i32": metadata}
	var atlas_format := rd.texture_get_format(atlas)
	var total := atlas_format.width * atlas_format.height * atlas_format.depth
	if total <= 0 or total > 2000000:
		return {"available": false, "reason": "olv_atlas_size_out_of_bounds", "metadata_i32": metadata}
	var shader_source := RDShaderSource.new()
	shader_source.source_compute = """#version 450
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform texture3D label_texture;
layout(set = 0, binding = 1) uniform sampler nearest_sampler;
layout(set = 0, binding = 2, std430) buffer Result { float values[]; } result_data;
void main() {
	ivec3 size = textureSize(sampler3D(label_texture, nearest_sampler), 0);
	uint index = gl_GlobalInvocationID.x;
	uint total = uint(size.x * size.y * size.z);
	if (index < total) {
		uint x = index % uint(size.x);
		uint y = (index / uint(size.x)) % uint(size.y);
		uint z = index / uint(size.x * size.y);
		result_data.values[index] = texelFetch(sampler3D(label_texture, nearest_sampler),
			ivec3(int(x), int(y), int(z)), 0).r * 255.0;
	}
}
"""
	var spirv := rd.shader_compile_spirv_from_source(shader_source)
	if not spirv.compile_error_compute.is_empty():
		return {"available": false, "reason": "olv_readback_shader_compile_failed",
			"compile_error": spirv.compile_error_compute, "metadata_i32": metadata}
	var shader := rd.shader_create_from_spirv(spirv, "Magic GI Production OLV Atlas Readback")
	var pipeline := rd.compute_pipeline_create(shader)
	var sampler_state := RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	var sampler := rd.sampler_create(sampler_state)
	var output := rd.storage_buffer_create(total * 4)
	var texture_uniform := RDUniform.new()
	texture_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_TEXTURE
	texture_uniform.binding = 0
	texture_uniform.add_id(atlas)
	var sampler_uniform := RDUniform.new()
	sampler_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER
	sampler_uniform.binding = 1
	sampler_uniform.add_id(sampler)
	var output_uniform := RDUniform.new()
	output_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	output_uniform.binding = 2
	output_uniform.add_id(output)
	var uniform_set := rd.uniform_set_create([texture_uniform, sampler_uniform,
		output_uniform], shader, 0)
	var readback := PackedFloat32Array()
	if shader.is_valid() and pipeline.is_valid() and sampler.is_valid() \
			and output.is_valid() and uniform_set.is_valid():
		var compute_list := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
		rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
		rd.compute_list_dispatch(compute_list, int(ceili(float(total) / 64.0)), 1, 1)
		rd.compute_list_end()
		readback = rd.buffer_get_data(output, 0, total * 4).to_float32_array()
	for rid in [uniform_set, output, sampler, pipeline, shader]:
		if rid.is_valid():
			rd.free_rid(rid)
	if readback.size() != total:
		return {"available": false, "reason": "olv_atlas_gpu_readback_failed",
			"readback_values": readback.size(), "expected_values": total,
			"metadata_i32": metadata}
	var counts := PackedInt32Array([0, 0, 0, 0])
	var invalid := 0
	var unexpected := 0
	for label in readback:
		var raw := int(round(label))
		var code := raw & 3
		if absf(label - float(raw)) > 0.0001 or raw < 0 or raw > 7:
			unexpected += 1
		elif code == 0:
			invalid += 1
		else:
			counts[code] += 1
	return {"available": true, "gpu_compute_readback": true,
		"metadata_i32": metadata, "atlas_values": total,
		"unset_or_unknown": invalid, "exterior": counts[1],
		"interior": counts[2], "ambiguous": counts[3],
		"unexpected_values": unexpected,
		"labels_hash": String(binding.get("labels_hash", "")),
		"sampled_class_counts_are_gpu_atlas_readback": true}

func _finish(report: Dictionary, exit_code: int, error: String) -> void:
	report["error"] = error
	print("OLV_REPORT " + JSON.stringify(report, "", true, true))
	quit(exit_code)
