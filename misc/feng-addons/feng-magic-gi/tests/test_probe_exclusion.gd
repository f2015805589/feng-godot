extends SceneTree
const Volume = preload("../feng_magic_gi_volume.gd")
const Exclusion = preload("../feng_magic_gi_probe_exclusion.gd")
const Baker = preload("../feng_magic_gi_volume_source_baker.gd")
const Chunk = preload("../feng_magic_gi_volume_source_chunk.gd")
const Paged = preload("../feng_magic_gi_paged_source_baker.gd")
const Tracker = preload("../feng_magic_gi_scene_tracker.gd")
const Payload = preload("../feng_magic_gi_olv_probe_domain_payload.gd")
var checks := 0
var failures := 0
class EmptyGeometry:
	extends RefCounted
	var queried := PackedVector3Array()
	func point_is_inside_or_ambiguous_solid(point: Vector3) -> bool:
		queried.append(point)
		return false
func _initialize() -> void: call_deferred("run")
func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(message)
func run() -> void:
	var scene := Node3D.new()
	root.add_child(scene)
	current_scene = scene
	var volume := Volume.new()
	volume.show_probes = false
	volume.size = Vector3.ONE
	volume.clv_cell_size = 0.25
	volume.bake_samples = 1
	volume.bake_bounces = 1
	volume.bake_distance = 2.0
	scene.add_child(volume)
	var baseline := Baker.settings_signature(volume,false)
	var exclusion := Exclusion.new()
	exclusion.size = Vector3(1,2,2)
	exclusion.position.x = 0.5
	volume.add_child(exclusion)
	var captured := Exclusion.capture(volume)
	check(Baker.settings_signature(volume,false) != baseline,"Adding an exclusion changes the bake fingerprint")
	check(Exclusion.contains(Vector3(0.1,0,0),captured) and not Exclusion.contains(Vector3(-0.1,0,0),captured),"Only the intersecting half is excluded")
	var signature := Tracker.stable_scene_signature(volume)
	exclusion.position.x += 0.1
	check(signature != Tracker.stable_scene_signature(volume),"Moving an exclusion invalidates an in-flight bake")
	exclusion.position.x -= 0.1
	exclusion.enabled = false
	check(Baker.settings_signature(volume,false) == baseline,"Disabling the exclusion restores the ordinary signature")
	exclusion.enabled = true
	for spacing in [0.1,0.25,0.5,1.0,5.0]:
		volume.size = Vector3.ONE*spacing*4
		exclusion.size = Vector3(4,8,8)*spacing
		exclusion.position = Vector3(2,0,0)*spacing
		volume.rotation.y = 0.31
		var bounds: AABB = volume.global_transform*AABB(-volume.size*0.5,volume.size)
		var source := Chunk.new()
		source.allocate(Vector3i((bounds.size/spacing).ceil()),PackedStringArray())
		source.spacing_m = spacing
		source.origin_world = bounds.position+Vector3.ONE*spacing*0.5
		source.probe_exclusions = Exclusion.capture(volume)
		var geometry := EmptyGeometry.new()
		check(Baker.new()._classify_cells(source,volume,geometry,Callable(),Callable()),"Classification completes at spacing "+str(spacing))
		var removed := 0
		var kept := 0
		for i in source.probe_count:
			if Exclusion.contains(source.cell_position(i),source.probe_exclusions):
				removed += 1
				check(not source.cell_is_valid(i),"Excluded point is never created")
			elif source.cell_is_valid(i): kept += 1
		check(removed > 0 and kept > 0,"Partial overlap preserves outside Probes at every density")
		for point in geometry.queried:
			check(not Exclusion.contains(point,source.probe_exclusions),"Excluded cells skip geometry classification entirely")
	volume.rotation = Vector3.ZERO
	volume.size = Vector3.ONE
	exclusion.position = Vector3(0.5,0,0)
	exclusion.size = Vector3(1,2,2)
	var floor_mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(2,0.1,2)
	floor_mesh.mesh = box
	floor_mesh.position.y = -0.7
	scene.add_child(floor_mesh)
	await process_frame
	var result: Dictionary = await Baker.new().bake_async(volume)
	check(bool(result.get("ok",false)),"Ordinary source bake: "+str(result.get("error","")))
	if result.get("ok",false):
		var source: Resource = result.chunk
		check(source.valid_cell_count() == 32 and source.source_storage_count == 32,"Excluded half has no stored transport samples")
		check(Payload.source_binding(source).get("ok",false),"OLV accepts the reduced valid layout")
		for i in source.probe_count:
			if Exclusion.contains(source.cell_position(i),source.probe_exclusions):
				check(not source.cell_is_valid(i) and source.storage_index(i) == -1,"Excluded logical slots have no transport payload")
		for level in 4:
			var dims := Vector3i(source.clv_prepared_dimensions[level*3],source.clv_prepared_dimensions[level*3+1],source.clv_prepared_dimensions[level*3+2])
			for z in dims.z:
				for y in dims.y:
					for x in dims.x:
						var world: Vector3 = source.origin_world+Vector3(x,y,z)*source.spacing_m*float(1<<level)
						var index: int = source.clv_prepared_offsets[level]+(z*dims.y+y)*dims.x+x
						if Exclusion.contains(world,source.probe_exclusions): check(source.clv_prepared_validity[index] == 0,"CLV does not refill the excluded region")
	var output := "res://.godot/feng-olv-tests/exclusions"
	result = await Paged.new().bake_async(volume,str(Time.get_ticks_usec()),output,{"prepared_levels":3,"core_axis":2})
	check(bool(result.get("ok",false)),"Paged multi-LOD bake: "+str(result.get("error","")))
	if result.get("ok",false):
		var manifest: Resource = result.manifest
		volume.bake_manifest = manifest
		var loaded: Dictionary = volume._load_active_source_page()
		check(loaded.get("ok",false),"Independent OLV loads the paged exclusion layout")
		if loaded.get("ok",false):
			var source: Resource = loaded.source
			for i in source.probe_count:
				if Exclusion.contains(source.cell_position(i),source.probe_exclusions): check(not source.cell_is_valid(i),"No LOD reintroduces excluded Probes")
		for entry in manifest.page_entries:
			var page: Resource = load(entry.resource_path)
			var brick: Resource = page.prepared_transfer_brick
			for z in brick.dimensions.z:
				for y in brick.dimensions.y:
					for x in brick.dimensions.x:
						var cell: Vector3i = brick.cell_origin+Vector3i(x,y,z)
						if Exclusion.contains(brick.cell_position(cell),Exclusion.capture(volume)):
							check(brick.validity[brick.cell_index(cell)] == 0,"Paged halo interpolation preserves holes")
		exclusion.position.x -= 0.1
		check(not volume._load_active_source_page().get("ok",false),"OLV refuses a stale layout after exclusion changes")
	print("PROBE_EXCLUSION_RESULT ",JSON.stringify({"checks":checks,"failures":failures}))
	scene.queue_free()
	await process_frame
	quit(1 if failures else 0)
