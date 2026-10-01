extends SceneTree
const Registry = preload("res://addons/feng-sky/feng_sky_light_registry.gd")
const Fog = preload("res://addons/feng-fog/feng_height_fog.gd")
const FogRuntime = preload("res://addons/feng-fog/feng_fog_runtime.gd")
var failed := false
func _initialize() -> void:
	call_deferred("run")
func require(value: bool, message: String) -> void:
	if not value:
		failed = true
		push_error("REGRESSION: " + message)
func run() -> void:
	var scene := Node3D.new()
	root.add_child(scene)
	for i in 5000:
		scene.add_child(Node3D.new())
	var first := DirectionalLight3D.new()
	scene.add_child(first)
	var registry := Registry.new()
	registry.attach(self)
	var world := scene.get_world_3d()
	require(registry.resolve(world) == first, "existing sun was not seeded")
	var second := DirectionalLight3D.new()
	scene.add_child(second)
	require(registry.resolve(world) == first, "first scene-order sun changed on insertion")
	require(registry.resolve(world, first) == second, "secondary exclusion failed")
	first.hide()
	require(registry.resolve(world) == second, "hidden sun did not switch immediately")
	first.show()
	require(registry.resolve(world) == first, "shown sun did not restore immediately")
	first.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	require(registry.resolve(world) == second, "light-only sun selected")
	first.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_AND_SKY
	scene.move_child(second, 0)
	require(registry.resolve(world) == second, "scene reorder ignored")
	var viewport := SubViewport.new()
	viewport.own_world_3d = true
	root.add_child(viewport)
	second.reparent(viewport)
	require(registry.resolve(world) == first, "foreign-world light selected")
	require(registry.resolve(viewport.find_world_3d()) == second, "reparented light missing")
	second.free()
	require(registry.resolve(viewport.find_world_3d()) == null, "freed light retained")
	var costs: Array[int] = []
	for i in 100:
		var start := Time.get_ticks_usec()
		require(registry.resolve(world) == first, "stable selection failed")
		costs.append(Time.get_ticks_usec() - start)
	costs.sort()
	require(registry.seed_scan_count == 1, "steady selection traversed the tree again")
	print("LIGHT REGISTRY nodes=5000 samples=100 median_usec=", costs[50], " p95_usec=", costs[95], " seed_scans=", registry.seed_scan_count)

	var fog := Fog.new()
	scene.add_child(fog)
	require(FogRuntime._sun_for(fog, world) == first, "fog auto-sun discovery failed")
	first.hide()
	require(FogRuntime._sun_for(fog, world) == null, "fog cached hidden light")
	first.show()
	fog.sun_light = first
	first.reparent(viewport)
	require(FogRuntime._sun_for(fog, world) == null, "fog accepted explicit foreign-world light")
	first.reparent(scene)
	require(FogRuntime._sun_for(fog, world) == first, "fog explicit sun reparent recovery failed")
	fog.free()
	require(FogRuntime._scene_lights.is_empty(), "fog registry retained nodes after final owner left")
	registry.detach()
	require(registry.resolve(world) == null, "detached registry retained candidates")
	registry.attach(self)
	require(registry.resolve(world) == first, "reattach failed")
	registry.detach()
	viewport.free()
	scene.free()
	if not failed:
		print("SKY LIGHT REGISTRY PASS")
	quit(1 if failed else 0)
