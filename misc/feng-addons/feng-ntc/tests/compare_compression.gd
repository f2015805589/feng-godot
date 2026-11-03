extends SceneTree
## Run in the NTC demo project. No retraining; compare the deployed payload with its source.
const TextureSet = preload("res://addons/feng-ntc/texture_set.gd")
const MaterialTools = preload("res://addons/feng-ntc/material_tools.gd")
const OUTPUT := "res://comparison"
var report := {"method": "2048x2048 RGBA8 source; complete mips; direct BC7 CVTT quality 3 versus portable NTC compute to RGBA8; RGB PSNR at mip 0", "materials": []}

func _init() -> void: _run.call_deferred()

func _run() -> void:
	if not ClassDB.class_exists(&"FengNTCCodec"): GDExtensionManager.load_extension("res://addons/feng-ntc/tools/feng_ntc.gdextension")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	for name: String in ["gray_rocks", "grass_ground"]:
		var source: StandardMaterial3D = load("res://materials/%s_original.tres" % name)
		var snapshot := MaterialTools.snapshot(source)
		if not snapshot.get("ok", false): push_error(str(snapshot)); quit(1); return
		var codec: Object = ClassDB.instantiate(&"FengNTCCodec")
		var started := Time.get_ticks_msec()
		var worker := Thread.new()
		worker.start(func() -> Dictionary: return codec.encode_bc7_material(MaterialTools.pack(snapshot)))
		while worker.is_alive(): await process_frame
		var direct: Dictionary = worker.wait_to_finish()
		if not direct.get("ok", false): push_error(str(direct)); quit(1); return
		var encoding_ms := Time.get_ticks_msec() - started
		var asset: Resource = load("res://materials/%s.ntc.res" % name)
		var loaded: Dictionary = await asset.prepare_async()
		if loaded.is_empty(): push_error(asset.last_error); quit(1); return
		var ntc_images := {}
		for slot: String in loaded: ntc_images[slot] = loaded[slot].get_image()
		var raw_bytes := 0
		var bc7_bytes := 0
		var raw_all := 0
		var bc7_all := 0
		for slot: String in direct.reference_images:
			raw_all += direct.reference_images[slot].get_data_size()
			bc7_all += direct.images[slot].get_data_size()
			if slot != "orm":
				raw_bytes += direct.reference_images[slot].get_data_size()
				bc7_bytes += direct.images[slot].get_data_size()
		var ntc_vram := 0
		for image: Image in ntc_images.values(): ntc_vram += image.get_data_size()
		var raw_mat := _material(source, direct.reference_images)
		var bc7_mat := _material(source, direct.images)
		var raw_path := OUTPUT + "/" + name + "_rgba8.res"
		var bc7_path := OUTPUT + "/" + name + "_bc7.res"
		if ResourceSaver.save(raw_mat, raw_path, ResourceSaver.FLAG_COMPRESS) != OK: quit(1); return
		if ResourceSaver.save(bc7_mat, bc7_path, ResourceSaver.FLAG_COMPRESS) != OK: quit(1); return
		var row := {"name": name, "source_maps": "albedo + normal; ORM is constant and omitted for conventional materials",
			"raw_rgba8_bytes": raw_bytes, "direct_bc7_bytes": bc7_bytes, "ntc_portable_bytes": var_to_bytes(asset.package).size(),
			"ntc_full_load_rgba8_bytes": ntc_vram, "source_all_maps_rgba8_bytes": raw_all, "source_all_maps_bc7_bytes": bc7_all,
			"rgba8_zstd_res_bytes": _size(raw_path), "bc7_zstd_res_bytes": _size(bc7_path),
			"ntc_zstd_res_bytes": _size("res://materials/%s.ntc.res" % name), "direct_bc7_encoding_ms": encoding_ms,
			"quality": {}}
		for slot: String in ["albedo", "normal"]:
			var reference := _base(direct.reference_images[slot])
			var bc7 := _base(direct.images[slot])
			var ntc := _base(ntc_images[slot])
			row.quality[slot] = {"bc7_rgb_psnr_db": _psnr(reference, bc7), "ntc_final_rgb_psnr_db": _psnr(reference, ntc)}
			if slot == "normal":
				row.quality[slot].bc7_angle = _normal_error(reference, bc7)
				row.quality[slot].ntc_angle = _normal_error(reference, ntc)
			# Fixed central crop; same pixels, 1:1 scale, no hand-picked differences.
			var region := Rect2i(896, 896, 256, 256)
			reference.get_region(region).save_png(OUTPUT + "/%s_%s_raw.png" % [name, slot])
			bc7.get_region(region).save_png(OUTPUT + "/%s_%s_bc7.png" % [name, slot])
			ntc.get_region(region).save_png(OUTPUT + "/%s_%s_ntc.png" % [name, slot])
		report.materials.append(row)
		print("COMPARISON: ", JSON.stringify(row))
	var file := FileAccess.open(OUTPUT + "/metrics.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("COMPARISON_COMPLETE")
	quit()

func _material(source: StandardMaterial3D, images: Dictionary) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	MaterialTools.copy_material_properties(source, material)
	material.resource_name = source.resource_name
	material.albedo_texture = ImageTexture.create_from_image(images.albedo)
	material.normal_texture = ImageTexture.create_from_image(images.normal)
	# These two demo sources contain no ORM textures. Keep scalar material settings, not a 2K constant image.
	return material

func _size(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	return file.get_length() if file != null else -1

func _base(image: Image) -> Image:
	var result: Image = image.duplicate()
	if result.is_compressed(): result.decompress()
	result.clear_mipmaps()
	result.convert(Image.FORMAT_RGB8)
	return result

func _psnr(reference: Image, decoded: Image) -> float:
	# Godot's RGB metric also averages the identical implicit alpha channel; correct to RGB only.
	var metric := reference.compute_image_metrics(decoded, false)
	return float(metric.peak_snr) - 10.0 * log(4.0 / 3.0) / log(10.0)

func _normal_error(reference: Image, decoded: Image) -> Dictionary:
	var angles := PackedFloat32Array()
	var sum := 0.0
	for y in range(0, reference.get_height(), 8):
		for x in range(0, reference.get_width(), 8):
			var a := reference.get_pixel(x, y)
			var b := decoded.get_pixel(x, y)
			# Godot's material normal path reconstructs positive Z from the stored XY components.
			var va := Vector3(a.r * 2.0 - 1.0, a.g * 2.0 - 1.0, 0)
			var vb := Vector3(b.r * 2.0 - 1.0, b.g * 2.0 - 1.0, 0)
			va.z = sqrt(maxf(0.0, 1.0 - va.length_squared()))
			vb.z = sqrt(maxf(0.0, 1.0 - vb.length_squared()))
			var angle := rad_to_deg(acos(clampf(va.normalized().dot(vb.normalized()), -1.0, 1.0)))
			angles.append(angle)
			sum += angle
	angles.sort()
	return {"mean_degrees": sum / angles.size(), "p95_degrees": angles[int(angles.size() * 0.95)], "samples": angles.size()}
