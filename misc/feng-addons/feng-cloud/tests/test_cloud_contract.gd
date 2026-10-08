extends SceneTree
## Run headlessly for the native packet contract, or add -- --gpu for RD ownership.

const CloudGPU = preload("res://addons/feng-cloud/feng_cloud_gpu.gd")

class FaultCloudGPU extends CloudGPU:
	var remaining_allocations := -1

	func _create_named_texture(buffers: RenderSceneBuffersRD, state: Dictionary, name: String,
			format: int, size: Vector2i, layers: int, array_texture: bool, rd: RenderingDevice,
			scope_override: StringName = &"") -> bool:
		if remaining_allocations == 0:
			remaining_allocations = -1
			return false
		if remaining_allocations > 0:
			remaining_allocations -= 1
		return super._create_named_texture(buffers, state, name, format, size, layers, array_texture, rd, scope_override)

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
	test_registry_and_material()
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


func test_registry_and_material() -> void:
	var texture := GradientTexture2D.new()
	var material := FengCloudMaterial.new()
	material.weather_texture = texture
	material.layout_cloud_mask_texture = texture
	var revision := material.get_revision()
	texture.emit_changed()
	require(material.get_revision() == revision + 1, "Shared texture changes must touch its material exactly once")
	material.weather_texture = null
	revision = material.get_revision()
	texture.emit_changed()
	require(material.get_revision() == revision + 1, "Removing one texture input disconnected another input")
	var copy := material.duplicate() as FengCloudMaterial
	material.layout_cloud_mask_texture = null
	revision = material.get_revision()
	var copy_revision := copy.get_revision()
	texture.emit_changed()
	require(material.get_revision() == revision and copy.get_revision() == copy_revision + 1, "Texture subscriptions did not follow independent material ownership")
	copy.layout_cloud_mask_texture = null
	copy_revision = copy.get_revision()
	texture.emit_changed()
	require(copy.get_revision() == copy_revision, "Removing the final texture input retained its subscription")
	var viewport := SubViewport.new()
	viewport.world_3d = World3D.new()
	root.add_child(viewport)
	var older := FengVolumetricCloud.new()
	var newer := FengVolumetricCloud.new()
	viewport.add_child(older)
	viewport.add_child(newer)
	var runtime := FengCloudRuntime
	var world_id := viewport.world_3d.get_instance_id()
	runtime.register_cloud(older, viewport.world_3d)
	require(runtime.snapshot_for_world(world_id).get("provider_id") == newer.get_instance_id(), "Repeated registration reordered cloud precedence")
	var input := {"provider_id": newer.get_instance_id(), "nested": {"value": 7}}
	runtime.publish_cloud(newer, world_id, input)
	input["nested"]["value"] = 0
	var published := runtime.snapshot_for_world(world_id)
	require(published["nested"]["value"] == 7, "Cloud publication borrowed mutable input")
	published["nested"].clear()
	var rendered := runtime.snapshots()
	require(rendered.size() == 1 and rendered[0]["nested"].get("value") == 7, "Main-thread cloud reads mutated render publication")
	rendered[0]["nested"].clear()
	require(runtime.snapshot_for_world(world_id)["nested"].get("value") == 7, "Render snapshot reads mutated stored cloud state")
	newer.enabled = false
	require(runtime.snapshot_for_world(world_id).get("provider_id") == older.get_instance_id(), "Disabling newest cloud did not restore its predecessor")
	newer.enabled = true
	require(runtime.snapshot_for_world(world_id).get("provider_id") == newer.get_instance_id(), "Re-enabled cloud did not regain newest registration")
	viewport.free()
	require(runtime.snapshot_for_world(world_id).is_empty() and runtime.snapshots().is_empty(), "World removal retained a cloud publication")


func run_gpu() -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		require(false, "GPU checks require a RenderingDevice renderer")
		gpu_done.post()
		return
	var fault := FaultCloudGPU.new()
	for allocation in 16: # Five stereo channels, two history banks, one ambient texture.
		var retry_buffers := RenderSceneBuffersRD.new()
		fault.remaining_allocations = allocation
		require(fault._ensure_buffer_state(retry_buffers, rd, 103, Vector2i(17, 19), 2, 0, false).is_empty(), "Texture allocation failure did not abort the state")
		var retry := fault._ensure_buffer_state(retry_buffers, rd, 103, Vector2i(17, 19), 2, 0, false)
		require(not retry.is_empty() and fault._buffer_state_textures_valid(retry_buffers, rd, retry, 0), "Partial texture state did not rebuild after allocation failure")
		fault.cleanup(rd)
		fault.cleanup(rd)

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
	state = gpu._ensure_buffer_state(buffers, rd, 101, Vector2i(17, 19), 2, 1, false)
	require(state.trace_size == Vector2i(9, 10) and state.full_radiance.is_empty() and gpu._buffer_state_textures_valid(buffers, rd, state, 1), "Resized mode-1 retained temporal textures or used the wrong ceil size")
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
