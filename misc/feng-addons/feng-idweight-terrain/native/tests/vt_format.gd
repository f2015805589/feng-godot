# Run with a graphical rendering driver; see README.md in this directory.
#
# Changing the atlas format changes how a page is stored, never where it lives. The three
# material page arrays are rebuilt in place by the producer, so the page pool, the world
# addresses, the owners and the demand plan have to survive the change. Rebuilding them
# detaches both views, releases every resident page (the atlas cannot be resized in place)
# and then grows the pool back to the capacity it had already published, which the demand
# pass sees as a capacity change. That regression reached a user as
#   WARNING: Virtual texture pool grew to N pages; resident pages were released ...
# on a plain property change in the editor, so this test pins the invariant directly:
# the pool generation must not move, the capacity must not shrink, and the runner rejects
# that warning anywhere in the log.
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

# Produces live material pages, which is what builds the arrays the format applies to.
func pump(terrain: Terrain3D, frames: int) -> void:
	for _frame in frames:
		terrain.update_surface_vt(64)
		terrain.update_surface_svt(64)
		await process_frame

# The service, not just the producer, has to be up before anything is asserted: the
# producer object exists from the first asset assignment, while the shared pool and the
# render callback only exist once the service configured itself.
func wait_for_service(terrain: Terrain3D) -> bool:
	for _frame in 120:
		await process_frame
		var settings: Dictionary = terrain.get_vt_settings()
		if bool(settings.get("shared_pool", false)) and bool(settings.get("callback_registered", false)) \
				and settings.has("vt_atlas_compression_available"):
			return true
	return false

func run() -> void:
	var terrain := await make_terrain()
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

	require(await wait_for_service(terrain),
			"the VT service must publish a shared pool and register its render callback")
	if failed:
		quit(1)
		return

	# A codec this build can actually store and sample. The list a page setting offers is the
	# producer's own codec list, so this walks exactly that and asks the producer which of them
	# this device accepted.
	var codec := -1
	for mode in range(1, Terrain3D.SURFACE_PAGE_COUNT):
		terrain.vt_atlas_compression = mode
		await process_frame
		require(terrain.vt_atlas_compression == mode, "the property must round trip mode %d" % mode)
		if int(terrain.get_vt_settings().get("vt_atlas_compression_available", -1)) == mode:
			codec = mode
			break
	terrain.vt_atlas_compression = 0
	await process_frame
	if codec < 0:
		print("VTFMT skipped: this build has no usable alpha-capable codec")
		terrain.queue_free()
		await process_frame
		quit()
		return

	terrain.surface_vt_selection_mode = 1
	terrain.set_surface_vt_force_mip(true, 0)
	await pump(terrain, 120)
	var before: Dictionary = terrain.get_vt_settings()
	var baked_before := int(producer_stats(terrain).get("baked_pages", 0))
	var pool_before := int(before.get("pool_generation", -1))
	var capacity_before := int(before.get("page_count", 0))
	print("VTFMT produced codec=%d baked=%d pages=%d pool=%d capacity=%d applied=%d" % [
			codec, baked_before, terrain.get_vt_pages().size(), pool_before, capacity_before,
			int(before.get("vt_atlas_compression_applied", 0))])
	require(pool_before > 0, "the fixture must have configured the VT service")
	require(capacity_before >= 16, "the fixture must publish the requested capacity")

	# The change under test: a format change is not a reconfiguration.
	print("VTFMT phase=change codec=%d" % codec)
	terrain.vt_atlas_compression = codec
	await physics_frame
	await pump(terrain, 180)
	var after: Dictionary = terrain.get_vt_settings()
	var applied := int(after.get("vt_atlas_compression_applied", 0))
	print("VTFMT changed baked=%d pages=%d pool=%d capacity=%d applied=%d retired=%d" % [
			int(producer_stats(terrain).get("baked_pages", 0)), terrain.get_vt_pages().size(),
			int(after.get("pool_generation", -2)), int(after.get("page_count", 0)), applied,
			int(producer_stats(terrain).get("retired_bundles", 0))])
	require(int(after.get("pool_generation", -2)) == pool_before,
			"changing the atlas format must not rebuild the page pool (pool generation %d -> %d)" % [
					pool_before, int(after.get("pool_generation", -2))])
	require(int(after.get("page_count", 0)) >= capacity_before,
			"a format change must not shrink the published capacity (%d -> %d)" % [
					capacity_before, int(after.get("page_count", 0))])
	require(bool(after.get("shared_pool", false)), "the shared pool must survive a format change")
	require(applied == codec, "the new format must be applied to the arrays, got %d want %d" % [applied, codec])

	# And back: the same invariant in the other direction.
	print("VTFMT phase=restore")
	var pooled := int(after.get("pool_generation", -1))
	terrain.vt_atlas_compression = 0
	await physics_frame
	await pump(terrain, 120)
	var restored: Dictionary = terrain.get_vt_settings()
	print("VTFMT restored pool=%d capacity=%d applied=%d retired=%d" % [
			int(restored.get("pool_generation", -2)), int(restored.get("page_count", 0)),
			int(restored.get("vt_atlas_compression_applied", -1)),
			int(producer_stats(terrain).get("retired_bundles", 0))])
	require(int(restored.get("pool_generation", -2)) == pooled,
			"restoring uncompressed must not rebuild the page pool")
	require(int(restored.get("vt_atlas_compression_applied", -1)) == 0,
			"restoring uncompressed must store the arrays uncompressed")
	# Every format change replaces the three arrays. The replaced pair may only be released
	# after the material has been rebound to its successor, and it must be released.
	var retired := -1
	for _frame in 60:
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
	print("PASS virtual texture format change keeps the page pool")
	quit()
