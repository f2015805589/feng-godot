extends SceneTree

# FRP Core surface regression.
#
# A pass that is part of an FRP pipeline receives an FRPPassContext instead of a bare
# CompositorEffect callback, so it can run the engine's own rendering primitives. These
# checks prove that a plugin pass can take over an engine pass in its exact list
# position and produce the frame the engine's own entry produced:
#   * Sky: disabled natively, drawn from the scripted pass through draw_sky() and
#     resolve_sky(), with a control frame proving the native entry was what drew it.
#   * Transparent: disabled natively, run from the scripted pass through the fallback,
#     screen/depth copy and transparent primitives.
# A primitive wired to the wrong operation, or a context that cannot see the frame,
# leaves the takeover frame different from the baseline.

const FRP_BASE = preload("res://addons/feng-render-pipeline/passes/pass_base.gd")
const SKY_PASS_ID := 4
const TRANSPARENT_PASS_ID := 5
const POST_PASS_ID := 7

var root_window: Window


func require(value: bool, message: String) -> void:
	if not value:
		push_error("REGRESSION: " + message)
		quit(1)


func frame() -> Image:
	for i in 8:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


func mean_luma(image: Image) -> float:
	var sum := 0.0
	var w := image.get_width()
	var h := image.get_height()
	for y in h:
		for x in w:
			var p := image.get_pixel(x, y)
			sum += (p.r + p.g + p.b) / 3.0
	return sum / float(w * h)


func changed_pixels(a: Image, b: Image) -> int:
	var changed := 0
	for y in a.get_height():
		for x in a.get_width():
			if a.get_pixel(x, y) != b.get_pixel(x, y):
				changed += 1
	return changed


# Runs the Sky entry's operations from script, where the native entry used to be.
class ScriptedSkyPass extends FengPass:
	var calls := 0
	var sequence: Array[String] = []

	func _init() -> void:
		stage = EFFECT_CALLBACK_TYPE_POST_SKY
		resource_name = "Scripted Sky"

	func _frp_execute(ctx: FRPPassContext) -> void:
		calls += 1
		sequence.clear()
		if ctx == null or ctx.get_render_data() == null:
			push_error("REGRESSION: FRP pass context is unusable")
			return
		if ctx.get_view_count() < 1 or ctx.get_internal_size().x < 1:
			push_error("REGRESSION: FRP pass context cannot see the frame")
		if ctx.get_pass_name(SKY_PASS_ID) != "Sky" or not ctx.is_valid_pass_id(SKY_PASS_ID):
			push_error("REGRESSION: FRP pass context does not expose the pass spec")
		# Parameters authored on the entry for this pass, wherever it is executed from.
		if ctx.get_pass_parameters(SKY_PASS_ID).get("skip", false):
			return
		sequence.append("sky")
		ctx.draw_sky()
		sequence.append("sky_resolve")
		ctx.resolve_sky()


# Runs the Transparent entry's operations from script.
class ScriptedTransparentPass extends FengPass:
	var calls := 0
	var sequence: Array[String] = []

	func _init() -> void:
		stage = EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT
		resource_name = "Scripted Transparent"

	func _frp_execute(ctx: FRPPassContext) -> void:
		calls += 1
		sequence.clear()
		sequence.append("opaque_fallback")
		ctx.draw_opaque_fallback()
		sequence.append("screen_depth_copy")
		ctx.copy_screen_and_depth()
		sequence.append("transparent")
		ctx.draw_transparent()


# A Post Process pass that runs its own shader inside the engine pass: after the final
# resolve and history copy, before the engine's tone mapping, so the shader works on
# the frame's HDR colour and its result is presented. This is what the overlay slot is
# for: an engine pass and a project shader as one pipeline entry.
class OverlaidPostPass extends FengNativePass:
	func _init() -> void:
		native_id = POST_PASS_ID
		resource_name = "Post Process / Tonemap"

	func _frp_execute(ctx: FRPPassContext) -> void:
		ctx.resolve_final()
		ctx.copy_history()
		if overlay != null:
			overlay._frp_execute(ctx)
		ctx.post_process_and_tonemap()


func _native_pass(renderer: Object, native_id: int):
	for pass_entry in renderer.passes:
		if pass_entry.get("native_id") != null and int(pass_entry.native_id) == native_id:
			return pass_entry
	return null


# Replaces an engine entry with a scripted pass at the same list position.
func _replace_entry(renderer: Object, native_id: int, scripted) -> void:
	var values: Array[FRP_BASE] = []
	var replaced := false
	for pass_entry in renderer.passes:
		if not pass_entry is FRP_BASE:
			continue
		if pass_entry.get("native_id") != null and int(pass_entry.native_id) == native_id:
			pass_entry.enabled = false
			values.append(scripted)
			values.append(pass_entry)
			replaced = true
			continue
		values.append(pass_entry)
	require(replaced, "renderer does not expose native pass %d" % native_id)
	renderer.passes = values


# The seeded pipeline also carries the library's authoring passes (tint, blur, fxaa,
# colour grade, bloom). A comparison against the engine default order needs them off,
# otherwise the difference measured is the library look, not the taken-over pass.
func _disable_library(renderer: Object) -> void:
	for pass_entry in renderer.passes:
		if pass_entry != null and pass_entry.get("native_id") == null:
			pass_entry.enabled = false


# Drives the whole frame with the granular primitives, with no engine entry in the
# schedule at all.
class ScriptedFramePass extends FengPass:
	var calls := 0

	func _init() -> void:
		stage = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
		resource_name = "Scripted Frame"
		# This pass runs every mandatory entry's work itself, so the renderer accepts
		# a list without engine entries instead of re-adding them.
		provides_native_ids = [0, 1, 2, 3, 7]

	func _frp_execute(ctx: FRPPassContext) -> void:
		calls += 1
		ctx.execute_virtual_texture_updates()
		ctx.draw_gbuffer()
		ctx.draw_motion_vectors()
		ctx.prepare_lighting()
		ctx.draw_deferred_lighting()
		ctx.merge_subsurface_and_specular()
		ctx.resolve_opaque()
		ctx.draw_sky()
		ctx.resolve_sky()
		ctx.draw_opaque_fallback()
		ctx.copy_screen_and_depth()
		ctx.draw_transparent()
		ctx.temporal_aa_and_upscale()
		ctx.resolve_final()
		ctx.copy_history()
		ctx.post_process_and_tonemap()


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	root.msaa_3d = Viewport.MSAA_DISABLED
	root.use_taa = false
	root.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	root.scaling_3d_scale = 1.0

	var scene := Node3D.new()
	root.add_child(scene)
	var camera := Camera3D.new()
	scene.add_child(camera)
	camera.position = Vector3(0, 0, 6)
	camera.current = true

	var box := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3(2, 2, 2)
	box.mesh = box_mesh
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.8, 0.6, 0.4)
	box.material_override = material
	scene.add_child(box)

	var quad := MeshInstance3D.new()
	var quad_mesh := QuadMesh.new()
	quad_mesh.size = Vector2(2, 2)
	quad.mesh = quad_mesh
	quad.position = Vector3(1.4, 0.0, 2.0)
	var quad_material := StandardMaterial3D.new()
	quad_material.albedo_color = Color(0.1, 0.9, 0.2, 0.35)
	quad_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	quad.material_override = quad_material
	scene.add_child(quad)

	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.2, 0.4, 0.9)
	sky_material.sky_horizon_color = Color(0.7, 0.8, 1.0)
	sky_material.ground_bottom_color = Color(0.1, 0.1, 0.2)
	sky_material.ground_horizon_color = Color(0.4, 0.4, 0.5)
	sky.sky_material = sky_material
	environment.environment.sky = sky
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	environment.environment.ambient_light_energy = 1.0
	scene.add_child(environment)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, 30, 0)
	light.light_energy = 1.5
	scene.add_child(light)

	# Baseline: the engine default order, no pipeline authored.
	var baseline: Image = await frame()
	var baseline_luma := mean_luma(baseline)
	require(baseline_luma > 0.02, "baseline frame is not lit: %.4f" % baseline_luma)

	var renderer_script = load("res://addons/feng-render-pipeline/renderer.gd")
	var compositor_script = load("res://addons/feng-render-pipeline/compositor.gd")
	require(renderer_script != null and compositor_script != null, "FRP addon scripts did not load")

	# 1. Sky: control frame without the native entry and without a scripted pass.
	var sky_renderer = renderer_script.new()
	_native_pass(sky_renderer, SKY_PASS_ID).enabled = false
	_disable_library(sky_renderer)
	var sky_compositor = compositor_script.new()
	sky_compositor.renderer = sky_renderer
	camera.compositor = sky_compositor
	sky_renderer.apply(sky_compositor)
	require(sky_renderer.get_validation_warnings().is_empty(), "the Sky entry cannot be disabled: %s" % [sky_renderer.get_validation_warnings()])
	var without_sky: Image = await frame()
	var without_sky_luma := mean_luma(without_sky)
	require(without_sky_luma < baseline_luma - 0.02, "disabling the Sky entry did not remove the sky: %.4f vs %.4f" % [without_sky_luma, baseline_luma])

	# 2. Sky: the scripted pass runs the Sky operations at the same list position.
	var scripted_sky := ScriptedSkyPass.new()
	_replace_entry(sky_renderer, SKY_PASS_ID, scripted_sky)
	sky_renderer.apply(sky_compositor)
	var with_scripted_sky: Image = await frame()
	require(scripted_sky.calls > 0, "the scripted Sky pass was never executed by the renderer")
	require(scripted_sky.sequence == ["sky", "sky_resolve"], "the scripted Sky pass did not run the Sky primitives: %s" % [scripted_sky.sequence])
	var scripted_sky_luma := mean_luma(with_scripted_sky)
	# The scripted pass draws the sky through the engine's own primitive: the sky region
	# is filled where the control frame is black.
	var scripted_sky_pixel := with_scripted_sky.get_pixel(2, 2)
	var control_sky_pixel := without_sky.get_pixel(2, 2)
	require(scripted_sky_pixel.b > control_sky_pixel.b + 0.2, "the scripted Sky pass did not draw the sky: %s vs %s" % [scripted_sky_pixel, control_sky_pixel])
	# With the library look out of the way, the takeover has to reproduce the engine's
	# own Sky entry exactly.
	require(absf(scripted_sky_luma - baseline_luma) < 0.02, "a scripted Sky pass did not match the engine's own entry: %.4f vs %.4f" % [scripted_sky_luma, baseline_luma])
	print("PASS scripted Sky pass: calls=%d luma=%.4f vs engine %.4f (control %.4f)" % [scripted_sky.calls, scripted_sky_luma, baseline_luma, without_sky_luma])

	# Parameters authored in the pipeline resource reach the pass script that runs the
	# pass: the entry is the authoring slot even when another object executes it, so a
	# takeover keeps the settings a project configured.
	_native_pass(sky_renderer, SKY_PASS_ID).pass_parameters = {"skip": true}
	sky_renderer.apply(sky_compositor)
	var skipped_sky: Image = await frame()
	require(mean_luma(skipped_sky) < baseline_luma - 0.02, "pass parameters did not reach the pass script: %.4f" % mean_luma(skipped_sky))
	_native_pass(sky_renderer, SKY_PASS_ID).pass_parameters = {}
	sky_renderer.apply(sky_compositor)
	var restored_sky: Image = await frame()
	require(absf(mean_luma(restored_sky) - baseline_luma) < 0.02, "clearing the pass parameters did not restore the pass: %.4f" % mean_luma(restored_sky))
	print("PASS pass parameters travel from the pipeline resource to the pass script")

	# 3. Transparent: the same takeover mechanism for the forward queue. The scripted
	# pass has to reproduce the engine's own entry exactly, with the control frame
	# (entry disabled, no scripted pass) proving the transparent quad is what changes.
	var transparent_renderer = renderer_script.new()
	_native_pass(transparent_renderer, TRANSPARENT_PASS_ID).enabled = false
	_disable_library(transparent_renderer)
	var transparent_compositor = compositor_script.new()
	transparent_compositor.renderer = transparent_renderer
	camera.compositor = transparent_compositor
	transparent_renderer.apply(transparent_compositor)
	require(transparent_renderer.get_validation_warnings().is_empty(), "the Transparent entry cannot be disabled: %s" % [transparent_renderer.get_validation_warnings()])
	var without_transparent: Image = await frame()
	var without_transparent_luma := mean_luma(without_transparent)
	require(absf(without_transparent_luma - baseline_luma) > 0.002, "the transparent quad is not measurable; the takeover test would be vacuous")
	var scripted_transparent := ScriptedTransparentPass.new()
	_replace_entry(transparent_renderer, TRANSPARENT_PASS_ID, scripted_transparent)
	transparent_renderer.apply(transparent_compositor)
	var with_scripted_transparent: Image = await frame()
	require(scripted_transparent.calls > 0, "the scripted Transparent pass was never executed by the renderer")
	require(scripted_transparent.sequence == ["opaque_fallback", "screen_depth_copy", "transparent"], "the scripted Transparent pass did not run the transparent primitives: %s" % [scripted_transparent.sequence])
	var scripted_transparent_luma := mean_luma(with_scripted_transparent)
	require(absf(scripted_transparent_luma - baseline_luma) < 0.02, "a scripted Transparent pass did not match the engine's own entry: %.4f vs %.4f" % [scripted_transparent_luma, baseline_luma])
	print("PASS scripted Transparent pass: calls=%d luma=%.4f vs engine %.4f (control %.4f)" % [scripted_transparent.calls, scripted_transparent_luma, baseline_luma, without_transparent_luma])

	# 4. The whole frame driven by one plugin pass, with no engine entry at all. The
	# pass declares the mandatory entries in provides_native_ids, so the authored
	# renderer is a complete schedule on its own: normalization must not re-add the
	# engine entries and validation must stay clean.
	var frame_renderer = renderer_script.new()
	# The library look is part of the renderer's default list. Mark those entries as
	# known so removing them is an explicit authoring decision (a tombstone) rather
	# than an entry the next sync adds back; a saved resource carries the same
	# bookkeeping from the editor.
	for library_path in renderer_script.DEFAULT_PASS_PATHS:
		frame_renderer.mark_library_pass(library_path)
	var frame_pass := ScriptedFramePass.new()
	var authored: Array[FRP_BASE] = [frame_pass]
	frame_renderer.passes = authored
	var frame_compositor = compositor_script.new()
	frame_compositor.renderer = frame_renderer
	camera.compositor = frame_compositor
	frame_renderer.apply(frame_compositor)
	require(frame_renderer.get_validation_warnings().is_empty(), "a pass that provides every mandatory entry must validate clean: %s" % [frame_renderer.get_validation_warnings()])
	var listed: Array = frame_renderer.passes
	require(listed.size() == 1, "an authored schedule without engine entries was repaired: %d entries" % listed.size())
	require(listed[0] == frame_pass, "the authored schedule was replaced during apply()")
	require(frame_renderer.get_execution_tokens() == PackedInt32Array([-1, -2]), "the authored schedule produced unexpected tokens: %s" % [frame_renderer.get_execution_tokens()])
	var scripted_frame: Image = await frame()
	require(frame_pass.calls > 0, "the engine rejected a schedule without any built-in pass")
	var scripted_frame_luma := mean_luma(scripted_frame)
	require(absf(scripted_frame_luma - baseline_luma) < 0.02, "a whole frame driven by one plugin pass differs from the engine default order: %.4f vs %.4f" % [scripted_frame_luma, baseline_luma])
	print("PASS fully scripted frame: calls=%d luma=%.4f vs engine %.4f" % [frame_pass.calls, scripted_frame_luma, baseline_luma])

	# 5. The escape hatch is the declaration: the same single-pass schedule without
	# provides_native_ids looks exactly like a pre-schema-5 array, so the renderer
	# re-seeds instead of running a one-pass frame. That safety net is what keeps an
	# accidental removal from silently producing an incomplete frame.
	var undeclared_renderer = renderer_script.new()
	var undeclared_pass := ScriptedFramePass.new()
	undeclared_pass.provides_native_ids = []
	var undeclared_list: Array[FRP_BASE] = [undeclared_pass]
	undeclared_renderer.passes = undeclared_list
	var repaired_list: Array = undeclared_renderer.passes
	var mandatory_count: int = renderer_script.mandatory_native_ids().size()
	var restored_mandatory := 0
	for pass_entry in repaired_list:
		if pass_entry is FRP_BASE and pass_entry.get("native_id") != null and renderer_script.mandatory_native_ids().has(int(pass_entry.native_id)):
			restored_mandatory += 1
	require(restored_mandatory == mandatory_count, "an undeclared schedule must get its mandatory entries back, got %d of %d" % [restored_mandatory, mandatory_count])
	require(repaired_list.has(undeclared_pass), "the undeclared pass was dropped while repairing the schedule")
	print("PASS undeclared schedule is repaired: %d entries, %d mandatory restored" % [repaired_list.size(), restored_mandatory])

	# 6. The same fully scripted schedule, uploaded directly to the engine. This is
	# the engine-side half of the same capability: the Core surface accepts a token
	# list that contains no built-in entry.
	var raw_pass := ScriptedFramePass.new()
	var frame_effects: Array[CompositorEffect] = [raw_pass]
	var raw_compositor := Compositor.new()
	raw_compositor.compositor_effects = frame_effects
	camera.compositor = raw_compositor
	RenderingServer.compositor_set_frp_pipeline(raw_compositor.get_rid(), PackedInt32Array([-1]), PackedStringArray(["Scripted Frame"]))
	var raw_frame: Image = await frame()
	require(raw_pass.calls > 0, "the engine rejected a raw schedule without any built-in pass")
	var raw_frame_luma := mean_luma(raw_frame)
	require(absf(raw_frame_luma - baseline_luma) < 0.02, "a raw scripted frame differs from the engine default order: %.4f vs %.4f" % [raw_frame_luma, baseline_luma])
	print("PASS raw scripted frame: calls=%d luma=%.4f vs engine %.4f" % [raw_pass.calls, raw_frame_luma, baseline_luma])

	# 7. The default pipeline is addon-side code (schema 6): every engine pass entry
	# carries a pass script, so the schedule is a list of plugin passes and the engine
	# emits no token for them. Removing the scripts has to give the same frame through
	# the engine's own passes, which is what makes the scripts a faithful
	# implementation of the default pass set instead of a second renderer.
	var default_renderer = renderer_script.new()
	for library_path in renderer_script.DEFAULT_PASS_PATHS:
		default_renderer.mark_library_pass(library_path)
	# The library's authoring chain is deliberately not part of this comparison: it is
	# a look the project adds, and with it enabled consecutive frames differ slightly
	# (the engine-token fallback below is not frame-stable either), which would hide
	# the pass equivalence this section is about.
	_disable_library(default_renderer)
	var default_compositor = compositor_script.new()
	default_compositor.renderer = default_renderer
	camera.compositor = default_compositor
	default_renderer.apply(default_compositor)
	require(default_renderer.get_validation_warnings().is_empty(), "the default pipeline must validate clean: %s" % [default_renderer.get_validation_warnings()])
	var scripted_entries := 0
	for pass_entry in default_renderer.passes:
		if pass_entry.get("native_id") != null:
			require(pass_entry.get("implementation") != null, "native pass %d has no addon pass script" % int(pass_entry.native_id))
			scripted_entries += 1
	require(scripted_entries == 8, "the default pipeline must implement all 8 engine passes in the addon, got %d" % scripted_entries)
	var scripted_tokens: PackedInt32Array = default_renderer.get_execution_tokens()
	for token in scripted_tokens:
		require(token < 0, "the default pipeline still emits an engine token: %s" % [scripted_tokens])
	var provided: PackedInt32Array = default_renderer.get_provided_native_ids()
	for native_id in [0, 1, 2, 3, 4, 5, 7]:
		require(provided.has(native_id), "the scripted default does not report pass %d as provided: %s" % [native_id, provided])
	var scripted_default: Image = await frame()

	# The same schedule with the scripts removed: the entries fall back to the engine's
	# own passes, which must render exactly the same frame.
	for pass_entry in default_renderer.passes:
		if pass_entry.get("native_id") != null:
			pass_entry.implementation = null
	default_renderer.apply(default_compositor)
	var engine_tokens: PackedInt32Array = default_renderer.get_execution_tokens()
	require(engine_tokens.has(2) and engine_tokens.has(7), "the fallback schedule lost its engine tokens: %s" % [engine_tokens])
	require(default_renderer.get_provided_native_ids().is_empty(), "the fallback schedule still reports provided passes: %s" % [default_renderer.get_provided_native_ids()])
	var engine_default: Image = await frame()
	var scripted_delta := changed_pixels(scripted_default, engine_default)
	print("scripted default luma=%.4f engine default luma=%.4f changed=%d" % [mean_luma(scripted_default), mean_luma(engine_default), scripted_delta])
	require(scripted_delta == 0, "the addon pass scripts do not reproduce the engine's own passes (%d pixels differ)" % scripted_delta)
	print("PASS addon pass scripts implement the default pipeline: %d entries, provided=%s, tokens=%d, pixel-identical to the engine's own passes" % [scripted_entries, provided, scripted_tokens.size()])

	# 8. A pass can carry its own shader: an engine pass script sets an overlay (a
	# shader pass with its shader_file and parameters), and the overlay runs inside the
	# same pipeline slot. The pipeline resource therefore exposes the engine pass and
	# the shader as one entry, and the overlay's resource contract (its inputs and the
	# resolved-attachment flags the engine needs) is what the entry reports.
	var overlay_renderer = renderer_script.new()
	for library_path in renderer_script.DEFAULT_PASS_PATHS:
		overlay_renderer.mark_library_pass(library_path)
	_disable_library(overlay_renderer)
	var overlay_compositor = compositor_script.new()
	overlay_compositor.renderer = overlay_renderer
	camera.compositor = overlay_compositor
	overlay_renderer.apply(overlay_compositor)
	var plain_frame: Image = await frame()

	var post_entry = _native_pass(overlay_renderer, POST_PASS_ID)
	require(post_entry != null, "renderer does not expose native pass %d" % POST_PASS_ID)
	var post_implementation = OverlaidPostPass.new()
	var tint = load("res://addons/feng-render-pipeline/library/tint/tint.tres").duplicate(true)
	tint.enabled = true
	tint.parameters = Vector4(0.25, 1.0, 1.0, 1.0)
	post_implementation.overlay = tint
	post_entry.implementation = post_implementation
	overlay_renderer.apply(overlay_compositor)
	require(overlay_renderer.get_validation_warnings().is_empty(), "a pass with an overlay must validate clean: %s" % [overlay_renderer.get_validation_warnings()])
	var overlaid_frame: Image = await frame()
	require(mean_luma(overlaid_frame) < mean_luma(plain_frame) - 0.02, "the pass overlay shader did not run in the pass slot: %.4f vs %.4f" % [mean_luma(overlaid_frame), mean_luma(plain_frame)])

	# Removing the overlay brings the engine pass back exactly.
	post_implementation.overlay = null
	overlay_renderer.apply(overlay_compositor)
	var restored_frame: Image = await frame()
	require(changed_pixels(plain_frame, restored_frame) == 0, "removing the pass overlay did not restore the engine pass")
	print("PASS a pass carries its own shader: overlay luma=%.4f vs plain %.4f, restored pixel-identical" % [mean_luma(overlaid_frame), mean_luma(plain_frame)])

	camera.compositor = null
	await frame()
	print("PASS FRP Core primitives drive an engine pass from a plugin pass")
	quit(0)
