extends SceneTree

const Data = preload("res://addons/feng-magic-gi/feng_magic_gi_data.gd")
const Placement = preload("res://addons/feng-magic-gi/feng_magic_gi_placement.gd")
const Baker = preload("res://addons/feng-magic-gi/feng_magic_gi_baker.gd")
const Lighting = preload("res://addons/feng-magic-gi/feng_magic_gi_lighting.gd")
const Runtime = preload("res://addons/feng-magic-gi/feng_magic_gi_runtime.gd")
const Viz = preload("res://addons/feng-magic-gi/feng_magic_gi_viz.gd")
const Volume = preload("res://addons/feng-magic-gi/feng_magic_gi_volume.gd")
const InspectorPlugin = preload("res://addons/feng-magic-gi/editor/magic_gi_inspector_plugin.gd")

class FakeTerrainData extends Object:
	signal maps_changed
	signal maps_edited(edited_area: AABB)

var _failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_test_pure_contracts()
	var scene := Node3D.new()
	root.add_child(scene)
	var density_volume := Volume.new()
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
	_check(coarse_count > 10, "plane creates many surface probes, not one overwritten slot")
	var fine_mesh := _make_horizontal_plane(10.0, 20, white)
	coarse.mesh = fine_mesh
	var fine_placement := Placement.new()
	_check(fine_placement.collect(density_volume, false), "fine plane placement collection succeeds")
	var fine_count := fine_placement.positions.size()
	_check(absf(float(fine_count - coarse_count)) <= maxf(12.0, coarse_count * 0.3),
			"probe count remains stable when plane tessellation changes (%d vs %d)" % [coarse_count, fine_count])
	_check(_minimum_same_normal_spacing(fine_placement) >= 0.79,
			"same-facing plane probes respect the spacing density")
	_check(_normal_count(fine_placement, Vector3.UP) > 8, "plane probes face the visible surface")
	coarse.queue_free()
	density_volume.queue_free()
	await process_frame
	var zero_volume := Volume.new()
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
	var zero_baked: bool = await zero_volume.bake()
	_check(zero_baked and zero_volume.bake_data.is_valid(),
			"an isolated plane produces a valid bake even when it has no indirect transport")
	_check(not zero_volume.bake_data.has_nonzero_transfer()
			and not zero_volume.has_nonzero_indirect_transfer(),
			"a single flat receiver correctly stores zero indirect transport")
	var zero_warnings: PackedStringArray = zero_volume._get_configuration_warnings()
	_check(zero_warnings.has(Volume.ZERO_TRANSFER_DIAGNOSTIC),
			"a valid all-zero bake exposes a persistent no-indirect-light warning")
	isolated_ground.queue_free()
	zero_volume.queue_free()
	await process_frame

	var boundary_volume := Volume.new()
	boundary_volume.size = Vector3.ONE * 2.0
	boundary_volume.probe_spacing = 1.0
	scene.add_child(boundary_volume)
	var min_face := MeshInstance3D.new()
	min_face.mesh = _make_horizontal_plane(2.0, 1, white, -1.0)
	scene.add_child(min_face)
	var max_face := MeshInstance3D.new()
	max_face.mesh = _make_horizontal_plane(2.0, 1, white, 1.0)
	scene.add_child(max_face)
	var boundary_placement := Placement.new()
	_check(boundary_placement.collect(boundary_volume, false), "planes on both volume Y faces collect successfully")
	_check(_surface_height_count(boundary_placement, boundary_volume, -1.0) > 0,
			"plane on the exact minimum volume face is sampled")
	_check(_surface_height_count(boundary_placement, boundary_volume, 1.0) > 0,
			"plane on the exact maximum volume face is sampled")
	min_face.queue_free()
	max_face.queue_free()
	boundary_volume.queue_free()
	await process_frame

	var box_volume := Volume.new()
	box_volume.size = Vector3.ONE * 2.0
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
	_check(box_placement.positions.size() > 12, "closed box has multiple samples on each face")
	for direction in [Vector3.LEFT, Vector3.RIGHT, Vector3.UP, Vector3.DOWN, Vector3.FORWARD, Vector3.BACK]:
		_check(_normal_count(box_placement, direction) > 0, "closed box retains face normal %s" % direction)
	var box_data := Data.new()
	box_data.grid_dims = box_volume.grid_dimensions()
	box_data.volume_size = box_volume.size
	box_data.spacing = box_volume.probe_spacing
	box_data.surface_offset = box_volume.surface_offset
	box_data.volume_transform = box_volume.global_transform
	box_data.world_to_grid = box_volume.world_to_grid_transform()
	box_data.positions = box_placement.positions
	box_data.normals = box_placement.normals
	_check(box_data.build_cell_indices(), "closed box stays within the 8-slot cell capacity")
	box_volume.queue_free()
	box_instance.queue_free()
	await process_frame

	var curved_volume := Volume.new()
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
	_check(curved_collected, "1m sphere and cone placement fits the 8-slot grid")
	_check(curved_placement.positions.size() > 0 and _max_cell_load(curved_placement) <= Data.CELL_CAPACITY,
			"curved surfaces remain represented without lookup-cell overflow")
	_check(_normal_count(curved_placement, Vector3.UP) > 0,
			"curved object fixture retains upward-facing surface samples")
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
		var cornell_collected: bool = cornell_placement.collect(cornell_volume, true, false)
		_check(cornell_collected and cornell_placement.positions.size() >= 200,
				"full Cornell room and props collect at 1m spacing without holes/overflow")
		_check(_max_cell_load(cornell_placement) <= Data.CELL_CAPACITY,
				"Cornell room corner cells stay within eight lookup slots")
		var cornell_data: Resource = cornell_volume.get("bake_data")
		_check(cornell_data != null and cornell_data.call("is_valid")
				and cornell_data.get("scene_signature") == Baker.signature_for_geometry(cornell_placement.scene_signature)
				and cornell_volume.call("has_bake"),
				"saved Cornell scene references a current valid bake")
		_check(cornell_data != null and cornell_data.call("has_nonzero_transfer"),
				"saved Cornell bake contains real nonzero indirect transport")
		cornell_scene.queue_free()
		await process_frame

	var volume := Volume.new()
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
	var empty_volume := Volume.new()
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
	_check(data.format_version == Data.FORMAT_VERSION and data.is_valid(), "baked resource validates as PRT v2")
	_check(data.scene_signature == Baker.signature_for_geometry(actual_placement.scene_signature),
			"bake signature records the current sampler revision without changing Data v2")
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
	var transport_viz: Node3D = FMagicGIViz.build(volume)
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
	var clone_volume := Volume.new()
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
	_check(clone_volume.has_bake()
			and persistent_signature == Baker.signature_for_geometry(clone_volume._current_scene_signature),
			"equivalent re-instantiated scene accepts saved bake without process IDs")
	clone_wall_material.albedo_color = Color.BLUE
	clone_volume.refresh_surface_points()
	_check(not clone_volume.has_bake(), "material change invalidates baked scene signature")
	scene_copy.queue_free()
	await process_frame

	print("MAGIC_GI_PRT_RESULT failures=", _failures)
	quit(1 if _failures > 0 else 0)

func _test_pure_contracts() -> void:
	_check(InspectorPlugin != null, "inspector plugin parses with the PRT diagnostic")
	_check(Volume.BAKE_QUALITY_SAMPLES == [256, 1024, 2048],
			"Draft, Final, and High quality presets have explicit ray counts")
	var default_volume := Volume.new()
	_check(default_volume.bake_samples == 256, "existing numerical bake-sample default remains 256")
	default_volume.free()
	_check(Baker.signature_for_geometry(12345) == Baker.signature_for_geometry(12345)
			and Baker.signature_for_geometry(12345) != 12345,
			"sampler signature is persistent and distinguishes old raw geometry signatures")
	_test_qmc_variance()
	var max_cell: Vector3i = Data.cell_coordinates(Vector3(10.0, 10.0, 10.0), Vector3i(10, 10, 10))
	_check(max_cell == Vector3i(9, 9, 9), "exact positive volume face maps to final cell")
	var legacy := Data.new()
	_check(not legacy.is_valid(), "legacy/default radiance data is stale for PRT v2")
	var image := Image.create(64, 32, false, Image.FORMAT_RGBAF)
	image.fill(Color.BLACK)
	image.set_pixel(12, 16, Color.WHITE)
	var sky_sh: PackedFloat32Array = Lighting.project_panorama(image)
	_check(sky_sh[9] < 0.0 and sky_sh[6] < 0.0,
			"asymmetric panorama projects with Godot's non-mirrored equirectangular axes")
	var env := Environment.new()
	var lighting := Lighting.new()
	lighting._watch_environment(env)
	var previous_signature: int = lighting._environment_signature
	env.background_color = Color(0.1, 0.4, 0.8)
	lighting._watch_environment(env)
	_check(lighting._environment_signature != previous_signature and lighting._sky_dirty,
			"environment property changes invalidate cached sky SH")
	var fake_data := FakeTerrainData.new()
	Placement._watch_object(fake_data)
	var fake_id := fake_data.get_instance_id()
	fake_data.maps_changed.emit()
	fake_data.maps_edited.emit(AABB(Vector3.ZERO, Vector3.ONE))
	_check(Placement._resource_revisions[fake_id] == 2,
			"Terrain3DData Object signals invalidate the lightweight scene fingerprint")
	fake_data.free()

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

func _make_horizontal_plane(extent: float, subdivisions: int, material: Material, y := 0.0) -> ArrayMesh:
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
			vertices.append_array([a, b, c, a, c, d])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
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

func _minimum_same_normal_spacing(placement: RefCounted) -> float:
	var minimum := INF
	for i in placement.positions.size():
		for j in range(i + 1, placement.positions.size()):
			if placement.normals[i].dot(placement.normals[j]) > 0.95:
				minimum = minf(minimum, placement.positions[i].distance_to(placement.positions[j]))
	return minimum

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

func _surface_height_count(placement: RefCounted, volume: Node3D, y: float) -> int:
	var count := 0
	for index in placement.positions.size():
		var surface_y: float = placement.positions[index].y - placement.normals[index].y * volume.surface_offset
		if is_equal_approx(surface_y, y):
			count += 1
	return count

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

func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)
