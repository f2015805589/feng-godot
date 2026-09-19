extends SceneTree

# Temporal-AA regression for the FRP renderer.
#
# FRP replaces upstream's forward colour pass with a full-screen deferred
# lighting pass, so the G-buffer pass is the only geometry pass over opaque
# surfaces and it cannot write per-object motion vectors. Motion vectors must
# therefore come from the dedicated Motion Vectors pass, which has to run before
# Deferred Lighting. When that was wrong, attaching the velocity texture to the
# lighting framebuffer made pipeline creation fail and the whole frame went
# black. These checks guard every frame that needs motion vectors without 3D
# upscaling: TAA, the motion debug view, and upscaling itself.

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
			var pa := a.get_pixel(x, y)
			var pb := b.get_pixel(x, y)
			if max(max(abs(pa.r - pb.r), abs(pa.g - pb.g)), abs(pa.b - pb.b)) > 0.01:
				changed += 1
	return changed


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	root.msaa_3d = Viewport.MSAA_DISABLED
	root.use_taa = false
	root.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	root.scaling_3d_scale = 1.0
	root.debug_draw = Viewport.DEBUG_DRAW_DISABLED

	var scene := Node3D.new()
	root.add_child(scene)
	var camera := Camera3D.new()
	scene.add_child(camera)
	camera.position = Vector3(0, 0, 6)
	camera.current = true

	# Shallow-angle checker plane plus a small sphere: aliased edges are what TAA
	# resolves, so a working TAA has to change those pixels.
	var plane := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(60, 60)
	plane.mesh = pm
	plane.rotation_degrees = Vector3(-82, 0, 0)
	plane.position = Vector3(0, -1.0, 0)
	var pmat := StandardMaterial3D.new()
	pmat.albedo_color = Color(0.9, 0.9, 0.9)
	pm.material = pmat
	scene.add_child(plane)

	var sphere := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.35
	sm.height = 0.7
	sphere.mesh = sm
	sphere.position = Vector3(0.6, 0.1, 0)
	var smat := StandardMaterial3D.new()
	smat.albedo_color = Color(0.1, 0.1, 0.1)
	smat.roughness = 0.05
	sm.material = smat
	scene.add_child(sphere)

	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.05, 0.08, 0.15)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	environment.environment.ambient_light_energy = 1.0
	scene.add_child(environment)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, 30, 0)
	light.light_energy = 1.5
	scene.add_child(light)

	# Control: a static scene without TAA is deterministic, so any later
	# difference is attributable to the feature under test.
	var off_a: Image = await frame()
	var off_b: Image = await frame()
	require(changed_pixels(off_a, off_b) == 0, "static no-TAA frames differ; harness is not deterministic")
	var off_luma := mean_luma(off_b)
	require(off_luma > 0.02, "no-TAA baseline is not lit: %.4f" % off_luma)
	var off_draws := RenderingServer.viewport_get_render_info(root.get_viewport_rid(), RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME)
	require(off_draws > 0, "the draw call counter reports nothing; the shared G-buffer pass guard would be vacuous")

	# TAA without 3D upscaling: this is the path that used to fail pipeline
	# creation and render a fully black frame.
	root.use_taa = true
	var taa_a: Image = await frame()
	var taa_draws := RenderingServer.viewport_get_render_info(root.get_viewport_rid(), RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME)
	var taa_luma := mean_luma(taa_a)
	require(taa_luma > off_luma * 0.5, "TAA frame is not lit (deferred lighting did not draw): %.4f vs %.4f" % [taa_luma, off_luma])
	# Motion vectors are written by the G-buffer pass in the same draw, so needing them
	# must not add a second geometry pass over the opaque surfaces. Before that, TAA
	# (and the motion debug view) re-drew every opaque surface, which this guards.
	require(taa_draws <= off_draws + 2, "TAA added %d draw calls over %d: motion vectors are not sharing the G-buffer pass" % [taa_draws, off_draws])
	var total_pixels := taa_a.get_width() * taa_a.get_height()
	var taa_changed := changed_pixels(off_b, taa_a)
	require(taa_changed > 0, "TAA had no effect on the frame")
	require(taa_changed < total_pixels / 2, "TAA destroyed the frame (%d/%d pixels changed)" % [taa_changed, total_pixels])
	root.use_taa = false
	await frame()

	# The motion debug view forces motion vectors without upscaling and used to
	# black out for the same reason as TAA.
	root.debug_draw = Viewport.DEBUG_DRAW_MOTION_VECTORS
	var mvs_image: Image = await frame()
	var mvs_draws := RenderingServer.viewport_get_render_info(root.get_viewport_rid(), RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME)
	var mvs_luma := mean_luma(mvs_image)
	require(mvs_luma > 0.02, "motion vector debug view is not lit: %.4f" % mvs_luma)
	require(mvs_draws <= off_draws + 2, "the motion debug view added %d draw calls over %d: motion vectors are not sharing the G-buffer pass" % [mvs_draws, off_draws])
	root.debug_draw = Viewport.DEBUG_DRAW_DISABLED
	await frame()

	# 3D upscaling already produced motion vectors; keep it working.
	root.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2
	root.scaling_3d_scale = 0.5
	var fsr2_image: Image = await frame()
	var fsr2_luma := mean_luma(fsr2_image)
	require(fsr2_luma > off_luma * 0.5, "FSR2 upscaling frame is not lit: %.4f vs %.4f" % [fsr2_luma, off_luma])
	root.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	root.scaling_3d_scale = 1.0
	await frame()

	# The Temporal AA entry is the TAA switch while a schedule is authored, and the
	# viewport jitter follows it (see RendererSceneCull::render_camera). With the entry
	# disabled, turning the viewport's TAA on must therefore leave the frame exactly
	# as it was instead of jittering it with nobody doing the temporal resolve.
	var renderer_script = load("res://addons/feng-render-pipeline/renderer.gd")
	var compositor_script = load("res://addons/feng-render-pipeline/compositor.gd")
	require(renderer_script != null and compositor_script != null, "FRP addon scripts did not load")
	var renderer = renderer_script.new()
	var temporal = null
	for pass_entry in renderer.passes:
		if pass_entry.get("native_id") != null:
			if int(pass_entry.native_id) == 6:
				temporal = pass_entry
		else:
			pass_entry.enabled = false
	require(temporal != null, "renderer does not expose native pass 6")
	temporal.enabled = false
	var feng_compositor = compositor_script.new()
	feng_compositor.renderer = renderer
	camera.compositor = feng_compositor
	renderer.apply(feng_compositor)
	require(not renderer.get_execution_tokens().has(6) and not renderer.get_provided_native_ids().has(6), "the authored schedule unexpectedly contains pass 6")

	root.use_taa = false
	var entry_off_no_taa: Image = await frame()
	root.use_taa = true
	var entry_off_image: Image = await frame()
	require(mean_luma(entry_off_image) > off_luma * 0.5, "disabling the Temporal AA entry voided the frame: %.4f vs %.4f" % [mean_luma(entry_off_image), off_luma])
	require(changed_pixels(entry_off_no_taa, entry_off_image) == 0, "the frame was jittered while the Temporal AA entry was disabled")

	# The entry alone turns TAA on: the viewport flag stays off and the renderer still
	# jitters and resolves, so "enabling the pass enables the feature" holds.
	temporal.enabled = true
	renderer.apply(feng_compositor)
	var entry_on_image: Image = await frame()
	# A native entry is driven by the addon's pass script (schema 6), so it reaches the
	# engine as a provided pass rather than as a native token; either way it has to be
	# in the schedule.
	require(renderer.get_execution_tokens().has(6) or renderer.get_provided_native_ids().has(6), "the enabled Temporal AA entry is missing from the schedule")
	require(mean_luma(entry_on_image) > off_luma * 0.5, "enabling the Temporal AA entry voided the frame")
	require(changed_pixels(entry_off_no_taa, entry_on_image) > 0, "enabling the Temporal AA entry with Viewport.use_taa off did not turn TAA on")

	# The entry's parameters come from the pipeline resource. `jitter_phases` sizes the
	# jitter cycle the viewport uses, and one phase freezes the sampling pattern while
	# Temporal AA still resolves, which makes the parameter observable from the frames
	# alone instead of by inspecting engine state.
	#
	# It is declared by the pass script itself (a typed export, so the pipeline resource
	# shows one field for this pass) rather than as free-form data.
	root.use_taa = false
	var aa_implementation = load("res://addons/feng-render-pipeline/passes/native/temporal_aa_pass.gd").new()
	require(aa_implementation.get_frp_parameters().has("jitter_phases"), "the Temporal AA pass does not expose jitter_phases")
	temporal.implementation = aa_implementation
	temporal.pass_parameters = {}
	aa_implementation.jitter_phases = 1
	renderer.apply(feng_compositor)
	for i in 4:
		await frame()
	var frozen_a: Image = await frame()
	var frozen_b: Image = await frame()
	var declared_frozen := changed_pixels(frozen_a, frozen_b)
	require(mean_luma(frozen_a) > off_luma * 0.5, "jitter_phases=1 voided the frame")

	aa_implementation.jitter_phases = 16
	renderer.apply(feng_compositor)
	var authored_a: Image = await frame()
	var authored_b: Image = await frame()
	var authored_motion := changed_pixels(authored_a, authored_b)
	require(authored_motion > 0, "the Temporal AA entry stopped jittering entirely")
	require(declared_frozen * 4 < authored_motion, "the pass's declared jitter_phases did not change the jitter (%d vs %d pixels)" % [declared_frozen, authored_motion])

	# The entry's own dictionary overrides what the pass declared, so a pipeline can
	# change one value without editing the pass resource.
	temporal.pass_parameters = {"jitter_phases": 1}
	renderer.apply(feng_compositor)
	for i in 12:
		await frame()
	var overridden_a: Image = await frame()
	var overridden_b: Image = await frame()
	var overridden_motion := changed_pixels(overridden_a, overridden_b)
	# Re-uploading the schedule restarts the temporal accumulation, so the warm-up above
	# is what makes the comparison about the sampling pattern rather than about the
	# frames right after a configuration change.
	require(overridden_motion * 4 < authored_motion, "the entry's pass_parameters did not override the declared value (%d vs %d pixels)" % [overridden_motion, authored_motion])
	require(renderer.get_pass_parameters().get(6, {}).get("jitter_phases", 0) == 1, "the entry override is missing from the authored parameters: %s" % [renderer.get_pass_parameters()])
	temporal.pass_parameters = {}
	print("PASS a pass declares its parameters and the entry overrides them (%d declared / %d authored / %d overridden pixels of movement)" % [declared_frozen, authored_motion, overridden_motion])

	# A volume overrides a pass parameter while the camera is inside it, which is how
	# FRP gets URP-style volume overrides without going through the engine's
	# Environment: the profile belongs to FRP, and the volumes around the active camera
	# are resolved per frame.
	var volume_profile_script = load("res://addons/feng-render-pipeline/volume/feng_volume_profile.gd")
	var volume_script = load("res://addons/feng-render-pipeline/volume/feng_volume.gd")
	require(volume_profile_script != null and volume_script != null, "FRP volume scripts did not load")
	aa_implementation.jitter_phases = 16
	renderer.apply(feng_compositor)
	var volume_profile = volume_profile_script.new()
	volume_profile.pass_parameters = {6: {"jitter_phases": 1}}
	var volume = volume_script.new()
	volume.profile = volume_profile
	volume.size = Vector3(20.0, 20.0, 20.0)
	scene.add_child(volume)
	volume.global_position = camera.global_position
	# Re-uploading the schedule restarts the temporal accumulation, so let it settle
	# before comparing frames: the point is the frozen sampling pattern, not the first
	# frames after a configuration change.
	for i in 8:
		await frame()
	var in_volume_a: Image = await frame()
	var in_volume_b: Image = await frame()
	var volume_frozen := changed_pixels(in_volume_a, in_volume_b)
	require(renderer.get_volume_parameters().has(6), "the volume overrides did not reach the renderer: %s" % [renderer.get_volume_parameters()])
	volume.global_position = camera.global_position + Vector3(100.0, 0.0, 0.0)
	var out_of_volume_a: Image = await frame()
	var out_of_volume_b: Image = await frame()
	var volume_jittered := changed_pixels(out_of_volume_a, out_of_volume_b)
	require(volume_frozen * 4 < volume_jittered, "a volume inside the camera did not override the Temporal AA jitter (%d vs %d pixels)" % [volume_frozen, volume_jittered])
	require(renderer.get_volume_parameters().is_empty(), "the volume overrides were not cleared: %s" % [renderer.get_volume_parameters()])
	print("PASS a FengVolume overrides pass parameters while the camera is inside it (%d vs %d pixels of movement)" % [volume_frozen, volume_jittered])

	# Unreal-style volume controls. An unbound volume (Unreal ticks "Unbound") applies
	# to every camera, and a blend distance ramps the weight in from the box edges.
	volume.unbound = true
	require(volume.influence_at(camera.global_position + Vector3(500.0, 0.0, 0.0)) > 0.0, "an unbound volume does not reach a camera outside its box")
	volume.queue_free()

	volume = volume_script.new()
	volume.profile = volume_profile
	volume.size = Vector3(20.0, 20.0, 20.0)
	volume.blend_distance = 10.0
	scene.add_child(volume)
	# The camera sits 8 units off the volume's centre, so it is 2 units inside the near
	# face: with a 10 unit blend distance the override is applied at 20%.
	volume.global_position = camera.global_position + Vector3(-8.0, 0.0, 0.0)
	var blended_influence: float = volume.influence_at(camera.global_position)
	require(blended_influence > 0.1 and blended_influence < 0.4, "the blend distance did not ramp the volume in: %.2f" % blended_influence)
	await frame()
	var blended_phases: Variant = renderer.get_volume_parameters().get(6, {}).get("jitter_phases", null)
	require(blended_phases != null and blended_phases > 1 and blended_phases < 16, "the blended override is not between the authored and the volume value: %s" % [blended_phases])
	volume.enabled = false
	await frame()
	require(renderer.get_volume_parameters().is_empty(), "disabling the volume did not clear its override: %s" % [renderer.get_volume_parameters()])
	volume.queue_free()
	print("PASS unbound and blend distance behave like an Unreal post process volume (blended jitter_phases=%.1f)" % [blended_phases])

	# A volume switches whole passes on and off without touching the pass resources: the
	# entry keeps its authored state and the schedule (and the engine's provided pass
	# set) follows the volume while the camera is inside it.
	root.use_taa = false
	temporal.pass_parameters = {}
	temporal.implementation = null
	temporal.enabled = true
	renderer.apply(feng_compositor)
	for i in 4:
		await frame()
	var authored_on: Image = await frame()
	require(changed_pixels(entry_off_no_taa, authored_on) > 0, "the authored Temporal AA entry is not running")

	var toggle_profile = volume_profile_script.new()
	# The profile's pass lists are typed arrays, so the test builds typed ones too.
	var off_ids: Array[int] = [6]
	toggle_profile.disabled_passes = off_ids
	var toggle_volume = volume_script.new()
	toggle_volume.profile = toggle_profile
	toggle_volume.size = Vector3(20.0, 20.0, 20.0)
	scene.add_child(toggle_volume)
	toggle_volume.global_position = camera.global_position
	for i in 4:
		await frame()
	var switched_off: Image = await frame()
	require(temporal.enabled, "the volume override changed the authored entry instead of layering over it")
	require(renderer.get_volume_pass_states().get(6, true) == false, "the volume did not report the pass state: %s" % [renderer.get_volume_pass_states()])
	require(changed_pixels(entry_off_no_taa, switched_off) == 0, "the volume did not switch the Temporal AA pass off")

	# The other direction: the entry is authored off and the volume switches it on,
	# which also has to put the pass back into the provided set for the viewport jitter.
	temporal.enabled = false
	var no_ids: Array[int] = []
	toggle_profile.disabled_passes = no_ids
	var on_ids: Array[int] = [6]
	toggle_profile.enabled_passes = on_ids
	renderer.apply(feng_compositor)
	for i in 4:
		await frame()
	var switched_on: Image = await frame()
	require(not temporal.enabled, "the volume override changed the authored entry instead of layering over it")
	require(changed_pixels(entry_off_no_taa, switched_on) > 0, "the volume did not switch the Temporal AA pass on")
	toggle_volume.queue_free()
	await frame()
	print("PASS a volume switches whole passes on and off without touching the pass resources")

	# The same switch through a plugin pass: the whole frame is driven by one pass, and
	# declaring that it provides Temporal AA is what turns the feature on. The viewport
	# flag stays off, so the declaration is the only thing that can enable it: it is
	# what keeps the viewport jitter on (the primitive then has a jittered history to
	# accumulate) and what lets the renderer run the temporal resolve. Both frames come
	# from the same pass, so the only difference between them is the declaration.
	root.use_taa = false
	var scripted_renderer = renderer_script.new()
	for library_path in renderer_script.DEFAULT_PASS_PATHS:
		scripted_renderer.mark_library_pass(library_path)
	var scripted_frame := ScriptedTaaPass.new()
	scripted_frame.provides_native_ids = [0, 1, 2, 3, 7]
	var scripted_list: Array[PASS_BASE] = [scripted_frame]
	scripted_renderer.passes = scripted_list
	var scripted_compositor = compositor_script.new()
	scripted_compositor.renderer = scripted_renderer
	camera.compositor = scripted_compositor
	scripted_renderer.apply(scripted_compositor)
	require(scripted_renderer.get_validation_warnings().is_empty(), "a plugin-provided Temporal AA schedule must validate clean: %s" % [scripted_renderer.get_validation_warnings()])
	var scripted_no_taa: Image = await frame()

	scripted_frame.provides_native_ids = [0, 1, 2, 3, 6, 7]
	scripted_renderer.apply(scripted_compositor)
	require(not scripted_renderer.get_execution_tokens().has(6), "a provided Temporal AA pass must not keep entry 6 in the schedule")
	var provided_taa_image: Image = await frame()
	require(scripted_frame.calls > 0, "the scripted Temporal AA pass was never executed by the renderer")
	require(mean_luma(provided_taa_image) > off_luma * 0.5, "a plugin-provided Temporal AA pass voided the frame")
	require(changed_pixels(scripted_no_taa, provided_taa_image) > 0, "declaring Temporal AA in provides_native_ids did not turn TAA on")

	temporal.enabled = false
	renderer.apply(feng_compositor)
	root.use_taa = false
	camera.compositor = null
	await frame()

	print("PASS TAA, motion debug view and FSR2 upscaling all keep the FRP frame lit; the Temporal AA entry is the switch")
	print("PASS a plugin pass provides Temporal AA and keeps the viewport jitter")
	quit(0)


# Drives the whole frame from one plugin pass that can also provide Temporal AA.
class ScriptedTaaPass extends FengPass:
	var calls := 0

	func _init() -> void:
		stage = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
		resource_name = "Scripted TAA Frame"
		provides_native_ids = [0, 1, 2, 3, 6, 7]

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


const PASS_BASE = preload("res://addons/feng-render-pipeline/passes/pass_base.gd")
