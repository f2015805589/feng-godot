extends SceneTree
## Run headlessly for the native packet contract, or add -- --gpu for RD ownership.

const CloudGPU = preload("res://addons/feng-cloud/feng_cloud_gpu.gd")
var failures := 0
var gpu_done := Semaphore.new()
var passes: Array[FengVolumetricCloudPass] = []
var pass_textures: Array[RID] = []


func require(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error("REGRESSION: " + message)


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var ctx := FRPPassContext.new()
	var optical := RenderingServer.texture_2d_placeholder_create()
	var multiple := RenderingServer.texture_2d_placeholder_create()
	var packet := PackedFloat32Array()
	packet.resize(64)
	ctx.set_atmosphere_parameters(packet, RID(), RID(), optical, multiple)
	require(ctx.get_atmosphere_optical_texture() == optical, "Optical LUT lost at the native zero-argument getter")
	require(ctx.get_atmosphere_multiple_texture() == multiple, "Multiple-scattering LUT lost at the native zero-argument getter")
	ctx.set_atmosphere_parameters(PackedFloat32Array(), RID(), RID(), RID(), RID())
	require(not ctx.get_atmosphere_optical_texture().is_valid() and not ctx.get_atmosphere_multiple_texture().is_valid(), "Clearing atmosphere retained a borrowed LUT")
	RenderingServer.free_rid(optical)
	RenderingServer.free_rid(multiple)
	if "--gpu" in OS.get_cmdline_user_args():
		passes.assign([FengCloudShadowPass.new(), FengCloudTracePass.new()])
		RenderingServer.call_on_render_thread(run_gpu)
		gpu_done.wait()
		passes.clear()
		RenderingServer.call_on_render_thread(check_destructors)
		gpu_done.wait()
	print("CLOUD CONTRACT PASS" if failures == 0 else "CLOUD CONTRACT FAIL")
	quit(0 if failures == 0 else 1)


func run_gpu() -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		require(false, "GPU checks require a RenderingDevice renderer")
		gpu_done.post()
		return
	var gpu := CloudGPU.new()
	require(gpu._ensure_neutral_resources(rd), "Neutral texture allocation failed")
	var neutral: RID = gpu._neutral_lut
	var buffers := RenderSceneBuffersRD.new()
	var other := RenderSceneBuffersRD.new()
	var state: Dictionary = gpu._ensure_buffer_state(buffers, rd, 101, Vector2i(16, 16), 2, 0, false)
	var original: RID = state.trace_radiance
	require(gpu._buffer_state_textures_valid(buffers, rd, state, 0), "Stereo mode-0 textures are incomplete")
	buffers.clear_context(state.scope)
	state = gpu._ensure_buffer_state(buffers, rd, 101, Vector2i(16, 16), 2, 0, false)
	require(state.trace_radiance != original and gpu._buffer_state_textures_valid(buffers, rd, state, 0), "Cleared named textures were not rebuilt")
	state = gpu._ensure_buffer_state(buffers, rd, 101, Vector2i(16, 16), 2, 2, false)
	require(state.full_secondary_radiance.is_empty() and gpu._buffer_state_textures_valid(buffers, rd, state, 2), "Mode-2 retained mode-0 secondary textures")
	var other_state: Dictionary = gpu._ensure_buffer_state(other, rd, 102, Vector2i(8, 8), 1, 3, false)
	gpu._release_buffer(buffers, rd)
	gpu._release_idle_resources(rd)
	require(rd.texture_is_valid(neutral) and gpu._buffers.size() == 1, "Releasing one view destroyed another view's resources")
	var ubo_state := {"ubos": {}}
	var floats := PackedFloat32Array([1.0, 2.0, 3.0, 4.0])
	require(gpu._update_ubo(ubo_state, "test", floats, 16, rd, true), "Cached UBO creation failed")
	require(gpu._update_ubo_bytes(ubo_state, "test", PackedFloat32Array([5.0, 6.0, 7.0, 8.0]).to_byte_array(), 16, rd), "Byte UBO update failed")
	require(gpu._update_ubo(ubo_state, "test", floats, 16, rd, true), "Float UBO update after byte write failed")
	require(rd.buffer_get_data(ubo_state.test).to_float32_array() == floats, "Byte write left a stale float UBO cache")
	gpu._free_state_buffers(ubo_state, rd)
	for filename in ["cloud_trace.glslinc", "cloud_reconstruct.glslinc", "cloud_composite.glslinc", "cloud_shadow.glslinc", "cloud_shadow_filter.glslinc", "cloud_ao.glslinc", "cloud_ao_filter.glslinc", "cloud_sky_ambient.glslinc"]:
		require(not gpu._ensure_pipeline(rd, filename).is_empty(), "Cloud shader failed: " + filename)
	for filename in ["cloud_trace.glslinc", "cloud_reconstruct.glslinc", "cloud_composite.glslinc"]:
		require(not gpu._ensure_pipeline(rd, filename, {"FENG_CLOUD_VRT_SECONDARY": 1}).is_empty(), "Secondary cloud shader failed: " + filename)
	var kernel := FileAccess.get_file_as_string(FengCloudMaterial.DEFAULT_UE58_KERNEL_SOURCE_PATH)
	for filename in ["cloud_trace.glslinc", "cloud_shadow.glslinc", "cloud_ao.glslinc"]:
		require(not gpu._ensure_pipeline(rd, filename, {"FENG_CLOUD_UE58_LAYOUT_INPUTS": 1}, kernel).is_empty(), "UE cloud shader failed: " + filename)
	var packets := {}
	for layout in [["material", 76], ["lighting", 48], ["atmosphere", 64], ["fog", 28], ["native_shadow", 156]]:
		var values := PackedFloat32Array()
		values.resize(layout[1])
		packets[layout[0]] = values
	require(gpu._update_shared_ubos(other_state, rd, packets), "Ambient UBOs failed")
	require(gpu._dispatch_ambient(FRPPassContext.new(), other_state, packets, rd), "Ambient dispatch failed with neutral LUTs")
	gpu.cleanup(rd)
	gpu.cleanup(rd)
	require(not rd.texture_is_valid(neutral) and gpu.take_cleanup_payload().rids.is_empty(), "GPU cleanup was not complete and idempotent")
	for resource in passes:
		require(resource._cloud_gpu._ensure_neutral_resources(rd), "Pass-owned neutral texture allocation failed")
		pass_textures.append(resource._cloud_gpu._neutral_lut)
	gpu_done.post()


func check_destructors() -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd != null:
		for texture in pass_textures:
			require(not rd.texture_is_valid(texture), "Inherited cloud pass destructor retained a texture")
	gpu_done.post()
