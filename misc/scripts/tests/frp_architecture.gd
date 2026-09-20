extends SceneTree
## Resource contracts must invalidate view snapshots without polling each frame.
const PassBase = preload("res://addons/feng-render-pipeline/passes/pass_base.gd")
const ViewState = preload("res://addons/feng-render-pipeline/pipeline/view_state.gd")
const Evaluator = preload("res://addons/feng-render-pipeline/volume/volume_evaluator.gd")

class SettingsSource extends RefCounted:
	var revision := 0
	var reads := 0
	func get_parameter_revision() -> int:
		return revision
	func get_volume_context() -> Dictionary:
		reads += 1
		return {"base": {"test": {"amount": 2.0}}, "schema": {"test": {"amount": {"type": TYPE_FLOAT}}}}

class ContractPass extends PassBase:
	func _frp_execute(_ctx: FRPPassContext) -> void:
		pass

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	# Evaluation depends on settings and a position, not on scene/camera ownership.
	var settings := SettingsSource.new()
	var volume := FengVolume.new()
	volume.unbound = true
	volume.profile = FengVolumeProfile.new()
	volume.profile.pass_parameters = {"test": {"amount": 8.0}}
	root.add_child(volume)
	var first := Evaluator.new()
	var second := Evaluator.new()
	assert(first.evaluate([volume], Vector3.ZERO, settings).parameters.test.amount == 8.0)
	assert(first.evaluate([volume], Vector3.ONE, settings).is_empty())
	assert(settings.reads == 1, "stationary influence must not query the settings context")
	assert(second.evaluate([volume], Vector3.ZERO, settings).parameters.test.amount == 8.0)
	volume.profile.pass_parameters.test.amount = 5.0
	assert(first.evaluate([volume], Vector3.ZERO, settings).parameters.test.amount == 5.0)
	assert(second.evaluate([volume], Vector3.ZERO, settings).parameters.test.amount == 5.0)
	volume.weight = 0.0
	assert(first.evaluate([volume], Vector3.ZERO, settings).parameters.is_empty())
	volume.weight = 1.0
	assert(first.evaluate([volume], Vector3.ZERO, settings).parameters.test.amount == 5.0)
	settings.revision += 1
	assert(not first.evaluate([volume], Vector3.ZERO, settings).is_empty())
	volume.free()
	var shader_pass := FengShaderPass.new()
	var notifications := [0]
	shader_pass.changed.connect(func(): notifications[0] += 1)
	var shader_a := RDShaderFile.new()
	var shader_b := RDShaderFile.new()
	shader_pass.shader_file = shader_a
	var count: int = notifications[0]
	shader_a.emit_changed()
	assert(notifications[0] == count + 1, "shader content changes must propagate")
	shader_pass.shader_file = shader_b
	count = notifications[0]
	shader_a.emit_changed()
	shader_pass.shader_file = shader_b
	assert(notifications[0] == count, "old shaders must disconnect; unchanged assignments must stay silent")
	shader_b.emit_changed()
	assert(notifications[0] == count + 1)
	var renderer := FengRenderer.new()
	var source := ContractPass.new()
	var output := FengPassOutput.new()
	output.name = &"architecture_output"
	source.outputs = [output]
	var input := FengPassTexture.new()
	source.inputs = [input]
	var entries: Array[FengPass] = renderer.passes.duplicate()
	entries.insert(entries.size() - 1, source)
	renderer.passes = entries
	var compositor := Compositor.new()
	var view := ViewState.new()
	view.apply(compositor, renderer, {}, {})
	var executor: FengPass = view._executors[source]
	assert(executor != source)
	assert(executor.outputs[0].scale == Vector2.ONE)
	var revision := renderer.get_parameter_revision()
	output.scale = Vector2(0.5, 0.5)
	assert(renderer.get_parameter_revision() > revision, "output edits must invalidate the renderer's view snapshots")
	view.apply(compositor, renderer, {}, {})
	assert(view._executors[source] != executor)
	assert(view._executors[source].outputs[0].scale == Vector2(0.5, 0.5))
	revision = renderer.get_parameter_revision()
	input.source = FengPassTexture.Source.DEPTH
	assert(renderer.get_parameter_revision() > revision, "input edits must propagate attachment contract changes")
	view.apply(compositor, renderer, {}, {})
	assert(view._executors[source].inputs[0].source == FengPassTexture.Source.DEPTH)
	revision = renderer.get_parameter_revision()
	input.source = FengPassTexture.Source.DEPTH
	output.scale = Vector2(0.5, 0.5)
	assert(renderer.get_parameter_revision() == revision, "unchanged declarations must not invalidate caches")
	source.inputs = []
	source.outputs = []
	revision = renderer.get_parameter_revision()
	input.binding = 1
	output.scale = Vector2.ONE
	assert(renderer.get_parameter_revision() == revision, "removed declaration resources must be disconnected")
	compositor.compositor_effects = []
	print("PASS FRP contract resource notifications, view invalidation and detached dependency lifetime")
	quit()
