extends SceneTree
## CPU-only tests for the LightmapGI capture-probe adapter.

const BakedVolume = preload("res://addons/feng-fog/rendering/baked_lighting/fog_baked_lighting_volume.gd")
const BakedProvider = preload("res://addons/feng-fog/rendering/baked_lighting/fog_baked_lighting_provider.gd")
const EMPTY_BSP_LEAF := -2147483648

var _checks := 0
var _failures := 0
var _changed_signal_count := 0


func _initialize() -> void:
	call_deferred("_run")


func _require(p_condition: bool, p_message: String) -> void:
	_checks += 1
	if not p_condition:
		_failures += 1
		push_error("REGRESSION: " + p_message)


func _float_bits(p_value: float) -> int:
	return PackedFloat32Array([p_value]).to_byte_array().decode_s32(0)


func _all_zero(p_values: PackedFloat32Array) -> bool:
	for value in p_values:
		if value != 0.0:
			return false
	return true


func _record_changed_signal() -> void:
	_changed_signal_count += 1


func _run() -> void:
	var sampling_shader := FileAccess.get_file_as_string(
			"res://addons/feng-fog/rendering/baked_lighting/fog_baked_lighting_sampling.glslinc")
	_require(sampling_shader.contains("ffog_sample_baked_probe_volume_ue_two_band")
			and sampling_shader.contains("p_world_position, p_world_camera_vector, p_g, 2u")
			and sampling_shader.contains("p_world_position, p_world_camera_vector, p_g, 1u"),
			"GPU include keeps generic SH9 and exposes UE two-band sampling through one common path")
	var positions := PackedVector3Array([
		Vector3.ZERO,
		Vector3.RIGHT,
		Vector3.UP,
		Vector3.BACK,
	])
	var sh := PackedColorArray()
	for probe in positions.size():
		for _coefficient in 9:
			var value := float(probe + 1)
			sh.append(Color(value, value, value, 0.0))
	var bsp := PackedInt32Array([
		_float_bits(0.0), _float_bits(0.0), _float_bits(1.0), _float_bits(0.1),
		-1, EMPTY_BSP_LEAF,
	])
	var source := LightmapGIData.new()
	var source_data := {
		"bounds": AABB(Vector3.ZERO, Vector3.ONE),
		"points": positions,
		"sh": sh,
		"tetrahedra": PackedInt32Array([0, 1, 2, 3]),
		"bsp": bsp,
		"interior": true,
		"baked_exposure": 2.0,
		"lightprobe_hash": 73,
	}
	source.probe_data = source_data
	var capture_transform := Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(12.0, 4.0, -3.0))
	var volume = BakedVolume.new()
	var property_names: Array[StringName] = []
	for property in volume.get_property_list():
		property_names.append(property.name)
	_require(property_names.has(&"source_lightmap_gi_data")
			and property_names.has(&"source_capture_transform")
			and property_names.has(&"refresh_import_action")
			and volume.refresh_import_action.is_valid(),
			"resource Inspector exposes a selected LightmapGIData, staged transform, and live tool button")
	var initial_revision := int(volume.revision)
	volume.source_lightmap_gi_data = source
	volume.source_capture_transform = capture_transform
	_require(int(volume.revision) == initial_revision
			and volume.probe_positions.is_empty()
			and volume.capture_transform == Transform3D.IDENTITY,
			"staging source fields does not mutate the serialized active v1 payload")
	var renderer_payload: Dictionary = source.get("probe_data")
	if renderer_payload.get("points", PackedVector3Array()).size() == positions.size():
		var staged_import: Dictionary = volume.refresh_from_selected_source()
		_require(bool(staged_import.get("valid", false))
				and bool(staged_import.get("changed", false))
				and volume.capture_transform == capture_transform,
				"tool refresh imports a valid LightmapGIData and its capture transform")
	else:
		print("SKIP LightmapGIData RS roundtrip: headless dummy storage does not retain probe capture data")
		var failed_staged_import: Dictionary = volume.refresh_from_selected_source()
		_require(not bool(failed_staged_import.get("valid", true))
				and not String(failed_staged_import.get("reason", "")).is_empty()
				and int(volume.revision) == initial_revision
				and volume.capture_transform == Transform3D.IDENTITY,
			"failed staged import reports a reason and leaves the active payload untouched")
	var staged_fixture = BakedVolume.new()
	staged_fixture.changed.connect(_record_changed_signal)
	var staged_fixture_import: Dictionary = staged_fixture.call(
			"_stage_and_import_capture_data", source_data, capture_transform)
	_require(bool(staged_fixture_import.get("valid", false))
			and bool(staged_fixture_import.get("changed", false))
			and int(staged_fixture.revision) == 1
			and staged_fixture.capture_transform == capture_transform,
			"valid staged capture commits the active payload and transform in one revision")
	_require(_changed_signal_count == 1,
			"successful staged capture emits one changed signal for the atomic commit (got %d)" % _changed_signal_count)
	var same_fixture_import: Dictionary = staged_fixture.call(
			"_stage_and_import_capture_data", source_data, capture_transform)
	_require(bool(same_fixture_import.get("valid", false))
			and not bool(same_fixture_import.get("changed", true))
			and int(staged_fixture.revision) == 1
			and _changed_signal_count == 1,
			"identical staged data does not re-emit changed or churn the revision (got %d)" % _changed_signal_count)
	_require(volume.capture_probe_data(source_data, capture_transform), "probe dictionary fixture validates")
	_require(volume.is_valid(), "captured payload remains valid")
	var invalid_node := LightmapGI.new()
	get_root().add_child(invalid_node)
	var before_invalid_node_revision := int(volume.revision)
	var invalid_node_result: Dictionary = volume.capture_lightmap_gi_node(invalid_node)
	_require(not bool(invalid_node_result.get("valid", true))
			and not String(invalid_node_result.get("reason", "")).is_empty()
			and int(volume.revision) == before_invalid_node_revision
			and volume.is_valid(),
			"node import without LightmapGIData reports a reason and preserves the active payload")
	invalid_node.queue_free()
	if renderer_payload.get("points", PackedVector3Array()).size() == positions.size():
		var lightmap_node := LightmapGI.new()
		get_root().add_child(lightmap_node)
		lightmap_node.light_data = source
		lightmap_node.transform = Transform3D(Basis(Vector3.UP, PI * 0.25), Vector3(3.0, 5.0, -7.0))
		var node_transform := lightmap_node.global_transform
		var before_node_import_revision := int(volume.revision)
		var node_import: Dictionary = volume.capture_lightmap_gi_node(lightmap_node)
		_require(bool(node_import.get("valid", false))
				and bool(node_import.get("changed", false))
				and volume.capture_transform == node_transform
				and int(volume.revision) == before_node_import_revision + 1,
			"LightmapGI node helper imports light_data and global_transform atomically once")
		var same_node_import: Dictionary = volume.capture_lightmap_gi_node(lightmap_node)
		_require(bool(same_node_import.get("valid", false))
				and not bool(same_node_import.get("changed", true))
				and int(volume.revision) == before_node_import_revision + 1,
			"reimporting identical probes and transform does not churn the revision/cache")
		lightmap_node.queue_free()
	var payload: Dictionary = volume.get_gpu_payload()
	_require(payload.get("coordinate_space") == "lightmap_capture", "GPU payload declares capture coordinate space")
	_require(payload.get("capture_transform") == capture_transform, "GPU payload carries capture transform")
	_require(payload.get("probe_positions").size() == 4, "GPU payload keeps all four probes")
	_require(payload.get("probe_sh").size() == 4 * 9 * 3, "GPU payload packs RGB SH9 per probe")
	_require(payload.get("coefficient_domain") == "godot_lightmapper_incident_radiance_real_sh9_scaled_by_1_over_pi",
			"payload records LightmapperRD's incident-radiance SH scale")
	_require(is_equal_approx(float(payload.get("coefficient_to_physical_radiance_scale")), PI),
			"payload publishes the single PI conversion back to physical radiance")
	_require(payload.get("source_lightprobe_hash") == 73, "GPU payload carries source probe hash")
	_require(int(payload.get("source_revision", 0)) != 0, "GPU payload carries source data revision")
	_require(is_equal_approx(float(payload.get("baked_exposure")), 2.0), "GPU payload preserves baked exposure")
	_require(bool(payload.get("contains_surface_direct_radiance")), "payload marks direct-lit surface radiance")
	_require(payload.get("baked_direct_semantics", "").contains("no direct-at-probe term")
			and not bool(payload.get("includes_probe_origin_direct_lighting", true))
			and not bool(payload.get("suppresses_live_direct_lighting", true)),
			"valid probes do not suppress distinct live direct volume scattering")
	_require(payload.get("bake_mode") == "lightmapgi_capture_probes", "payload declares LightmapGI probe mode")
	_require(bool(payload.get("includes_environment_radiance", false)),
			"environment radiance defaults to conservative baked-source inclusion")
	var first_revision := int(volume.revision)
	volume.includes_environment_radiance = false
	var no_environment_payload: Dictionary = volume.get_gpu_payload()
	_require(int(volume.revision) != first_revision
			and not bool(no_environment_payload.get("includes_environment_radiance", true)),
			"environment-source override invalidates the resource revision")
	volume.includes_environment_radiance = true
	var sky_replaced := BakedProvider.resolve_source_usage(true, true, 1.0)
	_require(bool(sky_replaced.get("apply_baked_probe_radiance"))
			and bool(sky_replaced.get("suppress_live_sky"))
			and not bool(sky_replaced.get("apply_live_sky"))
			and bool(sky_replaced.get("apply_live_direct_lights")),
			"valid environment-inclusive probes replace only live sky, never live direct lights")
	var no_suppression := BakedProvider.resolve_source_usage(true, true, 0.0)
	_require(not bool(no_suppression.get("apply_baked_probe_radiance"))
			and bool(no_suppression.get("apply_live_sky"))
			and bool(no_suppression.get("apply_live_direct_lights")),
			"zero static scattering keeps the live sky and direct lights")
	var outside_probe := BakedProvider.resolve_source_usage(false, true, 1.0)
	_require(not bool(outside_probe.get("suppress_live_sky"))
			and bool(outside_probe.get("apply_live_sky"))
			and bool(outside_probe.get("apply_live_direct_lights")),
			"invalid/outside probes keep live sky and direct lights")
	var environment_excluded := BakedProvider.resolve_source_usage(true, false, 1.0)
	_require(bool(environment_excluded.get("apply_baked_probe_radiance"))
			and not bool(environment_excluded.get("suppress_live_sky"))
			and bool(environment_excluded.get("apply_live_sky"))
			and bool(environment_excluded.get("apply_live_direct_lights")),
			"valid captures without baked environment keep live sky and direct lights")
	var provider = BakedProvider.new()
	var snapshot: Dictionary = provider.call("snapshot_for_rendering", volume)
	var snapshot_again: Dictionary = provider.call("snapshot_for_rendering", volume)
	var resource_instance_id := volume.get_instance_id()
	_require(resource_instance_id != 0
			and BakedProvider._resource_id_is_valid(resource_instance_id),
			"a real Resource instance ID is accepted regardless of its signed high-bit representation")
	_require(bool(snapshot.get("valid", false)) and int(snapshot.get("probe_count", 0)) == 4
			and int(snapshot.get("tetrahedron_count", 0)) == 1
			and int(snapshot.get("bsp_node_count", 0)) == 1,
			"provider creates a typed immutable probe snapshot")
	_require(int(snapshot.get("resource_id", 0)) == resource_instance_id
			and int(snapshot.get("snapshot_generation", -1))
			== int(snapshot_again.get("snapshot_generation", -2)),
			"provider keys the Resource snapshot cache with its real signed instance ID")
	_require(int(snapshot.get("snapshot_generation", -1))
			== int(snapshot_again.get("snapshot_generation", -2)),
			"provider reuses a snapshot for an unchanged resource revision")
	snapshot["probe_count"] = -99
	_require(int(provider.call("snapshot_for_rendering", volume).get("probe_count", 0)) == 4,
			"a caller cannot mutate the provider's cached snapshot dictionary")
	var generation_before_metadata_change := int(snapshot_again.get("snapshot_generation", -1))
	volume.includes_environment_radiance = false
	var metadata_snapshot: Dictionary = provider.call("snapshot_for_rendering", volume)
	_require(int(metadata_snapshot.get("snapshot_generation", -1)) != generation_before_metadata_change
			and not bool(metadata_snapshot.get("includes_environment_radiance", true)),
			"source metadata changes publish a new immutable GPU snapshot")
	volume.includes_environment_radiance = true
	var packed_params: PackedByteArray = provider.call("_pack_params", snapshot_again)
	_require(packed_params.size() == 176,
			"provider packs the fixed five-vec4 176-byte GPU parameter block")
	if packed_params.size() == 176:
		_require(packed_params.decode_s32(160) == 4
				and packed_params.decode_s32(164) == 1
				and packed_params.decode_s32(168) == 1
				and (packed_params.decode_s32(172) & BakedProvider.FLAG_INCLUDES_ENVIRONMENT_RADIANCE) != 0,
				"GPU params publish counts and environment source flag in the final uvec4")
	var exposure_scale := BakedProvider.scene_radiance_scale(snapshot_again,
		{"scene_normalization": 0.25, "pre_exposure": 2.0})
	_require(bool(exposure_scale.get("valid", false))
			and is_equal_approx(float(exposure_scale.get("scale", 0.0)), 0.25),
			"baked probe radiance applies scene normalization, baked exposure and pre-exposure once")
	var uniform_radiance := 2.3
	var uniform_sh := PackedFloat32Array()
	uniform_sh.resize(27)
	uniform_sh.fill(0.0)
	var uniform_l0 := 4.0 * 0.282095 * uniform_radiance
	uniform_sh[0] = uniform_l0
	uniform_sh[1] = uniform_l0
	uniform_sh[2] = uniform_l0
	for anisotropy in [0.0, 0.65]:
		var recovered := volume.evaluate_hg_incident_radiance(uniform_sh,
				Vector3(0.3, -0.4, 0.5), anisotropy)
		_require(absf(recovered.x - uniform_radiance) < 0.0001
				and absf(recovered.y - uniform_radiance) < 0.0001
				and absf(recovered.z - uniform_radiance) < 0.0001,
				"uniform incident radiance remains calibrated for HG g=%0.2f" % anisotropy)
		var recovered_ue := volume.evaluate_hg_incident_radiance_ue_two_band(uniform_sh,
				Vector3(0.3, -0.4, 0.5), anisotropy)
		_require(absf(recovered_ue.x - uniform_radiance) < 0.0001
				and absf(recovered_ue.y - uniform_radiance) < 0.0001
				and absf(recovered_ue.z - uniform_radiance) < 0.0001,
				"UE two-band uniform radiance remains calibrated for HG g=%0.2f" % anisotropy)
	var l2_only := PackedFloat32Array()
	l2_only.resize(27)
	l2_only.fill(0.0)
	l2_only[6 * 3] = 1.0
	var generic_l2 := volume.evaluate_hg_incident_radiance(l2_only, Vector3.FORWARD, 0.5)
	var ue_two_band_l2 := volume.evaluate_hg_incident_radiance_ue_two_band(
			l2_only, Vector3.FORWARD, 0.5)
	_require(generic_l2.length_squared() > 0.0 and ue_two_band_l2.is_equal_approx(Vector3.ZERO),
			"generic SH9 keeps L2 while the UE VolumetricFog SH2 entry drops it")
	var local_sample := Vector3(0.25, 0.25, 0.25)
	var world_sample := capture_transform * local_sample
	var sampled: PackedFloat32Array = volume.sample_sh9(world_sample)
	_require(bool(volume.sample_sh9_with_validity(world_sample).get("valid")), "valid probe sample is distinguished from zero radiance")
	_require(sampled.size() == 27, "CPU oracle returns SH9 RGB")
	for coefficient in 9:
		for channel in 3:
			_require(is_equal_approx(sampled[coefficient * 3 + channel], 2.5),
				"CPU oracle interpolates tetrahedral SH coefficient %d channel %d" % [coefficient, channel])
	var outside := volume.sample_sh9(capture_transform * Vector3(1.2, 0.2, 0.2))
	_require(not bool(volume.sample_sh9_with_validity(capture_transform * Vector3(1.2, 0.2, 0.2)).get("valid")),
		"outside sample is marked invalid")
	_require(_all_zero(outside), "outside capture bounds returns zero SH")
	var before_bad_stage_revision := int(volume.revision)
	var before_bad_stage_transform: Transform3D = volume.capture_transform
	volume.source_capture_transform = Transform3D(Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO), Vector3.ONE)
	var bad_transform_import: Dictionary = volume.refresh_from_selected_source()
	_require(not bool(bad_transform_import.get("valid", true))
			and not String(bad_transform_import.get("reason", "")).is_empty()
			and int(volume.revision) == before_bad_stage_revision
			and volume.capture_transform == before_bad_stage_transform
			and volume.is_valid(),
			"singular staged transform reports an error without moving or invalidating the active payload")
	volume.source_lightmap_gi_data = LightmapGIData.new()
	volume.source_capture_transform = capture_transform
	var bad_data_import: Dictionary = volume.refresh_from_selected_source()
	_require(not bool(bad_data_import.get("valid", true))
			and not String(bad_data_import.get("reason", "")).is_empty()
			and int(volume.revision) == before_bad_stage_revision
			and volume.capture_transform == before_bad_stage_transform
			and volume.is_valid(),
			"empty LightmapGIData candidate leaves the serialized probe payload intact")
	volume.clear()
	_require(not volume.is_valid() and volume.get_gpu_payload().is_empty(), "clear removes stale GPU payload")
	var legacy_api := BakedVolume.new()
	_require(legacy_api.capture_probe_data(source_data, capture_transform), "legacy API fixture is valid before failed import")
	_require(not legacy_api.capture_lightmap_gi_data(null, capture_transform)
			and not legacy_api.is_valid(),
			"legacy direct importer retains its existing invalid-input clear semantics")
	if _failures == 0:
		print("PASS baked lighting adapter (%d checks)" % _checks)
	else:
		push_error("baked lighting adapter failed: %d/%d" % [_failures, _checks])
	quit(1 if _failures > 0 else 0)
