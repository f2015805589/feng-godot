extends SceneTree
## Native render-target routes require a RenderingDevice renderer.

const Routes = preload("res://addons/feng-render-pipeline/passes/snapshot_worlds.gd")
var failures := 0


func require(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error("REGRESSION: " + message)


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	if RenderingServer.get_rendering_device() == null:
		require(false, "SkyLight routing requires a RenderingDevice renderer")
		quit(1)
		return
	var world_a := World3D.new()
	var world_b := World3D.new()
	var a := SubViewport.new()
	var b := SubViewport.new()
	a.size = Vector2i(32, 32)
	b.size = Vector2i(32, 32)
	a.world_3d = world_a
	b.world_3d = world_b
	root.add_child(a)
	root.add_child(b)
	var light := FengSkyLight.new()
	light.enabled = false
	a.add_child(light)
	light.set_process(false)
	Routes.scan(root, self)
	light._provider_active = true
	light._native_radiance_ready = true
	light._native_radiance_revision = 1
	light._sync_frp_sources()
	var target_a := RenderingServer.viewport_get_render_target(a.get_viewport_rid())
	var target_b := RenderingServer.viewport_get_render_target(b.get_viewport_rid())
	require(light._registered_targets == [target_a], "SkyLight routed into a foreign world")
	b.world_3d = a.world_3d
	light._sync_frp_sources()
	require(light._registered_targets.size() == 2 and light._registered_targets.has(target_b), "New same-world viewport was not registered with an unchanged source signature")
	b.world_3d = world_b
	light._native_radiance_ready = false
	light._sync_frp_sources()
	require(light._registered_targets == [target_a], "Stale SkyLight route survived while replacement radiance was pending")
	light._native_radiance_ready = true
	b.world_3d = a.world_3d
	light._sync_frp_sources()
	require(light._registered_targets.size() == 2, "Returned viewport was not registered again")
	light._deactivate_provider()
	require(light._registered_targets.is_empty(), "Deactivated provider retained native routes")
	Routes.unregister_owner(self)
	a.free()
	b.free()
	print("SKY LIGHT ROUTES PASS" if failures == 0 else "SKY LIGHT ROUTES FAIL")
	quit(0 if failures == 0 else 1)
