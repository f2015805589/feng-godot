@tool
extends RefCounted
## World/volume-owned GPU surfel cache used by FengMagicGIPass.
##
## All persistent RIDs are owned by this helper. Frame light buffers and GBuffer
## textures are borrowed for the duration of one render callback only.

const U = preload("../rd/uniforms.gd")
const SCENE_GPU_PATH := "res://addons/feng-raytracing/rendering/rt_gi_scene_gpu.gd"
const RAY_SHADER_DIR := "res://addons/feng-raytracing/shaders/"
const SHADER_DIR := "res://addons/feng-render-pipeline/library/magic-gi/surfel/"
const SURFEL_CACHE_GLSL := SHADER_DIR + "gi_surfel_cache.glslinc"
const SURFEL_CACHE_HLSL := SHADER_DIR + "gi_surfel_cache.hlslinc"
const DIRECT_GLSL := SHADER_DIR + "surfel_direct_lighting.glslinc"
const DIRECT_HLSL := SHADER_DIR + "surfel_direct_lighting.hlslinc"
const SURFEL_GATHER_GLSL := SHADER_DIR + "surfel_gather.glslinc"
const SURFEL_GATHER_HLSL := SHADER_DIR + "surfel_gather.hlslinc"
const MAX_CACHE_STATES := 16
const RECORD_BYTES := 80
const RESPONSE_BYTES := 16
const CONFIG_BYTES := 192
const COUNTER_BYTES := 16
const SEED_SHADER := "magic_gi_surfel_seed.glsl"

var rd: RenderingDevice
var error := ""
var _states: Dictionary = {} # world_id/cache_key -> immutable layout + persistent GPU state.
var _backends: Dictionary = {} # sky-array bool -> ray pipeline, SBT and shaders.
var _compute: Dictionary = {} # seed/commit compute shader and pipeline.
var _owned_shared: Array[RID] = []
var _cache_clock := 0
var resource_revision := 0
var _scene_gpu_script: Script
var _scene_gpu_script_checked := false

func initialize(device: RenderingDevice) -> bool:
	if device == null:
		return _fail("Surfel RenderingDevice is unavailable")
	var seed_pipeline: RID = _compute.get("seed_pipeline", RID())
	var commit_pipeline: RID = _compute.get("commit_pipeline", RID())
	if rd == device and seed_pipeline.is_valid() and commit_pipeline.is_valid():
		return true
	if rd != null and rd != device:
		release_all()
	rd = device
	error = ""
	return _ensure_compute("seed") and _ensure_compute("commit")

func release_all() -> void:
	if rd != null:
		for state in _states.values():
			_free_state(state)
		for backend in _backends.values():
			_free_rids(backend.get("owned", []))
		_free_rids(_owned_shared)
	_states.clear()
	_backends.clear()
	_compute.clear()
	_owned_shared.clear()
	rd = null
	resource_revision += 1

func take_owned_rids() -> Array[RID]:
	var result := _release_order_rids()
	_states.clear()
	_backends.clear()
	_compute.clear()
	_owned_shared.clear()
	resource_revision += 1
	return result

func get_resource_revision() -> int:
	return resource_revision

func get_all_rids() -> Array[RID]:
	return _release_order_rids()

func _release_order_rids() -> Array[RID]:
	var result: Array[RID] = []
	# RenderingDevice recursively frees dependent RIDs when a dependency is freed.
	# Return dependent pipelines/SBTs before the shaders and other resources they use.
	# Keep this order for both the live snapshot and detached cleanup inventory: base
	# pass finalization may need the stored snapshot after derived properties vanish.
	result.append_array(_reversed_rids(_owned_shared))
	for backend in _backends.values():
		result.append_array(_reversed_rids(backend.get("owned", [])))
	for state in _states.values():
		var scene: Variant = state.get("scene")
		if scene != null:
			result.append_array(_reversed_rids(scene.all_rids()))
		result.append_array(_reversed_rids(state.get("owned", [])))
	return _unique_rids(result)

func is_cache_ready(snapshot: Dictionary) -> bool:
	var key := _state_key(snapshot)
	if key.is_empty() or not _states.has(key):
		return false
	var state: Dictionary = _states[key]
	return int(state.get("gpu_positive_updates", 0)) > 0 and bool(state.get("scene_ready", false))

## Optional readback stalls the RenderingDevice and is intended for acceptance diagnostics only.
func get_debug_info(cache_key := "", readback_counters := false) -> Dictionary:
	var selected := cache_key
	if selected.is_empty() and not _states.is_empty():
		selected = str(_states.keys()[0])
	if not _states.has(selected):
		return {"cache_key": selected, "available": false}
	var state: Dictionary = _states[selected]
	var gpu_counts := PackedInt32Array()
	if readback_counters and rd != null:
		var bytes := rd.buffer_get_data(state.counters, 0, COUNTER_BYTES)
		if bytes.size() >= COUNTER_BYTES:
			gpu_counts = bytes.to_int32_array()
			state.gpu_active_count = gpu_counts[1]
			state.gpu_positive_updates = gpu_counts[2]
			state.gpu_seeded_this_frame = gpu_counts[3]
			_states[selected] = state
	var seeded_views_value: Variant = state.get("seeded_views", {})
	var seeded_view_count: int = seeded_views_value.size() if seeded_views_value is Dictionary else 0
	return {"cache_key": str(state.get("cache_key", selected)),
		"available": true, "ready": int(state.get("gpu_positive_updates", 0)) > 0,
		"capacity": int(state.get("capacity", 0)), "hash_capacity": int(state.get("hash_capacity", 0)),
		"record_bytes": int(state.get("record_bytes", 0)),
		"response_bytes": int(state.get("response_bytes", 0)),
		"cache_bytes": int(state.get("cache_bytes", 0)),
		"layout_version": int(state.get("layout_version", -1)),
		"world_generation": int(state.get("world_generation", -1)),
		"last_update_frame": int(state.get("last_update_frame", -1)),
		"last_seed_frame": int(state.get("last_seed_frame", -1)),
		"seeded_view_count": seeded_view_count,
		"diagnostic_readback": readback_counters and not gpu_counts.is_empty(),
		"gpu_active_count": int(state.get("gpu_active_count", -1)),
		"gpu_positive_updates": int(state.get("gpu_positive_updates", -1)),
		"gpu_seeded_this_frame": int(state.get("gpu_seeded_this_frame", -1)),
		"dispatch_count": int(state.get("dispatch_count", 0)),
		"last_error": str(state.get("error", ""))}

func render(device: RenderingDevice, snapshot: Dictionary, frame: Dictionary,
		textures: Array[RID], color: RID,
		output: RID, sky_diffuse: RID, diffuse_ao: RID, size: Vector2i,
		strength: float, replacement_enabled: bool, frame_token: int) -> bool:
	error = ""
	if not initialize(device):
		return _fail("Surfel RenderingDevice is unavailable")
	if textures.size() < 4 or not color.is_valid() or not output.is_valid():
		return _fail("Surfel GBuffer or output attachment is unavailable")
	if not bool(snapshot.get("surfel", false)) or not bool(snapshot.get("valid", false)):
		return _fail(_snapshot_failure(snapshot))
	var settings_value: Variant = snapshot.get("surfel_settings", {})
	var settings: Dictionary = settings_value if settings_value is Dictionary else {}
	var radius := _finite_range(settings.get("surfel_radius", 0.15), 0.15, 0.001, 64.0)
	var capacity := clampi(int(settings.get("max_surfels", 65536)), 1024, 262144)
	var updates := clampi(int(settings.get("updates_per_frame", 2048)), 1, capacity)
	var rays := clampi(int(settings.get("rays_per_surfel", 4)), 1, 32)
	var max_distance := _finite_range(settings.get("max_ray_distance", 128.0), 128.0, 0.1, 4096.0)
	var history_weight: float = _finite_range(settings.get("history_weight", 0.9), 0.9, 0.0, 0.99)
	var debug_view := clampi(int(settings.get("debug_view", 0)), 0, 3)
	var cache_key := _state_key(snapshot)
	if cache_key.is_empty():
		return _fail("Surfel cache key is unavailable")
	var layout_version := int(snapshot.get("layout_version", snapshot.get("version", -1)))
	var world_generation := int(snapshot.get("world_generation", 0))
	var registry_epoch := int(snapshot.get("registry_epoch", 0))
	var owner_transform_value: Variant = snapshot.get("owner_transform", Transform3D.IDENTITY)
	var owner_size_value: Variant = snapshot.get("owner_size", Vector3.ZERO)
	if not owner_transform_value is Transform3D or not owner_size_value is Vector3 \
			or owner_size_value.x <= 0.0 or owner_size_value.y <= 0.0 or owner_size_value.z <= 0.0:
		return _fail("Surfel volume bounds are invalid")
	var frame_token_u32 := frame_token & 0xffffffff
	var light_counts := PackedInt32Array([
		clampi(int(frame.get("directional_light_count", 0)), 0, 8),
		clampi(int(frame.get("omni_light_count", 0)), 0, 65535),
		clampi(int(frame.get("spot_light_count", 0)), 0, 65535),
		clampi(int(frame.get("area_light_count", 0)), 0, 65535)])
	var sky_array := bool(frame.get("sky_radiance_is_array", false))
	var state := _ensure_state(cache_key, snapshot, capacity, layout_version,
		world_generation, registry_epoch, sky_array)
	if state.is_empty():
		return _fail(error if not error.is_empty() else "Surfel cache allocation failed")
	var backend := _ensure_backend(sky_array)
	if backend.is_empty():
		return _fail(error if not error.is_empty() else "Surfel ray pipeline is unavailable")
	var scene: Variant = state.get("scene")
	if scene == null:
		return _fail("Surfel TLAS is unavailable")
	var scene_rids_before: Array[RID] = scene.all_rids()
	var scene_synced: bool = bool(scene.sync_scene(snapshot, int(backend.get("sbt_range", 0))))
	var scene_rids_after: Array[RID] = scene.all_rids()
	if scene_rids_before != scene_rids_after:
		# FengPass keeps an owned-only RID snapshot between callbacks. SceneGPU may
		# release and replace TLAS/BLAS/geometry RIDs inside sync_scene, so refresh
		# that inventory after this render callback completes.
		resource_revision += 1
	if not scene_synced:
		state.error = scene.error if scene != null else "Surfel TLAS is unavailable"
		return _fail(str(state.error))
	state.scene_ready = true
	state.sky_array = sky_array
	var bounds: Transform3D = owner_transform_value
	var frame_bytes := _pack_frame(frame, size, max_distance, rays,
		int(state.get("update_cursor", 0)), frame_token_u32, sky_array)
	var config_bytes := _pack_config(bounds, owner_size_value, radius, capacity,
		int(state.hash_capacity), updates, frame_token_u32, light_counts,
		max_distance, history_weight, mini(updates, maxi(size.x * size.y, 1)), debug_view)
	if frame_bytes.size() != 256 or config_bytes.size() != CONFIG_BYTES \
			or rd.buffer_update(state.frame_buffer, 0, frame_bytes.size(), frame_bytes) != OK \
			or rd.buffer_update(state.config_buffer, 0, config_bytes.size(), config_bytes) != OK:
		return _fail("Surfel frame/configuration upload failed")
	var textures_ok := true
	for rid in textures.slice(0, 4):
		textures_ok = textures_ok and rid.is_valid()
	if not textures_ok:
		return _fail("Surfel depth/normal/albedo/ORM input is unavailable")
	var effective_strength := clampf(float(snapshot.get("strength", 1.0)) * strength, 0.0, 8.0)
	var gather_bytes := PackedFloat32Array([effective_strength,
		1.0 if replacement_enabled else 0.0, float(frame_token_u32), 0.0]).to_byte_array()
	if not state.gather_ubo.is_valid() \
			or rd.buffer_update(state.gather_ubo, 0, gather_bytes.size(), gather_bytes) != OK:
		return _fail("Surfel gather parameter upload failed")
	if int(state.get("last_seed_frame", -1)) != frame_token:
		var reset_counters := PackedInt32Array([0, 0]).to_byte_array()
		if rd.buffer_update(state.counters, 8, reset_counters.size(), reset_counters) != OK:
			return _fail("Surfel frame counter reset failed")
		state.last_seed_frame = frame_token
		state.seeded_views = {}
	var seeded_views: Dictionary = state.get("seeded_views", {})
	var view_key := _seed_view_key(textures[0], textures[1], size)
	if not seeded_views.has(view_key):
		state.seed_count = mini(updates, maxi(size.x * size.y, 1))
		if not _dispatch_seed(state, textures[0], textures[1], size):
			return _fail(error)
		seeded_views[view_key] = true
		state.seeded_views = seeded_views
	if int(state.get("last_update_frame", -1)) != frame_token:
		var read_index := int(state.get("response_read", 0))
		var previous: RID = state.responses[read_index]
		var next: RID = state.responses[1 - read_index]
		var copy_bytes := int(state.capacity) * RESPONSE_BYTES
		if rd.buffer_copy(previous, next, 0, 0, copy_bytes) != OK \
				or rd.buffer_clear(state.processed_bits, 0, int(state.processed_bits_bytes)) != OK:
			return _fail("Surfel response history copy failed")
		if not _dispatch_trace(state, backend, frame, previous, next,
				min(updates, int(state.capacity)), rays, textures, color, output,
				sky_diffuse, diffuse_ao, size, false):
			return _fail(error)
		if not _dispatch_commit(state, min(updates, int(state.capacity))):
			return _fail(error)
		state.update_cursor = (int(state.get("update_cursor", 0)) + mini(updates, int(state.capacity))) & 0xffffffff
		state.response_read = 1 - read_index
		state.last_update_frame = frame_token
		state.dispatch_count = int(state.get("dispatch_count", 0)) + 1
	state.last_used = _cache_clock
	var current_response: RID = state.responses[int(state.response_read)]
	if not _dispatch_gather(state, backend, frame, textures, color, output,
			sky_diffuse, diffuse_ao, size, current_response, max_distance, rays,
			frame_token_u32):
		return _fail(error)
	state.error = ""
	_states[cache_key] = state
	return true

func _seed_view_key(depth: RID, normal: RID, size: Vector2i) -> String:
	return "%d:%d:%d:%d" % [depth.get_id(), normal.get_id(), size.x, size.y]

func _ensure_compute(kind: String) -> bool:
	var shader_key := kind + "_shader"
	var pipeline_key := kind + "_pipeline"
	if _compute.has(pipeline_key) and _compute[pipeline_key].is_valid():
		return true
	var source := RDShaderSource.new()
	var shader_name := SEED_SHADER if kind == "seed" else "magic_gi_surfel_commit.glsl"
	var shader_text := FileAccess.get_file_as_string(SHADER_DIR + shader_name)
	if shader_text.is_empty():
		return _fail("Surfel %s shader source is missing" % kind)
	if shader_text.begins_with("#[compute]"):
		var marker_end := shader_text.find("\n")
		shader_text = shader_text.substr(marker_end + 1)
	source.source_compute = shader_text
	var spirv := rd.shader_compile_spirv_from_source(source)
	if not spirv.compile_error_compute.is_empty():
		return _fail("Surfel %s shader compile failed: %s" % [kind, spirv.compile_error_compute])
	var shader: RID = rd.shader_create_from_spirv(spirv, "Magic GI Surfel %s" % kind)
	if not shader.is_valid():
		return _fail("Surfel %s shader creation failed" % kind)
	var pipeline: RID = rd.compute_pipeline_create(shader)
	if not pipeline.is_valid():
		rd.free_rid(shader)
		return _fail("Surfel %s compute pipeline creation failed" % kind)
	_compute[shader_key] = shader
	_compute[pipeline_key] = pipeline
	_owned_shared.append_array([shader, pipeline])
	resource_revision += 1
	return true

func _ensure_backend(sky_array: bool) -> Dictionary:
	var key := int(sky_array)
	if _backends.has(key):
		return _backends[key]
	var source := RDShaderSource.new()
	if not _attach_trace_stage(source, RenderingDevice.SHADER_STAGE_RAYGEN,
		"magic_gi_surfel_raygen", "FengMagicGISurfelRayGen", true, sky_array) \
		or not _attach_trace_stage(source, RenderingDevice.SHADER_STAGE_MISS,
		"gi_primary_miss", "FengGIPrimaryMiss", false, sky_array) \
		or not _attach_trace_stage(source, RenderingDevice.SHADER_STAGE_CLOSEST_HIT,
		"gi_closest_hit", "FengGIClosestHit", false, sky_array) \
		or not _attach_trace_stage(source, RenderingDevice.SHADER_STAGE_ANY_HIT,
		"gi_any_hit", "FengGIAnyHit", false, sky_array):
		return {}
	var shader := _compile_trace_source(source, "Magic GI Surfel")
	if not shader.is_valid():
		return {}
	var shadow_source := RDShaderSource.new()
	if not _attach_trace_stage(shadow_source, RenderingDevice.SHADER_STAGE_MISS,
		"gi_shadow_miss", "FengGIShadowMiss", false, sky_array):
		rd.free_rid(shader)
		return {}
	var shadow_shader := _compile_trace_source(shadow_source, "Magic GI Surfel Shadow")
	if not shadow_shader.is_valid():
		rd.free_rid(shader)
		return {}
	var raygen := RDPipelineShader.new()
	raygen.shader = shader
	var miss := RDPipelineShader.new()
	miss.shader = shader
	var shadow_miss := RDPipelineShader.new()
	shadow_miss.shader = shadow_shader
	var hit := RDHitGroup.new()
	hit.closest_hit_shader = raygen
	hit.any_hit_shader = raygen
	var owned: Array[RID] = [shader, shadow_shader]
	var pipeline := rd.raytracing_pipeline_create([raygen], [miss, shadow_miss], [hit], 2)
	if not pipeline.is_valid():
		_free_rids(owned)
		_fail("Surfel ray tracing pipeline creation failed")
		return {}
	owned.append(pipeline)
	var sbt := rd.hit_sbt_create(pipeline, 1)
	if not sbt.is_valid():
		_free_rids(owned)
		_fail("Surfel hit SBT creation failed")
		return {}
	owned.append(sbt)
	var sbt_range := rd.hit_sbt_range_alloc(sbt, 1)
	if sbt_range == 0 or rd.hit_sbt_range_update(sbt, sbt_range, 0, PackedInt32Array([0])) != OK:
		_free_rids(owned)
		_fail("Surfel hit SBT range setup failed")
		return {}
	var neutral_local: Array[RID] = []
	for unused in 3:
		neutral_local.append(rd.storage_buffer_create(224))
	owned.append_array(neutral_local)
	for rid in owned:
		if not rid.is_valid():
			_free_rids(owned)
			_fail("Surfel ray backend resource allocation failed")
			return {}
	var backend := {"shader": shader, "shadow_shader": shadow_shader,
		"pipeline": pipeline, "sbt": sbt, "sbt_range": sbt_range,
		"neutral_local": neutral_local,
		"owned": owned, "sky_array": sky_array}
	_backends[key] = backend
	resource_revision += 1
	return backend

func _attach_trace_stage(source: RDShaderSource, stage: int, stem: String,
		entry: String, surfel_raygen: bool, sky_array: bool) -> bool:
	var prefix := "#define FENG_GI_SKY_ARRAY %d\n#define FENG_GI_SURFEL_CACHE 1\n#define FENG_GI_SURFEL_RAYGEN %d\n" % [int(sky_array), int(surfel_raygen)]
	var glsl_path := (SHADER_DIR + stem + ".glslinc") if surfel_raygen else (RAY_SHADER_DIR + stem + ".glslinc")
	var hlsl_path := (SHADER_DIR + stem + ".hlslinc") if surfel_raygen else (RAY_SHADER_DIR + stem + ".hlslinc")
	var glsl := FileAccess.get_file_as_string(
		glsl_path)
	if glsl.is_empty():
		return _fail("Surfel ray shader source is missing: %s" % stem)
	if glsl.begins_with("#version"):
		var line_end := glsl.find("\n")
		glsl = glsl.substr(0, line_end + 1) + prefix + glsl.substr(line_end + 1)
	else:
		glsl = prefix + glsl
	var native_hlsl := prefix + FileAccess.get_file_as_string(hlsl_path)
	if native_hlsl.trim_prefix(prefix).is_empty():
		return _fail("Surfel native HLSL ray shader source is missing: %s" % stem)
	if stem == "magic_gi_surfel_raygen":
		var cache_glsl := FileAccess.get_file_as_string(SURFEL_CACHE_GLSL)
		var gather_glsl := FileAccess.get_file_as_string(SURFEL_GATHER_GLSL)
		var cache_hlsl := FileAccess.get_file_as_string(SURFEL_CACHE_HLSL)
		var gather_hlsl := FileAccess.get_file_as_string(SURFEL_GATHER_HLSL)
		if cache_glsl.is_empty() or gather_glsl.is_empty() \
				or cache_hlsl.is_empty() or gather_hlsl.is_empty():
			return _fail("Surfel raygen cache or gather shader include is missing")
		var include_marker := "// FENG_GI_SURFEL_CACHE_AND_GATHER_INCLUDES"
		var cache_and_gather_glsl := cache_glsl + "\n" + gather_glsl
		var cache_and_gather_hlsl := cache_hlsl + "\n" + gather_hlsl
		if not glsl.contains(include_marker) or not native_hlsl.contains(include_marker):
			return _fail("Surfel raygen cache/gather injection point was not found")
		glsl = glsl.replace(include_marker, cache_and_gather_glsl)
		native_hlsl = native_hlsl.replace(include_marker, cache_and_gather_hlsl)
		if not glsl.contains("void gi_surfel_gather()") \
				or not native_hlsl.contains("void gi_surfel_gather()"):
			return _fail("Surfel gather entry point was not found")
	elif stem == "gi_closest_hit":
		var cache_glsl := FileAccess.get_file_as_string(SURFEL_CACHE_GLSL)
		var direct_glsl := FileAccess.get_file_as_string(DIRECT_GLSL)
		var cache_hlsl := FileAccess.get_file_as_string(SURFEL_CACHE_HLSL)
		var direct_hlsl := FileAccess.get_file_as_string(DIRECT_HLSL)
		if cache_glsl.is_empty() or direct_glsl.is_empty() or cache_hlsl.is_empty() or direct_hlsl.is_empty():
			return _fail("Surfel closest-hit cache or local-light shader include is missing")
		glsl = glsl.replace("void main() {", cache_glsl + "\n" + direct_glsl + "\nvoid main() {")
		native_hlsl = native_hlsl.replace("[shader(\"closesthit\")]",
				cache_hlsl + "\n" + direct_hlsl + "\n[shader(\"closesthit\")]")
		if not glsl.contains("gi_surfel_lookup_previous") or not native_hlsl.contains("gi_surfel_lookup_previous"):
			return _fail("Surfel closest-hit cache include injection point was not found")
	source.set_stage_source(stage, glsl)
	if source.has_method("set_native_hlsl_stage_source"):
		source.call("set_native_hlsl_stage_source", stage, native_hlsl)
		source.call("set_native_hlsl_stage_export", stage, entry)
		source.call("set_native_hlsl_max_payload_size_bytes", 24)
		source.call("set_native_hlsl_max_attribute_size_bytes", 8)
	return true

func _compile_trace_source(source: RDShaderSource, label: String) -> RID:
	var spirv := rd.shader_compile_spirv_from_source(source)
	for stage in range(RenderingDevice.SHADER_STAGE_MAX):
		var stage_error := spirv.get_stage_compile_error(stage)
		if not stage_error.is_empty():
			_fail("%s shader compile failed: %s" % [label, stage_error])
			return RID()
	var shader := rd.shader_create_from_spirv(spirv, label)
	if not shader.is_valid():
		_fail("%s shader creation failed" % label)
	return shader

func _ensure_state(cache_key: String, snapshot: Dictionary, capacity: int,
		layout_version: int, world_generation: int, registry_epoch: int,
		sky_array: bool) -> Dictionary:
	_cache_clock += 1
	var state: Dictionary = _states.get(cache_key, {})
	var incompatible := not state.is_empty() and (int(state.get("layout_version", -1)) != layout_version \
			or int(state.get("world_generation", -1)) != world_generation \
			or int(state.get("registry_epoch", -1)) != registry_epoch \
			or int(state.get("capacity", 0)) != capacity)
	if incompatible:
		_free_state(state)
		_states.erase(cache_key)
		state = {}
	if state.is_empty():
		var scene_type := _get_scene_gpu_script()
		if scene_type == null:
			error = "Surfel requires feng-raytracing SceneGPU support"
			return {}
		var scene: Variant = scene_type.new()
		if not scene.initialize(rd):
			error = "Surfel RTGI scene resources failed to initialize"
			scene.release()
			return {}
		var hash_capacity := _next_power_of_two(capacity * 2)
		var table_bytes := PackedInt32Array()
		table_bytes.resize(hash_capacity)
		for index in table_bytes.size():
			table_bytes[index] = -1
		var table := rd.storage_buffer_create(hash_capacity * 4, table_bytes.to_byte_array())
		var records := rd.storage_buffer_create(capacity * RECORD_BYTES)
		var update_queue := rd.storage_buffer_create(capacity * 8)
		var pending_results := rd.storage_buffer_create(capacity * 16)
		var processed_bits_bytes := maxi(4, ceili(float(capacity) / 32.0) * 4)
		var processed_bits := rd.storage_buffer_create(processed_bits_bytes)
		var responses: Array[RID] = [rd.storage_buffer_create(capacity * RESPONSE_BYTES),
			rd.storage_buffer_create(capacity * RESPONSE_BYTES)]
		var config := rd.uniform_buffer_create(CONFIG_BYTES)
		var counters := rd.storage_buffer_create(COUNTER_BYTES,
			PackedInt32Array([0, 0, 0, 0]).to_byte_array())
		var frame_buffer := rd.uniform_buffer_create(256)
		var gather_ubo := rd.uniform_buffer_create(16)
		var sampler_state := RDSamplerState.new()
		sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		sampler_state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		var sampler := rd.sampler_create(sampler_state)
		var owned: Array[RID] = [table, records, update_queue, pending_results, processed_bits,
			responses[0], responses[1], config, counters, frame_buffer, gather_ubo, sampler]
		for rid in owned:
			if not rid.is_valid():
				_free_rids(owned)
				scene.release()
				error = "Surfel cache bounded storage allocation failed"
				return {}
		if rd.buffer_clear(records, 0, capacity * RECORD_BYTES) != OK \
				or rd.buffer_clear(update_queue, 0, capacity * 8) != OK \
				or rd.buffer_clear(pending_results, 0, capacity * 16) != OK \
				or rd.buffer_clear(processed_bits, 0, processed_bits_bytes) != OK \
				or rd.buffer_clear(responses[0], 0, capacity * RESPONSE_BYTES) != OK \
				or rd.buffer_clear(responses[1], 0, capacity * RESPONSE_BYTES) != OK:
			_free_rids(owned)
			scene.release()
			error = "Surfel response history initialization failed"
			return {}
		state = {"cache_key": cache_key, "scene": scene, "owned": owned,
			"table": table, "records": records, "responses": responses,
			"update_queue": update_queue, "pending_results": pending_results,
			"processed_bits": processed_bits, "processed_bits_bytes": processed_bits_bytes,
			"config_buffer": config, "counters": counters, "frame_buffer": frame_buffer,
			"gather_ubo": gather_ubo, "sampler": sampler, "response_read": 0, "last_update_frame": -1,
			"last_seed_frame": -1, "valid_updates": 0, "capacity": capacity,
			"hash_capacity": hash_capacity, "record_bytes": capacity * RECORD_BYTES,
			"response_bytes": capacity * RESPONSE_BYTES * 2,
			"cache_bytes": hash_capacity * 4 + capacity * (RECORD_BYTES + RESPONSE_BYTES * 2 + 8 + 16) + processed_bits_bytes + CONFIG_BYTES + COUNTER_BYTES + 256 + 16,
			"layout_version": layout_version, "world_generation": world_generation,
			"registry_epoch": registry_epoch, "sky_array": sky_array,
			"scene_ready": false, "last_used": _cache_clock, "error": ""}
		state.update_cursor = 0
		state.dispatch_count = 0
		state.gpu_positive_updates = 0
		state.gpu_active_count = 0
		_states[cache_key] = state
		resource_revision += 1
		_evict_old_states(cache_key)
	return state

func _evict_old_states(keep_key: String) -> void:
	while _states.size() > MAX_CACHE_STATES:
		var oldest_key := ""
		var oldest_frame := 0x7fffffff
		for key in _states:
			if str(key) == keep_key:
				continue
			var candidate: Dictionary = _states[key]
			if int(candidate.get("last_used", 0)) < oldest_frame:
				oldest_frame = int(candidate.get("last_used", 0))
				oldest_key = str(key)
		if oldest_key.is_empty():
			break
		var stale: Dictionary = _states[oldest_key]
		_states.erase(oldest_key)
		_free_state(stale)

func _free_state(state: Dictionary) -> void:
	var scene: Variant = state.get("scene")
	if scene != null:
		scene.release()
	_free_rids(state.get("owned", []))
	resource_revision += 1

func _dispatch_seed(state: Dictionary, depth: RID, normal: RID, size: Vector2i) -> bool:
	var set0: Array[RDUniform] = [U.sampled(1, state.sampler, depth),
		U.sampled(2, state.sampler, normal), U.uniform_buffer(20, state.frame_buffer)]
	var set1: Array[RDUniform] = [U.storage_buffer(0, state.records),
		U.storage_buffer(1, state.table), U.storage_buffer(2, state.responses[0]),
		U.storage_buffer(3, state.responses[1]), U.uniform_buffer(4, state.config_buffer),
		U.storage_buffer(5, state.counters), U.storage_buffer(6, state.update_queue)]
	return _dispatch(_compute.seed_shader, _compute.seed_pipeline, set0, set1,
		int(state.get("seed_count", 0)), Vector2i(64, 1))

func _dispatch_commit(state: Dictionary, update_count: int) -> bool:
	var set0: Array[RDUniform] = [U.uniform_buffer(4, state.config_buffer)]
	var set1: Array[RDUniform] = [U.storage_buffer(0, state.records),
		U.storage_buffer(6, state.update_queue), U.storage_buffer(7, state.pending_results)]
	return _dispatch(_compute.commit_shader, _compute.commit_pipeline, set0, set1,
		update_count, Vector2i(64, 1))

func _dispatch_gather(state: Dictionary, backend: Dictionary, frame: Dictionary,
		textures: Array[RID], color: RID, output: RID, sky_diffuse: RID,
		diffuse_ao: RID, size: Vector2i, current_response: RID,
		max_distance: float, rays_per_surfel: int, frame_token: int) -> bool:
	if size.x <= 0 or size.y <= 0:
		return true
	var frame_bytes := _pack_frame(frame, size, max_distance, rays_per_surfel,
		int(state.get("update_cursor", 0)), frame_token, bool(state.get("sky_array", false)), 1)
	if frame_bytes.size() != 256 \
			or rd.buffer_update(state.frame_buffer, 0, frame_bytes.size(), frame_bytes) != OK:
		return _fail("Surfel gather frame upload failed")
	var next_response: RID = state.responses[1 - int(state.get("response_read", 0))]
	return _dispatch_trace(state, backend, frame, current_response, next_response,
		1, rays_per_surfel, textures, color, output, sky_diffuse, diffuse_ao,
		size, true)

func _dispatch_trace(state: Dictionary, backend: Dictionary, frame: Dictionary,
		previous: RID, next: RID, update_count: int, rays_per_surfel: int,
		textures: Array[RID], color: RID, output: RID, sky_diffuse: RID,
		diffuse_ao: RID, size: Vector2i, gather_mode: bool) -> bool:
	if not gather_mode and update_count <= 0:
		return true
	var scene: Variant = state.scene
	var lighting: Dictionary = frame
	var sky_array := bool(state.sky_array)
	var sky: RID = lighting.get("sky_radiance_texture", RID())
	if not sky.is_valid():
		sky = scene.black_array if sky_array else scene.black_2d
	var directional: RID = lighting.get("directional_light_buffer", RID())
	if not directional.is_valid():
		directional = scene.neutral_lights
	var sun_view_projection := _trace_uniforms(state, backend, lighting, sky, directional,
		previous, next, textures, color, output, sky_diffuse, diffuse_ao)
	if sun_view_projection.is_empty():
		return false
	var set0: RID = rd.uniform_set_create(sun_view_projection[0], backend.shader, 0)
	var set1: RID = rd.uniform_set_create(sun_view_projection[1], backend.shader, 1)
	if not set0.is_valid() or not set1.is_valid():
		if set0.is_valid(): rd.free_rid(set0)
		if set1.is_valid(): rd.free_rid(set1)
		return _fail("Surfel trace descriptor sets are invalid")
	var list := rd.raytracing_list_begin()
	if list < 0:
		rd.free_rid(set0)
		rd.free_rid(set1)
		return _fail("Surfel ray tracing list could not begin")
	rd.raytracing_list_bind_raytracing_pipeline(list, backend.pipeline)
	rd.raytracing_list_bind_uniform_set(list, set0, 0)
	rd.raytracing_list_bind_uniform_set(list, set1, 1)
	var ray_width := size.x if gather_mode else update_count
	var ray_height := size.y if gather_mode else 1
	rd.raytracing_list_trace_rays(list, 0, backend.sbt, ray_width, ray_height, 1)
	rd.raytracing_list_end()
	rd.free_rid(set0)
	rd.free_rid(set1)
	return true

func _trace_uniforms(state: Dictionary, backend: Dictionary, frame: Dictionary,
		sky: RID, directional: RID, previous: RID, next: RID,
		textures: Array[RID], color: RID, output: RID, sky_diffuse: RID,
		diffuse_ao: RID) -> Array:
	var scene: Variant = state.scene
	if textures.size() < 4 or not color.is_valid() or not output.is_valid():
		_fail("Surfel ray dispatch is missing per-view attachments")
		return []
	var neutral: Array = backend.neutral_local
	var omni: RID = _valid_light_buffer(frame, "omni_light_buffer", "omni_light_count", 224, neutral[0])
	var spot: RID = _valid_light_buffer(frame, "spot_light_buffer", "spot_light_count", 224, neutral[1])
	var area: RID = _valid_light_buffer(frame, "area_light_buffer", "area_light_count", 224, neutral[2])
	var set0: Array[RDUniform] = []
	var acceleration := RDUniform.new()
	acceleration.uniform_type = RenderingDevice.UNIFORM_TYPE_ACCELERATION_STRUCTURE
	acceleration.binding = 0
	acceleration.add_id(scene.tlas)
	set0.append(acceleration)
	set0.append(U.sampled(6, scene.sampler, sky))
	set0.append(U.uniform_buffer(7, directional))
	set0.append(U.storage_buffer(8, scene.vertices))
	set0.append(U.storage_buffer(9, scene.indices))
	set0.append(U.storage_buffer(10, scene.surfaces))
	set0.append(U.storage_buffer(11, scene.materials))
	for index in 8:
		var group := mini(index, scene.atlas.size() - 1)
		set0.append(U.sampled(12 + index, scene.atlas_samplers[group], scene.atlas[group]))
	set0.append(U.uniform_buffer(20, state.frame_buffer))
	set0.append(U.sampled(23, scene.sampler, scene.black_2d))
	set0.append(U.storage_buffer(25, scene.emitters))
	set0.append(U.storage_buffer(26, omni))
	set0.append(U.storage_buffer(27, spot))
	set0.append(U.storage_buffer(28, area))
	var sky_diffuse_texture: RID = sky_diffuse if sky_diffuse.is_valid() else scene.black_2d
	var ao_texture: RID = diffuse_ao if diffuse_ao.is_valid() else _ensure_white_ao(state)
	if not sky_diffuse_texture.is_valid() or not ao_texture.is_valid():
		_fail("Surfel gather fallback textures are unavailable")
		return []
	set0.append(U.image(29, color))
	set0.append(U.image(30, output))
	set0.append(U.sampled(31, state.sampler, textures[0]))
	set0.append(U.sampled(32, state.sampler, textures[1]))
	set0.append(U.sampled(33, state.sampler, textures[2]))
	set0.append(U.sampled(34, state.sampler, textures[3]))
	set0.append(U.sampled(35, scene.sampler, sky_diffuse_texture))
	set0.append(U.sampled(36, state.sampler, ao_texture))
	set0.append(U.uniform_buffer(37, state.gather_ubo))
	var set1: Array[RDUniform] = [U.storage_buffer(0, state.records),
		U.storage_buffer(1, state.table), U.storage_buffer(2, previous),
		U.storage_buffer(3, next), U.uniform_buffer(4, state.config_buffer),
		U.storage_buffer(5, state.counters), U.storage_buffer(6, state.update_queue),
		U.storage_buffer(7, state.pending_results), U.storage_buffer(8, state.processed_bits)]
	return [set0, set1]

func _valid_light_buffer(frame: Dictionary, buffer_key: String, count_key: String,
		stride: int, fallback: RID) -> RID:
	var rid_value: Variant = frame.get(buffer_key, RID())
	var count := int(frame.get(count_key, 0))
	if rid_value is RID and rid_value.is_valid() and count > 0 \
			and int(frame.get(buffer_key.trim_suffix("buffer") + "stride_bytes", stride)) == stride:
		return rid_value
	return fallback

func _dispatch(shader: RID, pipeline: RID, set0_uniforms: Array[RDUniform],
		set1_uniforms: Array[RDUniform], extent: Variant, workgroup: Vector2i) -> bool:
	var groups: Vector3i
	if extent is Vector2i:
		groups = Vector3i(ceili(float(extent.x) / workgroup.x), ceili(float(extent.y) / workgroup.y), 1)
	else:
		groups = Vector3i(ceili(float(int(extent)) / workgroup.x), 1, 1)
	if groups.x <= 0 or groups.y <= 0:
		return true
	var set0 := rd.uniform_set_create(set0_uniforms, shader, 0)
	var set1 := rd.uniform_set_create(set1_uniforms, shader, 1) if not set1_uniforms.is_empty() else RID()
	if not set0.is_valid() or (not set1_uniforms.is_empty() and not set1.is_valid()):
		if set0.is_valid():
			rd.free_rid(set0)
		if set1.is_valid():
			rd.free_rid(set1)
		return _fail("Surfel compute descriptor set is invalid")
	var list := rd.compute_list_begin()
	if list < 0:
		rd.free_rid(set0)
		if set1.is_valid():
			rd.free_rid(set1)
		return _fail("Surfel compute list could not begin")
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	rd.compute_list_bind_uniform_set(list, set0, 0)
	if set1.is_valid():
		rd.compute_list_bind_uniform_set(list, set1, 1)
	if extent is Vector2i:
		rd.compute_list_dispatch(list, groups.x, groups.y, 1)
	else:
		rd.compute_list_dispatch(list, groups.x, 1, 1)
	rd.compute_list_end()
	rd.free_rid(set0)
	if set1.is_valid():
		rd.free_rid(set1)
	return true

func _pack_frame(frame: Dictionary, size: Vector2i, max_distance: float,
		rays_per_surfel: int, update_cursor: int, frame_token: int,
		sky_array: bool, raygen_mode: int = 0) -> PackedByteArray:
	var bytes := PackedByteArray()
	_append_projection(bytes, frame.get("inverse_projection", Projection.IDENTITY))
	var camera: Transform3D = frame.get("camera_transform", Transform3D.IDENTITY)
	_append_transform(bytes, Transform3D(camera.basis.orthonormalized(), camera.origin))
	bytes.append_array(PackedFloat32Array([size.x, size.y,
		_finite_range(frame.get("pre_exposure", 1.0), 1.0, 1e-6, 1e6),
		_finite_range(frame.get("scene_normalization", 1.0), 1.0, 1e-6, 1e6),
		_finite_range(frame.get("light_buffer_exposure_normalization", 1.0), 1.0, 1e-6, 1e6),
		_finite_range(frame.get("sky_light_energy", 0.0), 0.0, 0.0, 1e6),
		_finite_range(frame.get("sky_captured_exposure", 1.0), 1.0, 1e-6, 1e6),
		_finite_range(frame.get("sky_uv_border_size", 0.0), 0.0, 0.0, 0.49)]).to_byte_array())
	var sky_rotation: Basis = frame.get("sky_light_rotation", Basis.IDENTITY)
	var rotation: Basis = sky_rotation.inverse()
	for axis in [rotation.x, rotation.y, rotation.z]:
		bytes.append_array(PackedFloat32Array([axis.x, axis.y, axis.z, 0.0]).to_byte_array())
	var sun := int(frame.get("cloud_primary_sun_directional_index", -1))
	if sun < 0 and int(frame.get("directional_light_count", 0)) > 0:
		sun = 0
	bytes.append_array(PackedInt32Array([sun, int(frame.get("view_index", 0)), frame_token, int(sky_array)]).to_byte_array())
	bytes.append_array(PackedFloat32Array([max_distance, 1.0, float(rays_per_surfel), 0.0]).to_byte_array())
	# generation_history_flags.y disables the base RTGI emitter MIS suppression:
	# Surfel paths use cosine rays and do not perform the matching emitter NEE.
	bytes.append_array(PackedInt32Array([update_cursor, 1, raygen_mode, 0]).to_byte_array())
	return bytes

func _pack_config(owner: Transform3D, owner_size: Vector3, radius: float,
		capacity: int, hash_capacity: int, updates: int, frame_token: int,
		light_counts: PackedInt32Array, max_distance: float, history_weight: float,
		seed_count: int, debug_view: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	_append_transform(bytes, owner.affine_inverse())
	_append_transform(bytes, owner)
	bytes.append_array(PackedFloat32Array([owner_size.x, owner_size.y, owner_size.z, radius]).to_byte_array())
	bytes.append_array(PackedInt32Array([capacity, hash_capacity - 1, updates, frame_token]).to_byte_array())
	bytes.append_array(light_counts.to_byte_array())
	bytes.append_array(PackedFloat32Array([max_distance, history_weight, seed_count, debug_view]).to_byte_array())
	return bytes

func _append_projection(bytes: PackedByteArray, projection: Projection) -> void:
	var values := PackedFloat32Array()
	for column in 4:
		var axis: Vector4 = projection[column]
		values.append_array(PackedFloat32Array([axis.x, axis.y, axis.z, axis.w]))
	bytes.append_array(values.to_byte_array())

func _append_transform(bytes: PackedByteArray, transform: Transform3D) -> void:
	for axis in [transform.basis.x, transform.basis.y, transform.basis.z]:
		bytes.append_array(PackedFloat32Array([axis.x, axis.y, axis.z, 0.0]).to_byte_array())
	bytes.append_array(PackedFloat32Array([transform.origin.x, transform.origin.y, transform.origin.z, 1.0]).to_byte_array())

func _ensure_white_ao(state: Dictionary) -> RID:
	var texture: RID = state.get("white_ao", RID())
	if texture.is_valid() and rd.texture_is_valid(texture):
		return texture
	var format := RDTextureFormat.new()
	format.width = 1
	format.height = 1
	format.format = RenderingDevice.DATA_FORMAT_R16_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	texture = rd.texture_create(format, RDTextureView.new(), [PackedByteArray([0, 0x3c])])
	if texture.is_valid():
		state.white_ao = texture
		state.owned.append(texture)
		state.cache_bytes = int(state.get("cache_bytes", 0)) + 2
		resource_revision += 1
	return texture

func _state_key(snapshot: Dictionary) -> String:
	var cache_key := str(snapshot.get("cache_key", ""))
	var world_id := int(snapshot.get("world_id", 0))
	return "%d/%s" % [world_id, cache_key] if world_id != 0 and not cache_key.is_empty() else ""

func _get_scene_gpu_script() -> Script:
	if not _scene_gpu_script_checked:
		_scene_gpu_script_checked = true
		if ResourceLoader.exists(SCENE_GPU_PATH):
			var loaded: Variant = load(SCENE_GPU_PATH)
			if loaded is Script:
				_scene_gpu_script = loaded
	return _scene_gpu_script

func _next_power_of_two(value: int) -> int:
	var result := 1
	while result < value:
		result <<= 1
	return result

func _finite_range(value: Variant, fallback: float, minimum: float, maximum: float) -> float:
	var number := float(value)
	return clampf(number, minimum, maximum) if is_finite(number) else fallback

func _snapshot_failure(snapshot: Dictionary) -> String:
	var reasons: Array = snapshot.get("unsupported_reasons", [])
	return str(reasons[0]) if not reasons.is_empty() else "Surfel geometry snapshot is not ready"

func _unique_rids(values: Array) -> Array[RID]:
	var result: Array[RID] = []
	var seen: Dictionary = {}
	for value in values:
		if value is RID and value.is_valid() and not seen.has(value):
			seen[value] = true
			result.append(value)
	return result

func _reversed_rids(values: Array) -> Array[RID]:
	var result: Array[RID] = []
	for index in range(values.size() - 1, -1, -1):
		var value: Variant = values[index]
		if value is RID:
			result.append(value)
	return result

func _free_rids(values: Array) -> void:
	if rd == null:
		return
	var seen: Dictionary = {}
	for index in range(values.size() - 1, -1, -1):
		var rid: Variant = values[index]
		if rid is RID and rid.is_valid() and not seen.has(rid):
			seen[rid] = true
			rd.free_rid(rid)

func _fail(message: String) -> bool:
	error = message
	return false
