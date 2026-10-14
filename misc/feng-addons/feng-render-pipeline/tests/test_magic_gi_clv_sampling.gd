extends SceneTree

const Visibility = preload("res://addons/feng-magic-gi/feng_magic_gi_visibility.gd")
const Clipmap = preload("res://addons/feng-render-pipeline/passes/magic_gi_clv_cache.gd")
const MagicGIPass = preload("res://addons/feng-render-pipeline/passes/magic_gi_pass.gd")
const RESOLUTION := 16
const LEVELS := 3
const EPOCH := 7
const PATCH := 7

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
var coefficient_texture := RID()

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
	_rd_free(good_tags)
	_run_partial("wrong logical tag", "tag_xyz", Vector3i(15, 2, 3),
			Vector3i(0, 0, 0), Vector3(0.35, 0.25, 0.6), 0.805)
	_run_partial("stale epoch", "epoch", Vector3i(15, 2, 3),
			Vector3i(0, 0, 0), Vector3(0.35, 0.25, 0.6), 0.805)
	_run_partial("wrong patch", "wrong_patch", Vector3i(15, 2, 3),
			Vector3i(0, 0, 0), Vector3(0.35, 0.25, 0.6), 0.805)
	_run_partial("missing support", "invalid_patch", Vector3i(15, 2, 3),
			Vector3i(0, 0, 0), Vector3(0.35, 0.25, 0.6), 0.805)
	_run_partial("normal gate", "normal", Vector3i(15, 2, 3),
			Vector3i(0, 0, 0), Vector3(0.35, 0.25, 0.6), 0.805)
	_run_partial("zero-weight invalid corner", "tag_xyz", Vector3i(0, 2, 3),
			Vector3i(1, 0, 0), Vector3(0.0, 0.25, 0.6), 1.0)
	_run_zero_coverage_rejection()
	_run_black_primary()
	_run_thin_blocker()
	_run_geometric_query_position()
	_run_clv_disabled_reason()
	_run_outside_reason()
	print("MAGIC_GI_CLV_SAMPLING checks=", checks, " failures=", failures,
			" cases=interior,x,y,z,xyz,level1,level2,geometric_query,negative_world,known_wall gates=partial_tag,epoch,patch,support,normal,zero_weight,thin_wall,exact_support,focus_bounds,diagnostics")
	_finish()

func _test_focus_for_bounds() -> void:
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
	triangles = rd.storage_buffer_create(16, PackedFloat32Array([0, 0, 0, 0]).to_byte_array())
	directional = rd.storage_buffer_create(16, PackedFloat32Array([0, 0, 0, 0]).to_byte_array())
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
	return nodes.is_valid() and triangles.is_valid() and directional.is_valid() \
			and parameters.is_valid() and input_buffer.is_valid() and output_buffer.is_valid() \
			and sampler.is_valid()

func _test_shader_source() -> String:
	var visibility := _expand_includes("res://addons/feng-render-pipeline/library/magic-gi/magic_gi_visibility.glslinc")
	var sh := _expand_includes("res://addons/feng-render-pipeline/library/magic-gi/magic_gi_sh.glslinc")
	var sample := _expand_includes("res://addons/feng-render-pipeline/library/magic-gi/magic_gi_clv_sample.glslinc")
	if visibility.is_empty() or sh.is_empty() or sample.is_empty():
		check(false, "Regression shader must expand the production visibility, SH, and CLV sampler includes.")
		return ""
	return """
#version 450
layout(local_size_x = 1) in;
layout(set = 0, binding = 0, std430) readonly buffer VisibilityNodes { vec4 nodes[]; } visibility_bvh;
layout(set = 0, binding = 1, std430) readonly buffer VisibilityTriangles { vec4 triangles[]; } visibility_geometry;
layout(set = 0, binding = 22, std430) readonly buffer QueryCases { vec4 values[]; } query_cases;
layout(set = 0, binding = 23, std430) writeonly buffer Results { vec4 values[]; } results;
""" + visibility + "\n" + sh + "\n" + sample + """
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
	vec3 supported_secondary; vec3 supported_primary;
	complete_partial_clv(secondary, primary, cache_weight,
			vec3(0.0), vec3(0.0), 1.0, supported_secondary, supported_primary);
	results.values[index * 9 + 3] = vec4(supported_secondary, float(reject_reason));
	results.values[index * 9 + 4] = vec4(supported_primary, cell_fraction.x);
	vec3 unsupported_secondary; vec3 unsupported_primary;
	complete_partial_clv(secondary, primary, cache_weight,
			vec3(0.0), vec3(0.0), 0.0, unsupported_secondary, unsupported_primary);
	results.values[index * 9 + 5] = vec4(unsupported_secondary, cell_fraction.y);
	results.values[index * 9 + 6] = vec4(unsupported_primary, cell_fraction.z);
	vec3 blended_secondary; vec3 blended_primary;
	complete_partial_clv(vec3(2.0, 3.0, 4.0), vec3(5.0, 6.0, 7.0), 0.25,
			vec3(10.0, 20.0, 30.0), vec3(40.0, 50.0, 60.0), 1.0,
			blended_secondary, blended_primary);
	results.values[index * 9 + 7] = vec4(blended_secondary, 0.0);
	results.values[index * 9 + 8] = vec4(blended_primary, 0.0);
	if (normal_and_patch.w == -1.0) {
		vec3 query_position;
		ivec3 query_base;
		vec3 query_fraction;
		bool query_valid = clv_surface_query_position(world_and_triangle.xyz,
				normal_and_patch.xyz, int(world_and_triangle.w), clv.spacing.x,
				query_position, query_base, query_fraction);
		results.values[index * 9 + 7] = vec4(query_position, query_valid ? 1.0 : 0.0);
	}
}
"""

func _case(label: String, base: Vector3i, fraction: Vector3, level: int,
		receiver_patch := 0) -> Dictionary:
	var normal := Vector3.UP
	var step_size := float(1 << level)
	var world := (Vector3(base) + fraction + Vector3.ONE * 0.5) * step_size \
			- normal * step_size * 0.75
	return {"label": label, "base": base, "fraction": fraction, "level": level,
			"world": world, "normal": normal, "receiver_patch": receiver_patch,
			"receiver_triangle": -1}

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
		var expected_secondary := _expected(base, fraction, level, false, zero_primary)
		var expected_primary := _expected(base, fraction, level, true, zero_primary)
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
		if i == 0:
			check(Vector3(output[output_base + 12], output[output_base + 13], output[output_base + 14])
					.distance_to(secondary) < 0.00001,
					"Zero-RGB exact light with positive visible support must retain partial cached SH.")
			check(Vector3(output[output_base + 16], output[output_base + 17], output[output_base + 18])
					.distance_to(primary) < 0.00001,
					"Zero-RGB exact light with positive visible support must retain partial primary SH.")
			check(Vector3(output[output_base + 20], output[output_base + 21], output[output_base + 22]).length()
					< 0.00001,
					"Zero visible exact support must reject partial cached secondary SH even when exact RGB is black.")
			check(Vector3(output[output_base + 24], output[output_base + 25], output[output_base + 26]).length()
					< 0.00001,
					"Zero visible exact support must reject partial cached primary SH even when exact RGB is black.")
			check(Vector3(output[output_base + 28], output[output_base + 29], output[output_base + 30])
					.distance_to(Vector3(9.5, 18.0, 26.5)) < 0.00001,
					"Supported partial cache must add exact SH by the missing coverage weight.")
			check(Vector3(output[output_base + 32], output[output_base + 33], output[output_base + 34])
					.distance_to(Vector3(35.0, 43.5, 52.0)) < 0.00001,
					"Supported partial primary must add exact SH by the missing coverage weight.")
	if set.is_valid():
		rd.free_rid(set)
	return all_match

func _run_partial(label: String, mutation: String, target: Vector3i,
		invalid_offset: Vector3i, fraction: Vector3, expected_coverage: float) -> void:
	var query := _case(label, Vector3i(-1, 2, 3), fraction, 0, PATCH)
	var tag_texture := _create_tag_texture(mutation, target)
	var original_coefficients := coefficient_texture
	coefficient_texture = _create_coefficient_texture(false, mutation, target, true)
	var output := _run_single_with_values(query, tag_texture, nodes, triangles)
	var expected_secondary := _expected(query.base, fraction, 0, false, false, invalid_offset)
	var expected_primary := _expected(query.base, fraction, 0, true, false, invalid_offset)
	check(output.valid and not output.complete,
			label + " must publish only its metadata-valid partial CLV support.")
	check(output.selected_level == 0 and output.sample_status == 2 and output.reject_reason == 0,
			label + " diagnostics must identify the selected partial level without a reject reason.")
	check(output.cell_fraction.distance_to(fraction) < 0.00001,
			label + " diagnostics must expose the partial stencil fraction.")
	check(absf(output.cache_weight - expected_coverage) < 0.00001,
			label + " must expose the unnormalized valid trilinear coverage C.")
	check(output.secondary.distance_to(expected_secondary) < 0.0002,
			label + " must ignore its bright invalid secondary sentinel and match the partial SH oracle.")
	check(output.primary.distance_to(expected_primary) < 0.0002,
			label + " must ignore its bright invalid primary sentinel and match the partial SH oracle.")
	check(output.supported_secondary.distance_to(expected_secondary) < 0.0002
				and output.supported_primary.distance_to(expected_primary) < 0.0002,
			label + " must preserve partial radiance when exact visible support exists but exact RGB is black.")
	check(output.unsupported_secondary.length() < 0.00001
				and output.unsupported_primary.length() < 0.00001,
			label + " must use the exact black result when exact visible support is zero.")
	_rd_free(coefficient_texture)
	coefficient_texture = original_coefficients
	_rd_free(tag_texture)

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

func _run_thin_blocker() -> void:
	var faces := PackedVector3Array([
		Vector3(0.0, 0.0, 0.0), Vector3(0.0, 8.0, 0.0), Vector3(0.0, 8.0, 8.0),
		Vector3(0.0, 0.0, 0.0), Vector3(0.0, 8.0, 8.0), Vector3(0.0, 0.0, 8.0),
	])
	var bvh: Dictionary = Visibility.build(faces)
	check(not bvh.is_empty() and Visibility.validate(bvh.nodes, bvh.triangles),
			"Thin-blocker fixture must build a valid production-format static BVH.")
	if bvh.is_empty():
		return
	var wall_nodes := rd.storage_buffer_create(bvh.nodes.size() * 4, bvh.nodes.to_byte_array())
	var wall_triangles := rd.storage_buffer_create(bvh.triangles.size() * 4, bvh.triangles.to_byte_array())
	# The blocked corner is deliberately metadata-invalid; geometry must still test it.
	var tags := _create_tag_texture("tag_xyz")
	var query := _case("thin blocker", Vector3i(-1, 2, 3), Vector3(0.35, 0.25, 0.6), 0)
	check(Visibility.segment_blocked(bvh.nodes, bvh.triangles,
			Vector3(0.5, 2.5, 3.5), query.world),
			"The production BVH fixture must block an actual corner-to-receiver segment.")
	var output := _run_single_with_values(query, tags, wall_nodes, wall_triangles)
	check(not output.valid and absf(output.cache_weight) < 0.000001,
			"A thin blocker at an invalid-metadata corner must reject the complete level.")
	check(output.selected_level == -1 and output.sample_status == 0 and output.reject_reason == 4,
			"A thin blocker must expose the exact-fallback geometry rejection reason.")
	_rd_free(tags)
	_rd_free(wall_nodes)
	_rd_free(wall_triangles)

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
		world + bitangent * 100.0,
		world - tangent * 100.0 - bitangent * 100.0,
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
		"supported_secondary": Vector3(output[12], output[13], output[14]),
		"supported_primary": Vector3(output[16], output[17], output[18]),
		"unsupported_secondary": Vector3(output[20], output[21], output[22]),
		"unsupported_primary": Vector3(output[24], output[25], output[26]),
		"query_position": Vector3(output[28], output[29], output[30]),
		"query_position_valid": output[31] > 0.5}

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
	return rd.uniform_set_create(uniforms, shader, 0)

func _storage(binding: int, buffer: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = binding
	uniform.add_id(buffer)
	return uniform

func _create_coefficient_texture(zero_primary: bool, mutation := "",
		target := Vector3i(15, 2, 3), bright_invalid := false,
		metadata_normal := Vector3.UP) -> RID:
	var width := RESOLUTION * 19
	var height := RESOLUTION
	var depth := RESOLUTION * LEVELS
	var data := PackedFloat32Array()
	data.resize(width * height * depth * 4)
	for level in LEVELS:
		for z in RESOLUTION:
			for y in RESOLUTION:
				for x in width:
					var slab := x / RESOLUTION
					var px := x % RESOLUTION
					var index := _index4(x, y, z + level * RESOLUTION, width, height)
					if slab == 18:
						data[index] = metadata_normal.x
						data[index + 1] = metadata_normal.y
						data[index + 2] = metadata_normal.z
						data[index + 3] = float(PATCH)
						if level == 0 and px == target.x and y == target.y and z == target.z:
							if mutation == "invalid_patch": data[index + 3] = -1.0
							if mutation == "normal": data[index + 1] = -1.0
							if mutation == "wrong_patch": data[index + 3] = float(PATCH + 1)
					elif slab < 18:
						var primary := slab >= 9
						var coefficient := slab % 9
						var value := _field(coefficient, px, y, z, level, primary,
								zero_primary)
						if bright_invalid and level == 0 \
								and px == target.x and y == target.y and z == target.z:
							value = Vector3(4096.0, 2048.0, 1024.0)
						data[index] = value.x
						data[index + 1] = value.y
						data[index + 2] = value.z
						data[index + 3] = 1.0
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
		zero_primary: bool) -> Vector3:
	if primary and zero_primary:
		return Vector3.ZERO
	var wave := 0.004 * sin(TAU * (float(x) + 0.5) / RESOLUTION) \
			+ 0.003 * cos(TAU * (float(y) + 0.5) / RESOLUTION) \
			+ 0.002 * sin(TAU * (float(z) + 0.5) / RESOLUTION)
	var base := (0.12 if primary else 0.08) + 0.003 * float(k) + 0.0005 * float(level) + wave
	return Vector3(base, base * 1.3 + 0.002, base * 1.7 + 0.004)

func _expected(base: Vector3i, fraction: Vector3, level: int, primary: bool,
		zero_primary: bool, excluded_offset := Vector3i(-1, -1, -1)) -> Vector3:
	var normal := Vector3.UP
	var basis := PackedFloat64Array([
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
							level, primary, zero_primary) * weight
		result += coefficient * basis[k]
	return Vector3(maxf(result.x, 0.0), maxf(result.y, 0.0), maxf(result.z, 0.0))

func _clipmap_parameters(clv_enabled := true, level_count := LEVELS) -> PackedByteArray:
	var bytes := PackedByteArray()
	for origin in origins:
		bytes.append_array(PackedInt32Array([origin.x, origin.y, origin.z, 0]).to_byte_array())
	bytes.append_array(PackedFloat32Array([1.0, 0.0, 0.0, 0.0]).to_byte_array())
	bytes.append_array(PackedInt32Array([RESOLUTION, level_count, EPOCH, 1 if clv_enabled else 0]).to_byte_array())
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
	for rid in [coefficient_texture, sampler, output_buffer, input_buffer, parameters,
			directional, triangles, nodes, pipeline, shader]:
		_rd_free(rid)
	if rd != null:
		rd.free()
		rd = null
	quit(1 if failures else 0)
