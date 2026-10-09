extends SceneTree
## CPU-only oracle tests for sky SH packing and rect-area lighting contracts.

const SkySH = preload("res://addons/feng-fog/rendering/lighting/fog_sky_sh_provider.gd")
const RectLight = preload("res://addons/feng-fog/rendering/lighting/fog_rect_light.gd")
const CapsuleLight = preload("res://addons/feng-fog/rendering/lighting/fog_capsule_light.gd")
const FengSkyRuntime = preload("res://addons/feng-sky/feng_sky_light_runtime.gd")

class FakeSkyProvider extends Node3D:
	var priority := 0
	var readback_requested := false

	func _feng_sky_light_is_candidate(_world_id: int) -> bool:
		return true

	func _feng_sky_light_set_active(_active: bool) -> void:
		pass

	func _feng_sky_light_volumetric_metadata() -> Dictionary:
		return {"ready": true, "source_revision": 12, "volumetric_scattering_intensity": 1.5}

	func _feng_sky_light_runtime_snapshot() -> Dictionary:
		readback_requested = true
		return {"cpu_sh": PackedFloat32Array([1.0])}

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
	_test_uniform_sky_projection()
	_test_sky_l1_and_l2_packing()
	_test_sky_radiance_dimensions()
	_test_sky_compute_source_loading()
	_test_sky_source_metadata_matching()
	_test_rect_light()
	_test_capsule_light()
	await _test_sky_runtime_metadata()
	if _failures == 0:
		print("PASS fog lighting helpers (%d checks)" % _checks)
	else:
		push_error("fog lighting helper tests failed: %d/%d" % [_failures, _checks])
	quit(1 if _failures > 0 else 0)


func _test_uniform_sky_projection() -> void:
	const width := 128
	const height := 64
	var directions := PackedVector3Array()
	var radiances := PackedVector3Array()
	for y in height:
		var z := 1.0 - 2.0 * (float(y) + 0.5) / float(height)
		var radial := sqrt(maxf(1.0 - z * z, 0.0))
		for x in width:
			var phi := TAU * (float(x) + 0.5) / float(width)
			directions.append(Vector3(radial * cos(phi), radial * sin(phi), z))
			radiances.append(Vector3(1.0, 0.25, 2.0))
	var raw := SkySH.project_samples_to_raw_sh(directions, radiances)
	var packed := SkySH.pack_ue_diffuse_over_pi(raw)
	_require(packed.size() == 28, "uniform environment packs seven vec4 coefficients")
	if packed.size() != 28:
		return
	for direction in [Vector3.RIGHT, Vector3.UP, Vector3.BACK, Vector3(0.3, -0.4, 0.5).normalized()]:
		var value := SkySH.evaluate_simple_diffuse(packed, direction)
		_require(value.distance_to(Vector3(1.0, 0.25, 2.0)) < 0.0003,
				"constant environment evaluates to its original radiance")
	_require(absf(packed[0]) < 0.00001 and absf(packed[1]) < 0.00001 \
			and absf(packed[2]) < 0.00001, "constant sky has no L1 x/y contribution")
	_require(absf(packed[3] - 1.0) < 0.0002 and absf(packed[7] - 0.25) < 0.0002 \
			and absf(packed[11] - 2.0) < 0.0002, "UE L0 terms preserve linear color")
	_require(absf(packed[27] - 1.0) < 0.00001, "UE V6 constant term uses the required W lane")


func _test_sky_l1_and_l2_packing() -> void:
	var raw_l1 := PackedFloat32Array()
	raw_l1.resize(27)
	raw_l1.fill(0.0)
	for channel in 3:
		raw_l1[1 * 3 + channel] = 1.0
	var packed_l1 := SkySH.pack_ue_diffuse_over_pi(raw_l1)
	var zero_anisotropy := SkySH.evaluate_simple_diffuse(packed_l1, Vector3.ZERO)
	_require(zero_anisotropy.is_equal_approx(Vector3.ZERO),
			"g=0 evaluates only the L0 basis and removes pure L1 sky")
	var directional := SkySH.evaluate_simple_diffuse(packed_l1, Vector3.DOWN)
	_require(directional.length_squared() > 0.0, "nonzero direction preserves the signed L1 lobe")

	var raw_l2 := PackedFloat32Array()
	raw_l2.resize(27)
	raw_l2.fill(0.0)
	for channel in 3:
		raw_l2[6 * 3 + channel] = 2.0
		raw_l2[8 * 3 + channel] = 3.0
	var packed_l2 := SkySH.pack_ue_diffuse_over_pi(raw_l2)
	const c3 := 0.07884789131313001
	const c4 := 0.171523349234824
	_require(absf(packed_l2[3] + c3 * 2.0) < 0.00001,
			"L2 Y20 contribution is retained in the UE L0/L1 constant lane")
	_require(absf(packed_l2[14] - 3.0 * c3 * 2.0) < 0.00001,
			"L2 Y20 contribution is retained in the packed L2 lane")
	_require(absf(packed_l2[24] - c4 * 3.0) < 0.00001,
			"L2 X2-Y2 contribution is retained in UE V6")


func _test_sky_source_metadata_matching() -> void:
	var provider = SkySH.new()
	var frame := {
		"sky_light_source_owner_id": 81,
		"sky_light_source_revision": 12,
		"sky_light_energy": 2.0,
		"sky_captured_exposure": 1.25,
		"sky_light_rotation": Basis.IDENTITY,
	}
	var metadata := {
		"ready": true,
		"provider_id": 81,
		"source_revision": 12,
		"radiance_energy": 2.0,
		"captured_exposure": 1.25,
		"rotation": Basis.IDENTITY,
	}
	_require(provider._metadata_matches_frame(frame, metadata),
			"volumetric source metadata matches the explicit native frame")
	metadata["radiance_energy"] = 2.1
	_require(not provider._metadata_matches_frame(frame, metadata),
			"stale energy metadata cannot apply to a different frame light value")
	metadata["radiance_energy"] = 2.0
	metadata["rotation"] = Basis(Vector3.UP, 0.1)
	_require(not provider._metadata_matches_frame(frame, metadata),
			"stale source rotation cannot apply to the current native frame")
	provider.release()


func _test_sky_radiance_dimensions() -> void:
	# SkyRD uses actual octmap width 2*nominal + 2*padding and border=padding/width.
	# Array, non-array, regular, and external radiance all share this shape rule.
	var array_sky := SkySH.validate_radiance_dimensions(288, 288, 128, 16.0 / 288.0)
	_require(bool(array_sky.get("valid", false)),
			"padded 2D-array octmap uses its nominal face size plus explicit border")
	_require(is_equal_approx(float(array_sky.get("interior_width", 0.0)), 256.0),
			"array octmap interior resolves to twice nominal cube-face size")
	var non_array_sky := SkySH.validate_radiance_dimensions(272, 272, 128, 8.0 / 272.0)
	_require(bool(non_array_sky.get("valid", false)),
			"non-array octmap accepts the smaller roughness-layer padding")
	var external_array := SkySH.validate_radiance_dimensions(288, 288, 128, 16.0 / 288.0)
	var external_non_array := SkySH.validate_radiance_dimensions(272, 272, 128, 8.0 / 272.0)
	_require(bool(external_array.get("valid", false))
			and bool(external_non_array.get("valid", false)),
			"external captures use the same dimension contract for both RD texture types")
	var rectangular := SkySH.validate_radiance_dimensions(288, 272, 128, 16.0 / 288.0)
	_require(not bool(rectangular.get("valid", true)),
			"non-square radiance textures fail closed")
	var wrong_border := SkySH.validate_radiance_dimensions(288, 288, 128, 0.1)
	_require(not bool(wrong_border.get("valid", true)),
			"a border that produces the wrong octmap interior fails closed")
	var invalid_border := SkySH.validate_radiance_dimensions(288, 288, 128, 0.5)
	_require(not bool(invalid_border.get("valid", true)),
			"invalid border metadata is rejected")
	var tolerance_case := SkySH.validate_radiance_dimensions(288, 288, 128,
			16.0 / 288.0 + 0.0005)
	_require(bool(tolerance_case.get("valid", false)),
			"float border round-off within half a pixel is tolerated")
	var outside_tolerance := SkySH.validate_radiance_dimensions(288, 288, 128,
			16.0 / 288.0 + 0.002)
	_require(not bool(outside_tolerance.get("valid", true)),
			"border drift greater than half a pixel is rejected")
	var provider = SkySH.new()
	var frame := {
		"sky_light_source_owner_id": 12,
		"sky_light_source_revision": 3,
		"sky_light_revision": 7,
		"sky_radiance_texture": RID(),
		"sky_light_source": RID(),
		"sky_radiance_size": 128,
		"sky_radiance_is_array": true,
		"sky_light_rotation": Basis.IDENTITY,
	}
	var format_a := RDTextureFormat.new()
	format_a.width = 288
	format_a.height = 288
	format_a.array_layers = 6
	format_a.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	format_a.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	var format_b := RDTextureFormat.new()
	format_b.width = 304
	format_b.height = 304
	format_b.array_layers = 6
	format_b.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	format_b.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	var key_a: Array = provider._make_source_key(frame, format_a, 16.0 / 288.0)
	var key_b: Array = provider._make_source_key(frame, format_b, 24.0 / 304.0)
	_require(key_a != key_b,
			"actual RD dimensions and border changes invalidate the SH projection cache")
	provider.release()


func _test_sky_compute_source_loading() -> void:
	var project_source := FileAccess.get_file_as_string(
			"res://addons/feng-fog/rendering/lighting/fog_sky_sh_project.glslinc")
	var pack_source := FileAccess.get_file_as_string(
			"res://addons/feng-fog/rendering/lighting/fog_sky_sh_pack.glslinc")
	var raw_project := SkySH.strip_compute_marker(project_source)
	var raw_pack := SkySH.strip_compute_marker(pack_source)
	_require(raw_project.begins_with("#version 450") and not raw_project.contains("#[compute]"),
			"RD projector source strips the Godot-only compute importer marker")
	_require(raw_pack.begins_with("#version 450") and not raw_pack.contains("#[compute]"),
			"RD SH packer source strips the Godot-only compute importer marker")
	_require(SkySH.strip_compute_marker("#version 450\nvoid main() {}\n").is_empty(),
			"malformed compute sources fail closed instead of compiling importer syntax")


func _test_rect_light() -> void:
	var rect_shader := FileAccess.get_file_as_string(
			"res://addons/feng-fog/rendering/lighting/fog_rect_light.glslinc")
	_require(rect_shader.contains("length(area_width), length(area_height)) * 0.5")
			and rect_shader.contains("local_position / half_extent")
			and rect_shader.contains("half_extent.x * half_extent.y"),
			"GLSL atlas UV and LOD use UE half extents from native full-span axes")
	_require(rect_shader.contains("FFogRectVisibleRect ffog_rect_visible_rect")
			and rect_shader.contains("vec3 axis_2 = -light_forward")
			and rect_shader.contains("FFogRectBarnDoorCosThreshold = 0.035")
			and rect_shader.contains("shifted_to_light = to_light - axis_0 * rect_offset.x - axis_1 * rect_offset.y"),
			"GLSL exposes the UE visible-rect contract and native-to-UE axis mapping")
	var atlas_rect := Rect2(0.2, 0.3, 0.5, 0.4)
	var result := RectLight.evaluate_volume(
			Vector3(0.0, 0.0, -10.0), Vector3(0.0, 0.0, -5.0),
			Vector3(2.0, 0.0, 0.0), Vector3(0.0, 2.0, 0.0), Vector3(0.0, 0.0, -1.0),
			0.1, 10.0, 1.0, atlas_rect, Vector2i(256, 256), 4.0, true)
	_require(bool(result.get("valid", false)), "nonzero rectangular emitter has a valid spherical integral")
	if not bool(result.get("valid", false)):
		return
	_require(absf(float(result.get("integrate_light", 0.0)) - 0.1503884) < 0.0002,
			"rect spherical-polygon integral matches the UE center-ray fixture")
	_require(not bool(result.get("inverse_square_applied", true)),
			"rect solid-angle integral does not get a second inverse-square factor")
	_require(is_equal_approx(float(result.get("soft_fade", -1.0)), 0.5),
			"UE soft fade includes the light-to-froxel distance")
	_require(is_equal_approx(float(result.get("radius_mask", -1.0)), 0.87890625),
			"finite range uses the UE quartic radius mask")
	var rect_phase_cosine := float(result.get("phase_cosine", -2.0))
	_require(is_equal_approx(rect_phase_cosine, -1.0),
			"rect phase returns FRP dot(L, viewRay) with center froxel-to-light L")
	var anisotropy := 0.5
	var frp_phase := (1.0 - anisotropy * anisotropy) \
			/ pow(1.0 + anisotropy * anisotropy - 2.0 * anisotropy * rect_phase_cosine, 1.5)
	var ue_cosine := -rect_phase_cosine
	var ue_phase := (1.0 - anisotropy * anisotropy) \
			/ pow(1.0 + anisotropy * anisotropy + 2.0 * anisotropy * ue_cosine, 1.5)
	_require(is_equal_approx(frp_phase, ue_phase),
			"FRP minus-sign HG with dot(L, viewRay) matches UE plus-sign HG with -dot(L, CameraVector)")
	var source: Dictionary = result.get("source_texture", {})
	_require(bool(source.get("valid", false)), "AreaLight3D source atlas rect yields a texture sample")
	if bool(source.get("valid", false)):
		_require(source.get("local_uv", Vector2.ZERO).is_equal_approx(Vector2(0.5, 0.5)),
				"center ray maps to the center of the rect source texture")
		_require(source.get("uv", Vector2.ZERO).is_equal_approx(atlas_rect.get_center()),
				"center source sample maps to the AreaLight3D atlas rectangle center")
		_require(float(source.get("mip", -1.0)) <= 4.0,
				"source mip stays within the native area-atlas mip limit")
		_require(bool(result.get("source_texture_enabled", false)),
				"bound source atlas is enabled without a second IES multiplier")
	var large_atlas_rect := Rect2(0.125, 0.25, 0.5, 0.5)
	var to_light := Vector3(0.0, 0.0, 5.0)
	var edge_case := RectLight._source_texture_sample(
			Vector3(2.0, 0.0, 5.0).normalized(), to_light, Vector3.RIGHT, Vector3.UP,
			Vector3(0.0, 0.0, -1.0), Vector2(2.0, 3.0), large_atlas_rect,
			Vector2i(4096, 4096), 10.0)
	_require(bool(edge_case.get("valid", false))
			and is_equal_approx(edge_case.get("local_uv", Vector2.ZERO).x, 1.0)
			and is_equal_approx(edge_case.get("local_uv", Vector2.ZERO).y, 0.5),
			"noncenter ray through the right half-extent maps to local U=1")
	var left_edge_case := RectLight._source_texture_sample(
			Vector3(-2.0, 0.0, 5.0).normalized(), to_light, Vector3.RIGHT, Vector3.UP,
			Vector3(0.0, 0.0, -1.0), Vector2(2.0, 3.0), large_atlas_rect,
			Vector2i(4096, 4096), 10.0)
	_require(bool(left_edge_case.get("valid", false))
			and is_equal_approx(left_edge_case.get("local_uv", Vector2.ONE).x, 0.0),
			"left half-extent maps to local U=0")
	var upper_edge_case := RectLight._source_texture_sample(
			Vector3(0.0, 3.0, 5.0).normalized(), to_light, Vector3.RIGHT, Vector3.UP,
			Vector3(0.0, 0.0, -1.0), Vector2(2.0, 3.0), large_atlas_rect,
			Vector2i(4096, 4096), 10.0)
	_require(bool(upper_edge_case.get("valid", false))
			and is_equal_approx(upper_edge_case.get("local_uv", Vector2.ONE).y, 0.0),
			"positive height half-extent follows UE's inverted V mapping to local V=0")
	var lower_edge_case := RectLight._source_texture_sample(
			Vector3(0.0, -3.0, 5.0).normalized(), to_light, Vector3.RIGHT, Vector3.UP,
			Vector3(0.0, 0.0, -1.0), Vector2(2.0, 3.0), large_atlas_rect,
			Vector2i(4096, 4096), 10.0)
	_require(bool(lower_edge_case.get("valid", false))
			and is_equal_approx(lower_edge_case.get("local_uv", Vector2.ZERO).y, 1.0),
			"negative height half-extent follows UE's inverted V mapping to local V=1")
	var expected_half_extent_lod := minf(log(sqrt(29.0) / sqrt(6.0)) / log(2.0) + 11.0 - 2.0, 10.0)
	_require(absf(float(edge_case.get("mip", -1.0)) - expected_half_extent_lod) < 0.0002
			and edge_case.get("half_extent", Vector2.ZERO).is_equal_approx(Vector2(2.0, 3.0)),
			"atlas LOD uses UE's half extents rather than the native full-span dimensions")

	var front_result := RectLight.evaluate_volume(
			Vector3(0.0, 0.0, -5.5), Vector3(0.0, 0.0, -5.0),
			Vector3(2.0, 0.0, 0.0), Vector3(0.0, 2.0, 0.0), Vector3(0.0, 0.0, -1.0),
			0.1, 1.0, 1.0, Rect2(), Vector2i.ZERO, 0.0, true)
	_require(bool(front_result.get("front_facing", false)), "front-facing area receiver passes its plane mask")
	_require(is_equal_approx(float(front_result.get("soft_fade", -1.0)), 0.5),
			"near emitter soft fade scales with the actual front distance")
	_require(not bool(front_result.get("source_texture_enabled", true)),
			"no packed source rect defaults to an untextured white multiplier")

	var back_result := RectLight.evaluate_volume(
			Vector3(0.0, 0.0, 0.0), Vector3(0.0, 0.0, -5.0),
			Vector3(2.0, 0.0, 0.0), Vector3(0.0, 2.0, 0.0), Vector3(0.0, 0.0, -1.0),
			0.1, 1.0, 1.0)
	_require(not bool(back_result.get("front_facing", true)), "back-facing area receiver is rejected")
	_require(float(back_result.get("front_mask", 1.0)) == 0.0,
			"back-facing area contribution has zero front mask")

	var zero_extent := RectLight.evaluate_volume(
			Vector3.ZERO, Vector3(0.0, 0.0, -5.0), Vector3.ZERO,
			Vector3(0.0, 2.0, 0.0), Vector3(0.0, 0.0, -1.0), 0.1, 1.0, 1.0)
	_require(not bool(zero_extent.get("valid", true)), "zero-size area source is rejected")
	_test_rect_barn_doors()


func _test_rect_barn_doors() -> void:
	var to_light := Vector3(0.0, 0.0, 10.0)
	var width := Vector3(4.0, 0.0, 0.0)
	var height := Vector3(0.0, 2.0, 0.0)
	var native_forward := Vector3(0.0, 0.0, -1.0)
	var cos_60 := cos(deg_to_rad(60.0))
	var center := RectLight.visible_rect(to_light, width, height, native_forward,
			cos_60, 4.0, true)
	_require(bool(center.get("valid", false)) and not bool(center.get("clipped", true)),
			"center receiver keeps the full UE rect because all four door projections are symmetric")
	_compare_rect_to_ue_literal(to_light, width, height, native_forward, cos_60, 4.0, true,
			"center receiver")

	var off_axis_to_light := Vector3(30.0, 0.0, 10.0)
	var off_axis := RectLight.visible_rect(off_axis_to_light, width, height,
			native_forward, cos_60, 4.0, true)
	_require(bool(off_axis.get("valid", false)) and bool(off_axis.get("clipped", false))
			and Vector2(off_axis.get("half_extent", Vector2.ZERO)).x < 2.0
			and Vector2(off_axis.get("half_extent", Vector2.ZERO)).y == 1.0,
			"off-axis receiver clips only the occluded side of the barn-door rectangle")
	_compare_rect_to_ue_literal(off_axis_to_light, width, height, native_forward,
			cos_60, 4.0, true, "off-axis partial clip")
	_require(Vector3(off_axis.get("to_light", Vector3.ZERO)).x > off_axis_to_light.x,
			"UE RectOffset shifts the visible rectangle toward the exposed side")

	var blocked := RectLight.visible_rect(Vector3(100.0, 0.0, 10.0), width,
			height, native_forward, cos_60, 4.0, true)
	_require(not bool(blocked.get("valid", true)),
			"receiver outside both door projections gets a zero-width fully blocked rect")
	_compare_rect_to_ue_literal(Vector3(100.0, 0.0, 10.0), width, height,
			native_forward, cos_60, 4.0, true, "fully blocked receiver")

	var cos_88 := cos(deg_to_rad(88.0))
	var at_88 := RectLight.visible_rect(to_light, width, height, native_forward,
			cos_88, 4.0, true)
	_require(bool(at_88.get("valid", false)) and not bool(at_88.get("clipped", true))
			and Vector3(at_88.get("area_width", Vector3.ZERO)).is_equal_approx(width),
			"the UE 88-degree cutoff leaves the full rect unchanged")
	_compare_rect_to_ue_literal(to_light, width, height, native_forward, cos_88, 4.0, true,
			"88-degree threshold")
	var at_cos_cutoff := RectLight.visible_rect(to_light, width, height,
			native_forward, 0.035, 4.0, true)
	_require(bool(at_cos_cutoff.get("valid", false))
			and not bool(at_cos_cutoff.get("clipped", true)),
			"the exact UE barn-door cosine cutoff leaves the full rect unchanged")
	var zero_length := RectLight.visible_rect(to_light, width, height, native_forward,
			cos_60, 0.0, true)
	_require(bool(zero_length.get("valid", false)) and not bool(zero_length.get("clipped", true)),
			"zero barn length leaves the full source rectangle unchanged")
	var disabled := RectLight.visible_rect(to_light, width, height, native_forward,
			cos_60, 4.0, false)
	_require(bool(disabled.get("valid", false)) and not bool(disabled.get("clipped", true)),
			"disabled barn doors leave the full source rectangle unchanged")
	var disabled_backside := RectLight.visible_rect(Vector3(0.0, 0.0, -10.0),
			width, height, native_forward, cos_60, 4.0, false)
	_require(bool(disabled_backside.get("valid", false))
			and Vector3(disabled_backside.get("area_width", Vector3.ZERO)).is_equal_approx(width),
			"disabled GetRect geometry returns the full source even when the receiver is behind it")

	var rotation := Basis(Vector3(1.0, 2.0, -1.0).normalized(), 0.73)
	var rotated := RectLight.visible_rect(rotation * off_axis_to_light,
			rotation * width, rotation * height, rotation * native_forward,
			cos_60, 4.0, true)
	_compare_rect_to_ue_literal(rotation * off_axis_to_light, rotation * width,
			rotation * height, rotation * native_forward, cos_60, 4.0, true,
			"rotated off-axis receiver")
	_require(bool(rotated.get("valid", false))
			and Vector3(rotated.get("to_light", Vector3.ZERO)).distance_to(
					rotation * Vector3(off_axis.get("to_light", Vector3.ZERO))) < 0.0001,
			"rotating the complete light frame rotates the clipped result without changing its local clip")

	var backside := RectLight.visible_rect(Vector3(0.0, 0.0, -10.0), width,
			height, native_forward, cos_60, 4.0, true)
	_require(not bool(backside.get("valid", true)),
			"receiver behind the emitting plane fails closed")
	var zero_area := RectLight.visible_rect(to_light, Vector3.ZERO, height,
			native_forward, cos_60, 4.0, true)
	_require(not bool(zero_area.get("valid", true))
			and Vector3(zero_area.get("to_light", Vector3.ZERO)).is_finite(),
			"zero area returns a finite invalid rect")
	var overflowing := RectLight.visible_rect(Vector3(0.0, 0.0, 10.0),
			Vector3(1.0e30, 0.0, 0.0), height, native_forward, cos_60, 4.0, true)
	_require(not bool(overflowing.get("valid", true))
			and Vector3(overflowing.get("to_light", Vector3.ZERO)).is_finite()
			and Vector3(overflowing.get("area_width", Vector3.ZERO)).is_finite(),
			"finite but overflowing source dimensions return a finite neutral rect")

	var clipped_volume := RectLight.evaluate_volume(
			Vector3(-30.0, 0.0, -10.0), Vector3.ZERO, width, height, native_forward,
			0.1, 10.0, 1.0, Rect2(), Vector2i.ZERO, 0.0, false,
			Vector3(0.0, 0.0, -1.0), cos_60, 4.0, true)
	_require(bool(clipped_volume.get("visible_rect", {}).get("clipped", false))
			and float(clipped_volume.get("integrate_light", 0.0)) > 0.0,
			"area integration consumes the clipped rectangle while phase remains center-based")
	var clipped_rect: Dictionary = clipped_volume.get("visible_rect", {})
	var literal_integral := _ue_rect_integral_literal(clipped_rect.to_light,
			clipped_rect.area_width, clipped_rect.area_height)
	_require(absf(float(clipped_volume.get("integrate_light", 0.0)) - literal_integral) < 0.000001,
			"the scalar area integral is evaluated from the clipped UE origin and extents")
	_require(is_equal_approx(float(clipped_volume.get("phase_cosine", 0.0)), -1.0)
			and not bool(clipped_volume.get("source_texture_enabled", true)),
			"barn clipping does not move the original-center phase or enable an absent source texture")
	var source_rect := Rect2(0.125, 0.25, 0.5, 0.5)
	var original_source_sample := RectLight.evaluate_volume(
			Vector3(-30.0, 0.0, -10.0), Vector3.ZERO, width, height, native_forward,
			0.1, 10.0, 1.0, source_rect, Vector2i(2048, 2048), 8.0, false)
	var clipped_source_sample := RectLight.evaluate_volume(
			Vector3(-30.0, 0.0, -10.0), Vector3.ZERO, width, height, native_forward,
			0.1, 10.0, 1.0, source_rect, Vector2i(2048, 2048), 8.0, false,
			Vector3(0.0, 0.0, -1.0), cos_60, 4.0, true)
	var original_source: Dictionary = original_source_sample.get("source_texture", {})
	var clipped_source: Dictionary = clipped_source_sample.get("source_texture", {})
	_require(bool(clipped_source_sample.get("visible_rect", {}).get("clipped", false))
			and clipped_source.get("uv", Vector2.ZERO).is_equal_approx(original_source.get("uv", Vector2.ONE))
			and is_equal_approx(float(clipped_source.get("mip", -1.0)),
					float(original_source.get("mip", -2.0))),
			"source-texture UV and mip continue using original center and full area spans")


func _compare_rect_to_ue_literal(p_to_light: Vector3, p_width: Vector3,
		p_height: Vector3, p_native_forward: Vector3, p_cos_angle: float,
		p_barn_length: float, p_enabled: bool, p_label: String) -> void:
	var expected := _ue_get_rect_literal(p_to_light, p_width, p_height,
			p_native_forward, p_cos_angle, p_barn_length, p_enabled)
	var actual := RectLight.visible_rect(p_to_light, p_width, p_height,
			p_native_forward, p_cos_angle, p_barn_length, p_enabled)
	_require(bool(actual.get("valid", false)) == bool(expected.get("valid", false)),
			p_label + " valid result matches the literal UE formula")
	if bool(expected.get("valid", false)):
		_require(Vector3(actual.get("to_light", Vector3.ZERO)).distance_to(expected.to_light) < 0.0001
				and Vector3(actual.get("area_width", Vector3.ZERO)).distance_to(expected.area_width) < 0.0001
				and Vector3(actual.get("area_height", Vector3.ZERO)).distance_to(expected.area_height) < 0.0001,
				p_label + " shifted center and full-span axes match the literal UE formula")
		_require(Vector2(actual.get("half_extent", Vector2.ZERO)).distance_to(expected.half_extent) < 0.0001
				and Vector2(actual.get("offset", Vector2.ZERO)).distance_to(expected.offset) < 0.0001,
				p_label + " extent and origin offset match the literal UE formula")


## Independently transcribed from UE RectLight.ush::GetRect, lines 602-687.
## This test oracle uses the source's Axis[] projection and clamp sequence rather
## than calling the production helper's intermediate utilities.
func _ue_get_rect_literal(p_to_light: Vector3, p_width: Vector3,
		p_height: Vector3, p_native_forward: Vector3, p_cos_angle: float,
		p_barn_length: float, p_enabled: bool) -> Dictionary:
	if not p_to_light.is_finite() or not p_width.is_finite() \
			or not p_height.is_finite() or not p_native_forward.is_finite() \
			or not is_finite(p_cos_angle) or not is_finite(p_barn_length):
		return {"valid": false}
	var width_length := p_width.length()
	var height_length := p_height.length()
	if width_length <= 0.01 or height_length <= 0.01 or p_native_forward.length_squared() <= 0.0001:
		return {"valid": false}
	var axis_1 := p_height / height_length
	var axis_2 := -p_native_forward.normalized()
	var axis_0 := axis_1.cross(axis_2).normalized()
	if axis_0.dot(p_width.normalized()) < 0.999:
		return {"valid": false}
	var extent := Vector2(width_length, height_length) * 0.5
	var source_origin := p_to_light
	var offset := Vector2.ZERO
	if axis_2.dot(p_to_light) <= 0.0:
		return {"valid": false}
	if p_enabled and p_cos_angle > 0.035 and p_barn_length > 0.0:
		var s_light := Vector3(axis_0.dot(p_to_light), axis_1.dot(p_to_light), axis_2.dot(p_to_light))
		var sin_theta := sqrt(1.0 - p_cos_angle * p_cos_angle)
		var barn_depth := minf(s_light.z, p_cos_angle * p_barn_length)
		var s_ratio := barn_depth / maxf(0.0001, p_cos_angle * p_barn_length)
		var d_b := sin_theta * p_barn_length * s_ratio
		var sign_s := Vector2(sign(s_light.x), sign(s_light.y))
		s_light.x = sign_s.x * maxf(absf(s_light.x), extent.x + d_b)
		s_light.y = sign_s.y * maxf(absf(s_light.y), extent.y + d_b)
		var corner := Vector3(sign_s.x * (extent.x + d_b), sign_s.y * (extent.y + d_b), barn_depth)
		var s_proj := s_light - corner
		var cos_eta := maxf(s_proj.z, 0.001)
		var d_s := Vector2(absf(s_proj.x), absf(s_proj.y)) / cos_eta * barn_depth
		var min_xy := Vector2(
				clampf(-extent.x + (d_s.x - d_b) * maxf(0.0, -sign_s.x), -extent.x, extent.x),
				clampf(-extent.y + (d_s.y - d_b) * maxf(0.0, -sign_s.y), -extent.y, extent.y))
		var max_xy := Vector2(
				clampf(extent.x - (d_s.x - d_b) * maxf(0.0, sign_s.x), -extent.x, extent.x),
				clampf(extent.y - (d_s.y - d_b) * maxf(0.0, sign_s.y), -extent.y, extent.y))
		offset = 0.5 * (min_xy + max_xy)
		extent = 0.5 * (max_xy - min_xy)
		if extent.x <= 0.0 or extent.y <= 0.0:
			return {"valid": false}
		source_origin = source_origin - axis_0 * offset.x - axis_1 * offset.y
	return {
		"valid": true,
		"to_light": source_origin,
		"area_width": axis_0 * (2.0 * extent.x),
		"area_height": axis_1 * (2.0 * extent.y),
		"half_extent": extent,
		"offset": offset,
	}


## Independent literal RectLightIntegrate.ush spherical-polygon formula. The
## clipped-rectangle test calls this with the returned geometry, then compares
## against evaluate_volume's integral to prove the consumer uses that geometry.
func _ue_rect_integral_literal(p_to_light: Vector3, p_width: Vector3,
		p_height: Vector3) -> float:
	var corners: Array[Vector3] = [
			(p_to_light - p_width * 0.5 - p_height * 0.5).normalized(),
			(p_to_light + p_width * 0.5 - p_height * 0.5).normalized(),
			(p_to_light + p_width * 0.5 + p_height * 0.5).normalized(),
			(p_to_light - p_width * 0.5 + p_height * 0.5).normalized(),
	]
	var w01 := (1.5708 - 0.175 * corners[0].dot(corners[1])) \
			/ sqrt(maxf(corners[0].dot(corners[1]) + 1.0, 0.0001))
	var w12 := (1.5708 - 0.175 * corners[1].dot(corners[2])) \
			/ sqrt(maxf(corners[1].dot(corners[2]) + 1.0, 0.0001))
	var w23 := (1.5708 - 0.175 * corners[2].dot(corners[3])) \
			/ sqrt(maxf(corners[2].dot(corners[3]) + 1.0, 0.0001))
	var w30 := (1.5708 - 0.175 * corners[3].dot(corners[0])) \
			/ sqrt(maxf(corners[3].dot(corners[0]) + 1.0, 0.0001))
	var spherical_integral := corners[1].cross(-w01 * corners[0] + w12 * corners[2]) \
			+ corners[3].cross(w30 * corners[0] - w23 * corners[2])
	return 0.5 * spherical_integral.length()


func _test_sky_runtime_metadata() -> void:
	var viewport := SubViewport.new()
	var world := World3D.new()
	viewport.world_3d = world
	root.add_child(viewport)
	var provider := FakeSkyProvider.new()
	viewport.add_child(provider)
	await process_frame
	FengSkyRuntime.refresh_provider(provider)
	var metadata := FengSkyRuntime.volumetric_metadata_for_world(world.get_instance_id())
	_require(bool(metadata.get("ready", false)), "runtime exposes active ready provider metadata")
	_require(int(metadata.get("provider_id", 0)) == provider.get_instance_id(),
			"metadata identifies the active registered sky provider")
	_require(is_equal_approx(float(metadata.get("volumetric_scattering_intensity", 0.0)), 1.5),
			"runtime metadata preserves the authored volumetric scattering intensity")
	_require(not provider.readback_requested,
			"volumetric metadata path does not request the CPU radiance SH snapshot")
	FengSkyRuntime.unregister_provider(provider)
	viewport.queue_free()
	await process_frame


func _test_capsule_light() -> void:
	_require(is_equal_approx(CapsuleLight.distance_bias_m(0.0), 0.01)
			and is_equal_approx(CapsuleLight.distance_bias_m(0.05, 2.0), 0.1),
			"UE one-centimeter distance-bias minimum is converted to meters")
	var point := CapsuleLight.integrate(Vector3(0.0, 0.0, 2.0), Vector3.UP,
			0.0, 0.01, true)
	_require(bool(point.get("valid", false))
			and is_equal_approx(float(point.get("falloff", 0.0)), 1.0 / 4.0001)
			and point.direction.is_equal_approx(Vector3.BACK),
			"zero-length capsule uses UE's inverse-square point integral")
	var diffuse_point := CapsuleLight.integrate(Vector3(0.0, 0.0, 2.0), Vector3.UP,
			0.0, 0.01, false)
	_require(bool(diffuse_point.get("valid", false))
			and is_equal_approx(float(diffuse_point.get("falloff", 0.0)), 1.0),
			"non-inverse-squared mode leaves the capsule integral falloff at one")
	var zero_distance := CapsuleLight.integrate(Vector3.ZERO, Vector3.UP,
			0.0, 0.0, true)
	_require(bool(zero_distance.get("valid", false))
			and is_equal_approx(float(zero_distance.get("falloff", 0.0)), 1.0 / 1.0e-12),
			"zero-distance, zero-bias point input remains finite and matches the GPU epsilon guard")
	var line := CapsuleLight.integrate(Vector3(0.0, 0.0, 3.0), Vector3.RIGHT,
			2.0, 0.01, true)
	var expected_line_falloff := 0.1 / (0.9 + 0.00001)
	_require(bool(line.get("valid", false))
			and absf(float(line.get("falloff", 0.0)) - expected_line_falloff) < 0.000001,
			"nonzero capsule matches UE's two-endpoint inverse-square expression")
	_require(line.direction.is_equal_approx(Vector3(0.0, 0.0, 3.0 / sqrt(10.0))),
			"line direction is UE's unnormalized average of normalized endpoint vectors")
	var diffuse_line := CapsuleLight.integrate(Vector3(0.0, 0.0, 3.0), Vector3.RIGHT,
			2.0, 0.01, false)
	_require(bool(diffuse_line.get("valid", false))
			and is_equal_approx(float(diffuse_line.get("falloff", 0.0)), 1.0)
			and diffuse_line.direction.is_equal_approx(line.direction),
			"non-inverse-squared line keeps UE's segment direction but removes falloff")
	var endpoint_singularity := CapsuleLight.integrate(Vector3(2.0, 0.0, 0.0),
			Vector3.RIGHT, 4.0, 0.01, true)
	_require(bool(endpoint_singularity.get("valid", false))
			and is_equal_approx(float(endpoint_singularity.get("falloff", 0.0)), 1.0 / 4.0001)
			and endpoint_singularity.direction.is_equal_approx(Vector3.RIGHT),
			"collapsed segment endpoint uses the same finite point-source limit as GLSL")
	var rotated := Transform3D(Basis(Vector3.FORWARD, PI * 0.5), Vector3.ZERO)
	var rotated_axis := CapsuleLight.axis_world_from_light_transform(rotated, 1)
	_require(rotated_axis.distance_to(rotated.basis.orthonormalized() * Vector3.UP) < 0.00001,
			"explicit local capsule axis follows the orthonormalized light basis")
	_require(CapsuleLight.axis_world_from_light_transform(Transform3D.IDENTITY, 3) == Vector3.ZERO,
			"an invalid capsule axis fails closed")
	var shader_source := FileAccess.get_file_as_string(
			"res://addons/feng-fog/rendering/lighting/fog_capsule_light.glslinc")
	_require(shader_source.contains("0.5 * cosine_subtended + 0.5")
			and shader_source.contains("inverse_lengths / denominator")
			and shader_source.contains("ffog_light_capsule_axis_world"),
			"GLSL helper mirrors UE capsule integration and explicit ABI v2 axis")
