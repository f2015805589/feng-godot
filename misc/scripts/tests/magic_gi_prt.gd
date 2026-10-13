extends SceneTree

const Data = preload("res://addons/feng-magic-gi/feng_magic_gi_data.gd")
const Placement = preload("res://addons/feng-magic-gi/feng_magic_gi_placement.gd")
const Baker = preload("res://addons/feng-magic-gi/feng_magic_gi_baker.gd")
const Emission = preload("res://addons/feng-magic-gi/feng_magic_gi_emission.gd")
const Lighting = preload("res://addons/feng-magic-gi/feng_magic_gi_lighting.gd")
const Runtime = preload("res://addons/feng-magic-gi/feng_magic_gi_runtime.gd")
const Viz = preload("res://addons/feng-magic-gi/feng_magic_gi_viz.gd")
const ProbeLayout = preload("res://addons/feng-magic-gi/feng_magic_gi_probe_layout.gd")
const Volume = preload("res://addons/feng-magic-gi/feng_magic_gi_volume.gd")
const AdaptiveLayout = preload("res://addons/feng-magic-gi/feng_magic_gi_adaptive_layout.gd")
const SceneTracker = preload("res://addons/feng-magic-gi/feng_magic_gi_scene_tracker.gd")
const InspectorPlugin = preload("res://addons/feng-magic-gi/editor/magic_gi_inspector_plugin.gd")
const TraceScene = preload("res://addons/feng-magic-gi/feng_magic_gi_trace_scene.gd")
const MaterialSampler = preload("res://addons/feng-magic-gi/feng_magic_gi_material_sampler.gd")

class FakeTerrainData extends Object:
	signal maps_changed
	signal maps_edited(edited_area: AABB)

class ValidationCountingData:
	extends "res://addons/feng-magic-gi/feng_magic_gi_data.gd"
	var validation_count := 0

	func is_valid() -> bool:
		validation_count += 1
		return super.is_valid()

class CountingMaterialSampler extends RefCounted:
	var source: RefCounted
	var sample_calls := 0

	func sample(index: int, uv: Vector2) -> Vector3:
		sample_calls += 1
		return source.call("sample", index, uv)

class AdaptiveFeatureFaceStub extends RefCounted:
	var faces := PackedVector3Array()

class AdaptiveFeatureGeometryStub extends RefCounted:
	var query_count := 0

	func trace(_origin: Vector3, _direction: Vector3, _distance: float) -> Dictionary:
		query_count += 1
		return {}

var _failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_test_pure_contracts()
	await _test_adaptive_default_scene_compatibility()
	_test_probe_viz_contracts()
	await _test_small_triangle_centroid_sampling()
	await _test_centered_seam_clearance()
	_test_coplanar_crossing_topology()
	await _test_corner_center_separation()
	await _test_world_spacing_variants()
	_test_adaptive_feature_edge_budget()
	var scene := Node3D.new()
	root.add_child(scene)
	var density_volume := _new_uniform_test_volume()
	density_volume.size = Vector3(10.0, 10.0, 10.0)
	density_volume.probe_spacing = 1.0
	scene.add_child(density_volume)
	var white := _make_material(Color.WHITE)
	var coarse := MeshInstance3D.new()
	coarse.mesh = _make_horizontal_plane(10.0, 1, white)
	scene.add_child(coarse)
	await process_frame
	var placement := Placement.new()
	_check(placement.collect(density_volume, false), "coarse plane placement collection succeeds")
	var coarse_count := placement.positions.size()
	var coarse_anchor_keys := _surface_anchor_keys(placement.surface_positions)
	_check(coarse_count > 10, "plane creates many surface probes, not one overwritten slot")
	var fine_mesh := _make_horizontal_plane(10.0, 20, white)
	coarse.mesh = fine_mesh
	var fine_placement := Placement.new()
	var fine_collect_start_usec := Time.get_ticks_usec()
	var fine_collected: bool = fine_placement.collect(density_volume, false)
	var fine_collect_ms := float(Time.get_ticks_usec() - fine_collect_start_usec) / 1000.0
	_check(fine_collected, "fine plane placement collection succeeds")
	var fine_count := fine_placement.positions.size()
	_check(absf(float(fine_count - coarse_count)) <= maxf(12.0, coarse_count * 0.3),
			"probe count remains stable when plane tessellation changes (%d vs %d)" % [coarse_count, fine_count])
	_check(_surface_anchor_keys(fine_placement.surface_positions) == coarse_anchor_keys,
			"coplanar coarse and fine tessellations retain the same canonical world-grid anchors")
	_check(_minimum_same_normal_spacing(fine_placement) >= 0.79,
			"same-facing plane probes respect the spacing density")
	_check(_world_spacing_violation_pair_count(fine_placement.positions, 1.0) == 0
			and fine_placement.adjusted_center_count == 0,
			"ordinary plane placement keeps its samples while enforcing world-meter spacing")
	_check(_world_max_occupancy(fine_placement.positions, 1.0) == 1,
			"one world-aligned Probe Spacing cell retains at most one actual probe")
	_check(_normal_count(fine_placement, Vector3.UP) > 8, "plane probes face the visible surface")
	var fine_candidate_total := fine_placement._canonical_candidate_count \
			+ fine_placement._fallback_candidate_count
	var fallback_ratio := float(fine_placement._fallback_candidate_count) \
			/ maxf(1.0, float(fine_candidate_total))
	print("MAGIC_GI_CANONICAL_PLANE coarse=%d fine=%d collect_ms=%.3f raw=%d staged=%d selected=%d pruned=%d fine_canonical=%d fine_fallback=%d fallback_ratio=%.5f seam_rejections=%d" % [
		coarse_count, fine_count, fine_collect_ms, fine_placement._valid_candidate_count,
		fine_placement._staged_candidate_count, fine_placement.positions.size(),
		fine_placement._bounded_candidate_pruned_count,
		fine_placement._canonical_candidate_count,
		fine_placement._fallback_candidate_count, fallback_ratio,
		fine_placement.rejected_foreign_surface_center_count])
	density_volume.adaptive_placement = true
	var adaptive_fine_placement := Placement.new()
	var adaptive_fine_start_usec := Time.get_ticks_usec()
	var adaptive_fine_collected: bool = adaptive_fine_placement.collect(
			density_volume, false, false)
	var adaptive_fine_ms := float(Time.get_ticks_usec() - adaptive_fine_start_usec) / 1000.0
	_check(adaptive_fine_collected, "adaptive fine-plane candidate profile collects")
	_print_adaptive_profile("plane", adaptive_fine_placement, adaptive_fine_ms)
	_check(adaptive_fine_placement.probe_spacings.size() == adaptive_fine_placement.positions.size()
			and adaptive_fine_placement._refined_valid_candidate_count == 0
			and _adaptive_spacing_violation_pair_count(adaptive_fine_placement) == 0,
			"a smooth plane keeps coarse density and records its local spacing without fine overgeneration")
	coarse.queue_free()
	density_volume.queue_free()
	await process_frame
	var zero_volume := _new_uniform_test_volume()
	zero_volume.size = Vector3(4.0, 4.0, 4.0)
	zero_volume.probe_spacing = 1.0
	zero_volume.bake_samples = 64
	zero_volume.bake_bounces = 2
	zero_volume.bake_distance = 5.0
	scene.add_child(zero_volume)
	var isolated_ground := MeshInstance3D.new()
	isolated_ground.mesh = _make_horizontal_plane(4.0, 1, white)
	scene.add_child(isolated_ground)
	await process_frame
	var zero_bake_start_usec := Time.get_ticks_usec()
	var zero_baked: bool = await zero_volume.bake()
	var zero_bake_elapsed_ms := float(Time.get_ticks_usec() - zero_bake_start_usec) / 1000.0
	_check(zero_baked and zero_volume.bake_data.is_valid(),
			"an isolated plane produces a valid bake without secondary surface transport")
	if zero_baked:
		var center_probe := 0
		var center_probe_distance := INF
		for probe in zero_volume.bake_data.probe_count():
			var distance_to_center: float = zero_volume.bake_data.surface_positions[probe].length_squared()
			if distance_to_center < center_probe_distance:
				center_probe_distance = distance_to_center
				center_probe = probe
		var clear_up_moments: Vector2 = zero_volume.bake_data.sample_visibility_moments(center_probe, Vector3.UP)
		var ground_hit_moments: Vector2 = zero_volume.bake_data.sample_visibility_moments(center_probe, Vector3.DOWN)
		_check(clear_up_moments.x > zero_volume.bake_distance * 0.95
				and ground_hit_moments.x < zero_volume.bake_distance * 0.1,
				"measured directional moments distinguish open sky from the receiver plane")
		print("MAGIC_GI_CPU_BAKE probes=%d visibility_bytes=%d elapsed_ms=%.3f up_mean=%.4f down_mean=%.4f" % [
			zero_volume.bake_data.probe_count(),
			zero_volume.bake_data.probe_count() * Data.VISIBILITY_TEXELS_PER_PROBE
			* Data.VISIBILITY_MOMENT_CHANNELS * 4,
			zero_bake_elapsed_ms, clear_up_moments.x, ground_hit_moments.x])
		var legacy_v5: Resource = zero_volume.bake_data.duplicate(true)
		legacy_v5.format_version = Data.MOMENT_FORMAT_VERSION
		legacy_v5.visibility_nodes.clear()
		legacy_v5.visibility_triangles.clear()
		zero_volume.bake_data = legacy_v5
		var upgraded: Resource = Baker.new().upgrade_visibility_bake(zero_volume)
		_check(upgraded != null and upgraded.is_valid()
				and upgraded.transfer.to_byte_array() == legacy_v5.transfer.to_byte_array()
				and upgraded.primary_sky_visibility.to_byte_array() == legacy_v5.primary_sky_visibility.to_byte_array()
				and upgraded.emitter_transport.to_byte_array() == legacy_v5.emitter_transport.to_byte_array()
				and upgraded.visibility_moments.to_byte_array() == legacy_v5.visibility_moments.to_byte_array()
				and zero_volume.bake_data == legacy_v5,
				"matching v5 upgrades static blockers without recomputing transport or mutating its volume")
		legacy_v5.scene_signature += 1
		_check(Baker.new().upgrade_visibility_bake(zero_volume) == null,
				"v5 blocker upgrade refuses a mismatched geometry signature")
		legacy_v5.scene_signature -= 1
		zero_volume.bake_samples += 1
		_check(Baker.new().upgrade_visibility_bake(zero_volume) == null,
				"v5 blocker upgrade refuses changed bake settings")
		zero_volume.bake_samples -= 1
		zero_volume.refresh_surface_points()
		_check(zero_volume.bake_data != legacy_v5
				and zero_volume.bake_data.format_version == Data.FORMAT_VERSION
				and zero_volume.has_bake()
				and legacy_v5.format_version == Data.MOMENT_FORMAT_VERSION
				and legacy_v5.visibility_nodes.is_empty(),
				"scene refresh upgrades a matching v5 in memory while leaving its saved resource untouched")
	var primary_visibility_l1 := 0.0
	for coefficient in zero_volume.bake_data.primary_sky_visibility:
		primary_visibility_l1 += absf(coefficient)
	_check(_packed_values_all_zero(zero_volume.bake_data.transfer)
			and _packed_values_all_zero(zero_volume.bake_data.emitter_transport)
			and primary_visibility_l1 > 0.0
			and zero_volume.bake_data.has_nonzero_transfer()
			and zero_volume.has_nonzero_indirect_transfer(),
			"an isolated flat receiver stores no secondary/emitter transfer but preserves primary sky visibility")
	var zero_warnings: PackedStringArray = zero_volume._get_configuration_warnings()
	_check(not zero_warnings.has(Volume.ZERO_TRANSFER_DIAGNOSTIC),
			"a valid primary-visibility bake is not diagnosed as an all-zero bake")
	isolated_ground.queue_free()
	zero_volume.queue_free()
	await process_frame

	var boundary_volume := _new_uniform_test_volume()
	boundary_volume.size = Vector3.ONE * 2.0
	boundary_volume.probe_spacing = 1.0
	scene.add_child(boundary_volume)
	var min_face := MeshInstance3D.new()
	min_face.mesh = _make_horizontal_plane(2.0, 1, white, -1.0)
	scene.add_child(min_face)
	var max_face := MeshInstance3D.new()
	max_face.mesh = _make_horizontal_plane(2.0, 1, white, 1.0)
	scene.add_child(max_face)
	var inward_max_face := MeshInstance3D.new()
	inward_max_face.mesh = _make_horizontal_plane(2.0, 1, white, 1.0, true)
	scene.add_child(inward_max_face)
	var boundary_placement := Placement.new()
	_check(boundary_placement.collect(boundary_volume, false), "planes on volume Y faces collect successfully")
	_check(_surface_height_count(boundary_placement, boundary_volume, -1.0) > 0,
			"inward-offset plane on the exact minimum volume face is retained")
	_check(_surface_height_count(boundary_placement, boundary_volume, 1.0, Vector3.UP) == 0
			and boundary_placement.rejected_occluded_count > 0,
			"outward clearance from the exact maximum volume face is rejected before its center leaves the volume")
	_check(_surface_height_count(boundary_placement, boundary_volume, 1.0, Vector3.DOWN) > 0,
			"inward offset from the exact maximum face remains inside and is retained")
	print("MAGIC_GI_BOUNDARY_LAYOUT min_inward=%d max_outward=%d max_inward=%d center_outside_rejected=%d" % [
		_surface_height_count(boundary_placement, boundary_volume, -1.0, Vector3.UP),
		_surface_height_count(boundary_placement, boundary_volume, 1.0, Vector3.UP),
		_surface_height_count(boundary_placement, boundary_volume, 1.0, Vector3.DOWN),
		boundary_placement.rejected_center_outside_count])
	min_face.queue_free()
	max_face.queue_free()
	inward_max_face.queue_free()
	boundary_volume.queue_free()
	await process_frame

	var box_volume := _new_uniform_test_volume()
	box_volume.size = Vector3.ONE * 2.2
	box_volume.probe_spacing = 1.0
	scene.add_child(box_volume)
	var box_instance := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3.ONE * 2.0
	box_mesh.material = _make_material(Color.WHITE)
	box_instance.mesh = box_mesh
	scene.add_child(box_instance)
	var box_placement := Placement.new()
	_check(box_placement.collect(box_volume, false), "volume fitted to closed BoxMesh collects surfaces")
	_check(box_placement.positions.size() >= 6,
			"closed box retains at least one world-spaced probe for every face")
	for direction in [Vector3.LEFT, Vector3.RIGHT, Vector3.UP, Vector3.DOWN, Vector3.FORWARD, Vector3.BACK]:
		_check(_normal_count(box_placement, direction) > 0, "closed box retains face normal %s" % direction)
	var box_data := Data.new()
	box_data.format_version = Data.FORMAT_VERSION
	box_data.grid_dims = box_volume.grid_dimensions()
	box_data.volume_size = box_volume.size
	box_data.spacing = box_volume.probe_spacing
	box_data.surface_offset = box_volume.surface_offset
	box_data.volume_transform = box_volume.global_transform
	box_data.world_to_grid = box_volume.world_to_grid_transform()
	box_data.positions = box_placement.positions
	box_data.surface_positions = box_placement.surface_positions
	box_data.normals = box_placement.normals
	_check(box_data.build_cell_indices(), "closed box stays within the 8-slot cell capacity")
	box_volume.queue_free()
	box_instance.queue_free()
	await process_frame

	var embedded_volume := _new_uniform_test_volume()
	embedded_volume.size = Vector3(6.0, 4.0, 4.0)
	embedded_volume.probe_spacing = 1.0
	scene.add_child(embedded_volume)
	var solid_instance := MeshInstance3D.new()
	var solid_mesh := BoxMesh.new()
	solid_mesh.size = Vector3.ONE * 2.0
	solid_instance.mesh = solid_mesh
	scene.add_child(solid_instance)
	var embedded_plane := MeshInstance3D.new()
	embedded_plane.mesh = _make_horizontal_plane(1.0, 1, white)
	scene.add_child(embedded_plane)
	var transparent_material := _make_material(Color(1.0, 1.0, 1.0, 0.5))
	transparent_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var transparent_box := MeshInstance3D.new()
	var transparent_box_mesh := BoxMesh.new()
	transparent_box_mesh.size = Vector3.ONE * 0.8
	transparent_box_mesh.material = transparent_material
	transparent_box.mesh = transparent_box_mesh
	transparent_box.position.x = 2.4
	scene.add_child(transparent_box)
	var transparent_receiver := MeshInstance3D.new()
	transparent_receiver.mesh = _make_horizontal_plane(0.5, 1, white)
	transparent_receiver.position.x = 2.4
	scene.add_child(transparent_receiver)
	var embedded_placement := Placement.new()
	_check(embedded_placement.collect(embedded_volume, false),
			"closed-solid containment fixture collects successfully")
	_check(embedded_placement._occlusion_volumes.size() == 1,
			"watertight BoxMesh is registered for inside-volume rejection")
	_check(_surface_height_count(embedded_placement, embedded_volume, 0.0, Vector3.UP, 2.1, 2.7) > 0,
			"a transparent closed BoxMesh does not reject probes on an overlapping open receiver")
	_check(_surface_height_count(embedded_placement, embedded_volume, 0.0, Vector3.UP, -0.9, 0.9) == 0
			and embedded_placement.rejected_occluded_count > 0,
			"open plane probes wholly inside another BoxMesh are rejected when both offset endpoints are inside")
	_check(embedded_placement.positions.size() > 0
			and _normal_count(embedded_placement, Vector3.UP) > 0,
			"source BoxMesh keeps its own outward-offset probes while its solid interior rejects other sources")
	print("MAGIC_GI_EMBEDDED_LAYOUT retained=%d rejected_inside_or_crossing=%d" % [
		embedded_placement.positions.size(), embedded_placement.rejected_occluded_count])
	embedded_volume.queue_free()
	solid_instance.queue_free()
	embedded_plane.queue_free()
	transparent_box.queue_free()
	transparent_receiver.queue_free()
	await process_frame

	var thin_wall_volume := _new_uniform_test_volume()
	thin_wall_volume.size = Vector3.ONE * 2.2
	thin_wall_volume.probe_spacing = 1.0
	scene.add_child(thin_wall_volume)
	var thin_wall_left := MeshInstance3D.new()
	thin_wall_left.mesh = _make_horizontal_plane(4.0, 1, white)
	thin_wall_left.rotation.z = -PI * 0.5
	thin_wall_left.position.x = -0.03
	scene.add_child(thin_wall_left)
	var thin_wall_right := MeshInstance3D.new()
	thin_wall_right.mesh = _make_horizontal_plane(4.0, 1, white)
	thin_wall_right.rotation.z = PI * 0.5
	thin_wall_right.position.x = 0.03
	scene.add_child(thin_wall_right)
	var thin_wall_placement := Placement.new()
	_check(thin_wall_placement.collect(thin_wall_volume, false),
			"two thin opposing walls collect successfully")
	var thin_left_count := 0
	var thin_right_count := 0
	var thin_anchors_and_offsets_valid := true
	for index in thin_wall_placement.positions.size():
		var anchor: Vector3 = thin_wall_placement.surface_positions[index]
		var center: Vector3 = thin_wall_placement.positions[index]
		var normal: Vector3 = thin_wall_placement.normals[index]
		if anchor.x < -0.029 and normal.dot(Vector3.RIGHT) > 0.95:
			thin_left_count += 1
			thin_anchors_and_offsets_valid = thin_anchors_and_offsets_valid \
					and absf(anchor.x + 0.03) < 0.0001 and (center - anchor).dot(normal) > 0.0
		elif anchor.x > 0.029 and normal.dot(Vector3.LEFT) > 0.95:
			thin_right_count += 1
			thin_anchors_and_offsets_valid = thin_anchors_and_offsets_valid \
					and absf(anchor.x - 0.03) < 0.0001 and (center - anchor).dot(normal) > 0.0
	var thin_wall_spacing_violations := _world_spacing_violation_pair_count(
			thin_wall_placement.positions, thin_wall_volume.probe_spacing)
	_check(thin_left_count > 0 and thin_right_count > 0 and thin_anchors_and_offsets_valid
			and thin_wall_spacing_violations == 0
			and _world_max_occupancy(thin_wall_placement.positions,
			thin_wall_volume.probe_spacing) == 1,
			"opposing thin-wall faces retain safe coverage across available cells at world spacing")
	thin_wall_volume.bake_samples = 1
	thin_wall_volume.bake_bounces = 1
	thin_wall_volume.bake_distance = 2.0
	var thin_wall_baked: bool = await thin_wall_volume.bake()
	var thin_wall_first_hit_mean := INF
	if thin_wall_baked:
		for index in thin_wall_volume.bake_data.probe_count():
			if thin_wall_volume.bake_data.normals[index].dot(Vector3.RIGHT) > 0.95 \
					and thin_wall_volume.bake_data.surface_positions[index].x < -0.029:
				var moments: Vector2 = thin_wall_volume.bake_data.sample_visibility_moments(
						index, Vector3.RIGHT)
				thin_wall_first_hit_mean = minf(thin_wall_first_hit_mean, moments.x)
	_check(thin_wall_baked and thin_wall_first_hit_mean < 0.1,
		"a probe facing through the 6cm opposing wall pair stores its near first hit")
	print("MAGIC_GI_THIN_WALL_VISIBILITY baked=%s first_hit_mean=%.5f" % [
		thin_wall_baked, thin_wall_first_hit_mean])
	print("MAGIC_GI_THIN_WALL left=%d right=%d spacing_violations=%d adjusted=%d rejected_center_overlap=%d rejected_clearance=%d pruned=%d" % [
		thin_left_count, thin_right_count, thin_wall_spacing_violations,
		thin_wall_placement.adjusted_center_count,
		thin_wall_placement.rejected_center_overlap_count,
		thin_wall_placement.rejected_occluded_count,
		thin_wall_placement._bounded_candidate_pruned_count])
	thin_wall_volume.adaptive_placement = true
	var thin_wall_adaptive_placement := Placement.new()
	var thin_wall_adaptive_start_usec := Time.get_ticks_usec()
	var thin_wall_adaptive_collected: bool = thin_wall_adaptive_placement.collect(
			thin_wall_volume, false, false)
	var thin_wall_adaptive_ms := float(Time.get_ticks_usec() - thin_wall_adaptive_start_usec) / 1000.0
	_check(thin_wall_adaptive_collected,
			"adaptive opposing-wall candidate profile collects")
	_print_adaptive_profile("thin_wall", thin_wall_adaptive_placement, thin_wall_adaptive_ms)
	var adaptive_thin_left := 0
	var adaptive_thin_right := 0
	for index in thin_wall_adaptive_placement.positions.size():
		var anchor: Vector3 = thin_wall_adaptive_placement.surface_positions[index]
		var normal: Vector3 = thin_wall_adaptive_placement.normals[index]
		if anchor.x < -0.029 and normal.dot(Vector3.RIGHT) > 0.95:
			adaptive_thin_left += 1
		elif anchor.x > 0.029 and normal.dot(Vector3.LEFT) > 0.95:
			adaptive_thin_right += 1
	_check(adaptive_thin_left > 0 and adaptive_thin_right > 0
			and _adaptive_spacing_violation_pair_count(thin_wall_adaptive_placement) == 0,
			"adaptive refinement preserves valid probe coverage on both faces of the 6cm thin-wall pair")
	thin_wall_volume.queue_free()
	thin_wall_left.queue_free()
	thin_wall_right.queue_free()
	await process_frame

	var translated_root := Node3D.new()
	translated_root.position = Vector3(16384.0, -8192.0, 32768.0)
	translated_root.rotation = Vector3(0.23, -0.17, 0.31)
	translated_root.scale = Vector3(2.0, 0.5, 1.5)
	scene.add_child(translated_root)
	var translated_volume := _new_uniform_test_volume()
	translated_volume.size = Vector3.ONE * 4.0
	translated_volume.probe_spacing = 1.0
	translated_volume.surface_offset = 0.001
	translated_root.add_child(translated_volume)
	var nested_mesh := MeshInstance3D.new()
	nested_mesh.mesh = _make_nested_box_mesh(3.8, 1.0, white)
	nested_mesh.scale = Vector3(-0.8, 1.0, 0.9)
	nested_mesh.material_override = white
	translated_root.add_child(nested_mesh)
	var translated_placement := Placement.new()
	_check(translated_placement.collect(translated_volume, false),
			"translated nonuniformly-scaled nested closed mesh collects")
	var nested_solid: Dictionary = translated_placement._occlusion_volumes[0] if not translated_placement._occlusion_volumes.is_empty() else {}
	var inner_samples := 0
	var inner_normals_point_into_cavity := true
	var every_center_is_outside_solid := not nested_solid.is_empty()
	for index in translated_placement.positions.size():
		var local_anchor: Vector3 = nested_mesh.global_transform.affine_inverse() \
				* translated_placement.surface_positions[index]
		var local_normal: Vector3 = (nested_mesh.global_transform.basis.transposed() \
				* translated_placement.normals[index]).normalized()
		if _is_nested_inner_surface(local_anchor, 0.5):
			inner_samples += 1
			inner_normals_point_into_cavity = inner_normals_point_into_cavity \
					and _nested_normal_matches_cavity(local_anchor, local_normal, 0.5)
		if not nested_solid.is_empty() and nested_solid.world_aabb.grow(0.01).has_point(
				translated_placement.positions[index]):
			every_center_is_outside_solid = every_center_is_outside_solid \
					and translated_placement._point_inside_closed_mesh_state(
					translated_placement.positions[index], nested_solid.world_aabb,
						nested_solid.bvh, nested_solid.faces) == 0
	print("MAGIC_GI_NESTED_CLEARANCE probes=%d inner=%d canonical=%d fallback=%d staged=%d valid=%d foreign_rejections=%d owner_connection=%d owner_empty=%d owner_mismatch=%d raw_anchor_proof=%d center_clearance=%d no_offset=%d inside=%d outside=%d cell_competition=%d spacing_cells=%d warning=%s" % [
		translated_placement.positions.size(), inner_samples,
		translated_placement._canonical_candidate_count,
		translated_placement._fallback_candidate_count,
		translated_placement._staged_candidate_count,
		translated_placement._valid_candidate_count,
		translated_placement.rejected_foreign_surface_center_count,
		translated_placement.rejected_owner_connection_count,
		translated_placement.rejected_owner_connection_empty_count,
		translated_placement.rejected_owner_connection_mismatch_count,
		translated_placement.owner_connection_raw_anchor_count,
		translated_placement.rejected_center_clearance_count,
		translated_placement.rejected_no_safe_offset_count,
		translated_placement.rejected_inside_or_indeterminate_center_count,
		translated_placement.rejected_center_outside_count,
		translated_placement.rejected_world_cell_competition_count,
		translated_placement.rejected_center_overlap_count,
		translated_placement.warning_message])
	_check(inner_samples > 0 and inner_normals_point_into_cavity,
			"per-face containment orients reversed nested-shell probes toward the cavity")
	_check(every_center_is_outside_solid
			and nested_solid.world_aabb.position.x > 10000.0,
			"translated, nonuniformly-scaled placement centers stay outside their source solid")
	var minimum_adaptive_offset := INF
	for index in translated_placement.positions.size():
		minimum_adaptive_offset = minf(minimum_adaptive_offset,
			translated_placement.positions[index].distance_to(
				translated_placement.surface_positions[index]))
	_check(is_finite(minimum_adaptive_offset) and minimum_adaptive_offset >= 0.022,
			"placement retains spacing-relative clearance under translation and nonuniform scale")
	_check(_world_spacing_violation_pair_count(translated_placement.positions,
			translated_volume.probe_spacing) == 0,
			"world-space center spacing is independent of the parent nonuniform scale")
	print("MAGIC_GI_TRANSLATED_NESTED probes=%d inner=%d min_offset=%.5f" % [
		translated_placement.positions.size(), inner_samples,
		minimum_adaptive_offset if is_finite(minimum_adaptive_offset) else 0.0])
	translated_root.queue_free()
	await process_frame

	var layered_volume := _new_uniform_test_volume()
	layered_volume.size = Vector3(4.0, 2.0, 4.0)
	layered_volume.probe_spacing = 1.0
	scene.add_child(layered_volume)
	var lower_plane := MeshInstance3D.new()
	lower_plane.mesh = _make_horizontal_plane(2.2, 1, white, 0.0)
	scene.add_child(lower_plane)
	var upper_plane := MeshInstance3D.new()
	upper_plane.mesh = _make_horizontal_plane(2.2, 1, white, 0.1)
	scene.add_child(upper_plane)
	var layered_placement := Placement.new()
	_check(layered_placement.collect(layered_volume, false),
			"thickness-separated parallel surfaces collect successfully")
	_check(_surface_height_count(layered_placement, layered_volume, 0.0, Vector3.UP) > 0
			and _surface_height_count(layered_placement, layered_volume, 0.1, Vector3.UP) > 0,
			"nearby parallel source domains both get coverage when separate world cells permit it")
	var layered_spacing_violations := _world_spacing_violation_pair_count(
			layered_placement.positions, layered_volume.probe_spacing)
	_check(layered_spacing_violations == 0
			and _world_max_occupancy(layered_placement.positions, layered_volume.probe_spacing) == 1,
			"parallel surfaces share one global world-space density budget")
	print("MAGIC_GI_PARALLEL_LAYOUT lower=%d upper=%d duplicates=%d adjusted=%d spacing_violations=%d" % [
		_surface_height_count(layered_placement, layered_volume, 0.0, Vector3.UP),
		_surface_height_count(layered_placement, layered_volume, 0.1, Vector3.UP),
		layered_placement.rejected_duplicate_count,
		layered_placement.adjusted_center_count, layered_spacing_violations])
	layered_volume.queue_free()
	lower_plane.queue_free()
	upper_plane.queue_free()
	await process_frame

	var coplanar_volume := _new_uniform_test_volume()
	coplanar_volume.size = Vector3(4.0, 2.0, 4.0)
	coplanar_volume.probe_spacing = 1.0
	scene.add_child(coplanar_volume)
	var coplanar_a := MeshInstance3D.new()
	coplanar_a.mesh = _make_horizontal_plane(0.8, 1, white, 0.0)
	scene.add_child(coplanar_a)
	var coplanar_b := MeshInstance3D.new()
	coplanar_b.mesh = _make_horizontal_plane(0.8, 1, white, 0.0)
	scene.add_child(coplanar_b)
	var coplanar_placement := Placement.new()
	_check(coplanar_placement.collect(coplanar_volume, false),
			"coincident source surfaces collect successfully")
	print("MAGIC_GI_COPLANAR_CLEARANCE probes=%d canonical=%d fallback=%d staged=%d valid=%d foreign_rejections=%d owner_connection=%d owner_empty=%d owner_mismatch=%d raw_anchor_proof=%d center_clearance=%d cell_competition=%d spacing_cells=%d warning=%s" % [
		coplanar_placement.positions.size(),
		coplanar_placement._canonical_candidate_count,
		coplanar_placement._fallback_candidate_count,
		coplanar_placement._staged_candidate_count,
		coplanar_placement._valid_candidate_count,
		coplanar_placement.rejected_foreign_surface_center_count,
		coplanar_placement.rejected_owner_connection_count,
		coplanar_placement.rejected_owner_connection_empty_count,
		coplanar_placement.rejected_owner_connection_mismatch_count,
		coplanar_placement.owner_connection_raw_anchor_count,
		coplanar_placement.rejected_center_clearance_count,
		coplanar_placement.rejected_world_cell_competition_count,
		coplanar_placement.rejected_center_overlap_count,
		coplanar_placement.warning_message])
	for face_index in coplanar_placement.faces.size() / 3:
		var face_start := face_index * 3
		var face_a: Vector3 = coplanar_placement.faces[face_start]
		var face_b: Vector3 = coplanar_placement.faces[face_start + 1]
		var face_c: Vector3 = coplanar_placement.faces[face_start + 2]
		var face_normal := (face_c - face_a).cross(face_b - face_a).normalized()
		var face_surface := (face_a + face_b + face_c) / 3.0
		var face_center := face_surface + face_normal * 0.03
		var ray_epsilon := 0.003
		var face_hit: Dictionary = coplanar_placement.bvh.intersect_segment(
				face_center - face_normal * ray_epsilon,
				face_surface - face_normal * ray_epsilon)
		var hit_face := int(face_hit.get("face_index", -1))
		print("MAGIC_GI_COPLANAR_FACE index=%d hit=%d same=%s clear=%s normal=%s" % [
			face_index, hit_face,
			str(coplanar_placement._face_is_same_coplanar_surface(
				hit_face, face_index, face_surface, face_normal)),
			str(coplanar_placement._center_has_foreign_surface_clearance(
				face_surface, face_normal, face_center, face_index)), str(face_normal)])
	_check(_surface_height_count(coplanar_placement, coplanar_volume, 0.0, Vector3.UP) > 0
			and _world_max_occupancy(coplanar_placement.positions,
			coplanar_volume.probe_spacing) == 1
			and _world_spacing_violation_pair_count(coplanar_placement.positions,
			coplanar_volume.probe_spacing) == 0
			and coplanar_placement.rejected_world_cell_competition_count > 0
			and coplanar_placement.warning_message.is_empty(),
			"coplanar objects share one bounded world-space probe set without duplicate centers")
	coplanar_volume.queue_free()
	coplanar_a.queue_free()
	coplanar_b.queue_free()
	await process_frame

	var curved_volume := _new_uniform_test_volume()
	curved_volume.size = Vector3(6.0, 4.0, 6.0)
	curved_volume.probe_spacing = 1.0
	scene.add_child(curved_volume)
	var curved_material := _make_material(Color.WHITE)
	var sphere_instance := MeshInstance3D.new()
	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = 0.9
	sphere_mesh.height = 1.8
	sphere_mesh.radial_segments = 16
	sphere_mesh.rings = 8
	sphere_mesh.material = curved_material
	sphere_instance.mesh = sphere_mesh
	sphere_instance.position = Vector3(-1.4, 0.0, 0.0)
	scene.add_child(sphere_instance)
	var cone_instance := MeshInstance3D.new()
	var cone_mesh := CylinderMesh.new()
	cone_mesh.top_radius = 0.0
	cone_mesh.bottom_radius = 0.7
	cone_mesh.height = 1.6
	cone_mesh.radial_segments = 12
	cone_mesh.rings = 1
	cone_mesh.material = curved_material
	cone_instance.mesh = cone_mesh
	cone_instance.position = Vector3(1.4, -0.1, 0.0)
	scene.add_child(cone_instance)
	var curved_placement := Placement.new()
	var curved_collected: bool = curved_placement.collect(curved_volume, false)
	var sphere_samples := 0
	var cone_samples := 0
	for anchor in curved_placement.surface_positions:
		if anchor.x < 0.0:
			sphere_samples += 1
		else:
			cone_samples += 1
	print("CURVED_PLACEMENT collected=%s error=%s probes=%d duplicates=%d rejected=%d cells=%d" % [
		curved_collected, curved_placement.error_message, curved_placement.positions.size(),
		curved_placement.rejected_duplicate_count, curved_placement.rejected_occluded_count,
		curved_placement._cell_counts.size()])
	print("MAGIC_GI_CURVED_LAYOUT sphere=%d cone=%d" % [sphere_samples, cone_samples])
	_check(curved_collected, "1m sphere and cone placement fits the 8-slot grid")
	_check(sphere_samples > 0 and cone_samples > 0
			and _max_cell_load(curved_placement) <= Data.CELL_CAPACITY,
			"the sphere and cone both retain samples under the shared world density")
	# TriangleMesh.get_faces() snaps generated PrimitiveMesh vertices to 1e-4.
	# A geometrically identical ArrayMesh made from those canonical faces must
	# therefore produce the same persisted inputs and legacy scene signature.
	var primitive_faces: PackedVector3Array = curved_placement.faces.duplicate()
	var primitive_reflectance: PackedVector3Array = curved_placement.reflectance.duplicate()
	var primitive_positions: PackedVector3Array = curved_placement.positions.duplicate()
	var primitive_normals: PackedVector3Array = curved_placement.normals.duplicate()
	var primitive_signature: int = curved_placement.scene_signature
	var equivalent_mesh := _make_array_mesh_from_faces(sphere_mesh.get_faces(), curved_material)
	sphere_instance.mesh = equivalent_mesh
	var equivalent_placement := Placement.new()
	var equivalent_collected: bool = equivalent_placement.collect(curved_volume, false)
	_check(equivalent_collected, "canonical-face ArrayMesh collects beside the same curved scene")
	_check(equivalent_placement.faces == primitive_faces,
			"PrimitiveMesh and canonical-face ArrayMesh preserve identical collector face positions")
	_check(equivalent_placement.reflectance == primitive_reflectance,
			"PrimitiveMesh and canonical-face ArrayMesh preserve identical per-face reflectance")
	_check(equivalent_placement.positions == primitive_positions
			and equivalent_placement.normals == primitive_normals,
			"PrimitiveMesh and canonical-face ArrayMesh preserve probe positions and normals")
	_check(equivalent_placement.scene_signature == primitive_signature,
			"PrimitiveMesh and canonical-face ArrayMesh preserve the exact persisted geometry signature")
	print("PRIMITIVE_MESH_COMPAT faces=%d probes=%d signature=%d equivalent_signature=%d" % [
		primitive_faces.size(), primitive_positions.size(), primitive_signature,
		equivalent_placement.scene_signature])
	curved_volume.adaptive_placement = true
	var adaptive_curved_placement := Placement.new()
	var adaptive_curved_start_usec := Time.get_ticks_usec()
	var adaptive_curved_collected: bool = adaptive_curved_placement.collect(
			curved_volume, false, false)
	var adaptive_curved_ms := float(Time.get_ticks_usec() - adaptive_curved_start_usec) / 1000.0
	var adaptive_sphere_samples := 0
	var adaptive_cone_samples := 0
	for anchor in adaptive_curved_placement.surface_positions:
		if anchor.x < 0.0:
			adaptive_sphere_samples += 1
		else:
			adaptive_cone_samples += 1
	_print_adaptive_profile("sphere_cone", adaptive_curved_placement, adaptive_curved_ms)
	_check(adaptive_curved_collected and adaptive_sphere_samples > 0
			and adaptive_cone_samples > 0
			and adaptive_curved_placement.probe_spacings.size() \
				== adaptive_curved_placement.positions.size()
			and _adaptive_spacing_violation_pair_count(adaptive_curved_placement) == 0,
			"adaptive feature refinement retains curved sphere and cone coverage with valid local spacing")
	curved_volume.queue_free()
	sphere_instance.queue_free()
	cone_instance.queue_free()
	await process_frame

	if ResourceLoader.exists("res://scenes/cornell_box.tscn"):
		var cornell_scene := (load("res://scenes/cornell_box.tscn") as PackedScene).instantiate()
		root.add_child(cornell_scene)
		await process_frame
		var cornell_volume: Node3D = cornell_scene.get_node("FMagicGIVolume")
		var cornell_placement := Placement.new()
		var cornell_collect_start_usec := Time.get_ticks_usec()
		var cornell_collected: bool = cornell_placement.collect(cornell_volume, true, false)
		var cornell_collect_ms := float(Time.get_ticks_usec() - cornell_collect_start_usec) / 1000.0
		var cornell_repeat_placement := Placement.new()
		var cornell_repeat_collected: bool = cornell_repeat_placement.collect(
				cornell_volume, true, false)
		var cornell_repeat_positions_match := cornell_placement.positions.to_byte_array() \
				== cornell_repeat_placement.positions.to_byte_array()
		var cornell_repeat_anchors_match := cornell_placement.surface_positions.to_byte_array() \
				== cornell_repeat_placement.surface_positions.to_byte_array()
		var cornell_repeat_normals_match := cornell_placement.normals.to_byte_array() \
				== cornell_repeat_placement.normals.to_byte_array()
		print("MAGIC_GI_CORNELL_REPEAT count_a=%d count_b=%d positions=%s anchors=%s normals=%s signature=%s" % [
			cornell_placement.positions.size(), cornell_repeat_placement.positions.size(),
			str(cornell_repeat_positions_match), str(cornell_repeat_anchors_match),
			str(cornell_repeat_normals_match),
			str(cornell_placement.scene_signature == cornell_repeat_placement.scene_signature)])
		_check(cornell_collected and cornell_repeat_collected
				and cornell_placement.positions.size() == cornell_repeat_placement.positions.size()
				and cornell_repeat_positions_match and cornell_repeat_anchors_match
				and cornell_repeat_normals_match
				and cornell_placement.scene_signature == cornell_repeat_placement.scene_signature,
				"unchanged Cornell geometry collects the same ordered probe layout and signature")
		var cornell_axis_counts := PackedInt32Array()
		for direction in [Vector3.LEFT, Vector3.RIGHT, Vector3.UP, Vector3.DOWN,
				Vector3.FORWARD, Vector3.BACK]:
			cornell_axis_counts.append(_normal_count(cornell_placement, direction))
		var all_cornell_axes_covered := true
		for axis_count in cornell_axis_counts:
			all_cornell_axes_covered = all_cornell_axes_covered and axis_count > 0
		print("MAGIC_GI_CORNELL_AXES left=%d right=%d up=%d down=%d forward=%d back=%d" % [
			cornell_axis_counts[0], cornell_axis_counts[1], cornell_axis_counts[2],
			cornell_axis_counts[3], cornell_axis_counts[4], cornell_axis_counts[5]])
		_check(cornell_collected and cornell_placement.positions.size() >= 100
				and all_cornell_axes_covered,
				"full Cornell room and props retain one-meter-spaced samples across all six axes")
		var cornell_spacing_violations := _adaptive_spacing_violation_pair_count(
				cornell_placement) if cornell_volume.get("adaptive_placement") \
				else _world_spacing_violation_pair_count(cornell_placement.positions,
				cornell_volume.probe_spacing)
		var cornell_lookup_valid := cornell_placement.probe_spacings.size() \
				== cornell_placement.positions.size() if cornell_volume.get("adaptive_placement") \
				else _max_cell_load(cornell_placement) <= Data.CELL_CAPACITY
		_check(cornell_lookup_valid,
				"Cornell layout uses the sparse adaptive index or respects the uniform eight-slot limit")
		var cornell_data: Resource = cornell_volume.get("bake_data")
		var old_probe_positions: PackedVector3Array = cornell_data.get("positions") \
				if cornell_data != null else PackedVector3Array()
		var old_probe_bytes := old_probe_positions.to_byte_array()
		var old_surface_positions: PackedVector3Array = cornell_data.get("surface_positions") \
				if cornell_data != null else PackedVector3Array()
		var old_normal_values: PackedVector3Array = cornell_data.get("normals") \
				if cornell_data != null else PackedVector3Array()
		var old_data_signature := int(cornell_data.get("scene_signature")) \
				if cornell_data != null else 0
		var new_data_signature := Baker.signature_for_geometry(cornell_placement.scene_signature)
		var center_layout_changed := old_probe_bytes != cornell_placement.positions.to_byte_array() \
				or old_surface_positions.to_byte_array() != cornell_placement.surface_positions.to_byte_array() \
				or old_normal_values.to_byte_array() != cornell_placement.normals.to_byte_array()
		var old_world_occupancy := _world_max_occupancy(old_probe_positions,
				cornell_volume.probe_spacing)
		var new_world_occupancy := _world_max_occupancy(cornell_placement.positions,
				cornell_volume.probe_spacing)
		var new_spacing_violations := cornell_spacing_violations
		print("MAGIC_GI_CORNELL_LAYOUT adaptive=%s collect_ms=%.3f old_probes=%d coarse_candidates=%d fine_candidates=%d raw_candidates=%d staged_candidates=%d selected=%d staged_pruned=%d feature_cells=%d cell_visits=%d old_max_world_cell=%d old_occupied_cells=%d new_probes=%d new_max_world_cell=%d min_spacing=%.6f spacing_violations=%d world_cell_competition=%d rejected_spacing_cells=%d rejected_clearance=%d rejected_inside=%d rejected_outside=%d rejected_lookup=%d ambiguous=%d" % [
			str(cornell_volume.get("adaptive_placement")),
			cornell_collect_ms,
		old_probe_positions.size(),
			cornell_placement._coarse_valid_candidate_count,
			cornell_placement._refined_valid_candidate_count,
			cornell_placement._valid_candidate_count,
			cornell_placement._staged_candidate_count,
			cornell_placement.positions.size(),
			cornell_placement._bounded_candidate_pruned_count,
			cornell_placement._refinement_cell_count,
			cornell_placement._refinement_cell_visit_count,
		old_world_occupancy,
			_world_cell_counts(old_probe_positions, cornell_volume.probe_spacing).size(),
			cornell_placement.positions.size(), new_world_occupancy,
			_minimum_world_spacing(cornell_placement.positions), new_spacing_violations,
			cornell_placement.rejected_world_cell_competition_count,
			cornell_placement.rejected_center_overlap_count,
			cornell_placement.rejected_no_safe_offset_count,
			cornell_placement.rejected_inside_or_indeterminate_center_count,
			cornell_placement.rejected_center_outside_count,
			cornell_placement.rejected_lookup_capacity_count,
			cornell_placement.rejected_ambiguous_side_count])
		_check((bool(cornell_volume.get("adaptive_placement")) or new_world_occupancy <= 1)
				and new_spacing_violations == 0,
				"collected Cornell layout honors its per-probe adaptive spacing or uniform world-cell spacing")
		var old_bake_is_stale := not bool(cornell_volume.call("has_bake"))
		_check(cornell_data != null and cornell_data.call("is_valid")
				and old_probe_bytes == old_probe_positions.to_byte_array()
				and ((center_layout_changed and old_bake_is_stale
					and old_data_signature != new_data_signature)
					or (not center_layout_changed and not old_bake_is_stale
					and old_data_signature == new_data_signature)),
				"saved Cornell data remains valid and unchanged; a changed center layout is recognized as stale")
		var cornell_rebaked := false
		var original_cornell_samples := int(cornell_volume.get("bake_samples"))
		var protocol_cornell_samples := mini(original_cornell_samples, 64)
		if cornell_collected:
			cornell_volume.set("bake_samples", protocol_cornell_samples)
			cornell_rebaked = await cornell_volume.call("bake")
		var rebaked_cornell_data: Resource = cornell_volume.get("bake_data")
		var rebaked_positions: PackedVector3Array = rebaked_cornell_data.get("positions") \
				if rebaked_cornell_data != null else PackedVector3Array()
		_check(cornell_rebaked and rebaked_cornell_data != null
				and rebaked_cornell_data.call("is_valid")
				and rebaked_cornell_data.get("bake_samples") == protocol_cornell_samples
				and rebaked_cornell_data.get("scene_signature")
				== new_data_signature
				and rebaked_positions.to_byte_array() == cornell_placement.positions.to_byte_array()
				and cornell_volume.call("has_bake"),
				"low-sample Temp Cornell rebake stores current centers under the matching signature")
		_check(cornell_data != null and cornell_data.call("is_valid")
				and old_probe_bytes == cornell_data.get("positions").to_byte_array()
				and old_surface_positions.to_byte_array()
				== cornell_data.get("surface_positions").to_byte_array()
				and old_normal_values.to_byte_array() == cornell_data.get("normals").to_byte_array(),
				"rebaking the Temp scene does not mutate the saved resource instance")
		_check(rebaked_cornell_data != null and rebaked_cornell_data.call("has_nonzero_transfer"),
				"rebaked Cornell bake contains real nonzero indirect transport")
		if cornell_collected:
			cornell_volume.set("bake_samples", original_cornell_samples)
		cornell_scene.queue_free()
		await process_frame

	var volume := _new_uniform_test_volume()
	volume.size = Vector3(4.0, 4.0, 4.0)
	volume.probe_spacing = 1.0
	volume.surface_offset = 0.03
	volume.bake_samples = 512
	volume.bake_bounces = 1
	volume.bake_distance = 5.0
	volume.fallback_material_reflectance = 0.0
	volume.lighting_environment = Environment.new()
	volume.lighting_environment.background_mode = Environment.BG_CAMERA_FEED
	scene.add_child(volume)
	var ground := MeshInstance3D.new()
	ground.mesh = _make_horizontal_plane(4.0, 1, _make_material(Color.WHITE))
	scene.add_child(ground)
	var red_wall := MeshInstance3D.new()
	red_wall.mesh = _make_red_wall(4.0, 3.0, _make_material(Color.RED))
	scene.add_child(red_wall)
	var sun := DirectionalLight3D.new()
	sun.light_color = Color.RED
	sun.light_energy = 1.0
	sun.light_indirect_energy = 1.0
	volume.sun = sun
	scene.add_child(sun)
	await process_frame
	var actual_placement := Placement.new()
	_check(actual_placement.collect(volume, true, false), "red wall scene placement collection succeeds")
	var has_ground_normal := _normal_count(actual_placement, Vector3.UP) > 0
	var has_wall_normal := _normal_count(actual_placement, Vector3.LEFT) > 0
	_check(has_ground_normal and has_wall_normal, "ground and red wall samples retain distinct normals")
	var empty_volume := _new_uniform_test_volume()
	empty_volume.position = Vector3(100.0, 0.0, 0.0)
	empty_volume.size = Vector3.ONE * 2.0
	scene.add_child(empty_volume)
	var empty_placement := Placement.new()
	_check(empty_placement.collect(empty_volume, true, false) and empty_placement.positions.is_empty(),
			"empty volume creates no probes in air")

	var baked := await volume.bake()
	_check(baked, "real PRT bake completes with one geometry bounce")
	var data: Resource = volume.bake_data
	if not baked:
		quit(1)
		return
	_check(data.format_version == Data.FORMAT_VERSION and data.is_valid(), "baked resource validates as current PRT")
	_check(data.scene_signature == Baker.signature_for_geometry(actual_placement.scene_signature),
			"bake signature records the current sampler revision without changing the data contract")
	_check(data.bake_samples == volume.bake_samples, "bake stores the actual selected ray count")
	_check(data.has_nonzero_transfer() and volume.has_nonzero_indirect_transfer(),
			"a red wall creates nonzero indirect transport and clears the zero-transfer diagnostic")
	var old_sampler_data: Resource = data.duplicate(true)
	old_sampler_data.scene_signature = actual_placement.scene_signature
	volume.bake_data = old_sampler_data
	volume.refresh_surface_points()
	_check(old_sampler_data.is_valid() and not volume.has_bake(),
			"an old random-sampler format-2 bake remains loadable but is rejected as current")
	var old_sampler_warnings: PackedStringArray = volume._get_configuration_warnings()
	_check(_warnings_contain(old_sampler_warnings, "previous random sampler"),
			"old sampler bake exposes an explicit re-bake warning")
	volume.bake_data = data
	volume.refresh_surface_points()
	_check(volume.has_bake(), "restoring the revision-matched bake makes it current")
	old_sampler_data = null
	var signature_before_quality_change: int = volume._current_scene_signature
	volume.bake_samples = 1024
	var quality_warnings: PackedStringArray = volume._get_configuration_warnings()
	_check(not volume.has_bake() and data.bake_samples == 512
			and _warnings_contain(quality_warnings, "selected quality requests 1024")
			and volume._scene_signature_checked
			and volume._current_scene_signature == signature_before_quality_change,
			"changing quality marks old data stale without rewriting its baked sample count")
	Runtime.publish(volume)
	var preview_owns_diffuse := false
	for snapshot in Runtime.snapshots():
		if snapshot.volume_id == volume.get_instance_id():
			preview_owns_diffuse = bool(snapshot.replacement_enabled)
	_check(preview_owns_diffuse, "stale v6 preview replaces SkyLight instead of adding unoccluded ambient light")
	volume.bake_samples = 512
	_check(volume.has_bake(), "restoring the matching quality accepts the existing bake again")
	var receiver := _find_probe(data, Vector3(0.0, 0.0, 0.0), Vector3.UP)
	_check(receiver >= 0, "receiver ground probe is available")
	var before_transfer := PackedFloat32Array(data.transfer)
	var lighting := Lighting.new()
	sun.look_at(-Vector3(-0.8, 0.6, 0.0), Vector3.UP)
	sun.light_color = Color.RED
	var red_sh := lighting.coefficients(volume)
	var red_output: Vector3 = data.evaluate(receiver, red_sh) if receiver >= 0 else Vector3.ZERO
	sun.light_color = Color.GREEN
	var green_sh := lighting.coefficients(volume)
	var green_output: Vector3 = data.evaluate(receiver, green_sh) if receiver >= 0 else Vector3.ZERO
	_check(red_output.x > 0.000001, "red wall bounce contributes red under red directional light")
	_check(green_output.y < 0.00001, "red wall transport remains red when directional light turns green")
	_check(data.transfer.to_byte_array() == before_transfer.to_byte_array(),
			"dynamic sunlight color changes lighting SH without modifying baked transfer")
	volume.show_sh_probes = true
	var transport_viz: Node3D = FMagicGIViz.build(volume, Runtime.preview_snapshot(volume))
	_check(transport_viz.get_node_or_null("_Transport") != null,
			"editor transport visualization builds from the world-space SH data")
	transport_viz.free()
	volume.show_sh_probes = false

	var snapshots: Array = Runtime.snapshots()
	var snapshot_found := false
	for snapshot in snapshots:
		if snapshot.get("volume_id", 0) == volume.get_instance_id():
			snapshot_found = true
			for field in ["data", "version", "cache_key", "strength", "lighting", "world_id", "volume_id", "render_targets"]:
				_check(snapshot.has(field), "runtime snapshot contains %s" % field)
	_check(snapshot_found, "runtime publishes baked volume snapshot")

	var save_path := "user://magic_gi_prt_%d.tres" % Time.get_ticks_usec()
	var save_error := ResourceSaver.save(data, save_path)
	_check(save_error == OK, "baked PRT resource saves")
	var loaded: Resource = ResourceLoader.load(save_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	_check(loaded != null and loaded.is_valid() and loaded.scene_signature == data.scene_signature,
			"saved/reloaded PRT keeps valid scene signature")

	var persistent_signature: int = data.scene_signature
	scene.queue_free()
	await process_frame
	var scene_copy := Node3D.new()
	root.add_child(scene_copy)
	var clone_ground := MeshInstance3D.new()
	clone_ground.mesh = _make_horizontal_plane(4.0, 1, _make_material(Color.WHITE))
	scene_copy.add_child(clone_ground)
	var clone_wall := MeshInstance3D.new()
	var clone_wall_material := _make_material(Color.RED)
	clone_wall.mesh = _make_red_wall(4.0, 3.0, clone_wall_material)
	scene_copy.add_child(clone_wall)
	var clone_volume := _new_uniform_test_volume()
	clone_volume.size = loaded.volume_size
	clone_volume.probe_spacing = loaded.spacing
	clone_volume.surface_offset = loaded.surface_offset
	clone_volume.bake_samples = loaded.bake_samples
	clone_volume.bake_bounces = loaded.bake_bounces
	clone_volume.bake_distance = loaded.bake_distance
	clone_volume.fallback_material_reflectance = loaded.material_reflectance
	clone_volume.terrain_reflectance = loaded.terrain_reflectance
	clone_volume.lighting_environment = Environment.new()
	clone_volume.lighting_environment.background_mode = Environment.BG_CAMERA_FEED
	scene_copy.add_child(clone_volume)
	clone_volume.bake_data = loaded
	await process_frame
	var clone_has_bake := clone_volume.has_bake()
	var clone_placement := Placement.new()
	var clone_collected: bool = clone_placement.collect(clone_volume, false, false)
	_check(clone_collected
			and clone_placement.positions.to_byte_array() == loaded.positions.to_byte_array()
			and clone_placement.surface_positions.to_byte_array() == loaded.surface_positions.to_byte_array()
			and clone_placement.normals == loaded.normals,
			"equivalent re-instantiated geometry preserves the saved probe layout")
	_check(clone_has_bake
			and persistent_signature == Baker.signature_for_geometry(clone_volume._current_scene_signature),
			"equivalent re-instantiated scene accepts saved bake without process IDs")
	clone_wall_material.albedo_color = Color.BLUE
	clone_volume.refresh_surface_points()
	_check(not clone_volume.has_bake(), "material change invalidates baked scene signature")
	scene_copy.queue_free()
	await process_frame
	await _run_emission_bake_contracts()

	print("MAGIC_GI_PRT_RESULT failures=", _failures)
	quit(1 if _failures > 0 else 0)

func _test_pure_contracts() -> void:
	_check(InspectorPlugin != null, "inspector plugin parses with the PRT diagnostic")
	_test_runtime_atlas_positivity_filter()
	_test_emission_data_contracts()
	_test_directional_visibility_contracts()
	_check(Volume.BAKE_QUALITY_SAMPLES == [256, 1024, 2048],
			"Draft, Final, and High quality presets have explicit ray counts")
	var default_volume := Volume.new()
	_check(is_equal_approx(default_volume.probe_spacing, 1.0),
			"new Magic GI volumes default to one-meter probe spacing")
	_check(default_volume.adaptive_placement and default_volume.use_clv,
			"new Magic GI volumes enable adaptive placement and CLV independently")
	default_volume.adaptive_placement = false
	_check(not default_volume.adaptive_placement and default_volume.use_clv,
			"an explicit uniform-placement choice does not disable CLV")
	default_volume.probe_spacing = 2.0
	_check(is_equal_approx(default_volume.probe_spacing, 2.0),
			"probe spacing remains author-configurable after changing the default")
	_check(default_volume.bake_samples == 256, "existing numerical bake-sample default remains 256")
	default_volume.free()
	_check(Baker.signature_for_geometry(12345) == Baker.signature_for_geometry(12345)
			and Baker.signature_for_geometry(12345) != 12345,
			"sampler signature is persistent and distinguishes old raw geometry signatures")
	_test_qmc_variance()
	_test_trace_geometry_sampler_contracts()
	var max_cell: Vector3i = Data.cell_coordinates(Vector3(10.0, 10.0, 10.0), Vector3i(10, 10, 10))
	_check(max_cell == Vector3i(9, 9, 9), "exact positive volume face maps to final cell")
	var legacy := Data.new()
	_check(not legacy.is_valid(), "default/unbaked data remains invalid for the current PRT format")
	var image := Image.create(64, 32, false, Image.FORMAT_RGBAF)

	image.fill(Color.BLACK)
	image.set_pixel(12, 16, Color.WHITE)
	var sky_sh: PackedFloat32Array = Lighting.project_panorama(image)
	_check(sky_sh[9] < 0.0 and sky_sh[6] < 0.0,
			"asymmetric panorama projects with Godot's non-mirrored equirectangular axes")
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = Sky.new()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	var no_provider_scene := Node3D.new()
	root.add_child(no_provider_scene)
	var world_environment := WorldEnvironment.new()
	world_environment.environment = env
	no_provider_scene.add_child(world_environment)
	var no_provider_volume := _new_uniform_test_volume()
	no_provider_volume.lighting_environment = env
	no_provider_scene.add_child(no_provider_volume)
	var lighting := Lighting.new()
	var light_sets: Dictionary = lighting.coefficient_sets(no_provider_volume)
	_check(_packed_values_all_zero(light_sets.sky_lighting),
			"WorldEnvironment Sky is not an implicit Magic GI source without a ready FengSkyLight")
	_check(_packed_values_all_zero(light_sets.lighting),
			"no-provider SkyLight contributes zero to secondary lighting coefficients")
	no_provider_scene.free()
	var fake_data := FakeTerrainData.new()
	SceneTracker.watch_object(fake_data)
	var revision_before := SceneTracker.resource_revision(fake_data)
	fake_data.maps_changed.emit()
	fake_data.maps_edited.emit(AABB(Vector3.ZERO, Vector3.ONE))
	_check(SceneTracker.resource_revision(fake_data) == revision_before + 2,
			"Terrain3DData Object signals invalidate the lightweight scene fingerprint")
	fake_data.free()

func _test_trace_geometry_sampler_contracts() -> void:
	var faces := PackedVector3Array([
		Vector3(-1.0, -1.0, 0.0), Vector3(1.0, -1.0, 0.0),
		Vector3(0.0, 1.0, 0.0)])
	var bvh := TriangleMesh.new()
	var bvh_created: bool = bvh.create_from_faces(faces)
	_check(bvh_created, "geometry-only trace fixture builds a native triangle BVH")
	if not bvh_created:
		return
	var image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.25, 0.5, 0.75, 1.0))
	var material_sampler := MaterialSampler.new()
	material_sampler.records.append({
		"image": image,
		"scale": Vector3.ONE,
		"offset": Vector3.ZERO,
		"repeat": true,
		"filter": BaseMaterial3D.TEXTURE_FILTER_NEAREST
	})
	var counting_sampler := CountingMaterialSampler.new()
	counting_sampler.source = material_sampler
	var trace_scene := TraceScene.new()
	trace_scene.bvh = bvh
	trace_scene.faces = faces
	trace_scene.reflectance = PackedVector3Array([Vector3.ONE])
	trace_scene.face_materials = PackedInt32Array([0])
	trace_scene.face_emitter_indices = PackedInt32Array([-1])
	trace_scene.face_uv = PackedVector2Array([Vector2.ZERO, Vector2.ONE, Vector2(0.5, 1.0)])
	trace_scene.face_uv2 = PackedVector2Array([Vector2.ZERO, Vector2.ONE, Vector2(0.5, 1.0)])
	trace_scene.material_sampler = counting_sampler
	var placement := Placement.new()
	placement.bvh_ready = true
	placement.trace_scene = trace_scene
	var origin := Vector3(0.0, 0.0, 1.0)
	var direction := Vector3(0.0, 0.0, -1.0)
	var full_hit: Dictionary = placement.trace(origin, direction, 2.0)
	var full_sample_calls := counting_sampler.sample_calls
	counting_sampler.sample_calls = 0
	var geometry_hit: Dictionary = placement.trace_geometry(origin, direction, 2.0)
	_check(not full_hit.is_empty() and not geometry_hit.is_empty()
			and full_hit.face_index == geometry_hit.face_index
			and full_hit.position == geometry_hit.position
			and full_hit.normal == geometry_hit.normal,
			"geometry-only trace preserves the full query face, hit point, and face-forward normal")
	_check(full_hit.has("albedo") and not geometry_hit.has("albedo")
			and full_sample_calls == 1 and counting_sampler.sample_calls == 0,
			"geometry-only placement queries skip textured albedo sampling while full trace samples once")

func _test_adaptive_default_scene_compatibility() -> void:
	var omitted := _load_adaptive_compatibility_scene(false)
	var omitted_scene: PackedScene = omitted.get("packed")
	if omitted_scene == null:
		return
	var omitted_root := omitted_scene.instantiate()
	var omitted_volume := omitted_root.get_node("Volume") as Volume
	_check(omitted_volume != null and omitted_volume.adaptive_placement,
			"a scene with no serialized adaptive_placement loads with the new true default")
	_erase_adaptive_compatibility_scene(String(omitted["path"]))
	omitted_root.free()

	var explicit := _load_adaptive_compatibility_scene(true)
	var explicit_scene: PackedScene = explicit.get("packed")
	if explicit_scene == null:
		return
	var explicit_root := explicit_scene.instantiate()
	var explicit_volume := explicit_root.get_node("Volume") as Volume
	_check(explicit_volume != null and not explicit_volume.adaptive_placement,
			"a scene with adaptive_placement=false keeps its explicit choice")
	_erase_adaptive_compatibility_scene(String(explicit["path"]))
	explicit_root.free()

	var legacy_scene := Node3D.new()
	root.add_child(legacy_scene)
	var legacy_volume := Volume.new()
	legacy_volume.size = Vector3(2.0, 1.0, 1.0)
	var legacy_bake: Resource = _make_emission_contract_data()
	legacy_bake.adaptive_placement = false
	legacy_volume.bake_data = legacy_bake
	legacy_scene.add_child(legacy_volume)
	await process_frame
	await process_frame
	Runtime.publish(legacy_volume)
	var old_bake_published := false
	for snapshot in Runtime.snapshots():
		if int(snapshot.get("volume_id", 0)) == legacy_volume.get_instance_id():
			old_bake_published = snapshot.get("data") == legacy_bake \
					and bool(snapshot.get("replacement_enabled", false))
	_check(legacy_volume.adaptive_placement and legacy_volume.needs_rebake()
			and legacy_volume.has_usable_bake() and legacy_volume.bake_data == legacy_bake
			and legacy_bake.is_valid() and old_bake_published,
			"a valid uniform bake remains published and untouched while the default adaptive layout is stale")
	legacy_scene.queue_free()
	await process_frame

func _load_adaptive_compatibility_scene(explicit_false: bool) -> Dictionary:
	var path := "res://_adaptive_default_explicit_false.tscn" if explicit_false \
			else "res://_adaptive_default_omitted.tscn"
	var source := "[gd_scene load_steps=2 format=3]\n\n" \
			+ "[ext_resource type=\"Script\" path=\"res://addons/feng-magic-gi/feng_magic_gi_volume.gd\" id=\"1_volume\"]\n\n" \
			+ "[node name=\"Root\" type=\"Node3D\"]\n\n" \
			+ "[node name=\"Volume\" type=\"Node3D\" parent=\".\"]\n" \
			+ "script = ExtResource(\"1_volume\")\n"
	if explicit_false:
		source += "adaptive_placement = false\n"
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_check(false, "adaptive compatibility scene fixture can be written in the scratch project")
		return {"path": path, "packed": null}
	file.store_string(source)
	file.close()
	var packed := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	_check(packed != null, "adaptive compatibility scene fixture parses")
	return {"path": path, "packed": packed}

func _erase_adaptive_compatibility_scene(path: String) -> void:
	var absolute_path := ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(absolute_path):
		DirAccess.remove_absolute(absolute_path)

func _test_directional_visibility_contracts() -> void:
	_check(Data.fold_visibility_texel(Vector2i(-1, 3)) == Vector2i(0, 4)
			and Data.fold_visibility_texel(Vector2i(8, 3)) == Vector2i(7, 4)
			and Data.fold_visibility_texel(Vector2i(3, -1)) == Vector2i(4, 0)
			and Data.fold_visibility_texel(Vector2i(3, 8)) == Vector2i(4, 7),
			"octahedral texel borders fold with integer mirror-and-axis-flip addressing")
	var data: Resource = _make_filter_test_data()
	for y in Data.VISIBILITY_TILE_SIZE:
		for x in Data.VISIBILITY_TILE_SIZE:
			var uv := (Vector2(x, y) + Vector2(0.5, 0.5)) / float(Data.VISIBILITY_TILE_SIZE)
			var direction := Data.octahedral_decode(uv)
			var mean := 2.0 + direction.dot(Vector3(1.0, 0.5, -0.25).normalized()) * 0.4
			var base := (y * Data.VISIBILITY_TILE_SIZE + x) * Data.VISIBILITY_MOMENT_CHANNELS
			data.visibility_moments[base] = mean
			data.visibility_moments[base + 1] = mean * mean + 0.01
	var seam_positive: Vector2 = data.sample_visibility_moments(0, Vector3(-1.0, 0.00001, 0.0))
	var seam_negative: Vector2 = data.sample_visibility_moments(0, Vector3(-1.0, -0.00001, 0.0))
	_check(seam_positive.distance_to(seam_negative) < 0.0001,
			"directional moments stay continuous while sampling across an octahedral tile seam")
	_check(is_equal_approx(Data.one_sided_chebyshev_bound(2.0, 4.0, 1.0, 0.0001), 1.0)
			and Data.chebyshev_visibility(2.0, 4.0, 3.0, 0.0001) < 0.000001,
			"unblocked receiver distance preserves unit visibility and the shaped one-sided bound rejects blocked distance")

func _test_emission_data_contracts() -> void:
	var data: Resource = _make_emission_contract_data()
	_check(data.is_valid() and data.format_version == Data.FORMAT_VERSION,
			"synthetic v6 emitter bake validates with explicit anchors and visibility moments")
	_test_render_upload_package(data)
	for invalid in [NAN, INF]:
		var bad_transform: Resource = data.duplicate(true)
		bad_transform.volume_transform.origin.x = invalid
		_check(not bad_transform.is_valid(), "non-finite volume transforms remain invalid")
		var bad_grid: Resource = data.duplicate(true)
		bad_grid.world_to_grid.basis.x.y = invalid
		_check(not bad_grid.is_valid() and not bad_grid.build_cell_indices() and bad_grid.cell_indices.is_empty(),
				"non-finite lookup transforms fail validation and clear their index payload")
	_check(data.emitter_count() == 1 and data.has_nonzero_transfer(),
		"synthetic v6 data counts emitter transport as real indirect transport")
	var raw_transfer: PackedByteArray = data.transfer.to_byte_array()
	var raw_emitter_transport: PackedByteArray = data.emitter_transport.to_byte_array()
	var source_values := PackedFloat32Array([0.5, 0.25, 0.125, 1.0, 1.0, 1.0])
	var composed: PackedFloat32Array = data.compose_emission(source_values)
	_check(composed.size() == data.probe_count() * 3,
			"emitter sources compose into one RGB value per probe")
	if composed.size() == data.probe_count() * 3:
		_check(is_equal_approx(composed[0], 0.35)
				and is_equal_approx(composed[1], 0.10)
				and is_equal_approx(composed[2], 0.10),
				"source composition keeps uniform RGB and texture RGB as separate transport terms")
	_check(data.transfer.to_byte_array() == raw_transfer
			and data.emitter_transport.to_byte_array() == raw_emitter_transport,
			"runtime emission composition leaves both baked transport arrays immutable")
	var emission_atlas: Image = data.make_emission_atlas_image(composed)
	_check(emission_atlas != null and emission_atlas.get_width() == Data.ATLAS_COLUMNS
			and emission_atlas.get_height() == 1
			and emission_atlas.get_format() == Image.FORMAT_RGBAF,
			"emission payload packs as a 32-column RGBAF atlas")
	var empty_atlas: Image = data.make_emission_atlas_image(PackedFloat32Array())
	_check(empty_atlas != null and empty_atlas.get_width() == Data.ATLAS_COLUMNS
			and empty_atlas.get_pixel(0, 0).get_luminance() == 0.0,
			"an empty or legacy emission payload maps to a black atlas")

	var legacy_v2: Resource = _make_filter_test_data()
	legacy_v2.format_version = Data.LEGACY_FORMAT_VERSION
	legacy_v2.emitter_keys = PackedStringArray()
	legacy_v2.emitter_static_signatures = PackedInt64Array()
	legacy_v2.emitter_transport = PackedFloat32Array()
	legacy_v2.primary_sky_visibility = PackedFloat32Array()
	legacy_v2.surface_positions.clear()
	legacy_v2.visibility_moments.clear()
	legacy_v2.visibility_nodes.clear()
	legacy_v2.visibility_triangles.clear()
	_check(legacy_v2.is_valid() and legacy_v2.emitter_count() == 0,
			"legacy v2 surface-transport bakes remain valid without emitter arrays")
	var legacy_v3: Resource = data.duplicate(true)
	legacy_v3.format_version = Data.EMITTER_FORMAT_VERSION
	legacy_v3.primary_sky_visibility.clear()
	legacy_v3.surface_positions.clear()
	legacy_v3.visibility_moments.clear()
	legacy_v3.visibility_nodes.clear()
	legacy_v3.visibility_triangles.clear()
	_check(legacy_v3.is_valid() and legacy_v3.emitter_count() == 1,
			"legacy v3 emitter bakes remain valid without primary Sky visibility")
	var legacy_v4: Resource = data.duplicate(true)
	legacy_v4.format_version = Data.PRIMARY_SKY_FORMAT_VERSION
	legacy_v4.surface_positions.clear()
	legacy_v4.visibility_moments.clear()
	legacy_v4.visibility_nodes.clear()
	legacy_v4.visibility_triangles.clear()
	_check(legacy_v4.is_valid() and not legacy_v4.matches_layout(
			legacy_v4.volume_size, legacy_v4.spacing, legacy_v4.surface_offset,
			legacy_v4.volume_transform, legacy_v4.bake_samples, legacy_v4.bake_bounces,
			legacy_v4.bake_distance, legacy_v4.terrain_reflectance, legacy_v4.material_reflectance),
			"legacy v4 data remains loadable but cannot satisfy the v6 runtime layout")
	var legacy_v5: Resource = data.duplicate(true)
	legacy_v5.format_version = Data.MOMENT_FORMAT_VERSION
	legacy_v5.visibility_nodes.clear()
	legacy_v5.visibility_triangles.clear()
	_check(legacy_v5.is_valid(), "legacy v5 remains loadable with its original surface and moment payload")
	var preview_upload: Dictionary = legacy_v5.make_render_upload()
	_check(not preview_upload.is_empty() and preview_upload.visibility_node_bytes.size() == 32
			and preview_upload.visibility_triangle_bytes.size() == 48
			and legacy_v5.visibility_nodes.is_empty() and legacy_v5.visibility_triangles.is_empty(),
			"stale v5 keeps its moment-based preview using upload-only empty traversal buffers")
	for legacy_data in [legacy_v2, legacy_v3, legacy_v4]:
		var legacy_upload: Dictionary = legacy_data.make_render_upload()
		_check(legacy_upload.is_empty(), "legacy v2-v4 upload requires an explicit current-format rebake")
		_check(legacy_data.make_geometry_image() == null
				and legacy_data.make_visibility_moment_image() == null,
				"legacy v2-v4 data cannot enter a current geometry or visibility atlas packer")
	var primary_only: Resource = data.duplicate(true)
	primary_only.transfer.fill(0.0)
	primary_only.emitter_keys.clear()
	primary_only.emitter_static_signatures.clear()
	primary_only.emitter_transport.clear()
	primary_only.primary_sky_visibility.fill(0.0)
	primary_only.primary_sky_visibility[0] = 0.25
	var sky_only_lighting := PackedFloat32Array()
	sky_only_lighting.resize(27)
	sky_only_lighting.fill(0.0)
	sky_only_lighting[0] = 2.0
	sky_only_lighting[1] = 3.0
	sky_only_lighting[2] = 4.0
	var no_secondary_lighting := PackedFloat32Array()
	no_secondary_lighting.resize(27)
	no_secondary_lighting.fill(0.0)
	_check(primary_only.is_valid() and primary_only.has_nonzero_transfer()
			and primary_only.evaluate(0, no_secondary_lighting, sky_only_lighting).is_equal_approx(Vector3(0.5, 0.75, 1.0) / PI),
			"v6 primary Sky visibility remains valid transport and evaluates only against Sky-only SH")
	# A unit-radiance white sky gives PI irradiance and unit outgoing radiance
	# on a white Lambertian surface. This must match the cosine-sampled RT path.
	primary_only.primary_sky_visibility[0] = PI * 0.2820947918
	for channel in 3:
		sky_only_lighting[channel] = 1.0 / 0.2820947918
	_check(primary_only.evaluate(0, no_secondary_lighting, sky_only_lighting).is_equal_approx(Vector3.ONE),
			"constant white sky preserves unit diffuse radiance without a PI energy gain")
	var independent_clamp: Resource = primary_only.duplicate(true)
	independent_clamp.transfer.fill(0.0)
	independent_clamp.primary_sky_visibility.fill(0.0)
	independent_clamp.transfer[0] = -2.0
	independent_clamp.transfer[1] = 2.0
	independent_clamp.primary_sky_visibility[0] = PI * 3.0
	var mixed_secondary := PackedFloat32Array()
	mixed_secondary.resize(27)
	mixed_secondary.fill(0.0)
	mixed_secondary[0] = 1.0
	mixed_secondary[1] = 1.0
	var mixed_sky := PackedFloat32Array()
	mixed_sky.resize(27)
	mixed_sky.fill(0.0)
	mixed_sky[0] = 1.0
	mixed_sky[1] = -1.0
	_check(independent_clamp.evaluate(0, mixed_secondary, mixed_sky).is_equal_approx(Vector3(3.0, 2.0, 0.0)),
			"negative secondary and primary SH lobes do not cancel positive light from the other transport family")
	var bad_shape: Resource = data.duplicate(true)
	bad_shape.emitter_transport.resize(bad_shape.emitter_transport.size() - 1)
	_check(not bad_shape.is_valid(), "v6 rejects an emitter payload with the wrong probe shape")
	var bad_count: Resource = data.duplicate(true)
	bad_count.emitter_static_signatures.clear()
	_check(not bad_count.is_valid(), "v6 rejects mismatched emitter key/static-signature counts")
	var bad_negative: Resource = data.duplicate(true)
	bad_negative.emitter_transport[0] = -0.001
	_check(not bad_negative.is_valid(), "v6 rejects negative emitter transport")
	var bad_nan: Resource = data.duplicate(true)
	bad_nan.emitter_transport[0] = NAN
	_check(not bad_nan.is_valid(), "v6 rejects non-finite emitter transport")
	var bad_primary_shape: Resource = data.duplicate(true)
	bad_primary_shape.primary_sky_visibility.resize(bad_primary_shape.primary_sky_visibility.size() - 1)
	_check(not bad_primary_shape.is_valid(), "v6 rejects primary Sky visibility with the wrong probe shape")
	var unsupported: Resource = data.duplicate(true)
	unsupported.format_version = Data.FORMAT_VERSION + 1
	_check(not unsupported.is_valid(), "unsupported future PRT versions fail closed")
	_check(unsupported.make_render_upload().is_empty(),
			"an invalid bake rejects the complete render upload package without partial fields")

func _test_render_upload_package(data: Resource) -> void:
	var upload: Dictionary = data.make_render_upload()
	var expected_keys := ["transfer_image", "primary_sky_image", "geometry_image", "visibility_moment_image",
			"visibility_node_bytes", "visibility_triangle_bytes", "index_bytes", "emission_image", "sparse_indices", "index_entries"]
	var has_contract_fields := upload.size() == expected_keys.size()
	for key in expected_keys:
		has_contract_fields = has_contract_fields and upload.has(key)
	_check(has_contract_fields, "render upload returns the atomic transport and lookup package")
	if not has_contract_fields:
		return
	var transfer_image: Image = upload["transfer_image"]
	var primary_sky_image: Image = upload["primary_sky_image"]
	var geometry_image: Image = upload["geometry_image"]
	var visibility_image: Image = upload["visibility_moment_image"]
	var emission_image: Image = upload["emission_image"]
	var index_bytes: PackedByteArray = upload["index_bytes"]
	var expected_transfer: Image = data.make_runtime_atlas_image()
	var expected_geometry: Image = data.make_geometry_image()
	var expected_visibility: Image = data.make_visibility_moment_image()
	var expected_emission: Image = data.make_emission_atlas_image(PackedFloat32Array())
	_check(transfer_image != null and expected_transfer != null
			and transfer_image.get_data() == expected_transfer.get_data(),
			"atomic transfer image is byte-identical to the existing runtime packer")
	_check(primary_sky_image != null and primary_sky_image.get_width() == Data.ATLAS_COLUMNS * Data.PRIMARY_SKY_TEXELS_PER_POINT
			and is_equal_approx(primary_sky_image.get_pixel(0, 0).r, data.primary_sky_visibility[0]),
			"atomic upload includes the primary Sky visibility atlas")
	_check(geometry_image != null and expected_geometry != null
			and geometry_image.get_data() == expected_geometry.get_data(),
			"atomic geometry image is byte-identical to the existing geometry packer")
	_check(visibility_image != null and expected_visibility != null
			and visibility_image.get_data() == expected_visibility.get_data()
			and visibility_image.get_format() == Image.FORMAT_RGF,
			"atomic upload includes the two-channel directional visibility moment atlas")
	_check(index_bytes == data.make_index_bytes(),
			"atomic index bytes are byte-identical to the existing index packer")
	_check(upload.visibility_node_bytes == data.visibility_nodes.to_byte_array()
			and upload.visibility_triangle_bytes == data.visibility_triangles.to_byte_array(),
			"atomic upload includes the exact immutable static blocker buffers")
	_check(emission_image != null and expected_emission != null
			and emission_image.get_data() == expected_emission.get_data(),
			"atomic emission image matches the existing zero-emission atlas layout")
	var counting_data := ValidationCountingData.new()
	_make_emission_contract_data(counting_data)
	var counted_upload: Dictionary = counting_data.make_render_upload()
	_check(not counted_upload.is_empty() and counting_data.validation_count == 1,
			"render upload validates a bake exactly once before producing every resource")

func _run_emission_bake_contracts() -> void:
	var fixture := Node3D.new()
	fixture.name = "EmissionBakeFixture"
	root.add_child(fixture)
	var black := _make_material(Color.BLACK)
	var floor := _add_emission_fixture_plane(fixture, "Floor", 0.0, Vector3.ZERO, black)
	var ceiling := _add_emission_fixture_plane(fixture, "Ceiling", 3.0,
			Vector3(PI, 0.0, 0.0), black)
	var back_wall := _add_emission_fixture_plane(fixture, "BackWall", 0.0,
			Vector3(-PI * 0.5, 0.0, 0.0), black)
	back_wall.position = Vector3(0.0, 1.5, 1.5)
	var front_wall := _add_emission_fixture_plane(fixture, "FrontWall", 0.0,
			Vector3(PI * 0.5, 0.0, 0.0), black)
	front_wall.position = Vector3(0.0, 1.5, -1.5)
	var left_wall := _add_emission_fixture_plane(fixture, "LeftWall", 0.0,
			Vector3(0.0, 0.0, -PI * 0.5), black)
	left_wall.position = Vector3(-1.5, 1.5, 0.0)
	var right_wall := _add_emission_fixture_plane(fixture, "RightWall", 0.0,
			Vector3(0.0, 0.0, PI * 0.5), black)
	right_wall.position = Vector3(1.5, 1.5, 0.0)
	var divider := _add_emission_fixture_plane(fixture, "Occluder", 0.0,
			Vector3(0.0, 0.0, PI * 0.5), black)
	divider.position = Vector3(0.0, 1.5, 0.0)
	var emitter_material := _make_material(Color.BLACK)
	emitter_material.emission_enabled = true
	emitter_material.emission = Color.GREEN
	emitter_material.emission_energy_multiplier = 1.0
	if bool(ProjectSettings.get_setting("rendering/lights_and_shadows/use_physical_light_units", false)):
		emitter_material.emission_intensity = 1.0
	var emitter := MeshInstance3D.new()
	emitter.name = "EmitterPanel"
	emitter.mesh = _make_horizontal_plane(0.8, 1, emitter_material)
	emitter.rotation.x = PI
	emitter.position = Vector3(-0.75, 2.4, 0.4)
	fixture.add_child(emitter)
	var volume := _new_uniform_test_volume()
	volume.name = "FMagicGIVolume"
	volume.position = Vector3(0.0, 1.5, 0.0)
	volume.size = Vector3(4.0, 3.6, 4.0)
	# This physics fixture needs representative floor receivers on both sides of
	# its divider; use finer spacing than the one-meter layout contract fixture.
	volume.probe_spacing = 0.5
	volume.surface_offset = 0.03
	volume.bake_samples = 64
	volume.bake_bounces = 1
	volume.bake_distance = 6.0
	volume.fallback_material_reflectance = 0.0
	volume.show_probes = false
	fixture.add_child(volume)
	await process_frame
	volume.refresh_surface_points()
	var single_sided_ok: bool = await volume.bake()
	_check(single_sided_ok and volume.has_bake(),
			"closed black-room emitter fixture completes a valid CPU bake")
	if not single_sided_ok:
		fixture.queue_free()
		await process_frame
		return
	var single_data: Resource = volume.bake_data
	var stale_bake_state := {"done": false, "success": false}
	_capture_bake_result(volume, stale_bake_state)
	await process_frame
	volume.bake_samples = 65
	while not bool(stale_bake_state["done"]):
		await process_frame
	volume.bake_samples = 64
	_check(not bool(stale_bake_state["success"])
			and volume.bake_data == single_data and volume.has_bake(),
			"a bake whose request is invalidated after yielding is discarded without replacing the valid bake")
	var initial_transfer_bytes: PackedByteArray = single_data.transfer.to_byte_array()
	var initial_emitter_bytes: PackedByteArray = single_data.emitter_transport.to_byte_array()
	var initial_position_bytes: PackedByteArray = single_data.positions.to_byte_array()
	var initial_normal_bytes: PackedByteArray = single_data.normals.to_byte_array()
	var deterministic_rebake_ok: bool = await volume.bake()
	var deterministic_data: Resource = volume.bake_data
	_check(deterministic_rebake_ok and deterministic_data.is_valid()
			and deterministic_data.scene_signature == single_data.scene_signature
			and deterministic_data.positions.to_byte_array() == initial_position_bytes
			and deterministic_data.normals.to_byte_array() == initial_normal_bytes
			and deterministic_data.transfer.to_byte_array() == initial_transfer_bytes
			and deterministic_data.emitter_transport.to_byte_array() == initial_emitter_bytes
			and deterministic_data.emitter_keys == single_data.emitter_keys
			and deterministic_data.emitter_static_signatures == single_data.emitter_static_signatures,
			"repeating an unchanged small bake preserves exact geometry, signatures and raw transport")
	if deterministic_rebake_ok:
		single_data = deterministic_data
	_emit_architecture_bake_snapshot(volume, single_data)
	var far_field_l1 := 0.0
	for coefficient in single_data.transfer:
		far_field_l1 += absf(coefficient)
	var source_l1 := 0.0
	for coefficient in single_data.emitter_transport:
		source_l1 += absf(coefficient)
	var primary_sky_l1 := 0.0
	for coefficient in single_data.primary_sky_visibility:
		primary_sky_l1 += absf(coefficient)
	_check(single_data.is_valid() and single_data.emitter_count() == 1,
			"real bake persists one stable area-emitter binding")
	_check(far_field_l1 == 0.0 and source_l1 > 0.0 and single_data.has_nonzero_transfer(),
			"black room has zero secondary transfer but positive emissive transport (SH %.8f, emitter %.8f)" % [far_field_l1, source_l1])
	var floor_probe := _find_probe_in_surface_region(single_data,
			Vector3(-0.5, 0.0, 0.5), Vector3.UP, 0.0, -INF, -0.1, -1.0, 1.0)
	var occluded_probe := _find_probe_in_surface_region(single_data,
			Vector3(0.5, 0.0, 0.5), Vector3.UP, 0.0, 0.1, INF, -1.0, 1.0)
	var back_probe := _find_probe_in_surface_region(single_data,
			Vector3(-0.75, 3.0, 0.4), Vector3.DOWN, 3.0, -INF, INF)
	var floor_sky_l1 := _primary_sky_probe_l1(single_data, floor_probe)
	var occluded_sky_l1 := _primary_sky_probe_l1(single_data, occluded_probe)
	var back_sky_l1 := _primary_sky_probe_l1(single_data, back_probe)
	print("MAGIC_GI_ROOM_SKY spacing=%.2f total_l1=%.8f floor_probe=%d floor_l1=%.8f occluded_probe=%d occluded_l1=%.8f back_probe=%d back_l1=%.8f" % [
		single_data.spacing, primary_sky_l1, floor_probe, floor_sky_l1, occluded_probe,
		occluded_sky_l1, back_probe, back_sky_l1])
	_check(floor_probe >= 0 and occluded_probe >= 0 and back_probe >= 0
			and floor_sky_l1 == 0.0 and occluded_sky_l1 == 0.0 and back_sky_l1 == 0.0,
			"interior floor, occluded floor and back-side probes have no first-segment sky visibility")
	var single_floor_weight := _emitter_transport_term0(single_data, floor_probe)
	var single_occluded_weight := _emitter_transport_term0(single_data, occluded_probe)
	var single_back_weight := _emitter_transport_term0(single_data, back_probe)
	_check(floor_probe >= 0 and single_floor_weight > 0.0,
			"single-sided black-albedo panel directly transports energy to the visible floor (probe=%d, weight=%.8f)" % [floor_probe, single_floor_weight])
	_check(occluded_probe >= 0 and single_occluded_weight <= single_floor_weight * 0.01,
			"opaque divider blocks area-source transport to the opposite floor (visible %.8f, blocked %.8f)" % [single_floor_weight, single_occluded_weight])
	_check(back_probe >= 0 and single_back_weight <= single_floor_weight * 0.01,
			"single-sided downward panel does not illuminate its back-side ceiling probe (visible %.8f, back %.8f)" % [single_floor_weight, single_back_weight])
	var helper := Emission.new()
	var initial_values: PackedFloat32Array = helper.read_source_values(volume, single_data)
	_check(initial_values.size() == 6 and initial_values[0] == 0.0
			and is_equal_approx(initial_values[1], 1.0) and initial_values[2] == 0.0
			and initial_values[3] == 1.0 and initial_values[4] == 1.0 and initial_values[5] == 1.0,
			"ADD emitter reads live linear RGB and energy while static transport ignores source albedo")
	var initial_payload: PackedFloat32Array = single_data.compose_emission(initial_values)
	var doubled_version: int = single_data.bake_version
	var immutable_transfer: PackedByteArray = single_data.transfer.to_byte_array()
	var immutable_emitter: PackedByteArray = single_data.emitter_transport.to_byte_array()
	emitter_material.emission_energy_multiplier = 2.0
	var doubled_values: PackedFloat32Array = helper.read_source_values(volume, single_data)
	var doubled_payload: PackedFloat32Array = single_data.compose_emission(doubled_values)
	var doubled_ratio_ok := _payload_ratio_matches(initial_payload, doubled_payload, 2.0, 0.0001)
	_check(doubled_ratio_ok,
			"doubling live emitter energy doubles the raw per-probe payload (no display transform)")
	emitter_material.emission = Color.RED
	var red_values: PackedFloat32Array = helper.read_source_values(volume, single_data)
	var red_payload: PackedFloat32Array = single_data.compose_emission(red_values)
	_check(red_values[0] > 1.9 and red_values[1] == 0.0 and red_payload[floor_probe * 3] > 0.0
			and red_payload[floor_probe * 3 + 1] == 0.0,
			"runtime emitter color changes to red without changing baked geometry")
	emitter_material.emission = Color.BLUE
	var blue_values: PackedFloat32Array = helper.read_source_values(volume, single_data)
	var blue_payload: PackedFloat32Array = single_data.compose_emission(blue_values)
	_check(blue_values[2] > 1.9 and blue_values[0] == 0.0
			and blue_payload[floor_probe * 3 + 2] > 0.0 and blue_payload[floor_probe * 3] == 0.0,
			"runtime emitter color changes to blue in raw GI payload")
	emitter_material.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY
	var multiply_values: PackedFloat32Array = helper.read_source_values(volume, single_data)
	_check(multiply_values[0] == 0.0 and multiply_values[1] == 0.0 and multiply_values[2] == 0.0
			and multiply_values[5] > 1.9,
			"MULTIPLY operator places dynamic color only in the texture-weight term")
	emitter_material.emission_operator = BaseMaterial3D.EMISSION_OP_ADD
	emitter_material.emission_enabled = false
	var disabled_values: PackedFloat32Array = helper.read_source_values(volume, single_data)
	var disabled_payload: PackedFloat32Array = single_data.compose_emission(disabled_values)
	_check(_packed_values_all_zero(disabled_values) and _packed_values_all_zero(disabled_payload),
			"disabling every emitter makes the live emissive contribution exactly zero")
	_check(volume.has_bake() and single_data.bake_version == doubled_version
			and single_data.transfer.to_byte_array() == immutable_transfer
			and single_data.emitter_transport.to_byte_array() == immutable_emitter,
			"emitter color, energy, operator and enabled changes preserve bake validity and raw arrays")
	_check(helper.get_warning().is_empty(), "valid dynamic emitter changes do not request a rebake")

	# Re-bake with a double-sided panel and one extra path bounce. With all receiver
	# reflectance black, the added path bounce cannot add a second copy of direct NEE.
	volume.bake_bounces = 2
	emitter_material.emission_enabled = true
	emitter_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	var double_sided_ok: bool = await volume.bake()
	_check(double_sided_ok and volume.has_bake(), "double-sided source rebakes with the next transport depth")
	if double_sided_ok:
		var double_data: Resource = volume.bake_data
		var double_floor_weight := _emitter_transport_term0(double_data, _find_probe(double_data,
				Vector3(-0.5, 0.0, 0.5), Vector3.UP))
		var double_back_weight := _emitter_transport_term0(double_data, _find_probe(double_data,
				Vector3(-0.75, 3.0, 0.4), Vector3.DOWN))
		_check(double_back_weight > 0.0,
			"double-sided panel transports light to the formerly dark back-side receiver")
		_check(is_equal_approx(double_floor_weight, single_floor_weight),
			"extra bounce does not double-count a direct source hit (single %.8f, extra-bounce %.8f)" % [single_floor_weight, double_floor_weight])
	fixture.queue_free()
	await process_frame

func _emit_architecture_bake_snapshot(volume: Node3D, data: Resource) -> void:
	var placement := Placement.new()
	var collected: bool = placement.collect(volume, true, true, true)
	_check(collected, "Placement collector collects the rebaked scene for architecture comparison")
	if not collected:
		return
	_check(placement.positions.to_byte_array() == data.positions.to_byte_array()
			and placement.normals.to_byte_array() == data.normals.to_byte_array()
			and placement.emitters.keys == data.emitter_keys
			and placement.emitters.static_signatures == data.emitter_static_signatures
			and data.scene_signature == Baker.signature_for_geometry(placement.scene_signature),
			"bake payload retains the collected geometry and static-emitter binding order")
	var summary := {
		"geometry_signature": str(placement.scene_signature),
		"bake_signature": str(data.scene_signature),
		"face_count": placement.faces.size(),
		"probe_count": data.probe_count(),
		"emitter_keys": Array(data.emitter_keys),
		"faces_sha256": _sha256(placement.faces.to_byte_array()),
		"probe_positions_sha256": _sha256(data.positions.to_byte_array()),
		"probe_normals_sha256": _sha256(data.normals.to_byte_array()),
		"reflectance_sha256": _sha256(placement.reflectance.to_byte_array()),
		"emitter_keys_sha256": _sha256("\n".join(data.emitter_keys).to_utf8_buffer()),
		"emitter_static_sha256": _sha256(data.emitter_static_signatures.to_byte_array()),
		"transfer_sha256": _sha256(data.transfer.to_byte_array()),
		"emitter_transport_sha256": _sha256(data.emitter_transport.to_byte_array()),
	}
	print("MAGIC_GI_ARCH_BAKE_SNAPSHOT=", JSON.stringify(summary))

func _sha256(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	context.update(bytes)
	return context.finish().hex_encode()

func _capture_bake_result(volume, state: Dictionary) -> void:
	state["success"] = await volume.bake()
	state["data"] = volume.bake_data
	state["done"] = true

func _add_emission_fixture_plane(parent: Node, node_name: String, y: float,
		rotation: Vector3, material: Material) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = _make_horizontal_plane(3.0, 1, material)
	instance.rotation = rotation
	instance.position.y = y
	parent.add_child(instance)
	return instance

func _emitter_transport_term0(data: Resource, probe: int) -> float:
	if probe < 0 or probe >= data.probe_count() or data.emitter_count() == 0:
		return 0.0
	var base := probe * 6
	return maxf(data.emitter_transport[base], maxf(data.emitter_transport[base + 1], data.emitter_transport[base + 2]))

func _payload_ratio_matches(before: PackedFloat32Array, after: PackedFloat32Array,
		expected_ratio: float, tolerance: float) -> bool:
	if before.size() != after.size():
		return false
	var compared := 0
	for index in before.size():
		if before[index] > 0.00001:
			if absf(after[index] / before[index] - expected_ratio) > tolerance:
				return false
			compared += 1
	return compared > 0

func _packed_values_all_zero(values: PackedFloat32Array) -> bool:
	for value in values:
		if value != 0.0:
			return false
	return true

func _make_emission_contract_data(data: Resource = null) -> Resource:
	if data == null:
		data = Data.new()
	data.format_version = Data.FORMAT_VERSION
	data.grid_dims = Vector3i(2, 1, 1)
	data.volume_size = Vector3(2.0, 1.0, 1.0)
	data.spacing = 1.0
	data.surface_offset = 0.03
	data.volume_transform = Transform3D.IDENTITY
	data.world_to_grid = Transform3D.IDENTITY
	data.bake_samples = 64
	data.bake_bounces = 2
	data.bake_distance = 4.0
	data.terrain_reflectance = 0.5
	data.material_reflectance = 0.5
	data.positions = PackedVector3Array([Vector3(0.5, 0.53, 0.5), Vector3(1.5, 0.53, 0.5)])
	data.surface_positions = PackedVector3Array([Vector3(0.5, 0.5, 0.5), Vector3(1.5, 0.5, 0.5)])
	data.normals = PackedVector3Array([Vector3.UP, Vector3.UP])
	Baker._build_visibility_geometry(data, PackedVector3Array([
		Vector3.ZERO, Vector3(4, 0, 0), Vector3(0, 0, 4)]))
	data.visibility_moments.resize(data.probe_count() * Data.VISIBILITY_TEXELS_PER_PROBE
			* Data.VISIBILITY_MOMENT_CHANNELS)
	for probe in data.probe_count():
		for texel in Data.VISIBILITY_TEXELS_PER_PROBE:
			var moment_base: int = (probe * Data.VISIBILITY_TEXELS_PER_PROBE + texel) * Data.VISIBILITY_MOMENT_CHANNELS
			data.visibility_moments[moment_base] = data.bake_distance
			data.visibility_moments[moment_base + 1] = data.bake_distance * data.bake_distance
	data.transfer.resize(data.probe_count() * 27)
	data.transfer.fill(0.0)
	data.primary_sky_visibility.resize(data.probe_count() * 9)
	data.primary_sky_visibility.fill(0.0)
	data.primary_sky_visibility[0] = 0.25
	data.emitter_keys = PackedStringArray(["EmissionFixture/Panel#surface=0"])
	data.emitter_static_signatures = PackedInt64Array([1234])
	data.emitter_transport = PackedFloat32Array([
		0.5, 0.0, 0.0, 0.1, 0.1, 0.1,
		0.25, 0.0, 0.0, 0.05, 0.05, 0.05,
	])
	data.bake_version = 1
	data.build_cell_indices()
	return data

func _test_runtime_atlas_positivity_filter() -> void:
	var data: Resource = _make_filter_test_data()
	_check(data.is_valid(), "synthetic positivity-filter bake is a valid current PRT resource")
	var raw_bytes: PackedByteArray = data.transfer.to_byte_array()
	var raw_image: Image = data.make_atlas_image()
	var runtime_image: Image = data.make_runtime_atlas_image()
	_check(raw_image != null and runtime_image != null,
			"raw and runtime transfer atlases are both generated")
	if raw_image == null or runtime_image == null:
		return
	_check(data.transfer.to_byte_array() == raw_bytes,
			"runtime positivity filtering leaves serialized transfer coefficients unchanged")
	for channel in 3:
		var original_dc := _atlas_coefficient(raw_image, 0, 0, channel)
		var runtime_dc := _atlas_coefficient(runtime_image, 0, 0, channel)
		_check(is_equal_approx(original_dc, runtime_dc),
				"runtime atlas preserves the raw DC coefficient for channel %d" % channel)
	_check(_atlas_coefficient(runtime_image, 0, 1, 0) != 0.0
			and is_equal_approx(
				_atlas_coefficient(runtime_image, 0, 1, 0) / _atlas_coefficient(raw_image, 0, 1, 0),
				_atlas_coefficient(runtime_image, 0, 4, 0) / _atlas_coefficient(raw_image, 0, 4, 0)),
			"runtime atlas applies one per-channel scale to both l=1 and l=2 bands")
	var minimum := Vector3(INF, INF, INF)
	var minimum_raw := Vector3(INF, INF, INF)
	for latitude_step in range(-8, 9):
		var y := float(latitude_step) / 8.0
		var ring_radius := sqrt(maxf(0.0, 1.0 - y * y))
		for sector in 24:
			var angle := TAU * float(sector) / 24.0
			var direction := Vector3(cos(angle) * ring_radius, y, sin(angle) * ring_radius)
			var basis: PackedFloat32Array = Data.sh_basis(direction)
			for channel in 3:
				var raw_value := 0.0
				var runtime_value := 0.0
				for coefficient in 9:
					raw_value += _atlas_coefficient(raw_image, 0, coefficient, channel) * basis[coefficient]
					runtime_value += _atlas_coefficient(runtime_image, 0, coefficient, channel) * basis[coefficient]
				minimum[channel] = minf(minimum[channel], runtime_value)
				minimum_raw[channel] = minf(minimum_raw[channel], raw_value)
	_check(minimum_raw.x < -0.001 or minimum_raw.y < -0.001,
			"synthetic transport contains SH9 ringing before runtime filtering")
	_check(minimum.x >= -0.00002 and minimum.y >= -0.00002,
			"addition-theorem bounds keep sampled runtime SH9 transport nonnegative: %s" % minimum)
	_check(runtime_image.get_pixel(0, 0).b == 0.0
			and _atlas_coefficient(runtime_image, 0, 8, 2) == 0.0,
			"zero-DC channels discard higher bands without adding a radiance floor")
	var uniform_lighting := PackedFloat32Array()
	uniform_lighting.resize(27)
	uniform_lighting.fill(0.0)
	for channel in 3:
		uniform_lighting[channel] = 2.0
	var raw_uniform := _evaluate_atlas(raw_image, 0, uniform_lighting)
	var runtime_uniform := _evaluate_atlas(runtime_image, 0, uniform_lighting)
	_check(raw_uniform.is_equal_approx(runtime_uniform),
			"runtime filtering preserves the DC response to uniform illumination")
	var directional_lighting := uniform_lighting.duplicate()
	directional_lighting[3] = 0.4
	var combined_lighting := PackedFloat32Array()
	combined_lighting.resize(27)
	for index in 27:
		combined_lighting[index] = uniform_lighting[index] + directional_lighting[index]
	var runtime_directional := _evaluate_atlas(runtime_image, 0, directional_lighting)
	var runtime_combined := _evaluate_atlas(runtime_image, 0, combined_lighting)
	_check(not runtime_directional.is_equal_approx(runtime_uniform)
			and runtime_combined.is_equal_approx(runtime_uniform + runtime_directional),
			"filtered transfer remains responsive and linear under changing light SH")
	var zero_lighting := PackedFloat32Array()
	zero_lighting.resize(27)
	zero_lighting.fill(0.0)
	_check(_evaluate_atlas(runtime_image, 0, zero_lighting) == Vector3.ZERO,
			"zero lighting SH produces an exactly zero runtime response")
	data.transfer.fill(0.0)
	var zero_atlas: Image = data.make_runtime_atlas_image()
	var zero_bytes := zero_atlas.get_data()
	var bytes_are_zero := true
	for value in zero_bytes:
		if value != 0:
			bytes_are_zero = false
			break
	_check(bytes_are_zero and _evaluate_atlas(zero_atlas, 0, combined_lighting) == Vector3.ZERO,
			"all-zero transport yields zero atlas bytes and zero runtime response")

func _make_filter_test_data() -> Resource:
	var data := Data.new()
	data.format_version = Data.FORMAT_VERSION
	data.grid_dims = Vector3i.ONE
	data.volume_size = Vector3.ONE
	data.spacing = 1.0
	data.surface_offset = 0.03
	data.bake_samples = 256
	data.bake_bounces = 1
	data.bake_distance = 4.0
	data.terrain_reflectance = 0.5
	data.material_reflectance = 0.5
	data.positions = PackedVector3Array([Vector3(0.5, 0.53, 0.5)])
	data.surface_positions = PackedVector3Array([Vector3(0.5, 0.5, 0.5)])
	data.normals = PackedVector3Array([Vector3.UP])
	Baker._build_visibility_geometry(data, PackedVector3Array([
		Vector3.ZERO, Vector3(4, 0, 0), Vector3(0, 0, 4)]))
	data.visibility_moments.resize(Data.VISIBILITY_TEXELS_PER_PROBE * Data.VISIBILITY_MOMENT_CHANNELS)
	for texel in Data.VISIBILITY_TEXELS_PER_PROBE:
		var moment_base := texel * Data.VISIBILITY_MOMENT_CHANNELS
		data.visibility_moments[moment_base] = data.bake_distance
		data.visibility_moments[moment_base + 1] = data.bake_distance * data.bake_distance
	data.transfer.resize(27)
	data.transfer.fill(0.0)
	data.primary_sky_visibility.resize(9)
	data.primary_sky_visibility.fill(0.0)
	var coefficients := [
		Vector3(1.0, 2.0, 0.0),
		Vector3(3.0, -1.5, 4.0),
		Vector3(-2.0, 1.0, -3.0),
		Vector3(4.0, 2.0, 2.5),
		Vector3(3.0, -2.0, 4.0),
		Vector3(-1.0, 3.0, -2.0),
		Vector3(2.0, -1.0, 5.0),
		Vector3(0.5, 1.5, -4.0),
		Vector3(-2.0, 2.0, 3.0),
	]
	for coefficient in 9:
		for channel in 3:
			data.transfer[coefficient * 3 + channel] = coefficients[coefficient][channel]
	data.cell_indices.resize(Data.CELL_CAPACITY)
	data.cell_indices.fill(-1)
	data.cell_indices[0] = 0
	data.bake_version = 1
	return data

func _atlas_coefficient(image: Image, probe: int, coefficient: int, channel: int) -> float:
	var packed_index := coefficient * 3 + channel
	var x := (probe % Data.ATLAS_COLUMNS) * Data.TRANSFER_TEXELS_PER_POINT + (packed_index >> 2)
	var y := probe / Data.ATLAS_COLUMNS
	var texel := image.get_pixel(x, y)
	return texel[packed_index % 4]

func _evaluate_atlas(image: Image, probe: int, lighting: PackedFloat32Array) -> Vector3:
	var result := Vector3.ZERO
	for coefficient in 9:
		for channel in 3:
			result[channel] += _atlas_coefficient(image, probe, coefficient, channel) \
					* lighting[coefficient * 3 + channel]
	return result

func _test_qmc_variance() -> void:
	const SAMPLE_COUNT := 64
	const REPLICATES := 24
	const EXACT_MEAN := 0.7916666666666666
	var qmc_squared_error := 0.0
	var random_squared_error := 0.0
	for replicate in REPLICATES:
		var shift_rng := RandomNumberGenerator.new()
		shift_rng.seed = 91021 + replicate
		var shift_u := shift_rng.randf()
		var shift_v := shift_rng.randf()
		var iid_rng := RandomNumberGenerator.new()
		iid_rng.seed = 42017 + replicate
		var qmc_total := 0.0
		var iid_total := 0.0
		for sample_index in SAMPLE_COUNT:
			var qmc_u: float = Baker.qmc_sample(sample_index, SAMPLE_COUNT, 0, shift_u)
			var qmc_v: float = Baker.qmc_sample(sample_index, SAMPLE_COUNT, 1, shift_v)
			qmc_total += _smooth_integrand(qmc_u, qmc_v)
			iid_total += _smooth_integrand(iid_rng.randf(), iid_rng.randf())
		var qmc_error := qmc_total / SAMPLE_COUNT - EXACT_MEAN
		var iid_error := iid_total / SAMPLE_COUNT - EXACT_MEAN
		qmc_squared_error += qmc_error * qmc_error
		random_squared_error += iid_error * iid_error
	var qmc_rmse := sqrt(qmc_squared_error / REPLICATES)
	var random_rmse := sqrt(random_squared_error / REPLICATES)
	_check(qmc_rmse < random_rmse * 0.5,
			"randomized low-discrepancy samples reduce smooth-integral RMSE (%.6f vs %.6f)" % [qmc_rmse, random_rmse])

func _smooth_integrand(u: float, v: float) -> float:
	return u * u + v * v + 0.5 * u * v

func _warnings_contain(warnings: PackedStringArray, fragment: String) -> bool:
	for warning in warnings:
		if warning.contains(fragment):
			return true
	return false

func _make_horizontal_plane(extent: float, subdivisions: int, material: Material,
		y := 0.0, face_down := false) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var half := extent * 0.5
	for z in subdivisions:
		for x in subdivisions:
			var x0 := -half + extent * float(x) / subdivisions
			var x1 := -half + extent * float(x + 1) / subdivisions
			var z0 := -half + extent * float(z) / subdivisions
			var z1 := -half + extent * float(z + 1) / subdivisions
			var a := Vector3(x0, y, z0)
			var b := Vector3(x1, y, z0)
			var c := Vector3(x1, y, z1)
			var d := Vector3(x0, y, z1)
			if face_down:
				vertices.append_array([a, c, b, a, d, c])
			else:
				vertices.append_array([a, b, c, a, c, d])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material)
	return mesh

func _make_triangle_surface(a: Vector3, b: Vector3, c: Vector3,
		material: Material) -> ArrayMesh:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([a, b, c])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material)
	return mesh

func _make_nested_box_mesh(outer_size: float, inner_size: float, material: Material) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	_add_box_surface(mesh, outer_size, false, material)
	_add_box_surface(mesh, inner_size, true, material)
	return mesh

func _add_box_surface(mesh: ArrayMesh, side: float, reverse_winding: bool,
		material: Material) -> void:
	var box := BoxMesh.new()
	box.size = Vector3.ONE * side
	var source_faces: PackedVector3Array = box.get_faces()
	var faces := PackedVector3Array()
	faces.resize(source_faces.size())
	for face in range(0, source_faces.size(), 3):
		faces[face] = source_faces[face]
		faces[face + 1] = source_faces[face + (2 if reverse_winding else 1)]
		faces[face + 2] = source_faces[face + (1 if reverse_winding else 2)]
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = faces
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(mesh.get_surface_count() - 1, material)

func _is_nested_inner_surface(local_point: Vector3, half_extent: float) -> bool:
	var tolerance := 0.001
	var on_x := absf(absf(local_point.x) - half_extent) <= tolerance \
			and absf(local_point.y) <= half_extent + tolerance \
			and absf(local_point.z) <= half_extent + tolerance
	var on_y := absf(absf(local_point.y) - half_extent) <= tolerance \
			and absf(local_point.x) <= half_extent + tolerance \
			and absf(local_point.z) <= half_extent + tolerance
	var on_z := absf(absf(local_point.z) - half_extent) <= tolerance \
			and absf(local_point.x) <= half_extent + tolerance \
			and absf(local_point.y) <= half_extent + tolerance
	return on_x or on_y or on_z

func _nested_normal_matches_cavity(local_point: Vector3, local_normal: Vector3,
		half_extent: float) -> bool:
	var x_match := absf(absf(local_point.x) - half_extent) <= 0.001 \
			and local_normal.dot(Vector3.RIGHT * (-1.0 if local_point.x > 0.0 else 1.0)) > 0.9
	var y_match := absf(absf(local_point.y) - half_extent) <= 0.001 \
			and local_normal.dot(Vector3.UP * (-1.0 if local_point.y > 0.0 else 1.0)) > 0.9
	var z_match := absf(absf(local_point.z) - half_extent) <= 0.001 \
			and local_normal.dot(Vector3.BACK * (-1.0 if local_point.z > 0.0 else 1.0)) > 0.9
	return x_match or y_match or z_match

func _make_array_mesh_from_faces(faces: PackedVector3Array, material: Material) -> ArrayMesh:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = faces
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material)
	return mesh

func _make_red_wall(width: float, height: float, material: Material) -> ArrayMesh:
	var half := width * 0.5
	var a := Vector3(1.0, 0.0, -half)
	var b := Vector3(1.0, height, -half)
	var c := Vector3(1.0, height, half)
	var d := Vector3(1.0, 0.0, half)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([a, b, c, a, c, d])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material)
	return mesh

func _make_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	return material

func _new_uniform_test_volume() -> FMagicGIVolume:
	var volume := Volume.new()
	volume.adaptive_placement = false
	return volume

func _minimum_same_normal_spacing(placement: RefCounted) -> float:
	var minimum := INF
	for i in placement.positions.size():
		for j in range(i + 1, placement.positions.size()):
			if placement.normals[i].dot(placement.normals[j]) > 0.95:
				minimum = minf(minimum, placement.positions[i].distance_to(placement.positions[j]))
	return minimum

func _world_spacing_violation_pair_count(positions: PackedVector3Array,
		spacing: float) -> int:
	var minimum_distance := maxf(0.0, spacing - maxf(0.000001, spacing * 0.000001))
	var minimum_distance_squared := minimum_distance * minimum_distance
	var violations := 0
	for i in positions.size():
		for j in range(i + 1, positions.size()):
			if positions[i].distance_squared_to(positions[j]) < minimum_distance_squared:
				violations += 1
	return violations

func _adaptive_spacing_violation_pair_count(placement: RefCounted) -> int:
	if placement.probe_spacings.size() != placement.positions.size():
		return -1
	var violations := 0
	for first in placement.positions.size():
		for second in range(first + 1, placement.positions.size()):
			var required_distance: float = 0.5 * (placement.probe_spacings[first]
					+ placement.probe_spacings[second])
			if placement.positions[first].distance_squared_to(placement.positions[second]) \
					< required_distance * required_distance * 0.99999:
				violations += 1
	return violations

func _print_adaptive_profile(label: String, placement: RefCounted,
		collect_ms: float) -> void:
	var min_spacing: float = placement._arbitration_spacing
	var spacing_metrics := _adaptive_pair_spacing_metrics(placement)
	print("MAGIC_GI_ADAPTIVE_PROFILE case=%s collect_ms=%.3f attempted=%d coarse_valid=%d refined_valid=%d raw_candidates=%d staged_candidates=%d selected=%d staged_pruned=%d feature_cells=%d cell_visits=%d world_cells=%d min_spacing=%.6f min_grid_max_occupancy=%d duplicate_centers=%d nearest_pair_m=%.6f nearest_pair_spacing=%.6f nearest_pair_ratio=%.6f marker_diameter_spacing_ratio=0.240000 spacing_violations=%d clearance_rejected=%d inside_rejected=%d" % [
		label, collect_ms, placement._candidate_count,
		placement._coarse_valid_candidate_count, placement._refined_valid_candidate_count,
		placement._valid_candidate_count,
		placement._staged_candidate_count, placement.positions.size(),
		placement._bounded_candidate_pruned_count, placement._refinement_cell_count,
		placement._refinement_cell_visit_count,
		_world_cell_counts(placement.positions, 1.0).size(),
		_minimum_world_spacing(placement.positions),
		_world_max_occupancy(placement.positions, min_spacing),
		_duplicate_probe_center_count(placement.positions),
		spacing_metrics.x, spacing_metrics.y, spacing_metrics.z,
		_adaptive_spacing_violation_pair_count(placement),
		placement.rejected_no_safe_offset_count,
		placement.rejected_inside_or_indeterminate_center_count])

func _adaptive_pair_spacing_metrics(placement: RefCounted) -> Vector3:
	if placement.positions.size() != placement.probe_spacings.size() \
			or placement.positions.size() < 2:
		return Vector3(INF, INF, INF)
	var minimum_distance := INF
	var required_spacing := INF
	var minimum_ratio := INF
	for first in placement.positions.size():
		for second in range(first + 1, placement.positions.size()):
			var average_spacing: float = 0.5 * (placement.probe_spacings[first]
					+ placement.probe_spacings[second])
			var distance: float = placement.positions[first].distance_to(
					placement.positions[second])
			var ratio := distance / maxf(average_spacing, 0.000001)
			if ratio < minimum_ratio:
				minimum_ratio = ratio
				minimum_distance = distance
				required_spacing = average_spacing
	return Vector3(minimum_distance, required_spacing, minimum_ratio)

func _duplicate_probe_center_count(positions: PackedVector3Array) -> int:
	var seen: Dictionary = {}
	var duplicates := 0
	for position in positions:
		var key := "%d,%d,%d" % [roundi(position.x * 1000000.0),
				roundi(position.y * 1000000.0), roundi(position.z * 1000000.0)]
		if seen.has(key):
			duplicates += 1
		else:
			seen[key] = true
	return duplicates

func _test_adaptive_feature_edge_budget() -> void:
	var geometry := AdaptiveFeatureGeometryStub.new()
	var source := AdaptiveFeatureFaceStub.new()
	var far := 1000000.0
	# Two faces share a sharp edge that spans two million world meters, while the
	# placement bounds intersect only its two-meter middle section.
	source.faces = PackedVector3Array([
		Vector3(-far, 0.0, 0.0), Vector3(far, 0.0, 0.0), Vector3(0.0, 1.0, 0.0),
		Vector3(far, 0.0, 0.0), Vector3(-far, 0.0, 0.0), Vector3(0.0, 0.0, 1.0)])
	var placement_bounds := AABB(Vector3(-1.0, -1.0, -1.0), Vector3.ONE * 2.0)
	var clipped := AdaptiveLayout._clip_segment_to_aabb(source.faces[0],
		source.faces[1], placement_bounds.grow(1.0))
	var clipped_samples := ceili(clipped[0].distance_to(clipped[1]) / 0.5) + 1 \
			if clipped.size() == 2 else 0
	var result: Dictionary = AdaptiveLayout.mark_refinement_cells({},
			Callable(geometry, "trace"), source, placement_bounds, 1.0, 0.25)
	var marked: Dictionary = result["cells"]
	_check(clipped_samples <= 9 and String(result["error"]).is_empty()
			and marked.size() <= clipped_samples * 27,
			"a long sharp edge is clipped to bounded placement support before refinement marking")
	print("MAGIC_GI_ADAPTIVE_EDGE_BUDGET original_m=%.1f clipped_samples=%d marked_cells=%d error=%s" % [
		source.faces[0].distance_to(source.faces[1]), clipped_samples,
		marked.size(), result["error"]])

func _minimum_world_spacing(positions: PackedVector3Array) -> float:
	var minimum_distance := INF
	for first in positions.size():
		for second in range(first + 1, positions.size()):
			minimum_distance = minf(minimum_distance,
					positions[first].distance_to(positions[second]))
	return minimum_distance

func _surface_anchor_keys(anchors: PackedVector3Array) -> Array[String]:
	var keys: Array[String] = []
	for anchor in anchors:
		keys.append("%d,%d,%d" % [
			roundi(anchor.x * 100000.0), roundi(anchor.y * 100000.0),
			roundi(anchor.z * 100000.0)])
	keys.sort()
	return keys

func _world_cell_counts(positions: PackedVector3Array, spacing: float) -> Dictionary:
	var counts: Dictionary = {}
	for position in positions:
		var cell := ProbeLayout.world_cell(position, spacing)
		counts[cell] = int(counts.get(cell, 0)) + 1
	return counts

func _world_max_occupancy(positions: PackedVector3Array, spacing: float) -> int:
	var maximum := 0
	for count in _world_cell_counts(positions, spacing).values():
		maximum = maxi(maximum, int(count))
	return maximum

func _normal_count(placement: RefCounted, direction: Vector3) -> int:
	var count := 0
	for normal in placement.normals:
		if normal.dot(direction) > 0.95:
			count += 1
	return count

func _max_cell_load(placement: RefCounted) -> int:
	var maximum := 0
	for key in placement._cell_counts:
		maximum = maxi(maximum, int(placement._cell_counts[key]))
	return maximum

func _surface_height_count(placement: RefCounted, volume: Node3D, y: float,
		normal_filter := Vector3.ZERO, x_min := -INF, x_max := INF) -> int:
	var count := 0
	for index in placement.positions.size():
		if normal_filter.length_squared() > 0.5 \
				and placement.normals[index].dot(normal_filter) < 0.95:
			continue
		if placement.positions[index].x < x_min or placement.positions[index].x > x_max:
			continue
		var surface_y: float = placement.surface_positions[index].y
		if is_equal_approx(surface_y, y):
			count += 1
	return count

func _test_probe_viz_contracts() -> void:
	var volume := _new_uniform_test_volume()
	volume.position = Vector3(3.0, -2.0, 1.0)
	volume.rotation = Vector3(0.2, -0.35, 0.4)
	volume.scale = Vector3(2.0, 1.0, 0.5)
	root.add_child(volume)
	volume.size = Vector3.ONE * 4.0
	volume.probe_spacing = 2.0
	volume.surface_offset = 0.03
	var volume_transform := volume.global_transform
	var surface_normal := (volume_transform.basis.inverse().transposed() * Vector3.UP).normalized()
	var single_surface := volume_transform * Vector3.ZERO
	var single_center := volume_transform * Vector3(0.0, volume.surface_offset, 0.0)
	var data := Data.new()
	data.positions = PackedVector3Array([single_center])
	data.normals = PackedVector3Array([surface_normal])
	data.transfer.resize(27)
	data.transfer.fill(0.0)
	var lighting := PackedFloat32Array()
	lighting.resize(27)
	lighting.fill(1.0)
	var preview := {"data": data, "data_valid": true, "layout_matches": true,
		"current_available": true, "lighting": lighting}
	var zero_color: Color = Viz._probe_color_state(preview, 0).color
	_check(zero_color.b > 0.8 and zero_color.g > 0.5,
			"valid zero-response probes have a visible diagnostic tint rather than appearing invalid")
	data.transfer[0] = 0.001
	var low_state: Dictionary = Viz._probe_color_state(preview, 0)
	_check(is_equal_approx(low_state.color.r, 0.001) and not low_state.compensate,
			"weak positive transport retains physical response without diagnostic exposure compensation")
	volume.probe_positions = PackedVector3Array([single_center])
	volume.probe_surface_positions = PackedVector3Array([single_surface])
	volume.probe_normals = PackedVector3Array([surface_normal])
	volume.bake_data = data
	var single_viz_root := Node3D.new()
	volume.add_child(single_viz_root)
	Viz._build_box(volume, single_viz_root)
	Viz._build_probes(volume, single_viz_root, preview)
	Viz._build_sh(volume, single_viz_root, preview)
	var off := GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var box := single_viz_root.get_node("_Box") as MeshInstance3D
	var probes := single_viz_root.get_node("_Probes") as MultiMeshInstance3D
	var transport := single_viz_root.get_node("_Transport") as Node3D
	var transport_mesh := transport.get_child(0) as MeshInstance3D
	var sphere := probes.multimesh.mesh as SphereMesh
	var probe_material := sphere.material as ShaderMaterial
	_check(box.cast_shadow == off and probes.cast_shadow == off and transport_mesh.cast_shadow == off,
			"volume box, MultiMesh probes, and transport meshes do not cast shadows")
	_check(probes.visible and probes.multimesh.use_colors,
			"probe spheres are visible and use per-instance diagnostic colors")
	var expected_radius := ProbeLayout.marker_radius(volume.cell_size())
	_check(is_equal_approx(sphere.radius, expected_radius)
			and is_equal_approx(sphere.height, expected_radius * 2.0),
			"probe markers retain the established cell-relative mesh size")
	_check(volume.probe_positions.size() == 1 and probes.multimesh.instance_count == 1,
			"each authored probe center produces exactly one visualization instance")
	_check(probes.multimesh.transform_format == MultiMesh.TRANSFORM_3D,
			"probe markers use 3D instance transforms; headless Dummy does not expose their values")
	_check(probe_material != null
			and probe_material.shader == Viz.PreviewShader
			and not probe_material.get_shader_parameter("preview_unit_transport"),
			"probe sphere material uses the exposure-aware physical response preview")
	single_viz_root.free()
	data = null
	volume.free()

func _test_small_triangle_centroid_sampling() -> void:
	var fixture := Node3D.new()
	fixture.name = "SmallTriangleFixture"
	root.add_child(fixture)
	var volume := _new_uniform_test_volume()
	volume.size = Vector3.ONE * 2.0
	volume.probe_spacing = 1.0
	volume.surface_offset = 0.03
	fixture.add_child(volume)
	var a := Vector3(1.0, 0.99, 0.95)
	var b := Vector3(0.95, 1.0, 0.99)
	var c := Vector3(0.99, 0.95, 1.0)
	var triangle_mesh := ArrayMesh.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([a, c, b])
	triangle_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_check(triangle_mesh.get_surface_count() == 1,
			"small-triangle centroid fixture mesh is valid")
	triangle_mesh.surface_set_material(0, _make_material(Color.WHITE))
	var triangle_instance := MeshInstance3D.new()
	triangle_instance.mesh = triangle_mesh
	fixture.add_child(triangle_instance)
	await process_frame
	var placement := Placement.new()
	var collected: bool = placement.collect(volume, false)
	var centroid := (a + b + c) / 3.0
	_check(collected, "small boundary triangle collects without a bake error")
	_check(placement.positions.size() == 1 and placement.surface_positions.size() == 1
			and placement.surface_positions[0].distance_to(centroid) < 0.00001
			and placement.rejected_no_safe_offset_count == 3,
			"a small triangle whose vertices lack clearance is represented by its safe centroid (probes %d, no-offset %d, inside %d, outside %d, centers %s, anchors %s)" % [
				placement.positions.size(), placement.rejected_no_safe_offset_count,
				placement.rejected_inside_or_indeterminate_center_count,
				placement.rejected_center_outside_count,
				str(placement.positions), str(placement.surface_positions)])
	volume.adaptive_placement = true
	var adaptive_placement := Placement.new()
	var adaptive_collected: bool = adaptive_placement.collect(volume, false, false)
	var adaptive_centroid_found := false
	for anchor in adaptive_placement.surface_positions:
		if anchor.distance_to(centroid) < 0.00001:
			adaptive_centroid_found = true
	_check(adaptive_collected and adaptive_centroid_found
			and adaptive_placement.probe_spacings.size() == adaptive_placement.positions.size()
			and adaptive_placement.positions.size() > 0
			and _adaptive_spacing_violation_pair_count(adaptive_placement) == 0,
			"adaptive refinement preserves the small isolated triangle through safe centroid fallback")
	_print_adaptive_profile("small_triangle", adaptive_placement, 0.0)
	fixture.queue_free()
	await process_frame

func _test_centered_seam_clearance() -> void:
	var fixture := Node3D.new()
	fixture.name = "ProbeCenteredClearanceFixture"
	root.add_child(fixture)
	var volume := _new_uniform_test_volume()
	volume.size = Vector3.ONE * 4.0
	volume.probe_spacing = 1.0
	fixture.add_child(volume)
	var material := _make_material(Color.WHITE)
	var floor := MeshInstance3D.new()
	floor.mesh = _make_horizontal_plane(2.0, 1, material)
	fixture.add_child(floor)
	var foreign := MeshInstance3D.new()
	foreign.mesh = _make_array_mesh_from_faces(PackedVector3Array([
		Vector3(0.5, -1.0, -1.0), Vector3(0.5, 1.0, -1.0),
		Vector3(0.5, 1.0, 1.0), Vector3(0.5, -1.0, -1.0),
		Vector3(0.5, 1.0, 1.0), Vector3(0.5, -1.0, 1.0)]), material)
	fixture.add_child(foreign)
	await process_frame
	var placement := Placement.new()
	var collected: bool = placement.collect(volume, false)
	var surface := Vector3(0.5, 0.0, -0.5)
	var center := surface + Vector3.UP * Placement._preferred_probe_offset(volume)
	var owner_ray_epsilon := Placement._preferred_probe_offset(volume) * 0.1
	var owner_hit: Dictionary = {}
	if collected and placement.bvh_ready:
		owner_hit = placement.bvh.intersect_segment(
				center - Vector3.UP * owner_ray_epsilon,
				surface - Vector3.UP * owner_ray_epsilon)
	var owner_connection_is_valid := not owner_hit.is_empty() \
			and int(owner_hit.get("face_index", -1)) < 2
	var centered_clearance_rejects := collected and placement.bvh_ready \
			and not placement._center_has_foreign_surface_clearance(
				surface, Vector3.UP, center, 0)
	var near_minimum_center := surface + Vector3.UP * 0.002
	var near_minimum_owner_hit: Dictionary = {}
	if collected and placement.bvh_ready:
		near_minimum_owner_hit = placement.bvh.intersect_segment(
				near_minimum_center + Vector3.UP * 0.0002,
				surface - Vector3.UP * 0.0002)
	var near_minimum_owner_reached := not near_minimum_owner_hit.is_empty() \
			and int(near_minimum_owner_hit.get("face_index", -1)) < 2
	var near_minimum_clearance_rejects := collected and placement.bvh_ready \
			and not placement._center_has_foreign_surface_clearance(
				surface, Vector3.UP, near_minimum_center, 0)
	var seam_anchor_was_rejected := true
	for index in placement.surface_positions.size():
		if placement.normals[index].dot(Vector3.UP) > 0.95 \
				and placement.surface_positions[index].distance_to(surface) < 0.0001:
			seam_anchor_was_rejected = false
	_check(collected and owner_connection_is_valid and centered_clearance_rejects,
			"six-axis centered BVH clearance rejects a perpendicular foreign face even when the owner ray reaches its source face")
	_check(near_minimum_owner_reached and near_minimum_clearance_rejects,
			"centered clearance rejects a seam face at the minimum permitted probe offset")
	_check(seam_anchor_was_rejected and placement.rejected_foreign_surface_center_count > 0,
			"the cross-seam canonical owner probe is not staged through a foreign face")
	print("MAGIC_GI_SEAM_CLEARANCE collected=%s owner_ray_face=%d foreign_rejections=%d" % [
		str(collected), int(owner_hit.get("face_index", -1)),
		placement.rejected_foreign_surface_center_count])
	fixture.queue_free()
	await process_frame

	var far_fixture := Node3D.new()
	far_fixture.position = Vector3(16384.0, -8192.0, 32768.0)
	far_fixture.rotation = Vector3(0.23, -0.17, 0.31)
	far_fixture.scale = Vector3(2.0, 0.5, 1.5)
	root.add_child(far_fixture)
	var far_volume := _new_uniform_test_volume()
	far_volume.size = Vector3.ONE * 4.0
	far_volume.probe_spacing = 1.0
	far_fixture.add_child(far_volume)
	var far_open_plane := MeshInstance3D.new()
	far_open_plane.mesh = _make_horizontal_plane(4.0, 1, material)
	far_fixture.add_child(far_open_plane)
	await process_frame
	var far_placement := Placement.new()
	var far_collected: bool = far_placement.collect(far_volume, false)
	var far_owner_side_valid := far_placement.faces.size() >= 3 \
			and far_placement.positions.size() > 0
	if far_placement.faces.size() >= 3:
		var raw_a: Vector3 = far_placement.faces[0]
		var raw_b: Vector3 = far_placement.faces[1]
		var raw_c: Vector3 = far_placement.faces[2]
		var raw_normal := (raw_c - raw_a).cross(raw_b - raw_a).normalized()
		for index in far_placement.positions.size():
			var oriented_raw_normal := raw_normal
			if oriented_raw_normal.dot(far_placement.normals[index]) < 0.0:
				oriented_raw_normal = -oriented_raw_normal
			far_owner_side_valid = far_owner_side_valid \
					and (far_placement.positions[index] - raw_a).dot(
					oriented_raw_normal) > 0.0
	_check(far_collected and far_placement.positions.size() > 0
			and far_owner_side_valid
			and far_placement.rejected_owner_backside_center_count > 0,
			"finite far open plane keeps accepted probes in the raw owner front half-space and rejects slipped backside centers")
	print("MAGIC_GI_FAR_OPEN_OWNER_SIDE collected=%s probes=%d rejected_backside=%d valid=%s" % [
		str(far_collected), far_placement.positions.size(),
		far_placement.rejected_owner_backside_center_count, str(far_owner_side_valid)])
	far_fixture.queue_free()
	await process_frame

func _test_coplanar_crossing_topology() -> void:
	var placement := Placement.new()
	placement._probe_spacing = 1.0
	var large_x := 32768.0
	var adjacent_plane := PackedVector3Array([
		Vector3(large_x, 0.0, 0.0), Vector3(large_x + 2.0, 0.0, 0.0),
		Vector3(large_x + 2.0, 0.0, 2.0),
		Vector3(large_x, 0.0, 0.0), Vector3(large_x + 2.0, 0.0, 2.0),
		Vector3(large_x, 0.0, 2.0)])
	var parallel_gap := 0.002
	var parallel_planes := PackedVector3Array([
		Vector3(large_x, 0.0, 0.0), Vector3(large_x + 2.0, 0.0, 0.0),
		Vector3(large_x + 2.0, 0.0, 2.0),
		Vector3(large_x, parallel_gap, 0.0),
		Vector3(large_x + 2.0, parallel_gap, 0.0),
		Vector3(large_x + 2.0, parallel_gap, 2.0)])
	var shared_edge_continuation := placement._mesh_faces_share_coplanar_crossing(
			adjacent_plane, 0, 1, Vector3(large_x + 1.0, 0.0, 1.0))
	var distinct_parallel_continuation := placement._mesh_faces_share_coplanar_crossing(
			parallel_planes, 0, 1, Vector3(large_x + 0.75, 0.0, 0.5))
	var parallel_bvh := TriangleMesh.new()
	var parallel_bvh_created: bool = parallel_bvh.create_from_faces(parallel_planes)
	var parallel_crossings := placement._ray_crossing_count(
			Vector3(large_x + 0.75, -0.02, 0.5), Vector3.UP, 0.05,
			0.0000001, 0.005, parallel_bvh, parallel_planes) if parallel_bvh_created else -2
	_check(shared_edge_continuation,
			"coplanar triangulated faces sharing a raw edge remain a valid crossing continuation")
	_check(not distinct_parallel_continuation,
			"nearby parallel faces without a shared raw edge are not coplanar continuations")
	_check(parallel_bvh_created and parallel_crossings == -1,
			"reverse crossing verification reports a 2 mm shell inside the large-coordinate ULP advance as ambiguous")
	print("MAGIC_GI_COPLANAR_TOPOLOGY shared_edge=%s separated_parallel=%s gap=%.4f ray_crossings=%d bvh=%s" % [
		str(shared_edge_continuation), str(distinct_parallel_continuation),
		parallel_gap, parallel_crossings, str(parallel_bvh_created)])

func _test_corner_center_separation() -> void:
	var fixture := Node3D.new()
	fixture.name = "ProbeCornerFixture"
	root.add_child(fixture)
	var volume := _new_uniform_test_volume()
	volume.size = Vector3.ONE * 4.0
	volume.probe_spacing = 1.0
	fixture.add_child(volume)
	var material := _make_material(Color.WHITE)
	var floor := MeshInstance3D.new()
	floor.mesh = _make_triangle_surface(Vector3.ZERO, Vector3(2.2, 0.0, 0.0),
			Vector3(0.0, 0.0, 2.2), material)
	fixture.add_child(floor)
	var wall := MeshInstance3D.new()
	wall.mesh = _make_triangle_surface(Vector3.ZERO, Vector3(0.0, 0.0, 2.2),
			Vector3(0.0, 2.2, 0.0), material)
	fixture.add_child(wall)
	await process_frame
	var placement := Placement.new()
	var collected: bool = placement.collect(volume, false)
	var floor_normal := (floor.global_transform.basis * Vector3.UP).normalized()
	var wall_normal := Vector3.RIGHT
	var floor_count := 0
	var wall_count := 0
	var anchors_remain_on_source_planes := true
	for index in placement.positions.size():
		var anchor: Vector3 = placement.surface_positions[index]
		var center: Vector3 = placement.positions[index]
		var normal: Vector3 = placement.normals[index]
		if normal.dot(floor_normal) > 0.95:
			floor_count += 1
			anchors_remain_on_source_planes = anchors_remain_on_source_planes \
					and absf(anchor.y) < 0.0001 and (center - anchor).dot(normal) > 0.0
		elif normal.dot(wall_normal) > 0.95:
			wall_count += 1
			anchors_remain_on_source_planes = anchors_remain_on_source_planes \
					and absf(anchor.x) < 0.0001 and (center - anchor).dot(normal) > 0.0
	var spacing_violations := _world_spacing_violation_pair_count(
			placement.positions, volume.probe_spacing)
	_check(collected and floor_count > 0 and wall_count > 0,
			"perpendicular corner surfaces get independent samples where separate world cells permit them")
	_check(anchors_remain_on_source_planes and spacing_violations == 0
			and _world_max_occupancy(placement.positions, volume.probe_spacing) == 1
			and placement.adjusted_center_count == 0,
			"corner arbitration preserves source anchors and enforces one world probe per spacing cell")
	print("MAGIC_GI_CORNER_LAYOUT floor=%d wall=%d adjusted=%d rejected_spacing_cells=%d spacing_violations=%d" % [
		floor_count, wall_count, placement.adjusted_center_count,
		placement.rejected_center_overlap_count, spacing_violations])
	volume.adaptive_placement = true
	var adaptive_corner_placement := Placement.new()
	var adaptive_corner_start_usec := Time.get_ticks_usec()
	var adaptive_corner_collected: bool = adaptive_corner_placement.collect(
			volume, false, false)
	var adaptive_corner_ms := float(Time.get_ticks_usec() - adaptive_corner_start_usec) / 1000.0
	_check(adaptive_corner_collected, "adaptive corner candidate profile collects")
	_print_adaptive_profile("corner", adaptive_corner_placement, adaptive_corner_ms)
	fixture.queue_free()
	await process_frame

func _test_world_spacing_variants() -> void:
	_check(ProbeLayout.world_cell(Vector3(-0.001, 0.0, -1.001), 1.0)
			== Vector3i(-1, 0, -2),
			"world-cell occupancy uses floor from the global zero origin for negative coordinates")
	for spacing in [0.5, 1.0, 2.0]:
		var fixture := Node3D.new()
		fixture.name = "WorldSpacing_%.1f" % spacing
		fixture.position = Vector3(-2.35, -0.2, 1.1)
		fixture.rotation = Vector3(0.23, -0.17, 0.31)
		fixture.scale = Vector3(1.8, 0.65, 1.2)
		root.add_child(fixture)
		var volume := _new_uniform_test_volume()
		volume.size = Vector3(8.0, 6.0, 8.0)
		volume.probe_spacing = spacing
		fixture.add_child(volume)
		var plane := MeshInstance3D.new()
		plane.name = "SpacingPlane"
		plane.mesh = _make_horizontal_plane(8.0, 2, _make_material(Color.WHITE))
		fixture.add_child(plane)
		await process_frame
		var placement := Placement.new()
		var collected: bool = placement.collect(volume, false)
		var occupancy := _world_cell_counts(placement.positions, spacing)
		var crosses_zero := false
		var has_negative_cell := false
		var has_positive_cell := false
		for cell_value in occupancy:
			var cell: Vector3i = cell_value
			if cell.x < 0 or cell.z < 0:
				has_negative_cell = true
			if cell.x > 0 or cell.z > 0:
				has_positive_cell = true
			if (cell.x < 0 and cell.z > 0) or (cell.x > 0 and cell.z < 0):
				crosses_zero = true
		_check(collected and placement.positions.size() > 0
				and _world_max_occupancy(placement.positions, spacing) == 1
				and _world_spacing_violation_pair_count(placement.positions, spacing) == 0,
				"spacing %.1fm stays global across rotated nonuniform parent scale" % spacing)
		_check(has_negative_cell and has_positive_cell and crosses_zero,
				"spacing %.1fm fixture exercises world cells on both sides of zero" % spacing)
		print("MAGIC_GI_WORLD_SPACING spacing=%.2f probes=%d world_cells=%d max_cell=%.0f violations=%d" % [
			spacing, placement.positions.size(), occupancy.size(),
			float(_world_max_occupancy(placement.positions, spacing)),
			_world_spacing_violation_pair_count(placement.positions, spacing)])
		fixture.queue_free()
		await process_frame
	var stable_results: Array[PackedVector3Array] = []
	var stable_normals: Array[PackedVector3Array] = []
	for reverse_order in [false, true]:
		var fixture := Node3D.new()
		fixture.name = "TraversalOrderFixture"
		root.add_child(fixture)
		var volume := _new_uniform_test_volume()
		volume.name = "Volume"
		volume.size = Vector3(4.0, 2.0, 4.0)
		volume.probe_spacing = 1.0
		fixture.add_child(volume)
		var first := MeshInstance3D.new()
		first.name = "SurfaceA"
		first.mesh = _make_horizontal_plane(3.0, 2, _make_material(Color.WHITE))
		var second := MeshInstance3D.new()
		second.name = "SurfaceB"
		second.mesh = _make_horizontal_plane(3.0, 2, _make_material(Color.WHITE))
		if reverse_order:
			fixture.add_child(second)
			fixture.add_child(first)
		else:
			fixture.add_child(first)
			fixture.add_child(second)
		await process_frame
		var placement := Placement.new()
		var collected: bool = placement.collect(volume, false)
		_check(collected and placement.positions.size() > 0
				and _world_max_occupancy(placement.positions, 1.0) == 1
				and _world_spacing_violation_pair_count(placement.positions, 1.0) == 0,
				"overlapping objects collect under the shared global spacing rule")
		stable_results.append(placement.positions.duplicate())
		stable_normals.append(placement.normals.duplicate())
		fixture.queue_free()
		await process_frame
	_check(stable_results.size() == 2 and stable_normals.size() == 2
			and stable_results[0] == stable_results[1]
			and stable_normals[0] == stable_normals[1],
			"Morton arbitration and geometric/path ties are independent of node traversal order")

func _find_probe(data: Resource, target: Vector3, normal: Vector3) -> int:
	var best := -1
	var distance := INF
	for i in data.probe_count():
		if data.normals[i].dot(normal) < 0.95:
			continue
		var sample_distance: float = data.positions[i].distance_squared_to(target)
		if sample_distance < distance:
			distance = sample_distance
			best = i
	return best

func _find_probe_in_surface_region(data: Resource, target: Vector3, normal: Vector3,
		surface_y: float, minimum_x: float, maximum_x: float,
		minimum_z := -INF, maximum_z := INF) -> int:
	var best := -1
	var best_distance := INF
	for index in data.probe_count():
		if data.normals[index].dot(normal) < 0.95:
			continue
		var anchor: Vector3 = data.surface_positions[index]
		if absf(anchor.y - surface_y) > 0.02 or anchor.x < minimum_x or anchor.x > maximum_x \
				or anchor.z < minimum_z or anchor.z > maximum_z:
			continue
		var distance: float = data.positions[index].distance_squared_to(target)
		if distance < best_distance:
			best_distance = distance
			best = index
	return best

func _primary_sky_probe_l1(data: Resource, probe: int) -> float:
	if probe < 0 or probe >= data.probe_count() \
			or data.primary_sky_visibility.size() != data.probe_count() * 9:
		return INF
	var total := 0.0
	for coefficient in 9:
		total += absf(data.primary_sky_visibility[probe * 9 + coefficient])
	return total

func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)
