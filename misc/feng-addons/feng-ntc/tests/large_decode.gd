extends SceneTree
const Decoder = preload("res://addons/feng-ntc/gpu_decoder.gd")
const TextureSet = preload("res://addons/feng-ntc/texture_set.gd")
func _init() -> void: _run.call_deferred()
func _run() -> void:
	var codec: Object = ClassDB.instantiate(&"FengNTCCodec")
	var asset: Resource = load("res://large.ntc.res")
	var payload: PackedByteArray = asset.payload
	if not asset.ensure_portable(): push_error(asset.last_error); quit(1); return
	var data: Dictionary = asset.package
	var output := FileAccess.open("res://large_portable.bin",FileAccess.WRITE)
	output.store_var(data); output.close()
	var rd := RenderingServer.create_local_rendering_device()
	var decoder := Decoder.new()
	if not decoder.initialize(rd,data,Vector2i(data.width,data.height),data.mips): push_error(decoder.last_error); quit(1); return
	decoder.dispatch(Rect2i(0,0,1,1),Vector2i.ZERO,data.mips-1,data.mips-1)
	rd.submit(); rd.sync()
	var began := Time.get_ticks_usec()
	rd.capture_timestamp("full_begin")
	for mip in range(data.mips): decoder.dispatch(Rect2i(0,0,maxi(1,data.width>>mip),maxi(1,data.height>>mip)),Vector2i.ZERO,mip,mip)
	rd.capture_timestamp("full_end")
	rd.submit(); rd.sync()
	var elapsed := (Time.get_ticks_usec()-began)/1000.0
	var gpu_ms := -1.0
	for frame in range(4):
		for i in range(rd.get_captured_timestamps_count()-1):
			if rd.get_captured_timestamp_name(i)=="full_begin": gpu_ms=(rd.get_captured_timestamp_gpu_time(i+1)-rd.get_captured_timestamp_gpu_time(i))/1000000.0
		rd.submit(); rd.sync()
	var images := decoder.read_images()
	images.albedo.save_png("res://large_gpu_full.png")
	var ref: Dictionary = codec.decode_material(payload,0,false) if not payload.is_empty() else {"images":{}}
	var metrics := {"width":data.width,"height":data.height,"portable_bytes":var_to_bytes(data).size(),"maps":data.maps.keys(),"full_submit_sync_ms":elapsed,"full_gpu_ms":gpu_ms,"parity":{}}
	for name: String in images:
		if ref.images.has(name):
			var m: Dictionary = images[name].compute_image_metrics(ref.images[name],false)
			metrics.parity[name]=m
			ref.images[name].get_region(Rect2i(896,896,256,256)).save_png("res://large_cuda_"+name+".png")
		images[name].get_region(Rect2i(896,896,256,256)).save_png("res://large_gpu_"+name+".png")
	# Compare small pages to full decoding, including virtual image wrap/gutters.
	var pages := Decoder.new()
	if not pages.initialize(rd,data,Vector2i(68,68),1,true): push_error(pages.last_error); quit(1); return
	var timings: Array[float] = []
	for i in range(12):
		began=Time.get_ticks_usec()
		rd.capture_timestamp("page_begin")
		pages.dispatch(Rect2i(-2,-2,68,68),Vector2i.ZERO,0)
		rd.capture_timestamp("page_end")
		rd.submit(); rd.sync()
		if i>1: timings.append((Time.get_ticks_usec()-began)/1000.0)
	var page_images := pages.read_images()
	page_images.albedo.save_png("res://streamed_page.png")
	var page_diff := 0.0
	for xy in [Vector2i(0,0),Vector2i(1,1),Vector2i(2,2),Vector2i(67,67),Vector2i(35,27)]:
		var a: Color=page_images.albedo.get_pixelv(xy)
		var b: Color=images.albedo.get_pixel(posmod(xy.x-2,data.width),posmod(xy.y-2,data.height))
		print("TILE_PIXEL ",xy," ",a," / ",b)
		page_diff=maxf(page_diff,absf(a.r-b.r)+absf(a.g-b.g)+absf(a.b-b.b))
	timings.sort()
	metrics.page_submit_sync_median_ms=timings[timings.size()/2]
	metrics.gutter_max_rgb_diff=page_diff
	metrics.full_gpu_compressed_bytes=decoder.gpu_compressed_bytes
	metrics.vt_gpu_compressed_bytes=pages.gpu_compressed_bytes
	var staged := rd.buffer_get_data(pages._buffers[2])
	var ranges := rd.buffer_get_data(pages._buffers[3]).to_int32_array()
	var mismatches := 0
	var neural: int=data.constants.decode_s32(0)
	for level in range(2):
		for layer in range(data.layers):
			var i: int=(level*data.layers+layer)*8
			var j: int=((neural+level)*data.layers+layer)*4
			for y in range(ranges[i+7]):
				for x in range(ranges[i+6]):
					var got := staged.decode_u16(ranges[i]+y*ranges[i+3]+x*2)
					var expected: int=data.latents.decode_u16(data.layout[j]+posmod(y+ranges[i+5],data.layout[j+2])*data.layout[j+3]+posmod(x+ranges[i+4],data.layout[j+1])*2)
					if got!=expected: mismatches+=1
	print("FEATURE_WINDOW ",ranges," MISMATCHES ",mismatches)
	for frame in range(4):
		for i in range(rd.get_captured_timestamps_count()-1):
			if rd.get_captured_timestamp_name(i)=="page_begin": metrics.page_gpu_ms=(rd.get_captured_timestamp_gpu_time(i+1)-rd.get_captured_timestamp_gpu_time(i))/1000000.0
		rd.submit(); rd.sync()
	print("LARGE_DECODE: ",JSON.stringify(metrics))
	output=FileAccess.open("res://large_metrics.json",FileAccess.WRITE)
	output.store_string(JSON.stringify(metrics,"\t")); output.close()
	pages.dispose(); decoder.dispose(); rd.free()
	print("LARGE_RESULT: ","PASS" if page_diff<0.001 else "FAIL")
	quit(0 if page_diff<0.001 else 1)
