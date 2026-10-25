extends SceneTree
## Capture cloning accepts derived renderers; filtering follows typed pass chains.
const Probe = preload("res://addons/feng-reflect-probe/feng_reflect_probe.gd")
const Renderer = preload("res://addons/feng-render-pipeline/renderer.gd")
const CompositorType = preload("res://addons/feng-render-pipeline/compositor.gd")
const Pass = preload("res://addons/feng-render-pipeline/passes/pass_base.gd")

class CustomRenderer extends Renderer:
	pass

class CustomCompositor extends CompositorType:
	func _apply_renderer() -> void:
		pass # Cloning is independent of a native rendering device.

class QuietProbe extends Probe:
	func _ready() -> void:
		pass

class Wrapper extends Pass:
	var source: FengPass
	func get_parameter_source() -> FengPass:
		return source

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var viewport := SubViewport.new()
	viewport.world_3d = World3D.new()
	root.add_child(viewport)
	var camera := Camera3D.new()
	viewport.add_child(camera)
	camera.make_current()
	var source := CustomRenderer.new()
	source.passes = []
	var compositor := CustomCompositor.new()
	compositor.renderer = source
	camera.compositor = compositor
	var probe := QuietProbe.new()
	probe.enabled = false
	probe.update_mode = Probe.UpdateMode.MANUAL
	viewport.add_child(probe)
	var copy := probe._clone_source_renderer()
	assert(copy is CustomRenderer and copy != source, "capture preserves derived renderer identity and isolation")
	var leaf := Pass.new()
	leaf.stable_id = &"library:eye_adaptation"
	var chain: FengPass = leaf
	var wrappers: Array[FengPass] = []
	for index in 12:
		var wrapper := Wrapper.new()
		wrapper.source = chain
		wrappers.append(wrapper)
		chain = wrapper
	assert(probe._parameter_source(chain) == leaf and probe._skip_in_capture(chain), "capture follows deep parameter chains")
	var first := Wrapper.new()
	var second := Wrapper.new()
	first.source = second
	second.source = first
	assert(probe._parameter_source(first) == first, "cyclic custom parameter chains terminate")
	first.source = null
	second.source = null
	assert(probe._skip_in_capture(null) and not probe._skip_in_capture(Pass.new()))
	viewport.free()
	print("PASS reflection capture typed contracts")
	quit()
