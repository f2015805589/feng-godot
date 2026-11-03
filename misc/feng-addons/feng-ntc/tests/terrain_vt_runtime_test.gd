extends SceneTree
const Data = preload("res://addons/feng-ntc/terrain_vt_data.gd")
var baker: Terrain3DSurfaceBaker
func _init() -> void: _run.call_deferred()
func frames(count: int) -> void:
	for i in range(count): await RenderingServer.frame_post_draw
func _run() -> void:
	create_timer(90.0).timeout.connect(func(): push_error("VT runtime test timed out"); quit(1))
	if ClassDB.class_exists(&"FengNTCCodec"): push_error("Runtime test must have no NTC SDK extension"); quit(1); return
	var asset: Resource = load("res://vt_pages.res")
	asset.runtime_storage = 1
	print("VT_NETWORK_SPACES ", asset.packages[0].constants.decode_u32(81*4))
	var reference: Array = FileAccess.open("res://references.bin", FileAccess.READ).get_var(false)
	# Force eviction/re-upload using two model addresses and a one-model GPU budget.
	asset.packages.append(asset.packages[0])
	asset.gpu_model_cache = 1
	asset.cache_compression = 0
	var index := 0
	for entry: Dictionary in asset.pages.values(): entry.model = index%2; index += 1
	baker = Terrain3DSurfaceBaker.new()
	baker.get_stats() # A pre-device statistics probe must not disable GPU copies.
	baker.configure(64, 2, 16)
	baker.set_tier_compression(0, 4)
	baker.set_tier_compression(1, 4)
	baker.set_materials(RID(), RID(), PackedColorArray(), PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array(), PackedVector2Array(), PackedVector3Array())
	baker.set_neural_codec(asset.create_terrain_decoder())
	for i in range(16):
		if not baker.queue_neural_page(i, Rect2(i, 0, 1, 1), i%2, "synthetic-vt-1"): push_error("Neural page lookup failed"); quit(1); return
	if baker.queue_neural_page(0, Rect2(0, 0, 1, 1), 0, "stale"): push_error("Stale neural data accepted"); quit(1); return
	if baker.queue_neural_page(0, Rect2(99, 0, 1, 1), 0, "synthetic-vt-1"): push_error("Missing page accepted"); quit(1); return
	for attempt in range(100):
		RenderingServer.call_on_render_thread(baker.render_pending)
		await frames(1)
		if int(baker.get_tier_compression_info(0).neural_decodes) >= 16: break
	var stats := baker.get_tier_compression_info(0)
	print("TERRAIN_VT_RUNTIME_STATS ", stats)
	if int(stats.neural_decodes) != 16: push_error("VT pages did not decode"); quit(1); return
	for i in range(16):
		var decoded := baker.export_page(i)
		if not decoded.get("valid", false): push_error("VT page is not ready"); quit(1); return
		var key := Terrain3DSurfaceBaker.neural_page_key(Rect2(i, 0, 1, 1), 64, 2, i%2)
		var rect: Rect2i = asset.pages[key].rect
		for name: String in ["albedo_height", "normal_roughness", "params"]:
			var ref_info: Dictionary = reference[0][name]
			var ref_image := Image.create_from_data(ref_info.size.x, ref_info.size.y, true, Image.FORMAT_RGBAH, ref_info.pixels)
			var error := 0.0
			for y in range(68):
				for x in range(68):
					var a: Color = decoded[name].get_pixel(x, y)
					var b: Color = ref_image.get_pixel(rect.position.x+x, rect.position.y+y)
					if name == "normal_roughness":
						var n := Vector3(b.r, b.g, b.b).normalized(); b = Color(n.x, n.y, n.z, clampf(b.a, 0.0, 1.0))
					if name == "params": b.a = 1.0 if b.a >= 0.5 else 0.0
					error += (Vector4(a.r, a.g, a.b, a.a)-Vector4(b.r, b.g, b.b, b.a)).length_squared()
			error = sqrt(error/(68.0*68.0*4.0))
			print("VT_REFERENCE_ERROR ", i, " ", name, " ", error)
			# CUDA uses its fused/half intermediate implementation; the portable
			# integer/FP32 implementation need not be bit-identical to that backend.
			if error > 0.015: push_error("Signed VT decoder mismatch: %s / %s" % [name, error]); quit(1); return
	for i in range(12): RenderingServer.call_on_render_thread(baker.render_pending); await frames(1)
	if int(baker.get_tier_compression_info(0).neural_decodes) != 16: push_error("Cached VT pages decoded again"); quit(1); return
	# The NTC payload can optionally populate the existing hardware BC7 cache.
	asset.cache_compression = 1
	asset.max_pages_per_frame = 16
	baker.set_neural_codec(asset.create_terrain_decoder())
	for i in range(16):
		if not baker.queue_neural_page(i, Rect2(i, 0, 1, 1), i%2, "synthetic-vt-1"): quit(1); return
	for attempt in range(40):
		RenderingServer.call_on_render_thread(baker.render_pending)
		await frames(1)
		if int(baker.get_stats().ready_pages) == 16: break
	var bc_info := baker.get_tier_compression_info(0)
	print("VT_NTC_BC7_CACHE ", bc_info)
	if not baker.is_page_ready(0) or int(bc_info.applied) != 1 or bc_info.decoded_cache != "BC7": push_error("NTC to BC7 cache failed"); quit(1); return
	if int(baker.get_stats().ready_pages) != 16: push_error("Small staging ring lost a multi-batch page"); quit(1); return
	var cache_stats := baker.get_stats()
	if not cache_stats.get("sampled_arrays_shared", false): push_error("Identical tier formats allocated duplicate arrays"); quit(1); return
	if RenderingServer.get_rendering_device().has_method("texture_copy_from_buffer") and (int(cache_stats.staging_layers) != 8 or int(cache_stats.encode_readbacks) != 0):
		push_error("GPU-copy scratch path unexpectedly used readbacks or a full ring"); quit(1); return
	print("VT_SHARED_CACHE_STATS ", cache_stats)
	# Every slot in both tiers must survive aliasing and in-frame scratch reuse.
	for i in range(16):
		var page := baker.export_page(i)
		if not page.get("valid", false): push_error("Shared cache slot was overwritten"); quit(1); return
		var key := Terrain3DSurfaceBaker.neural_page_key(Rect2(i, 0, 1, 1), 64, 2, i%2)
		var rect: Rect2i = asset.pages[key].rect
		var ref_info: Dictionary = reference[0].albedo_height
		var ref_image := Image.create_from_data(ref_info.size.x, ref_info.size.y, true, Image.FORMAT_RGBAH, ref_info.pixels)
		for p: Vector2i in [Vector2i(8, 8), Vector2i(32, 32), Vector2i(60, 60)]:
			if absf(page.albedo_height.get_pixelv(p).b-ref_image.get_pixelv(rect.position+p).b) > 0.04:
				push_error("Scratch reuse corrupted another resident page"); quit(1); return
	var bc_page := baker.export_page(0)
	var normal: Color = bc_page.normal_roughness.get_pixel(32, 32)
	var parameters: Color = bc_page.params.get_pixel(32, 32)
	if normal.g < 0.8 or absf(parameters.r-1.4) > 0.08: push_error("NTC BC7 signed/range channels corrupted"); quit(1); return
	baker.set_tier_compression(0, 1)
	if baker.queue_neural_page(0, Rect2(0, 0, 1, 1), 0, "synthetic-vt-1"): push_error("BC7 mode used NTC"); quit(1); return
	# A live switch must release full staging, keep mixed tiers writable, and
	# preserve the immutable resource catalog through decoder retirement.
	asset.runtime_storage = 0
	asset.decoded_cache_pages = 8
	for modes: Vector2i in [Vector2i(4,4),Vector2i(4,1),Vector2i(1,4),Vector2i(1,1),Vector2i(4,4)]:
		baker.set_tier_compression(0,modes.x)
		baker.set_tier_compression(1,modes.y)
		baker.set_neural_codec(asset.create_terrain_decoder() if modes!=Vector2i(1,1) else {})
		for i in range(16):
			if modes[i%2]==4:
				if not baker.queue_neural_page(i,Rect2(i,0,1,1),i%2,"synthetic-vt-1"): push_error("Direct page rejected after switch"); quit(1); return
			else:
				baker.queue_cached_page(i,bc_page,i%2)
		for attempt in range(180):
			RenderingServer.call_on_render_thread(baker.render_pending)
			await frames(1)
			var current := baker.get_stats()
			if int(current.ready_pages)==16 and int(current.neural_runtime.get("cache_pending",0))==0: break
		var switched := baker.get_stats()
		if int(switched.ready_pages)!=16: push_error("Mixed codec switch lost pages: "+str(modes)); quit(1); return
		if modes==Vector2i(4,4) and int(switched.material_bytes)!=60: push_error("Direct residency retained the full decoded atlas"); quit(1); return
		if modes!=Vector2i(4,4) and int(switched.staging_layers)!=8: push_error("Mixed codecs allocated full raw staging"); quit(1); return
		for i in range(16):
			if modes[i%2]!=1: continue
			var decoded := baker.export_page(i)
			if not decoded.get("valid",false) or absf(decoded.albedo_height.get_pixel(32,32).b-bc_page.albedo_height.get_pixel(32,32).b)>0.04:
				push_error("Mixed codec switch corrupted hardware pages"); quit(1); return
		if asset.pages.size()!=16: push_error("Decoder retirement cleared the resource catalog"); quit(1); return
		print("VT_NTC_MODE_SWITCH ",modes," material_bytes=",switched.material_bytes)
	baker.clear()
	baker = null
	await frames(6)
	print("TERRAIN_VT_RUNTIME_PASS")
	quit()
