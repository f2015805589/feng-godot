extends SceneTree
const Baker = preload("res://addons/feng-ntc/terrain_vt_baker.gd")
class CaptureCodec extends RefCounted:
	var codec: Object
	var reference: Array = []
	func compress_terrain_pages(images: Dictionary, bpp: float, steps: int, device: int) -> Dictionary:
		var result: Dictionary = codec.compress_terrain_pages(images, bpp, steps, device)
		if result.get("ok", false):
			var maps := {}
			for name: String in result.images:
				var image: Image = result.images[name]
				maps[name] = {"size": image.get_size(), "pixels": image.get_data()}
			reference.append(maps)
		return result

func _init() -> void: _run.call_deferred()
func _run() -> void:
	var wrapped := CaptureCodec.new()
	wrapped.codec = ClassDB.instantiate(&"FengNTCCodec")
	if not wrapped.codec.has_method("compress_terrain_pages"): push_error("Missing VT encoder"); quit(1); return
	var captured: Array = []
	for i in range(16):
		var page := {"key": Terrain3DSurfaceBaker.neural_page_key(Rect2(i, 0, 1, 1), 64, 2, i%2)}
		for name: String in Baker.CHANNELS: page[name] = Image.create_empty(68, 68, false, Image.FORMAT_RGBAH)
		for y in range(68):
			for x in range(68):
				var u := float(x)/67.0
				var v := float(y)/67.0
				var n := Vector3(sin(u*TAU+i)*0.4, 1.0, cos(v*TAU+i)*0.4).normalized()
				page.albedo_height.set_pixel(x, y, Color(0.1+u*0.4, 0.2+v*0.4, float(i)/32.0, 0.6))
				page.normal_roughness.set_pixel(x, y, Color(n.x, n.y, n.z, 0.6))
				page.params.set_pixel(x, y, Color(1.4, 0.3+u*0.6, 0.8, 1.0))
		captured.append(page)
	var result := Baker.compress(wrapped, captured, "synthetic-vt-1", 2.0, 4096)
	if not result.get("ok", false): push_error(str(result)); quit(1); return
	var asset: Resource = result.asset
	if ResourceSaver.save(asset, "res://vt_pages.res", ResourceSaver.FLAG_COMPRESS) != OK: quit(1); return
	var file := FileAccess.open("res://references.bin", FileAccess.WRITE)
	file.store_var(wrapped.reference, false)
	file.close()
	print("TERRAIN_VT_ENCODE_STATS ", result.storage, " psnr=", result.psnr)
	if int(result.storage.encoded_bytes) >= int(result.storage.bc7_page_bytes): push_error("NTC page data is larger than BC7"); quit(1); return
	print("TERRAIN_VT_ENCODE_PASS")
	quit()
