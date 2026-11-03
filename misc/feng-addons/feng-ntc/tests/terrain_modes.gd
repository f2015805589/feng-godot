extends SceneTree
## Run in the real terrain fixture; all overrides are in memory.
var terrain: Terrain3D

func _init() -> void: _run.call_deferred()
func frames(count: int) -> void:
	for i in range(count): await RenderingServer.frame_post_draw
func fail(message: String) -> void:
	push_error(message); quit(1)

func _run() -> void:
	create_timer(150.0).timeout.connect(fail.bind("Terrain mode switch timed out"))
	var demo: Node3D = load("res://terrain_ntc_demo.tscn").instantiate()
	terrain = demo.get_node("EnvironmentScene/Terrain3D")
	terrain.surface_svt_auto_bake = false
	root.add_child(demo)
	demo.set_process(false)
	var data: Resource = terrain.vt_neural_data
	if data.runtime_storage!=0 or data.decoded_cache_pages!=384:
		fail("Saved scene did not select bounded NTC residency"); return
	for pair: Vector2i in [Vector2i(4,4),Vector2i(4,1),Vector2i(1,4),Vector2i(1,1),Vector2i(4,4)]:
		terrain.surface_vt_compression=pair.x
		terrain.surface_svt_compression=pair.y
		await frames(45)
		var code := RenderingServer.shader_get_code(terrain.material.get_shader_rid())
		var route := "true" if pair==Vector2i(4,4) else ("false" if pair==Vector2i(1,1) else ("tier == 0" if pair.x==4 else "tier == 1"))
		if not code.contains("bool surface_neural_tier(int tier) { return "+route+"; }"):
			fail("Terrain retained stale tier routing after "+str(pair)); return
		print("TERRAIN_SHADER_MODE ",pair)
	for i in range(1200):
		await frames(1)
		var stats: Dictionary=terrain.get_vt_settings().producer
		if int(stats.get("ready_pages",0))>700 and int(stats.get("neural_runtime",{}).get("cache_ready",0))==384 and int(stats.neural_runtime.get("cache_pending",0))==0: break
	var stats: Dictionary=terrain.get_vt_settings().producer
	if int(stats.get("material_bytes",0))!=60 or int(stats.get("neural_runtime",{}).get("cache_ready",0))!=384:
		fail("Returning to NTC did not release the full atlas or restore the cache"); return
	if data.pages.size()!=750: fail("Live resource catalog was modified"); return
	print("TERRAIN_MODE_STATS ",stats.neural_runtime)
	demo.queue_free(); terrain=null; data=null
	await frames(12)
	print("TERRAIN_MODES_PASS"); quit()
