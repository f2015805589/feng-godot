extends SceneTree
## Engine integration regression for viewport-local exposure and TAA lifetimes.
## The probe uses the same native setter retained by asynchronous GPU callbacks;
## deliberately calling a retired context makes callback timing deterministic.

const Renderer = preload("res://addons/feng-render-pipeline/renderer.gd")
const PassBase = preload("res://addons/feng-render-pipeline/passes/pass_base.gd")

class ExposureProbe extends FengPass:
	var use_pre_exposure := true
	var write_scale := 4.0
	var observed := 0.0
	var history := RID()
	var latest_context: FRPPassContext
	var retired_context: FRPPassContext
	var calls := 0

	func _init() -> void:
		stable_id = &"library:eye_adaptation"
		resource_name = "Exposure lifetime probe"

	func get_frp_parameters() -> Dictionary:
		return {"pre_exposure": use_pre_exposure}

	func _frp_execute(ctx: FRPPassContext) -> void:
		calls += 1
		observed = ctx.get_pre_exposure(0)
		latest_context = ctx
		var buffers := ctx.get_render_scene_buffers() as RenderSceneBuffersRD
		history = buffers.get_texture("taa", "history") if buffers.has_texture("taa", "history") else RID()
		if retired_context != null:
			# Only the exposure writer is lifetime-safe after a frame has ended.
			# Other context operations refer to frame-local render data.
			retired_context.set_next_pre_exposure(0, 64.0)
		if write_scale > 0.0:
			ctx.set_next_pre_exposure(0, write_scale)

var renderer: FengRenderer
var probe: ExposureProbe
var camera: Camera3D
var temporal: FengPass
var failed := false

func require(value: bool, message: String) -> void:
	if not value:
		failed = true
		push_error("REGRESSION: " + message)
		quit(1)
		assert(value, message)

func _initialize() -> void:
	call_deferred("run")

func settle() -> void:
	for _i in 8:
		await process_frame
	await RenderingServer.frame_post_draw

func expect_scale(value: float, label: String) -> void:
	require(absf(probe.observed - value) < 0.0001, "%s: exposure %f, expected %f" % [label, probe.observed, value])

func change_pre_exposure(value: bool) -> void:
	probe.use_pre_exposure = value
	probe.emit_changed()
	renderer.apply(camera.compositor)

func retire_writer() -> void:
	probe.retired_context = probe.latest_context
	probe.write_scale = 0.0

func run() -> void:
	# Pin render resolution independently of desktop window-manager resizing.
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	root.content_scale_size = Vector2i(320, 240)
	root.msaa_3d = Viewport.MSAA_DISABLED
	root.use_taa = false
	var scene := Node3D.new()
	root.add_child(scene)
	camera = Camera3D.new()
	camera.position.z = 3.0
	scene.add_child(camera)
	camera.current = true
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.12, 0.08, 0.04)
	scene.add_child(environment)

	renderer = Renderer.new()
	probe = ExposureProbe.new()
	var entries: Array[PassBase] = renderer.passes.duplicate()
	for i in entries.size():
		if entries[i].stable_id == &"library:eye_adaptation":
			entries[i] = probe
		elif entries[i].stable_id == &"native:6":
			temporal = entries[i]
			temporal.enabled = true
			temporal.pass_parameters = {"jitter_phases": 1}
	renderer.passes = entries
	camera.compositor = Compositor.new()
	renderer.apply(camera.compositor)
	require(renderer.get_validation_warnings().is_empty(), "probe pipeline is invalid")
	await settle()
	require(probe.calls > 1, "exposure probe never executed")
	expect_scale(4.0, "initial camera")
	require(probe.history.is_valid(), "enabled TAA did not create history")

	# A pre-exposure mode change must not let a late readback from the prior
	# mode become the first exposure of the newly enabled mode.
	retire_writer()
	change_pre_exposure(false)
	await settle()
	expect_scale(1.0, "pre-exposure off")
	change_pre_exposure(true)
	await settle()
	expect_scale(1.0, "pre-exposure re-enabled with stale callback")
	probe.retired_context = null
	probe.write_scale = 0.25
	await settle()
	expect_scale(0.25, "rapid exposure decrease")
	probe.write_scale = 32.0
	await settle()
	expect_scale(32.0, "rapid exposure increase")

	# Disabling TAA discards both the history color and previous velocity.
	var previous_history := probe.history
	temporal.enabled = false
	renderer.apply(camera.compositor)
	await settle()
	require(not probe.history.is_valid(), "disabled TAA retained stale history")
	temporal.enabled = true
	renderer.apply(camera.compositor)
	await settle()
	require(probe.history.is_valid() and probe.history != previous_history, "re-enabled TAA reused stale history")

	retire_writer()
	previous_history = probe.history
	root.content_scale_size += Vector2i(8, 8)
	await settle()
	expect_scale(1.0, "resize with stale callback")
	require(probe.history.is_valid() and probe.history != previous_history, "resize reused old TAA history")

	probe.retired_context = null
	probe.write_scale = 8.0
	await settle()
	expect_scale(8.0, "before compositor switch")
	retire_writer()
	previous_history = probe.history
	camera.compositor = Compositor.new()
	renderer.apply(camera.compositor)
	await settle()
	expect_scale(1.0, "compositor switch with stale callback")
	require(probe.history.is_valid() and probe.history != previous_history, "compositor switch reused old TAA history")

	# No retained frame contexts survive teardown of the fixture itself.
	probe.retired_context = null
	probe.latest_context = null
	camera.compositor = null
	scene.queue_free()
	await process_frame
	if failed:
		quit(1)
	else:
		print("PASS FRP exposure readback retirement, pre-exposure toggle, TAA restart, resize and compositor switch")
		quit(0)
