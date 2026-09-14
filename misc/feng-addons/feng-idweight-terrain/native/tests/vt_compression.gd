# Run with a graphical rendering driver; see README.md in this directory.
#
# The three material page arrays must all share one format, and each of them carries an
# alpha value the shader reads (material height, roughness, and the params validity bit).
# This pins the resolver, not a codec: which requests are refused because the codec keeps
# no alpha, which are refused because this build has no compressor or the device cannot
# sample the result, and that an accepted request is exactly the effective format with no
# reason attached. The accepted set is build dependent (etcpak and astcenc ship in every
# build, cvtt and betsy are editor-only, and a desktop device can only sample BC formats),
# so the test asserts the invariants and prints what it found.
extends SceneTree

var failed := false

func _initialize() -> void:
	call_deferred("run")

func require(value: bool, message: String) -> void:
	if not value:
		push_error("REGRESSION: " + message)
		failed = true

func producer_stats(p_terrain: Terrain3D) -> Dictionary:
	return p_terrain.get_vt_settings().get("producer", {})

func make_terrain() -> Terrain3D:
	var terrain := Terrain3D.new()
	terrain.free_editor_textures = false
	root.add_child(terrain)
	var camera := Camera3D.new()
	camera.position = Vector3(0.0, 120.0, 0.0)
	camera.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	camera.current = true
	terrain.add_child(camera)
	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)
	await process_frame
	await process_frame
	return terrain

# Property enum order: which entries keep an alpha channel.
const NO_ALPHA_CODECS := [2, 4, 5, 6, 7, 8, 10, 11]

# A gradient plus hard block edges: the edges are what make a block codec show any error at
# all, and the gradient keeps the mean meaningful.
func make_probe_image() -> Image:
	var image := Image.create_empty(64, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 64:
			var base := float(x + y) / 126.0
			var edge := 0.0 if ((x / 8 + y / 8) % 2 == 0) else 1.0
			image.set_pixel(x, y, Color(base * 0.5 + edge * 0.5, edge, 1.0 - base, 0.25 + 0.75 * edge))
	return image

func run() -> void:
	var terrain := await make_terrain()
	# The VT service refuses to build material pages without a texture asset list, and it is
	# what registers the render callback that runs the baker at all.
	terrain.assets = Terrain3DAssets.new()
	terrain.region_size = 64
	terrain.vt_page_size = 16
	terrain.vt_page_border = 1
	terrain.vt_page_count = 16
	terrain.surface_vt_enabled = true
	terrain.surface_svt_enabled = true
	terrain.data.add_region_blank(Vector2i.ZERO)
	terrain.data.update_maps()
	await physics_frame

	# The baker owns the resolver, so wait until the VT service built it.
	var ready := false
	for _frame in 30:
		await process_frame
		if terrain.get_vt_settings().has("vt_atlas_compression_available"):
			ready = true
			break
	require(ready, "the surface baker must publish its atlas compression resolution")
	if failed:
		quit(1)
		return

	require(terrain.vt_atlas_compression == 0, "atlas compression must default to uncompressed")
	var initial: Dictionary = terrain.get_vt_settings()
	require(int(initial.get("vt_atlas_compression_available", -1)) == 0,
			"uncompressed must resolve to itself")
	require(String(initial.get("vt_atlas_compression_reason", "non-empty")).is_empty(),
			"an accepted request must not carry a reason")

	var accepted := PackedStringArray()
	var refused := PackedStringArray()
	var first_accepted := -1
	for mode in range(16):
		terrain.vt_atlas_compression = mode
		await process_frame
		require(terrain.vt_atlas_compression == mode, "the property must round trip mode %d" % mode)
		var settings: Dictionary = terrain.get_vt_settings()
		var name := String(settings.get("vt_atlas_compression_name", "?"))
		var available := int(settings.get("vt_atlas_compression_available", -1))
		var reason := String(settings.get("vt_atlas_compression_reason", ""))
		if mode in NO_ALPHA_CODECS:
			require(available == 0, "%s keeps no alpha and must be refused" % name)
			require(reason.contains("alpha"),
					"mode %d must be refused for the alpha reason, got '%s'" % [mode, reason])
			refused.append("mode %d [%s]" % [mode, reason])
			continue
		if available == mode:
			require(reason.is_empty(), "%s was accepted but carries reason '%s'" % [name, reason])
			accepted.append(name)
			# Only a lossy codec is interesting for the round trip below.
			if mode != 0 and first_accepted < 0:
				first_accepted = mode
		else:
			require(available == 0, "%s must fall back to uncompressed, got %d" % [name, available])
			require(not reason.is_empty(), "%s was refused without a reason" % name)
			refused.append("%s [%s]" % [name, reason])
	print("VTCOMPRESSION accepted=%s refused=%s" % [", ".join(accepted), "; ".join(refused)])
	# etcpak ships in every build and every desktop device samples BC, so BC3 must work.
	require(accepted.size() > 0, "at least one alpha-capable codec must be usable in this build")

	# The codec path itself: compress and decode a real image through the same codec, which
	# is where the loss shows up. A lossy codec must change the image (that is the proof the
	# encode ran) and its error must stay bounded; uncompressed must round trip exactly.
	if first_accepted >= 0:
		terrain.vt_atlas_compression = first_accepted
		# Live bake pages are what build the arrays that carry the codec, and the legacy
		# region path queues them synchronously (the sector planner is asynchronous).
		terrain.surface_vt_selection_mode = 1
		terrain.set_surface_vt_force_mip(true, 0)
		var applied := 0
		for _frame in 90:
			terrain.update_surface_vt(64)
			terrain.update_surface_svt(64)
			await process_frame
			applied = int(terrain.get_vt_settings().get("vt_atlas_compression_applied", 0))
			if applied != 0:
				break
		var probe: Dictionary = terrain.probe_vt_atlas_compression(make_probe_image())
		var settings_after: Dictionary = terrain.get_vt_settings()
		var page_count := terrain.get_vt_pages().size()
		print("VTCOMPRESSION producer=%s callback=%s pages=%d sel=%d" % [
				str(settings_after.get("producer", {})), str(settings_after.get("callback_registered", false)),
				page_count, terrain.surface_vt_selection_mode])
		require(bool(probe.get("valid", false)), "the codec probe must succeed for an accepted codec")
		require(float(probe.get("max_error", 0.0)) > 0.0,
				"a lossy codec must change the image, which proves the encode ran")
		require(float(probe.get("mean_error", 1.0)) < 0.08,
				"the codec error must stay bounded, got %f" % float(probe.get("mean_error", 1.0)))
		print("VTCOMPRESSION probe name=%s applied=%d max=%.4f mean=%.5f" % [
				String(probe.get("name", "")), applied, float(probe.get("max_error", 0.0)),
				float(probe.get("mean_error", 0.0))])
		# Page production is what creates the arrays. When the fixture produced one, the
		# codec that was accepted must be the one the arrays are actually stored in.
		if applied != 0:
			require(applied == first_accepted,
					"the accepted codec must be applied to the arrays (applied=%d, wanted=%d)" % [applied, first_accepted])
		elif page_count > 0:
			require(false,
					"page production built the arrays for %d pages, but the accepted codec was never applied" % page_count)
		else:
			print("VTCOMPRESSION applied_unverified: this fixture produced no material page")

	# Going back must clear the reason and round trip exactly again.
	terrain.vt_atlas_compression = 0
	await process_frame
	var restored: Dictionary = terrain.get_vt_settings()
	require(int(restored.get("vt_atlas_compression_available", -1)) == 0,
			"uncompressed must be restorable after a compressed mode")
	require(String(restored.get("vt_atlas_compression_reason", "non-empty")).is_empty(),
			"restoring uncompressed must clear the refusal reason")
	var exact: Dictionary = terrain.probe_vt_atlas_compression(make_probe_image())
	require(bool(exact.get("valid", true)), "the uncompressed probe must succeed")
	require(float(exact.get("max_error", -1.0)) == 0.0,
			"uncompressed must round trip exactly, got max error %f" % float(exact.get("max_error", -1.0)))

	# Every format change rebuilds the three arrays. The replaced pair may only be released
	# after the material has been rebound to its successor, and it must be released: a
	# non-zero count in a settled frame is a rebuild that leaks a whole page array.
	var retired := -1
	for _frame in 40:
		await process_frame
		retired = int(producer_stats(terrain).get("retired_bundles", -1))
		if retired == 0:
			break
	require(retired == 0, "a replaced page array must be released once the material rebinds, got %d" % retired)

	terrain.queue_free()
	await process_frame
	if failed:
		quit(1)
		return
	print("PASS virtual texture atlas compression resolution")
	quit()
