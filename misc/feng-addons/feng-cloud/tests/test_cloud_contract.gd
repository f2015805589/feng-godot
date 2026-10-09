extends SceneTree
## Run headlessly for the native packet contract, or add -- --gpu for RD ownership.

const CloudGPU = preload("res://addons/feng-cloud/feng_cloud_gpu.gd")
const HeightFogPassScript = preload("res://addons/feng-render-pipeline/passes/height_fog_pass.gd")

class OwnedPass extends FengPass:
	var owned := RID()
	var borrowed := RID()
	func _setup(rd: RenderingDevice) -> void:
		var format := RDTextureFormat.new()
		format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
		format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		owned = rd.texture_create(format, RDTextureView.new())
	func _take_owned_rids() -> Array[RID]:
		var rids := super._take_owned_rids()
		rids.append(owned)
		owned = RID()
		return rids

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
var custom_pass: OwnedPass
var borrowed_texture := RID()


func require(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error("REGRESSION: " + message)


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	test_registry_and_material()
	test_atmosphere_sources()
	test_cloud_fog_view_depth()
	test_cloud_volume_composition_shader_assembly()
	test_cloud_volume_composition_revision_domains()
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
		custom_pass = OwnedPass.new()
		RenderingServer.call_on_render_thread(run_gpu)
		gpu_done.wait()
		passes.clear()
		var reference := weakref(custom_pass)
		custom_pass = null
		require(reference.get_ref() == null, "Cleanup retained the dying custom pass")
		RenderingServer.call_on_render_thread(check_destructors)
		gpu_done.wait()
	print("CLOUD CONTRACT PASS" if failures == 0 else "CLOUD CONTRACT FAIL")
	quit(0 if failures == 0 else 1)


func test_cloud_fog_view_depth() -> void:
	var perspective_ray := Vector3(0.8, 0.3, -1.0).normalized()
	var perspective_distance := 120.0
	var perspective_point := perspective_ray * perspective_distance
	var perspective_view_depth := maxf(-perspective_point.z, 0.0)
	require(perspective_view_depth < perspective_distance
		and is_equal_approx(perspective_view_depth, -perspective_ray.z * perspective_distance),
		"Off-axis cloud tAP distance must be converted to camera view depth before froxel-Z sampling")
	var orthographic_near_origin := Vector3(0.0, 0.0, -0.2)
	var orthographic_direction := Vector3(0.0, 0.0, -1.0)
	var orthographic_ray_distance := 45.0
	var orthographic_point := orthographic_near_origin \
			+ orthographic_direction * orthographic_ray_distance
	var orthographic_view_depth := maxf(-orthographic_point.z, 0.0)
	require(is_equal_approx(orthographic_view_depth, 45.2),
		"Orthographic cloud distance must retain the near-plane origin offset")
	var shader := FileAccess.get_file_as_string(
			"res://addons/feng-cloud/shaders/cloud_composite.glslinc")
	require(shader.contains("cloud_frame.world_to_view * vec4(representative_world, 1.0)")
		and shader.contains("feng_cloud_sample_integrated_volume(uv, cloud_view_depth_m"),
		"Cloud volume sampling must use the ray representative's reconstructed view-Z")


func test_cloud_volume_composition_shader_assembly() -> void:
	var gpu := CloudGPU.new()
	var path := "res://addons/feng-cloud/shaders/cloud_composite.glslinc"
	var loader_source := FileAccess.get_file_as_string("res://addons/feng-cloud/feng_cloud_gpu.gd")
	require(loader_source.contains("source_text = _assemble_shader_source(source_text, defines)"),
		"Pipeline compilation must use the source assembly path exercised by this CPU gate")
	var expanded := gpu._expand_shader(path, 0)
	require(not expanded.is_empty(), "Cloud composite source and includes must expand through the runtime loader")
	for deferred in [0, 1]:
		var assembled := gpu._assemble_shader_source(expanded, {
			"FENG_CLOUD_VOLUME_DEFERRED": deferred,
			"FENG_CLOUD_VRT_SECONDARY": 0,
		})
		require(not assembled.is_empty(), "Cloud composite assembly failed for deferred mode %d" % deferred)
		require(assembled.contains("#define FENG_CLOUD_VOLUME_DEFERRED %d" % deferred)
			and not assembled.contains("#include"),
			"Cloud composite assembly must inject mode defines after expanding includes")
		require(assembled.contains("#if FENG_CLOUD_VOLUME_DEFERRED\nFENG_CLOUD_DECLARE_VOLUME_COMPOSITION_OUTPUTS;\n#endif"),
			"Volume output declaration must be preprocessor guarded in both assembly modes")
	var main_start := expanded.find("void main()")
	var bounds_end := expanded.find("\n\t}\n", expanded.find("if (any(greaterThanEqual(pixel, output_size))", main_start))
	var uv_declaration := expanded.find("vec2 uv = (vec2(pixel) + vec2(0.5)) / vec2(max(output_size, ivec2(1)));", main_start)
	var first_apply := expanded.find("feng_cloud_apply_volume_at_depth(tap_radiance", main_start)
	var second_apply := expanded.find("feng_cloud_apply_volume_at_depth(cloud_radiance", main_start)
	require(main_start >= 0 and bounds_end > main_start and uv_declaration > bounds_end
		and first_apply > uv_declaration and second_apply > uv_declaration,
		"Main composite must define viewport-local UV after bounds validation and before both volume samples")


func test_cloud_volume_composition_revision_domains() -> void:
	var context := FRPPassContext.new()
	var native_signature := 0x19283746
	var gpu_signature := 0x56473829
	var cloud_packet := PackedFloat32Array()
	cloud_packet.resize(76)
	context.set_cloud_snapshot(cloud_packet, RID(), RID(), RID(), RID(),
			RID(), RID(), native_signature)
	var gpu := CloudGPU.new()
	var native_identity: Dictionary = gpu._read_native_cloud_snapshot_signature(context)
	require(bool(native_identity.get("valid", false))
		and int(native_identity.get("signature", 0)) == native_signature,
		"Cloud sidecar publisher must read the exact signature of the current native snapshot")
	var metadata := {
		"native_snapshot_source_signature": native_signature,
		"gpu_source_signature": gpu_signature,
		"frame_generation": 17,
		"buffer_id": 91,
		"view_count": 2,
		"internal_size": Vector2i(641, 359),
	}
	require(gpu_signature != native_signature
		and HeightFogPassScript.cloud_composition_metadata_matches_current_frame(
			context, metadata, 17, 91, 2, Vector2i(641, 359)),
		"A current sidecar must validate against native snapshot identity, independently of the GPU cache signature")
	var mismatch := metadata.duplicate()
	mismatch["native_snapshot_source_signature"] = native_signature + 1
	require(not HeightFogPassScript.cloud_composition_metadata_matches_current_frame(
			context, mismatch, 17, 91, 2, Vector2i(641, 359)),
		"A sidecar from a different native snapshot must be rejected")
	for field in ["frame_generation", "buffer_id", "view_count", "internal_size"]:
		mismatch = metadata.duplicate()
		match field:
			"frame_generation": mismatch[field] = 18
			"buffer_id": mismatch[field] = 92
			"view_count": mismatch[field] = 1
			"internal_size": mismatch[field] = Vector2i(640, 359)
		require(not HeightFogPassScript.cloud_composition_metadata_matches_current_frame(
				context, mismatch, 17, 91, 2, Vector2i(641, 359)),
			"A sidecar with mismatched %s must be rejected" % field)
	context.set_cloud_snapshot(cloud_packet, RID(), RID(), RID(), RID(),
			RID(), RID(), native_signature + 2)
	require(not HeightFogPassScript.cloud_composition_metadata_matches_current_frame(
			context, metadata, 17, 91, 2, Vector2i(641, 359)),
		"A sidecar from the previous native cloud snapshot must be rejected")
	context.clear_cloud_snapshot()
	require(not HeightFogPassScript.cloud_composition_metadata_matches_current_frame(
			context, metadata, 17, 91, 2, Vector2i(641, 359))
		and not bool(gpu._read_native_cloud_snapshot_signature(context).get("valid", false)),
		"Clearing the native cloud snapshot must invalidate its sidecar and publisher identity")
	require(not HeightFogPassScript.cloud_composition_metadata_matches_current_frame(
			RefCounted.new(), metadata, 17, 91, 2, Vector2i(641, 359))
		and not bool(gpu._read_native_cloud_snapshot_signature(RefCounted.new()).get("valid", false)),
		"Unsupported contexts must fail closed without calling missing native getters")


func test_atmosphere_sources() -> void:
	var viewport := SubViewport.new()
	viewport.world_3d = World3D.new()
	root.add_child(viewport)
	var world := viewport.world_3d
	var primary := DirectionalLight3D.new()
	primary.rotation_degrees.x = -35.5
	viewport.add_child(primary)
	var secondary := DirectionalLight3D.new()
	secondary.rotation_degrees.x = -15.25
	viewport.add_child(secondary)
	var sky := FengSkyAtmosphere.new()
	sky.sun_light = primary
	sky.secondary_sun_light = secondary
	viewport.add_child(sky)
	sky._process(0.0)
	var cloud := FengVolumetricCloud.new()
	viewport.add_child(cloud)
	var source := sky.rendering_snapshot(world)
	for selected in [null, sky]:
		cloud.planet_source = selected
		var snapshot := cloud._build_snapshot(world)
		snapshot["atmosphere_snapshot"]["render_targets"] = []
		require(snapshot["atmosphere_snapshot"] == source and snapshot["sun_inputs"] == cloud._resolve_sun_inputs(source),
			"Automatic, explicit and direct consumers must share Sky's source schema")
	require(source["optical_column_lut"] != null and source["multi_scattering_lut"] != null,
		"Current supported atmosphere tables must remain leased by the snapshot")
	var cache_misses: int = sky.atmosphere_cache_stats()["cache_misses"]
	for index in 5:
		sky.rendering_snapshot(world)
	require(sky.atmosphere_cache_stats()["cache_misses"] == cache_misses,
		"Consumer snapshots must not integrate ambient radiance")
	for elevation in [-20.0, -0.1, 0.0, 0.1, 35.5, 90.0]:
		var angle := deg_to_rad(elevation)
		var direction := Vector3(cos(angle), sin(angle), 0.0)
		var expected: Vector3 = sky._ambient_entry_for_sun(direction, false)["ground_transmittance"]
		require((sky._ambient_entry_for_sun(direction, false, true)["ground_transmittance"] as Vector3).is_equal_approx(expected),
			"Published ground transport must preserve ambient-cache interpolation and horizon clipping")
	var radius: float = source["settings"]["planet_radius_km"]
	source["settings"]["planet_radius_km"] = 1.0
	source["optical_lut_revision"].clear()
	var reread := sky.rendering_snapshot(world)
	require(reread["settings"]["planet_radius_km"] == radius \
			and not reread["optical_lut_revision"].is_empty(),
		"Direct consumer reads must not mutate provider settings or revision arrays")
	require(cloud._snapshot_signature() == cloud._snapshot_signature(),
		"Unchanged atmosphere snapshots must preserve cloud cache identity")
	if primary.get_base().is_valid(): # Native light RIDs are absent in the headless dummy renderer.
		var override_sun := DirectionalLight3D.new()
		viewport.add_child(override_sun)
		for light in [override_sun, primary]:
			cloud.primary_sun = light
			var expected: Vector3 = reread["sun_ground_transmittance"] if light == primary else Vector3.ONE
			require(cloud._build_snapshot(world)["sun_inputs"][0]["ground_transmittance"] == expected,
				"Only a matching cloud sun may receive atmospheric ground transmittance")
		cloud.primary_sun = null
		primary.hide()
		sky._process(0.0)
		var secondary_only := cloud._build_snapshot(world)
		require(secondary_only["sun_inputs"][0].is_empty() \
				and secondary_only["sun_inputs"][1]["light_rid"] == secondary.get_base(),
			"A secondary-only atmosphere must retain its cloud sun slot")
		primary.show()
		sky._process(0.0)

	# Explicit same-world sources remain usable without owning the Environment.
	world.environment = Environment.new()
	sky._process(0.0)
	cloud.planet_source = null
	require(cloud._build_snapshot(world)["atmosphere_snapshot"].is_empty(),
		"An automatic cloud source must stop when the atmosphere loses world ownership")
	cloud.planet_source = sky
	var inactive := cloud._build_snapshot(world)
	require(inactive["planet_source_id"] == sky.get_instance_id() \
			and inactive["atmosphere_snapshot"]["sun_light_instance_id"] == primary.get_instance_id(),
		"An explicit inactive same-world source must retain its optics and authored suns")
	primary.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	require(cloud._build_snapshot(world)["atmosphere_snapshot"]["sun_light_instance_id"] == primary.get_instance_id(),
		"Explicit inactive source selection must retain Light Only compatibility")
	primary.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_AND_SKY
	var prior_settings: Dictionary = inactive["atmosphere_snapshot"]["settings"].duplicate(true)
	sky.rayleigh_exponential_distribution += 0.5
	var changed := cloud._build_snapshot(world)
	require(changed["atmosphere_revision"] > inactive["atmosphere_revision"],
		"Inactive source edits must advance the consumer revision")
	require(changed["atmosphere_snapshot"]["optical_column_lut"] == null \
			and changed["atmosphere_snapshot"]["multi_scattering_lut"] == null,
		"Changed inactive optics must not lease stale shader tables")
	require(inactive["atmosphere_snapshot"]["settings"] == prior_settings,
		"Changing source settings must not mutate an earlier cloud snapshot")
	world.environment = sky.environment
	sky._process(0.0)
	require(cloud._build_snapshot(world)["atmosphere_snapshot"]["optical_column_lut"] != null,
		"Restoring the provider must publish rebuilt supported tables")
	sky.mie_exponential_distribution = 0.001
	sky._process(0.0)
	require(cloud._build_snapshot(world)["atmosphere_snapshot"]["optical_column_lut"] == null,
		"Unsupported thin profiles must retain exact transport without an optical LUT")

	var foreign := SubViewport.new()
	foreign.world_3d = World3D.new()
	root.add_child(foreign)
	sky.reparent(foreign)
	require(sky.rendering_snapshot(world).is_empty(), "A source must reject foreign-world reads")
	var fallback := cloud._build_snapshot(world)
	require(fallback["atmosphere_snapshot"].is_empty() and fallback["planet_source_id"] == 0 \
			and fallback["planet_radius_m"] == cloud.planet_radius_km * 1000.0,
		"An explicit foreign-world source must preserve authored planet fallback")
	sky.free()
	cloud.planet_source = null
	require(cloud._build_snapshot(world)["atmosphere_snapshot"].is_empty(),
		"Removing a provider must clear its consumer publication")
	var late_sky := FengSkyAtmosphere.new()
	late_sky.multi_scattering_factor = 0.0
	viewport.add_child(late_sky)
	late_sky._process(0.0)
	require(cloud._build_snapshot(world)["planet_source_id"] == late_sky.get_instance_id(),
		"A later atmosphere provider must be picked up without reloading the cloud")
	viewport.free()
	foreign.free()


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
	# The fixture owns the first texture; the pass borrows it and owns the next.
	custom_pass._setup(rd)
	borrowed_texture = custom_pass.owned
	custom_pass.borrowed = borrowed_texture
	custom_pass._setup(rd)
	var owned := custom_pass.owned
	require(rd.texture_is_valid(owned), "Custom pass texture allocation failed")
	custom_pass._setup_complete = true
	custom_pass._cleanup(rd)
	custom_pass._cleanup(rd)
	require(not rd.texture_is_valid(owned) and not custom_pass.owned.is_valid() and not custom_pass._setup_complete, "Custom pass cleanup must drain ownership and permit setup again")
	require(rd.texture_is_valid(borrowed_texture), "Explicit cleanup freed a borrowed texture")
	custom_pass._setup(rd)
	require(rd.texture_is_valid(custom_pass.owned), "Custom pass could not allocate after cleanup")
	pass_textures.append(custom_pass.owned)
	gpu_done.post()


func check_destructors() -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd != null:
		for texture in pass_textures:
			require(not rd.texture_is_valid(texture), "Pass destructor retained an owned texture")
		require(rd.texture_is_valid(borrowed_texture), "Deferred destruction freed a borrowed texture")
		rd.free_rid(borrowed_texture)
	gpu_done.post()
