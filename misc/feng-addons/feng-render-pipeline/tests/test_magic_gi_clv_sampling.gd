extends SceneTree

const Visibility = preload("res://addons/feng-magic-gi/feng_magic_gi_visibility.gd")
const Clipmap = preload("res://addons/feng-render-pipeline/passes/magic_gi_clv_cache.gd")
const MagicGIPass = preload("res://addons/feng-render-pipeline/passes/magic_gi_pass.gd")
const U = preload("res://addons/feng-render-pipeline/rd/uniforms.gd")
const RESOLUTION := 16
const LEVELS := 3
const EPOCH := 7
const PATCH := 7
const CONTACT_WORLD := Vector3(-1.044751, 0.017502, -0.255381)

var checks := 0
var failures := 0
var rd: RenderingDevice
var shader := RID()
var pipeline := RID()
var nodes := RID()
var triangles := RID()
var directional := RID()
var parameters := RID()
var sampler := RID()
var input_buffer := RID()
var output_buffer := RID()
var origins: Array[Vector3i] = [Vector3i(-1, -1, -1), Vector3i(15, -1, -1), Vector3i(15, -1, -1)]
var clv_spacing := 1.0
var coefficient_texture := RID()
var support_texture := RID()

func _initialize() -> void:
	call_deferred("run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)

func run() -> void:
	_test_focus_for_bounds()
	_test_debug_view_parameter()
	_test_gpu_byte_estimate()
	_test_clv_fill_surface_search_domain()
	rd = RenderingServer.create_local_rendering_device()
	check(rd != null, "CLV seam sampling regression requires a RenderingDevice.")
	if rd == null:
		_finish()
		return
	if not _create_pipeline():
		_finish()
		return
	coefficient_texture = _create_coefficient_texture(false)
	var good_tags := _create_tag_texture("")
	var cases := [
		_case("interior level 0", Vector3i(2, 2, 2), Vector3(0.2, 0.3, 0.4), 0),
		_case("negative x seam", Vector3i(-1, 2, 3), Vector3(0.35, 0.25, 0.6), 0),
		_case("negative y seam", Vector3i(2, -1, 3), Vector3(0.6, 0.35, 0.2), 0),
		_case("negative z seam", Vector3i(2, 3, -1), Vector3(0.25, 0.7, 0.4), 0),
		_case("negative xyz seam", Vector3i(-1, -1, -1), Vector3(0.4, 0.3, 0.65), 0),
		_case("positive x seam level 1", Vector3i(15, 2, 2), Vector3(0.3, 0.6, 0.25), 1),
		_case("positive x seam level 2", Vector3i(15, 2, 2), Vector3(0.7, 0.35, 0.4), 2),
	]
	check(_run_cases(cases, good_tags, nodes, triangles, false),
			"Every valid interior/seam sample must match the CPU trilinear SH oracle.")
	var axis_cases := [
		_case("dominant X slot", Vector3i(2, 2, 2), Vector3(0.2, 0.3, 0.4), 0,
				0, Vector3.RIGHT, 0),
		_case("dominant Y slot", Vector3i(2, 2, 2), Vector3(0.2, 0.3, 0.4), 0,
				0, Vector3.UP, 1),
		_case("dominant Z slot", Vector3i(2, 2, 2), Vector3(0.2, 0.3, 0.4), 0,
				0, Vector3.BACK, 2),
	]
	check(_run_cases(axis_cases, good_tags, nodes, triangles, false),
			"The geometric receiver normal must select the matching independent X/Y/Z cache face.")
	check(_run_cases([_case("varying shading normal", Vector3i(2, 2, 2),
			Vector3(0.2, 0.3, 0.4), 0, 0, Vector3(0.2, 1.0, 0.15).normalized())],
			good_tags, nodes, triangles, false),
			"A shading normal distinct from the cached plane must retain directional SH lighting.")
	check(rd.buffer_update(parameters, 0, 80,
			_clipmap_parameters(true, LEVELS, Clipmap.LAYOUT_VERSION - 1)) == OK,
			"The stale-layout control must update the CLV ABI version field.")
	var stale_layout := _run_single_with_values(
			_case("stale CLV layout", Vector3i(2, 2, 2), Vector3(0.2, 0.3, 0.4), 0),
			good_tags, nodes, triangles)
	check(not bool(stale_layout.get("valid", false))
			and int(stale_layout.get("reject_reason", -1)) == 1,
			"A prior CLV layout version must not be consumed by the current shader.")
	check(rd.buffer_update(parameters, 0, 80, _clipmap_parameters()) == OK,
			"The current CLV layout version must be restored after the stale-layout control.")
	_rd_free(good_tags)
	_run_partial("wrong logical tag", "tag_xyz", Vector3i(15, 2, 3),
			Vector3(0.35, 0.25, 0.6), 0.805)
	_run_partial("stale epoch", "epoch", Vector3i(15, 2, 3),
			Vector3(0.35, 0.25, 0.6), 0.805)
	_run_partial("wrong patch", "wrong_patch", Vector3i(15, 2, 3),
			Vector3(0.35, 0.25, 0.6), 0.805)
	_run_partial("missing support", "invalid_patch", Vector3i(15, 2, 3),
			Vector3(0.35, 0.25, 0.6), 0.805)
	_run_partial("normal gate", "normal", Vector3i(15, 2, 3),
			Vector3(0.35, 0.25, 0.6), 0.805)
	_run_zero_weight_invalid_metadata()
	_run_zero_coverage_rejection()
	_run_black_primary()
	_run_contact_invalid_blocker()
	_run_zero_weight_blocker()
	_run_partial_blocked_corner_uses_exact()
	_run_valid_weight_blocker()
	_run_geometric_query_position()
	_run_clv_disabled_reason()
	_run_outside_reason()
	_run_cached_receiver_tests()
	_run_filtered_visibility_tests()
	_run_certified_cache_tests()
	print("MAGIC_GI_CLV_SAMPLING checks=", checks, " failures=", failures,
			" cases=interior,x,y,z,xyz,level1,level2,geometric_query,negative_world,contact_invalid_blocker,zero_weight_blocker,partial_blocked_corner,valid_weight_blocker gates=incomplete_exact,zero_weight_metadata,thin_wall,geometry_fallback,focus_bounds,diagnostics")
	_finish()

func _test_focus_for_bounds() -> void:
	var streamed_small_source_bounds: Array[AABB] = [
		AABB(Vector3(-3.0, 0.0, -3.0), Vector3(6.0, 3.0, 6.0)),
	]
	var streamed_small_bounds := MagicGIPass._union_clv_source_bounds(streamed_small_source_bounds)
	check(streamed_small_bounds.position == Vector3(-3.0, 0.0, -3.0)
			and streamed_small_bounds.size == Vector3(6.0, 3.0, 6.0),
			"Streamed CLV focus must use the cached source probe bounds.")
	var outside_cornell_camera := Vector3(0.0, 2.5, 8.9)
	var streamed_focus := Clipmap.focus_for_bounds(outside_cornell_camera,
		streamed_small_bounds, 0.5)
	check(streamed_focus.distance_to(Vector3(0.0, 1.5, 0.0)) < 0.00002,
			"A camera outside a small streamed scene must focus CLV on its baked probe region.")
	var streamed_large_source_bounds: Array[AABB] = [
		AABB(Vector3(-100.0, -20.0, -100.0), Vector3(200.0, 40.0, 200.0)),
		AABB(Vector3(100.0, -20.0, 100.0), Vector3(200.0, 40.0, 200.0)),
	]
	var streamed_large_bounds := MagicGIPass._union_clv_source_bounds(streamed_large_source_bounds)
	check(streamed_large_bounds.position == Vector3(-100.0, -20.0, -100.0)
			and streamed_large_bounds.size == Vector3(400.0, 40.0, 400.0),
			"Streamed CLV focus bounds must union source bounds for all ready pages.")
	var large_world_camera := Vector3(12.0, 2.0, 18.0)
	var streamed_large_focus := Clipmap.focus_for_bounds(large_world_camera,
		streamed_large_bounds, 0.5)
	check(streamed_large_focus.distance_to(large_world_camera) < 0.00002,
			"Large streamed bounds must keep the CLV focus camera-relative.")
	var no_source_bounds: Array[AABB] = [AABB(Vector3.ZERO, Vector3(-1.0, 1.0, 1.0))]
	check(not MagicGIPass._valid_clv_focus_bounds(
			MagicGIPass._union_clv_source_bounds(no_source_bounds)),
			"Invalid cached source bounds must leave streamed CLV camera-centered.")
	var full := AABB(Vector3(-10.0, -10.0, -10.0), Vector3.ONE * 20.0)
	_check_focus("large bounds clamp", Vector3(2.0, -2.0, 50.0), full, 0.5,
			Vector3(2.0, -2.0, 6.625))
	var small := AABB(Vector3(-2.0, 1.0, 7.0), Vector3(4.0, 2.0, 6.0))
	_check_focus("small bounds center", Vector3(30.0, -20.0, -40.0), small, 0.5,
			Vector3(0.0, 2.0, 10.0))
	var exact_span := AABB(Vector3(-5.0, 3.0, -10.0), Vector3.ONE * 6.75)
	_check_focus("exact safe span", Vector3(100.0, -100.0, 0.0), exact_span, 0.5,
			Vector3(-1.625, 6.375, -6.625))
	var mixed_negative := AABB(Vector3(-20.0, -4.0, -14.0), Vector3(40.0, 8.0, 20.0))
	_check_focus("negative world bounds and per-axis clamp", Vector3(30.0, -10.0, -100.0),
			mixed_negative, 0.5, Vector3(16.625, -0.625, -10.625))
	var large_for_tiny_step := AABB(Vector3.ZERO, Vector3.ONE * 100.0)
	_check_focus("tiny positive spacing", Vector3(50.0, -4.0, 2.0), large_for_tiny_step,
			0.0001, Vector3(50.0, 0.000675, 2.0))
	var negative_step_bounds := AABB(Vector3.ONE * -100.0, Vector3.ONE * 200.0)
	_check_focus("negative spacing fallback", Vector3(-120.0, -50.0, 150.0),
			negative_step_bounds, -0.5, Vector3(-99.99325, -50.0, 99.99325))
	var degenerate := AABB(Vector3(3.0, -2.0, 7.0), Vector3.ZERO)
	_check_focus("degenerate bounds center", Vector3(-30.0, 40.0, -50.0), degenerate,
			0.5, Vector3(3.0, -2.0, 7.0))
	var negative_size := AABB(Vector3(8.0, 10.0, 12.0), Vector3(-4.0, -6.0, -8.0))
	_check_focus("negative size normalized", Vector3(8.0, 10.0, 8.0), negative_size,
			0.5, Vector3(6.0, 7.0, 8.0))

func _check_focus(label: String, camera: Vector3, bounds: AABB, spacing: float,
		expected: Vector3) -> void:
	var actual := Clipmap.focus_for_bounds(camera, bounds, spacing)
	check(actual.distance_to(expected) < 0.00002,
			label + " expected=" + str(expected) + " actual=" + str(actual))

func _test_debug_view_parameter() -> void:
	var gi_pass := MagicGIPass.new()
	check(gi_pass.clv_debug_view == 0,
			"CLV diagnostics must default to Off.")
	for view in 5:
		gi_pass.clv_debug_view = view
		var bytes := gi_pass._parameter_bytes()
		check(int(round(bytes.decode_float(12))) == view,
				"CLV debug view must be encoded in the spare push-constant lane.")
	gi_pass.clv_debug_view = 99
	check(gi_pass.clv_debug_view == 4 and int(round(gi_pass._parameter_bytes().decode_float(12))) == 4,
			"CLV debug view values must clamp to the supported enum range.")

func _test_gpu_byte_estimate() -> void:
	var breakdown: Dictionary = Clipmap.estimate_gpu_bytes_breakdown()
	check(breakdown.get("coefficient_texture_dimensions") == Vector3i(1056, 16, 48)
			and breakdown.get("coefficient_texture_format") == "R32G32B32A32_SFLOAT"
			and int(breakdown.get("coefficient_texture_bytes", 0)) == 12976128
			and int(breakdown.get("layout_version", 0)) == Clipmap.LAYOUT_VERSION
			and Clipmap.LAYOUT_VERSION == 8
			and Clipmap.CLV_FACE_COUNT == 3
			and Clipmap.CLV_FACE_SLOT_COLUMNS == 22
			and Clipmap.CLV_TEXTURE_COLUMNS == 66
			and Clipmap.RADIANCE_COEFFICIENT_COLUMNS == 18
			and Clipmap.SURFACE_METADATA_COLUMN == 18
			and Clipmap.SURFACE_ANCHOR_COLUMN == 19 and Clipmap.DIFFUSE_PROJECTION_COLUMN == 20,
			"The three-face RGBA32F texture must include both diffuse projection columns.")
	check(breakdown.get("tag_texture_dimensions") == Vector3i(16, 16, 48)
			and breakdown.get("tag_texture_format") == "R32G32B32A32_SINT"
			and int(breakdown.get("tag_texture_bytes", 0)) == 196608,
			"The RGBA32I CLV tag texture estimate must match its allocated 3D format.")
	check(int(breakdown.get("parameter_buffer_bytes", 0)) == 80
			and int(breakdown.get("jobs_buffer_bytes", 0)) == 8192
			and int(breakdown.get("fallback_cluster_buffer_bytes", 0)) == 16
			and int(breakdown.get("support_texture_bytes", 0)) == 49152
			and int(breakdown.get("stencil_buffer_bytes", 0)) == 7667712
			and int(breakdown.get("total_bytes", 0)) == 20897888
			and Clipmap.estimate_gpu_bytes() == 20897888,
			"The CLV estimate must include each allocated size-bearing buffer and preserve its exact total.")

func _test_clv_fill_surface_search_domain() -> void:
	# nearest_surface() shifts its argument back by radius and caps the hit at
	# radius*2, so the fill's half_distance yields a reach of 3*search_spacing.
	const PROBE_SPACING := 1.0
	const BASE_CLV_SPACING := 0.5
	const PHASE := 0.7501
	for level in Clipmap.LEVELS:
		var step_size: float = BASE_CLV_SPACING * float(1 << level)
		var surface_y: float = step_size * PHASE
		var query_grid_y: float = surface_y / step_size + 0.75 - 0.5
		var cell_y: int = floori(query_grid_y)
		var fraction_y: float = query_grid_y - float(cell_y)
		var upper_corner_y: float = (float(cell_y) + 1.5) * step_size
		var upper_distance: float = upper_corner_y - surface_y
		var half_distance: float = maxf(PROBE_SPACING, step_size) * 1.5
		var nearest_surface_argument_y: float = upper_corner_y + half_distance
		var actual_ray_origin_y: float = nearest_surface_argument_y - half_distance
		var actual_ray_reach: float = half_distance * 2.0
		check(fraction_y > 0.0 and upper_distance > 0.0,
				"The coarse-phase upper corner must have positive interpolation support.")
		check(is_equal_approx(actual_ray_origin_y, upper_corner_y)
				and actual_ray_reach >= upper_distance,
				"The shared nearest_surface double-radius search must cover each positive-weight CLV corner.")
		if level == 2:
			check(upper_distance > PROBE_SPACING * 3.0,
					"This level-2 phase must reproduce the prior 3*probe-spacing search gap.")
	# The real test-2 floor near y=0.017502 remains inside the old reach; this
	# confirms the fix targets the phase-dependent coarse corner, not that sample.
	var test2_floor_upper_distance: float = 3.0 - 0.01750207
	check(test2_floor_upper_distance < PROBE_SPACING * 3.0,
			"The corrected range contract must preserve the already-covered test-2 floor sample.")
	_test_surface_box_certificate_reference()
	var sample_source := FileAccess.get_file_as_string(
			"res://addons/feng-render-pipeline/library/magic-gi/magic_gi_clv_sample.glslinc")
	check(sample_source.contains("receiver_patch > 0 && surface_patch != receiver_patch")
			and sample_source.contains("segment_blocked(corner, world, receiver_triangle, 0)"),
			"The certificate fast path must preserve the original patch gate and exact LOS fallback.")

func _test_surface_box_certificate_reference() -> void:
	const HALF_EXTENT := 1.75
	const TOLERANCE := 0.0001
	const PATCH_ID := 7
	var center := Vector3.ZERO
	var anchor := Vector3.ZERO
	var normal := Vector3.UP
	var coplanar := [
		{"a": Vector3(-2.0, 0.0, -2.0), "b": Vector3(2.0, 0.0, -2.0),
			"c": Vector3(-2.0, 0.0, 2.0), "patch": PATCH_ID},
		{"a": Vector3(2.0, 0.0, -2.0), "b": Vector3(2.0, 0.0, 2.0),
			"c": Vector3(-2.0, 0.0, 2.0), "patch": PATCH_ID},
	]
	check(_reference_surface_box_clear(center, HALF_EXTENT, anchor, normal,
			TOLERANCE, PATCH_ID, coplanar, true),
			"A complete BVH box containing only coplanar same-patch triangles may certify.")
	var foreign_patch: Array = coplanar.duplicate()
	foreign_patch.append({"a": Vector3(0.0, -1.0, -1.0), "b": Vector3(0.0, 1.0, -1.0),
			"c": Vector3(0.0, 0.0, 1.0), "patch": PATCH_ID + 1})
	check(not _reference_surface_box_clear(center, HALF_EXTENT, anchor, normal,
			TOLERANCE, PATCH_ID, foreign_patch, true),
			"An intersecting different-patch triangle must reject the certificate.")
	var bent_patch: Array = coplanar.duplicate()
	bent_patch.append({"a": Vector3(0.0, 0.0, 0.0), "b": Vector3(1.0, 0.0, 0.0),
			"c": Vector3(0.0, 0.1, 1.0), "patch": PATCH_ID})
	check(not _reference_surface_box_clear(center, HALF_EXTENT, anchor, normal,
			TOLERANCE, PATCH_ID, bent_patch, true),
			"A same-patch triangle that bends away from the anchor plane must reject.")
	check(_reference_certificate_contains(center + Vector3(1.7, 0.0, 0.0), center,
			center, HALF_EXTENT, anchor, normal, TOLERANCE),
			"A receiver and corner inside the certified convex box may use the certificate.")
	check(not _reference_certificate_contains(center + Vector3(1.8, 0.0, 0.0), center,
			center, HALF_EXTENT, anchor, normal, TOLERANCE),
			"A receiver outside the certificate box must take exact LOS fallback.")
	check(not _reference_certificate_contains(center, center + Vector3(0.0, 0.0, 1.8),
			center, HALF_EXTENT, anchor, normal, TOLERANCE),
			"A corner outside the certificate box must take exact LOS fallback.")
	check(not _reference_surface_box_clear(center, HALF_EXTENT, anchor, normal,
			TOLERANCE, PATCH_ID, coplanar, false),
			"A truncated BVH traversal must never publish a certificate.")

func _reference_surface_box_clear(center: Vector3, half_extent: float, anchor: Vector3,
		normal: Vector3, plane_tolerance: float, patch: int, triangles: Array,
		traversal_complete: bool) -> bool:
	if not traversal_complete or patch <= 0 or half_extent <= 0.0 \
			or normal.length_squared() <= 1e-12:
		return false
	var unit_normal := normal.normalized()
	var lower := center - Vector3.ONE * half_extent
	var upper := center + Vector3.ONE * half_extent
	for triangle in triangles:
		var a: Vector3 = triangle.a
		var b: Vector3 = triangle.b
		var c: Vector3 = triangle.c
		var triangle_lower := a.min(b).min(c)
		var triangle_upper := a.max(b).max(c)
		if not _reference_aabb_overlap(lower, upper, triangle_lower, triangle_upper):
			continue
		if int(triangle.patch) != patch:
			return false
		var triangle_normal := (c - a).cross(b - a)
		if triangle_normal.length_squared() <= 1e-12 \
				or triangle_normal.normalized().dot(unit_normal) < 0.9999 \
				or absf((a - anchor).dot(unit_normal)) > plane_tolerance \
				or absf((b - anchor).dot(unit_normal)) > plane_tolerance \
				or absf((c - anchor).dot(unit_normal)) > plane_tolerance:
			return false
	return true

func _reference_certificate_contains(receiver: Vector3, corner: Vector3,
		center: Vector3, half_extent: float, anchor: Vector3, normal: Vector3,
		plane_tolerance: float) -> bool:
	var lower := center - Vector3.ONE * half_extent
	var upper := center + Vector3.ONE * half_extent
	return _reference_point_in_box(receiver, lower, upper) \
			and _reference_point_in_box(corner, lower, upper) \
			and (receiver - anchor).dot(normal.normalized()) >= -plane_tolerance \
			and absf((receiver - anchor).dot(normal.normalized())) <= plane_tolerance \
			and (corner - anchor).dot(normal.normalized()) >= -plane_tolerance

func _reference_point_in_box(point: Vector3, lower: Vector3, upper: Vector3) -> bool:
	return point.x >= lower.x and point.y >= lower.y and point.z >= lower.z \
			and point.x <= upper.x and point.y <= upper.y and point.z <= upper.z

func _reference_aabb_overlap(first_lower: Vector3, first_upper: Vector3,
		second_lower: Vector3, second_upper: Vector3) -> bool:
	return first_upper.x >= second_lower.x and first_lower.x <= second_upper.x \
			and first_upper.y >= second_lower.y and first_lower.y <= second_upper.y \
			and first_upper.z >= second_lower.z and first_lower.z <= second_upper.z

func _create_pipeline() -> bool:
	var shader_text := _test_shader_source()
	var source := RDShaderSource.new()
	source.source_compute = shader_text
	var spirv := rd.shader_compile_spirv_from_source(source)
	check(spirv.compile_error_compute.is_empty(), "Production CLV sampling include compile failed: "
			+ spirv.compile_error_compute)
	if not spirv.compile_error_compute.is_empty():
		return false
	shader = rd.shader_create_from_spirv(spirv, "Magic GI CLV Sampling Regression")
	pipeline = rd.compute_pipeline_create(shader)
	check(shader.is_valid() and pipeline.is_valid(), "CLV sampling regression pipeline must be valid.")
	if not shader.is_valid() or not pipeline.is_valid():
		return false
	# A single vec4 makes the real segment_blocked() implementation see an empty BVH.
	nodes = rd.storage_buffer_create(16, PackedFloat32Array([0, 0, 0, 0]).to_byte_array())
	triangles = rd.storage_buffer_create(36 * 4, PackedFloat32Array([
		# +X: cross(edge2, edge1) = +X.
		0, 0, 0, 0, 0, 0, 1, 0.000001, 0, 1, 0, float(PATCH),
		# +Y: cross(edge2, edge1) = +Y.
		0, 0, 0, 0, 1, 0, 0, 0.000001, 0, 0, 1, float(PATCH),
		# +Z: cross(edge2, edge1) = +Z.
		0, 0, 0, 0, 0, 1, 0, 0.000001, 1, 0, 0, float(PATCH),
	]).to_byte_array())
	var lighting_zero := PackedFloat32Array()
	lighting_zero.resize(60 * 4)
	directional = rd.storage_buffer_create(lighting_zero.size() * 4, lighting_zero.to_byte_array())
	parameters = rd.uniform_buffer_create(80, _clipmap_parameters())
	var input_zero := PackedByteArray()
	input_zero.resize(7 * 32)
	input_buffer = rd.storage_buffer_create(7 * 32, input_zero)
	var output_zero := PackedByteArray()
	output_zero.resize(7 * 144)
	output_buffer = rd.storage_buffer_create(7 * 144, output_zero)
	var state := RDSamplerState.new()
	state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler = rd.sampler_create(state)
	var support_format := RDTextureFormat.new()
	support_format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	support_format.format = RenderingDevice.DATA_FORMAT_R32_UINT
	support_format.width = 1
	support_format.height = 1
	support_format.depth = 1
	support_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	support_texture = rd.texture_create(support_format, RDTextureView.new(), [PackedByteArray([0, 0, 0, 0])])
	return nodes.is_valid() and triangles.is_valid() and directional.is_valid() \
			and parameters.is_valid() and input_buffer.is_valid() and output_buffer.is_valid() \
			and sampler.is_valid()

func _test_shader_source() -> String:
	var visibility := _expand_includes("res://addons/feng-render-pipeline/library/magic-gi/magic_gi_visibility.glslinc")
	var sh := _expand_includes("res://addons/feng-render-pipeline/library/magic-gi/magic_gi_sh.glslinc")
	var layout := _expand_includes("res://addons/feng-render-pipeline/library/magic-gi/magic_gi_clv_layout.glslinc")
	var sample := _expand_includes("res://addons/feng-render-pipeline/library/magic-gi/magic_gi_clv_sample.glslinc")
	if visibility.is_empty() or sh.is_empty() or layout.is_empty() or sample.is_empty():
		check(false, "Regression shader must expand the production visibility, SH, CLV layout, and sampler includes.")
		return ""
	return """
#version 450
layout(local_size_x = 1) in;
layout(set = 0, binding = 0, std430) readonly buffer VisibilityNodes { vec4 nodes[]; } visibility_bvh;
layout(set = 0, binding = 1, std430) readonly buffer VisibilityTriangles { vec4 triangles[]; } visibility_geometry;
layout(set = 0, binding = 22, std430) readonly buffer QueryCases { vec4 values[]; } query_cases;
layout(set = 0, binding = 23, std430) writeonly buffer Results { vec4 values[]; } results;
""" + visibility + "\n" + sh + "\n" + layout + "\n" + sample + """
void main() {
	uint index = gl_GlobalInvocationID.x;
	vec4 world_and_triangle = query_cases.values[index * 2];
	vec4 normal_and_patch = query_cases.values[index * 2 + 1];
	vec3 secondary;
	vec3 primary;
	float cache_weight;
	bool complete_support;
	int selected_level;
	int sample_status;
	int reject_reason;
	vec3 cell_fraction;
	bool valid = sample_clv_diagnostic(world_and_triangle.xyz, normal_and_patch.xyz,
			int(world_and_triangle.w), int(normal_and_patch.w), secondary, primary,
			cache_weight, complete_support, selected_level, sample_status,
			reject_reason, cell_fraction);
	// Keep the production lighting descriptor active in this test shader as it is in apply.
	if (directional_lighting.values[0].x > 1e30) { secondary = vec3(0.0); }
	results.values[index * 9] = vec4(secondary, valid ? 1.0 : 0.0);
	results.values[index * 9 + 1] = vec4(primary, valid ? 1.0 : 0.0);
	results.values[index * 9 + 2] = vec4(cache_weight, complete_support ? 1.0 : 0.0,
			float(selected_level), float(sample_status));
	results.values[index * 9 + 3] = vec4(0.0, 0.0, 0.0, float(reject_reason));
	results.values[index * 9 + 4] = vec4(0.0, 0.0, 0.0, cell_fraction.x);
	results.values[index * 9 + 5] = vec4(0.0, 0.0, 0.0, cell_fraction.y);
	results.values[index * 9 + 6] = vec4(0.0, 0.0, 0.0, cell_fraction.z);
	results.values[index * 9 + 7] = vec4(0.0);
	results.values[index * 9 + 8] = vec4(0.0);
	if (normal_and_patch.w == -1.0) {
		vec3 query_position;
		ivec3 query_base;
		vec3 query_fraction;
		bool query_valid = clv_surface_query_position(world_and_triangle.xyz,
				normal_and_patch.xyz, int(world_and_triangle.w), clv.spacing.x,
				query_position, query_base, query_fraction);
		results.values[index * 9 + 7] = vec4(query_position, query_valid ? 1.0 : 0.0);
	}
	if (normal_and_patch.w <= -2.0) {
		vec3 direction = normal_and_patch.w == -3.0 ? vec3(0, 1, 0)
				: (normal_and_patch.w == -4.0 ? vec3(1, 0, 0) : vec3(0, -1, 0));
		float radius = normal_and_patch.w == -5.0 ? 3.0 : 0.2;
		vec3 cached; int cached_triangle; int reference_triangle;
		bool hit = clv_cached_receiver(world_and_triangle.xyz, direction, radius,
				normal_and_patch.xyz, cached, cached_triangle);
		vec3 reference = nearest_surface(world_and_triangle.xyz, direction, radius,
				-1, reference_triangle);
		results.values[index * 9 + 7] = vec4(cached, hit ? 1.0 : 0.0);
		results.values[index * 9 + 8] = vec4(reference, reference_triangle);
		results.values[index * 9 + 6].w = float(cached_triangle);
	}
	if (normal_and_patch.w == -6.0) {
		bool supported = sample_clv_certified(world_and_triangle.xyz, normal_and_patch.xyz,
				secondary, primary, selected_level, cell_fraction);
		results.values[index * 9] = vec4(secondary, supported ? 1.0 : 0.0);
		results.values[index * 9 + 1] = vec4(primary, supported ? 1.0 : 0.0);
	}
}
"""

func _run_certified_cache_tests() -> void:
	var cache := Clipmap.new()
	check(cache.create(rd), "Certified CLV regression must allocate the production cache resources.")
	# Seed synthetic producer output directly; runtime textures are GPU-written.
	for field in ["texture", "tags"]:
		var original: RID = cache.get(field)
		var format := rd.texture_get_format(original)
		format.usage_bits |= RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
		cache.set(field, rd.texture_create(format, RDTextureView.new(), []))
		_rd_free(original)
	var previous_coefficients := coefficient_texture
	var previous_support := support_texture
	coefficient_texture = cache.texture
	support_texture = cache.support
	var base := Vector3i(2, 2, 2)
	var query := {"label": "certified plane", "world": Vector3(2.7, 2.0, 2.9),
			"normal": Vector3.UP, "receiver_triangle": 0, "receiver_patch": -6}
	var width := RESOLUTION * Clipmap.CLV_TEXTURE_COLUMNS
	var values := PackedFloat32Array()
	values.resize(width * RESOLUTION * RESOLUTION * LEVELS * 4)
	var tag_values := PackedInt32Array()
	tag_values.resize(RESOLUTION * RESOLUTION * RESOLUTION * LEVELS * 4)
	var jobs := PackedInt32Array([base.x + 1, base.y + 1, base.z + 1, 0]).to_byte_array()
	rd.buffer_update(cache._jobs, 0, jobs.size(), jobs)
	var push := PackedInt32Array([1, RESOLUTION, EPOCH]).to_byte_array()
	push.append_array(PackedFloat32Array([1.0]).to_byte_array())
	for fixture in ["plane", "wall", "missing corner", "stale neighbor", "black"]:
		var faces := _plane_faces(Vector3(0, 2, 0), Vector3.UP)
		if fixture == "wall":
			faces.append_array(PackedVector3Array([
				Vector3(3, 2, 2), Vector3(3, 4, 2), Vector3(3, 2, 4)]))
		var bvh: Dictionary = Visibility.build(faces)
		check(not bvh.is_empty(), "Certified fixture geometry must be valid: " + fixture)
		if bvh.is_empty(): continue
		var patch := float(bvh.triangles[11])
		values.fill(0.0)
		tag_values.fill(0)
		for z in 2:
			for y in 2:
				for x in 2:
					var cell := base + Vector3i(x, y, z)
					var tag_offset := ((cell.z * RESOLUTION + cell.y) * RESOLUTION + cell.x) * 4
					tag_values[tag_offset] = cell.x
					tag_values[tag_offset + 1] = cell.y
					tag_values[tag_offset + 2] = cell.z
					tag_values[tag_offset + 3] = EPOCH + 1 if fixture == "stale neighbor" and x + y + z == 3 else EPOCH
					var column := Clipmap.CLV_FACE_SLOT_COLUMNS
					var metadata := _index4((column + Clipmap.SURFACE_METADATA_COLUMN) * RESOLUTION + cell.x,
							cell.y, cell.z, width, RESOLUTION)
					values[metadata + 1] = 1.0
					values[metadata + 3] = -1.0 if fixture == "missing corner" and x + y + z == 3 else patch
					var anchor := _index4((column + Clipmap.SURFACE_ANCHOR_COLUMN) * RESOLUTION + cell.x,
							cell.y, cell.z, width, RESOLUTION)
					values[anchor + 1] = 2.0
					values[anchor + 3] = -1.0 # A surface hint suffices; the producer proves the tighter neighborhood.
					for channel in 3:
						var diffuse := _index4((column + Clipmap.DIFFUSE_PROJECTION_COLUMN) * RESOLUTION + cell.x,
								cell.y, cell.z, width, RESOLUTION)
						values[diffuse + channel] = 0.0 if fixture == "black" else float(channel + 1)
						values[diffuse + RESOLUTION * 4 + channel] = float(channel + 4)
		check(rd.texture_update(cache.texture, 0, values.to_byte_array()) == OK
				and rd.texture_update(cache.tags, 0, tag_values.to_byte_array()) == OK,
				"The certified fixture must publish its coefficients and logical tags.")
		rd.texture_clear(cache.support, Color(0, 0, 0, 0), 0, 1, 0, 1)
		var node_buffer := rd.storage_buffer_create(bvh.nodes.size() * 4, bvh.nodes.to_byte_array())
		var triangle_buffer := rd.storage_buffer_create(bvh.triangles.size() * 4, bvh.triangles.to_byte_array())
		var uniforms := rd.uniform_set_create([U.image(0, cache.texture), U.image(1, cache.tags),
			U.image(2, cache.support), _storage(3, cache._jobs), _storage(4, node_buffer),
			_storage(5, triangle_buffer)], cache._certify_shader, 0)
		check(uniforms.is_valid(), "The production certification shader must accept the fixture bindings.")
		if not uniforms.is_valid(): continue
		var list := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(list, cache._certify_pipeline)
		rd.compute_list_bind_uniform_set(list, uniforms, 0)
		rd.compute_list_set_push_constant(list, push, push.size())
		rd.compute_list_dispatch(list, 1, 1, 1)
		rd.compute_list_end()
		rd.submit()
		rd.sync()
		var result := _run_single_with_values(query, cache.tags, nodes, triangles)
		var expected_valid: bool = fixture in ["plane", "black"]
		check(bool(result.get("valid", false)) == expected_valid,
				"Certified interpolation must preserve visibility: " + fixture + " " + str(result))
		if expected_valid:
			var expected := Vector3.ZERO if fixture == "black" else Vector3(1, 2, 3)
			check(Vector3(result.secondary).distance_to(expected) < 0.0001
					and Vector3(result.primary).distance_to(Vector3(4, 5, 6)) < 0.0001,
					"Certified interpolation must keep secondary/primary independent, including valid black.")
			var outside := query.duplicate()
			outside.world.y += 0.2
			check(not bool(_run_single_with_values(outside, cache.tags, nodes, triangles).get("valid", false)),
					"A certificate must reject a receiver on a distinct parallel plane.")
			var curved := query.duplicate()
			curved.normal = Vector3(0.2, 1, 0).normalized()
			check(not bool(_run_single_with_values(curved, cache.tags, nodes, triangles).get("valid", false)),
					"A distinct shading normal must retain directional reconstruction.")
		for rid in [uniforms, node_buffer, triangle_buffer]: _rd_free(rid)
	coefficient_texture = previous_coefficients
	support_texture = previous_support
	for rid in cache.owned_rids(): _rd_free(rid)

func _case(label: String, base: Vector3i, fraction: Vector3, level: int,
		receiver_patch := 0, normal := Vector3.UP, receiver_triangle := 1) -> Dictionary:
	var step_size := float(1 << level)
	var world := (Vector3(base) + fraction + Vector3.ONE * 0.5) * step_size \
			- normal * step_size * 0.75
	return {"label": label, "base": base, "fraction": fraction, "level": level,
			"world": world, "normal": normal, "receiver_patch": receiver_patch,
			"receiver_triangle": receiver_triangle}

func _run_cases(cases: Array, tag_texture: RID, node_buffer: RID, triangle_buffer: RID,
		zero_primary: bool) -> bool:
	var query_values := PackedFloat32Array()
	for query in cases:
		var world: Vector3 = query.world
		var normal: Vector3 = query.normal
		query_values.append_array(PackedFloat32Array([
			world.x, world.y, world.z, float(query.get("receiver_triangle", -1)),
			normal.x, normal.y, normal.z, float(query.receiver_patch),
		]))
	var query_bytes := query_values.to_byte_array()
	rd.buffer_update(input_buffer, 0, query_bytes.size(), query_bytes)
	var result_bytes := PackedByteArray()
	result_bytes.resize(cases.size() * 144)
	rd.buffer_update(output_buffer, 0, result_bytes.size(), result_bytes)
	var set := _uniform_set(tag_texture, node_buffer, triangle_buffer)
	if not set.is_valid():
		check(false, "CLV sampling descriptor set must be valid.")
		return false
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	rd.compute_list_bind_uniform_set(list, set, 0)
	rd.compute_list_dispatch(list, cases.size(), 1, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	var output := rd.buffer_get_data(output_buffer).to_float32_array()
	var all_match := true
	for i in cases.size():
		var query: Dictionary = cases[i]
		var base: Vector3i = query.base
		var fraction: Vector3 = query.fraction
		var level: int = query.level
		var output_base := i * 36
		var secondary := Vector3(output[output_base], output[output_base + 1], output[output_base + 2])
		var secondary_valid := output[output_base + 3] > 0.5
		var primary := Vector3(output[output_base + 4], output[output_base + 5], output[output_base + 6])
		var primary_valid := output[output_base + 7] > 0.5
		var cache_weight := output[output_base + 8]
		var complete_support := output[output_base + 9] > 0.5
		var selected_level := int(round(output[output_base + 10]))
		var sample_status := int(round(output[output_base + 11]))
		var reject_reason := int(round(output[output_base + 15]))
		var cell_fraction := Vector3(output[output_base + 19], output[output_base + 23], output[output_base + 27])
		var expected_axis := _dominant_axis(query.normal)
		var expected_secondary := _expected(base, fraction, level, false, zero_primary,
				Vector3i(-1, -1, -1), query.normal, expected_axis)
		var expected_primary := _expected(base, fraction, level, true, zero_primary,
				Vector3i(-1, -1, -1), query.normal, expected_axis)
		check(secondary_valid and primary_valid, str(query.label) + " must publish valid cache radiance.")
		check(complete_support and absf(cache_weight - 1.0) < 0.000001,
				str(query.label) + " full-valid samples must publish complete support with C=1.")
		check(selected_level == level and sample_status == 1 and reject_reason == 0,
				str(query.label) + " diagnostics must report its full-support selected level.")
		check(cell_fraction.distance_to(fraction) < 0.00001,
				str(query.label) + " diagnostics must expose the selected trilinear cell fraction.")
		check(secondary.distance_to(expected_secondary) < 0.0002,
				str(query.label) + " secondary SH slabs must match wrapped trilinear oracle; actual="
				+ str(secondary) + " expected=" + str(expected_secondary))
		check(primary.distance_to(expected_primary) < 0.0002,
				str(query.label) + " primary SH slabs must match wrapped trilinear oracle; actual="
				+ str(primary) + " expected=" + str(expected_primary))
		if not secondary_valid or not primary_valid or not complete_support \
				or selected_level != level or sample_status != 1 or reject_reason != 0 \
				or cell_fraction.distance_to(fraction) >= 0.00001 \
				or absf(cache_weight - 1.0) >= 0.000001 \
				or secondary.distance_to(expected_secondary) >= 0.0002 \
				or primary.distance_to(expected_primary) >= 0.0002:
			all_match = false
	if set.is_valid():
		rd.free_rid(set)
	return all_match

func _dominant_axis(normal: Vector3) -> int:
	var magnitude := normal.abs()
	if magnitude.x >= magnitude.y and magnitude.x >= magnitude.z:
		return 0
	if magnitude.y >= magnitude.z:
		return 1
	return 2

func _run_partial(label: String, mutation: String, target: Vector3i,
		fraction: Vector3, expected_coverage: float) -> void:
	var saved_origins := origins
	var saved_spacing := clv_spacing
	var saved_texture := coefficient_texture
	origins = [Vector3i(-8, -8, -8), Vector3i(-8, -8, -8), Vector3i(-8, -8, -8)]
	check(rd.buffer_update(parameters, 0, 80, _clipmap_parameters(true, 2)) == OK,
			label + " must expose a valid coarser cache level for the no-mixing check.")
	var query := _case(label, Vector3i(-1, 2, 3), fraction, 0, PATCH)
	var tag_texture := _create_tag_texture(mutation, target)
	coefficient_texture = _create_coefficient_texture(false, mutation, target, true)
	var output := _run_single_with_values(query, tag_texture, nodes, triangles)
	check(not output.valid and not output.complete,
			label + " must reject incomplete CLV support so the caller uses one exact gather.")
	check(output.selected_level == 0 and output.sample_status == 0 and output.reject_reason == 8,
			label + " diagnostics must report an exact fallback at the first partial level.")
	check(output.cell_fraction.distance_to(fraction) < 0.00001,
			label + " diagnostics must expose the rejected stencil fraction.")
	check(absf(output.cache_weight - expected_coverage) < 0.00001,
			label + " diagnostics must report the measured partial coverage.")
	check(output.secondary.length() < 0.00001 and output.primary.length() < 0.00001,
			label + " must not read or return radiance from its invalid sentinel corner.")
	var coarse_tags := _create_tag_texture("invalidate_level0_stencil", Vector3i(15, 2, 3))
	_rd_free(coefficient_texture)
	coefficient_texture = _create_coefficient_texture(false)
	var coarse_output := _run_single_with_values(query, coarse_tags, nodes, triangles)
	check(coarse_output.valid and coarse_output.complete and coarse_output.selected_level == 1
				and coarse_output.sample_status == 1
				and absf(coarse_output.cache_weight - 1.0) < 0.00001,
			label + " fixture must prove a complete coarser cache exists when level zero is incomplete.")
	check(not output.valid and output.selected_level == 0,
			label + " must not silently replace the first partial level with coarser cache radiance.")
	_rd_free(coarse_tags)
	_rd_free(coefficient_texture)
	coefficient_texture = saved_texture
	_rd_free(tag_texture)
	origins = saved_origins
	clv_spacing = saved_spacing
	check(rd.buffer_update(parameters, 0, 80, _clipmap_parameters()) == OK,
			"CLV state must be restored after partial-support exact-fallback checks.")

func _run_zero_weight_invalid_metadata() -> void:
	var query := _case("zero-weight invalid metadata", Vector3i(-1, 2, 3),
			Vector3(0.0, 0.25, 0.6), 0, PATCH)
	var tags := _create_tag_texture("tag_xyz", Vector3i(0, 2, 3))
	var original_coefficients := coefficient_texture
	coefficient_texture = _create_coefficient_texture(false, "", Vector3i(0, 2, 3), true)
	var output := _run_single_with_values(query, tags, nodes, triangles)
	var expected_secondary := _expected(query.base, query.fraction, 0, false, false)
	var expected_primary := _expected(query.base, query.fraction, 0, true, false)
	check(output.valid and output.complete and output.selected_level == 0
				and output.sample_status == 1 and output.reject_reason == 0
				and absf(output.cache_weight - 1.0) < 0.00001,
			"A zero-weight invalid corner must leave all contributing cache support complete.")
	check(output.secondary.distance_to(expected_secondary) < 0.0002
				and output.primary.distance_to(expected_primary) < 0.0002,
			"Manual interpolation must skip the bright invalid zero-weight corner and match the full oracle.")
	_rd_free(tags)
	_rd_free(coefficient_texture)
	coefficient_texture = original_coefficients

func _run_zero_coverage_rejection() -> void:
	var tags := _create_tag_texture("")
	var query := _case("zero CLV coverage", Vector3i(-1, 2, 3), Vector3(0.35, 0.25, 0.6), 0, PATCH + 1)
	var output := _run_single_with_values(query, tags, nodes, triangles)
	check(not output.valid and not output.complete and absf(output.cache_weight) < 0.000001,
			"No matching receiver patch must keep C=0 and fall through to the exact path.")
	check(output.selected_level == -1 and output.sample_status == 0 and output.reject_reason == 3,
			"Zero metadata support diagnostics must report exact fallback and no valid corners.")
	_rd_free(tags)

func _run_black_primary() -> void:
	var original := coefficient_texture
	coefficient_texture = _create_coefficient_texture(true)
	var tags := _create_tag_texture("")
	var query := _case("true black primary", Vector3i(-1, 2, 3), Vector3(0.35, 0.25, 0.6), 0)
	var output := _run_single_with_values(query, tags, nodes, triangles)
	check(output.valid and output.complete and absf(output.cache_weight - 1.0) < 0.000001,
			"A valid all-black primary-SH field must stay complete cache support.")
	check(output.sample_status == 1 and output.reject_reason == 0,
			"A true-black primary field must remain a full-support diagnostic result.")
	check(output.primary.length() < 0.00001, "True black primary radiance must remain black.")
	_rd_free(tags)
	_rd_free(coefficient_texture)
	coefficient_texture = original

func _run_contact_invalid_blocker() -> void:
	var saved_origins := origins
	var saved_spacing := clv_spacing
	var saved_texture := coefficient_texture
	origins = [Vector3i(-8, -8, -8), Vector3i(-8, -8, -8), Vector3i(-8, -8, -8)]
	clv_spacing = 0.5
	check(rd.buffer_update(parameters, 0, 80, _clipmap_parameters(true, 1)) == OK,
			"Contact test must use its half-meter level-zero clipmap.")
	var bvh: Dictionary = Visibility.build(_contact_faces())
	check(not bvh.is_empty() and Visibility.validate(bvh.nodes, bvh.triangles),
			"Sphere/floor contact fixture must use the production BVH builder.")
	if bvh.is_empty():
		_restore_clv_test_state(saved_origins, saved_spacing, saved_texture)
		return
	var floor_patch := _find_floor_patch(bvh.triangles)
	var receiver_triangle := _find_floor_triangle(bvh.triangles)
	check(floor_patch > 0 and receiver_triangle >= 0,
			"Contact fixture must identify the floor patch and receiver triangle.")
	if floor_patch <= 0 or receiver_triangle < 0:
		_restore_clv_test_state(saved_origins, saved_spacing, saved_texture)
		return
	var base := _surface_grid_base(CONTACT_WORLD, Vector3.UP, clv_spacing)
	var fraction := _surface_grid_fraction(CONTACT_WORLD, Vector3.UP, clv_spacing, base)
	var overrides: Dictionary = {}
	var valid_coverage := 0.0
	var blocked_invalid := 0
	var blocked_valid_contributors := 0
	for z in 2:
		for y in 2:
			for x in 2:
				var offset := Vector3i(x, y, z)
				var weight := _corner_weight(fraction, offset)
				var cell := base + offset
				var corner := (Vector3(cell) + Vector3.ONE * 0.5) * clv_spacing
				var hit := _nearest_axis_surface(corner, bvh.triangles)
				var patch := int(hit.patch) if hit.found else -1
				var corner_normal: Vector3 = hit.normal if hit.found else Vector3.ZERO
				var valid := bool(hit.found) and patch == floor_patch \
						and corner_normal.dot(Vector3.UP) >= 0.9
				var blocked := Visibility.segment_blocked(bvh.nodes, bvh.triangles,
					corner, CONTACT_WORLD)
				overrides[cell] = {"patch": patch, "normal": corner_normal}
				if valid and weight > 0.0:
					valid_coverage += weight
					if blocked:
						blocked_valid_contributors += 1
				elif blocked:
					blocked_invalid += 1
	check(valid_coverage > 0.8 and valid_coverage < 0.85,
			"Contact fixture must retain its measured partial floor support.")
	check(blocked_invalid > 0 and blocked_valid_contributors == 0,
			"Contact fixture must block an invalid sphere corner while floor contributors remain clear.")
	var tag_texture := _create_tag_texture("")
	coefficient_texture = _create_coefficient_texture(false, "", Vector3i.ZERO,
			false, Vector3.UP, overrides, -1)
	var contact_nodes := rd.storage_buffer_create(bvh.nodes.size() * 4, bvh.nodes.to_byte_array())
	var contact_triangles := rd.storage_buffer_create(bvh.triangles.size() * 4,
			bvh.triangles.to_byte_array())
	var query := {"label": "near-touch sphere/floor", "world": CONTACT_WORLD,
			"normal": Vector3.UP, "receiver_triangle": receiver_triangle,
			"receiver_patch": floor_patch}
	var output := _run_single_with_values(query, tag_texture, contact_nodes, contact_triangles)
	check(not output.valid and not output.complete and output.selected_level == 0
				and output.sample_status == 0 and output.reject_reason == 8,
			"Near-touch floor partial support must miss the cache and use exact sampling.")
	check(absf(output.cache_weight - valid_coverage) < 0.002,
			"Contact cache weight must match the measured valid floor-corner coverage.")
	check(output.cell_fraction.distance_to(fraction) < 0.00002,
			"Contact sampling must keep the current floor interpolation address.")
	print("CLV_CONTACT_REGRESSION gap=%.6f spacing=%.3f base=%s fraction=%s coverage=%.6f blocked_invalid=%d blocked_contributors=%d cache_hit=%s diagnostic_coverage=%.6f status=%d reject=%d" % [
			0.020000 - 0.017502, clv_spacing, str(base), str(fraction), valid_coverage,
			blocked_invalid, blocked_valid_contributors, str(output.valid), output.cache_weight,
			output.sample_status, output.reject_reason])
	_rd_free(tag_texture)
	_rd_free(contact_nodes)
	_rd_free(contact_triangles)
	_restore_clv_test_state(saved_origins, saved_spacing, saved_texture)

func _run_zero_weight_blocker() -> void:
	var saved_origins := origins
	var saved_spacing := clv_spacing
	var saved_texture := coefficient_texture
	clv_spacing = 1.0
	check(rd.buffer_update(parameters, 0, 80, _clipmap_parameters(true, 1)) == OK,
			"Zero-weight wall test must use only level zero.")
	var query := _case("zero-weight blocked corner", Vector3i(-1, 2, 3),
			Vector3(0.35, 0.25, 0.0), 0, PATCH)
	var zero_corner := (Vector3(query.base + Vector3i(1, 0, 1)) + Vector3.ONE * 0.5)
	var faces := _plane_faces(query.world, Vector3.UP)
	faces.append_array(_small_wall_faces(zero_corner, query.world))
	var bvh: Dictionary = Visibility.build(faces)
	check(not bvh.is_empty() and Visibility.validate(bvh.nodes, bvh.triangles),
			"Zero-weight blocker must use the production BVH builder.")
	if bvh.is_empty():
		_restore_clv_test_state(saved_origins, saved_spacing, saved_texture)
		return
	var receiver_triangle := _find_receiver_triangle(bvh.triangles, query.world, Vector3.UP)
	check(receiver_triangle >= 0,
			"Zero-weight blocker query must resolve a real geometric receiver triangle.")
	if receiver_triangle < 0:
		_restore_clv_test_state(saved_origins, saved_spacing, saved_texture)
		return
	query.receiver_triangle = receiver_triangle
	query.receiver_patch = 0
	check(_corner_weight(query.fraction, Vector3i(1, 0, 1)) == 0.0
				and Visibility.segment_blocked(bvh.nodes, bvh.triangles, zero_corner, query.world),
			"The wall must block the exactly zero-weight stencil corner.")
	var positive_rays_clear := true
	for z in 2:
		for y in 2:
			for x in 2:
				var offset := Vector3i(x, y, z)
				if _corner_weight(query.fraction, offset) <= 0.0 or offset == Vector3i(1, 0, 1):
					continue
				var corner := (Vector3(query.base + offset) + Vector3.ONE * 0.5)
				positive_rays_clear = positive_rays_clear and not Visibility.segment_blocked(
						bvh.nodes, bvh.triangles, corner, query.world)
	check(positive_rays_clear,
			"The zero-weight wall must not obscure any positive-weight interpolation corner.")
	var tags := _create_tag_texture("")
	coefficient_texture = _create_coefficient_texture(false)
	var wall_nodes := rd.storage_buffer_create(bvh.nodes.size() * 4, bvh.nodes.to_byte_array())
	var wall_triangles := rd.storage_buffer_create(bvh.triangles.size() * 4,
			bvh.triangles.to_byte_array())
	var output := _run_single_with_values(query, tags, wall_nodes, wall_triangles)
	check(output.valid and output.complete and output.selected_level == 0
				and output.reject_reason == 0 and absf(output.cache_weight - 1.0) < 0.00001,
			"A blocked exactly zero-weight corner must not reject otherwise complete CLV support.")
	print("CLV_ZERO_WEIGHT_BLOCKER weight=0 blocked=true positive_rays_clear=%s result_valid=%s cache=%.6f status=%d reject=%d" % [
			str(positive_rays_clear), str(output.valid), output.cache_weight,
			output.sample_status, output.reject_reason])
	_rd_free(tags)
	_rd_free(wall_nodes)
	_rd_free(wall_triangles)
	_restore_clv_test_state(saved_origins, saved_spacing, saved_texture)

func _run_valid_weight_blocker() -> void:
	var saved_origins := origins
	var saved_spacing := clv_spacing
	var saved_texture := coefficient_texture
	clv_spacing = 1.0
	check(rd.buffer_update(parameters, 0, 80, _clipmap_parameters(true, 1)) == OK,
			"Positive-weight wall control must use only level zero.")
	var query := _case("positive-weight blocked corner", Vector3i(-1, 2, 3),
			Vector3(0.35, 0.25, 0.6), 0, PATCH)
	var blocked_offset := Vector3i(1, 0, 0)
	var blocked_corner := Vector3(query.base + blocked_offset) + Vector3.ONE * 0.5
	var faces := _plane_faces(query.world, Vector3.UP)
	faces.append_array(_small_wall_faces(blocked_corner, query.world))
	var bvh: Dictionary = Visibility.build(faces)
	check(not bvh.is_empty() and Visibility.validate(bvh.nodes, bvh.triangles),
			"Positive-weight thin-wall control must use the production BVH builder.")
	if bvh.is_empty():
		_restore_clv_test_state(saved_origins, saved_spacing, saved_texture)
		return
	var receiver_triangle := _find_receiver_triangle(bvh.triangles, query.world, Vector3.UP)
	check(receiver_triangle >= 0,
			"Positive-weight blocker query must resolve a real geometric receiver triangle.")
	if receiver_triangle < 0:
		_restore_clv_test_state(saved_origins, saved_spacing, saved_texture)
		return
	query.receiver_triangle = receiver_triangle
	query.receiver_patch = 0
	var corner_weight := _corner_weight(query.fraction, blocked_offset)
	check(corner_weight > 0.0 and Visibility.segment_blocked(bvh.nodes, bvh.triangles,
			blocked_corner, query.world),
			"Thin wall must block the positive-weight contributor segment.")
	var tags := _create_tag_texture("")
	coefficient_texture = _create_coefficient_texture(false)
	var wall_nodes := rd.storage_buffer_create(bvh.nodes.size() * 4, bvh.nodes.to_byte_array())
	var wall_triangles := rd.storage_buffer_create(bvh.triangles.size() * 4,
			bvh.triangles.to_byte_array())
	var output := _run_single_with_values(query, tags, wall_nodes, wall_triangles)
	check(not output.valid and not output.complete and output.selected_level == -1
				and output.cache_weight == 0.0 and output.reject_reason == 4,
			"A blocked positive-weight contributor must still reject the entire clipmap level.")
	print("CLV_POSITIVE_WEIGHT_BLOCKER weight=%.6f blocked=true result_valid=%s reject=%d" % [
			corner_weight, str(output.valid), output.reject_reason])
	_rd_free(tags)
	_rd_free(wall_nodes)
	_rd_free(wall_triangles)
	_restore_clv_test_state(saved_origins, saved_spacing, saved_texture)

func _run_partial_blocked_corner_uses_exact() -> void:
	var saved_origins := origins
	var saved_spacing := clv_spacing
	var saved_texture := coefficient_texture
	origins = [Vector3i(-8, -8, -8), Vector3i(-8, -8, -8), Vector3i(-8, -8, -8)]
	clv_spacing = 1.0
	check(rd.buffer_update(parameters, 0, 80, _clipmap_parameters(true, 1)) == OK,
			"Partial-plus-blocked CLV test must isolate the first level.")
	var fraction := Vector3(0.35, 0.25, 0.6)
	var query := _case("partial support with blocked valid corner",
			Vector3i(-1, 2, 3), fraction, 0, PATCH)
	var invalid_offset := Vector3i(0, 0, 0)
	var blocked_offset := Vector3i(1, 0, 0)
	var blocked_corner := Vector3(query.base + blocked_offset) + Vector3.ONE * 0.5
	var invalid_weight := _corner_weight(fraction, invalid_offset)
	var blocked_weight := _corner_weight(fraction, blocked_offset)
	var faces := _plane_faces(query.world, Vector3.UP)
	faces.append_array(_small_wall_faces(blocked_corner, query.world, 0.01))
	var bvh: Dictionary = Visibility.build(faces)
	check(not bvh.is_empty() and Visibility.validate(bvh.nodes, bvh.triangles),
			"Partial-plus-blocked fixture must use a valid thin-wall BVH.")
	if bvh.is_empty():
		_restore_clv_test_state(saved_origins, saved_spacing, saved_texture)
		return
	var receiver_triangle := _find_receiver_triangle(bvh.triangles, query.world, Vector3.UP)
	check(receiver_triangle >= 0,
			"Partial-plus-blocked query must resolve a real geometric receiver triangle.")
	if receiver_triangle < 0:
		_restore_clv_test_state(saved_origins, saved_spacing, saved_texture)
		return
	query.receiver_triangle = receiver_triangle
	query.receiver_patch = 0
	var blocked := blocked_weight > 0.0 and Visibility.segment_blocked(
			bvh.nodes, bvh.triangles, blocked_corner, query.world)
	check(invalid_weight > 0.0 and blocked,
			"The fixture must have a positive-weight invalid corner and a separately blocked valid corner.")
	var tags := _create_tag_texture("epoch", Vector3i(15, 2, 3))
	coefficient_texture = _create_coefficient_texture(false)
	var wall_nodes := rd.storage_buffer_create(bvh.nodes.size() * 4,
			bvh.nodes.to_byte_array())
	var wall_triangles := rd.storage_buffer_create(bvh.triangles.size() * 4,
			bvh.triangles.to_byte_array())
	var output := _run_single_with_values(query, tags, wall_nodes, wall_triangles)
	var expected_coverage := 1.0 - invalid_weight
	check(not output.valid and not output.complete and output.sample_status == 0
				and output.reject_reason == 8,
			"Incomplete positive-weight support must return exact before LOS work, even with another blocked corner.")
	check(output.selected_level == 0 and absf(output.cache_weight - expected_coverage) < 0.00001,
			"The early exact fallback must preserve first-level selection and partial coverage diagnostics.")
	check(output.secondary.length() < 0.00001 and output.primary.length() < 0.00001,
			"The partial-plus-blocked fallback must not return partial cached radiance.")
	print("CLV_PARTIAL_BLOCKED_EXACT invalid_weight=%.6f blocked_weight=%.6f blocked=%s valid=%s coverage=%.6f reason=%d" % [
			invalid_weight, blocked_weight, str(blocked), str(output.valid),
			output.cache_weight, output.reject_reason])
	_rd_free(tags)
	_rd_free(wall_nodes)
	_rd_free(wall_triangles)
	_restore_clv_test_state(saved_origins, saved_spacing, saved_texture)

func _restore_clv_test_state(saved_origins: Array[Vector3i], saved_spacing: float,
		saved_texture: RID) -> void:
	if coefficient_texture != saved_texture:
		_rd_free(coefficient_texture)
	coefficient_texture = saved_texture
	origins = saved_origins
	clv_spacing = saved_spacing
	check(rd.buffer_update(parameters, 0, 80, _clipmap_parameters()) == OK,
			"CLV sampling state must be restored after each geometry regression.")

func _contact_faces() -> PackedVector3Array:
	var faces := PackedVector3Array()
	var a := Vector3(-12.0, 0.017502, -12.0)
	var b := Vector3(12.0, 0.017502, 12.0)
	var c := Vector3(-12.0, 0.017502, 12.0)
	var d := Vector3(12.0, 0.017502, -12.0)
	faces.append_array(PackedVector3Array([a, b, c, a, d, b]))
	var center := Vector3(-1.644751, 0.92, -1.230381)
	for latitude in 18:
		var theta0 := PI * float(latitude) / 18.0
		var theta1 := PI * float(latitude + 1) / 18.0
		for longitude in 32:
			var phi0 := TAU * float(longitude) / 32.0
			var phi1 := TAU * float(longitude + 1) / 32.0
			var p00 := _sphere_point(center, theta0, phi0)
			var p01 := _sphere_point(center, theta0, phi1)
			var p10 := _sphere_point(center, theta1, phi0)
			var p11 := _sphere_point(center, theta1, phi1)
			_append_inward_triangle(faces, center, p00, p10, p11)
			_append_inward_triangle(faces, center, p00, p11, p01)
	return faces

func _sphere_point(center: Vector3, theta: float, phi: float) -> Vector3:
	return center + 0.9 * Vector3(sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi))

func _append_inward_triangle(faces: PackedVector3Array, center: Vector3,
		a: Vector3, b: Vector3, c: Vector3) -> void:
	var triangle_center := (a + b + c) / 3.0
	if (b - a).cross(c - a).dot(triangle_center - center) > 0.0:
		faces.append_array(PackedVector3Array([a, c, b]))
	else:
		faces.append_array(PackedVector3Array([a, b, c]))

func _find_floor_patch(triangles: PackedFloat32Array) -> int:
	for triangle in triangles.size() / 12:
		var index := triangle * 12
		var a := Vector3(triangles[index], triangles[index + 1], triangles[index + 2])
		var edge1 := Vector3(triangles[index + 4], triangles[index + 5], triangles[index + 6])
		var edge2 := Vector3(triangles[index + 8], triangles[index + 9], triangles[index + 10])
		if absf(a.y - 0.017502) < 0.00001 and edge2.cross(edge1).normalized().dot(Vector3.UP) > 0.99:
			return int(triangles[index + 11])
	return 0

func _find_floor_triangle(triangles: PackedFloat32Array) -> int:
	var point := Vector3(-1.644751 + 0.013, 0.017502, -1.230381 + 0.011)
	for triangle in triangles.size() / 12:
		var index := triangle * 12
		var a := Vector3(triangles[index], triangles[index + 1], triangles[index + 2])
		var edge1 := Vector3(triangles[index + 4], triangles[index + 5], triangles[index + 6])
		var edge2 := Vector3(triangles[index + 8], triangles[index + 9], triangles[index + 10])
		if absf(a.y - 0.017502) < 0.00001 and _inside_triangle(point, a, edge1, edge2):
			return triangle
	return -1

func _inside_triangle(point: Vector3, a: Vector3, edge1: Vector3, edge2: Vector3) -> bool:
	var relative := point - a
	var d00 := edge1.dot(edge1)
	var d01 := edge1.dot(edge2)
	var d11 := edge2.dot(edge2)
	var d20 := relative.dot(edge1)
	var d21 := relative.dot(edge2)
	var denominator := d00 * d11 - d01 * d01
	if absf(denominator) < 1e-10:
		return false
	var u := (d11 * d20 - d01 * d21) / denominator
	var v := (d00 * d21 - d01 * d20) / denominator
	return u >= -0.0001 and v >= -0.0001 and u + v <= 1.0001

func _nearest_axis_surface(point: Vector3, triangles: PackedFloat32Array) -> Dictionary:
	var directions := [Vector3.RIGHT, Vector3.LEFT, Vector3.UP, Vector3.DOWN,
			Vector3.BACK, Vector3.FORWARD]
	var best_distance := 1e30
	var result := {"found": false, "patch": -1, "normal": Vector3.ZERO}
	for direction: Vector3 in directions:
		for triangle in triangles.size() / 12:
			var index := triangle * 12
			var a := Vector3(triangles[index], triangles[index + 1], triangles[index + 2])
			var edge1 := Vector3(triangles[index + 4], triangles[index + 5], triangles[index + 6])
			var edge2 := Vector3(triangles[index + 8], triangles[index + 9], triangles[index + 10])
			var p := direction.cross(edge2)
			var determinant := edge1.dot(p)
			if absf(determinant) < triangles[index + 7]:
				continue
			var from_a := point - a
			var u := from_a.dot(p) / determinant
			var q := from_a.cross(edge1)
			var v := direction.dot(q) / determinant
			var distance := edge2.dot(q) / determinant
			if u < -1e-6 or v < -1e-6 or u + v > 1.000001 \
					or distance <= 0.00001 or distance >= best_distance or distance > 18.0:
				continue
			best_distance = distance
			result = {"found": true, "patch": int(triangles[index + 11]),
					"normal": edge2.cross(edge1).normalized()}
	return result

func _surface_grid_base(world: Vector3, normal: Vector3, step_size: float) -> Vector3i:
	var position := (world + normal * step_size * 0.75) / step_size - Vector3.ONE * 0.5
	return Vector3i(floori(position.x), floori(position.y), floori(position.z))

func _surface_grid_fraction(world: Vector3, normal: Vector3, step_size: float,
		base: Vector3i) -> Vector3:
	var position := (world + normal * step_size * 0.75) / step_size - Vector3.ONE * 0.5
	return position - Vector3(base)

func _corner_weight(fraction: Vector3, offset: Vector3i) -> float:
	return (fraction.x if offset.x == 1 else 1.0 - fraction.x) \
			* (fraction.y if offset.y == 1 else 1.0 - fraction.y) \
			* (fraction.z if offset.z == 1 else 1.0 - fraction.z)

func _find_receiver_triangle(triangle_data: PackedFloat32Array, point: Vector3,
		normal: Vector3) -> int:
	var target_normal := normal.normalized()
	for triangle in triangle_data.size() / 12:
		var index := triangle * 12
		var a := Vector3(triangle_data[index], triangle_data[index + 1], triangle_data[index + 2])
		var edge1 := Vector3(triangle_data[index + 4], triangle_data[index + 5], triangle_data[index + 6])
		var edge2 := Vector3(triangle_data[index + 8], triangle_data[index + 9], triangle_data[index + 10])
		var geometric_normal := edge2.cross(edge1)
		if geometric_normal.length_squared() <= 1e-12:
			continue
		if geometric_normal.normalized().dot(target_normal) > 0.99 \
				and _inside_triangle(point, a, edge1, edge2):
			return triangle
	return -1

func _small_wall_faces(corner: Vector3, world: Vector3, half_extent := 0.05) -> PackedVector3Array:
	var ray := (world - corner).normalized()
	var tangent := ray.cross(Vector3.UP)
	if tangent.length_squared() < 1e-8:
		tangent = ray.cross(Vector3.RIGHT)
	tangent = tangent.normalized() * half_extent
	var bitangent := ray.cross(tangent).normalized() * half_extent
	var center := (corner + world) * 0.5
	var a := center - tangent - bitangent
	var b := center + tangent - bitangent
	var c := center + tangent + bitangent
	var d := center - tangent + bitangent
	return PackedVector3Array([a, b, c, a, c, d])

func _run_geometric_query_position() -> void:
	var geometric_normal := Vector3(0.28, 0.92, 0.28).normalized()
	var shading_normal := Vector3(0.20, 0.96, 0.15).normalized()
	var world := Vector3.ONE * 0.95 + Vector3.ONE * 0.5 - shading_normal * 0.75
	var plane_bvh := _plane_bvh(world, geometric_normal)
	check(not plane_bvh.is_empty(), "Receiver-plane fixture must build a valid BVH.")
	if plane_bvh.is_empty():
		return
	var plane_nodes := rd.storage_buffer_create(plane_bvh.nodes.size() * 4,
			plane_bvh.nodes.to_byte_array())
	var plane_triangles := rd.storage_buffer_create(plane_bvh.triangles.size() * 4,
			plane_bvh.triangles.to_byte_array())
	var tags := _create_tag_texture("")
	var oblique_query := {"label": "oblique phase", "world": world,
			"normal": shading_normal, "receiver_triangle": 0, "receiver_patch": -1}
	var oblique := _run_single_with_values(oblique_query, tags, plane_nodes, plane_triangles)
	var adjusted_position: Vector3 = oblique.query_position
	var adjusted_base := _floor_vec3i(adjusted_position)
	check(oblique.query_position_valid,
			"Known, finite receiver geometry must produce a bounded safe query position.")
	check(adjusted_base != _floor_vec3i(_legacy_query_position(world, shading_normal, 1.0)),
			"An oblique near-corner query must advance to a geometrically safe interpolation cell.")
	check(_min_corner_plane_distance(adjusted_base, 1.0, world, geometric_normal) >= 0.00009,
			"Every adjusted oblique cell corner must lie outside the receiver tangent plane.")
	check(oblique.valid and oblique.complete and oblique.selected_level == 0,
			"A safe adjusted query must still use the production CLV sampler and preserve full support.")

	var negative_world := world - Vector3.ONE * 4.0
	var negative_bvh := _plane_bvh(negative_world, geometric_normal)
	var negative_nodes := rd.storage_buffer_create(negative_bvh.nodes.size() * 4,
			negative_bvh.nodes.to_byte_array())
	var negative_triangles := rd.storage_buffer_create(negative_bvh.triangles.size() * 4,
			negative_bvh.triangles.to_byte_array())
	var negative_query := {"label": "negative oblique phase", "world": negative_world,
			"normal": shading_normal, "receiver_triangle": 0, "receiver_patch": -1}
	var negative_result := _run_single_with_values(negative_query, tags,
			negative_nodes, negative_triangles)
	var negative_base := _floor_vec3i(negative_result.query_position)
	check(negative_result.query_position_valid
			and _min_corner_plane_distance(negative_base, 1.0, negative_world,
			geometric_normal) >= 0.00009,
			"The safe-cell arithmetic must handle negative world and logical coordinates.")
	var down_normal := Vector3.DOWN
	var down_world := Vector3(1.45, 1.4, 1.45)
	var down_bvh := _plane_bvh(down_world, down_normal)
	var down_nodes := rd.storage_buffer_create(down_bvh.nodes.size() * 4,
			down_bvh.nodes.to_byte_array())
	var down_triangles := rd.storage_buffer_create(down_bvh.triangles.size() * 4,
			down_bvh.triangles.to_byte_array())
	var original_coefficient_texture := coefficient_texture
	coefficient_texture = _create_coefficient_texture(false, "", Vector3i(15, 2, 3),
			false, down_normal)
	var down_query := {"label": "negative-axis unsafe phase", "world": down_world,
			"normal": down_normal, "receiver_triangle": 0, "receiver_patch": -1}
	var down_result := _run_single_with_values(down_query, tags, down_nodes, down_triangles)
	var down_base := _floor_vec3i(down_result.query_position)
	var down_legacy_base := _floor_vec3i(_legacy_query_position(down_world, down_normal, 1.0))
	check(down_result.query_position_valid and down_base.y < down_legacy_base.y
			and _min_corner_plane_distance(down_base, 1.0, down_world, down_normal) >= 0.00009,
			"A DOWN-facing unsafe cell must advance across a negative-axis boundary to the safe exterior cell.")
	var down_corner := Vector3(down_base) + Vector3(0.0, 1.0, 0.0) + Vector3.ONE * 0.5
	var down_faces := _plane_faces(down_world, down_normal)
	down_faces.append_array(_wall_faces(down_corner, down_world))
	var down_wall_bvh: Dictionary = Visibility.build(down_faces)
	check(not down_wall_bvh.is_empty() and Visibility.validate(down_wall_bvh.nodes,
			down_wall_bvh.triangles), "Negative-axis adjusted-query wall fixture must be a valid BVH.")
	if not down_wall_bvh.is_empty():
		check(Visibility.segment_blocked(down_wall_bvh.nodes, down_wall_bvh.triangles,
				down_corner, down_world),
			"A thin wall must still block the DOWN-facing adjusted corner-to-receiver connection.")
		var down_wall_nodes := rd.storage_buffer_create(down_wall_bvh.nodes.size() * 4,
				down_wall_bvh.nodes.to_byte_array())
		var down_wall_triangles := rd.storage_buffer_create(down_wall_bvh.triangles.size() * 4,
				down_wall_bvh.triangles.to_byte_array())
		check(rd.buffer_update(parameters, 0, 80, _clipmap_parameters(true, 1)) == OK,
				"Negative-axis wall gate test must limit sampling to the adjusted fine level.")
		down_query.receiver_patch = 0
		var down_blocked := _run_single_with_values(down_query, tags,
				down_wall_nodes, down_wall_triangles)
		print("CLV_DOWN_WALL_RESULT valid=", down_blocked.valid,
				" cache_weight=", down_blocked.cache_weight,
				" complete=", down_blocked.complete,
				" level=", down_blocked.selected_level,
				" status=", down_blocked.sample_status,
				" reason=", down_blocked.reject_reason)
		check(not down_blocked.valid and down_blocked.cache_weight == 0.0
				and down_blocked.reject_reason == 4,
				"The production sampler must preserve the all-corner blocker gate for a DOWN-facing query.")
		check(rd.buffer_update(parameters, 0, 80, _clipmap_parameters()) == OK,
				"All clipmap levels must be restored after the negative-axis wall gate test.")
		_rd_free(down_wall_nodes)
		_rd_free(down_wall_triangles)
	_rd_free(coefficient_texture)
	coefficient_texture = original_coefficient_texture

	var safe_world := Vector3.ZERO
	var safe_bvh := _plane_bvh(safe_world, Vector3.UP)
	var safe_nodes := rd.storage_buffer_create(safe_bvh.nodes.size() * 4,
			safe_bvh.nodes.to_byte_array())
	var safe_triangles := rd.storage_buffer_create(safe_bvh.triangles.size() * 4,
			safe_bvh.triangles.to_byte_array())
	var safe_query := {"label": "already safe axis cell", "world": safe_world,
			"normal": Vector3.UP, "receiver_triangle": 0, "receiver_patch": -1}
	var safe_result := _run_single_with_values(safe_query, tags, safe_nodes, safe_triangles)
	check(safe_result.query_position_valid
			and safe_result.query_position.distance_to(_legacy_query_position(
				safe_world, Vector3.UP, 1.0)) < 0.000001,
			"An already-safe axis-aligned cell must keep its original query address.")

	var unknown_query := {"label": "unknown receiver", "world": world,
			"normal": shading_normal, "receiver_triangle": -1, "receiver_patch": -1}
	var unknown_result := _run_single_with_values(unknown_query, tags, plane_nodes, plane_triangles)
	check(unknown_result.query_position_valid
			and unknown_result.query_position.distance_to(_legacy_query_position(
				world, shading_normal, 1.0)) < 0.000001,
			"An unknown receiver triangle must preserve the legacy query position.")
	check(not unknown_result.valid and unknown_result.reject_reason == 3,
			"A receiver without a legal geometric triangle must use exact fallback, not a shading-normal face slot.")
	var degenerate_bvh := Visibility.build(PackedVector3Array([world, world, world]))
	check(not degenerate_bvh.is_empty(), "Degenerate receiver fallback fixture must build.")
	if not degenerate_bvh.is_empty():
		var degenerate_nodes := rd.storage_buffer_create(degenerate_bvh.nodes.size() * 4,
				degenerate_bvh.nodes.to_byte_array())
		var degenerate_triangles := rd.storage_buffer_create(degenerate_bvh.triangles.size() * 4,
				degenerate_bvh.triangles.to_byte_array())
		var degenerate_query := {"label": "degenerate receiver normal", "world": world,
				"normal": shading_normal, "receiver_triangle": 0, "receiver_patch": -1}
		var degenerate_result := _run_single_with_values(degenerate_query, tags,
				degenerate_nodes, degenerate_triangles)
		check(degenerate_result.query_position_valid
					and degenerate_result.query_position.distance_to(_legacy_query_position(
						world, shading_normal, 1.0)) < 0.000001,
				"A degenerate geometric normal must keep the old finite query position.")
		_rd_free(degenerate_nodes)
		_rd_free(degenerate_triangles)
	var tiny_normal_query := {"label": "invalid tiny shading normal", "world": world,
			"normal": Vector3.ZERO, "receiver_triangle": 0, "receiver_patch": -1}
	var tiny_normal_result := _run_single_with_values(tiny_normal_query, tags,
			plane_nodes, plane_triangles)
	check(not tiny_normal_result.query_position_valid
				and tiny_normal_result.query_position == Vector3.ZERO,
			"An unusable shading normal must reject safely with initialized zero outputs.")

	# Put a separate thin wall across the adjusted cell's first corner ray. The
	# production sampler must still reject that level after moving the query.
	var blocked_corner := (Vector3(adjusted_base) + Vector3.ONE * 0.5)
	var wall_faces := _wall_faces(blocked_corner, world)
	var blocker_faces := _plane_faces(world, geometric_normal)
	blocker_faces.append_array(wall_faces)
	var blocker_bvh: Dictionary = Visibility.build(blocker_faces)
	check(not blocker_bvh.is_empty() and Visibility.validate(blocker_bvh.nodes,
			blocker_bvh.triangles), "Adjusted-query thin-wall fixture must be a valid BVH.")
	if not blocker_bvh.is_empty():
		var receiver_edge1 := Vector3(blocker_bvh.triangles[4],
				blocker_bvh.triangles[5], blocker_bvh.triangles[6])
		var receiver_edge2 := Vector3(blocker_bvh.triangles[8],
				blocker_bvh.triangles[9], blocker_bvh.triangles[10])
		check(absf(receiver_edge1.cross(receiver_edge2).normalized().dot(geometric_normal)) > 0.999,
				"The BVH's first leaf triangle must remain the intended receiver plane at index 0.")
		check(Visibility.segment_blocked(blocker_bvh.nodes, blocker_bvh.triangles,
				blocked_corner, world),
				"The separate wall must block the adjusted corner-to-receiver segment.")
		var blocker_nodes := rd.storage_buffer_create(blocker_bvh.nodes.size() * 4,
				blocker_bvh.nodes.to_byte_array())
		var blocker_triangles := rd.storage_buffer_create(blocker_bvh.triangles.size() * 4,
				blocker_bvh.triangles.to_byte_array())
		check(rd.buffer_update(parameters, 0, 80, _clipmap_parameters(true, 1)) == OK,
				"Single-level wall gate test must limit sampling to the adjusted fine level.")
		var blocked_query := {"label": "wall after geometric adjustment", "world": world,
				"normal": shading_normal, "receiver_triangle": 0, "receiver_patch": 0}
		var blocked := _run_single_with_values(blocked_query, tags,
				blocker_nodes, blocker_triangles)
		check(not blocked.valid and blocked.cache_weight == 0.0
					and blocked.reject_reason == 4,
				"Geometric adjustment must not bypass the production all-corner thin-wall gate.")
		check(rd.buffer_update(parameters, 0, 80, _clipmap_parameters()) == OK,
				"All clipmap levels must be restored after the geometric safety test.")
		_rd_free(blocker_nodes)
		_rd_free(blocker_triangles)

	for buffer in [plane_nodes, plane_triangles, negative_nodes, negative_triangles,
			down_nodes, down_triangles,
			safe_nodes, safe_triangles, tags]:
		_rd_free(buffer)

func _plane_bvh(world: Vector3, normal: Vector3) -> Dictionary:
	return Visibility.build(_plane_faces(world, normal))

func _plane_faces(world: Vector3, normal: Vector3) -> PackedVector3Array:
	var tangent := normal.cross(Vector3.UP)
	if tangent.length_squared() < 1e-8:
		tangent = normal.cross(Vector3.RIGHT)
	tangent = tangent.normalized()
	var bitangent := normal.cross(tangent).normalized()
	return PackedVector3Array([
		world + tangent * 100.0,
		world - tangent * 100.0 - bitangent * 100.0,
		world + bitangent * 100.0,
	])

func _wall_faces(corner: Vector3, world: Vector3) -> PackedVector3Array:
	var ray := (world - corner).normalized()
	var tangent := ray.cross(Vector3.UP)
	if tangent.length_squared() < 1e-8:
		tangent = ray.cross(Vector3.RIGHT)
	tangent = tangent.normalized() * 0.4
	var bitangent := ray.cross(tangent).normalized() * 0.4
	var center := (corner + world) * 0.5
	var a := center - tangent - bitangent
	var b := center + tangent - bitangent
	var c := center + tangent + bitangent
	var d := center - tangent + bitangent
	return PackedVector3Array([a, b, c, a, c, d])

func _legacy_query_position(world: Vector3, normal: Vector3, step_size: float) -> Vector3:
	return (world + normal * step_size * 0.75) / step_size - Vector3.ONE * 0.5

func _floor_vec3i(value: Vector3) -> Vector3i:
	return Vector3i(floori(value.x), floori(value.y), floori(value.z))

func _min_corner_plane_distance(base: Vector3i, step_size: float,
		world: Vector3, normal: Vector3) -> float:
	var offset := Vector3(1.0 if normal.x < 0.0 else 0.0,
			1.0 if normal.y < 0.0 else 0.0,
			1.0 if normal.z < 0.0 else 0.0)
	var corner := (Vector3(base) + offset + Vector3.ONE * 0.5) * step_size
	return (corner - world).dot(normal)

func _run_clv_disabled_reason() -> void:
	var tags := _create_tag_texture("")
	var query := _case("CLV disabled", Vector3i(2, 2, 2), Vector3(0.2, 0.3, 0.4), 0)
	check(rd.buffer_update(parameters, 0, 80, _clipmap_parameters(false)) == OK,
			"CLV-disabled diagnostic setup must update the clipmap control word.")
	var output := _run_single_with_values(query, tags, nodes, triangles)
	check(not output.valid and output.selected_level == -1 and output.sample_status == 0
				and output.reject_reason == 1,
			"Directional data with CLV disabled must report the exact-path fallback reason.")
	check(rd.buffer_update(parameters, 0, 80, _clipmap_parameters()) == OK,
			"CLV-enabled diagnostic setup must be restored after the disabled-path check.")
	_rd_free(tags)

func _run_outside_reason() -> void:
	var tags := _create_tag_texture("")
	var query := _case("outside all clipmaps", Vector3i(512, -300, 900),
			Vector3(0.2, 0.3, 0.4), 0)
	var output := _run_single_with_values(query, tags, nodes, triangles)
	check(not output.valid and output.selected_level == -1 and output.sample_status == 0
				and output.reject_reason == 2,
			"Out-of-range diagnostics must report that every clipmap level missed.")
	_rd_free(tags)

func _run_single(query: Dictionary, tag_texture: RID, node_buffer: RID,
		triangle_buffer: RID) -> bool:
	return bool(_run_single_with_values(query, tag_texture, node_buffer, triangle_buffer).valid)

func _run_single_with_values(query: Dictionary, tag_texture: RID, node_buffer: RID,
		triangle_buffer: RID) -> Dictionary:
	var values := PackedFloat32Array()
	var world: Vector3 = query.world
	var normal: Vector3 = query.normal
	values.append_array(PackedFloat32Array([world.x, world.y, world.z,
		float(query.get("receiver_triangle", -1)),
		normal.x, normal.y, normal.z, float(query.receiver_patch)]))
	var bytes := values.to_byte_array()
	rd.buffer_update(input_buffer, 0, bytes.size(), bytes)
	var clear := PackedByteArray()
	clear.resize(144)
	rd.buffer_update(output_buffer, 0, clear.size(), clear)
	var set := _uniform_set(tag_texture, node_buffer, triangle_buffer)
	if not set.is_valid():
		check(false, "Single-case CLV descriptor set must be valid.")
		return {"valid": false, "complete": false, "cache_weight": 0.0,
				"secondary": Vector3.ZERO, "primary": Vector3.ZERO,
				"selected_level": -1, "sample_status": 0, "reject_reason": -1,
				"cell_fraction": Vector3.ZERO, "query_position": Vector3.ZERO,
				"query_position_valid": false}
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	rd.compute_list_bind_uniform_set(list, set, 0)
	rd.compute_list_dispatch(list, 1, 1, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	var output := rd.buffer_get_data(output_buffer).to_float32_array()
	rd.free_rid(set)
	return {"valid": output[3] > 0.5 and output[7] > 0.5,
		"cache_weight": output[8], "complete": output[9] > 0.5,
		"selected_level": int(round(output[10])), "sample_status": int(round(output[11])),
		"reject_reason": int(round(output[15])),
		"cell_fraction": Vector3(output[19], output[23], output[27]),
		"secondary": Vector3(output[0], output[1], output[2]),
		"primary": Vector3(output[4], output[5], output[6]),
		"query_position": Vector3(output[28], output[29], output[30]),
		"query_position_valid": output[31] > 0.5,
		"cached_receiver_triangle": int(round(output[27])),
		"reference_receiver": Vector3(output[32], output[33], output[34]),
		"reference_receiver_triangle": int(round(output[35]))}

func _run_cached_receiver_tests() -> void:
	var saved_texture := coefficient_texture
	var bvh := _plane_bvh(Vector3.ZERO, Vector3.UP)
	var plane_nodes := rd.storage_buffer_create(bvh.nodes.size() * 4, bvh.nodes.to_byte_array())
	var plane_triangles := rd.storage_buffer_create(bvh.triangles.size() * 4, bvh.triangles.to_byte_array())
	var patch := int(bvh.triangles[11])
	check(rd.buffer_update(parameters, 0, 80, _clipmap_parameters(true, 1)) == OK,
			"Cached receiver tests must isolate the fine cascade.")
	for variant in ["valid", "back side", "grazing", "long segment", "no certificate",
			"fractional index", "invalid index", "stale epoch", "stale logical", "old layout", "hole"]:
		var certificate := 1.0
		if variant == "no certificate": certificate = 0.0
		if variant == "fractional index": certificate = 1.5
		if variant == "invalid index": certificate = 2.0
		var overrides := {Vector3i.ZERO: {"patch": patch, "normal": Vector3.UP,
				"certificate": certificate}}
		coefficient_texture = _create_coefficient_texture(false, "", Vector3i.ZERO,
			false, Vector3.UP, overrides, patch)
		var mutation := "epoch" if variant == "stale epoch" else \
			("tag_xyz" if variant == "stale logical" else "")
		var tags := _create_tag_texture(mutation, Vector3i.ZERO)
		var mode := -3 if variant == "back side" else \
			(-4 if variant == "grazing" else (-5 if variant == "long segment" else -2))
		var query := {"label": variant, "world": Vector3(0.25, 0.01, 0.25),
			"normal": Vector3.UP, "receiver_triangle": 0, "receiver_patch": mode}
		var query_triangles := plane_triangles
		if variant == "old layout":
			rd.buffer_update(parameters, 0, 80, _clipmap_parameters(true, 1, Clipmap.LAYOUT_VERSION - 1))
		if variant == "hole":
			# A finite triangle in the same plane must not become an infinite plane.
			var small := Visibility.build(PackedVector3Array([
				Vector3.ZERO, Vector3(0.1, 0, 0), Vector3(0, 0, 0.1)]))
			query_triangles = rd.storage_buffer_create(small.triangles.size() * 4,
					small.triangles.to_byte_array())
		var result := _run_single_with_values(query, tags, plane_nodes, query_triangles)
		if variant == "valid":
			check(result.query_position_valid and result.cached_receiver_triangle == 0,
					"A certified receiver must actually bypass BVH using its stored finite triangle.")
			check(result.query_position.distance_to(result.reference_receiver) < 0.00001
					and result.cached_receiver_triangle == result.reference_receiver_triangle,
					"The cached receiver must match the full BVH's position and triangle.")
		else:
			check(not result.query_position_valid and result.cached_receiver_triangle == -1,
					variant + " must retain the exact receiver search.")
		if query_triangles != plane_triangles:
			_rd_free(query_triangles)
		_rd_free(tags)
		_rd_free(coefficient_texture)
		rd.buffer_update(parameters, 0, 80, _clipmap_parameters(true, 1))
	_rd_free(plane_nodes)
	_rd_free(plane_triangles)
	coefficient_texture = saved_texture
	rd.buffer_update(parameters, 0, 80, _clipmap_parameters())

func _run_filtered_visibility_tests() -> void:
	var saved_shader := shader
	var saved_pipeline := pipeline
	var saved_texture := coefficient_texture
	var source := RDShaderSource.new()
	source.source_compute = _test_shader_source().replace("#version 450", """#version 450
#define MAGIC_GI_BAKED_VISIBILITY
float clv_probe_visibility(int probe, vec3 receiver) { return probe == 0 ? 1.0 : (probe == 1 ? 0.0 : 0.01); }
""")
	var spirv := rd.shader_compile_spirv_from_source(source)
	check(spirv.compile_error_compute.is_empty(),
			"Baked-visibility interpolation must compile: " + spirv.compile_error_compute)
	if not spirv.compile_error_compute.is_empty():
		return
	shader = rd.shader_create_from_spirv(spirv)
	pipeline = rd.compute_pipeline_create(shader)
	var query := _case("baked visibility", Vector3i(2, 2, 2), Vector3(0.2, 0.3, 0.4), 0, PATCH)
	var tags := _create_tag_texture("")
	var full := _run_single_with_values(query, tags, nodes, triangles)
	check(full.valid and full.complete and full.cache_weight > 0.99999,
			"All-visible baked proxies must preserve full hardware interpolation.")
	coefficient_texture = _create_coefficient_texture(false, "", Vector3i(2, 2, 2), true)
	var unfiltered := _run_single_with_values(query, tags, nodes, triangles)
	check(unfiltered.primary.length() > 100.0,
			"The bright-corner control must prove its contribution reaches interpolation.")
	_rd_free(coefficient_texture)
	coefficient_texture = _create_coefficient_texture(false, "proxy_blocked", Vector3i(2, 2, 2), true)
	var filtered := _run_single_with_values(query, tags, nodes, triangles)
	check(filtered.valid and not filtered.complete and filtered.sample_status == 2
			and absf(filtered.cache_weight - 0.664) < 0.00001,
			"A blocked 0.336-weight corner must leave 0.664 visible support without an exact gather.")
	check(filtered.primary.length() < 100.0 and filtered.secondary.length() < 100.0,
			"The blocked bright proxy must contribute no radiance after renormalization.")
	_rd_free(coefficient_texture)
	coefficient_texture = _create_coefficient_texture(false, "weak_visibility_proxy")
	var weak := _run_single_with_values(query, tags, nodes, triangles)
	check(not weak.valid and weak.primary.length() < 0.00001 and weak.secondary.length() < 0.00001,
			"Uniformly uncertain visibility must reject the level rather than normalize back to full brightness.")
	_rd_free(coefficient_texture)
	coefficient_texture = _create_coefficient_texture(true)
	var black := _run_single_with_values(query, tags, nodes, triangles)
	check(black.valid and black.primary.length() < 0.00001,
			"Valid black primary lighting must remain legal in the baked-visibility path.")
	_rd_free(coefficient_texture)
	coefficient_texture = _create_coefficient_texture(false, "no_visibility_proxy")
	var missing := _run_single_with_values(query, tags, nodes, triangles)
	check(not missing.valid, "Missing visibility proxies must never authorize cached radiance.")
	_rd_free(coefficient_texture)
	_rd_free(tags)
	_rd_free(pipeline)
	_rd_free(shader)
	coefficient_texture = saved_texture
	shader = saved_shader
	pipeline = saved_pipeline

func _uniform_set(tag_texture: RID, node_buffer: RID, triangle_buffer: RID) -> RID:
	var uniforms: Array[RDUniform] = []
	uniforms.append(_storage(0, node_buffer))
	uniforms.append(_storage(1, triangle_buffer))
	uniforms.append(_storage(18, directional))
	var sample_uniform := RDUniform.new()
	sample_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	sample_uniform.binding = 19
	sample_uniform.add_id(sampler)
	sample_uniform.add_id(coefficient_texture)
	uniforms.append(sample_uniform)
	var tag_uniform := RDUniform.new()
	tag_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	tag_uniform.binding = 20
	tag_uniform.add_id(sampler)
	tag_uniform.add_id(tag_texture)
	uniforms.append(tag_uniform)
	var params_uniform := RDUniform.new()
	params_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	params_uniform.binding = 21
	params_uniform.add_id(parameters)
	uniforms.append(params_uniform)
	uniforms.append(_storage(22, input_buffer))
	uniforms.append(_storage(23, output_buffer))
	var support_uniform := RDUniform.new()
	support_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	support_uniform.binding = 25
	support_uniform.add_id(sampler)
	support_uniform.add_id(support_texture)
	uniforms.append(support_uniform)
	return rd.uniform_set_create(uniforms, shader, 0)

func _storage(binding: int, buffer: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = binding
	uniform.add_id(buffer)
	return uniform

func _create_coefficient_texture(zero_primary: bool, mutation := "",
		target := Vector3i(15, 2, 3), bright_invalid := false,
		metadata_normal := Vector3.UP, metadata_overrides: Dictionary = {},
		default_metadata_patch := PATCH) -> RID:
	var width := RESOLUTION * Clipmap.CLV_TEXTURE_COLUMNS
	var height := RESOLUTION
	var depth := RESOLUTION * LEVELS
	var data := PackedFloat32Array()
	data.resize(width * height * depth * 4)
	var face_bases := [_diffuse_basis(Vector3.RIGHT), _diffuse_basis(metadata_normal),
			_diffuse_basis(Vector3.BACK)]
	for level in LEVELS:
		for z in RESOLUTION:
			for y in RESOLUTION:
				for x in width:
					var slab := x / RESOLUTION
					var px := x % RESOLUTION
					var face_axis := slab / Clipmap.CLV_FACE_SLOT_COLUMNS
					var face_column := slab % Clipmap.CLV_FACE_SLOT_COLUMNS
					var index := _index4(x, y, z + level * RESOLUTION, width, height)
					if face_column == Clipmap.SURFACE_METADATA_COLUMN:
						var current_normal := Vector3.RIGHT if face_axis == 0 else \
								(Vector3.UP if face_axis == 1 else Vector3.BACK)
						if face_axis == 1:
							current_normal = metadata_normal
						var current_patch := float(default_metadata_patch)
						var logical_cell := Vector3i(
							_logical_at_slot(px, origins[level].x),
							_logical_at_slot(y, origins[level].y),
							_logical_at_slot(z, origins[level].z))
						if face_axis == 1 and metadata_overrides.has(logical_cell):
							var override: Dictionary = metadata_overrides[logical_cell]
							current_normal = override.normal
							current_patch = float(override.patch)
						data[index] = current_normal.x
						data[index + 1] = current_normal.y
						data[index + 2] = current_normal.z
						data[index + 3] = current_patch
						if face_axis == 1 and level == 0 and px == target.x \
								and y == target.y and z == target.z:
							if mutation == "invalid_patch": data[index + 3] = -1.0
							if mutation == "normal": data[index + 1] = -1.0
							if mutation == "wrong_patch": data[index + 3] = float(PATCH + 1)
					elif face_column == Clipmap.SURFACE_ANCHOR_COLUMN:
						# Test surfaces do not carry a certificate unless a dedicated case sets one.
						data[index + 3] = 0.0
						var logical_cell := Vector3i(_logical_at_slot(px, origins[level].x),
							_logical_at_slot(y, origins[level].y), _logical_at_slot(z, origins[level].z))
						if face_axis == 1 and metadata_overrides.has(logical_cell):
							data[index + 3] = float(metadata_overrides[logical_cell].get("certificate", 0.0))
					elif face_column < Clipmap.RADIANCE_COEFFICIENT_COLUMNS:
						var primary := face_column >= 9
						var coefficient := face_column % 9
						var value := _field(coefficient, px, y, z, level, primary,
								zero_primary, face_axis)
						if face_axis == 1 and bright_invalid and level == 0 \
								and px == target.x and y == target.y and z == target.z:
							value = Vector3(4096.0, 2048.0, 1024.0)
						data[index] = value.x
						data[index + 1] = value.y
						data[index + 2] = value.z
						data[index + 3] = 1.0
						if face_column == 0:
							if mutation == "no_visibility_proxy": data[index + 3] = 0.0
							if mutation == "weak_visibility_proxy": data[index + 3] = 3.0
							if mutation == "proxy_blocked" and level == 0 and px == target.x \
									and y == target.y and z == target.z: data[index + 3] = 2.0
					elif face_column >= Clipmap.DIFFUSE_PROJECTION_COLUMN:
						var primary := face_column == Clipmap.DIFFUSE_PROJECTION_COLUMN + 1
						var basis: PackedFloat64Array = face_bases[face_axis]
						var logical_cell := Vector3i(_logical_at_slot(px, origins[level].x),
							_logical_at_slot(y, origins[level].y), _logical_at_slot(z, origins[level].z))
						if face_axis == 1 and metadata_overrides.has(logical_cell):
							basis = _diffuse_basis(metadata_overrides[logical_cell].normal)
						var value := Vector3.ZERO
						for k in 9:
							var coefficient := _field(k, px, y, z, level, primary, zero_primary, face_axis)
							if face_axis == 1 and bright_invalid and level == 0 \
									and px == target.x and y == target.y and z == target.z:
								coefficient = Vector3(4096.0, 2048.0, 1024.0)
							value += coefficient * basis[k]
						data[index] = value.x
						data[index + 1] = value.y
						data[index + 2] = value.z
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	format.width = width
	format.height = height
	format.depth = depth
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	return rd.texture_create(format, RDTextureView.new(), [data.to_byte_array()])

func _create_tag_texture(mutation: String, target := Vector3i(15, 2, 3)) -> RID:
	var data := PackedInt32Array()
	data.resize(RESOLUTION * RESOLUTION * RESOLUTION * LEVELS * 4)
	var invalid_stencil_base := Vector3i(
			_logical_at_slot(target.x, origins[0].x),
			_logical_at_slot(target.y, origins[0].y),
			_logical_at_slot(target.z, origins[0].z))
	for level in LEVELS:
		for z in RESOLUTION:
			for y in RESOLUTION:
				for x in RESOLUTION:
					var logical := Vector3i(
						_logical_at_slot(x, origins[level].x),
						_logical_at_slot(y, origins[level].y),
						_logical_at_slot(z, origins[level].z))
					var index := _index4(x, y, z + level * RESOLUTION, RESOLUTION, RESOLUTION)
					data[index] = logical.x
					data[index + 1] = logical.y
					data[index + 2] = logical.z
					data[index + 3] = EPOCH
					if mutation == "invalidate_level0_stencil" and level == 0 \
							and logical.x >= invalid_stencil_base.x \
							and logical.x <= invalid_stencil_base.x + 1 \
							and logical.y >= invalid_stencil_base.y \
							and logical.y <= invalid_stencil_base.y + 1 \
							and logical.z >= invalid_stencil_base.z \
							and logical.z <= invalid_stencil_base.z + 1:
						data[index + 3] = EPOCH - 1
	var mutation_index := _index4(target.x, target.y, target.z, RESOLUTION, RESOLUTION)
	if mutation == "tag_xyz": data[mutation_index] += 1
	if mutation == "epoch": data[mutation_index + 3] = EPOCH - 1
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SINT
	format.width = RESOLUTION
	format.height = RESOLUTION
	format.depth = RESOLUTION * LEVELS
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	return rd.texture_create(format, RDTextureView.new(), [data.to_byte_array()])

func _field(k: int, x: int, y: int, z: int, level: int, primary: bool,
		zero_primary: bool, face_axis := 1) -> Vector3:
	if primary and zero_primary:
		return Vector3.ZERO
	var wave := 0.004 * sin(TAU * (float(x) + 0.5) / RESOLUTION) \
			+ 0.003 * cos(TAU * (float(y) + 0.5) / RESOLUTION) \
			+ 0.002 * sin(TAU * (float(z) + 0.5) / RESOLUTION)
	var base := (0.12 if primary else 0.08) + 0.003 * float(k) + 0.0005 * float(level) \
			+ 0.03 * float(face_axis - 1) + wave
	return Vector3(base, base * 1.3 + 0.002, base * 1.7 + 0.004)

func _diffuse_basis(normal: Vector3) -> PackedFloat64Array:
	return PackedFloat64Array([
		0.2820947918,
		0.4886025119 * normal.y * (2.0 / 3.0),
		0.4886025119 * normal.z * (2.0 / 3.0),
		0.4886025119 * normal.x * (2.0 / 3.0),
		1.0925484306 * normal.x * normal.y * 0.25,
		1.0925484306 * normal.y * normal.z * 0.25,
		0.3153915653 * (3.0 * normal.z * normal.z - 1.0) * 0.25,
		1.0925484306 * normal.x * normal.z * 0.25,
		0.5462742153 * (normal.x * normal.x - normal.y * normal.y) * 0.25,
	])

func _expected(base: Vector3i, fraction: Vector3, level: int, primary: bool,
		zero_primary: bool, excluded_offset := Vector3i(-1, -1, -1),
		normal := Vector3.UP, face_axis := 1) -> Vector3:
	var basis := _diffuse_basis(normal)
	var result := Vector3.ZERO
	for k in 9:
		var coefficient := Vector3.ZERO
		for z in 2:
			for y in 2:
				for x in 2:
					if Vector3i(x, y, z) == excluded_offset:
						continue
					var weight := (fraction.x if x == 1 else 1.0 - fraction.x) \
							* (fraction.y if y == 1 else 1.0 - fraction.y) \
							* (fraction.z if z == 1 else 1.0 - fraction.z)
					coefficient += _field(k, posmod(base.x + x, RESOLUTION),
							posmod(base.y + y, RESOLUTION), posmod(base.z + z, RESOLUTION),
							level, primary, zero_primary, face_axis) * weight
		result += coefficient * basis[k]
	return Vector3(maxf(result.x, 0.0), maxf(result.y, 0.0), maxf(result.z, 0.0))

func _clipmap_parameters(clv_enabled := true, level_count := LEVELS,
		layout_version := Clipmap.LAYOUT_VERSION) -> PackedByteArray:
	var bytes := PackedByteArray()
	for origin in origins:
		bytes.append_array(PackedInt32Array([origin.x, origin.y, origin.z, 0]).to_byte_array())
	bytes.append_array(PackedFloat32Array([clv_spacing, 0.0, 0.0, 0.0]).to_byte_array())
	bytes.append_array(PackedInt32Array([RESOLUTION, level_count, EPOCH,
			layout_version if clv_enabled else 0]).to_byte_array())
	return bytes

func _expand_includes(path: String) -> String:
	var contents := FileAccess.get_file_as_string(path)
	if contents.is_empty(): return ""
	var lines := PackedStringArray()
	for line in contents.split("\n"):
		var trimmed := line.strip_edges()
		if not trimmed.begins_with("#include"):
			lines.append(line)
			continue
		var first := trimmed.find("\"")
		var last := trimmed.find("\"", first + 1)
		if first < 0 or last <= first: return ""
		var nested := _expand_includes(path.get_base_dir().path_join(
				trimmed.substr(first + 1, last - first - 1)))
		if nested.is_empty(): return ""
		lines.append(nested)
	return "\n".join(lines)

func _world_for(base: Vector3i, fraction: Vector3, level: int) -> Vector3:
	var step_size := float(1 << level)
	return (Vector3(base) + fraction + Vector3.ONE * 0.5) * step_size - Vector3.UP * step_size * 0.75

func _logical_at_slot(physical: int, origin: int) -> int:
	return origin + posmod(physical - posmod(origin, RESOLUTION), RESOLUTION)

func _index4(x: int, y: int, z: int, width: int, height: int) -> int:
	return ((z * height + y) * width + x) * 4

func _rd_free(rid: RID) -> void:
	if rid.is_valid(): rd.free_rid(rid)

func _finish() -> void:
	for rid in [coefficient_texture, support_texture, sampler, output_buffer, input_buffer, parameters,
			directional, triangles, nodes, pipeline, shader]:
		_rd_free(rid)
	if rd != null:
		rd.free()
		rd = null
	quit(1 if failures else 0)
