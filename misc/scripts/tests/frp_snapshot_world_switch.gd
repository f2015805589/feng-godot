extends SceneTree
## Registered render targets must follow live World3D changes without recreation.
const Worlds = preload("res://addons/feng-render-pipeline/passes/snapshot_worlds.gd")

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var passed := true
	for reregister in [false, true]:
		var viewport := SubViewport.new()
		viewport.size = Vector2i(16, 16)
		var world_a := World3D.new()
		var world_b := World3D.new()
		viewport.world_3d = world_a
		root.add_child(viewport)
		Worlds.register_viewport(viewport)
		var target := RenderingServer.viewport_get_render_target(viewport.get_viewport_rid())
		if not target.is_valid():
			print("INCONCLUSIVE snapshot world switch: native render target required")
			Worlds.unregister_viewport(viewport)
			viewport.free()
			quit(2)
			return
		var before_a := Worlds.targets_for(world_a)
		var before_b := Worlds.targets_for(world_b)
		viewport.world_3d = world_b
		if reregister:
			Worlds.register_viewport(viewport)
		var after_a := Worlds.targets_for(world_a)
		var after_b := Worlds.targets_for(world_b)
		var forward_ok := before_a.has(target) and not before_b.has(target) and not after_a.has(target) and after_b.has(target)
		print("WORLD_SWITCH reregister=", reregister, " before=", before_a.has(target), "/", before_b.has(target), " after=", after_a.has(target), "/", after_b.has(target))
		passed = forward_ok and passed
		viewport.world_3d = world_a
		passed = Worlds.targets_for(world_a).has(target) and not Worlds.targets_for(world_b).has(target) and passed
		var stable_version: int = Worlds._targets_version
		Worlds.targets_for(world_a)
		Worlds.targets_for(world_b)
		passed = Worlds._targets_version == stable_version and passed
		root.remove_child(viewport)
		passed = not Worlds.targets_for(world_a).has(target) and passed
		root.add_child(viewport)
		passed = Worlds.targets_for(world_a).has(target) and passed
		Worlds.unregister_viewport(viewport)
		passed = not Worlds.targets_for(world_a).has(target) and passed
		viewport.free()
	# An inherited world can change without assigning anything on the registered
	# child viewport itself. Freeing its parent must remove the weak registration.
	var parent_view := SubViewport.new()
	parent_view.size = Vector2i(16, 16)
	var inherited_a := World3D.new()
	var inherited_b := World3D.new()
	parent_view.world_3d = inherited_a
	root.add_child(parent_view)
	var child_view := SubViewport.new()
	child_view.size = Vector2i(16, 16)
	parent_view.add_child(child_view)
	Worlds.register_viewport(child_view)
	var child_id := child_view.get_instance_id()
	var child_target := RenderingServer.viewport_get_render_target(child_view.get_viewport_rid())
	passed = child_view.find_world_3d() == inherited_a and Worlds.targets_for(inherited_a).has(child_target) and passed
	Worlds.targets_for(inherited_b)
	parent_view.world_3d = inherited_b
	passed = child_view.find_world_3d() == inherited_b and not Worlds.targets_for(inherited_a).has(child_target) and Worlds.targets_for(inherited_b).has(child_target) and passed
	parent_view.free()
	passed = not Worlds.viewports().has(child_id) and not Worlds.targets_for(inherited_b).has(child_target) and passed
	if not passed:
		push_error("REGRESSION: snapshot target cache retained an outdated viewport/world binding")
		quit(1)
	else:
		print("PASS FRP snapshot target cache follows live/inherited world switches, detach/reenter and weak removal")
		quit(0)
