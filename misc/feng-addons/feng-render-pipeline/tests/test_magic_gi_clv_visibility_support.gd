extends SceneTree

const Clipmap = preload("res://addons/feng-render-pipeline/passes/magic_gi_clv_cache.gd")
const Visibility = preload("res://addons/feng-magic-gi/feng_magic_gi_visibility.gd")

class TestDirectional extends RefCounted:
	var lighting := RID()
	var epoch := 1

var failures := 0
var checks := 0

func _initialize() -> void:
	call_deferred("run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)

func run() -> void:
	var rd := RenderingServer.get_rendering_device()
	check(rd != null, "CLV visibility-support regression requires a RenderingDevice.")
	if rd == null:
		_finish()
		return
	var blocked := _fill_cell(rd, true, "instrumented")
	var unblocked := _fill_cell(rd, false, "production")
	var density_control := _fill_cell(rd, false, "fallback_disabled")
	var nondirectional := _fill_cell(rd, false, "nondirectional")
	var nearest_blocked := _fill_cell(rd, true, "nearest_blocked")
	var nearest_blocked_old_pool := _fill_cell(rd, true, "nearest_blocked_old_pool")
	var all_blocked := _fill_cell(rd, true, "all_blocked")
	var nearest_clear := _fill_cell(rd, false, "nearest_clear", true)
	var nearest_clear_old_pool := _fill_cell(rd, false, "nearest_clear_old_pool")
	var visible_cap := _fill_cell(rd, false, "visible_cap")
	if not blocked.is_empty() and not unblocked.is_empty() \
			and not density_control.is_empty() and not nondirectional.is_empty() \
			and not nearest_blocked.is_empty() and not nearest_blocked_old_pool.is_empty() \
			and not all_blocked.is_empty() and not nearest_clear.is_empty() \
			and not nearest_clear_old_pool.is_empty() and not visible_cap.is_empty():
		check(float(blocked.cell0_candidate) > 0.0,
				"The wide gather must find a same-patch geometric candidate behind the thin wall.")
		check(float(blocked.cell0_visible_support) == 0.0,
				"A candidate blocked by the thin wall must contribute no visible reconstruction support.")
		check(float(blocked.cell0_metadata) < 0.0,
				"A same-patch candidate whose checked segment crosses the wall must not publish CLV metadata.")
		check(float(blocked.cell1_metadata) > 0.0,
				"The adjacent cell with a visible candidate must publish valid CLV metadata.")
		check(float(blocked.cell1_zero_radiance) == 0.0,
				"A valid, visibility-supported cell must remain legal when its RGB transport is zero.")
		check(float(density_control.cell0_metadata) < 0.0,
				"The narrow density-limited gather must leave the known same-patch distance gap invalid.")
		check(float(unblocked.cell0_metadata) > 0.0,
				"The same-patch wide fallback must fill that distance-clipped cell when its segment is visible.")
		check(float(unblocked.cell0_zero_radiance) == 0.0,
				"The recovered cell is true black and must stay valid without inventing light.")
		check(float(nondirectional.cell0_metadata) > 0.0,
				"The non-directional legacy gather must preserve its original supported metadata.")
		check(float(nondirectional.cell0_r) > 0.1,
				"The non-directional gather must retain its visible cross-patch coefficient instead of using directional fallback.")
		check(bool(nearest_blocked.near_segment_blocked),
				"The geometrically nearest same-patch candidate must be blocked by the thin wall.")
		check(not bool(nearest_blocked.far_segment_blocked),
				"The next same-patch candidate must have a clear segment around the wall.")
		check(float(nearest_blocked.cell0_candidate) > 0.0,
				"The bounded gather must keep geometric ownership when its nearest candidate is blocked.")
		check(float(nearest_blocked.cell0_visible_support) > 0.0,
				"The 16-candidate pool must pass blocked near candidates and retain the ninth candidate's real visible support.")
		check(float(nearest_blocked.cell0_metadata) > 0.0,
				"The ninth visible candidate must publish valid same-patch CLV metadata.")
		check(float(nearest_blocked.cell0_r) > 0.1,
				"The ninth visible candidate must contribute its actual directional lighting to production CLV output.")
		check(float(nearest_blocked_old_pool.cell0_visible_support) == 0.0,
				"The old eight-candidate control must reproduce the missing-support counterexample.")
		check(float(nearest_blocked_old_pool.cell0_metadata) < 0.0,
				"The eight-candidate control must not publish support when its entire pool is blocked.")
		check(float(all_blocked.cell0_candidate) > 0.0,
				"All sixteen blocked candidates must still establish geometric ownership.")
		check(float(all_blocked.cell0_visible_support) == 0.0,
				"Sixteen blocked candidates must never fabricate visible reconstruction support.")
		check(float(all_blocked.cell0_metadata) < 0.0 and float(all_blocked.cell0_r) == 0.0,
				"Sixteen blocked candidates must leave CLV invalid and dark, without restoring global SkyLight.")
		check(float(nearest_clear.cell0_metadata) > 0.0 and float(nearest_clear.cell0_r) > 0.1,
				"The nearby eight-probe control must produce supported nonzero lighting.")
		check(absf(float(nearest_clear.cell0_r) - float(nearest_clear_old_pool.cell0_r)) < 1e-6
				and absf(float(nearest_clear.cell0_g) - float(nearest_clear_old_pool.cell0_g)) < 1e-6
				and absf(float(nearest_clear.cell0_b) - float(nearest_clear_old_pool.cell0_b)) < 1e-6,
				"Eight nearby visible probes must produce the same supported output with a 16- or 8-candidate pool.")
		check(float(visible_cap.cell0_metadata) > 0.0 and float(visible_cap.cell0_r) > 0.1,
				"The wide gather must publish supported lighting when its first eight candidates are visible.")
		check(absf(float(visible_cap.cell0_b)) < 1e-6,
				"The ninth visible candidate must not exceed the eight-probe lighting budget.")
	print("MAGIC_GI_CLV_VISIBILITY_SUPPORT checks=", checks, " failures=", failures,
		" blocked_candidate=", blocked.get("cell0_candidate", NAN),
		" blocked_visible_support=", blocked.get("cell0_visible_support", NAN),
		" blocked_metadata=", blocked.get("cell0_metadata", NAN),
		" narrow_gap_metadata=", density_control.get("cell0_metadata", NAN),
		" fallback_gap_metadata=", unblocked.get("cell0_metadata", NAN),
		" nondirectional_r=", nondirectional.get("cell0_r", NAN),
		" nondirectional_rgb=", nondirectional.get("cell0_g", NAN), ",",
		nondirectional.get("cell0_b", NAN), " cell1_r=", nondirectional.get("cell1_r", NAN),
		" nearest_candidate=", nearest_blocked.get("cell0_candidate", NAN),
		" nearest_visible=", nearest_blocked.get("cell0_visible_support", NAN),
		" nearest_metadata=", nearest_blocked.get("cell0_metadata", NAN),
		" old_pool_visible=", nearest_blocked_old_pool.get("cell0_visible_support", NAN),
		" all_blocked_candidate=", all_blocked.get("cell0_candidate", NAN),
		" all_blocked_visible=", all_blocked.get("cell0_visible_support", NAN),
		" near_clear_rgb=", nearest_clear.get("cell0_r", NAN), ",",
		nearest_clear.get("cell0_g", NAN), ",", nearest_clear.get("cell0_b", NAN),
		" visible_cap_rgb=", visible_cap.get("cell0_r", NAN), ",",
		visible_cap.get("cell0_g", NAN), ",", visible_cap.get("cell0_b", NAN))
	_finish()

func _fill_cell(rd: RenderingDevice, include_wall: bool, shader_variant: String,
		exercise_spacing_reset := false) -> Dictionary:
	var faces := PackedVector3Array()
	var same_patch_fixture := shader_variant in ["nearest_blocked", "nearest_blocked_old_pool",
			"all_blocked", "nearest_clear", "nearest_clear_old_pool", "visible_cap"]
	var probe_count := 2
	if shader_variant in ["nearest_blocked", "nearest_blocked_old_pool", "visible_cap"]:
		probe_count = 9
	elif shader_variant == "all_blocked":
		probe_count = 16
	elif shader_variant in ["nearest_clear", "nearest_clear_old_pool"]:
		probe_count = 8
	if same_patch_fixture:
		_append_quad(faces, 0.0, 2.0)
	else:
		_append_quad(faces, 0.0, 0.9)
		_append_quad(faces, 1.1, 2.0)
	if include_wall:
		var wall_x := 0.55 if shader_variant in ["nearest_blocked", "nearest_blocked_old_pool", "all_blocked"] else 1.0
		faces.append_array(PackedVector3Array([
			Vector3(wall_x, 0.15, 0.0), Vector3(wall_x, 0.45, 0.0), Vector3(wall_x, 0.45, 1.0),
			Vector3(wall_x, 0.15, 0.0), Vector3(wall_x, 0.45, 1.0), Vector3(wall_x, 0.15, 1.0),
		]))
	var bvh: Dictionary = Visibility.build(faces)
	check(not bvh.is_empty() and Visibility.validate(bvh.nodes, bvh.triangles),
			"Synthetic disconnected floor patches and optional thin wall must validate.")
	if bvh.is_empty():
		return {}
	var left_patch := Visibility.surface_patch(bvh.nodes, bvh.triangles, Vector3(0.5, 0.1, 0.5))
	var right_patch := Visibility.surface_patch(bvh.nodes, bvh.triangles, Vector3(1.5, 0.1, 0.5))
	if same_patch_fixture:
		check(left_patch > 0 and left_patch == right_patch,
				"The bounded-pool fixtures must keep candidates and receivers on the same connected floor patch.")
	else:
		check(left_patch > 0 and right_patch > 0 and left_patch != right_patch,
				"The density-gap fixture must have two distinct receiver patches.")
	if not same_patch_fixture:
		check(Vector3(0.5, 0.1, 0.5).distance_to(Vector3(0.1, 0.1, 0.5)) > 0.1 * 2.5,
				"The local probe must be beyond the narrow density-support radius.")
	if shader_variant in ["nearest_blocked", "nearest_blocked_old_pool", "all_blocked"]:
		check(Visibility.segment_blocked(bvh.nodes, bvh.triangles,
				Vector3(0.56, 0.3, 0.5), Vector3(0.5, 0.1, 0.5)),
				"The thin wall must block the near same-patch candidate rays.")
	if shader_variant in ["nearest_blocked", "nearest_blocked_old_pool"]:
		check(Visibility.segment_blocked(bvh.nodes, bvh.triangles,
				Vector3(0.56, 0.3, 0.5), Vector3(0.5, 0.1, 0.5)),
				"The nearest candidate must use the wall-blocked ray.")
		check(not Visibility.segment_blocked(bvh.nodes, bvh.triangles,
				Vector3(0.1, 0.3, 0.5), Vector3(0.5, 0.1, 0.5)),
				"The ninth candidate must have a clear ray around the wall.")

	var geometry_image := Image.create_empty(96, 1, false, Image.FORMAT_RGBAF)
	for probe in probe_count:
		var anchor_x := 0.1 if probe == 0 else 1.5
		var sample_x := 1.5
		if shader_variant in ["nearest_blocked", "nearest_blocked_old_pool"]:
			anchor_x = (0.56 + float(probe) * 0.01) if probe < 8 else 0.1
			sample_x = anchor_x
		elif shader_variant == "all_blocked":
			anchor_x = 0.56 + float(probe) * 0.008
			sample_x = anchor_x
		elif shader_variant in ["nearest_clear", "nearest_clear_old_pool"]:
			anchor_x = 0.56 + float(probe) * 0.01
			sample_x = anchor_x
		elif shader_variant == "visible_cap":
			anchor_x = 0.1 if probe < 8 else 1.0
			sample_x = anchor_x
		var patch := left_patch if same_patch_fixture or probe == 0 else right_patch
		var normal_sign := 1.0 if probe == 0 else -1.0
		var sample_normal := Vector3(normal_sign * sqrt(1.0 - 0.16 * 0.16), 0.16, 0.0) \
				if shader_variant == "nondirectional" else Vector3.UP
		geometry_image.set_pixel(probe * 3, 0,
				Color(anchor_x, 0.1, 0.5, float(patch)))
		geometry_image.set_pixel(probe * 3 + 1, 0, Color(sample_x, 0.3, 0.5, 0.0))
		geometry_image.set_pixel(probe * 3 + 2, 0,
				Color(sample_normal.x, sample_normal.y, sample_normal.z, 0.1))
	var geometry_format := RDTextureFormat.new()
	geometry_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	geometry_format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	geometry_format.width = 96
	geometry_format.height = 1
	geometry_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	var geometry := rd.texture_create(geometry_format, RDTextureView.new(), [geometry_image.get_data()])

	# The legacy lookup layout has eight slots per grid cell. Wide-pool fixtures
	# fill the first cell, then continue into the second cell.
	var index_values := PackedInt32Array()
	index_values.resize(16 * 2)
	for i in index_values.size():
		index_values[i] = -1
	if probe_count == 2:
		index_values[0] = 0
		index_values[8 * 2] = 1
	else:
		for probe in probe_count:
			index_values[probe * 2] = probe
	var index_format := RDTextureFormat.new()
	index_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	index_format.format = RenderingDevice.DATA_FORMAT_R32G32_SINT
	index_format.width = 16
	index_format.height = 1
	index_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	var indices := rd.texture_create(index_format, RDTextureView.new(), [index_values.to_byte_array()])

	var directional_values := PackedFloat32Array()
	directional_values.resize(probe_count * 20 * 4)
	if shader_variant == "nondirectional":
		# k=0 red on the different-patch probe makes an accidental same-patch wide
		# gather observable in the rendered CLV coefficient.
		directional_values[20 * 4] = 1.0
	elif shader_variant in ["nearest_blocked", "nearest_blocked_old_pool"]:
		# Only the ninth candidate emits; its coefficient reaching the cache proves
		# that wide gathering continues after the nearest eight fail visibility.
		directional_values[8 * 20 * 4] = 1.0
	elif shader_variant in ["nearest_clear", "nearest_clear_old_pool"]:
		for probe in probe_count:
			directional_values[probe * 20 * 4] = 1.0
	elif shader_variant == "visible_cap":
		for probe in 8:
			directional_values[probe * 20 * 4] = 1.0
		directional_values[8 * 20 * 4 + 2] = 10.0
	var directional := TestDirectional.new()
	directional.lighting = rd.storage_buffer_create(directional_values.size() * 4,
			directional_values.to_byte_array())
	var nodes := rd.storage_buffer_create(bvh.nodes.size() * 4, bvh.nodes.to_byte_array())
	var triangles := rd.storage_buffer_create(bvh.triangles.size() * 4, bvh.triangles.to_byte_array())
	var index_entries := rd.storage_buffer_create(4, PackedInt32Array([0]).to_byte_array())
	var identity := PackedFloat32Array([
		1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1,
	])
	var parameters := PackedFloat32Array()
	parameters.append_array(identity)
	parameters.append_array(identity)
	parameters.append_array(identity)
	parameters.append_array(PackedFloat32Array([2.0, 1.0, 1.0, float(probe_count)]))
	parameters.append_array(PackedFloat32Array([1.0, 1.0, 1.0, 1.0]))
	parameters.resize(112)
	var ubo := rd.uniform_buffer_create(448, parameters.to_byte_array())
	var sampler_state := RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	var nearest_sampler := rd.sampler_create(sampler_state)
	var bake := {
		"geometry": geometry,
		"indices": indices,
		"visibility_nodes": nodes,
		"visibility_triangles": triangles,
		"index_entries": index_entries,
	}
	var cache := Clipmap.new()
	check(cache.create(rd), "CLV cache resources must be created for the synthetic scene.")
	var result := {}
	if cache.texture.is_valid() and _install_test_shader(rd, cache, shader_variant):
		check(cache.update(rd, Vector3(8.0, 8.0, 8.0), 1.0, 1, bake,
				directional, ubo, nearest_sampler, 512),
				"The first CLV slice must dispatch the synthetic receiving cells.")
		var values := rd.texture_get_data(cache.texture, 0).to_float32_array()
		var width := Clipmap.RESOLUTION * 19
		var cell0_metadata := 18 * Clipmap.RESOLUTION * 4
		var cell1_metadata := (18 * Clipmap.RESOLUTION + 1) * 4
		if values.size() < width * Clipmap.RESOLUTION * 4:
			check(false, "CLV coefficient and metadata slices must be readable for targeted cache cells.")
		else:
			result = {
				"cell0_r": values[0],
				"cell0_g": values[1],
				"cell0_b": values[2],
				"cell1_r": values[4],
				"cell0_zero_radiance": maxf(absf(values[0]),
						maxf(absf(values[1]), absf(values[2]))),
				"cell1_zero_radiance": maxf(absf(values[4]),
						maxf(absf(values[5]), absf(values[6]))),
				"cell0_metadata": values[cell0_metadata + 3],
				"cell1_metadata": values[cell1_metadata + 3],
			}
			if shader_variant in ["instrumented", "nearest_blocked", "nearest_blocked_old_pool",
					"all_blocked", "visible_cap"]:
				result["cell0_candidate"] = values[cell0_metadata]
				result["cell0_visible_support"] = values[cell0_metadata + 1]
				result["near_segment_blocked"] = Visibility.segment_blocked(bvh.nodes, bvh.triangles,
						Vector3(0.56, 0.3, 0.5), Vector3(0.5, 0.1, 0.5))
				result["far_segment_blocked"] = Visibility.segment_blocked(bvh.nodes, bvh.triangles,
						Vector3(0.1, 0.3, 0.5), Vector3(0.5, 0.1, 0.5))
	if exercise_spacing_reset and cache.texture.is_valid():
		_test_spacing_reset(rd, cache, bake, directional, ubo, nearest_sampler)
	for rid in cache.owned_rids():
		if rid.is_valid():
			rd.free_rid(rid)
	for rid in [geometry, indices, nodes, triangles, index_entries,
			directional.lighting, ubo, nearest_sampler]:
		if rid.is_valid():
			rd.free_rid(rid)
	return result

func _test_spacing_reset(rd: RenderingDevice, cache: RefCounted, bake: Dictionary,
		directional: RefCounted, ubo: RID, nearest_sampler: RID) -> void:
	const EPOCH := 1
	const NEW_SPACING := 0.5
	var old_tags := rd.texture_get_data(cache.tags, 0).to_int32_array()
	var new_origins := _origins_for(Vector3.ZERO, NEW_SPACING)
	var overlapping_old_corners := _count_valid_tags_for_origins(old_tags, new_origins, EPOCH)
	check(overlapping_old_corners > 0,
			"The spacing-change fixture must have old-epoch tag coordinates that would alias new-grid corners.")
	check(cache.update(rd, Vector3.ZERO, NEW_SPACING, EPOCH, bake, directional, ubo,
			nearest_sampler, 1), "A spacing change must start a one-job partial cache refill.")
	var partial_tags := rd.texture_get_data(cache.tags, 0).to_int32_array()
	check(_count_valid_tags_for_origins(partial_tags, new_origins, EPOCH) == 1,
			"After a spacing change, only the newly filled job may validate; overlapping old corners must be invalid.")
	check(cache._spacing == NEW_SPACING and cache._cursor == 1 and not cache._pending.is_empty(),
			"The spacing reset must preserve the scheduler's partial-budget state.")
	var dispatches := 0
	while (cache._cursor != 0 or not cache._pending.is_empty()) and dispatches < 32:
		check(cache.update(rd, Vector3.ZERO, NEW_SPACING, EPOCH, bake, directional, ubo,
				nearest_sampler, 512), "The remaining spacing-reset jobs must dispatch successfully.")
		dispatches += 1
	check(cache._cursor == 0 and cache._pending.is_empty(),
			"The spacing-reset fixture must become fully warm within its fixed test budget.")
	var warmed_tags := rd.texture_get_data(cache.tags, 0).to_int32_array()
	check(_count_valid_tags_for_origins(warmed_tags, cache._origins, EPOCH)
			== Clipmap.RESOLUTION * Clipmap.RESOLUTION * Clipmap.RESOLUTION * Clipmap.LEVELS,
			"A fully warmed new-spacing cache must publish all logical cell tags normally.")
	check(_all_active_tags_match(warmed_tags, cache._origins, EPOCH),
			"Every warmed physical slot must carry its new-spacing logical coordinate and epoch.")
	var values := rd.texture_get_data(cache.texture, 0).to_float32_array()
	var width := Clipmap.RESOLUTION * 19
	var supported_cells := 0
	for level in Clipmap.LEVELS:
		var origin: Vector3i = cache._origins[level]
		for z in range(origin.z, origin.z + Clipmap.RESOLUTION):
			for y in range(origin.y, origin.y + Clipmap.RESOLUTION):
				for x in range(origin.x, origin.x + Clipmap.RESOLUTION):
					var slot_x := _positive_mod(x, Clipmap.RESOLUTION)
					var slot_y := _positive_mod(y, Clipmap.RESOLUTION)
					var slot_z := level * Clipmap.RESOLUTION + _positive_mod(z, Clipmap.RESOLUTION)
					var metadata_index := ((slot_z * Clipmap.RESOLUTION + slot_y) * width
							+ 18 * Clipmap.RESOLUTION + slot_x) * 4 + 3
					if values[metadata_index] >= 0.0:
						supported_cells += 1
	check(supported_cells > 0,
			"A fully warmed new-spacing cache must publish at least one real surface-supported cell.")
	print("MAGIC_GI_CLV_SPACING_RESET old_overlap=", overlapping_old_corners,
			" partial_valid=", _count_valid_tags_for_origins(partial_tags, new_origins, EPOCH),
			" warmed_valid=", _count_valid_tags_for_origins(warmed_tags, cache._origins, EPOCH),
			" supported_cells=", supported_cells, " dispatches=", dispatches)

func _origins_for(camera: Vector3, spacing: float) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	for level in Clipmap.LEVELS:
		var step := spacing * float(1 << level)
		result.append(Vector3i((camera / step).floor()) - Vector3i.ONE * (Clipmap.RESOLUTION / 2))
	return result

func _count_valid_tags_for_origins(values: PackedInt32Array, origins: Array,
		epoch: int) -> int:
	var count := 0
	for level in origins.size():
		var origin: Vector3i = origins[level]
		for z in range(origin.z, origin.z + Clipmap.RESOLUTION):
			for y in range(origin.y, origin.y + Clipmap.RESOLUTION):
				for x in range(origin.x, origin.x + Clipmap.RESOLUTION):
					var index := _tag_index(Vector3i(x, y, z), level)
					if values[index] == x and values[index + 1] == y and values[index + 2] == z \
							and values[index + 3] == epoch:
						count += 1
	return count

func _all_active_tags_match(values: PackedInt32Array, origins: Array, epoch: int) -> bool:
	return _count_valid_tags_for_origins(values, origins, epoch) \
			== Clipmap.RESOLUTION * Clipmap.RESOLUTION * Clipmap.RESOLUTION * Clipmap.LEVELS

func _tag_index(cell: Vector3i, level: int) -> int:
	var x := _positive_mod(cell.x, Clipmap.RESOLUTION)
	var y := _positive_mod(cell.y, Clipmap.RESOLUTION)
	var z := level * Clipmap.RESOLUTION + _positive_mod(cell.z, Clipmap.RESOLUTION)
	return (z * Clipmap.RESOLUTION * Clipmap.RESOLUTION + y * Clipmap.RESOLUTION + x) * 4

func _positive_mod(value: int, modulus: int) -> int:
	return ((value % modulus) + modulus) % modulus

func _append_quad(faces: PackedVector3Array, lower_x: float, upper_x: float) -> void:
	var a := Vector3(lower_x, 0.1, 0.0)
	var b := Vector3(upper_x, 0.1, 0.0)
	var c := Vector3(upper_x, 0.1, 1.0)
	var d := Vector3(lower_x, 0.1, 1.0)
	faces.append_array(PackedVector3Array([a, b, c, a, c, d]))

func _install_test_shader(rd: RenderingDevice, cache: RefCounted, variant: String) -> bool:
	var shader_text := _expand_includes(
			"res://addons/feng-render-pipeline/library/magic-gi/magic_gi_clv_fill.glsl")
	if shader_text.is_empty():
		check(false, "The CLV fill shader source and includes must be readable for output variants.")
		return false
	if variant == "fallback_disabled":
		var fallback_condition := "|| narrow_coverage_confidence >= SURFACE_FALLBACK_COVERAGE_HIGH) {"
		check(shader_text.contains(fallback_condition), "Fallback control shader must locate the production branch.")
		shader_text = shader_text.replace(fallback_condition, "|| true) {")
	elif variant == "nondirectional":
		var directional_call := "nearest_triangle, true, true, coefficients,"
		check(shader_text.contains(directional_call), "Legacy-path shader must locate the directional source flag.")
		shader_text = shader_text.replace(directional_call,
				"nearest_triangle, true, false, coefficients,")
	elif variant in ["instrumented", "nearest_blocked", "nearest_blocked_old_pool",
			"all_blocked", "visible_cap"]:
		var metadata_write := "vec4(normal, visible_support_weight > 1e-10 ? float(surface_patch) : -1.0));"
		check(shader_text.contains(metadata_write), "Instrumented shader must locate the CLV metadata write.")
		shader_text = shader_text.replace(metadata_write,
				"vec4(candidate_weight, visible_support_weight, float(surface_patch), " \
				+ "visible_support_weight > 1e-10 ? float(surface_patch) : -1.0));")
	if variant in ["nearest_blocked_old_pool", "nearest_clear_old_pool"]:
		var pool_define := "#define MAGIC_GI_WIDE_CANDIDATE_POOL_LIMIT 16"
		check(shader_text.contains(pool_define), "Old-pool control must locate the production candidate-pool define.")
		shader_text = shader_text.replace(pool_define, "#define MAGIC_GI_WIDE_CANDIDATE_POOL_LIMIT 8")
	shader_text = shader_text.replace("#[compute]", "")
	var source := RDShaderSource.new()
	source.source_compute = shader_text.substr(shader_text.find("#version"))
	var spirv := rd.shader_compile_spirv_from_source(source)
	check(spirv.compile_error_compute.is_empty(), "CLV test shader compile failed: "
			+ spirv.compile_error_compute)
	if not spirv.compile_error_compute.is_empty():
		return false
	var shader := rd.shader_create_from_spirv(spirv)
	var pipeline := rd.compute_pipeline_create(shader)
	check(shader.is_valid() and pipeline.is_valid(), "CLV output-variant shader and pipeline must be valid.")
	if not shader.is_valid() or not pipeline.is_valid():
		if pipeline.is_valid(): rd.free_rid(pipeline)
		if shader.is_valid(): rd.free_rid(shader)
		return false
	var old_pipeline: RID = cache._pipeline
	var old_shader: RID = cache._shader
	cache._pipeline = pipeline
	cache._shader = shader
	if old_pipeline.is_valid(): rd.free_rid(old_pipeline)
	if old_shader.is_valid(): rd.free_rid(old_shader)
	return true

func _expand_includes(path: String) -> String:
	var contents := FileAccess.get_file_as_string(path)
	if contents.is_empty():
		return ""
	var expanded_lines := PackedStringArray()
	for line in contents.split("\n"):
		var trimmed := line.strip_edges()
		if not trimmed.begins_with("#include"):
			expanded_lines.append(line)
			continue
		var quote_start := trimmed.find("\"")
		var quote_end := trimmed.find("\"", quote_start + 1)
		if quote_start < 0 or quote_end <= quote_start:
			return ""
		var include_path := path.get_base_dir().path_join(
				trimmed.substr(quote_start + 1, quote_end - quote_start - 1))
		var included := _expand_includes(include_path)
		if included.is_empty():
			return ""
		expanded_lines.append(included)
	return "\n".join(expanded_lines)

func _finish() -> void:
	quit(1 if failures else 0)
