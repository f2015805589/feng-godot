extends SceneTree

const Visibility = preload("../feng_magic_gi_visibility.gd")
var failures := 0

func check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		failures += 1
		push_error(label)

func _initialize() -> void:
	var faces := PackedVector3Array([
		Vector3(0, -1, -1), Vector3(0, 1, -1), Vector3(0, 1, 1),
		Vector3(0, -1, -1), Vector3(0, 1, 1), Vector3(0, -1, 1)])
	var wall := Visibility.build(faces)
	check(Visibility.validate(wall.nodes, wall.triangles), "zero-thickness wall produces a valid packed BVH")
	check(Visibility.surface_patch(wall.nodes, wall.triangles, Vector3.ZERO) > 0,
			"an anchor on a shared coplanar edge resolves its smooth surface patch")
	check(Visibility.surface_patch(wall.nodes, wall.triangles, Vector3(0.01, 0, 0)) == 0,
			"an anchor away from the mesh cannot authorize a curved surface exception")
	check(wall.triangles[11] > 0 and wall.triangles[11] == wall.triangles[23],
			"shared smooth edge preserves its surface patch through BVH packing")
	var patch_entries: Array[Dictionary] = [
		{"a": Vector3.ZERO, "b": Vector3(0, 0, 1), "c": Vector3(1, 0, 0)},
		{"a": Vector3(1, 0, 0), "b": Vector3(0, 0, 1), "c": Vector3(1, 0, 1)},
		{"a": Vector3(1, 0, 0), "b": Vector3(1, 0, 1), "c": Vector3(2, -0.1, 0)},
		{"a": Vector3.ZERO, "b": Vector3(1, 0, 0), "c": Vector3(0, 1, 0)},
		{"a": Vector3(0, 0.1, 0), "b": Vector3(0, 0.1, 1), "c": Vector3(1, 0.1, 0)},
		{"a": Vector3.ZERO, "b": Vector3(1, 0, 0), "c": Vector3(0, 0, 1)},
	]
	Visibility._assign_surface_patches(patch_entries)
	check(patch_entries[0].patch == patch_entries[1].patch and patch_entries[1].patch == patch_entries[2].patch,
			"surface patches follow connected curvature")
	check(patch_entries[0].patch != patch_entries[3].patch and patch_entries[0].patch != patch_entries[4].patch
			and patch_entries[0].patch != patch_entries[5].patch,
			"sharp walls, disconnected planes and reversed faces stay separate patches")
	check(Visibility.segment_blocked(wall.nodes, wall.triangles,
			Vector3(-0.005, 0, 0), Vector3(0.005, 0, 0)),
			"thin wall rejects a segment across a 1 cm gap, including the shared triangle edge")
	check(Visibility.segment_blocked(wall.nodes, wall.triangles,
			Vector3(0.005, 0, 0), Vector3(-0.005, 0, 0)), "wall blocks both winding directions")
	check(not Visibility.segment_blocked(wall.nodes, wall.triangles,
			Vector3(-0.01, 0, 0), Vector3(-0.01, 0.5, 0)), "open same-plane segment keeps full visibility")
	check(not Visibility.segment_blocked(wall.nodes, wall.triangles,
			Vector3(-1, 2, 0), Vector3(1, 2, 0)), "a segment above the wall stays visible")
	# Both parallel surfaces face +X; the upper surface still separates the lower
	# probe from its receiver even though normal agreement alone would be perfect.
	check(Visibility.segment_blocked(wall.nodes, wall.triangles,
			Vector3(-0.02, 0, 0), Vector3(0.002, 0.2, 0)),
			"same-normal parallel surfaces cannot share a probe through the intervening face")
	check(not Visibility.segment_blocked(wall.nodes, wall.triangles,
			Vector3(-0.02, 0, 0), Vector3(0, 0.2, 0)), "receiver endpoint is not its own blocker")
	check(not Visibility.segment_blocked(wall.nodes, wall.triangles,
			Vector3(-0.02, 0, 0), Vector3(0.000002, 0.9, 0)),
			"grazing same-plane receiver tolerates 2 micrometers of depth reconstruction error")
	check(Visibility.segment_blocked(wall.nodes, wall.triangles,
			Vector3(-0.02, 0, 0), Vector3(0.00002, 0.9, 0)),
			"the normal-distance self-hit tolerance does not skip a separate face 20 micrometers away")
	check(Visibility.segment_blocked(wall.nodes, wall.triangles,
			Vector3(-1, 2, 0), Vector3(1, 2, 0), 0), "exhausted traversal budget fails closed")
	var invalid_nodes: PackedFloat32Array = wall.nodes.duplicate()
	invalid_nodes[3] = 0
	check(not Visibility.validate(invalid_nodes, wall.triangles), "cyclic escape links fail resource validation")
	invalid_nodes = wall.nodes.duplicate()
	invalid_nodes[5] = 0.5
	check(not Visibility.validate(invalid_nodes, wall.triangles),
			"bounds that hide part of a blocker fail validation")

	# Compare a multi-node tree with the engine's independent triangle query. No
	# random ray is chosen near a hit endpoint, so the documented trim is immaterial.
	for step in 24:
		var shift := Vector3(float(step) * 0.2, sin(float(step)), 3.0)
		faces.append_array(PackedVector3Array([
			shift, shift + Vector3(0, 0.8, 0), shift + Vector3(0, 0, 0.7)]))
	var tree := Visibility.build(faces)
	var oracle := TriangleMesh.new()
	oracle.create_from_faces(faces)
	var rng := RandomNumberGenerator.new()
	rng.seed = 942158
	var mismatches := 0
	for sample_index in 1000:
		var origin := Vector3(rng.randf_range(-2, 7), rng.randf_range(-2, 3), rng.randf_range(-2, 5))
		var target := Vector3(rng.randf_range(-2, 7), rng.randf_range(-2, 3), rng.randf_range(-2, 5))
		var expected := not oracle.intersect_segment(origin, target).is_empty()
		if Visibility.segment_blocked(tree.nodes, tree.triangles, origin, target) != expected:
			mismatches += 1
	check(Visibility.validate(tree.nodes, tree.triangles) and mismatches == 0,
			"1,000 multi-node segment results match independent TriangleMesh queries")
	var gap_origin := Vector3(-1, 0, 2)
	var gap_target := Vector3(7, 0, 2)
	check(not Visibility.segment_blocked(tree.nodes, tree.triangles, gap_origin, gap_target)
			and Visibility.segment_blocked(tree.nodes, tree.triangles, gap_origin, gap_target, 1),
			"a traversal truncated after its root cannot grant visibility to an unvisited subtree")
	invalid_nodes = tree.nodes.duplicate()
	invalid_nodes[3] -= 1
	check(not Visibility.validate(invalid_nodes, tree.triangles),
			"an escape link cannot omit a subtree from a persisted blocker tree")
	print("MAGIC_GI_VISIBILITY_RESULT failures=", failures,
		" nodes=", tree.nodes.size() / 8, " triangles=", tree.triangles.size() / 12)
	quit(1 if failures > 0 else 0)
