extends SceneTree
## CPU regression for area/BSDF emitter MIS and path/UV metadata.

const Baker = preload("../feng_magic_gi_directional_baker.gd")
const BakeSet = preload("../feng_magic_gi_emitter_bake_set.gd")
const TraceScene = preload("../feng_magic_gi_trace_scene.gd")
const DirectionalData = preload("../feng_magic_gi_directional_data.gd")
const MomentBaker = preload("../feng_magic_gi_moment_baker.gd")
const TextureSampler = preload("../feng_magic_gi_texture_sampler.gd")
const MaterialSampler = preload("../feng_magic_gi_material_sampler.gd")
const BakeJob = preload("../feng_magic_gi_bake_job.gd")
const Data = preload("../feng_magic_gi_data.gd")
const Placement = preload("../feng_magic_gi_placement.gd")
const ProbeBaker = preload("../feng_magic_gi_baker.gd")

class TestVolume:
	extends Node3D
	var size := Vector3.ONE * 100000.0
	var probe_spacing := 1.0
	var bake_request_current := true

	func is_bake_request_current(generation: int) -> bool:
		return bake_request_current and generation == 17

class ProbeJobTracker:
	extends RefCounted
	var mutex := Mutex.new()
	var started := 0
	var finished_probes := PackedInt32Array()

	func record_started() -> void:
		mutex.lock()
		started += 1
		mutex.unlock()

	func record_finished(probe: int) -> void:
		mutex.lock()
		finished_probes.append(probe)
		mutex.unlock()

	func snapshot() -> Dictionary:
		mutex.lock()
		var result := {"started": started, "finished_probes": finished_probes.duplicate()}
		mutex.unlock()
		return result

class ControlledBakeJob:
	extends "../feng_magic_gi_bake_job.gd"
	var tracker: ProbeJobTracker
	var probe_index := -1
	var delay_usec := 0
	var force_failure := false

	func run(geometry: RefCounted, signature: int, probe: int,
			coordinates: Array[PackedFloat64Array], minimum_coordinates: Array[PackedFloat64Array],
			extra_coordinates: Array[PackedFloat64Array], visibility_rays: int,
			directional_sources: Array[Dictionary] = []) -> void:
		tracker.record_started()
		if delay_usec > 0:
			OS.delay_usec(delay_usec)
		super.run(geometry, signature, probe, coordinates, minimum_coordinates,
			extra_coordinates, visibility_rays, directional_sources)
		if force_failure:
			valid = false
		tracker.record_finished(probe_index)

class ControlledBaker:
	extends "../feng_magic_gi_baker.gd"
	var tracker: ProbeJobTracker
	var failure_probe := -1
	var slow_probe_delay_usec := 50000

	func _probe_worker_limit() -> int:
		return 2

	func _create_bake_job(data: Data, probe: int) -> BakeJob:
		var job := ControlledBakeJob.new()
		job.initialize(data, probe)
		job.tracker = tracker
		job.probe_index = probe
		job.delay_usec = slow_probe_delay_usec if probe == 0 else 1000
		job.force_failure = probe == failure_probe
		return job

class TestGeometry:
	extends RefCounted
	var trace_scene: RefCounted
	var emitters: RefCounted
	var bvh: TriangleMesh
	var faces := PackedVector3Array()
	var reflectance := PackedVector3Array()
	var face_materials := PackedInt32Array()
	var face_uv := PackedVector2Array()
	var face_uv2 := PackedVector2Array()
	var face_emitter_indices := PackedInt32Array()
	var material_sampler: RefCounted

	func trace(origin: Vector3, direction: Vector3, max_distance: float) -> Dictionary:
		return trace_scene.trace(origin, direction, max_distance)

	func trace_geometry(origin: Vector3, direction: Vector3,
			max_distance: float) -> Dictionary:
		return trace_scene.trace_geometry(origin, direction, max_distance)

	func trace_path(origin: Vector3, direction: Vector3, max_distance: float,
			start_face_index := -1) -> Dictionary:
		return trace_scene.trace_path(origin, direction, max_distance, start_face_index)

	func trace_emitter_connection(origin: Vector3, direction: Vector3,
			max_distance: float, start_face_index := -1) -> Dictionary:
		return trace_scene.trace_emitter_connection(origin, direction, max_distance, start_face_index)

class ReferenceGeometry:
	extends RefCounted
	var owner: Object
	var source: TestGeometry
	var emitters: RefCounted

	func trace_path(origin: Vector3, direction: Vector3, max_distance: float,
			start_face_index := -1) -> Dictionary:
		return source.trace_path(origin, direction, max_distance, start_face_index)

	func trace_geometry(origin: Vector3, direction: Vector3,
			max_distance: float) -> Dictionary:
		return source.trace(origin, direction, max_distance)

	func trace_emitter_connection(origin: Vector3, direction: Vector3,
			max_distance: float, start_face_index := -1) -> Dictionary:
		var hit: Dictionary = owner.call("_reference_trace_emitter_connection",
				source.trace_scene, origin, direction, max_distance, start_face_index)
		return hit

class CountingMaterialSampler:
	extends RefCounted
	var source: RefCounted
	var sample_calls := 0

	func bind(source_sampler: RefCounted) -> void:
		source = source_sampler

	func sample(material_index: int, uv: Vector2) -> Vector3:
		sample_calls += 1
		var sampled: Vector3 = source.call("sample", material_index, uv)
		return sampled

class CountingEmitterLookup:
	extends RefCounted
	var source: RefCounted
	var groups: Array = []
	var sample_texture_calls := 0
	var honor_deferred_sampling := true

	func bind(source_set: RefCounted) -> void:
		source = source_set
		groups = source_set.get("groups")

	func sample_texture(emitter_index: int, uv1: Vector2, uv2: Vector2) -> Vector3:
		sample_texture_calls += 1
		var sampled: Vector3 = source.call("sample_texture", emitter_index, uv1, uv2)
		return sampled

	func sample_connection(emitter_index: int, receiver: Vector3,
			receiver_normal: Vector3, u_triangle: float, u_barycentric: float,
			u_edge: float, max_distance: float, spherical_receiver := false,
			defer_texture_sampling := false) -> Dictionary:
		var deferred := defer_texture_sampling and honor_deferred_sampling
		var sampled: Dictionary = source.call("sample_connection", emitter_index,
			receiver, receiver_normal, u_triangle, u_barycentric, u_edge,
			max_distance, spherical_receiver, deferred)
		if not sampled.is_empty() and not deferred and emitter_index >= 0 \
				and emitter_index < groups.size() \
				and groups[emitter_index].get("texture_image") != null:
			sample_texture_calls += 1
		return sampled

	func solid_angle_pdf(emitter_index: int, receiver: Vector3, target: Vector3,
			geometric_normal: Vector3) -> float:
		return float(source.call("solid_angle_pdf", emitter_index, receiver,
			target, geometric_normal))

class TestOutput:
	extends Resource
	var positions := PackedVector3Array([Vector3.ZERO])
	var normals := PackedVector3Array([Vector3(0.0, 0.0, 1.0)])
	var directional: Resource
	var transfer := PackedFloat32Array()
	var primary_sky_visibility := PackedFloat32Array()
	var emitter_transport := PackedFloat32Array()

	func probe_count() -> int:
		return positions.size()

var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_check(RenderingServer.get_rendering_device() == null,
			"headless CPU tests run without a RenderingDevice")
	_test_power_heuristic()
	_test_canonical_face_metadata()
	_test_physical_first_hit_and_texture()
	_test_nee_visibility_skips_shading_work()
	_test_moment_baker_uses_geometry_only()
	_test_culling()
	_test_actual_baker(0.0012, 1.0, 1.0, 1024, false)
	_test_actual_baker(0.03, 1.0, 1.0, 1024, false)
	_test_actual_baker(4.0, 1.0, 1.0, 2048, false)
	_test_actual_baker(0.1, 0.2, 0.2, 4096, true)
	_test_actual_baker_bounces1()
	_test_affine_endpoint_native_ray_retry()
	await _test_rolling_probe_window()
	if failures == 0:
		print("EMITTER_MIS_TESTS_OK")
		quit(0)
	else:
		push_error("EMITTER_MIS_TESTS_FAILED: %d" % failures)
		quit(1)

func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS ", message)
	else:
		failures += 1
		push_error("FAIL " + message)

func _reference_trace_emitter_connection(scene: TraceScene, origin: Vector3,
		direction: Vector3, max_distance: float, start_face_index: int) -> Dictionary:
	if scene.bvh == null or direction.length_squared() <= 0.000000000001:
		return {}
	var normalized_direction := direction.normalized()
	var hit := scene.trace_path(origin, normalized_direction, max_distance, start_face_index)
	if not hit.is_empty():
		return hit
	var ray_hit: Dictionary = scene.bvh.intersect_ray(origin, normalized_direction)
	if ray_hit.is_empty():
		return {}
	var ray_face := int(ray_hit.get("face_index", -1))
	var start_step := BakeSet.ray_epsilon(origin)
	if ray_face == start_face_index \
			and ray_hit.position.distance_to(origin) <= start_step * 2.0:
		ray_hit = scene.bvh.intersect_ray(origin + normalized_direction * start_step,
				normalized_direction)
		if ray_hit.is_empty():
			return {}
	return scene._decorate_hit(ray_hit, normalized_direction)

func _test_power_heuristic() -> void:
	var pairs := [[0.0795774715, 0.25], [1.0e-20, 0.0795774715], [1.0e20, 0.0795774715]]
	for pair in pairs:
		var first := BakeSet.power_heuristic(pair[0], pair[1])
		var second := BakeSet.power_heuristic(pair[1], pair[0])
		_check(is_finite(first) and is_finite(second) and absf(first + second - 1.0) < 0.000001,
				"power heuristic complement for PDFs %s / %s" % [pair[0], pair[1]])

func _test_canonical_face_metadata() -> void:
	var emitters := BakeSet.new()
	emitters.groups.append({
		"texture_image": null, "use_uv2": false, "uv_scale": Vector3.ONE,
		"uv_offset": Vector3.ZERO, "repeat": true,
		"filter": BaseMaterial3D.TEXTURE_FILTER_LINEAR,
		"cull_mode": BaseMaterial3D.CULL_DISABLED, "area": 0.0, "triangles": []
	})
	var collapsed := emitters.append_triangle(0, Vector3.ZERO,
		Vector3(0.00001, 0.0, 0.0), Vector3(0.0, 1.0, 0.0),
		Vector2.ZERO, Vector2.ZERO, Vector2.ZERO,
		Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, 0)
	var a := Vector3(-0.5, -0.5, 1.0)
	var b := Vector3(0.5, -0.5, 1.0)
	var c := Vector3(0.0, 0.5, 1.0)
	var appended := emitters.append_triangle(0, a, b, c,
		Vector2.ZERO, Vector2.ZERO, Vector2.ZERO,
		Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, 1)
	_check(not collapsed and appended and emitters.groups[0].triangles.size() == 1
			and int(emitters.groups[0].triangles[0].native_face_index) == 1,
			"collapsed snapped source face is skipped without shifting native face ids")
	var sampled: Dictionary = emitters.sample_connection(0, Vector3.ZERO, Vector3.ZERO,
		0.2, 0.3, 0.7, 2.0, true)
	_check(not sampled.is_empty() and int(sampled.get("sample_face_index", -1)) == 1,
			"area sample carries the stable native face id after a collapsed face")
	var deferred_without_texture: Dictionary = emitters.sample_connection(0,
		Vector3.ZERO, Vector3.ZERO, 0.2, 0.3, 0.7, 2.0, true, true)
	_check(sampled.get("texture_rgb", Vector3.ONE) == Vector3.ZERO
			and deferred_without_texture.get("texture_rgb", Vector3.ONE) == Vector3.ZERO
			and not deferred_without_texture.has("texture_uv1")
			and not deferred_without_texture.has("texture_uv2"),
			"image-less emitters keep black texture radiance without interpolating or returning deferred UVs")
	if sampled.is_empty():
		return
	var faces := PackedVector3Array([
		Vector3.ZERO, Vector3(0.00001, 0.0, 0.0), Vector3(0.0, 1.0, 0.0),
		BakeSet.canonical_vertex(a), BakeSet.canonical_vertex(b), BakeSet.canonical_vertex(c)
	])
	var bvh := TriangleMesh.new()
	var created := bvh.create_from_faces(faces)
	_check(created, "native face-id fixture BVH builds")
	if not created:
		return
	var scene := TraceScene.new()
	scene.bvh = bvh
	scene.faces = faces
	scene.reflectance = PackedVector3Array([Vector3.ZERO, Vector3.ZERO])
	scene.face_materials = PackedInt32Array([-1, -1])
	scene.face_uv = PackedVector2Array()
	scene.face_uv2 = PackedVector2Array()
	for _face in 2:
		scene.face_uv.append_array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
		scene.face_uv2.append_array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
	scene.face_emitter_indices = PackedInt32Array([-1, 0])
	scene.emitters = emitters
	var hit: Dictionary = scene.trace_path(Vector3.ZERO, Vector3(0.0, 0.0, 1.0), 2.0)
	_check(int(hit.get("face_index", -1)) == 1 and int(hit.get("emitter_index", -1)) == 0,
			"native BVH face id maps to the matching sampled emitter face after collapse")
	var expected_normal := (faces[5] - faces[3]).cross(faces[4] - faces[3]).normalized()
	_check(hit.get("normal", Vector3.ZERO).distance_to(expected_normal) < 0.000001,
			"path-hit normal uses the same canonical face as UV and emission metadata")

func _test_physical_first_hit_and_texture() -> void:
	var image := Image.create(4, 4, false, Image.FORMAT_RGBAF)
	for y in 4:
		for x in 4:
			image.set_pixel(x, y, Color(float(x) / 3.0, float(y) / 3.0, 0.25, 1.0))
	var fixture := _make_geometry(1.0, 1.0, 1.0, BaseMaterial3D.CULL_BACK, image, true, true)
	var geometry: TestGeometry = fixture.geometry
	var receiver := Vector3.ZERO
	var sample: Dictionary = geometry.emitters.sample_connection(0, receiver, Vector3.ZERO,
		0.41, 0.37, 0.63, 2.0, true)
	_check(not sample.is_empty(), "nearby rectangle area sample exists")
	if sample.is_empty():
		return
	var deferred_sample: Dictionary = geometry.emitters.sample_connection(0, receiver,
		Vector3.ZERO, 0.41, 0.37, 0.63, 2.0, true, true)
	var deferred_texture: Vector3 = geometry.emitters.sample_texture(0,
		deferred_sample.texture_uv1, deferred_sample.texture_uv2)
	_check(deferred_sample.get("texture_rgb", Vector3.ONE) == Vector3.ZERO
			and deferred_texture == sample.texture_rgb,
		"deferred UV texture sample exactly matches the legacy eager public sample")
	var hit: Dictionary = geometry.trace_path(receiver, sample.sample_direction, 2.0, 0)
	_check(not hit.is_empty() and int(hit.get("emitter_index", -1)) == 0,
			"physical BSDF ray and sampled rectangle resolve to the same emitter group")
	if not hit.is_empty():
		_check(hit.position.distance_to(receiver + sample.sample_direction * float(sample.distance)) < 0.00001,
				"physical first-hit endpoint agrees with sampled distance")
	var center_hit: Dictionary = geometry.trace_path(receiver, Vector3(0.0, 0.0, 1.0), 2.0, 0)
	var expected_uv := Vector2(0.5, 0.5) * Vector2(0.5, 0.5) + Vector2(0.25, 0.25)
	var expected_texture := TextureSampler.sample(image, expected_uv, true,
			BaseMaterial3D.TEXTURE_FILTER_NEAREST)
	var actual_texture: Vector3 = center_hit.emission_texture_rgb
	_check(actual_texture.distance_to(expected_texture) < 0.00001,
			"emitter hit interpolates UV2 then applies UV scale/offset, repeat and nearest filter")
	geometry.emitters.groups[0]["cull_mode"] = BaseMaterial3D.CULL_DISABLED
	var reverse_hit: Dictionary = geometry.trace_path(Vector3(0.0, 0.0, 2.0),
		Vector3(0.0, 0.0, -1.0), 2.0)
	var forward_normal: Vector3 = center_hit.get("normal", Vector3.ZERO)
	var reverse_normal: Vector3 = reverse_hit.get("normal", Vector3.ZERO)
	_check(forward_normal.dot(Vector3(0.0, 0.0, 1.0)) < -0.999
			and reverse_normal.dot(Vector3(0.0, 0.0, -1.0)) < -0.999,
			"two-sided canonical hit normals face incoming rays from either side")
	var forward_continue := Baker.cosine_hemisphere_direction(forward_normal, 0.64, 0.31)
	var reverse_continue := Baker.cosine_hemisphere_direction(reverse_normal, 0.64, 0.31)
	_check(forward_continue.dot(forward_normal) > 0.0
			and reverse_continue.dot(reverse_normal) > 0.0,
			"cosine continuation stays in the same hemisphere for either hit side")
	_check(center_hit.get("emission_normal", Vector3.ZERO).dot(reverse_hit.get(
			"emission_normal", Vector3.ZERO)) > 0.999,
			"two-sided emission metadata keeps the canonical source normal independent of hit side")
	var shadow_hit: Dictionary = geometry.trace_emitter_connection(sample.shadow_origin,
		sample.shadow_direction, sample.visibility_distance, 0)
	_check(Baker._matches_sampled_emitter_hit(shadow_hit, 0, sample),
			"visibility confirms the exact sampled point is the physical first hit")
	_check(int(shadow_hit.get("face_index", -1)) == int(sample.get("sample_face_index", -2)),
			"sample metadata resolves to the same native face as the first hit")
	var rounded_same_face_hit := shadow_hit.duplicate()
	rounded_same_face_hit["position"] = sample.sample_position + sample.sample_direction * float(sample.endpoint_tolerance) * 2.0
	_check(Baker._matches_sampled_emitter_hit(rounded_same_face_hit, 0, sample),
			"selected native face identity preserves a valid hit beyond point-reconstruction tolerance")
	_check(sample.shadow_origin == receiver and sample.shadow_direction == sample.sample_direction,
			"visibility ray shares the integration origin and sampled physical line")

	# Exercise a surface start face, a thin blocker close to it, a grazing path,
	# and large-world epsilon scale against actual TriangleMesh first hits.
	var base_fixture := _make_geometry(1.0, 1.0, 1.0, BaseMaterial3D.CULL_BACK, null, false, true)
	var thin := _add_front_blocker(base_fixture, 0.0, 0.001)
	var thin_direction := Vector3(0.1, 0.3, 1.0).normalized()
	var thin_hit: Dictionary = thin.trace_path(Vector3.ZERO, thin_direction, 2.0, 0)
	_check(not thin_hit.is_empty() and int(thin_hit.face_index) >= 2
			and int(thin_hit.face_index) <= 3 and absf(float(thin_hit.position.z) - 0.001) < 0.000001,
			"physical ray catches a 1 mm blocker inside the former 3 cm offset; face=%d point=%s"
			% [int(thin_hit.get("face_index", -1)), str(thin_hit.get("position", Vector3.ZERO))])
	if not thin_hit.is_empty():
		var thin_sample: Dictionary = thin.emitters.sample_connection(0, Vector3.ZERO,
			Vector3.ZERO, 0.5, 0.5, 0.5, 2.0, true)
		var blocked_nee_hit: Dictionary = thin.trace_emitter_connection(thin_sample.shadow_origin,
			thin_sample.shadow_direction, thin_sample.visibility_distance, 0)
		_check(not Baker._matches_sampled_emitter_hit(blocked_nee_hit, 0, thin_sample),
			"area NEE visibility stops at the thin first-hit blocker; hit="
			+ str(blocked_nee_hit) + " endpoint=" + str(thin_sample.sample_position))
		var after_blocker_hit: Dictionary = thin.trace_path(thin_hit.position,
			thin_direction, 2.0, int(thin_hit.face_index))
		_check(int(after_blocker_hit.get("emitter_index", -1)) == 0
				and absf(float(after_blocker_hit.position.z) - 1.0) < 0.00001,
				"next physical path skips only the 1 mm start-face self-hit and reaches the emitter")
		var half_mm := _add_front_blocker(base_fixture, 0.0, 0.0005)
		var half_mm_blocker: Dictionary = half_mm.trace_path(thin_sample.shadow_origin,
			thin_sample.shadow_direction, thin_sample.visibility_distance, 0)
		var half_mm_blocker_distance: float = half_mm_blocker.position.distance_to(thin_sample.shadow_origin)
		var short_nee_distance: float = half_mm_blocker_distance - maxf(
			BakeSet.ray_epsilon(thin_sample.shadow_origin) * 4.0, 0.000001)
		var short_nee_hit: Dictionary = half_mm.trace_path(thin_sample.shadow_origin,
			thin_sample.shadow_direction, short_nee_distance, 0)
		_check(short_nee_hit.is_empty(),
			"bounded NEE segment ends before the 0.5 mm blocker")
		var half_mm_hit: Dictionary = half_mm.trace_emitter_connection(
			thin_sample.shadow_origin, thin_sample.shadow_direction, short_nee_distance, 0)
		_check(not Baker._matches_sampled_emitter_hit(half_mm_hit, 0, thin_sample)
				and absf(float(half_mm_hit.get("position", Vector3.ZERO).z) - 0.0005) < 0.000001,
				"empty-segment NEE ray retry still returns the 0.5 mm first blocker")
	var short_path: Dictionary = base_fixture.geometry.trace_path(receiver,
		sample.sample_direction, float(sample.distance) * 0.5, 0)
	_check(short_path.is_empty(),
			"ordinary path queries remain finite and do not use the NEE ray retry")
	var same_group := _add_nearer_same_group_quad(base_fixture.geometry, 0.5)
	var farther_sample: Dictionary = same_group.emitters.sample_connection(0, receiver,
		Vector3.ZERO, 0.1, 0.5, 0.5, 2.0, true)
	var same_group_first: Dictionary = same_group.trace_emitter_connection(
		farther_sample.shadow_origin, farther_sample.shadow_direction,
		farther_sample.visibility_distance, -1)
	_check(not farther_sample.is_empty()
			and int(same_group_first.get("emitter_index", -1)) == 0
			and int(same_group_first.get("face_index", -1)) != int(farther_sample.sample_face_index)
			and not Baker._matches_sampled_emitter_hit(same_group_first, 0, farther_sample),
			"same-group nearer source face blocks a farther selected face")
	var grazing: Dictionary = base_fixture.geometry.trace_path(Vector3(0.0, 0.999, 0.0),
		Vector3(0.0005, 0.0, 1.0).normalized(), 2.0, 0)
	_check(not grazing.is_empty() and int(grazing.get("emitter_index", -1)) == 0,
			"grazing ray preserves the first emitter triangle")
	var large_point := Vector3(10000.0, 0.0, 0.0)
	var large_epsilon := BakeSet.ray_epsilon(large_point)
	_check(is_finite(large_epsilon) and large_epsilon > 0.0
			and large_epsilon < 0.01,
			"large-world epsilon scales to the float32 position precision at 10 km")
	var large_fixture := _make_geometry(1.0, 1.0, 1.0, BaseMaterial3D.CULL_BACK, null, false, false)
	var large_geometry: TestGeometry = _translate_geometry(large_fixture.geometry, large_point)
	var large_hit: Dictionary = large_geometry.trace_path(large_point, Vector3(0.0, 0.0, 1.0), 2.0)
	var large_expected_hit := large_point + Vector3(0.0, 0.0, 1.0)
	var large_position_error: float = large_hit.position.distance_to(large_expected_hit) if not large_hit.is_empty() else INF
	var large_distance_error: float = absf(large_hit.position.distance_to(large_point) - 1.0) if not large_hit.is_empty() else INF
	_check(int(large_hit.get("emitter_index", -1)) == 0
			and large_position_error <= large_epsilon
			and large_distance_error <= large_epsilon,
			"10 km physical ray first-hit position error=" + str(large_position_error)
			+ " m, distance error=" + str(large_distance_error) + " m, epsilon="
			+ str(large_epsilon) + " m")
	var large_blocker_base := _make_geometry(1.0, 1.0, 1.0,
		BaseMaterial3D.CULL_BACK, null, false, true)
	var large_blocker_scene: TestGeometry = _translate_geometry(
		large_blocker_base.geometry, large_point)
	var large_probe := large_point + Vector3(0.1, -0.2, 0.0)
	var large_blocker := _add_front_blocker({"geometry": large_blocker_scene},
		0.0, 0.001, large_point)
	var large_blocker_hit: Dictionary = large_blocker.trace_path(large_probe,
		thin_direction, 2.0, 0)
	_check(not large_blocker_hit.is_empty() and int(large_blocker_hit.face_index) >= 2
			and int(large_blocker_hit.face_index) <= 3
			and absf(float(large_blocker_hit.position.z) - 0.001) < 0.000001,
			"10 km translated origin still hits a 1 mm physical blocker; hit="
			+ str(large_blocker_hit))
	var large_sub_epsilon_blocker := _add_front_blocker({"geometry": large_blocker_scene},
		0.0, 0.0005, large_point)
	var large_sub_epsilon_hit: Dictionary = large_sub_epsilon_blocker.trace_path(large_probe,
		thin_direction, 2.0, 0)
	_check(not large_sub_epsilon_hit.is_empty()
			and absf(float(large_sub_epsilon_hit.position.z) - 0.0005) < 0.000001,
			"10 km translated origin does not skip a representable 0.5 mm blocker; hit="
			+ str(large_sub_epsilon_hit))

func _test_culling() -> void:
	var fixture := _make_geometry(1.0, 1.0, 1.0, BaseMaterial3D.CULL_BACK, null, false, false)
	var geometry: TestGeometry = fixture.geometry
	var upward := geometry.trace_path(Vector3.ZERO, Vector3(0.0, 0.0, 1.0), 2.0)
	_check(int(upward.get("emitter_index", -1)) == 0,
			"back-cull source emits from its front side")
	var downward := geometry.trace_path(Vector3(0.0, 0.0, 2.0), Vector3(0.0, 0.0, -1.0), 2.0)
	_check(not downward.has("emitter_index"), "back-cull source does not emit from its back side")
	geometry.emitters.groups[0]["cull_mode"] = BaseMaterial3D.CULL_FRONT
	downward = geometry.trace_path(Vector3(0.0, 0.0, 2.0), Vector3(0.0, 0.0, -1.0), 2.0)
	_check(int(downward.get("emitter_index", -1)) == 0,
			"front-cull source emits from its back side")
	geometry.emitters.groups[0]["cull_mode"] = BaseMaterial3D.CULL_DISABLED
	downward = geometry.trace_path(Vector3(0.0, 0.0, 2.0), Vector3(0.0, 0.0, -1.0), 2.0)
	_check(int(downward.get("emitter_index", -1)) == 0,
			"two-sided source emits from either side")

func _test_nee_visibility_skips_shading_work() -> void:
	for use_uv2 in [false, true]:
		var fixture := _make_counted_textured_geometry(use_uv2, false)
		_compare_reference_and_fast_nee(fixture, 48, "UV%d emitter" % (2 if use_uv2 else 0), true, false)
	var blocker_fixture := _make_counted_textured_geometry(false, true)
	_compare_reference_and_fast_nee(blocker_fixture, 48, "finite textured blocker", false, true)

func _compare_reference_and_fast_nee(geometry: TestGeometry, rays: int,
		label: String, expect_emitter_texture_reduction: bool,
		expect_material_reduction: bool) -> void:
	var reference := ReferenceGeometry.new()
	reference.owner = self
	reference.source = geometry
	reference.emitters = geometry.emitters
	var emitter_lookup: CountingEmitterLookup = geometry.trace_scene.emitters
	var material_lookup: CountingMaterialSampler = geometry.trace_scene.material_sampler
	emitter_lookup.honor_deferred_sampling = false
	var coordinates := _coordinates(4, rays)
	var shifts := PackedFloat32Array([0.17, 0.61, 0.29, 0.83])
	var emitter_shifts := PackedFloat32Array()
	emitter_shifts.resize(6)
	var reference_output := _make_transport_output(geometry.emitters.groups.size())
	Baker.bake_probe(reference_output, reference, 0, rays, 1, 4.0,
		coordinates, shifts, emitter_shifts)
	var reference_material_calls := material_lookup.sample_calls
	var reference_emitter_texture_calls := emitter_lookup.sample_texture_calls
	material_lookup.sample_calls = 0
	emitter_lookup.sample_texture_calls = 0
	emitter_lookup.honor_deferred_sampling = true
	var fast_output := _make_transport_output(geometry.emitters.groups.size())
	Baker.bake_probe(fast_output, geometry, 0, rays, 1, 4.0,
		coordinates, shifts, emitter_shifts)
	var fast_material_calls := material_lookup.sample_calls
	var fast_emitter_texture_calls := emitter_lookup.sample_texture_calls
	_check(_same_float32_bytes(reference_output.transfer, fast_output.transfer),
		label + " surface transfer bytes remain identical")
	_check(_same_float32_bytes(reference_output.primary_sky_visibility,
			fast_output.primary_sky_visibility),
		label + " surface sky bytes remain identical")
	_check(_same_float32_bytes(reference_output.emitter_transport, fast_output.emitter_transport),
		label + " surface emission bytes remain identical")
	_check(_same_float32_bytes(reference_output.directional.transfer,
			fast_output.directional.transfer),
		label + " directional transfer bytes remain identical")
	_check(_same_float32_bytes(reference_output.directional.sky, fast_output.directional.sky),
		label + " directional sky bytes remain identical")
	_check(_same_float32_bytes(reference_output.directional.emission,
			fast_output.directional.emission),
		label + " directional emission bytes remain identical")
	if expect_emitter_texture_reduction:
		_check(reference_emitter_texture_calls > fast_emitter_texture_calls
				and fast_emitter_texture_calls > 0,
				label + " NEE skips duplicate source-texture sampling while path hits still sample it; old=%d fast=%d"
				% [reference_emitter_texture_calls, fast_emitter_texture_calls])
	if expect_material_reduction:
		_check(reference_material_calls > fast_material_calls and fast_material_calls > 0,
				label + " NEE skips blocker-texture sampling while path hits still sample it; old=%d fast=%d"
				% [reference_material_calls, fast_material_calls])

func _test_moment_baker_uses_geometry_only() -> void:
	var geometry: TestGeometry = _make_counted_textured_geometry(false, true)
	var reference := ReferenceGeometry.new()
	reference.source = geometry
	var minimum_coordinates := _coordinates(2,
		Data.VISIBILITY_TEXELS_PER_PROBE * 4)
	var extra_coordinates: Array[PackedFloat64Array] = []
	var visibility_rays := Data.VISIBILITY_TEXELS_PER_PROBE * 4
	var reference_data := _make_moment_test_data()
	var reference_ok := MomentBaker.bake(reference_data, reference, 0,
		Vector2(0.17, 0.61), visibility_rays,
		minimum_coordinates, extra_coordinates)
	var material_lookup: CountingMaterialSampler = geometry.trace_scene.material_sampler
	var emitter_lookup: CountingEmitterLookup = geometry.trace_scene.emitters
	var reference_material_calls := material_lookup.sample_calls
	var reference_emitter_calls := emitter_lookup.sample_texture_calls
	material_lookup.sample_calls = 0
	emitter_lookup.sample_texture_calls = 0
	var fast_data := _make_moment_test_data()
	var fast_ok := MomentBaker.bake(fast_data, geometry, 0,
		Vector2(0.17, 0.61), visibility_rays,
		minimum_coordinates, extra_coordinates)
	_check(reference_ok and fast_ok
			and reference_data.visibility_moments.to_byte_array()
				== fast_data.visibility_moments.to_byte_array(),
			"geometry-only visibility moments preserve every packed output value")
	_check(reference_material_calls > 0 and reference_emitter_calls > 0
			and material_lookup.sample_calls == 0 and emitter_lookup.sample_texture_calls == 0,
			"geometry-only moment tracing skips receiver albedo and emitter texture evaluation")

func _make_moment_test_data() -> Data:
	var data := Data.new()
	data.positions = PackedVector3Array([Vector3.ZERO])
	data.bake_distance = 4.0
	data.visibility_moments.resize(Data.VISIBILITY_TEXELS_PER_PROBE
			* Data.VISIBILITY_MOMENT_CHANNELS)
	return data

func _make_transport_output(source_count: int) -> TestOutput:
	var output := TestOutput.new()
	output.positions = PackedVector3Array([Vector3.ZERO])
	output.normals = PackedVector3Array([Vector3(0.0, 0.0, 1.0)])
	output.directional = DirectionalData.new()
	output.directional.allocate(1, source_count)
	output.transfer.resize(27)
	output.primary_sky_visibility.resize(9)
	output.emitter_transport.resize(source_count * 6)
	return output

func _same_float32_bytes(first: PackedFloat32Array, second: PackedFloat32Array) -> bool:
	return first.size() == second.size() and first.to_byte_array() == second.to_byte_array()

func _make_counted_textured_geometry(use_uv2: bool, with_blocker: bool) -> TestGeometry:
	var image := Image.create(4, 4, false, Image.FORMAT_RGBAF)
	for y in 4:
		for x in 4:
			image.set_pixel(x, y, Color(0.1 + 0.2 * x, 0.05 + 0.15 * y,
				0.2 + 0.03 * x + 0.02 * y, 1.0))
	var fixture := _make_geometry(1.0, 1.0, 1.0, BaseMaterial3D.CULL_BACK,
		image, use_uv2, false)
	var geometry: TestGeometry = fixture.geometry
	if with_blocker:
		geometry = _add_textured_blocker(geometry, 0.4, Vector2(0.2, 0.2))
	var emitter_lookup := CountingEmitterLookup.new()
	emitter_lookup.bind(geometry.emitters)
	geometry.emitters = emitter_lookup
	geometry.trace_scene.emitters = emitter_lookup
	var material_source := MaterialSampler.new()
	material_source.records.append({
		"image": image,
		"scale": Vector3.ONE,
		"offset": Vector3.ZERO,
		"repeat": true,
		"filter": BaseMaterial3D.TEXTURE_FILTER_NEAREST
	})
	var material_lookup := CountingMaterialSampler.new()
	material_lookup.bind(material_source)
	geometry.trace_scene.material_sampler = material_lookup
	return geometry

func _add_textured_blocker(original: TestGeometry, z: float,
		half_extent: Vector2) -> TestGeometry:
	var source: TraceScene = original.trace_scene
	var faces := source.faces.duplicate()
	var reflectance := source.reflectance.duplicate()
	var face_materials := source.face_materials.duplicate()
	var face_uv := source.face_uv.duplicate()
	var face_uv2 := source.face_uv2.duplicate()
	var face_emitters := source.face_emitter_indices.duplicate()
	var a := Vector3(-half_extent.x, -half_extent.y, z)
	var b := Vector3(half_extent.x, -half_extent.y, z)
	var c := Vector3(half_extent.x, half_extent.y, z)
	var d := Vector3(-half_extent.x, half_extent.y, z)
	var first_face := face_materials.size()
	_append_face(faces, reflectance, face_materials, face_uv, face_uv2,
		face_emitters, a, b, c, -1, Vector3.ONE)
	face_materials[first_face] = 0
	var second_face := face_materials.size()
	_append_face(faces, reflectance, face_materials, face_uv, face_uv2,
		face_emitters, a, c, d, -1, Vector3.ONE)
	face_materials[second_face] = 0
	var blocker_uv_start := face_uv.size() - 6
	face_uv[blocker_uv_start] = Vector2.ZERO
	face_uv[blocker_uv_start + 1] = Vector2.RIGHT
	face_uv[blocker_uv_start + 2] = Vector2.ONE
	face_uv[blocker_uv_start + 3] = Vector2.ZERO
	face_uv[blocker_uv_start + 4] = Vector2.ONE
	face_uv[blocker_uv_start + 5] = Vector2.DOWN
	var bvh := TriangleMesh.new()
	_check(bvh.create_from_faces(faces), "finite textured blocker TriangleMesh fixture builds")
	var trace := TraceScene.new()
	trace.bvh = bvh
	trace.faces = faces
	trace.reflectance = reflectance
	trace.face_materials = face_materials
	trace.face_uv = face_uv
	trace.face_uv2 = face_uv2
	trace.face_emitter_indices = face_emitters
	trace.emitters = source.emitters
	var geometry := TestGeometry.new()
	geometry.trace_scene = trace
	geometry.emitters = original.emitters
	return geometry

func _test_actual_baker(height: float, half_width: float, half_height: float,
		rays: int, textured: bool) -> void:
	var image: Image
	if textured:
		image = Image.create(4, 4, false, Image.FORMAT_RGBAF)
		for y in 4:
			for x in 4:
				image.set_pixel(x, y, Color(0.1 + 0.2 * x, 0.05 + 0.15 * y, 0.25, 1.0))
	var fixture := _make_geometry(half_width, half_height, height, BaseMaterial3D.CULL_BACK,
		image, textured, false)
	var output := TestOutput.new()
	output.directional = DirectionalData.new()
	output.directional.allocate(1, 1)
	output.transfer.resize(27)
	output.primary_sky_visibility.resize(9)
	output.emitter_transport.resize(6)
	var coordinates := _coordinates(4, rays)
	var shifts := PackedFloat32Array([0.17, 0.61, 0.29, 0.83])
	var emitter_shifts := PackedFloat32Array([0.37, 0.73, 0.11])
	Baker.bake_probe(output, fixture.geometry, 0, rays, 0, 20.0,
		coordinates, shifts, emitter_shifts)
	var expected_surface := _rectangle_diffuse_response(half_width / height,
		half_height / height)
	var actual_surface := float(output.emitter_transport[0])
	var tolerance := 0.035 if height < 0.1 else 0.06
	_check(is_finite(actual_surface) and absf(actual_surface - expected_surface)
			<= maxf(0.0002, expected_surface * tolerance),
			"actual bounces=0 surface MIS at h=" + str(height) + " got="
			+ str(actual_surface) + " expected=" + str(expected_surface))
	var solid_angle := 4.0 * atan((half_width / height) * (half_height / height)
			/ sqrt(1.0 + pow(half_width / height, 2.0) + pow(half_height / height, 2.0)))
	var expected_dc := 0.2820947918 * solid_angle
	var actual_dc := float(output.directional.emission[0])
	_check(is_finite(actual_dc) and absf(actual_dc - expected_dc)
			<= maxf(0.0003, expected_dc * tolerance),
			"actual bounces=0 SH uses physical source direction at h=" + str(height)
			+ " got=" + str(actual_dc) + " expected=" + str(expected_dc))
	var surface_finite := true
	for value in output.emitter_transport:
		surface_finite = surface_finite and is_finite(value)
	_check(surface_finite, "actual baker surface HDR values remain finite")
	var directional_finite := true
	for value in output.directional.emission:
		directional_finite = directional_finite and is_finite(value)
	_check(directional_finite, "actual baker directional HDR values remain finite")
	if textured:
		_check(output.emitter_transport[3] > 0.0
				and absf(output.emitter_transport[3] - output.emitter_transport[0]) > 0.01,
				"texture hit/NEE response stays in the separate UV2 transport term")
	var near_sample: Dictionary = fixture.geometry.emitters.sample_connection(0, Vector3.ZERO,
		Vector3(0.0, 0.0, 1.0), 0.43, 0.31, 0.72, 20.0, false)
	if not near_sample.is_empty():
		var p_b := maxf(Vector3(0.0, 0.0, 1.0).dot(near_sample.sample_direction), 0.0) / PI
		var p_l := float(near_sample.light_pdf)
		var w_l := BakeSet.power_heuristic(p_l, p_b)
		var w_b := BakeSet.power_heuristic(p_b, p_l)
		_check(absf(w_l + w_b - 1.0) < 0.000001,
				"area/cosine MIS weights close at h=" + str(height))

func _test_actual_baker_bounces1() -> void:
	# Use one deterministic path and pair its exact last-bounce area sample with
	# the cosine sample. The source faces away from the probe but toward the
	# secondary surface, so the only emitter response occurs at bounce 1.
	var fixture := _make_geometry(1.0, 1.0, 0.5, BaseMaterial3D.CULL_FRONT,
		null, false, false, Vector3(2.0, 0.0, 0.0))
	var scene: TraceScene = fixture.geometry.trace_scene
	var faces := scene.faces.duplicate()
	var reflectance := scene.reflectance.duplicate()
	var face_materials := scene.face_materials.duplicate()
	var face_uv := scene.face_uv.duplicate()
	var face_uv2 := scene.face_uv2.duplicate()
	var face_emitters := scene.face_emitter_indices.duplicate()
	var a := Vector3(0.8, -0.2, 1.0)
	var b := Vector3(1.2, -0.2, 1.0)
	var c := Vector3(1.2, 0.2, 1.0)
	var d := Vector3(0.8, 0.2, 1.0)
	_append_face(faces, reflectance, face_materials, face_uv, face_uv2,
		face_emitters, a, b, c, -1, Vector3.ONE)
	_append_face(faces, reflectance, face_materials, face_uv, face_uv2,
		face_emitters, a, c, d, -1, Vector3.ONE)
	var bvh := TriangleMesh.new()
	_check(bvh.create_from_faces(faces), "CPU deterministic bounce-1 TriangleMesh fixture builds")
	scene.bvh = bvh
	scene.faces = faces
	scene.reflectance = reflectance
	scene.face_materials = face_materials
	scene.face_uv = face_uv
	scene.face_uv2 = face_uv2
	scene.face_emitter_indices = face_emitters
	var first_direction := Vector3(1.0, 0.0, 1.0).normalized()
	var first_hit: Dictionary = fixture.geometry.trace_path(Vector3.ZERO,
		first_direction, 1000.0)
	_check(not first_hit.is_empty() and first_hit.normal.dot(Vector3(0.0, 0.0, -1.0)) > 0.99,
			"bounces=1 path reaches the secondary surface from its emitting side; normal="
			+ str(first_hit.get("normal", Vector3.ZERO)))
	if first_hit.is_empty():
		return
	var sample: Dictionary = fixture.geometry.emitters.sample_connection(0,
		first_hit.position, first_hit.normal, 0.0, 0.25, 0.99999994, 1000.0, false)
	_check(not sample.is_empty() and sample.sample_position.distance_to(Vector3(2.0, 0.0, 0.5)) < 0.00001,
			"bounces=1 area sample resolves to the intended shared emitter point")
	if sample.is_empty():
		return
	var secondary_path_hit: Dictionary = fixture.geometry.trace_path(first_hit.position,
		sample.sample_direction, 1000.0, int(first_hit.face_index))
	_check(Baker._matches_sampled_emitter_hit(secondary_path_hit, 0, sample),
			"bounces=1 cosine and area techniques hit the same sampled source point")
	var output := TestOutput.new()
	output.directional = DirectionalData.new()
	output.directional.allocate(1, 1)
	output.transfer.resize(27)
	output.primary_sky_visibility.resize(9)
	output.emitter_transport.resize(6)
	var rays := 1
	var coordinates := _coordinates(4, rays)
	coordinates[0][0] = 0.5
	coordinates[1][0] = 0.125
	coordinates[2][0] = 0.8
	coordinates[3][0] = 0.0
	var emitter_shifts := PackedFloat32Array([0.0, 0.0, 0.0, 0.5, 0.125, 0.19999994])
	Baker.bake_probe(output, fixture.geometry, 0, rays, 1, 1000.0,
		coordinates, PackedFloat32Array([0.0, 0.0, 0.0, 0.0]), emitter_shifts)
	var value := float(output.emitter_transport[0])
	var primary_weight := 4.0 * maxf(Vector3(0.0, 0.0, 1.0).dot(first_direction), 0.0)
	var path_pdf := Baker._path_direction_pdf(1, first_hit.normal, sample.sample_direction)
	var light_weight := BakeSet.power_heuristic(sample.light_pdf, path_pdf)
	var hit_weight := BakeSet.power_heuristic(path_pdf, sample.light_pdf)
	var expected := primary_weight * (float(sample.weight) * light_weight + hit_weight)
	_check(is_finite(value) and absf(value - expected) < 0.00001,
			"actual bounces=1 last-vertex MIS equals its analytic paired-sample value; got="
			+ str(value) + " expected=" + str(expected))
	var all_finite := true
	for value_component in output.emitter_transport:
		all_finite = all_finite and is_finite(value_component)
	_check(all_finite, "actual bounces=1 surface HDR values remain finite")

func _test_affine_endpoint_native_ray_retry() -> void:
	var translation := Vector3(8.765, -3.219, 4.981)
	var scale := Vector3(9.25, 0.17, 3.6)
	var rotation := Basis.from_euler(Vector3(1.17, -0.83, 0.55))
	var basis := Basis(rotation.x * scale.x, rotation.y * scale.y, rotation.z * scale.z)
	var receiver_normal := basis.x.cross(basis.y).normalized()
	var half_width := 0.85
	var half_height := 0.55
	var local_height := 1.4
	var a := basis * Vector3(-half_width, -half_height, local_height) + translation
	var b := basis * Vector3(half_width, -half_height, local_height) + translation
	var c := basis * Vector3(half_width, half_height, local_height) + translation
	var d := basis * Vector3(-half_width, half_height, local_height) + translation
	var fixture := _make_affine_geometry(a, b, c, d)
	var coordinates := _coordinates(4, 4)
	var source: Dictionary = fixture.geometry.emitters.sample_connection(0, translation,
		Vector3.ZERO,
		fposmod(coordinates[0][3] + 0.37, 1.0),
		fposmod(coordinates[1][3] + 0.73, 1.0),
		fposmod(coordinates[2][3] + 0.11, 1.0), 1000.0, true)
	_check(not source.is_empty(), "anisotropic affine regression produces its deterministic NEE sample")
	if source.is_empty():
		return
	var short_visibility_distance := float(source.distance) - maxf(
		float(source.endpoint_tolerance) * 2.0, 0.00001)
	var bounded_hit: Dictionary = fixture.geometry.trace_path(source.shadow_origin,
		source.shadow_direction, short_visibility_distance, -1)
	_check(bounded_hit.is_empty(),
			"anisotropic affine control has no hit when its bounded segment ends before the panel")
	var recovered_hit: Dictionary = fixture.geometry.trace_emitter_connection(
		source.shadow_origin, source.shadow_direction, short_visibility_distance, -1)
	_check(int(recovered_hit.get("face_index", -1)) == int(source.sample_face_index)
			and Baker._matches_sampled_emitter_hit(recovered_hit, 0, source),
			"NEE-only native-ray retry recovers the selected affine source face")
	var placement := Placement.new()
	placement.trace_scene = fixture.geometry.trace_scene
	placement.bvh_ready = true
	var forwarded_hit: Dictionary = placement.trace_emitter_connection(
		source.shadow_origin, source.shadow_direction, source.visibility_distance, -1)
	_check(Baker._matches_sampled_emitter_hit(forwarded_hit, 0, source),
			"Placement forwards the same NEE connection interface to its immutable TraceScene")

	# BakeJob passes the immutable TraceScene itself to DirectionalBaker. Running
	# it here guards the production interface instead of only the test wrapper.
	var data: Resource = Data.new()
	data.positions = PackedVector3Array([translation])
	data.normals = PackedVector3Array([receiver_normal])
	data.emitter_keys = PackedStringArray(["affine-panel"])
	data.bake_samples = 4
	data.bake_bounces = 1
	data.bake_distance = 1000.0
	var job := BakeJob.new()
	job.initialize(data, 0)
	var qmc_coordinates := _coordinates(4, 4)
	var minimum_coordinates := _coordinates(2, Data.VISIBILITY_TEXELS_PER_PROBE * 4)
	var extra_coordinates := _coordinates(2, 0)
	job.run(fixture.geometry.trace_scene, 731, 0, qmc_coordinates,
		minimum_coordinates, extra_coordinates, Data.VISIBILITY_TEXELS_PER_PROBE * 4)
	var baked_response := float(job.result.emitter_transport[0]) if job.valid else -1.0
	_check(job.valid and is_finite(baked_response) and baked_response > 0.0,
			"actual BakeJob→TraceScene call path returns finite positive emitter response; value="
			+ str(baked_response))

func _test_rolling_probe_window() -> void:
	var fixture: Dictionary = _make_geometry(1.0, 1.0, 0.03,
			BaseMaterial3D.CULL_BACK, null, false, false)
	var geometry: TestGeometry = fixture.geometry
	geometry.trace_scene.material_sampler = MaterialSampler.new()
	var positions := PackedVector3Array([
		Vector3.ZERO, Vector3(0.2, 0.0, 0.0), Vector3(1.1, 0.0, 0.0), Vector3(-0.4, 0.1, 0.0)])
	var scheduler_emitter_keys := PackedStringArray(["test-panel"])
	var data := _make_scheduler_data(positions, scheduler_emitter_keys)
	var reference := _make_scheduler_data(positions, scheduler_emitter_keys)
	var qmc_coordinates := ProbeBaker._build_qmc_base_coordinates(data.bake_samples,
			(data.bake_bounces + 1) * 2)
	var visibility_rays := Data.VISIBILITY_TEXELS_PER_PROBE * 4
	var minimum_coordinates := ProbeBaker._build_qmc_base_coordinates(visibility_rays, 2)
	var extra_coordinates := ProbeBaker._build_qmc_base_coordinates(0, 2)
	var tracker := ProbeJobTracker.new()
	var baker := ControlledBaker.new()
	baker.tracker = tracker
	var volume := TestVolume.new()
	get_root().add_child(volume)
	var succeeded: bool = await baker._run_probe_jobs(data, volume, 17,
		geometry.trace_scene, 8271, qmc_coordinates, minimum_coordinates,
		extra_coordinates, visibility_rays)
	_check(succeeded, "rolling worker window completes the full probe set")
	var tracked: Dictionary = tracker.snapshot()
	_check(tracked.started == positions.size()
			and tracked.finished_probes.size() == positions.size(),
			"rolling window joins every submitted probe job")
	_check(tracked.finished_probes.size() > 1
			and tracked.finished_probes[0] != 0,
			"controlled workload completes out of probe order")
	var reference_ok := true
	for probe in positions.size():
		var job := BakeJob.new()
		job.initialize(reference, probe)
		job.run(geometry.trace_scene, 8271, probe, qmc_coordinates,
			minimum_coordinates, extra_coordinates, visibility_rays)
		if not job.valid:
			reference_ok = false
			break
		job.merge(reference, probe)
	_check(reference_ok and _scheduler_payload_bytes_equal(data, reference),
			"out-of-order worker completion preserves every per-probe output byte")

	var failing_tracker := ProbeJobTracker.new()
	var failing_baker := ControlledBaker.new()
	failing_baker.tracker = failing_tracker
	failing_baker.failure_probe = 1
	var failed_data := _make_scheduler_data(positions, scheduler_emitter_keys)
	var failed: bool = await failing_baker._run_probe_jobs(failed_data, volume, 17,
		geometry.trace_scene, 8271, qmc_coordinates, minimum_coordinates,
		extra_coordinates, visibility_rays)
	var failed_jobs: Dictionary = failing_tracker.snapshot()
	_check(not failed and failed_jobs.started == failed_jobs.finished_probes.size()
			and failed_jobs.started <= 2
			and _scheduler_payload_bytes_equal(failed_data,
				_make_scheduler_data(positions, scheduler_emitter_keys)),
			"worker failure stops refill, joins every in-flight job, and skips discarded payloads")
	get_root().remove_child(volume)
	volume.free()

	var cancelled_tracker := ProbeJobTracker.new()
	var cancelled_baker := ControlledBaker.new()
	cancelled_baker.tracker = cancelled_tracker
	var cancelled_data := _make_scheduler_data(positions, scheduler_emitter_keys)
	var cancelled_volume := TestVolume.new()
	get_root().add_child(cancelled_volume)
	call_deferred("_invalidate_bake_request", cancelled_volume)
	var cancelled: bool = await cancelled_baker._run_probe_jobs(cancelled_data,
		cancelled_volume, 17, geometry.trace_scene, 8271, qmc_coordinates,
		minimum_coordinates, extra_coordinates, visibility_rays)
	var cancelled_jobs: Dictionary = cancelled_tracker.snapshot()
	_check(not cancelled and cancelled_jobs.started == cancelled_jobs.finished_probes.size()
			and cancelled_jobs.started <= 2
			and _scheduler_payload_bytes_equal(cancelled_data,
				_make_scheduler_data(positions, scheduler_emitter_keys)),
			"cancellation stops refill, joins every in-flight job, and skips discarded payloads")
	get_root().remove_child(cancelled_volume)
	cancelled_volume.free()

func _invalidate_bake_request(volume: TestVolume) -> void:
	volume.bake_request_current = false

func _make_scheduler_data(positions: PackedVector3Array,
		emitter_keys: PackedStringArray) -> Data:
	var data := Data.new()
	data.positions = positions.duplicate()
	data.normals.resize(positions.size())
	data.normals.fill(Vector3(0.0, 0.0, 1.0))
	data.emitter_keys = emitter_keys
	data.bake_samples = 8
	data.bake_bounces = 1
	data.bake_distance = 4.0
	data.transfer.resize(positions.size() * 27)
	data.primary_sky_visibility.resize(positions.size() * 9)
	data.visibility_moments.resize(positions.size() * Data.VISIBILITY_TEXELS_PER_PROBE
			* Data.VISIBILITY_MOMENT_CHANNELS)
	data.emitter_transport.resize(positions.size() * emitter_keys.size() * 6)
	data.directional = Data.DirectionalData.new()
	data.directional.allocate(positions.size(), emitter_keys.size())
	return data

func _scheduler_payload_bytes_equal(a: Data, b: Data) -> bool:
	return a.transfer.to_byte_array() == b.transfer.to_byte_array() \
		and a.primary_sky_visibility.to_byte_array() == b.primary_sky_visibility.to_byte_array() \
		and a.visibility_moments.to_byte_array() == b.visibility_moments.to_byte_array() \
		and a.emitter_transport.to_byte_array() == b.emitter_transport.to_byte_array() \
		and a.directional.transfer.to_byte_array() == b.directional.transfer.to_byte_array() \
		and a.directional.sky.to_byte_array() == b.directional.sky.to_byte_array() \
		and a.directional.emission.to_byte_array() == b.directional.emission.to_byte_array()

func _make_geometry(half_width: float, half_height: float, height: float,
		cull_mode: int, texture_image: Image, use_uv2: bool,
		include_receiver_face: bool, emitter_offset: Vector3 = Vector3.ZERO) -> Dictionary:
	var geometry := TestGeometry.new()
	var emitters := BakeSet.new()
	emitters.groups.append({
		"texture_image": texture_image,
		"use_uv2": use_uv2,
		"uv_scale": Vector3(0.5, 0.5, 1.0),
		"uv_offset": Vector3(0.25, 0.25, 0.0),
		"repeat": true,
		"filter": BaseMaterial3D.TEXTURE_FILTER_NEAREST,
		"cull_mode": cull_mode,
		"area": 0.0,
		"triangles": []
	})
	var faces := PackedVector3Array()
	var reflectance := PackedVector3Array()
	var face_materials := PackedInt32Array()
	var face_uv := PackedVector2Array()
	var face_uv2 := PackedVector2Array()
	var face_emitters := PackedInt32Array()
	if include_receiver_face:
		_append_face(faces, reflectance, face_materials, face_uv, face_uv2,
				face_emitters, Vector3(-2.0, -2.0, 0.0), Vector3(2.0, -2.0, 0.0),
				Vector3(2.0, 2.0, 0.0), -1, Vector3.ZERO)
	var a := Vector3(-half_width, -half_height, height) + emitter_offset
	var b := Vector3(half_width, -half_height, height) + emitter_offset
	var c := Vector3(half_width, half_height, height) + emitter_offset
	var d := Vector3(-half_width, half_height, height) + emitter_offset
	_append_emitter_face(geometry, emitters, faces, reflectance, face_materials,
			face_uv, face_uv2, face_emitters, a, b, c,
			Vector2.ZERO, Vector2.ZERO, Vector2.ZERO,
			Vector2.ZERO, Vector2(1.0, 0.0), Vector2.ONE)
	_append_emitter_face(geometry, emitters, faces, reflectance, face_materials,
			face_uv, face_uv2, face_emitters, a, c, d,
			Vector2.ZERO, Vector2.ZERO, Vector2.ZERO,
			Vector2.ZERO, Vector2.ONE, Vector2(0.0, 1.0))
	var bvh := TriangleMesh.new()
	var created := bvh.create_from_faces(faces)
	_check(created, "CPU TriangleMesh fixture builds")
	var trace_scene := TraceScene.new()
	trace_scene.bvh = bvh
	trace_scene.faces = faces
	trace_scene.reflectance = reflectance
	trace_scene.face_materials = face_materials
	trace_scene.face_uv = face_uv
	trace_scene.face_uv2 = face_uv2
	trace_scene.face_emitter_indices = face_emitters
	trace_scene.emitters = emitters
	geometry.emitters = emitters
	geometry.trace_scene = trace_scene
	return {"geometry": geometry}

func _add_nearer_same_group_quad(original: TestGeometry, height: float) -> TestGeometry:
	var scene: TraceScene = original.trace_scene
	var faces := scene.faces.duplicate()
	var reflectance := scene.reflectance.duplicate()
	var face_materials := scene.face_materials.duplicate()
	var face_uv := scene.face_uv.duplicate()
	var face_uv2 := scene.face_uv2.duplicate()
	var face_emitters := scene.face_emitter_indices.duplicate()
	var geometry := TestGeometry.new()
	geometry.emitters = original.emitters
	var a := Vector3(-1.0, -1.0, height)
	var b := Vector3(1.0, -1.0, height)
	var c := Vector3(1.0, 1.0, height)
	var d := Vector3(-1.0, 1.0, height)
	_append_emitter_face(geometry, geometry.emitters, faces, reflectance,
		face_materials, face_uv, face_uv2, face_emitters, a, b, c,
		Vector2.ZERO, Vector2.ZERO, Vector2.ZERO,
		Vector2.ZERO, Vector2.ZERO, Vector2.ZERO)
	_append_emitter_face(geometry, geometry.emitters, faces, reflectance,
		face_materials, face_uv, face_uv2, face_emitters, a, c, d,
		Vector2.ZERO, Vector2.ZERO, Vector2.ZERO,
		Vector2.ZERO, Vector2.ZERO, Vector2.ZERO)
	var bvh := TriangleMesh.new()
	_check(bvh.create_from_faces(faces), "same-group nearer-face TriangleMesh fixture builds")
	var trace := TraceScene.new()
	trace.bvh = bvh
	trace.faces = faces
	trace.reflectance = reflectance
	trace.face_materials = face_materials
	trace.face_uv = face_uv
	trace.face_uv2 = face_uv2
	trace.face_emitter_indices = face_emitters
	trace.emitters = geometry.emitters
	geometry.trace_scene = trace
	return geometry

func _make_affine_geometry(a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> Dictionary:
	var geometry := TestGeometry.new()
	var emitters := BakeSet.new()
	emitters.groups.append({
		"texture_image": null, "use_uv2": false,
		"uv_scale": Vector3.ONE, "uv_offset": Vector3.ZERO,
		"repeat": true, "filter": BaseMaterial3D.TEXTURE_FILTER_NEAREST,
		"cull_mode": BaseMaterial3D.CULL_BACK, "area": 0.0, "triangles": []
	})
	geometry.emitters = emitters
	for triangle in [[a, b, c], [a, c, d]]:
		var ta: Vector3 = triangle[0]
		var tb: Vector3 = triangle[1]
		var tc: Vector3 = triangle[2]
		var native_face_index := geometry.face_emitter_indices.size()
		_check(emitters.append_triangle(0, ta, tb, tc,
				Vector2.ZERO, Vector2.ZERO, Vector2.ZERO,
				Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, native_face_index),
				"affine emitter triangle enters canonical source geometry")
		geometry.faces.append_array([ta, tb, tc])
		geometry.reflectance.append(Vector3.ZERO)
		geometry.face_materials.append(-1)
		geometry.face_uv.append_array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
		geometry.face_uv2.append_array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
		geometry.face_emitter_indices.append(0)
	var bvh := TriangleMesh.new()
	_check(bvh.create_from_faces(geometry.faces), "anisotropic affine TriangleMesh fixture builds")
	geometry.bvh = bvh
	var trace_scene := TraceScene.new()
	var volume := TestVolume.new()
	get_root().add_child(volume)
	trace_scene.initialize(geometry, volume, 0.03)
	get_root().remove_child(volume)
	volume.free()
	geometry.trace_scene = trace_scene
	return {"geometry": geometry}

func _append_face(faces: PackedVector3Array, reflectance: PackedVector3Array,
		face_materials: PackedInt32Array, face_uv: PackedVector2Array,
		face_uv2: PackedVector2Array, face_emitters: PackedInt32Array,
		a: Vector3, b: Vector3, c: Vector3, emitter_index: int,
		albedo: Vector3) -> void:
	faces.append_array([BakeSet.canonical_vertex(a), BakeSet.canonical_vertex(b), BakeSet.canonical_vertex(c)])
	reflectance.append(albedo)
	face_materials.append(-1)
	face_uv.append_array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
	face_uv2.append_array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
	face_emitters.append(emitter_index)

func _append_emitter_face(geometry: TestGeometry, emitters: BakeSet,
		faces: PackedVector3Array, reflectance: PackedVector3Array,
		face_materials: PackedInt32Array, face_uv: PackedVector2Array,
		face_uv2: PackedVector2Array, face_emitters: PackedInt32Array,
		a: Vector3, b: Vector3, c: Vector3,
		uv1_a: Vector2, uv1_b: Vector2, uv1_c: Vector2,
		uv2_a: Vector2, uv2_b: Vector2, uv2_c: Vector2) -> void:
	var native_face_index := face_emitters.size()
	var appended := emitters.append_triangle(0, a, b, c,
			uv1_a, uv1_b, uv1_c, uv2_a, uv2_b, uv2_c, native_face_index)
	_check(appended, "emitter face enters stable source group")
	faces.append_array([BakeSet.canonical_vertex(a), BakeSet.canonical_vertex(b), BakeSet.canonical_vertex(c)])
	reflectance.append(Vector3.ZERO)
	face_materials.append(-1)
	face_uv.append_array([uv1_a, uv1_b, uv1_c])
	face_uv2.append_array([uv2_a, uv2_b, uv2_c])
	face_emitters.append(0)

func _add_front_blocker(fixture: Dictionary, z: float, blocker_z: float,
		offset: Vector3 = Vector3.ZERO) -> TestGeometry:
	var original: TestGeometry = fixture.geometry
	var blocker_faces := PackedVector3Array()
	var blocker_materials := PackedInt32Array()
	var blocker_emitters := PackedInt32Array()
	var blocker_reflectance := PackedVector3Array()
	var blocker_uv1 := PackedVector2Array()
	var blocker_uv2 := PackedVector2Array()
	var a := Vector3(-1.0, -1.0, z) + offset
	var b := Vector3(1.0, -1.0, z) + offset
	var c := Vector3(1.0, 1.0, z) + offset
	var d := Vector3(-1.0, 1.0, z) + offset
	_append_face(blocker_faces, blocker_reflectance, blocker_materials, blocker_uv1,
		blocker_uv2, blocker_emitters, a, b, c, -1, Vector3.ZERO)
	_append_face(blocker_faces, blocker_reflectance, blocker_materials, blocker_uv1,
		blocker_uv2, blocker_emitters, a, c, d, -1, Vector3.ZERO)
	a.z = blocker_z + offset.z
	b.z = blocker_z + offset.z
	c.z = blocker_z + offset.z
	d.z = blocker_z + offset.z
	_append_face(blocker_faces, blocker_reflectance, blocker_materials, blocker_uv1,
		blocker_uv2, blocker_emitters, a, b, c, -1, Vector3.ZERO)
	_append_face(blocker_faces, blocker_reflectance, blocker_materials, blocker_uv1,
		blocker_uv2, blocker_emitters, a, c, d, -1, Vector3.ZERO)
	for index in range(3, original.trace_scene.faces.size()):
		blocker_faces.append(original.trace_scene.faces[index])
		if index % 3 == 2:
			var original_face := int((index) / 3)
			blocker_reflectance.append(original.trace_scene.reflectance[original_face])
			blocker_materials.append(-1)
			blocker_emitters.append(int(original.trace_scene.face_emitter_indices[original_face]))
			blocker_uv1.append_array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
			blocker_uv2.append_array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
	var bvh := TriangleMesh.new()
	bvh.create_from_faces(blocker_faces)
	var trace := TraceScene.new()
	trace.bvh = bvh
	trace.faces = blocker_faces
	trace.reflectance = blocker_reflectance
	trace.face_materials = blocker_materials
	trace.face_uv = blocker_uv1
	trace.face_uv2 = blocker_uv2
	trace.face_emitter_indices = blocker_emitters
	trace.emitters = original.emitters
	var geometry := TestGeometry.new()
	geometry.trace_scene = trace
	geometry.emitters = original.emitters
	return geometry

func _translate_geometry(original: TestGeometry, offset: Vector3) -> TestGeometry:
	var trace := TraceScene.new()
	var faces := PackedVector3Array()
	for point in original.trace_scene.faces:
		faces.append(point + offset)
	var bvh := TriangleMesh.new()
	bvh.create_from_faces(faces)
	trace.bvh = bvh
	trace.faces = faces
	trace.reflectance = original.trace_scene.reflectance
	trace.face_materials = original.trace_scene.face_materials
	trace.face_uv = original.trace_scene.face_uv
	trace.face_uv2 = original.trace_scene.face_uv2
	trace.face_emitter_indices = original.trace_scene.face_emitter_indices
	trace.emitters = original.emitters
	var geometry := TestGeometry.new()
	geometry.trace_scene = trace
	geometry.emitters = original.emitters
	return geometry

func _coordinates(dimensions: int, count: int) -> Array[PackedFloat64Array]:
	var bases := [2, 3, 5, 7, 11, 13]
	var result: Array[PackedFloat64Array] = []
	for dimension in dimensions:
		var values := PackedFloat64Array()
		values.resize(count)
		for sample in count:
			values[sample] = _radical_inverse(sample + 1, bases[dimension])
		result.append(values)
	return result

func _radical_inverse(value: int, base: int) -> float:
	var current := value
	var factor := 1.0 / base
	var result := 0.0
	while current > 0:
		result += float(current % base) * factor
		current /= base
		factor /= base
	return result

func _rectangle_diffuse_response(half_width_over_height: float,
		half_height_over_height: float) -> float:
	var u := half_width_over_height
	var v := half_height_over_height
	var first := u / sqrt(1.0 + u * u) * atan(v / sqrt(1.0 + u * u))
	var second := v / sqrt(1.0 + v * v) * atan(u / sqrt(1.0 + v * v))
	return 2.0 * (first + second) / PI
