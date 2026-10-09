extends SceneTree
## CPU contract checks for per-light extension registration, mapping and packing.

const Layout = preload("res://addons/feng-fog/rendering/lighting/light_extensions/fog_light_extension_layout.gd")
const Extension = preload("res://addons/feng-fog/rendering/lighting/light_extensions/fog_light_extension.gd")
const Registry = preload("res://addons/feng-fog/rendering/lighting/light_extensions/fog_light_extension_registry.gd")
const Provider = preload("res://addons/feng-fog/rendering/lighting/light_extensions/fog_light_extension_provider.gd")

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
	_test_cookie_sampler_requirements()
	await _test_scene_registry_and_snapshots()
	_test_record_layout_and_uv()
	_test_spot_cone_angle_math()
	_test_invalid_contracts()
	if _failures == 0:
		print("PASS fog light extensions (%d checks)" % _checks)
	else:
		push_error("fog light extension tests failed: %d/%d" % [_failures, _checks])
	quit(1 if _failures > 0 else 0)


func _test_cookie_sampler_requirements() -> void:
	_require(not Provider.requires_cookie_resampling(0)
			and Provider.requires_cookie_resampling(1)
			and Provider.requires_cookie_resampling(4),
		"empty neutral cookie arrays do not require a resample pipeline")
	var provider_source := FileAccess.get_file_as_string(
			"res://addons/feng-fog/rendering/lighting/light_extensions/fog_light_extension_provider.gd")
	var sampler_ensure := provider_source.find("if not _ensure_cookie_sampler(p_rd)")
	var row_collection := provider_source.find("var sources := _collect_cookie_sources(rows, p_rd)")
	_require(sampler_ensure >= 0 and row_collection > sampler_ensure
			and provider_source.contains("\"cookie_sampler\": _sampler"),
		"every valid result creates a sampler before the empty-cookie neutral path")
	var neutral_branch := provider_source.find("if not requires_cookie_resampling(p_items.size()):")
	var pipeline_branch := provider_source.find("if not _ensure_resample_pipeline(p_rd):")
	_require(neutral_branch >= 0 and pipeline_branch > neutral_branch
			and not provider_source.substr(neutral_branch,
				pipeline_branch - neutral_branch).contains("_ensure_resample_pipeline"),
		"neutral cookie path remains independent from shader and pipeline compilation")


func _test_scene_registry_and_snapshots() -> void:
	var viewport := SubViewport.new()
	var world := World3D.new()
	viewport.world_3d = world
	root.add_child(viewport)
	var omni := OmniLight3D.new()
	viewport.add_child(omni)
	var spot := SpotLight3D.new()
	spot.spot_angle = 45.0
	viewport.add_child(spot)
	var area := AreaLight3D.new()
	viewport.add_child(area)
	var directional := DirectionalLight3D.new()
	viewport.add_child(directional)
	await process_frame
	var light_rids := [omni.get_base(), spot.get_base(), area.get_base(), directional.get_base()]
	var native_rids_available := true
	for light in [omni, spot, area, directional]:
		_require(light is Light3D and light.is_inside_tree(), "real Light3D nodes enter the test World3D")
	for rid in light_rids:
		native_rids_available = native_rids_available and rid.is_valid()
	var extensions: Array[Node] = []
	for light in [omni, spot, area, directional]:
		var extension := Extension.new()
		light.add_child(extension)
		extensions.append(extension)
	extensions[3].set("static_lighting_key", &"PrimarySun")
	await process_frame
	var frame := _frame_for_lights(omni, spot, area, directional)
	var metadata_snapshot := Registry.snapshot_metadata_for_world(world.get_instance_id())
	_require(bool(metadata_snapshot.get("valid", false))
			and int(metadata_snapshot.get("abi_version", 0)) == 1
			and metadata_snapshot.get("by_light_rid") is Dictionary,
			"main-thread metadata phase emits a versioned RID-keyed value snapshot without native frame inputs")
	if native_rids_available:
		var metadata_rows: Dictionary = metadata_snapshot.get("by_light_rid", {})
		_require(metadata_rows.size() == 4,
				"metadata phase captures each registered light extension before native frame arrays exist")
		for metadata_row in metadata_rows.values():
			_require(not metadata_row is Node and not metadata_row is Resource,
					"metadata values crossing to the renderer contain no Node or Resource references")
		var directional_metadata: Dictionary = metadata_rows.get(light_rids[3], {})
		_require(String(directional_metadata.get("static_lighting_key", "")) == "PrimarySun",
				"stable primary-Sun match key crosses the main-thread metadata snapshot as a plain value")
		var joined_snapshot := Registry.join_native_frame(metadata_snapshot, frame,
				world.get_instance_id())
		_require(bool(joined_snapshot.get("valid", false))
				and joined_snapshot.get("rows", []).size() == 4
				and int(joined_snapshot.get("frame_generation", -1)) == int(frame.frame_generation),
				"value-only join uses same-frame native RID order and preserves frame generation")
		var active_only_frame := _empty_native_frame()
		active_only_frame["frame_generation"] = frame.frame_generation
		active_only_frame["omni_light_count"] = 1
		active_only_frame["omni_light_base_rids"] = [light_rids[0]]
		var active_only_join := Registry.join_native_frame(metadata_snapshot,
				active_only_frame, world.get_instance_id())
		_require(bool(active_only_join.get("valid", false))
				and active_only_join.get("rows", []).size() == 1
				and int(active_only_join.rows[0].get("source_extension_id", 0)) != 0,
				"valid world metadata for culled lights is ignored while active native RID rows still join")
		var snapshot := Registry.snapshot_for_world(world.get_instance_id(), frame)
		_require(bool(snapshot.get("valid", false)), "valid same-frame native RID arrays produce a value snapshot")
		_require(snapshot.get("native_order", []) == ["omni", "spot", "area", "directional"],
				"snapshot ordering exactly follows FRP native light buffer order")
		var rows: Array = snapshot.get("rows", [])
		_require(rows.size() == 4, "snapshot has one record row for every active native light")
		if rows.size() == 4:
			for index in 4:
				_require(rows[index].get("light_rid") == light_rids[index],
						"snapshot keeps the native RID ordering at row %d" % index)
				_require(int(rows[index].get("source_extension_id", 0)) != 0,
						"same-world extension is joined to its native RID")
			_require(int(rows[0].mapping_type) == Layout.MAPPING_OMNI_DUAL_PARABOLOID,
					"AUTO mapping resolves to omni dual paraboloid")
			_require(int(rows[1].mapping_type) == Layout.MAPPING_SPOT_PERSPECTIVE,
					"AUTO mapping resolves to spot perspective")
			_require(int(rows[2].mapping_type) == Layout.MAPPING_AREA_PLANE,
					"AUTO mapping resolves to area plane")
			_require(int(rows[3].mapping_type) == Layout.MAPPING_DIRECTIONAL_ORTHOGRAPHIC,
					"AUTO mapping resolves to directional orthographic")
			_require(String(rows[3].static_lighting_key) == "PrimarySun",
					"same-frame directional row retains the VLM primary-Sun match key")
			_require(is_equal_approx(float(rows[0].mapping_range_m), omni.omni_range),
					"omni cookie range defaults to the native light range")
			_require(is_equal_approx(float(rows[1].tan_half_spot_angle),
					Extension._spot_angle_tangent_for_cookie(spot.spot_angle)),
					"spot projection tangent uses the native authored cone half-angle")
			_require(rows[2].area_half_size_m.is_equal_approx(area.area_size * 0.5),
					"area projection uses native half extents")
			_require(not bool(rows[2].barn_door_enabled),
					"UE-compatible 88-degree default leaves area barn doors disabled")
			_require(is_equal_approx(float(rows[2].barn_door_length_m), 0.2),
					"UE 20 cm barn-door length is represented as 0.2 m")
			_require(float(rows[0].source_length_m) == 0.0
					and int(rows[0].capsule_axis_local) == 1,
					"capsule source defaults to a point with local Y axis and never infers length from Light3D.size")
		for row in rows:
			_require(float(row.cookie_strength) == 0.0,
					"light function strength defaults to neutral zero")
			_require(not row.cookie_texture_rd_rid.is_valid(),
					"disabled cookie does not resolve a source texture RID")
	else:
		var fail_closed := Registry.snapshot_for_world(world.get_instance_id(), frame)
		_require(not bool(fail_closed.get("valid", true)),
				"headless Dummy RenderingServer invalid base RIDs are rejected instead of joined")
		_require(Registry.registered_light_count(world.get_instance_id()) == 0,
				"Dummy RenderingServer cannot create native RID joins; no invalid extension is registered")
		for extension in extensions:
			_require(extension.get_target_light() != null,
					"extension still resolves its actual Light3D node without an RD backend")
		_require(is_equal_approx(extensions[2].barn_door_angle_degrees, 88.0)
				and is_equal_approx(extensions[2].barn_door_length_m, 0.2),
				"UE barn-door defaults remain available without renderer RIDs")
		_require(String(extensions[3].get("static_lighting_key")) == "PrimarySun",
				"directional extension retains its stable VLM key without requiring native RIDs")
		print("SKIP active/inactive metadata join: headless Dummy RenderingServer cannot create real Light3D base RIDs.")

	var image := Image.create(4, 2, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.25, 0.5, 0.75, 1.0))
	var texture := ImageTexture.create_from_image(image)
	var omni_extension = extensions[0]
	omni_extension.light_function_enabled = true
	omni_extension.light_function_texture = texture
	omni_extension.light_function_strength = 0.65
	omni_extension.mapping_scale = Vector2(0.75, 0.5)
	omni_extension.mapping_offset = Vector2(0.125, 0.25)
	omni_extension.volumetric_shadow_policy = Extension.VolumetricShadowPolicy.HARDWARE_RT_OPT_IN
	var resource_id := texture.get_instance_id()
	_require(Layout.is_resource_identity_valid(resource_id),
			"real Texture2D instance identity accepts signed Resource IDs")
	var texture_rid := texture.get_rid()
	if texture_rid.is_valid():
		_require(Provider.source_identity_is_valid(resource_id, texture_rid),
				"source identity validation accepts a real Texture2D RID")
	else:
		_require(not Provider.source_identity_is_valid(resource_id, texture_rid),
				"Dummy RenderingServer invalid texture RIDs fail closed")
	_require(Layout.is_resource_identity_valid(resource_id),
			"signed Texture2D Resource identity remains valid in the value path")
	if native_rids_available:
		var updated := Registry.snapshot_for_world(world.get_instance_id(), frame)
		var updated_rows: Array = updated.get("rows", [])
		if updated_rows.size() == 4:
			var cookie_row: Dictionary = updated_rows[0]
			_require(float(cookie_row.cookie_strength) > 0.64,
					"enabled cookie strength appears in the plain-value snapshot")
			_require(int(cookie_row.cookie_texture_resource_id) == resource_id,
					"snapshot records source identity without retaining the Texture2D object")
			_require(int(cookie_row.shadow_policy) == Layout.SHADOW_HARDWARE_RT_OPT_IN,
					"shadow request is preserved as metadata")
			_require(cookie_row.mapping_scale.is_equal_approx(Vector2(0.75, 0.5))
					and cookie_row.mapping_offset.is_equal_approx(Vector2(0.125, 0.25)),
					"explicit mapping scale and offset survive the snapshot")
			_require(cookie_row.cookie_texture_rd_rid is RID,
					"snapshot transports only a RenderingDevice RID for texture use")
		_require(not updated.has("texture_resource") and not updated.has("light_node"),
				"render snapshot does not carry a Resource or Node object")
	var another_world := World3D.new()
	if native_rids_available:
		var cross_world := Registry.snapshot_for_world(another_world.get_instance_id(), frame)
		_require(bool(cross_world.get("valid", false))
					and int(cross_world.rows[0].get("source_extension_id", 0)) == 0,
				"a different World3D cannot see this world's extension metadata")
	var duplicate := Extension.new()
	omni.add_child(duplicate)
	await process_frame
	if native_rids_available:
		_require_duplicate_state(world)
	duplicate.queue_free()
	await process_frame
	if native_rids_available:
		_require(Registry.registered_light_count(world.get_instance_id()) == 4,
				"weak registry remains stable after duplicate removal")
	for extension in extensions:
		extension.queue_free()
	viewport.queue_free()
	await process_frame
	_require(Registry.registered_light_count(world.get_instance_id()) == 0,
			"world registry releases extensions when their nodes leave the tree")
	if not native_rids_available:
		print("SKIP native RID join/duplicate assertions: headless Dummy RenderingServer returns RID(0).")


func _require_duplicate_state(p_world: World3D) -> void:
	_require(Registry.registered_light_count(p_world.get_instance_id()) == 4,
			"duplicate light extension does not replace the first registry entry")


func _frame_for_lights(p_omni: OmniLight3D, p_spot: SpotLight3D,
		p_area: AreaLight3D, p_directional: DirectionalLight3D) -> Dictionary:
	return {
		"abi_version": 1,
		"valid": true,
		"frame_generation": 0x100000002,
		"omni_light_count": 1,
		"omni_light_base_rids": [p_omni.get_base()],
		"spot_light_count": 1,
		"spot_light_base_rids": [p_spot.get_base()],
		"area_light_count": 1,
		"area_light_base_rids": [p_area.get_base()],
		"directional_light_count": 1,
		"directional_light_base_rids": [p_directional.get_base()],
	}


func _test_record_layout_and_uv() -> void:
	var transform := Transform3D(Basis.from_euler(Vector3(0.0, PI * 0.5, 0.0)), Vector3(3.0, 4.0, 5.0))
	var row := {
		"world_to_light": transform,
		"native_kind": Layout.KIND_AREA,
		"mapping_type": Layout.MAPPING_AREA_PLANE,
		"mapping_range_m": 12.0,
		"tan_half_spot_angle": 0.5,
		"area_half_size_m": Vector2(2.0, 3.0),
		"mapping_scale": Vector2(0.75, 0.5),
		"mapping_offset": Vector2(0.125, 0.25),
		"barn_door_enabled": true,
		"barn_door_cos_angle": cos(deg_to_rad(45.0)),
		"barn_door_length_m": 0.2,
		"source_length_m": 1.25,
		"capsule_axis_local": 2,
		"cookie_strength": 0.65,
		"shadow_policy": Layout.SHADOW_HARDWARE_RT_OPT_IN,
	}
	var record := Layout.pack_record(row, 3)
	_require(record.size() == 144, "ABI v2 std430 record is exactly 144 bytes")
	if record.size() == 144:
		_require(is_equal_approx(record.decode_float(48), 3.0)
				and is_equal_approx(record.decode_float(52), 4.0)
				and is_equal_approx(record.decode_float(56), 5.0)
				and is_equal_approx(record.decode_float(60), 1.0),
				"world-to-light matrix is packed column-major with translation in column four")
		_require(is_equal_approx(record.decode_float(64), 12.0)
				and is_equal_approx(record.decode_float(72), 2.0)
				and is_equal_approx(record.decode_float(76), 3.0),
				"mapping range and area half extents occupy vec4 lane 64")
		_require(is_equal_approx(record.decode_float(96), cos(deg_to_rad(45.0)))
				and is_equal_approx(record.decode_float(100), 0.2)
				and is_equal_approx(record.decode_float(104), 1.0)
				and is_equal_approx(record.decode_float(108), 0.65),
				"barn metadata and cookie strength share the agreed vec4")
		_require(record.decode_u32(112) == Layout.MAPPING_AREA_PLANE
				and record.decode_u32(116) == 3
				and record.decode_u32(120) == Layout.SHADOW_HARDWARE_RT_OPT_IN
				and record.decode_u32(124) == Layout.FEATURE_COOKIE,
				"mode flags encode mapping, layer, shadow policy and feature bits")
		_require(is_equal_approx(record.decode_float(128), 1.25)
				and is_equal_approx(record.decode_float(132), 2.0)
				and record.decode_float(136) == 0.0 and record.decode_float(140) == 0.0,
				"ABI v2 appends explicit source length and local capsule axis after the v1 lanes")
	var header := Layout.pack_header(4, 3, 0x100000002)
	_require(header.size() == 16, "set-3 header is exactly 16 bytes")
	_require(header.decode_u32(0) == 2 and header.decode_u32(4) == 4
			and header.decode_u32(8) == 3 and header.decode_u32(12) == 2,
			"header carries ABI, record/layer counts, and low frame-generation bits")
	var neutral := Layout.pack_record({
		"world_to_light": Transform3D.IDENTITY,
		"mapping_type": Layout.MAPPING_NONE,
		"cookie_strength": 1.0,
	}, -1)
	_require(neutral.size() == 144 and neutral.decode_u32(116) == 0xFFFFFFFF
			and neutral.decode_u32(124) == 0 and neutral.decode_float(108) == 0.0,
			"missing source uses a neutral layer and disables cookie blending")
	_require(neutral.decode_float(128) == 0.0 and neutral.decode_float(132) == 1.0,
			"neutral ABI v2 capsule record is a point with default local Y axis")
	var spot_center := Layout.cookie_uv(Layout.MAPPING_SPOT_PERSPECTIVE,
			Vector3(0.0, 0.0, -2.0), 10.0, 0.5, Vector2.ZERO)
	_require(bool(spot_center.get("valid", false))
			and spot_center.uv.is_equal_approx(Vector2(0.5, 0.5)),
			"spot centerline maps to cookie center")
	var spot_edge := Layout.cookie_uv(Layout.MAPPING_SPOT_PERSPECTIVE,
			Vector3(1.0, 0.0, -2.0), 10.0, 0.5, Vector2.ZERO)
	_require(bool(spot_edge.get("valid", false))
			and spot_edge.uv.is_equal_approx(Vector2(1.0, 0.5)),
			"spot cone edge maps to cookie boundary")
	var area_edge := Layout.cookie_uv(Layout.MAPPING_AREA_PLANE,
			Vector3(2.0, -3.0, -1.0), 4.0, 0.0, Vector2(2.0, 3.0))
	_require(bool(area_edge.get("valid", false))
			and area_edge.uv.is_equal_approx(Vector2.ONE),
			"area half extents map to the texture corner")
	var omni_invalid := Layout.cookie_uv(Layout.MAPPING_OMNI_DUAL_PARABOLOID,
			Vector3(0.0, 0.0, 12.0), 10.0, 0.0, Vector2.ZERO)
	_require(not bool(omni_invalid.get("valid", true)),
			"omni cookie mapping rejects samples beyond the native range")


func _test_spot_cone_angle_math() -> void:
	var tangent_45 := Extension._spot_angle_tangent_for_cookie(45.0)
	_require(is_equal_approx(tangent_45, 1.0),
			"a 45-degree Godot spot half-angle maps to tan(angle)=1")
	var edge := Layout.cookie_uv(Layout.MAPPING_SPOT_PERSPECTIVE,
			Vector3(2.0, 0.0, -2.0), 10.0, tangent_45, Vector2.ZERO)
	_require(bool(edge.get("valid", false))
			and edge.uv.is_equal_approx(Vector2(1.0, 0.5)),
			"the 45-degree spot cone boundary maps to cookie UV (1, 0.5)")
	var tangent_at_pole := Extension._spot_angle_tangent_for_cookie(90.0)
	var tangent_over_pole := Extension._spot_angle_tangent_for_cookie(180.0)
	_require(is_finite(tangent_at_pole) and is_finite(tangent_over_pole)
			and tangent_at_pole > 0.0 and tangent_over_pole > 0.0,
			"90- and 180-degree authored angles stay finite at the perspective tangent pole")


func _test_invalid_contracts() -> void:
	var bad_frame := Layout.collect_native_rows({
		"abi_version": 1,
		"valid": true,
		"omni_light_count": 1,
		"omni_light_base_rids": [],
		"spot_light_count": 0,
		"spot_light_base_rids": [],
		"area_light_count": 0,
		"area_light_base_rids": [],
		"directional_light_count": 0,
		"directional_light_base_rids": [],
	})
	_require(not bool(bad_frame.get("valid", true)),
			"mismatched native light count fails closed")
	var zero_resource_id := Layout.is_resource_identity_valid(0)
	_require(not zero_resource_id, "only zero is an invalid Resource instance identity")
	var negative_resource_id := Layout.is_resource_identity_valid(-9223372036854770000)
	_require(negative_resource_id, "negative high-bit Resource identities remain valid")
	_test_two_phase_join_rejections()
	var empty_header := Layout.pack_header(0, 0, 7)
	_require(empty_header.decode_u32(4) == 0 and empty_header.decode_u32(8) == 0,
			"empty native light and cookie arrays publish explicit zero counts")
	var shader_include := FileAccess.get_file_as_string(
			"res://addons/feng-fog/rendering/lighting/light_extensions/fog_light_extension.glslinc")
	_require(shader_include.contains("FFogLightExtensionABIVersion = 2u")
			and shader_include.contains("set = 3, binding = 0")
			and shader_include.contains("set = 3, binding = 1")
			and shader_include.contains("set = 3, binding = 2"),
			"GLSL helper declares the agreed descriptor set and all three bindings")
	_require(shader_include.contains("ffog_light_extension_record_index")
			and shader_include.contains("native_type_counts.x + native_type_counts.y + native_type_counts.z"),
			"GLSL helper converts type-local native indices into flat record order")
	_require(shader_include.contains("capsule_source_shape")
			and shader_include.contains("ffog_light_capsule_axis_world"),
			"GLSL ABI v2 exposes source length and transforms the explicit local capsule axis")


func _test_two_phase_join_rejections() -> void:
	var world_id := 12345
	var metadata := Registry.snapshot_metadata_for_world(world_id)
	var empty_frame := _empty_native_frame()
	empty_frame["frame_generation"] = 91
	var joined := Registry.join_native_frame(metadata, empty_frame, world_id)
	_require(bool(joined.get("valid", false)) and int(joined.get("frame_generation", -1)) == 91
			and joined.get("rows", []).is_empty(),
			"empty same-world metadata joins a valid zero-light native frame")
	_require(not bool(Registry.join_native_frame(metadata, empty_frame, world_id + 1).get("valid", true)),
			"explicit expected World3D rejects metadata from another world")
	var other_world_frame := _empty_native_frame()
	other_world_frame["world_id"] = world_id + 1
	_require(not bool(Registry.join_native_frame(metadata, other_world_frame).get("valid", true)),
			"frame world identity rejects cross-world value joins")
	var wrong_abi := metadata.duplicate(true)
	wrong_abi["abi_version"] = 2
	_require(not bool(Registry.join_native_frame(wrong_abi, empty_frame, world_id).get("valid", true)),
			"metadata ABI mismatch is rejected before joining native rows")
	_require(Registry.metadata_native_kind_matches({"native_kind": Layout.KIND_SPOT}, Layout.KIND_SPOT)
			and not Registry.metadata_native_kind_matches({"native_kind": Layout.KIND_AREA}, Layout.KIND_SPOT),
			"metadata cannot reuse a same RID under a different native light-buffer kind")
	var stale_generation := metadata.duplicate(true)
	stale_generation["snapshot_generation"] = 0
	_require(not bool(Registry.join_native_frame(stale_generation, empty_frame, world_id).get("valid", true)),
			"an absent metadata snapshot generation fails closed")
	var stale_metadata := metadata.duplicate(true)
	stale_metadata["by_light_rid"] = {RID(): {}}
	_require(not bool(Registry.join_native_frame(stale_metadata, empty_frame, world_id).get("valid", true)),
			"invalid or stale RID metadata fails closed instead of changing native light order")


func _empty_native_frame() -> Dictionary:
	return {
		"abi_version": 1,
		"valid": true,
		"frame_generation": 0,
		"omni_light_count": 0,
		"omni_light_base_rids": [],
		"spot_light_count": 0,
		"spot_light_base_rids": [],
		"area_light_count": 0,
		"area_light_base_rids": [],
		"directional_light_count": 0,
		"directional_light_base_rids": [],
	}

