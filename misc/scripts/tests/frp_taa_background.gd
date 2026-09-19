extends SceneTree

# Temporal-AA background regression for the FRP renderer.
#
# The engine clears the velocity attachment to (-1, -1), its "this pixel has no
# motion vector" marker, and only the G-buffer pass writes the attachment. The sky
# pass draws into a colour-only framebuffer, so every background pixel keeps the
# marker, and so does every pixel of the clear colour in a colour-background frame.
#
# TAA has to reproject those pixels like any other. Nothing used to turn the marker
# into motion: the resolve reads it as a velocity and reprojects the pixel a whole
# screen outside the frame, which makes it blend the current sample in whole and
# drop its history. The background therefore never accumulates, and a silhouette
# against it flickers: the object side accumulates, the background side does not,
# and the sub-pixel jitter moves the coverage of the edge pixels back and forth
# between the two.
#
# These checks are the stability a static camera has to have. A flat background
# frame must be pixel-identical between two consecutive resolved frames (only the
# silhouette may still move, by the resolve's own 1/16 blend), and a high-frequency
# sky must stop moving too instead of showing a freshly jittered sample per frame.

const PANORAMA_SIZE := Vector2i(256, 128)
# Sky only: the box below covers the middle of the frame.
const SKY_RECT := Rect2i(0, 0, 48, 32)
const SKY_DEVIATION_MIN := 0.05
# A changed pixel counts from here. The resolve blends 1/16 of the current sample
# per frame, so a converged edge stays under it (worst measured: 0.039, and 0.035 on
# the flat-background frame); a background blended in whole moves by the full
# contrast between the object and the background (worst measured: 0.627).
const CHANGED_THRESHOLD := 0.08
const MAX_CHANGED_FRACTION := 0.01

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


func mean_abs_difference(a: Image, b: Image, rect: Rect2i) -> float:
	var sum := 0.0
	for y in range(rect.position.y, rect.position.y + rect.size.y):
		for x in range(rect.position.x, rect.position.x + rect.size.x):
			var pa := a.get_pixel(x, y)
			var pb := b.get_pixel(x, y)
			sum += (absf(pa.r - pb.r) + absf(pa.g - pb.g) + absf(pa.b - pb.b)) / 3.0
	return sum / float(rect.size.x * rect.size.y)


func max_abs_difference(a: Image, b: Image) -> float:
	var worst := 0.0
	for y in a.get_height():
		for x in a.get_width():
			var pa := a.get_pixel(x, y)
			var pb := b.get_pixel(x, y)
			var d: float = maxf(maxf(absf(pa.r - pb.r), absf(pa.g - pb.g)), absf(pa.b - pb.b))
			worst = maxf(worst, d)
	return worst


func changed_pixels(a: Image, b: Image) -> int:
	var changed := 0
	for y in a.get_height():
		for x in a.get_width():
			var pa := a.get_pixel(x, y)
			var pb := b.get_pixel(x, y)
			var d: float = maxf(maxf(absf(pa.r - pb.r), absf(pa.g - pb.g)), absf(pa.b - pb.b))
			if d > CHANGED_THRESHOLD:
				changed += 1
	return changed


# How much the region reacts to a sub-pixel shift: it is what makes the
# temporal check below meaningful, so a flat region has to fail here instead.
func spatial_deviation(image: Image, rect: Rect2i) -> float:
	var values: Array[float] = []
	var mean := 0.0
	for y in range(rect.position.y, rect.position.y + rect.size.y):
		for x in range(rect.position.x, rect.position.x + rect.size.x):
			var p := image.get_pixel(x, y)
			var luma := (p.r + p.g + p.b) / 3.0
			values.push_back(luma)
			mean += luma
	mean /= float(values.size())
	var variance := 0.0
	for value in values:
		variance += (value - mean) * (value - mean)
	return sqrt(variance / float(values.size()))


func noise_panorama() -> ImageTexture:
	var image := Image.create(PANORAMA_SIZE.x, PANORAMA_SIZE.y, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260214
	for y in PANORAMA_SIZE.y:
		for x in PANORAMA_SIZE.x:
			image.set_pixel(x, y, Color(rng.randf_range(0.15, 1.0), rng.randf_range(0.15, 1.0), rng.randf_range(0.3, 1.0)))
	return ImageTexture.create_from_image(image)


# 16 jitter phases at a 1/16 blend converge after a few dozen frames; every
# measurement below is taken on a settled history.
func settle() -> void:
	for i in 14:
		await frame()


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
	camera.position = Vector3(0, 0, 5)
	camera.current = true

	# A dark box against the background: its silhouette is the edge the sub-pixel
	# jitter moves, and its flat faces are the control (they must not move at all).
	var box := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(2.0, 2.0, 2.0)
	box.mesh = bm
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = Color(0.04, 0.04, 0.05)
	bmat.metallic = 0.0
	bmat.roughness = 1.0
	bm.material = bmat
	scene.add_child(box)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, 30, 0)
	light.light_energy = 1.5
	scene.add_child(light)

	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	# A colour background is the clear colour: it is already flat, so it isolates the
	# silhouette. The sky below is the case the report is about.
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.35, 0.55, 0.85)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	environment.environment.ambient_light_energy = 1.0
	scene.add_child(environment)

	# Control: without TAA the frame is not jittered, so it is deterministic and any
	# difference measured below belongs to the temporal resolve.
	var off_a: Image = await frame()
	var off_b: Image = await frame()
	require(max_abs_difference(off_a, off_b) == 0.0, "static no-TAA frames differ; the harness is not deterministic")
	var total_pixels := off_a.get_width() * off_a.get_height()

	# Colour background, TAA on, static camera.
	root.use_taa = true
	await settle()
	var flat_a: Image = await frame()
	var flat_b: Image = await frame()
	var flat_changed := changed_pixels(flat_a, flat_b)
	var flat_max := max_abs_difference(flat_a, flat_b)
	# Where the movement is says what went wrong: the object's interior and the flat
	# background corner are the control (they must not move whatever the silhouette
	# does, or the scene rather than TAA is moving), and the silhouette band is where the
	# jitter flips an edge pixel's coverage between the object and the background.
	var interior_mean := mean_abs_difference(flat_a, flat_b, Rect2i(150, 110, 20, 20))
	var corner_mean := mean_abs_difference(flat_a, flat_b, Rect2i(0, 0, 24, 16))
	var band_mean := mean_abs_difference(flat_a, flat_b, Rect2i(110, 70, 100, 100))
	require(flat_changed == 0,
			"a static frame still changes with TAA on: %d of %d pixels (worst pixel %.3f; mean over the object %.4f, over the background corner %.4f, over the silhouette band %.4f); the background is not accumulating"
			% [flat_changed, total_pixels, flat_max, interior_mean, corner_mean, band_mean])
	print("PASS a colour background with TAA on is stable over a static frame (changed %d/%d, worst %.4f)" % [flat_changed, total_pixels, flat_max])

	# The reported case: a detailed sky. A sky pixel samples the panorama through the
	# jittered projection, so a pixel that is not accumulated changes every frame by a
	# large fraction of the panorama's local contrast.
	environment.environment.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_material := PanoramaSkyMaterial.new()
	sky_material.panorama = noise_panorama()
	sky.sky_material = sky_material
	environment.environment.sky = sky
	await settle()
	var sky_probe: Image = await frame()
	var deviation := spatial_deviation(sky_probe, SKY_RECT)
	require(deviation > SKY_DEVIATION_MIN, "the sky region is flat (deviation %.4f); the check below would be vacuous" % deviation)
	var sky_a: Image = await frame()
	var sky_b: Image = await frame()
	var sky_mean := mean_abs_difference(sky_a, sky_b, SKY_RECT)
	var sky_changed := changed_pixels(sky_a, sky_b)
	require(sky_mean < 0.05,
			"the sky does not accumulate: consecutive static frames differ by %.4f on average in the sky region (worst pixel %.3f, %d of %d pixels over the frame)"
			% [sky_mean, max_abs_difference(sky_a, sky_b), sky_changed, total_pixels])
	require(sky_changed < int(total_pixels * MAX_CHANGED_FRACTION),
			"%d of %d pixels still change under a static camera with a sky (%d allowed)" % [sky_changed, total_pixels, int(total_pixels * MAX_CHANGED_FRACTION)])
	print("PASS a detailed sky with TAA on accumulates over a static frame (sky mean %.4f, worst %.4f, changed %d/%d)" % [sky_mean, max_abs_difference(sky_a, sky_b), sky_changed, total_pixels])

	# The other half of the same fix: the filled motion vectors have to follow the
	# camera, not read as "no motion". Turning the camera over the same angle has to
	# change the sky by about as much with TAA on as it does without it; a background
	# held at zero velocity would instead sit on its own history and barely move.
	camera.rotation_degrees = Vector3(0, -6, 0)
	root.use_taa = false
	await settle()
	var turn_off_a: Image = await frame()
	camera.rotation_degrees = Vector3(0, 6, 0)
	await settle()
	var turn_off_b: Image = await frame()
	var turn_without_taa := mean_abs_difference(turn_off_a, turn_off_b, SKY_RECT)

	root.use_taa = true
	camera.rotation_degrees = Vector3(0, -6, 0)
	await settle()
	var turn_taa_a: Image = await frame()
	camera.rotation_degrees = Vector3(0, 6, 0)
	await settle()
	var turn_taa_b: Image = await frame()
	var turn_with_taa := mean_abs_difference(turn_taa_a, turn_taa_b, SKY_RECT)
	require(turn_without_taa > 0.02, "turning the camera does not change the sky (%.4f); the check below would be vacuous" % turn_without_taa)
	require(turn_with_taa > turn_without_taa * 0.5,
			"the sky does not follow the camera with TAA on: it moved %.4f over the turn against %.4f without TAA, so the background is reprojecting with a stale motion"
			% [turn_with_taa, turn_without_taa])
	print("PASS the sky follows the camera with TAA on (turn %.4f with TAA, %.4f without)" % [turn_with_taa, turn_without_taa])

	root.use_taa = false
	camera.rotation_degrees = Vector3.ZERO
	await frame()

	print("PASS the background is temporally resolved with TAA on: a static frame converges instead of showing a fresh jittered sample")
	quit(0)
