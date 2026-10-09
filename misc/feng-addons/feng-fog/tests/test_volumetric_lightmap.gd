extends SceneTree
## CPU-only contract tests for the decoded adaptive VLM resource and sampler.

const VLM = preload("res://addons/feng-fog/rendering/baked_lighting/volumetric_lightmap/fog_volumetric_lightmap.gd")
const VLMProvider = preload("res://addons/feng-fog/rendering/baked_lighting/volumetric_lightmap/fog_volumetric_lightmap_provider.gd")
const ProbeConverter = preload("res://addons/feng-fog/rendering/baked_lighting/volumetric_lightmap/fog_volumetric_lightmap_probe_converter.gd")
const ProbeVolume = preload("res://addons/feng-fog/rendering/baked_lighting/fog_baked_lighting_volume.gd")

var _checks := 0
var _failures := 0
var _resource_changed_signals := 0


func _initialize() -> void:
	call_deferred("_run")


func _require(p_condition: bool, p_message: String) -> void:
	_checks += 1
	if not p_condition:
		_failures += 1
		push_error("REGRESSION: " + p_message)


func _count_resource_changed() -> void:
	_resource_changed_signals += 1


func _run() -> void:
	var sampling := FileAccess.get_file_as_string(
			"res://addons/feng-fog/rendering/baked_lighting/volumetric_lightmap/fog_volumetric_lightmap_sampling.glslinc")
	_require(sampling.contains("layout(set = 5, binding = 0")
			and sampling.contains("binding = 10")
			and sampling.contains("brick.w")
			and sampling.contains("fract(indirection_coord / covered)")
			and sampling.contains("capture_camera_vector.y")
			and sampling.contains("FFOG_VLM_FLAG_STATIC_LIGHT_KEY_MATCH"),
		"GPU include uses the fixed Set 5 ABI, UE coarse-brick lookup, SH2 axis order, and keyed shadow gate")
	var payload := _make_two_neighbor_brick_payload()
	var volume = VLM.new()
	volume.changed.connect(_count_resource_changed)
	var property_usage := {}
	for property_info in volume.get_property_list():
		property_usage[property_info.name] = int(property_info.usage)
	_require((int(property_usage.get("decoded_payload_path", 0)) & PROPERTY_USAGE_EDITOR) != 0
				and (int(property_usage.get("capture_transform", 0)) & PROPERTY_USAGE_EDITOR) != 0
				and (int(property_usage.get("bounds_local", 0)) & PROPERTY_USAGE_EDITOR) != 0
				and (int(property_usage.get("baked_exposure", 0)) & PROPERTY_USAGE_EDITOR) != 0
			and (int(property_usage.get("static_directional_light_key", 0)) & PROPERTY_USAGE_EDITOR) != 0,
		"Inspector shows import source, capture bounds/transform, exposure, and static-light key")
	_require((int(property_usage.get("indirection_rgba8_uint", 0)) & PROPERTY_USAGE_EDITOR) == 0
				and (int(property_usage.get("ambient_rgba16f", 0)) & PROPERTY_USAGE_EDITOR) == 0
				and (int(property_usage.get("sh_coefficients_rgba8_unorm", 0)) & PROPERTY_USAGE_EDITOR) == 0,
		"large raw texture byte arrays stay hidden from the Inspector")
	var missing_path_result: Dictionary = volume.import_payload_from_path()
	_require(not bool(missing_path_result.get("valid", true))
				and not volume.last_import_status.is_empty(),
		"Import button reports a missing decoded payload path without changing active data")
	var edited_volume = VLM.new()
	var edited_revision := int(edited_volume.revision)
	edited_volume.baked_exposure = 3.0
	_require(int(edited_volume.revision) == edited_revision + 1,
		"Inspector edits to active source metadata advance the resource revision")
	var changed: Dictionary = volume.import_decoded_payload(payload)
	_require(bool(changed.get("valid", false)) and bool(changed.get("changed", false))
			and int(volume.revision) == 1 and _resource_changed_signals == 1,
		"valid versioned payload imports atomically, increments one revision, and emits one change signal")
	var snapshot: Dictionary = volume.get_rendering_snapshot()
	_require(bool(snapshot.get("valid", false))
			and snapshot.get("snapshot_thread_contract") == "main_thread_immutable_values_only"
			and snapshot.get("resource_id") == volume.get_instance_id(),
		"main-thread rendering snapshot contains value data and signed Resource identity only")
	_require(not snapshot.has("resource") and not snapshot.has("rendering_device"),
		"immutable snapshot has no Resource or RenderingDevice object reference")
	var parameter_bytes: PackedByteArray = VLMProvider.new()._pack_params(snapshot, 63)
	_require(parameter_bytes.size() == 208,
		"Set 5 v1 metadata block packs to exactly 208 bytes")
	var gpu_provider := VLMProvider.new()
	var synthetic_textures: Array[RID] = []
	for index in 10:
		synthetic_textures.append(RID())
	var active_result: Dictionary = gpu_provider._make_result(snapshot,
		{"textures": synthetic_textures, "neutral": false}, RID(), false, true)
	var neutral_result: Dictionary = gpu_provider._make_result(snapshot,
		{"textures": synthetic_textures, "neutral": true}, RID(), false, true)
	_require(bool(active_result.get("valid", false))
			and bool(active_result.get("payload_valid", false))
			and bool(neutral_result.get("valid", false))
			and not bool(neutral_result.get("payload_valid", true)),
		"valid neutral GPU resources are distinguished from an active VLM payload")
	var indirection_dims := VLMProvider._texture_dimensions_for_index(0, snapshot)
	var ambient_dims := VLMProvider._texture_dimensions_for_index(1, snapshot)
	var indirection_format: RDTextureFormat = gpu_provider._texture_format(indirection_dims,
		gpu_provider._format_for_index(0))
	var ambient_format: RDTextureFormat = gpu_provider._texture_format(ambient_dims,
		gpu_provider._format_for_index(1))
	var shadow_format: RDTextureFormat = gpu_provider._texture_format(
		VLMProvider._texture_dimensions_for_index(9, snapshot), gpu_provider._format_for_index(9))
	_require(indirection_dims == Vector3i(2, 1, 1)
			and Vector3i(indirection_format.width, indirection_format.height, indirection_format.depth) == indirection_dims
			and indirection_format.format == RenderingDevice.DATA_FORMAT_R8G8B8A8_UINT
			and ambient_dims == Vector3i(10, 5, 5)
			and Vector3i(ambient_format.width, ambient_format.height, ambient_format.depth) == ambient_dims
			and ambient_format.format == RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
			and Vector3i(shadow_format.width, shadow_format.height, shadow_format.depth) == ambient_dims
			and shadow_format.format == RenderingDevice.DATA_FORMAT_R8_UNORM,
		"indirection uses its own non-cubic dimensions while all brick textures use the padded atlas and matching formats")
	if parameter_bytes.size() == 208:
		_require(is_equal_approx(parameter_bytes.decode_float(128), 0.0)
				and is_equal_approx(parameter_bytes.decode_float(144), 2.0)
				and is_equal_approx(parameter_bytes.decode_float(148), 1.0),
			"capture bounds occupy the two vec4 slots at offsets 128 and 144")
		_require(parameter_bytes.decode_s32(160) == 2
				and parameter_bytes.decode_s32(172) == 4
				and parameter_bytes.decode_s32(176) == 10
				and parameter_bytes.decode_s32(188) == 63,
			"Set 5 dimensions, brick size, atlas dimensions, and flags match the UBO lanes")
		_require(is_equal_approx(parameter_bytes.decode_float(192), 2.5),
			"baked exposure occupies the final vec4 without applying view pre-exposure")
	var constant_payload := _make_two_neighbor_brick_payload()
	var constant_ambient: PackedByteArray = constant_payload["ambient_rgba16f"]
	for voxel in 10 * 5 * 5:
		var offset := voxel * 8
		constant_ambient.encode_half(offset, PI)
		constant_ambient.encode_half(offset + 2, PI)
		constant_ambient.encode_half(offset + 4, PI)
	constant_payload["ambient_rgba16f"] = constant_ambient
	var constant_volume = VLM.new()
	constant_volume.import_decoded_payload(constant_payload)
	var constant_sample: Dictionary = VLM.sample_cpu(constant_volume.get_rendering_snapshot(),
		constant_payload["capture_transform"] * Vector3(0.5, 0.5, 0.5), Vector3.UP, 0.0, "")
	_require(bool(constant_sample.get("valid", false))
				and absf(float(constant_sample.irradiance_over_pi.x) - 1.0) < 0.001
				and absf(float(constant_sample.irradiance_over_pi.y) - 1.0) < 0.001
				and absf(float(constant_sample.irradiance_over_pi.z) - 1.0) < 0.001,
		"constant-L g=0 SH2 fixture reconstructs the original radiance")
	var initial_revision := int(volume.revision)
	var same_import: Dictionary = volume.import_decoded_payload(payload)
	_require(bool(same_import.get("valid", false)) and not bool(same_import.get("changed", true))
			and int(volume.revision) == initial_revision and _resource_changed_signals == 1,
		"identical payload reimport does not churn revision, cache, or change signals")
	var json_volume = VLM.new()
	var json_path := "user://decoded_vlm_fixture.json"
	json_volume.decoded_payload_path = json_path
	var json_file := FileAccess.open(json_path, FileAccess.WRITE)
	_require(json_file != null, "temporary decoded JSON fixture can be created")
	if json_file != null:
		json_file.store_string(JSON.stringify(_make_json_payload(payload)))
		json_file.close()
		var json_import: Dictionary = json_volume.import_payload_from_path()
		_require(bool(json_import.get("valid", false)) and json_volume.is_valid()
				and json_volume.indirection_dimensions == payload["indirection_dimensions"]
				and json_volume.ambient_rgba16f == payload["ambient_rgba16f"]
				and json_volume.source_description == "decoded_vlm_fixture.json"
				and json_volume.last_import_status.contains("Imported"),
			"Inspector Import button coerces documented JSON arrays/base64 and reports success")
		DirAccess.remove_absolute(ProjectSettings.globalize_path(json_path))
	var optional_payload := payload.duplicate(true)
	optional_payload.erase("sky_bent_normal_rgba8_unorm")
	optional_payload.erase("directional_shadow_r8_unorm")
	optional_payload["has_sky_bent_normal"] = false
	optional_payload["has_directional_shadowing"] = false
	var optional_volume = VLM.new()
	var optional_import: Dictionary = optional_volume.import_decoded_payload(optional_payload)
	var optional_snapshot: Dictionary = optional_volume.get_rendering_snapshot()
	_require(bool(optional_import.get("valid", false))
				and optional_snapshot.get("sky_bent_normal_rgba8_unorm", PackedByteArray()).size() == 10 * 5 * 5 * 4
				and optional_snapshot.get("directional_shadow_r8_unorm", PackedByteArray()).size() == 10 * 5 * 5,
		"omitted optional bent/shadow layers are materialized as neutral textures with source flags disabled")
	var broken := payload.duplicate(true)
	broken["ambient_rgba16f"] = PackedByteArray([0, 1])
	var rejected: Dictionary = volume.import_decoded_payload(broken)
	_require(not bool(rejected.get("valid", true)) and int(volume.revision) == initial_revision
			and volume.get_rendering_snapshot().get("ambient_rgba16f") == snapshot.get("ambient_rgba16f"),
		"bad candidate bytes are rejected without replacing the previous active payload")
	var rotated_capture: Transform3D = payload["capture_transform"]
	var left_local := Vector3(0.5, 0.5, 0.5)
	var right_local := Vector3(1.5, 0.5, 0.5)
	var view_axis_world: Vector3 = rotated_capture.basis * Vector3.UP
	var left_sample: Dictionary = VLM.sample_cpu(snapshot, rotated_capture * left_local,
		view_axis_world, 0.5, "PrimarySun")
	var right_sample: Dictionary = VLM.sample_cpu(snapshot, rotated_capture * right_local,
		view_axis_world, 0.5, "PrimarySun")
	_require(bool(left_sample.get("valid", false)) and bool(right_sample.get("valid", false)),
		"rotated capture transform maps world positions into two valid adjacent bricks")
	_require(left_sample.get("indirection_cell") == Vector3i(0, 0, 0)
			and right_sample.get("indirection_cell") == Vector3i(1, 0, 0),
		"neighboring indirection cells select their own atlas bricks")
	_require(is_equal_approx(float(left_sample.brick_uv.x), 0.25)
			and is_equal_approx(float(right_sample.brick_uv.x), 0.75),
		"UE padded atlas coordinate includes +1 brick padding and half-texel center")
	_require(is_equal_approx(float(left_sample.irradiance_over_pi.x), _ue_sh2_oracle(payload,
		left_sample.brick_uv, view_axis_world, rotated_capture, 0.5, 0)),
		"positive L1 sample matches independent UE SH2 decode and HG dot-product oracle")
	var expected_left_ambient := _oracle_ambient(payload, left_sample.brick_uv).x
	var expected_right_ambient := _oracle_ambient(payload, right_sample.brick_uv).x
	_require(is_equal_approx(expected_left_ambient, 1.0)
			and is_equal_approx(expected_right_ambient, 2.0),
		"adjacent brick HDR ambient values survive half-float storage and interpolation")
	var bent_oracle := _oracle_bent_visibility(payload, left_sample.brick_uv)
	_require(absf(float(left_sample.sky_visibility) - bent_oracle) < 0.0001
			and bent_oracle > 0.99 and bent_oracle <= 1.01,
		"encoded SkyBentNormal is decoded as RGB*2-1 and visibility is its length")
	_require(absf(float(left_sample.directional_shadow) - 64.0 / 255.0) < 0.0001
			and bool(left_sample.static_light_key_match),
		"matched stable primary Sun key enables the scalar directional-shadow layer")
	var mismatched_sun: Dictionary = VLM.sample_cpu(snapshot,
		rotated_capture * left_local, view_axis_world, 0.5, "OtherSun")
	_require(is_equal_approx(float(mismatched_sun.directional_shadow), 1.0)
			and not bool(mismatched_sun.static_light_key_match)
			and (int(mismatched_sun.source_flags) & VLM.FLAG_CONTAINS_STATIC_DIRECT_DIRECTIONAL_LIGHTING) != 0,
		"a mismatched Sun keeps shadow neutral while preserving source metadata for live-light routing")
	_require(is_equal_approx(float(left_sample.baked_exposure), 2.5),
		"capture exposure stays separate from irradiance and view pre-exposure")
	var positive_payload := _payload_with_l1(192)
	var negative_payload := _payload_with_l1(63)
	var positive_volume = VLM.new()
	var negative_volume = VLM.new()
	positive_volume.import_decoded_payload(positive_payload)
	negative_volume.import_decoded_payload(negative_payload)
	var positive: Dictionary = VLM.sample_cpu(positive_volume.get_rendering_snapshot(),
		Vector3(0.5, 0.5, 0.5), Vector3.UP, 0.5, "")
	var negative: Dictionary = VLM.sample_cpu(negative_volume.get_rendering_snapshot(),
		Vector3(0.5, 0.5, 0.5), Vector3.UP, 0.5, "")
	_require(float(positive.irradiance_over_pi.x) > float(negative.irradiance_over_pi.x)
			and is_equal_approx(float(positive.irradiance_over_pi.x),
				_ue_sh2_oracle(positive_payload, positive.brick_uv, Vector3.UP,
					Transform3D.IDENTITY, 0.5, 0)),
		"positive and negative encoded L1 coefficients follow the UE signed normalized-SH decode")
	var boundary_sample: Dictionary = VLM.sample_cpu(snapshot,
		rotated_capture * Vector3(20.0, 0.5, 0.5), view_axis_world, 0.0, "PrimarySun")
	_require(bool(boundary_sample.get("valid", false))
			and boundary_sample.get("indirection_cell") == Vector3i(1, 0, 0),
		"positions outside bounds follow UE [0,0.99] indirection UV clamping")
	var coarse_payload := _make_coarse_entry_payload()
	var coarse_volume = VLM.new()
	var coarse_import: Dictionary = coarse_volume.import_decoded_payload(coarse_payload)
	var coarse_capture: Transform3D = coarse_payload["capture_transform"]
	var coarse_sample: Dictionary = VLM.sample_cpu(coarse_volume.get_rendering_snapshot(),
		coarse_capture * Vector3(1.0, 0.75, 0.5), Vector3.UP, 0.2, "")
	_require(bool(coarse_import.get("valid", false)) and bool(coarse_sample.get("valid", false))
			and coarse_sample.get("indirection_cell") == Vector3i(1, 1, 0),
		"coarse w=2 indirection entries use UE frac(indirectionCoordinate / w) mapping")
	var invalid_payload := _make_invalid_w_payload()
	var invalid_volume = VLM.new()
	var invalid_import: Dictionary = invalid_volume.import_decoded_payload(invalid_payload)
	var invalid_sample: Dictionary = VLM.sample_cpu(invalid_volume.get_rendering_snapshot(),
		Vector3(0.5, 0.5, 0.5), Vector3.UP, 0.2, "")
	_require(bool(invalid_import.get("valid", false)) and not bool(invalid_sample.get("valid", true))
			and is_equal_approx(float(invalid_sample.sky_visibility), 1.0)
			and is_equal_approx(float(invalid_sample.directional_shadow), 1.0),
		"w=0 is a guarded invalid brick with neutral visibility and shadow, never a divide-by-zero")
	var converter_case := _test_probe_resampler()
	_require(bool(converter_case.get("valid", false)),
		"tetra-probe conversion creates a valid approximate UE padded-brick payload")
	if bool(converter_case.get("valid", false)):
		_require(bool(converter_case.get("resource_imported", false))
				and int(converter_case.get("resource_revision", 0)) == 1
				and String(converter_case.get("resource_source_description", "")) == "LightmapGI tetra probe resample",
			"Inspector resample button imports the converter result and updates active Resource metadata once")
		var converted_payload: Dictionary = converter_case["payload"]
		_require(not bool(converted_payload.get("has_sky_bent_normal", true))
				and not bool(converted_payload.get("has_directional_shadowing", true))
				and not bool(converted_payload.get("contains_static_direct_directional_lighting", true)),
			"probe resampling marks unavailable BentNormal/shadow and direct-at-source channels neutral")
		var converted_volume = VLM.new()
		var converted_result: Dictionary = converted_volume.import_decoded_payload(converted_payload)
		_require(bool(converted_result.get("valid", false)) and converted_volume.is_valid(),
			"converted resource passes the same versioned payload validator")
	if _failures == 0:
		print("PASS volumetric lightmap CPU contract (%d checks)" % _checks)
	else:
		push_error("VOLUMETRIC LIGHTMAP CPU CONTRACT FAILED: %d/%d checks" % [_failures, _checks])
	quit(0 if _failures == 0 else 1)


func _make_two_neighbor_brick_payload() -> Dictionary:
	var dims := Vector3i(2, 1, 1)
	var atlas_dims := Vector3i(10, 5, 5)
	var voxels := atlas_dims.x * atlas_dims.y * atlas_dims.z
	var indirection := PackedByteArray([0, 0, 0, 1, 1, 0, 0, 1])
	var ambient := _ambient_bytes(atlas_dims, true)
	var layers := _neutral_sh_layers(voxels)
	for z in atlas_dims.z:
		for y in atlas_dims.y:
			for x in atlas_dims.x:
				var voxel := (z * atlas_dims.y + y) * atlas_dims.x + x
				var offset := voxel * 4
				layers[0][offset] = 192
				layers[2][offset + 1] = 64
				layers[4][offset + 2] = 200
	var bent := PackedByteArray()
	bent.resize(voxels * 4)
	var shadow := PackedByteArray()
	shadow.resize(voxels)
	for voxel in voxels:
		bent[voxel * 4] = 255
		bent[voxel * 4 + 1] = 128
		bent[voxel * 4 + 2] = 128
		bent[voxel * 4 + 3] = 255
		shadow[voxel] = 64
	return _base_payload(dims, atlas_dims, indirection, ambient, layers, bent, shadow)


func _payload_with_l1(p_encoded: int) -> Dictionary:
	var dims := Vector3i.ONE
	var atlas_dims := Vector3i(5, 5, 5)
	var voxels := atlas_dims.x * atlas_dims.y * atlas_dims.z
	var layers := _neutral_sh_layers(voxels)
	for voxel in voxels:
		layers[0][voxel * 4] = p_encoded
	return _base_payload(dims, atlas_dims, PackedByteArray([0, 0, 0, 1]),
		_ambient_bytes(atlas_dims, false), layers, _neutral_bent(voxels), _neutral_shadow(voxels))


func _make_coarse_entry_payload() -> Dictionary:
	var dims := Vector3i(2, 2, 1)
	var atlas_dims := Vector3i(5, 5, 5)
	var indirection := PackedByteArray()
	for _i in 4:
		indirection.append_array(PackedByteArray([0, 0, 0, 2]))
	var voxels := atlas_dims.x * atlas_dims.y * atlas_dims.z
	return _base_payload(dims, atlas_dims, indirection,
		_ambient_bytes(atlas_dims, false), _neutral_sh_layers(voxels),
		_neutral_bent(voxels), _neutral_shadow(voxels))


func _make_invalid_w_payload() -> Dictionary:
	var dims := Vector3i.ONE
	var atlas_dims := Vector3i(5, 5, 5)
	var voxels := atlas_dims.x * atlas_dims.y * atlas_dims.z
	return _base_payload(dims, atlas_dims, PackedByteArray([0, 0, 0, 0]),
		_ambient_bytes(atlas_dims, false), _neutral_sh_layers(voxels),
		_neutral_bent(voxels), _neutral_shadow(voxels))


func _base_payload(p_dims: Vector3i, p_atlas_dims: Vector3i,
		p_indirection: PackedByteArray, p_ambient: PackedByteArray,
		p_layers: Array[PackedByteArray], p_bent: PackedByteArray,
		p_shadow: PackedByteArray) -> Dictionary:
	return {
		"format_version": 1,
		"coordinate_units": "m",
		"capture_transform": Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(3.0, 2.0, -1.0)),
		"bounds_local": AABB(Vector3.ZERO, Vector3(2.0, 1.0, 1.0)),
		"brick_size": 4,
		"indirection_dimensions": p_dims,
		"brick_atlas_dimensions": p_atlas_dims,
		"indirection_rgba8_uint": p_indirection,
		"ambient_rgba16f": p_ambient,
		"sh_coefficients_rgba8_unorm": p_layers,
		"sky_bent_normal_rgba8_unorm": p_bent,
		"directional_shadow_r8_unorm": p_shadow,
		"baked_exposure": 2.5,
		"includes_environment_radiance": true,
		"contains_static_direct_directional_lighting": true,
		"has_sky_bent_normal": true,
		"has_directional_shadowing": true,
		"static_directional_light_key": "PrimarySun",
		"coefficient_domain": "ue_vlm_ambient_and_normalized_sh_v1",
		"source_revision": 19,
	}


func _ambient_bytes(p_dims: Vector3i, p_two_bricks: bool) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(p_dims.x * p_dims.y * p_dims.z * 8)
	for z in p_dims.z:
		for y in p_dims.y:
			for x in p_dims.x:
				var value := 1.0
				if p_two_bricks and x >= 5:
					value = 2.0
				var offset := ((z * p_dims.y + y) * p_dims.x + x) * 8
				bytes.encode_half(offset, value)
				bytes.encode_half(offset + 2, value)
				bytes.encode_half(offset + 4, value)
				bytes.encode_half(offset + 6, 1.0)
	return bytes


func _neutral_sh_layers(p_voxels: int) -> Array[PackedByteArray]:
	var layers: Array[PackedByteArray] = []
	for _layer in 6:
		var bytes := PackedByteArray()
		bytes.resize(p_voxels * 4)
		bytes.fill(128)
		layers.append(bytes)
	return layers


func _make_json_payload(p_payload: Dictionary) -> Dictionary:
	var capture: Transform3D = p_payload["capture_transform"]
	var bounds: AABB = p_payload["bounds_local"]
	var json_payload := p_payload.duplicate(true)
	json_payload["capture_transform"] = {
		"basis_columns": [
			[capture.basis.x.x, capture.basis.x.y, capture.basis.x.z],
			[capture.basis.y.x, capture.basis.y.y, capture.basis.y.z],
			[capture.basis.z.x, capture.basis.z.y, capture.basis.z.z],
		],
		"origin": [capture.origin.x, capture.origin.y, capture.origin.z],
	}
	json_payload["bounds_local"] = {
		"position": [bounds.position.x, bounds.position.y, bounds.position.z],
		"size": [bounds.size.x, bounds.size.y, bounds.size.z],
	}
	for field in ["indirection_dimensions", "brick_atlas_dimensions"]:
		var dimensions: Vector3i = p_payload[field]
		json_payload[field] = [dimensions.x, dimensions.y, dimensions.z]
	for field in ["indirection_rgba8_uint", "ambient_rgba16f", "sky_bent_normal_rgba8_unorm", "directional_shadow_r8_unorm"]:
		json_payload[field] = Marshalls.raw_to_base64(p_payload[field])
	var encoded_layers: Array[String] = []
	for layer in p_payload["sh_coefficients_rgba8_unorm"]:
		encoded_layers.append(Marshalls.raw_to_base64(layer))
	json_payload["sh_coefficients_rgba8_unorm"] = encoded_layers
	return json_payload


func _neutral_bent(p_voxels: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(p_voxels * 4)
	for voxel in p_voxels:
		bytes[voxel * 4] = 128
		bytes[voxel * 4 + 1] = 128
		bytes[voxel * 4 + 2] = 255
		bytes[voxel * 4 + 3] = 255
	return bytes


func _neutral_shadow(p_voxels: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(p_voxels)
	bytes.fill(255)
	return bytes


func _ue_sh2_oracle(p_payload: Dictionary, p_uv: Vector3,
		p_world_camera_vector: Vector3, p_capture: Transform3D,
		p_g: float, p_channel: int) -> float:
	# Independent literal mirror of VolumetricLightmapShared.ush decode and
	# VolumetricFog.usf's RotatedHGZonalHarmonic / PI expression.
	var ambient := _oracle_ambient(p_payload, p_uv)[p_channel]
	var layers: Array = p_payload["sh_coefficients_rgba8_unorm"]
	var sh_texel := _oracle_unorm_texel(layers[0], p_payload["brick_atlas_dimensions"], p_uv)
	var decoded_y := sh_texel.x * 2.0 - 1.0
	var world_to_capture: Basis = p_capture.basis.orthonormalized().transposed()
	var camera_direction := (world_to_capture * p_world_camera_vector.normalized()).normalized()
	var red_l1_y := decoded_y * ambient * (0.488603 / 0.282095)
	var dot_sh := ambient + red_l1_y * camera_direction.y * p_g
	return maxf(dot_sh, 0.0) / PI


func _oracle_ambient(p_payload: Dictionary, p_uv: Vector3) -> Vector3:
	var bytes: PackedByteArray = p_payload["ambient_rgba16f"]
	var dims: Vector3i = p_payload["brick_atlas_dimensions"]
	var texel := Vector3i(
		clampi(int(floor(p_uv.x * dims.x)), 0, dims.x - 1),
		clampi(int(floor(p_uv.y * dims.y)), 0, dims.y - 1),
		clampi(int(floor(p_uv.z * dims.z)), 0, dims.z - 1))
	var offset := ((texel.z * dims.y + texel.y) * dims.x + texel.x) * 8
	return Vector3(bytes.decode_half(offset), bytes.decode_half(offset + 2), bytes.decode_half(offset + 4))


func _oracle_bent_visibility(p_payload: Dictionary, p_uv: Vector3) -> float:
	var bytes: PackedByteArray = p_payload["sky_bent_normal_rgba8_unorm"]
	var dims: Vector3i = p_payload["brick_atlas_dimensions"]
	var texel := Vector3i(
		clampi(int(floor(p_uv.x * dims.x)), 0, dims.x - 1),
		clampi(int(floor(p_uv.y * dims.y)), 0, dims.y - 1),
		clampi(int(floor(p_uv.z * dims.z)), 0, dims.z - 1))
	var offset := ((texel.z * dims.y + texel.y) * dims.x + texel.x) * 4
	var decoded := Vector3(bytes[offset], bytes[offset + 1], bytes[offset + 2]) / 255.0 * 2.0 - Vector3.ONE
	return decoded.length()


func _oracle_unorm_texel(p_bytes: PackedByteArray, p_dims: Vector3i,
		p_uv: Vector3) -> Vector4:
	var texel := Vector3i(
		clampi(int(floor(p_uv.x * p_dims.x)), 0, p_dims.x - 1),
		clampi(int(floor(p_uv.y * p_dims.y)), 0, p_dims.y - 1),
		clampi(int(floor(p_uv.z * p_dims.z)), 0, p_dims.z - 1))
	var offset := ((texel.z * p_dims.y + texel.y) * p_dims.x + texel.x) * 4
	return Vector4(p_bytes[offset], p_bytes[offset + 1], p_bytes[offset + 2], p_bytes[offset + 3]) / 255.0


func _test_probe_resampler() -> Dictionary:
	var source = ProbeVolume.new()
	var positions := PackedVector3Array([Vector3.ZERO, Vector3(0.9, 0.0, 0.0),
		Vector3(0.0, 0.9, 0.0), Vector3(0.0, 0.0, 0.9)])
	var sh := PackedColorArray()
	for probe in positions.size():
		for coefficient in 9:
			var value := 1.0 if coefficient == 0 else 0.05 * float(probe + coefficient)
			sh.append(Color(value, value * 0.75, value * 0.5, 0.0))
	var bsp := PackedInt32Array([
		_float_bits(0.0), _float_bits(0.0), _float_bits(0.0), _float_bits(-1.0),
		-1, -2147483648,
	])
	var probe_payload := {
		"bounds": AABB(Vector3.ZERO, Vector3.ONE * 0.3),
		"points": positions,
		"sh": sh,
		"tetrahedra": PackedInt32Array([0, 1, 2, 3]),
		"bsp": bsp,
		"baked_exposure": 2.0,
		"includes_environment_radiance": true,
	}
	if not source.capture_probe_data(probe_payload, Transform3D.IDENTITY):
		return {"valid": false, "reason": "Could not create tetra source fixture."}
	var target = VLM.new()
	target.source_lightmap_gi_probe_volume = source
	var converted: Dictionary = target.resample_lightmapgi_probes()
	converted["resource_imported"] = target.is_valid()
	converted["resource_revision"] = target.revision
	converted["resource_source_description"] = target.source_description
	return converted


func _float_bits(p_value: float) -> int:
	return PackedFloat32Array([p_value]).to_byte_array().decode_s32(0)
