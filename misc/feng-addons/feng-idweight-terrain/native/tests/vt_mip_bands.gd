# GPU regression for the far-field distance -> mip table.
#
# The page producer and the shader resolve a page's level through the same table
# (Terrain3D::get_surface_svt_mip_for_distance and surface_svt_mip_for_distance in
# main.glsl), so the level a point renders at is a pure function of its distance from the
# camera. These checks pin that contract:
#   1. the band edges the table states,
#   2. that the level the shader starts at is the level that was produced, for every
#      probe distance (the page set the shader walks is exactly the page set demanded),
#   3. that neither the level nor the residency moves while the camera stays inside the
#      bands, and that a settled view does not churn the pool (the mip "jumping"
#      regression: the sampled mip used to follow whichever page happened to be
#      resident),
#   4. that an over-subscribed pool keeps the nearest pages and still settles instead of
#      rewriting levels.
extends SceneTree

const REGION_SIZE := 64
const REGION_COUNT := 10
const PAGE_SIZE := 32
const PAGE_BORDER := 2
const PAGE_COUNT := 64
const PAGE_WORLD := 64.0
const MAX_MIP := 4
const INVALID_SLOT := 65535
# Level m owns distances up to entry m, so these bands are 0..128, 128..256, 256..512,
# 512..1024, and everything beyond the table keeps the coarsest listed level.
const BAND_VALUES := [128.0, 256.0, 512.0, 1024.0]
# Flat ground at z = 0, 64 .. 576 from a camera at (32, 60, -60), which puts the probes
# in levels 0, 1, 2 and 3 with tens of metres of margin on every band edge.
const PROBE_Z := [0, 64, 128, 192, 256, 384, 512, 576]
const EXPECTED_LEVELS := [0, 1, 1, 2, 2, 2, 3, 3]

var terrain: Terrain3D
var scene: Node3D
var camera: Camera3D
var failed := false
var output_dir := "user://"

func _initialize() -> void:
	call_deferred("run")

func require(value: bool, message: String) -> void:
	if not value:
		push_error("REGRESSION: " + message)
		failed = true

func make_texture(color: Color) -> ImageTexture:
	var image := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	image.fill(color)
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)

func add_materials() -> void:
	terrain.assets = Terrain3DAssets.new()
	for id in 2:
		var asset := Terrain3DTextureAsset.new()
		asset.albedo_texture = make_texture(Color(0.16, 0.42, 0.2) if id == 0 else Color(0.55, 0.42, 0.2))
		asset.normal_texture = make_texture(Color(0.5, 0.5, 1.0))
		terrain.assets.set_texture_asset(id, asset)

func add_flat_regions() -> void:
	terrain.region_size = REGION_SIZE
	for z in REGION_COUNT:
		terrain.data.add_region_blank(Vector2i(0, z))
	terrain.data.update_maps()

func frame_barrier() -> void:
	await process_frame
	await RenderingServer.frame_post_draw

# Distance from the camera to a ground point, measured the way the shader measures it:
# the blank regions are flat at height 0, so the fragment is (x, 0, z).
func ground_distance(p_z: float) -> float:
	return Vector3(32.0, 0.0, p_z).distance_to(camera.global_position)

func probe_world(p_z: float) -> Vector2:
	return Vector2(32.0, p_z)

func bands() -> PackedFloat32Array:
	return PackedFloat32Array(BAND_VALUES)

# The level the shader starts its walk at for a world position.
func shader_level(p_world: Vector2) -> int:
	return terrain.get_surface_svt_mip_for_distance(
			Vector3(p_world.x, 0.0, p_world.y).distance_to(camera.global_position))

func page_of(p_world: Vector2) -> Vector2i:
	return Vector2i(int(floor(p_world.x / PAGE_WORLD)), int(floor(p_world.y / PAGE_WORLD)))

# Whether the level the shader would sample is actually published for that position.
func level_resident(p_world: Vector2, p_mip: int) -> bool:
	var page := page_of(p_world)
	var virtual := terrain.get_surface_svt().get_world_page_virtual(page.x, page.y, p_mip)
	return terrain.get_surface_svt().get_indirection_slot(virtual.x, virtual.y, p_mip) != INVALID_SLOT

# Under pool pressure the demand pass raises a coarseness floor, so a texel may be served
# by an ancestor of the level the distance table names. It is never served by a finer one.
func level_resolves(p_world: Vector2, p_mip: int) -> bool:
	for mip in range(p_mip, MAX_MIP + 2):
		if level_resident(p_world, mip):
			return true
	return false

func probe_report(p_phase: String) -> void:
	var lines: PackedStringArray = []
	for index in PROBE_Z.size():
		var world := probe_world(float(PROBE_Z[index]))
		var level := shader_level(world)
		lines.append("z%d:d%d=l%d%s" % [PROBE_Z[index], int(ground_distance(float(PROBE_Z[index]))), level,
				"R" if level_resident(world, level) else "!"])
	print("VT_MIP_BANDS %s %s" % [p_phase, " ".join(lines)])

func residency_signature() -> String:
	var parts: PackedStringArray = []
	for index in PROBE_Z.size():
		var world := probe_world(float(PROBE_Z[index]))
		var level := shader_level(world)
		parts.append("%d:%d:%d" % [level, 1 if level_resident(world, level) else 0,
				1 if level > 0 and level_resident(world, level - 1) else 0])
	# The effective level cap and the pool counters are part of the contract too: a
	# settled view must not keep allocating, evicting or extending the hierarchy.
	var stats: Dictionary = terrain.get_surface_svt().get_stats()
	return "%s|max%d|alloc%d|evict%d" % [" ".join(parts), terrain.get_surface_svt().get_world_max_mip(),
			int(stats.get("alloc_count", 0)), int(stats.get("evict_count", 0))]

# Drive the demand pass like a frame does, and let the pool settle.
func settle(p_passes: int = 8) -> void:
	for pass_index in p_passes:
		terrain.update_surface_svt()
		await frame_barrier()

func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 1:
		output_dir = args[1]
	DirAccess.make_dir_recursive_absolute(output_dir)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://vt_mip_bands_data"))

	scene = Node3D.new()
	terrain = Terrain3D.new()
	terrain.region_size = REGION_SIZE
	terrain.vt_page_size = PAGE_SIZE
	terrain.vt_page_border = PAGE_BORDER
	terrain.vt_page_count = PAGE_COUNT
	# Both views are created together, so the shared page pool exists; AVT is switched
	# off below, once the setup is complete.
	terrain.surface_vt_enabled = true
	terrain.surface_svt_enabled = true
	terrain.surface_svt_page_world = PAGE_WORLD
	terrain.surface_svt_max_mip = MAX_MIP
	terrain.surface_svt_root_mips = 0
	terrain.surface_svt_auto_bake = false
	terrain.surface_svt_mip_distances = bands()
	terrain.free_editor_textures = false
	terrain.data_directory = "user://vt_mip_bands_data"
	add_materials()

	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 900.0
	camera.near = 0.1
	camera.far = 8192.0
	camera.position = Vector3(32.0, 60.0, -60.0)
	root.add_child(camera)
	camera.look_at(Vector3(32.0, 0.0, 320.0), Vector3.UP)
	camera.current = true
	terrain.set_camera(camera)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-60.0, -20.0, 0.0)
	scene.add_child(light)
	scene.add_child(terrain)
	root.add_child(scene)
	terrain.set_clipmap_target(terrain)
	terrain.set_physics_process(false)
	add_flat_regions()
	await frame_barrier()
	terrain.surface_vt_enabled = false
	await frame_barrier()

	# 1. The table's band edges. Level m owns distances up to entry m; past the last
	# entry the coarsest listed level keeps serving.
	require(terrain.get_surface_svt_mip_distances() == bands(),
			"the terrain should store the band table it was given")
	require(terrain.get_surface_svt_mip_for_distance(0.0) == 0, "distance 0 is level 0")
	require(terrain.get_surface_svt_mip_for_distance(128.0) == 0, "a band edge belongs to its own level")
	require(terrain.get_surface_svt_mip_for_distance(128.5) == 1, "just past 128 m is level 1")
	require(terrain.get_surface_svt_mip_for_distance(256.0) == 1, "256 m is still level 1")
	require(terrain.get_surface_svt_mip_for_distance(512.0) == 2, "512 m is the end of level 2")
	require(terrain.get_surface_svt_mip_for_distance(512.5) == 3, "just past 512 m is level 3")
	require(terrain.get_surface_svt_mip_for_distance(1024.0) == 3, "1024 m is still level 3")
	require(terrain.get_surface_svt_mip_for_distance(5000.0) == 3,
			"beyond the table the coarsest listed level keeps serving")

	# 2. The level the shader samples is the level that was produced. Settle the view,
	# then require every probe's level to be published in the indirection.
	await settle(10)
	probe_report("settled")
	for index in PROBE_Z.size():
		var world := probe_world(float(PROBE_Z[index]))
		var level := shader_level(world)
		require(level == EXPECTED_LEVELS[index],
				"probe z=%d at %.1f m should resolve to level %d, got %d" %
				[PROBE_Z[index], ground_distance(float(PROBE_Z[index])), EXPECTED_LEVELS[index], level])
		require(level_resident(world, level),
				"the level the shader starts at must be produced: probe z=%d level %d is not published" %
				[PROBE_Z[index], level])

	# 3. A settled view must not move a level or churn the pool, and a small camera move
	# that stays inside every band must not move a level either. This is the regression:
	# the sampled level used to be whichever level happened to still be resident.
	var settled := residency_signature()
	await settle(12)
	require(residency_signature() == settled,
			"a settled view changed its levels or kept churning the pool: %s -> %s" %
			[settled, residency_signature()])
	# Moving away from the terrain lengthens every probe's distance by 4 m, which stays
	# inside every band (the tightest edge margin above is 9 m).
	camera.position += Vector3(0.0, 0.0, -4.0)
	await frame_barrier()
	await settle(6)
	var moved := residency_signature()
	require(moved.split("|")[0] == settled.split("|")[0],
			"a 4 m camera move inside the bands changed a probe level: %s -> %s" % [settled, moved])
	for index in PROBE_Z.size():
		var world := probe_world(float(PROBE_Z[index]))
		var level := shader_level(world)
		require(level_resident(world, level),
				"after a small camera move the level must still be resident: probe z=%d level %d" %
				[PROBE_Z[index], level])

	# 4. An over-subscribed pool raises a coarseness floor instead of rewriting levels, and
	# still settles. Every probe must resolve (its own level or a coarser ancestor), the
	# nearest ones first, and nothing may keep allocating or evicting once settled.
	camera.position = Vector3(32.0, 60.0, -60.0)
	await frame_barrier()
	terrain.vt_page_count = 8
	await frame_barrier()
	await settle(12)
	var crowded_first := residency_signature()
	await settle(12)
	var crowded_second := residency_signature()
	print("VT_MIP_BANDS crowded_first %s" % crowded_first)
	print("VT_MIP_BANDS crowded_second %s" % crowded_second)
	require(crowded_second == crowded_first,
			"an over-subscribed pool must settle instead of rewriting levels: %s -> %s" %
			[crowded_first, crowded_second])
	for index in [0, 1]:
		var world := probe_world(float(PROBE_Z[index]))
		var level := shader_level(world)
		require(level_resolves(world, level),
				"the nearest probe must still resolve when the pool is crowded: z=%d level %d" %
				[PROBE_Z[index], level])

	# 5. The far field keeps a protected root pyramid over the visible world, so a detail
	# miss has real coarse data to fall back on, and an over-subscribed pool raises a
	# coarseness floor instead of dropping the far end of the working set. Phase 4 above
	# runs with roots disabled, so this phase restores them.
	#
	# Automatic capacity is switched off for this phase, and that is what makes the assertion a
	# statement about the floor instead of a function of everything the earlier phases left behind:
	# with it on, the pool grows to fit the visible set - measured, 7 visible pages beside 8 roots
	# grew the pool to 16, so 7 <= 16 - 8 and nothing was over-subscribed by it. The floor is a
	# function of the visible set and the capacity left after the roots, so the test has to fix the
	# capacity to ask about it, and `detail_capacity` is the number the deciding pass published.
	terrain.surface_svt_root_mips = 2
	terrain.vt_auto_capacity = false
	terrain.vt_page_count = 4
	await frame_barrier()
	await settle(12)
	var root_settings: Dictionary = terrain.get_vt_settings()
	print("VT_MIP_BANDS roots root_pages=%d floor=%d visible=%d protected=%d pool=%d setting=%d detail_capacity=%d" % [
			int(root_settings.get("svt_root_pages", 0)), int(root_settings.get("svt_floor_level", 0)),
			int(root_settings.get("svt_visible_pages", 0)),
			int(terrain.get_surface_svt().get_stats().get("protected_count", 0)),
			int(root_settings.get("effective_page_count", 0)), int(root_settings.get("page_count", 0)),
			int(root_settings.get("svt_detail_capacity", 0))])
	require(int(root_settings.get("svt_root_pages", 0)) > 0,
			"the far field must pin a root pyramid covering the visible world")
	require(int(terrain.get_surface_svt().get_stats().get("protected_count", 0)) > 0,
			"root pages must stay protected so a detail miss resolves coarsely")
	var detail_capacity := int(root_settings.get("svt_detail_capacity", 0))
	require(int(root_settings.get("svt_visible_pages", 0)) > detail_capacity,
			"this phase must actually over-subscribe the pool: %d visible pages against %d detail slots" %
			[int(root_settings.get("svt_visible_pages", 0)), detail_capacity])
	require(int(root_settings.get("svt_floor_level", 0)) > 0,
			"an over-subscribed pool must raise a coarseness floor instead of dropping pages")

	scene.queue_free()
	camera.queue_free()
	await process_frame
	if failed:
		quit(1)
		return
	print("PASS far-field distance -> mip bands are produced, resident and stable")
	quit()
