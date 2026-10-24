extends SceneTree
## CPU contract for the camera-centered, paged prepared CLV layout.
## Run with --headless; no source payload arrays or RenderingDevice are needed.

const Layout = preload("../../feng-magic-gi/feng_magic_gi_prepared_clip_layout.gd")
const Header = preload("../../feng-magic-gi/feng_magic_gi_prepared_source_header.gd")
const RADIUS_M := 512.0
const EPSILON := 0.0001

var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)

func _header(bounds: AABB, levels: int) -> Resource:
	var result := Header.new()
	result.domain_bounds_world = bounds
	result.origin_world = bounds.position + Vector3.ONE * 0.125
	result.dimensions = Vector3i((bounds.size / 0.25).ceil())
	result.source_size_m = bounds.size
	result.prepared_level_count = levels
	result.directional_source_signature = "paged-clv-layout-cpu-fixture"
	for level in levels:
		var dims := Vector3i((Vector3(result.dimensions) / float(1 << level)).ceil())
		result.clv_prepared_dimensions.append_array(PackedInt32Array([dims.x, dims.y, dims.z]))
	return result

func _contains_closed(bounds: AABB, point: Vector3) -> bool:
	for axis in 3:
		if point[axis] < bounds.position[axis] - EPSILON \
				or point[axis] > bounds.end[axis] + EPSILON:
			return false
	return true

func _check_sphere_coverage(layout: Dictionary, camera: Vector3, label: String) -> void:
	check(bool(layout.get("valid", false)), "%s: layout is valid" % label)
	if not bool(layout.get("valid", false)):
		return
	var coarsest: Dictionary = layout.lods[-1]
	var bounds: AABB = coarsest.clip_bounds_world
	# A convex axis-aligned sample box covers the complete sphere iff it covers
	# all six axis extrema. Check the real sample centers, not the cell-box halo.
	for axis in 3:
		for sign_value in [-1.0, 1.0]:
			var receiver := camera
			receiver[axis] += sign_value * RADIUS_M
			check(_contains_closed(bounds, receiver),
				"%s: sphere axis %d sign %s stays within sample centers" % [label, axis, sign_value])

func _test_large_world(header: Resource) -> void:
	var center: Vector3 = header.origin_world + Vector3.ONE * 1024.0
	for resolution in [16, 24, 32]:
		var expected_levels := 10 if resolution == 16 else 9
		var baseline: Dictionary = Layout.build(header, center, resolution, RADIUS_M)
		check(bool(baseline.get("valid", false)), "R%d large-world layout is valid" % resolution)
		if not bool(baseline.get("valid", false)):
			continue
		check(baseline.level_count == expected_levels
				and baseline.required_level_count == expected_levels,
			"R%d uses the required guarded 512m level count" % resolution)
		check(baseline.dimensions == Vector3i(resolution, resolution, resolution * expected_levels),
			"R%d publishes the actual resident dimensions" % resolution)
		check(baseline.dimensions.z * 7 <= 2048,
			"R%d packed seven-field texture stays within the 3D depth limit" % resolution)
		check(baseline.resident_capacity == resolution * resolution * resolution * expected_levels,
			"R%d reports the complete bounded resident capacity" % resolution)
		check(baseline.anchor_world == center,
			"large-world windows center on the camera rather than the source center")
		var coarse_spacing: float = baseline.lods[-1].spacing_m
		# Exercise both signs, both sides of a quantization tie, and exact half
		# cells. Previous state tests the tie's stable side as well as cold snaps.
		for offset_cells in [-1.5001, -1.5, -1.4999, -0.5, 0.0, 0.5, 1.4999, 1.5, 1.5001]:
			var camera: Vector3 = center + Vector3.ONE * coarse_spacing * offset_cells
			var cold: Dictionary = Layout.build(header, camera, resolution, RADIUS_M)
			var warm: Dictionary = Layout.build(header, camera, resolution, RADIUS_M, baseline.state)
			_check_sphere_coverage(cold, camera, "R%d cold snap %s" % [resolution, offset_cells])
			_check_sphere_coverage(warm, camera, "R%d warm snap %s" % [resolution, offset_cells])
			if bool(warm.get("valid", false)):
				var repeat: Dictionary = Layout.build(header, camera, resolution, RADIUS_M, warm.state)
				check(repeat.state == warm.state,
					"R%d repeated half-cell state cannot alternate" % resolution)
		# The public input is position only: turning a camera transform must keep
		# every cascade origin and selected LOD identical.
		for rotation in [Vector3.ZERO, Vector3(0.0, PI, 0.0),
				Vector3(PI * 0.5, 0.0, 0.0), Vector3(-0.8, 1.7, 0.4)]:
			var view := Transform3D(Basis.from_euler(rotation), center)
			var turned: Dictionary = Layout.build(header, view.origin, resolution, RADIUS_M, baseline.state)
			check(turned.state == baseline.state and turned.lods == baseline.lods,
				"R%d camera rotation preserves all resident windows" % resolution)
		for axis in 3:
			for sign_value in [-1, 1]:
				var delta := Vector3.ZERO
				delta[axis] = 0.25 * sign_value
				var shifted: Dictionary = Layout.build(header, center + delta, resolution, RADIUS_M, baseline.state)
				var index_delta := Vector3i.ZERO
				index_delta[axis] = sign_value
				check(shifted.lods[0].origin_world.is_equal_approx(baseline.lods[0].origin_world + delta)
						and shifted.lods[0].logical_origin_source_index == baseline.lods[0].logical_origin_source_index + index_delta,
					"R%d one-cell translation moves the fine lattice by exactly one cell" % resolution)
				for level in range(1, expected_levels):
					check(shifted.lods[level] == baseline.lods[level],
						"R%d one fine-cell move preserves coarser level %d at its tie" % [resolution, level])

func _test_small_domain() -> void:
	var header := _header(AABB(Vector3(-2.0, -1.0, -2.0), Vector3(4.0, 2.0, 4.0)), 4)
	check(header.is_header_valid(), "legacy four-level small-domain header remains valid")
	var camera := Vector3(0.0, 0.0, 8.0)
	for resolution in [16, 24, 32]:
		var layout: Dictionary = Layout.build(header, camera, resolution, RADIUS_M)
		check(bool(layout.get("valid", false)) and layout.level_count == 4,
			"R%d old small domains retain four available LODs" % resolution)
		if not bool(layout.get("valid", false)):
			continue
		var expected_anchor := Vector3(0.0, 0.0, resolution * 0.125 - 2.0)
		check(layout.anchor_world.is_equal_approx(expected_anchor),
			"R%d outside-camera fit preserves the existing room anchor" % resolution)
		check(_contains_closed(layout.lods[0].clip_bounds_world, Vector3(0.0, 0.0, header.origin_world.z)),
			"R%d room's rear source sample stays in the fine sample window" % resolution)
		for level in 4:
			check(layout.lods[level].spacing_m == 0.25 * (1 << level),
				"legacy small-domain cascade spacing remains unchanged")

func _test_sphere_page_selection() -> void:
	var camera := Vector3(-17.25, 6.125, 39.5)
	check(Layout.intersects_sphere(AABB(camera - Vector3.ONE, Vector3.ONE * 2.0), camera, RADIUS_M),
		"a page containing the camera intersects its resident sphere")
	for axis in 3:
		for sign_value in [-1.0, 1.0]:
			var position := camera - Vector3.ONE
			position[axis] = camera[axis] + (RADIUS_M if sign_value > 0 else -RADIUS_M - 2.0)
			var tangent := AABB(position, Vector3.ONE * 2.0)
			check(Layout.intersects_sphere(tangent, camera, RADIUS_M),
				"axis %d sign %s boundary-touching page is retained" % [axis, sign_value])
			var outside := tangent
			outside.position[axis] += sign_value * 0.25
			check(not Layout.intersects_sphere(outside, camera, RADIUS_M),
				"axis %d sign %s wholly exterior page is excluded" % [axis, sign_value])
			var crossing := tangent
			crossing.position[axis] -= sign_value * 0.25
			check(Layout.intersects_sphere(crossing, camera, RADIUS_M),
				"axis %d sign %s sphere-crossing page is retained" % [axis, sign_value])
	check(not Layout.intersects_sphere(AABB(camera + Vector3.ONE * 400.0, Vector3.ONE * 8.0), camera, RADIUS_M),
		"a diagonal page inside the bounding cube but outside the sphere is excluded")

func run() -> void:
	check(RenderingServer.get_rendering_device() == null, "paged CLV tests run without a GPU device")
	var header := _header(AABB(Vector3.ONE * -1024.0, Vector3.ONE * 2048.0), 10)
	check(header.is_header_valid(), "ten-level metadata header validates without world-sized payloads")
	check(header.clv_prepared_dimensions.size() == 30,
		"header records all ten prepared level dimensions")
	_test_large_world(header)
	_test_small_domain()
	_test_sphere_page_selection()
	for resolution in [0, 15, 17, 23, 25, 31, 33, 64]:
		check(not Layout.build(header, Vector3.ZERO, resolution, RADIUS_M).valid,
			"unsupported prepared resolution is rejected")
	for radius in [0.0, -1.0, NAN, INF]:
		check(not Layout.build(header, Vector3.ZERO, 16, radius).valid,
			"nonpositive or nonfinite radius is rejected")
	for camera in [Vector3(NAN, 0.0, 0.0), Vector3(0.0, INF, 0.0)]:
		check(not Layout.build(header, camera, 16, RADIUS_M).valid,
			"nonfinite camera position is rejected")
	check(not Layout.build(null, Vector3.ZERO, 16, RADIUS_M).valid,
		"missing prepared metadata is rejected")
	var saved_dimensions: PackedInt32Array = header.clv_prepared_dimensions.duplicate()
	header.clv_prepared_dimensions.resize(12)
	check(not header.is_header_valid() and not Layout.build(header, Vector3.ZERO).valid,
		"ten-level metadata cannot silently use only the old four dimension entries")
	header.clv_prepared_dimensions = saved_dimensions
	header.prepared_level_count = 11
	check(not header.is_header_valid() and not Layout.build(header, Vector3.ZERO).valid,
		"metadata beyond the ten-level ABI is rejected")
	print("PAGED_CLV_LAYOUT checks=%d failures=%d" % [checks, failures])
	quit(1 if failures else 0)
