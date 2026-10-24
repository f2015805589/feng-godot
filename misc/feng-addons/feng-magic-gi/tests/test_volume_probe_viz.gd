extends SceneTree
## RenderingDevice regression for free-space/CLV editor probe visualization.
## Run against a project with the FRP addons linked, using --rendering-method
## forward_plus --rendering-driver d3d12 (or vulkan), not --headless. The dummy
## renderer cannot read MultiMesh instance data and must not report a pass.
const Viz = preload("res://addons/feng-magic-gi/feng_magic_gi_viz.gd")
const Volume = preload("res://addons/feng-magic-gi/feng_magic_gi_volume.gd")
var checks := 0
var failures := 0
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(label)
func _initialize() -> void:
	call_deferred("run")
func run() -> void:
	if RenderingServer.get_rendering_device() == null:
		push_error("test_volume_probe_viz requires a RenderingDevice; headless dummy is unsupported")
		quit(2)
		return
	var volume = Volume.new()
	volume.show_probes = true
	volume.show_sh_probes = true
	volume.set("_layout_stale", false)
	var positions := PackedVector3Array()
	var spacings := PackedFloat32Array()
	var coefficients := PackedFloat32Array()
	coefficients.resize(400 * 27)
	for i in 400:
		positions.append(Vector3(float(i % 20) * 0.25, float(i / 20) * 0.25, 0.0))
		spacings.append(0.25)
		coefficients[i * 27] = 3.5449077
		coefficients[i * 27 + 1] = 1.77245385
		coefficients[i * 27 + 2] = 0.886226925
	var snapshot := {"volume_probe_preview": true, "positions": positions, "spacings": spacings,
		"response_sh": coefficients, "layout_key": "layout_one", "revision": 1, "current_available": true,
		"strength": 1.0, "display_by_clv": true, "clv_levels": [{"lod": 0, "bounds": AABB(Vector3.ZERO, Vector3(5, 5, 5))}]}
	var node := Viz.build(volume, snapshot)
	root.add_child(node)
	var probes := node.get_node("_Probes") as MultiMeshInstance3D
	var sh := node.get_node("_Transport") as MultiMeshInstance3D
	check(probes.multimesh.instance_count == 400, "all resident points shown")
	check(probes.top_level, "world anchored markers")
	check(probes.gi_mode == GeometryInstance3D.GI_MODE_DISABLED, "markers excluded from GI")
	check(probes.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "markers do not shadow scene")
	check(probes.multimesh.get_instance_color(0).is_equal_approx(Color(1.0, 0.5, 0.25, 1.0)), "L0 mean matches irradiance")
	check(sh.multimesh.instance_count == 256, "SH count bounded")
	check(sh.get_meta("volume_preview_indices")[-1] > 390, "SH sample covers whole set")
	var texture := sh.get_meta("volume_preview_texture") as ImageTexture
	check(texture.get_width() == 9 and texture.get_height() == 256, "SH data texture dimensions")
	check(texture.get_image().get_format() == Image.FORMAT_RGBF, "HDR linear coefficients retained")
	check(node.has_node("_CLVLevel0"), "actual CLV bounds shown")
	check(not node.has_node("_StreamStatus"), "CLV status is kept out of the 3D scene")
	var first_mesh := sh.multimesh
	coefficients[0] = 7.0898154
	snapshot.response_sh = coefficients
	snapshot.revision = 2
	Viz.update_preview(volume, node, snapshot)
	check(probes.multimesh.get_instance_color(0).r > 1.99, "live relight updates points")
	check((node.get_node("_Transport") as MultiMeshInstance3D).multimesh == first_mesh, "relight reuses SH geometry")
	check(is_equal_approx(texture.get_image().get_pixel(0, 0).r, 7.0898154), "live relight updates HDR texture")
	snapshot.current_available = false
	Viz.update_preview(volume, node, snapshot)
	check(not node.has_node("_Transport"), "no stale SH shown while unavailable")
	check(probes.multimesh.get_instance_color(0).is_equal_approx(Viz.UNAVAILABLE_COLOR), "unavailable points are explicitly marked")
	snapshot.current_available = true
	snapshot.revision = 3
	Viz.update_preview(volume, node, snapshot)
	check(node.has_node("_Transport"), "SH returns on ready response")
	snapshot.layout_key = "layout_two"
	positions[0] = Vector3(0, 0, 2)
	snapshot.positions = positions
	Viz.update_preview(volume, node, snapshot)
	probes = node.get_node("_Probes")
	check(probes.multimesh.get_instance_transform(0).origin == Vector3(0, 0, 2), "residency change updates world position")
	volume.show_probes = false
	volume.show_sh_probes = false
	Viz.rebuild(volume, node, snapshot)
	check(not node.has_node("_Probes") and not node.has_node("_Transport") and not node.has_node("_CLVLevel0") and not node.has_node("_StreamStatus"), "disabled preview has no debug layers")
	# Reopening after asynchronous publication must construct current spheres,
	# even though the previous OFF rebuild discarded every debug layer.
	volume.show_sh_probes = true
	Viz.rebuild(volume, node, {"volume_probe_preview": true, "current_available": false,
		"positions": PackedVector3Array(), "layout_key": "pending", "revision": 4})
	check(not node.has_node("_Transport"), "reopen waits for a live response")
	snapshot.revision = 5
	Viz.update_preview(volume, node, snapshot)
	check(node.has_node("_Transport"), "async response appears after reopening")
	check(not node.has_node("_Probes"), "SH-only switch does not re-enable marker dots")
	snapshot.selected_clv_level = 1
	snapshot.layout_key = "selected_level_1"
	snapshot.clv_levels = [{"lod": 0, "bounds": AABB(Vector3.ZERO, Vector3.ONE)},
		{"lod": 1, "bounds": AABB(Vector3.ZERO, Vector3.ONE * 2.0)}]
	Viz.update_preview(volume, node, snapshot)
	check(not node.has_node("_CLVLevel0") and node.has_node("_CLVLevel1"), "selected cascade draws only its own bounds")
	node.position = Vector3(50.0, 70.0, 90.0)
	node.rotation = Vector3(0.2, 0.4, 0.6)
	node.scale = Vector3(2.0, 3.0, 4.0)
	var anchored := node.get_node("_Transport") as MultiMeshInstance3D
	check(anchored.global_transform.is_equal_approx(Transform3D.IDENTITY), "SH world anchors ignore parent transform")
	check(anchored.multimesh.get_instance_transform(0).origin == positions[0], "SH instance position remains the resident world cell")
	node.queue_free()
	await process_frame
	await render_live_sh(volume)
	await render_overlay_exposure(volume)
	volume.free()
	print("VOLUME_PREVIEW_VIZ checks=%d failures=%d" % [checks, failures])
	quit(1 if failures else 0)

func render_live_sh(volume: FMagicGIVolume) -> void:
	# Render two raw radiance-SH probes with different L1 RGB lobes. This checks
	# the real spatial shader rather than asserting a shader filename/code string.
	var response := PackedFloat32Array()
	response.resize(54)
	for index in [0, 1, 2, 27, 28, 29]:
		response[index] = 1.5
	response[6] = 2.0 # red +Z
	response[34] = 2.0 # green +Z
	var snapshot := {"volume_probe_preview": true,
		"positions": PackedVector3Array([Vector3(-0.5, 0, 0), Vector3(0.5, 0, 0)]),
		"spacings": PackedFloat32Array([1.0, 1.0]), "response_sh": response,
		"layout_key": "shader_render", "revision": 1, "current_available": true,
		"strength": 1.0, "display_by_clv": false}
	var display := Viz.build(volume, snapshot)
	root.add_child(display)
	display.get_node("_Box").hide()
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.position = Vector3(0, 0, 3)
	camera.current = true
	for frame in 12:
		await process_frame
	await RenderingServer.frame_post_draw
	var result := root.get_texture().get_image()
	check(not result.is_empty(), "actual shader draw produces a viewport image")
	var left := camera.unproject_position(Vector3(-0.5, 0, 0))
	var right := camera.unproject_position(Vector3(0.5, 0, 0))
	var left_color := result.get_pixel(int(left.x), int(left.y))
	var right_color := result.get_pixel(int(right.x), int(right.y))
	check(left_color.r > left_color.g + 0.15 and absf(left_color.g - left_color.b) < 0.04,
		"rendered SH red L1 coefficient is directional and preserves RGB order")
	check(right_color.g > right_color.r + 0.15 and absf(right_color.r - right_color.b) < 0.04,
		"second rendered SH sphere reads its own coefficient texture row")
	camera.queue_free()
	display.queue_free()

func render_overlay_exposure(volume: FMagicGIVolume) -> void:
	var snapshot := {"volume_probe_preview": true, "positions": PackedVector3Array(),
		"response_sh": PackedFloat32Array(), "layout_key": "wire_exposure", "revision": 1,
		"current_available": true, "display_by_clv": true, "selected_clv_level": 1,
		"clv_levels": [{"lod": 1, "bounds": AABB(Vector3(-0.5, -0.5, 0.0), Vector3.ONE)}]}
	var display := Viz.build(volume, snapshot)
	root.add_child(display)
	display.get_node("_Box").hide()
	var camera := Camera3D.new()
	camera.attributes = CameraAttributesPractical.new()
	root.add_child(camera)
	camera.position = Vector3(0, 0, 3)
	camera.current = true
	var material := (display.get_node("_CLVLevel1") as MeshInstance3D).material_override as ShaderMaterial
	check(material != null, "CLV bounds use an exposure-aware debug shader")
	var views := [{"origin": camera.position, "right": Vector3.RIGHT,
		"up": Vector3.UP, "back": Vector3.BACK, "projection_x": absf(camera.get_camera_projection().x.x),
		"projection_y": absf(camera.get_camera_projection().y.y), "viewport_size": Vector2(root.size),
		"exposure_scale": 0.5}]
	Viz.update_preview_exposure(volume, display, {"editor_views": views})
	check(is_equal_approx((material.get_shader_parameter("preview_eye_scale") as Vector4).x, 0.5),
		"CLV wire material receives current per-view Eye Adaptation scale")
	# This fixture has no Eye compositor: restore neutral eye metadata and vary
	# camera exposure only, testing actual rasterized wire pixels at both values.
	Viz.update_preview_exposure(volume, display, {"editor_views": []})
	var samples: Array[Color] = []
	for multiplier in [1.0, 0.001]:
		camera.attributes.exposure_multiplier = multiplier
		for frame in 12:
			await process_frame
		await RenderingServer.frame_post_draw
		var result := root.get_texture().get_image()
		var location := camera.unproject_position(Vector3(-0.5, 0.0, 1.0))
		var best := Color.BLACK
		var best_chroma := -INF
		for y in range(int(location.y) - 3, int(location.y) + 4):
			for x in range(int(location.x) - 3, int(location.x) + 4):
				var color := result.get_pixel(x, y)
				var chroma := color.g - maxf(color.r, color.b)
				if chroma > best_chroma:
					best_chroma = chroma
					best = color
		samples.append(best)
		check(best.g > 0.6 and best_chroma > 0.2,
			"actual CLV wire remains colored under exposure multiplier %.3f" % multiplier)
	check(absf(samples[0].r - samples[1].r) < 0.03
		and absf(samples[0].g - samples[1].g) < 0.03
		and absf(samples[0].b - samples[1].b) < 0.03,
		"wire diagnostic color is stable across a 1000x physical exposure change")
	camera.queue_free()
	display.queue_free()
