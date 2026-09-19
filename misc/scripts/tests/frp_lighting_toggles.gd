extends SceneTree

# FRP has no screen space effects and no global illumination: SSAO, SSIL, SSR,
# SDFGI and VoxelGI are not FRP passes, so the Environment's switches for them
# must not change an FRP frame at all. That is the property checked first here.
#
# The suite then pins down what the remaining entries do have: an entry is a real
# toggle (Sky is the conditional one), and a plugin pass can provide a native pass
# through provides_native_ids and run it with the Core primitives.

var scene: Node3D
var environment: Environment
var camera: Camera3D
var sun: DirectionalLight3D


func require(value: bool, message: String) -> void:
	if not value:
		push_error("REGRESSION: " + message)
		quit(1)
		assert(value, message)


func frame() -> Image:
	for i in 8:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


func mean_luminance(image: Image) -> float:
	var total := 0.0
	var count := 0
	for y in range(4, image.get_height() - 4, 2):
		for x in range(4, image.get_width() - 4, 2):
			var c := image.get_pixel(x, y)
			total += c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722
			count += 1
	return total / maxf(float(count), 1.0)


## Largest per-pixel luminance difference between two frames.
func max_luminance_delta(a: Image, b: Image) -> float:
	var best := 0.0
	for y in range(4, a.get_height() - 4, 2):
		for x in range(4, a.get_width() - 4, 2):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			var la := ca.r * 0.2126 + ca.g * 0.7152 + ca.b * 0.0722
			var lb := cb.r * 0.2126 + cb.g * 0.7152 + cb.b * 0.0722
			best = maxf(best, absf(la - lb))
	return best


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	print("START FRP lighting toggle tests")
	root.msaa_3d = Viewport.MSAA_DISABLED

	scene = Node3D.new()
	root.add_child(scene)

	camera = Camera3D.new()
	camera.position = Vector3(0.0, 2.2, 5.5)
	camera.rotation_degrees = Vector3(-14.0, 0.0, 0.0)
	camera.current = true
	scene.add_child(camera)

	# Floor plus a box: the contact area is where screen-space occlusion would be
	# strongest if FRP had any. A smooth metallic sphere gives SSR something to
	# reflect, again only to prove it does not.
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(30.0, 30.0)
	floor_mesh.mesh = plane
	var floor_material := StandardMaterial3D.new()
	floor_material.albedo_color = Color(0.75, 0.75, 0.75)
	floor_material.roughness = 0.9
	floor_mesh.material_override = floor_material
	scene.add_child(floor_mesh)

	var blocker := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(2.0, 2.0, 2.0)
	blocker.mesh = box
	blocker.position = Vector3(-0.8, 1.0, 0.0)
	scene.add_child(blocker)

	var sphere := MeshInstance3D.new()
	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = 0.9
	sphere_mesh.height = 1.8
	sphere.mesh = sphere_mesh
	sphere.position = Vector3(1.6, 0.9, 0.0)
	var sphere_material := StandardMaterial3D.new()
	sphere_material.albedo_color = Color(0.9, 0.9, 0.9)
	sphere_material.metallic = 1.0
	sphere_material.roughness = 0.05
	sphere.material_override = sphere_material
	scene.add_child(sphere)

	# A shadow-casting sun: the Shadow Precompute pass (id 0) is the only place FRP
	# draws shadow maps, and it is the pipeline's first entry, so this scene proves the
	# pass order still produces working shadows. Shadows start off so the screen-space
	# and sky sections below measure exactly what they say they measure.
	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55.0, -35.0, 0.0)
	sun.light_energy = 1.0
	sun.shadow_enabled = false
	scene.add_child(sun)

	environment = Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.0, 0.0, 0.0)
	# Ambient-only lighting: screen-space occlusion and indirect light would be the
	# only things that vary, instead of being swamped by a directional light.
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.WHITE
	environment.ambient_light_energy = 1.5
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	scene.add_child(world_environment)

	var renderer_script = load("res://addons/feng-render-pipeline/renderer.gd")
	require(renderer_script != null, "FRP renderer script did not load")
	var renderer = renderer_script.new()
	var entries := {}
	for pass_entry in renderer.passes:
		if pass_entry.get("native_id") != null:
			entries[int(pass_entry.native_id)] = pass_entry
		else:
			pass_entry.enabled = false
	var compositor := Compositor.new()
	camera.compositor = compositor

	# 1. The removed entries are gone from the authorable set, and the Environment
	# switches for them are inert: FRP has no attachment to occlude, reflect or
	# bounce into, so turning every one of them on has to leave the frame identical.
	# SDFGI is in this set too: FRP no longer creates, updates or renders an SDFGI at
	# all (it used to render cascades nothing consumed).
	for removed_id in [8, 9, 10, 11, 12]:
		require(not entries.has(removed_id), "renderer still exposes removed native pass %d" % removed_id)

	environment.ssao_enabled = true
	environment.ssao_radius = 2.0
	environment.ssao_intensity = 3.0
	environment.ssil_enabled = true
	environment.ssr_enabled = true
	environment.ssr_max_steps = 64
	environment.sdfgi_enabled = true
	renderer.apply(compositor)
	var with_ss := await frame()

	environment.ssao_enabled = false
	environment.ssil_enabled = false
	environment.ssr_enabled = false
	environment.sdfgi_enabled = false
	renderer.apply(compositor)
	var without_ss := await frame()

	var ss_delta := max_luminance_delta(with_ss, without_ss)
	print("Environment SSAO/SSIL/SSR/SDFGI in FRP: delta=%.4f" % ss_delta)
	require(mean_luminance(without_ss) > 0.01, "the frame is not lit")
	require(ss_delta < 0.001, "Environment screen space effects or SDFGI changed an FRP frame (delta %.4f)" % ss_delta)

	# 2. Sky is a conditional entry: it only does work when the environment draws a
	# sky. Disabling it has to remove the sky rather than be a no-op.
	require(entries.has(4), "renderer does not expose the Sky entry")
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	entries[4].enabled = true
	renderer.apply(compositor)
	var with_sky := await frame()
	entries[4].enabled = false
	renderer.apply(compositor)
	var without_sky := await frame()
	var sky_delta := max_luminance_delta(with_sky, without_sky)
	print("Sky (id 4): on/off delta=%.4f" % sky_delta)
	require(sky_delta > 0.02, "disabling the Sky entry did not remove the sky (delta %.4f)" % sky_delta)
	entries[4].enabled = true
	renderer.apply(compositor)
	await frame()

	# 3. A plugin pass can provide a native pass: it declares the native id in
	# provides_native_ids and drives the pass with the Core primitives. The engine
	# reads that declaration, so the schedule stays complete and validates clean
	# even though the engine entry for that id is switched off.
	var scripted_sky := ScriptedSkyPass.new()
	_replace_entry(renderer, 4, scripted_sky)
	renderer.apply(compositor)
	require(renderer.get_validation_warnings().is_empty(), "a declared Sky takeover must validate clean: %s" % [renderer.get_validation_warnings()])
	var provided_sky := await frame()
	require(scripted_sky.calls > 0, "the scripted Sky pass was never executed by the renderer")
	var takeover_delta := max_luminance_delta(with_sky, provided_sky)
	print("Sky provided by a plugin pass: control delta=%.4f  takeover delta=%.4f" % [sky_delta, takeover_delta])
	require(takeover_delta < 0.01, "a plugin-provided Sky pass did not reproduce the engine entry (delta %.4f)" % takeover_delta)

	# 4. Shadow Precompute (id 0) is the only source of shadow maps, and it is the
	# pipeline's first entry: it runs before the virtual texture pass and the G-buffer,
	# because drawing a shadow map reads no scene depth and no material page.
	require(entries.has(0), "renderer does not expose the Shadow Precompute entry")
	sun.shadow_enabled = true
	renderer.apply(compositor)
	var with_shadow := await frame()
	sun.shadow_enabled = false
	renderer.apply(compositor)
	var without_shadow := await frame()
	var shadow_delta := max_luminance_delta(with_shadow, without_shadow)
	print("Shadow Precompute (id 0): shadows on/off delta=%.4f" % shadow_delta)
	require(shadow_delta > 0.02, "the Shadow Precompute pass did not draw the shadow maps (delta %.4f)" % shadow_delta)

	# A plugin pass can provide pass 0 too: declaring the id and calling
	# ctx.precompute_shadows() has to reproduce the engine entry exactly.
	sun.shadow_enabled = true
	var scripted_shadow := ScriptedShadowPass.new()
	_replace_entry(renderer, 0, scripted_shadow)
	renderer.apply(compositor)
	require(renderer.get_validation_warnings().is_empty(), "a declared Shadow Precompute takeover must validate clean: %s" % [renderer.get_validation_warnings()])
	var provided_shadow := await frame()
	require(scripted_shadow.calls > 0, "the scripted Shadow Precompute pass was never executed by the renderer")
	var shadow_takeover := max_luminance_delta(with_shadow, provided_shadow)
	print("Shadow Precompute provided by a plugin pass: delta=%.4f" % shadow_takeover)
	require(shadow_takeover < 0.01, "a plugin-provided Shadow Precompute pass did not reproduce the engine entry (delta %.4f)" % shadow_takeover)

	print("PASS FRP ignores Environment SSAO/SSIL/SSR/SDFGI and the Sky entry is a real toggle")
	print("PASS Shadow Precompute draws the frame's shadow maps as the first pass")
	print("PASS a plugin pass provides a native pass through provides_native_ids")
	scene.queue_free()
	await process_frame
	quit()


# Takes the Shadow Precompute entry over and runs its operation through the Core
# surface.
class ScriptedShadowPass extends FengPass:
	var calls := 0

	func _init() -> void:
		stage = EFFECT_CALLBACK_TYPE_PRE_GBUFFER
		resource_name = "Scripted Shadow Precompute"
		# The declaration is what tells the engine the pass is part of the frame: the
		# schedule dropped the engine entry, and pass 0 is mandatory.
		provides_native_ids = [0]

	func _frp_execute(ctx: FRPPassContext) -> void:
		calls += 1
		ctx.precompute_shadows()


# Takes the Sky entry over and runs its operations through the Core surface.
class ScriptedSkyPass extends FengPass:
	var calls := 0

	func _init() -> void:
		stage = EFFECT_CALLBACK_TYPE_POST_LIGHTING
		resource_name = "Scripted Sky"
		# The declaration is what tells the engine the pass is part of the frame:
		# the schedule dropped the engine entry, so without this the validator would
		# report the Sky position as missing.
		provides_native_ids = [4]

	func _frp_execute(ctx: FRPPassContext) -> void:
		calls += 1
		ctx.run_pass(4)


const PASS_BASE = preload("res://addons/feng-render-pipeline/passes/pass_base.gd")


# Replaces an engine entry with a scripted pass at the same list position.
func _replace_entry(renderer: Object, native_id: int, scripted) -> void:
	# The renderer's `passes` property is a typed array, so the authored list has to
	# be typed as well.
	var values: Array[PASS_BASE] = []
	var replaced := false
	for pass_entry in renderer.passes:
		if not pass_entry is PASS_BASE:
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
