extends SceneTree

const Data = preload("res://addons/feng-magic-gi/feng_magic_gi_data.gd")
const Directional = preload("res://addons/feng-magic-gi/feng_magic_gi_directional_data.gd")
const DirectionalBaker = preload("res://addons/feng-magic-gi/feng_magic_gi_directional_baker.gd")
const Baker = preload("res://addons/feng-magic-gi/feng_magic_gi_baker.gd")
const EmitterSet = preload("res://addons/feng-magic-gi/feng_magic_gi_emitter_bake_set.gd")
const MaterialSampler = preload("res://addons/feng-magic-gi/feng_magic_gi_material_sampler.gd")
const Clipmap = preload("res://addons/feng-render-pipeline/passes/magic_gi_clv_cache.gd")
const RelightShader = preload("res://addons/feng-render-pipeline/library/magic-gi/magic_gi_directional_relight.glsl")
const U = preload("res://addons/feng-render-pipeline/rd/uniforms.gd")
const Placement = preload("res://addons/feng-magic-gi/feng_magic_gi_placement.gd")
const Volume = preload("res://addons/feng-magic-gi/feng_magic_gi_volume.gd")

class EmptyGeometry extends RefCounted:
	var emitters := EmitterSet.new()
	func trace(_origin: Vector3, _direction: Vector3, _distance: float) -> Dictionary:
		return {}
	func trace_path(_origin: Vector3, _direction: Vector3, _max_distance: float,
			_start_face_index := -1) -> Dictionary:
		return {}
	func trace_emitter_connection(_origin: Vector3, _direction: Vector3,
			_max_distance: float, _start_face_index := -1) -> Dictionary:
		return {}

var failures := 0

func check(condition: bool, description: String) -> void:
	if not condition:
		failures += 1
		push_error(description)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var data := Data.new()
	data.positions = PackedVector3Array([Vector3.ZERO])
	data.directional = Directional.new()
	data.directional.allocate(1, 0)
	DirectionalBaker.bake_probe(data, EmptyGeometry.new(), 0, 4096, 1, 100.0,
		Baker._build_qmc_base_coordinates(4096, 4), PackedFloat32Array([0, 0, 0, 0]), PackedFloat32Array())
	var light := PackedFloat32Array()
	light.resize(27)
	for channel in 3:
		light[channel] = 1.0 / Data.SH_Y00
	var relit: PackedFloat32Array = data.directional.relight(0, light, light, PackedFloat32Array())
	for normal in [Vector3.UP, Vector3.DOWN, Vector3.LEFT, Vector3.RIGHT, Vector3.FORWARD, Vector3.BACK]:
		check(Directional.diffuse_response(relit.slice(27), normal).distance_to(Vector3.ONE) < 0.006,
			"Unoccluded unit sky must return unit diffuse radiance for every normal.")
	check(Directional.diffuse_response(relit.slice(0, 27), Vector3.UP).length() == 0.0,
		"Empty space cannot contain secondary transport.")
	check(ResourceSaver.save(data.directional, "user://directional.res") == OK, "Save directional transport.")
	var restored: Resource = ResourceLoader.load("user://directional.res", "", ResourceLoader.CACHE_MODE_IGNORE)
	check(restored != null and restored.is_valid(1, 0) and restored.sky == data.directional.sky,
		"Binary reload preserves signed directional coefficients.")
	var cache := Clipmap.new()
	cache.queue_updates(Vector3.ZERO, 0.25, 1)
	var initial := drain(cache)
	check(initial.size() == 16 * 16 * 16 * 3, "Initial clipmaps cover exactly three complete grids.")
	cache.queue_updates(Vector3.ZERO, 0.25, 1)
	check(cache.take_jobs(512).is_empty(), "Static camera/lighting does no fill work.")
	cache.queue_updates(Vector3(0.25, 0, 0), 0.25, 1)
	check(drain(cache).size() == 256, "One finest-level cell movement updates only one entering slab.")
	cache.queue_updates(Vector3(0.25, 0, 0), 0.25, 2)
	check(drain(cache).size() == initial.size(), "Lighting epoch invalidates all levels.")
	cache.queue_updates(Vector3(-1000, 3, 500), 0.25, 2)
	var moved := drain(cache)
	check(moved.size() == initial.size(), "Teleport schedules each current cell once.")
	var animated := Clipmap.new()
	var levels_seen: Dictionary = {}
	for epoch in range(1, 60):
		animated.queue_updates(Vector3.ZERO, 0.25, epoch)
		for cell in animated.take_jobs(256):
			levels_seen[cell.w] = true
	check(levels_seen.size() == 3, "Continuous lighting changes cannot starve coarse cascades.")
	cache.queue_updates(Vector3(-999.5, 3.25, 499.75), 0.25, 2)
	var diagonal := drain(cache)
	check(not diagonal.is_empty() and diagonal.size() < initial.size(), "Diagonal scrolling updates entering slabs without a full refill.")
	var material := StandardMaterial3D.new()
	var image := Image.create_empty(2, 1, false, Image.FORMAT_RGB8)
	image.set_pixel(0, 0, Color(0.5, 0, 0))
	image.set_pixel(1, 0, Color(0, 0, 0.5))
	material.albedo_texture = ImageTexture.create_from_image(image)
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	var materials := MaterialSampler.new()
	var index := materials.register(material, true)
	var texel := materials.sample(index, Vector2(0.25, 0.5))
	check(texel.x > 0.20 and texel.x < 0.23 and texel.z == 0.0, "Albedo texels decode sRGB exactly once.")
	check(materials.sample(index, Vector2(1.75, 0.5)).z > 0.20, "Texture repeat preserves UV mapping.")
	check(materials.register(material, false) == -1 and not materials.error_message.is_empty(),
		"Reusing a textured material on a mesh without UVs must still reject the unsupported input.")
	gpu_relight()
	await adaptive_layout()
	print("MAGIC_GI_DIRECTIONAL_RESULT failures=", failures)
	quit(1 if failures else 0)

func drain(cache: RefCounted) -> Dictionary:
	var cells: Dictionary = {}
	while true:
		var jobs: Array = cache.take_jobs(117)
		check(jobs.size() <= 117, "Fill budget must be respected.")
		if jobs.is_empty():
			break
		for job in jobs:
			check(not cells.has(job), "A world cell cannot be scheduled twice.")
			cells[job] = true
	return cells

func gpu_relight() -> void:
	var rd := RenderingServer.create_local_rendering_device()
	check(rd != null, "GPU directional test requires RenderingDevice.")
	if rd == null:
		return
	var data := Directional.new()
	data.allocate(65, 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 28403
	for i in data.transfer.size(): data.transfer[i] = rng.randf_range(-1, 1)
	for i in data.sky.size(): data.sky[i] = rng.randf_range(-1, 1)
	for i in data.emission.size(): data.emission[i] = rng.randf_range(-1, 1)
	var params := PackedFloat32Array()
	params.resize(112)
	for i in 27:
		params[56 + i] = rng.randf_range(-1, 3) * 60000.0
		params[84 + i] = rng.randf_range(-1, 3) * 20000.0
	var sources := PackedFloat32Array([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])
	var buffers: Array[RID] = []
	for values in [data.transfer, data.sky, data.emission, sources]:
		var bytes: PackedByteArray = values.to_byte_array()
		buffers.append(rd.storage_buffer_create(bytes.size(), bytes))
	var ubo := rd.uniform_buffer_create(448, params.to_byte_array())
	var output := rd.storage_buffer_create(65 * 20 * 16)
	var normals := PackedFloat32Array()
	for probe in 65:
		normals.append_array([0.0, 1.0, 0.0, 0.0])
	var normal_buffer := rd.storage_buffer_create(normals.size() * 4, normals.to_byte_array())
	var reference_values := PackedFloat32Array()
	for i in 65 * 8:
		reference_values.append(rng.randf_range(10.0, 1000.0))
	var reference_buffer := rd.storage_buffer_create(reference_values.size() * 4, reference_values.to_byte_array())
	var shader := rd.shader_create_from_spirv(RelightShader.get_spirv())
	var pipeline := rd.compute_pipeline_create(shader)
	var uniforms := rd.uniform_set_create([U.storage_buffer(0, buffers[0]), U.storage_buffer(1, buffers[1]),
		U.storage_buffer(2, buffers[2]), U.storage_buffer(3, buffers[3]), U.uniform_buffer(4, ubo), U.storage_buffer(5, output), U.storage_buffer(6, normal_buffer), U.storage_buffer(7, reference_buffer)], shader, 0)
	var push := PackedInt32Array([65, 2]).to_byte_array()
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	rd.compute_list_bind_uniform_set(list, uniforms, 0)
	rd.compute_list_set_push_constant(list, push, 8)
	rd.compute_list_dispatch(list, (65 + 63) / 64, 1, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	var result := rd.buffer_get_data(output).to_float32_array()
	var maximum_error := 0.0
	for probe in 65:
		var expected := data.relight(probe, params.slice(56, 83), params.slice(84, 111), sources)
		var basis := Directional.basis(Vector3.UP)
		for family in 2:
			for channel in 3:
				var projected := 0.0
				for k in 9:
					var kernel := 1.0 if k == 0 else (2.0 / 3.0 if k < 4 else 0.25)
					projected += expected[family * 27 + k * 3 + channel] * basis[k] * kernel
				expected[family * 27 + channel] += (reference_values[probe * 8 + family * 4 + channel] - projected) / basis[0]
		for k in 18:
			for channel in 3:
				var actual := result[probe * 80 + k * 4 + channel]
				var reference := expected[k * 3 + channel]
				var error := absf(actual - reference) / maxf(1.0, absf(reference))
				maximum_error = maxf(maximum_error, error)
		for family in 2:
			var reference := Directional.diffuse_response(expected.slice(family * 27, (family + 1) * 27), Vector3.UP)
			var actual := Vector3(result[probe * 80 + (18 + family) * 4], result[probe * 80 + (18 + family) * 4 + 1], result[probe * 80 + (18 + family) * 4 + 2]).max(Vector3.ZERO)
			check(actual.distance_to(reference) / maxf(1.0, reference.length()) < 0.002,
				"Surface calibration preserves the independent hemispherical response.")
	check(maximum_error < 0.002, "Directional GPU contraction agrees with CPU reference.")
	print("Directional GPU maximum relative error: ", maximum_error)
	for rid in [uniforms, pipeline, shader, ubo, output, normal_buffer, reference_buffer] + buffers:
		rd.free_rid(rid)
	rd.free()

func adaptive_layout() -> void:
	var scene := Node3D.new()
	root.add_child(scene)
	var volume := Volume.new()
	volume.show_probes = false
	volume.adaptive_placement = true
	volume.minimum_probe_spacing = 0.125
	volume.size = Vector3(4, 4, 4)
	scene.add_child(volume)
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(4, 4)
	floor_mesh.mesh = plane
	scene.add_child(floor_mesh)
	var divider := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.1, 2, 4)
	divider.mesh = box
	divider.position = Vector3(0, 1, 0)
	scene.add_child(divider)
	await process_frame
	var geometry := Placement.new()
	check(geometry.collect(volume, true), "Adaptive thin-wall placement must succeed: " + geometry.error_message)
	check(geometry.probe_spacings.size() == geometry.positions.size(), "Every adaptive probe has a physical spacing.")
	var dense := 0
	var coarse := 0
	for spacing in geometry.probe_spacings:
		if spacing <= 0.25: dense += 1
		if spacing >= 0.5: coarse += 1
	check(dense > 0 and coarse > 0, "Refinement is local; both coarse and dense samples remain.")
	for a in geometry.positions.size():
		for b in range(a):
			var minimum := 0.5 * (geometry.probe_spacings[a] + geometry.probe_spacings[b])
			check(geometry.positions[a].distance_to(geometry.positions[b]) >= minimum * 0.9999,
				"Adaptive probe footprints cannot overlap.")
	var data := Data.new()
	data.adaptive_placement = true
	data.grid_dims = volume.grid_dimensions()
	data.world_to_grid = volume.world_to_grid_transform()
	data.positions = geometry.positions
	data.surface_positions = geometry.surface_positions
	check(data.build_cell_indices(), "Adaptive lookup stores every probe without eight-slot truncation.")
	check(data.cell_indices.size() == geometry.positions.size(), "Sparse lookup retains all probe indices.")
	var repeat := Placement.new()
	check(repeat.collect(volume, true) and repeat.positions == geometry.positions \
		and repeat.probe_spacings == geometry.probe_spacings, "Adaptive placement is deterministic.")
	print("Adaptive layout probes=", geometry.positions.size(), " dense=", dense, " coarse=", coarse)
	scene.queue_free()
	await process_frame
