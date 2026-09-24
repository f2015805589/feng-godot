extends "res://vt_adaptive_base.gd"

# A shader-only transition probe.  The fine page is resident, its direct local
# parent is deliberately absent, and the next local mip is resident.  This makes
# the transition resolver prove that it may skip a missing parent while the first
# (fine) resolver still remains strict when feedback is disabled.
const REGION := Vector2i.ZERO
const TARGET_XZ := Vector2(34.0, 34.0)
const PAGE_SIZE := 32
const PAGE_BORDER := 2
const DENSITY := 8.0
const PAGE_COUNT := 128
const FADE_FRAMES := 12
const CAMERA_SIZE := 4.0
const SCREEN_CENTER := Vector2(160.0, 120.0)

var albedo_array: Texture2DArray
var normal_array: Texture2DArray
var param_array: Texture2DArray
var fade_texture: ImageTexture

func _initialize() -> void:
	call_deferred("run")

func make_layer(color: Color) -> Image:
	var stored := PAGE_SIZE + 2 * PAGE_BORDER
	var image := Image.create(stored, stored, false, Image.FORMAT_RGBAF)
	image.fill(color)
	return image

func max_local_mip(block_size: int) -> int:
	var result := 0
	var size := block_size
	while size > 1:
		result += 1
		size >>= 1
	return result

func install_probe_pages(block_size: int) -> Dictionary:
	var vt := terrain.get_surface_vt()
	var max_mip := max_local_mip(block_size)
	for mip in range(max_mip + 1):
		var count := maxi(1, block_size >> mip)
		for y in range(count):
			for x in range(count):
				vt.release_page(REGION, mip, x, y)

	var fine_x := clampi(int(floor(TARGET_XZ.x / 64.0 * float(block_size))), 0, block_size - 1)
	var fine_y := clampi(int(floor(TARGET_XZ.y / 64.0 * float(block_size))), 0, block_size - 1)
	var fine_slot := vt.request_page(REGION, 0, fine_x, fine_y)
	var ancestor_mip := 2
	var ancestor_slot := vt.request_page(REGION, ancestor_mip, fine_x >> ancestor_mip, fine_y >> ancestor_mip)
	require(fine_slot >= 0, "allocate the fine transition page")
	require(ancestor_slot >= 0, "allocate the coarse ancestor transition page")
	vt.commit()

	var origin_x: int = vt.get_sector_block_origin_x(REGION)
	var origin_y: int = vt.get_sector_block_origin_y(REGION)
	var direct_x := (origin_x >> 1) + (fine_x >> 1)
	var direct_y := (origin_y >> 1) + (fine_y >> 1)
	var ancestor_x := (origin_x >> ancestor_mip) + (fine_x >> ancestor_mip)
	var ancestor_y := (origin_y >> ancestor_mip) + (fine_y >> ancestor_mip)
	require(vt.get_indirection_slot(direct_x, direct_y, 1) == 65535,
			"the direct local parent must stay absent")
	require(vt.get_indirection_slot(ancestor_x, ancestor_y, ancestor_mip) == ancestor_slot,
			"the coarser local ancestor must be resident")

	var albedo_images: Array[Image] = []
	var normal_images: Array[Image] = []
	var param_images: Array[Image] = []
	for slot in PAGE_COUNT:
		var albedo := Color.MAGENTA
		if slot == fine_slot:
			albedo = Color(0.95, 0.03, 0.02, 1.0)
		elif slot == ancestor_slot:
			albedo = Color(0.02, 0.08, 0.95, 1.0)
		albedo_images.append(make_layer(albedo))
		normal_images.append(make_layer(Color(0.5, 0.5, 1.0, 1.0)))
		param_images.append(make_layer(Color(0.0, 1.0, 0.0, 1.0)))

	albedo_array = Texture2DArray.new()
	normal_array = Texture2DArray.new()
	param_array = Texture2DArray.new()
	albedo_array.create_from_images(albedo_images)
	normal_array.create_from_images(normal_images)
	param_array.create_from_images(param_images)
	var material_rid := terrain.material.get_material_rid()
	RenderingServer.material_set_param(material_rid, "_surface_material_albedo", albedo_array.get_rid())
	RenderingServer.material_set_param(material_rid, "_surface_material_normal", normal_array.get_rid())
	RenderingServer.material_set_param(material_rid, "_surface_material_params", param_array.get_rid())
	return {"fine": fine_slot, "ancestor": ancestor_slot}

func install_fade(fine_slot: int, fine_fade: float) -> void:
	var bytes := PackedByteArray()
	bytes.resize(PAGE_COUNT)
	for slot in PAGE_COUNT:
		bytes[slot] = 255
	bytes[fine_slot] = clampi(int(round(clampf(fine_fade, 0.0, 1.0) * 255.0)), 0, 255)
	var image := Image.create_from_data(PAGE_COUNT, 1, false, Image.FORMAT_R8, bytes)
	fade_texture = ImageTexture.create_from_image(image)
	RenderingServer.material_set_param(terrain.material.get_material_rid(), "_surface_vt_page_fade", fade_texture.get_rid())
	RenderingServer.material_set_param(terrain.material.get_material_rid(), "_surface_vt_page_fade_frames", FADE_FRAMES)

func transition_label(image: Image) -> String:
	return sample_area(image, TARGET_XZ, 0)

func is_diagnostic(color: Color) -> bool:
	return color.r > color.g * 1.5 and color.b > color.g * 1.5

func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 1:
		output_dir = args[1]
	DirAccess.make_dir_recursive_absolute(output_dir)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://vt_transition_parent_data"))

	scene = Node3D.new()
	terrain = Terrain3D.new()
	terrain.vt_auto_capacity = false
	terrain.vt_page_size = PAGE_SIZE
	terrain.vt_page_border = PAGE_BORDER
	terrain.vt_page_count = PAGE_COUNT
	terrain.vt_pages_per_update = 16
	terrain.surface_vt_texels_per_meter = DENSITY
	terrain.surface_vt_adaptive_enabled = false
	terrain.surface_vt_selection_mode = 2
	terrain.surface_vt_region_grid = Vector2i.ONE
	terrain.surface_vt_distance = 512.0
	terrain.surface_vt_feedback = false
	terrain.surface_svt_enabled = false
	terrain.surface_svt_auto_bake = false
	terrain.vt_page_fade_frames = FADE_FRAMES
	terrain.free_editor_textures = false
	terrain.data_directory = "user://vt_transition_parent_data"
	scene.add_child(terrain)
	root.add_child(scene)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55.0, -25.0, 0.0)
	scene.add_child(light)
	add_assets()
	terrain.data.add_region_blank(REGION)
	terrain.data.update_maps()

	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = CAMERA_SIZE
	camera.near = 0.1
	camera.far = 512.0
	camera.position = Vector3(TARGET_XZ.x, 30.0, TARGET_XZ.y)
	camera.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	camera.current = true
	root.add_child(camera)
	terrain.set_camera(camera)
	terrain.surface_vt_enabled = true
	if terrain.material != null:
		terrain.material.update()

	for _frame in 180:
		await process_frame
	await RenderingServer.frame_post_draw
	terrain.set_process(false)
	terrain.set_physics_process(false)

	require(not terrain.surface_vt_feedback, "the transition probe must keep feedback disabled")
	var block_size := int(terrain.get_surface_vt().get_sector_block_size(REGION))
	require(block_size >= 4, "the AVT sector must expose at least two local parent mips")
	var slots: Dictionary = {}
	if block_size >= 4:
		slots = install_probe_pages(block_size)
	if int(slots.get("fine", -1)) < 0 or int(slots.get("ancestor", -1)) < 0:
		require(false, "transition probe slots were not allocated")
	else:
		var fine_slot := int(slots["fine"])
		var labels := {0.0: "blue", 0.5: "mixed", 1.0: "red"}
		for fine_fade in [0.0, 0.5, 1.0]:
			install_fade(fine_slot, fine_fade)
			var shot := await frame_image(3)
			var label := transition_label(shot)
			var center := shot.get_pixelv(Vector2i(int(SCREEN_CENTER.x), int(SCREEN_CENTER.y)))
			print("VT_TRANSITION_PARENT fade=%.2f label=%s center=%s" % [fine_fade, label, center])
			require(label == labels[fine_fade],
					"fine fade %.2f must resolve through the missing direct parent to the ancestor; got %s" % [fine_fade, label])

		# Removing the fine page must still fail the strict first resolve.  The valid
		# ancestor above is intentionally left in the indirection table to catch a
		# transition implementation that accidentally turns strict misses into recovery.
		var vt := terrain.get_surface_vt()
		var block := block_size
		var fine_x := clampi(int(floor(TARGET_XZ.x / 64.0 * float(block))), 0, block - 1)
		var fine_y := clampi(int(floor(TARGET_XZ.y / 64.0 * float(block))), 0, block - 1)
		vt.release_page(REGION, 0, fine_x, fine_y)
		vt.commit()
		var missing_shot := await frame_image(3)
		var missing_center := missing_shot.get_pixelv(Vector2i(int(SCREEN_CENTER.x), int(SCREEN_CENTER.y)))
		print("VT_TRANSITION_PARENT strict_missing center=", missing_center)
		require(is_diagnostic(missing_center),
				"a missing fine page must remain diagnostic even with a valid coarse ancestor")

	terrain.surface_vt_enabled = false
	terrain.set_process(false)
	terrain.set_physics_process(false)
	scene.queue_free()
	camera.queue_free()
	await process_frame
	await process_frame
	if failed:
		quit(1)
		return
	print("PASS AVT transition skips a missing direct parent while strict fine misses stay diagnostic")
	quit(0)
