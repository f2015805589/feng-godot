extends SceneTree
## CPU-only checks for the provider packet, source matching, and neutral fallbacks.

const Provider = preload("res://addons/feng-fog/rendering/lighting/environment_visibility/fog_volume_environment_visibility_provider.gd")

var _checks := 0
var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _require(p_condition: bool, p_message: String) -> void:
	_checks += 1
	if not p_condition:
		_failures += 1
		push_error("REGRESSION: " + p_message)


func _run() -> void:
	_test_cloud_packet_neutral_and_current()
	_test_sun_metadata_join()
	_test_shader_contract()
	if _failures == 0:
		print("PASS volume environment visibility (%d checks)" % _checks)
	else:
		push_error("volume environment visibility failed: %d/%d" % [_failures, _checks])
	quit(1 if _failures > 0 else 0)


func _test_cloud_packet_neutral_and_current() -> void:
	var stale := PackedFloat32Array()
	stale.resize(Provider.CLOUD_VISIBILITY_FLOATS)
	stale.fill(0.75)
	var neutral := Provider.normalize_cloud_parameters(stale, false, true, true, true)
	var neutral_values: PackedFloat32Array = neutral.parameters
	_require(not bool(neutral.current), "phase-4 or stale cloud maps are marked non-current")
	_require(neutral_values.size() == Provider.CLOUD_VISIBILITY_FLOATS
			and neutral_values.to_byte_array().size() == Provider.CLOUD_VISIBILITY_UBO_BYTES,
			"neutral CloudVisibilityData is exactly 592 bytes")
	_require(neutral_values[140] == -1.0 and neutral_values[141] == -1.0
			and neutral_values[142] == 0.0 and neutral_values[143] == 0.0
			and neutral_values[144] == 0.0,
			"stale cloud maps clear both sun mappings and AO validity")
	for index in range(0, 140):
		if neutral_values[index] != 0.0:
			_require(false, "stale projection matrices are not retained")
			break
	_require(neutral.diagnostic is String and not neutral.diagnostic.is_empty(),
			"stale cloud packet has a diagnostic")

	var current := PackedFloat32Array()
	current.resize(Provider.CLOUD_VISIBILITY_FLOATS)
	current.fill(0.0)
	current[140] = 1.0
	current[141] = 0.0
	current[142] = 1.0
	current[143] = 1.0
	current[144] = 1.0
	var normalized := Provider.normalize_cloud_parameters(current, true, true, false, true)
	var values: PackedFloat32Array = normalized.parameters
	_require(bool(normalized.current), "current cloud maps remain eligible")
	_require(values[140] == 1.0 and values[141] == 0.0,
			"current cloud sun-to-map mapping survives normalization")
	_require(values[142] == 1.0 and values[143] == 0.0,
			"a missing secondary map clears its validity lane")
	_require(values[144] == 1.0,
			"current raw cloud AO validity survives when its texture is sampleable")
	var nonfinite := current.duplicate()
	nonfinite[27] = NAN
	var rejected := Provider.normalize_cloud_parameters(nonfinite, true, true, true, true)
	_require(not bool(rejected.current) and rejected.parameters[144] == 0.0,
			"non-finite cloud packet fails closed to neutral")


func _test_sun_metadata_join() -> void:
	var primary := DirectionalLight3D.new()
	var secondary := DirectionalLight3D.new()
	var other := DirectionalLight3D.new()
	root.add_child(primary)
	root.add_child(secondary)
	root.add_child(other)
	var primary_rid := primary.get_base()
	var secondary_rid := secondary.get_base()
	var other_rid := other.get_base()
	var can_match := primary_rid.is_valid() and secondary_rid.is_valid() and other_rid.is_valid()
	var metadata := {
		"world_id": 41,
		"provider_id": 42,
		"settings_revision": 5,
		"sun_light_rid": primary_rid,
		"secondary_sun_light_rid": secondary_rid,
		"sun_ground_transmittance": Vector3(0.8, 0.7, 0.6),
		"secondary_sun_ground_transmittance": Vector3(0.4, 0.3, 0.2),
	}
	var frame := {
		"valid": true,
		"abi_version": 1,
		"world_id": 41,
		"directional_light_base_rids": [other_rid, primary_rid, secondary_rid],
	}
	var packet := Provider.make_ground_packet(frame, metadata, [primary_rid, secondary_rid])
	var ground: PackedFloat32Array = packet.ground_values
	var slots: PackedInt32Array = packet.sun_slots
	if can_match:
		_require(bool(packet.metadata_valid), "matching world has valid sky metadata")
		_require(slots[0] == 1 and slots[1] == 2,
				"source RID joins exact native directional indices")
		_require(is_equal_approx(ground[0], 0.8) and is_equal_approx(ground[1], 0.7)
			and is_equal_approx(ground[2], 0.6) and ground[3] == 1.0,
				"primary ground transmission uses one RGB+valid vec4")
		_require(is_equal_approx(ground[4], 0.4) and is_equal_approx(ground[5], 0.3)
			and is_equal_approx(ground[6], 0.2) and ground[7] == 1.0,
				"secondary ground transmission uses its own vec4")
	else:
		_require(slots[0] == -1 and slots[1] == -1 and ground[3] == 0.0 and ground[7] == 0.0,
				"Dummy RenderingServer RIDs cause safe neutral sun results")
	var bytes := ground.to_byte_array()
	bytes.append_array(slots.to_byte_array())
	_require(bytes.size() == 48, "ground and sun-slot packet is exactly 48 bytes")

	var wrong_world := frame.duplicate(true)
	wrong_world.world_id = 43
	var world_mismatch := Provider.make_ground_packet(wrong_world, metadata,
			[primary_rid, secondary_rid])
	_require(not bool(world_mismatch.metadata_valid)
			and world_mismatch.sun_slots[0] == (1 if can_match else -1)
			and world_mismatch.ground_values[3] == 0.0,
			"cross-world sky metadata is neutral")
	var wrong_primary := metadata.duplicate(true)
	wrong_primary.sun_light_rid = other_rid
	var source_mismatch := Provider.make_ground_packet(frame, wrong_primary,
			[primary_rid, secondary_rid])
	_require(source_mismatch.sun_slots[0] == (1 if can_match else -1)
			and source_mismatch.ground_values[3] == 0.0,
			"a different primary sun RID is not applied")
	var duplicate_frame := frame.duplicate(true)
	duplicate_frame.directional_light_base_rids = [primary_rid, primary_rid, secondary_rid]
	var duplicate_join := Provider.make_ground_packet(duplicate_frame, metadata,
			[primary_rid, secondary_rid])
	_require(duplicate_join.sun_slots[0] == -1 and duplicate_join.ground_values[3] == 0.0,
			"ambiguous duplicate native RID fails closed")
	var absent_world := frame.duplicate(true)
	absent_world.erase("world_id")
	var no_world := Provider.make_ground_packet(absent_world, metadata,
			[primary_rid, secondary_rid])
	_require(not bool(no_world.metadata_valid)
			and no_world.sun_slots[0] == (1 if can_match else -1),
			"missing frame world identity fails closed for ground values")
	var signed_metadata := metadata.duplicate(true)
	signed_metadata.world_id = -41
	signed_metadata.provider_id = -42
	var signed_frame := frame.duplicate(true)
	signed_frame.world_id = -41
	var signed_ids := Provider.make_ground_packet(signed_frame, signed_metadata,
			[primary_rid, secondary_rid])
	_require(bool(signed_ids.metadata_valid),
			"negative signed Godot instance IDs remain valid identities")
	primary.queue_free()
	secondary.queue_free()
	other.queue_free()


func _test_shader_contract() -> void:
	var path := "res://addons/feng-fog/rendering/lighting/environment_visibility/fog_volume_environment_visibility.glslinc"
	var source := FileAccess.get_file_as_string(path)
	_require(not source.is_empty(), "environment visibility shader include is present")
	for binding in range(5):
		_require(source.contains("binding = %d" % binding), "set-4 binding %d is declared" % binding)
	_require(source.contains("binding = 0, std140") and source.contains("ivec4 sun_slots"),
			"48-byte ground and slot block matches the UBO contract")
	_require(source.contains("height_fog_cloud_visibility.glslinc"),
			"cloud projection and visibility reuse the shared height-fog helper")
	_require(source.contains("ffog_volume_sun_ground_transmittance")
			and source.contains("ffog_volume_cloud_shadow_visibility")
			and source.contains("ffog_volume_sky_cloud_visibility"),
			"shader exposes direct-sun, shadow, and Sky-AO entry points")
	_require(not source.contains("ATMO_DIRECT_ONLY") and not source.contains("WorldEnvironment"),
			"the helper does not fall back to an atmosphere approximation or world environment")
