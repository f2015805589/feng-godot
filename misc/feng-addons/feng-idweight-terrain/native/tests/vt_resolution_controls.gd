extends SceneTree

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var terrain := Terrain3D.new()
	assert(terrain.vt_pages_per_update == 16)
	# No ceiling: the setting is the number that was set. The only guard is positivity.
	terrain.vt_pages_per_update = 64
	assert(terrain.vt_pages_per_update == 64)
	terrain.vt_pages_per_update = 1024
	assert(terrain.vt_pages_per_update == 1024)
	terrain.vt_pages_per_update = 0
	assert(terrain.vt_pages_per_update == 1)
	terrain.vt_pages_per_update = 16
	root.add_child(terrain)
	terrain.set_process(false)
	terrain.set_physics_process(false)
	var window = load("res://addons/feng-idweight-terrain/src/vt_editor.gd").new()
	root.add_child(window)
	window.initialize(null)
	window.set_terrain(terrain)
	window._refresh_settings_controls()
	assert(window.find_child("AVTResolution", true, false) == null)
	window.avt_density_spin.value = 768
	assert(terrain.surface_vt_texels_per_meter == 768)
	assert(terrain.get_vt_settings().avt_virtual_resolution == 49152)
	assert(terrain.get_vt_settings().avt_base_block_size == 256)
	window.svt_density_spin.value = 2
	assert(terrain.surface_svt_texels_per_meter == 2)
	assert(terrain.surface_vt_texels_per_meter == 768)
	window.page_size_spin.value = 128
	assert(terrain.surface_svt_texels_per_meter == 2)
	assert(terrain.surface_vt_texels_per_meter == 768)
	assert(terrain.get_vt_settings().avt_base_block_size == 512)
	window.avt_band_spins[1].value = 512
	assert(terrain.surface_vt_texels_per_meter == 1024)
	assert(window.avt_band_spins[0].value == 1024)
	assert(window.avt_band_spins[1].value == 512)
	assert(window.avt_band_spins[2].value == 256)
	assert(terrain.surface_svt_texels_per_meter == 2)
	assert(window.find_child("AVTRegionGridX", true, false) == null)
	assert(window.find_child("AVTRegionOffsetX", true, false) == null)
	assert(window.avt_band_spins.size() == 3)
	assert(window.find_child("AVTMipDistance0", true, false) == null)
	window.avt_distance_spin.value = 768
	assert(terrain.surface_vt_distance == 768)
	# Sector tier count is independent of the complete local page-table chain.
	assert(terrain.surface_vt_mip_levels == 3)
	var local_cap := int(terrain.get_vt_settings().avt_mip_level_cap)
	assert(local_cap == 9) # 64m * 1024 texels/m / 128 texels/page = 512 entries.
	terrain.surface_vt_mip_levels = 4
	assert(terrain.surface_vt_mip_levels == 4)
	assert(terrain.get_vt_settings().avt_mip_levels == 4)
	assert(terrain.get_vt_settings().avt_mip_level_cap == local_cap)
	terrain.surface_vt_mip_levels = 0
	assert(terrain.surface_vt_mip_levels == 3)
	assert(terrain.get_vt_settings().avt_mip_level_cap == local_cap)
	assert(window.mip_levels_spin != null and window.mip_levels_spin.name == "MipLevels")
	window.mip_levels_spin.value = 10
	assert(terrain.surface_vt_mip_levels == 10)
	assert(terrain.get_vt_settings().avt_sector_resolution_levels == 10)
	assert(terrain.get_vt_settings().avt_mip_level_cap == local_cap)
	window.mip_levels_spin.value = 3
	assert(terrain.surface_vt_mip_levels == 3)
	# Preview preference must never suppress runtime VT.
	assert(terrain.vt_editor_preview and not terrain.is_vt_editor_preview_active())
	var packed := PackedScene.new()
	assert(packed.pack(terrain) == OK)
	var restored: Terrain3D = packed.instantiate()
	assert(restored.surface_vt_texels_per_meter == 1024)
	assert(restored.surface_svt_texels_per_meter == 2)
	assert(restored.surface_vt_mip_distances.is_empty())
	assert(restored.surface_vt_distance == 768)
	assert(restored.surface_vt_mip_levels == 3)
	restored.free()
	window.free()
	terrain.free()
	print("PASS independent VT density and explicit mip controls")
	quit(0)
