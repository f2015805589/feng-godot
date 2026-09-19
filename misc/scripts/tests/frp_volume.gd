extends SceneTree
## Author-owned Volume schema, persistence, blend priority and real frame delivery.

const PassBase = preload("res://addons/feng-render-pipeline/passes/pass_base.gd")
const Renderer = preload("res://addons/feng-render-pipeline/renderer.gd")
const CompositorScript = preload("res://addons/feng-render-pipeline/compositor.gd")
const Volume = preload("res://addons/feng-render-pipeline/volume/feng_volume.gd")
const Profile = preload("res://addons/feng-render-pipeline/volume/feng_volume_profile.gd")
const Module = preload("res://addons/feng-render-pipeline/volume/feng_volume_module.gd")
const ParameterResolver = preload("res://addons/feng-render-pipeline/pipeline/parameter_resolver.gd")
const VolumeResolver = preload("res://addons/feng-render-pipeline/volume/volume_resolver.gd")
const VolumeRuntime = preload("res://addons/feng-render-pipeline/volume/volume_runtime.gd")

class Probe extends PassBase:
	@export_range(0.0, 10.0, 0.1) var strength := 2.0
	@export var pipeline_only := 4.0
	@export var tint := Color.BLACK
	var observed := {}
	func get_parameter_key() -> Variant:
		return "test:volume_probe"
	func get_volume_parameter_names() -> PackedStringArray:
		return PackedStringArray(["strength", "tint"])
	func _frp_execute(ctx: FRPPassContext) -> void:
		observed = get_resolved_parameters(ctx)

class ProvidedTAA extends PassBase:
	@export var jitter_phases := 16
	func _init() -> void:
		provides_native_ids = [6]
	func get_parameter_key() -> Variant:
		return "test:provided_taa"
	func get_volume_parameter_names() -> PackedStringArray:
		return PackedStringArray(["jitter_phases"])

class RepeatedPass extends PassBase:
	@export var amount := 1.0
	func get_volume_parameter_names() -> PackedStringArray:
		return PackedStringArray(["amount"])

func _initialize() -> void:
	_run.call_deferred()

func settle() -> void:
	for i in 6:
		await process_frame
		await RenderingServer.frame_post_draw

func _run() -> void:
	var identities := Renderer.new()
	var first := RepeatedPass.new()
	var second_instance := RepeatedPass.new()
	var identity_entries: Array[FengPass] = identities.passes.duplicate()
	identity_entries.append_array([first, second_instance])
	identities.passes = identity_entries
	assert(first.get_parameter_key() != second_instance.get_parameter_key(), "two instances of a custom pass need distinct persisted keys")
	assert(first.duplicate(true).get_parameter_key() == first.get_parameter_key())
	var provider := ProvidedTAA.new()
	var aliases := Renderer.new()
	for entry in aliases.passes:
		if entry is FengBuiltinPass and entry.native_id == 6:
			entry.implementation = provider
	aliases.set_volume_parameters({provider.get_parameter_key(): {"jitter_phases": 1}})
	assert(aliases.get_pass_parameters()[6].jitter_phases == 1, "native setup must receive an implementation module's override")
	assert(aliases.get_pass_parameters()[provider.get_parameter_key()].jitter_phases == 1)
	aliases.set_volume_parameters({6: {"jitter_phases": 3}})
	assert(aliases.get_pass_parameters()[provider.get_parameter_key()].jitter_phases == 3, "legacy native overrides must reach replacement implementations")
	var renderer := Renderer.new()
	var probe := Probe.new()
	probe.pass_parameters = {"strength": 4.0}
	var entries: Array[FengPass] = renderer.passes.duplicate()
	entries.append(probe)
	renderer.passes = entries
	var key: Variant = probe.get_parameter_key()
	assert(probe.get_frp_parameters().has("pipeline_only"), "custom exports must be collected automatically")
	assert(renderer.get_authored_pass_parameters()[key].strength == 4.0)
	var snapshot := renderer.get_volume_context()
	var resolved := ParameterResolver.with_overrides(snapshot.base, {key: {"strength": 9.0}}, snapshot.schema)
	assert(resolved[key].strength == 9.0 and snapshot.base[key].strength == 4.0,
			"resolving frame values must not mutate authored snapshots")
	var supplied := {key: {"strength": 7.0}}
	renderer.set_volume_parameters(supplied)
	supplied[key].strength = 99.0
	var returned := renderer.get_volume_parameters()
	returned[key].strength = 98.0
	assert(renderer.get_volume_parameters()[key].strength == 7.0,
			"Volume inputs and getters must not expose mutable renderer state")
	renderer.set_volume_parameters({})
	assert(renderer.get_volume_modules().has(probe), "custom passes need no native capability to expose a Volume module")
	var module := Module.from_pass(probe, renderer.get_authored_pass_parameters()[key])
	assert(module.get_parameters().size() == 2 and not module.get_parameters().has("pipeline_only"))
	module.set("parameters/strength", 8.0)
	module.set("parameters/tint", Color.WHITE)
	module.values.pipeline_only = 99.0
	assert(not module.get_parameters().has("pipeline_only"), "a Volume cannot expand the pass author's schema")
	var profile := Profile.new()
	profile.modules = [module]
	var volume := Volume.new()
	volume.profile = profile
	volume.size = Vector3(10, 10, 10)
	volume.blend_distance = 2.0
	root.add_child(volume)
	var base := renderer.get_authored_pass_parameters()
	var half := Volume.resolve_overrides([volume], base, Vector3(4, 0, 0))
	assert(is_equal_approx(half[key].strength, 6.0))
	assert(half[key].tint.is_equal_approx(Color(0.5, 0.5, 0.5, 1.0)))
	assert(Volume.resolve_overrides([volume], base, Vector3(6, 0, 0)).is_empty())
	profile.enabled_passes = [6]
	var sampled := VolumeResolver.evaluate([volume], base, Vector3(4, 0, 0), snapshot.schema, snapshot.aliases)
	assert(is_equal_approx(sampled.parameters[key].strength, 6.0) and sampled.pass_states[6],
			"parameters and pass switches must sample the same half-influence boundary")
	assert(VolumeResolver.evaluate([volume], base, Vector3(4.1, 0, 0)).pass_states.is_empty())
	profile.enabled_passes = []
	assert(VolumeRuntime.get_scene_volumes(null).is_empty())
	# A global-only field cannot enter the Volume UI or runtime, even through
	# stale hand-written profile dictionaries and legacy native switch lists.
	profile.pass_parameters = {key: {"pipeline_only": 99.0, "enabled": false}}
	profile.disabled_passes = [0]
	var filtered := VolumeResolver.evaluate([volume], base, Vector3.ZERO, snapshot.schema, snapshot.aliases, true)
	assert(not filtered.parameters[key].has("pipeline_only") and not filtered.parameters[key].has("enabled"))
	assert(filtered.pass_states.is_empty(), "undeclared Volume switches bypassed the pass author schema")
	for info in module.get_property_list():
		assert(info.name != "parameters/pipeline_only" and info.name != "parameters/enabled")
		if info.name == "enabled":
			assert((int(info.usage) & PROPERTY_USAGE_EDITOR) == 0, "generic module Enabled must not bypass author-owned fields")
	profile.pass_parameters = {}
	profile.disabled_passes = []
	var higher := Volume.new()
	higher.profile = Profile.new()
	var higher_module := Module.from_pass(probe)
	higher_module.set("parameters/strength", 10.0)
	higher.profile.modules = [higher_module]
	higher.unbound = true
	higher.priority = 10
	higher.weight = 0.5
	root.add_child(higher)
	assert(is_equal_approx(Volume.resolve_overrides([higher, volume], base, Vector3.ZERO)[key].strength, 9.0))
	higher.queue_free()
	renderer.set_volume_parameters({key: {"strength": 7.0, "pipeline_only": 99.0}})
	assert(renderer.get_pass_parameters()[key].strength == 7.0)
	assert(renderer.get_pass_parameters()[key].pipeline_only == 4.0, "runtime must enforce author permissions too")
	renderer.set_volume_parameters({})
	# Use the shipping native module to test saving/reloading real typed resources.
	var taa: FengPass
	for source in renderer.get_volume_modules():
		if source.get_parameter_key() is int and source.get_parameter_key() == 6:
			taa = source
	assert(taa != null)
	var saved := Profile.new()
	var saved_module := Module.from_pass(taa)
	saved_module.set("parameters/jitter_phases", 3)
	saved.modules = [saved_module]
	assert(ResourceSaver.save(saved, "user://volume-profile.tres") == OK)
	var restored = ResourceLoader.load("user://volume-profile.tres", "", ResourceLoader.CACHE_MODE_IGNORE)
	assert(restored.get_parameters()[6].jitter_phases == 3)
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	var compositor := CompositorScript.new()
	compositor.renderer = renderer
	world.compositor = compositor
	root.add_child(world)
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.current = true
	await settle()
	# Volume snapshots own their effect instances; find the runtime probe.
	var runtime_probe: Probe
	for effect in compositor.compositor_effects:
		if effect is Probe:
			runtime_probe = effect
	assert(runtime_probe != null and runtime_probe != probe)
	assert(runtime_probe.observed.get("strength") == 8.0, "the custom pass must receive Volume values through the engine frame context")
	VolumeRuntime.evaluate_camera([volume], camera, compositor)
	var started := Time.get_ticks_usec()
	for i in 300:
		assert(not VolumeRuntime.evaluate_camera([volume], camera, compositor),
				"unchanged Volume must not rebuild its parameter context")
	print("PASS unchanged Volume fast path: %.2f us/evaluation" % (float(Time.get_ticks_usec() - started) / 300.0))
	module.set("parameters/strength", 9.0)
	assert(VolumeRuntime.evaluate_camera([volume], camera, compositor), "module edits must invalidate stationary evaluation")
	module.set("parameters/strength", 8.0)
	assert(VolumeRuntime.evaluate_camera([volume], camera, compositor))
	assert(probe.strength == 2.0 and probe.pass_parameters.strength == 4.0, "authored values were mutated")
	assert(renderer.get_volume_parameters().is_empty(), "per-camera settings leaked into a shared renderer")
	var second := CompositorScript.new()
	second.renderer = renderer
	assert(second.get_volume_parameters().is_empty())
	assert(not second.compositor_effects.has(runtime_probe), "runtime effect RIDs must be isolated")
	volume.enabled = false
	await settle()
	assert(compositor.get_volume_parameters().is_empty())
	assert(probe.observed.get("strength") == 4.0, "leaving the Volume must restore pipeline values")
	var tint := load("res://addons/feng-render-pipeline/library/tint/tint.tres").duplicate(true) as FengShaderPass
	tint.parameters = Vector4.ONE
	var shader_entries: Array[FengPass] = renderer.passes.duplicate()
	for i in shader_entries.size():
		if shader_entries[i] is FengBuiltinPass and shader_entries[i].native_id == 7:
			shader_entries.insert(i, tint)
			break
	renderer.passes = shader_entries
	world.environment.background_color = Color(0.3, 0.3, 0.3)
	await settle()
	var before := root.get_texture().get_image().get_pixel(100, 100)
	var tint_module := Module.from_pass(tint)
	tint_module.set("parameters/parameters", Vector4(0.1, 1.0, 1.0, 1.0))
	profile.modules = [tint_module]
	volume.enabled = true
	await settle()
	var during := root.get_texture().get_image().get_pixel(100, 100)
	assert(before.r > 0.1 and during.r < before.r * 0.6, "Volume vector parameters must reach real shader push constants")
	volume.enabled = false
	await settle()
	var after := root.get_texture().get_image().get_pixel(100, 100)
	assert(absf(before.r - after.r) < 0.01, "shader parameters must restore after leaving the Volume")
	var warmed_renderer = compositor._runtime_renderer
	var transform_before := camera.global_transform
	for i in 48:
		volume.enabled = i % 2 == 0
		await process_frame
		await RenderingServer.frame_post_draw
		assert(compositor._runtime_renderer == warmed_renderer,
				"Volume boundary crossing rebuilt the shader resources")
		assert(camera.global_transform == transform_before, "Volume evaluation changed camera navigation")
	print("PASS Volume boundary stress preserves GPU resources and camera transform")
	volume.enabled = true
	await settle()
	assert(not compositor.get_volume_parameters().is_empty())
	volume.queue_free()
	await settle()
	assert(compositor.get_volume_parameters().is_empty(), "removing the last Volume must clear runtime contributions")
	print("PASS FRP author-defined Volume modules, typed fields, priority, persistence, custom frame parameters and compositor isolation")
	world.queue_free()
	camera.queue_free()
	await process_frame
	quit()
