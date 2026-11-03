@tool
extends RefCounted
## Offline authoring only. Captured pages include their original VT gutters and
## exact texel density. Never train or read back textures during game streaming.
const Data = preload("terrain_vt_data.gd")
const CHANNELS := ["albedo_height", "normal_roughness", "params"]


static func compress(codec: Object, captured: Array, signature: String, bpp: float, steps: int) -> Dictionary:
	if captured.is_empty() or signature.is_empty(): return {"ok": false, "error": "当前没有可压缩的 VT 页；请先让地形预览生成页面。"}
	var asset := Data.new()
	asset.source_signature = signature
	var size: Vector2i = captured[0].albedo_height.get_size()
	var stride := Vector2i(((size.x+16+15)/16)*16, ((size.y+16+15)/16)*16)
	# Train groups together: fixed-size SGD batches make one larger model much
	# faster than training dozens of small models independently at the same steps.
	var atlas_size := Vector2i(4096, 4096)
	var grid := atlas_size / stride
	if grid.x < 1 or grid.y < 1: return {"ok": false, "error": "VT 页面过大。"}
	var capacity := grid.x * grid.y
	var psnr: Array[float] = []
	for first in range(0, captured.size(), capacity):
		if codec.has_method("set_batch"): codec.set_batch(first/capacity+1, ceili(captured.size()/float(capacity)))
		var count := mini(capacity, captured.size()-first)
		atlas_size = _atlas_shape(count, stride)
		grid = atlas_size / stride
		var images: Dictionary = {}
		for name: String in CHANNELS: images[name] = Image.create_empty(atlas_size.x, atlas_size.y, false, Image.FORMAT_RGBAF)
		for i in range(count):
			var page: Dictionary = captured[first+i]
			var origin := Vector2i(i%grid.x, i/grid.x) * stride + Vector2i(8, 8)
			for name: String in CHANNELS:
				var image: Image = page[name].duplicate()
				if image.get_size() != size: return {"ok": false, "error": "VT 页尺寸在捕获期间发生变化。"}
				image.convert(Image.FORMAT_RGBAF)
				images[name].blit_rect(image, Rect2i(Vector2i.ZERO, size), origin)
				# Extra atlas padding separates unrelated pages, in addition to the
				# original terrain gutter. It is excluded from page addressing.
				for pad in range(8):
					images[name].blit_rect(image, Rect2i(0, 0, size.x, 1), origin-Vector2i(0, pad+1))
					images[name].blit_rect(image, Rect2i(0, size.y-1, size.x, 1), origin+Vector2i(0, size.y+pad))
					images[name].blit_rect(image, Rect2i(0, 0, 1, size.y), origin-Vector2i(pad+1, 0))
					images[name].blit_rect(image, Rect2i(size.x-1, 0, 1, size.y), origin+Vector2i(size.x+pad, 0))
			asset.pages[page.key] = {"model": asset.packages.size(), "rect": Rect2i(origin, size)}
		var result: Dictionary = codec.compress_terrain_pages(images, bpp, steps, 0)
		images.clear()
		if not result.get("ok", false): return result
		asset.packages.append(result.package)
		psnr.append(float(result.psnr))
		result.erase("images")
		result.erase("payload")
	return {"ok": true, "asset": asset, "psnr": psnr, "storage": asset.get_storage_info()}


static func _atlas_shape(count: int, stride: Vector2i) -> Vector2i:
	var best := Vector2i(4096, 4096)
	for width: int in [128, 256, 512, 1024, 2048, 4096]:
		for height: int in [128, 256, 512, 1024, 2048, 4096]:
			if (width/stride.x)*(height/stride.y) >= count and width*height < best.x*best.y:
				best = Vector2i(width, height)
	return best
