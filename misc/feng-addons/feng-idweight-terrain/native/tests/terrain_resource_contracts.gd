extends "res://vt_scene_base.gd"

var map_changes := 0

func connections(source: Object, signal_name: StringName, target: Object) -> int:
	var count := 0
	for connection in source.get_signal_connection_list(signal_name):
		if connection.callable.get_object() == target:
			count += 1
	return count

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	terrain = Terrain3D.new()
	terrain.vt_delivery_near_material = 0
	terrain.vt_delivery_far_material = 0
	terrain.vt_delivery_near_height = 0
	terrain.vt_delivery_far_height = 0
	root.add_child(terrain)
	terrain.collision_mode = 0
	terrain.region_size = 64
	terrain.set_physics_process(false)
	var data := terrain.data
	var old_material := terrain.material
	var old_assets := terrain.assets
	terrain.material = Terrain3DMaterial.new()
	require(connections(data, "maps_changed", old_material) == 0, "old material retained map subscription")
	require(connections(old_assets, "textures_changed", old_material) == 0, "old material retained texture subscription")
	require(connections(data, "maps_changed", terrain.material) == 1, "replacement material must subscribe once")
	terrain.assets = Terrain3DAssets.new()
	require(connections(old_assets, "textures_changed", terrain.material) == 0, "old asset library retained material subscription")
	require(connections(terrain.assets, "textures_changed", terrain.material) == 1, "replacement assets must subscribe once")

	var assets := terrain.assets
	var old_texture := Terrain3DTextureAsset.new()
	assets.set_texture_asset(0, old_texture)
	assets.set_texture_asset(0, Terrain3DTextureAsset.new())
	for signal_name in ["id_changed", "file_changed", "setting_changed"]:
		require(connections(old_texture, signal_name, assets) == 0, "replaced texture retained " + signal_name)
	var retained := assets.get_texture_asset(0)
	assets.clear_textures()
	for signal_name in ["id_changed", "file_changed", "setting_changed"]:
		require(connections(retained, signal_name, assets) == 0, "cleared texture retained " + signal_name)
	if OS.get_environment("TERRAIN_TEST_ABSENT_SLOT") == "1":
		assets.set_texture_asset(0, null)
		require(assets.get_texture_count() == 0, "clearing an absent slot inserted a texture")

	var old_mesh := assets.get_mesh_asset(0)
	var replacement := Terrain3DMeshAsset.new()
	var meshes: Array[Terrain3DMeshAsset] = [replacement]
	assets.set_mesh_list(meshes)
	require(assets.get_mesh_asset(0) == replacement, "mesh-list replacement reused old occupied slot")
	for signal_name in ["id_changed", "instancer_setting_changed"]:
		require(connections(old_mesh, signal_name, assets) == 0, "replaced mesh retained " + signal_name)

	# Pending colour/control uploads must not invalidate an unchanged height map.
	data.add_region_blank(Vector2i(-1, -1), false)
	data.update_maps(Terrain3DRegion.TYPE_HEIGHT, false, false)
	data.maps_changed.connect(func(): map_changes += 1)
	data.update_maps(Terrain3DRegion.TYPE_HEIGHT, false, false)
	require(map_changes == 0, "unrequested dirty maps emitted maps_changed")
	data.update_maps(Terrain3DRegion.TYPE_MAX, false, false)
	require(map_changes == 1, "remaining dirty maps did not publish their update")
	data.update_maps(Terrain3DRegion.TYPE_MAX, false, false)
	require(map_changes == 1, "settled map update emitted maps_changed")

	# Picking must use the authored density grid, including fractional negative positions.
	var region := data.get_region(Vector2i(-1, -1))
	region.set_surface_density(2)
	var pixels := PackedByteArray()
	pixels.resize(128 * 128 * 2)
	for y in 128:
		for x in 128:
			pixels.encode_u16((y * 128 + x) * 2, material_word(x % 2))
	region.set_surface_map(Image.create_from_data(128, 128, false, Image.FORMAT_R16, pixels))
	require(data.get_texture_id(Vector3(-0.25, 0, -0.25)).x == 1, "negative fractional material sample ignored density")
	require(data.get_texture_id(Vector3(-64, 0, -1)).x == 0, "negative region edge sampled the wrong payload")

	# The compact selector must preserve each generated variant byte-for-byte.
	terrain.material.shader_override_enabled = true
	for max_regions in [64, 128, 256, 512, 1024]:
		for filtering in 4:
			terrain.material.max_regions = max_regions
			terrain.material.texture_filtering = filtering
			var shader := Shader.new()
			terrain.material.shader_override = shader
			var code := shader.code
			require(not code.is_empty(), "shader variant capture must contain source")
			print("VARIANT ", max_regions, " ", filtering, " ", code.md5_text())

	root.remove_child(terrain)
	require(connections(data, "maps_changed", terrain.material) == 0, "tree exit retained material subscription")
	root.add_child(terrain)
	terrain.set_physics_process(false)
	require(connections(data, "maps_changed", terrain.material) == 1, "tree re-entry duplicated material subscription")
	terrain.free()
	if not failed:
		print("PASS terrain resource ownership and map dirtiness")
	quit(1 if failed else 0)
