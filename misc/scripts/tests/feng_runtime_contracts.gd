extends SceneTree
## Main-thread addon seams. No native render target, GPU or baked geometry needed.
const Worlds = preload("res://addons/feng-render-pipeline/passes/snapshot_worlds.gd")
const FogRuntime = preload("res://addons/feng-fog/feng_fog_runtime.gd")
const GIRuntime = preload("res://addons/feng-magic-gi/feng_magic_gi_runtime.gd")
const Lighting = preload("res://addons/feng-magic-gi/feng_magic_gi_lighting.gd")
const Data = preload("res://addons/feng-magic-gi/feng_magic_gi_data.gd")

class VolumeStub extends Node3D:
	var sun: DirectionalLight3D
	var lighting_environment: Environment

var _failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, label: String) -> void:
	if not condition:
		_failures += 1
		push_error("REGRESSION: " + label)

func _registered(viewport: Viewport) -> bool:
	return Worlds.viewports().has(viewport.get_instance_id())

func _run() -> void:
	_test_registry()
	_test_debanding()
	_test_lighting()
	print("FENG_RUNTIME_CONTRACTS failures=", _failures,
			" physical=", ProjectSettings.get_setting("rendering/lights_and_shadows/use_physical_light_units", false))
	quit(0 if _failures == 0 else 1)

func _test_registry() -> void:
	var viewport := SubViewport.new()
	root.add_child(viewport)
	var owner_a := RefCounted.new()
	var owner_b := RefCounted.new()
	Worlds.register_viewport(viewport, owner_a)
	var version: int = Worlds._targets_version
	Worlds.register_viewport(viewport, owner_a)
	Worlds.register_viewport(viewport, owner_b)
	_check(Worlds._targets_version == version, "duplicate/second-owner registration does not invalidate target cache")
	Worlds.unregister_viewport(viewport, owner_a)
	_check(_registered(viewport), "one producer cannot remove another producer's viewport")
	_check(Worlds._targets_version == version, "partial owner release keeps target cache valid")
	Worlds.unregister_viewport(viewport, owner_b)
	_check(not _registered(viewport), "last owner release removes the viewport")
	_check(Worlds._targets_version == version + 1, "last owner release invalidates target cache exactly once")
	Worlds.register_viewport(viewport)
	Worlds.register_viewport(viewport)
	Worlds.register_viewport(viewport, owner_a)
	Worlds.unregister_viewport(viewport)
	_check(_registered(viewport), "legacy unregister cannot remove an explicit owner")
	Worlds.unregister_owner(owner_a)
	_check(not _registered(viewport), "legacy registration remains idempotent")
	Worlds.register_viewport(viewport, owner_a)
	owner_a = null
	_check(not _registered(viewport), "expired weak owners are pruned without freeing the viewport")
	var child := SubViewport.new()
	viewport.add_child(child)
	Worlds.scan(viewport, owner_b)
	_check(_registered(viewport) and _registered(child), "subtree scanning uses its producer's owner")
	Worlds.unregister_owner(owner_b)
	_check(not _registered(viewport) and not _registered(child), "owner exit releases all scanned viewports")
	for fog_first in [true, false]:
		FogRuntime.register_viewport(viewport)
		GIRuntime.register_viewport(viewport)
		if fog_first:
			FogRuntime.unregister_viewport(viewport)
		else:
			GIRuntime.unregister_viewport(viewport)
		_check(_registered(viewport), "default runtime leases survive the other addon unregistering")
		if fog_first:
			GIRuntime.unregister_viewport(viewport)
		else:
			FogRuntime.unregister_viewport(viewport)
		_check(not _registered(viewport), "both runtime leases are released independently")
	Worlds.register_viewport(child, owner_b)
	var child_id := child.get_instance_id()
	viewport.free()
	_check(not Worlds.viewports().has(child_id), "freed viewport and its owner table are pruned")
	_check(not Worlds._viewport_owners.has(child_id), "owner metadata does not outlive the viewport")

func _test_debanding() -> void:
	for shared in [false, true]:
		var viewport := SubViewport.new()
		viewport.own_world_3d = true
		viewport.use_debanding = false
		root.add_child(viewport)
		if shared:
			GIRuntime.register_viewport(viewport)
		var fog := FengHeightFog.new()
		viewport.add_child(fog)
		FogRuntime.publish(fog)
		_check(viewport.use_debanding, "active fog enables output debanding")
		fog.free()
		_check(not viewport.use_debanding, "fog exit restores debanding after its owned viewport lease disappears")
		_check(_registered(viewport) == shared, "fog node exit preserves only other live producers")
		if shared:
			GIRuntime.unregister_viewport(viewport)
		viewport.free()

func _test_lighting() -> void:
	var scene := Node3D.new()
	root.add_child(scene)
	var red := DirectionalLight3D.new()
	red.light_color = Color.RED
	red.light_intensity_lux = 60000.0
	scene.add_child(red)
	var green := DirectionalLight3D.new()
	green.light_color = Color.GREEN
	green.light_intensity_lux = 60000.0
	scene.add_child(green)
	var volume := VolumeStub.new()
	scene.add_child(volume)
	var lighting := Lighting.new()
	volume.sun = red
	var first := lighting.coefficients(volume)
	_check(first[0] > 0.0 and first[1] == 0.0, "explicit red sun selects only its own SH source")
	volume.sun = green
	var second := lighting.coefficients(volume)
	_check(second[0] == 0.0 and second[1] > 0.0, "switching to an already-scanned green sun invalidates direct SH")
	volume.sun = null
	var combined := lighting.coefficients(volume)
	_check(combined[0] > 0.0 and combined[1] > 0.0, "clearing the explicit sun restores all scanned lights")
	volume.sun = red
	red.light_color = Color.WHITE
	red.light_temperature = 6500.0
	var neutral := lighting.coefficients(volume)
	red.light_temperature = 2000.0
	var warm := lighting.coefficients(volume)
	var physical := bool(ProjectSettings.get_setting("rendering/lights_and_shadows/use_physical_light_units", false))
	var expected_color := red.light_color.srgb_to_linear()
	var expected_energy := red.light_energy * red.light_indirect_energy
	if physical:
		expected_color *= red.get_correlated_color().srgb_to_linear()
		expected_energy *= red.light_intensity_lux
		_check(warm != neutral and warm[0] > warm[1] and warm[1] > warm[2], "physical temperature changes recolor cached SH")
	else:
		expected_energy *= PI
		_check(warm == neutral, "nonphysical light temperature does not recolor SH")
	var basis := Data.sh_basis(red.global_basis.z.normalized())
	for coefficient in 9:
		for channel in 3:
			_check(is_equal_approx(warm[coefficient * 3 + channel],
					expected_color[channel] * expected_energy * basis[coefficient]),
					"directional SH matches engine energy and color units")
	_check(lighting.coefficients(volume) == warm, "unchanged lighting retains the cached result")
	red.hide()
	_check(lighting.coefficients(volume)[0] == 0.0, "hiding the selected sun invalidates SH")
	scene.free()
