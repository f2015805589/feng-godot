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
		var signal_enabled := viewport.has_signal("world_3d_changed")
		var initial_bucket_a := Worlds.viewports_for_world(world_a)
		var initial_bucket_b := Worlds.viewports_for_world(world_b)
		var before_a := Worlds.targets_for(world_a)
		var before_b := Worlds.targets_for(world_b)
		passed = initial_bucket_a.has(viewport.get_instance_id()) \
				and not initial_bucket_b.has(viewport.get_instance_id()) and passed
		viewport.world_3d = world_b
		if reregister:
			Worlds.register_viewport(viewport)
		var after_a := Worlds.targets_for(world_a)
		var after_b := Worlds.targets_for(world_b)
		var moved_bucket_a := Worlds.viewports_for_world(world_a)
		var moved_bucket_b := Worlds.viewports_for_world(world_b)
		var forward_ok := before_a.has(target) and not before_b.has(target) and not after_a.has(target) and after_b.has(target)
		forward_ok = forward_ok and not moved_bucket_a.has(viewport.get_instance_id()) \
				and moved_bucket_b.has(viewport.get_instance_id())
		print("WORLD_SWITCH reregister=", reregister, " signal=", signal_enabled,
				" before=", before_a.has(target), "/", before_b.has(target),
				" after=", after_a.has(target), "/", after_b.has(target))
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
		var unchanged_generation := Worlds.generation_for_world(world_a)
		var unchanged_version: int = Worlds._targets_version
		Worlds.targets_for(world_a)
		Worlds.generation_for_world(world_a)
		passed = Worlds.generation_for_world(world_a) == unchanged_generation \
				and Worlds._targets_version == unchanged_version and passed
		Worlds.unregister_viewport(viewport)
		passed = not Worlds.targets_for(world_a).has(target) and passed
		viewport.free()
	# Independent owner leases retain one route until the last owner releases it.
	var leased_viewport := SubViewport.new()
	leased_viewport.size = Vector2i(16, 16)
	var leased_world := World3D.new()
	leased_viewport.world_3d = leased_world
	root.add_child(leased_viewport)
	var owner_a := RefCounted.new()
	var owner_b := RefCounted.new()
	Worlds.register_viewport(leased_viewport, owner_a)
	Worlds.register_viewport(leased_viewport, owner_b)
	var leased_target := RenderingServer.viewport_get_render_target(leased_viewport.get_viewport_rid())
	Worlds.unregister_viewport(leased_viewport, owner_a)
	passed = Worlds.targets_for(leased_world).has(leased_target) and passed
	Worlds.unregister_viewport(leased_viewport, owner_b)
	passed = not Worlds.targets_for(leased_world).has(leased_target) and passed
	leased_viewport.free()
	# RefCounted leases are weak: a world query validates the requested bucket
	# immediately instead of returning a stale cached generation/target.
	var weak_viewport := SubViewport.new()
	weak_viewport.size = Vector2i(16, 16)
	var weak_world := World3D.new()
	weak_viewport.world_3d = weak_world
	root.add_child(weak_viewport)
	var transient_owner := RefCounted.new()
	var owner_weak: WeakRef = weakref(transient_owner)
	Worlds.register_viewport(weak_viewport, transient_owner)
	var weak_target := RenderingServer.viewport_get_render_target(weak_viewport.get_viewport_rid())
	transient_owner = null
	passed = owner_weak.get_ref() == null and passed
	Worlds.generation_for_world(weak_world)
	passed = not Worlds.targets_for(weak_world).has(weak_target) and passed
	weak_viewport.free()
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
	# Reparenting between differently-worlded parents updates the route without
	# requiring producer re-registration, even when the new world is queried first.
	var parent_view_c := SubViewport.new()
	parent_view_c.size = Vector2i(16, 16)
	var inherited_c := World3D.new()
	parent_view_c.world_3d = inherited_c
	root.add_child(parent_view_c)
	parent_view.remove_child(child_view)
	parent_view_c.add_child(child_view)
	passed = child_view.find_world_3d() == inherited_c \
			and Worlds.targets_for(inherited_c).has(child_target) \
			and not Worlds.targets_for(inherited_b).has(child_target) and passed
	child_view.free()
	parent_view.free()
	parent_view_c.free()
	passed = not Worlds.viewports().has(child_id) \
			and not Worlds.targets_for(inherited_c).has(child_target) and passed
	if not passed:
		push_error("REGRESSION: snapshot target cache retained an outdated viewport/world binding")
		quit(1)
	else:
		print("PASS FRP snapshot target cache follows live/inherited world switches, detach/reenter and weak removal")
		quit(0)
