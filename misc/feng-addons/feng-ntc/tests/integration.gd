extends SceneTree
const TextureSet = preload("res://addons/feng-ntc/texture_set.gd")
const Tools = preload("res://addons/feng-ntc/material_tools.gd")
const Cache = preload("res://addons/feng-ntc/compression_cache.gd")
const Decoder = preload("res://addons/feng-ntc/gpu_decoder.gd")
var checks := 0
var failures := 0
func _init() -> void: _run.call_deferred()
func check(ok: bool,message: String) -> void:
	checks += 1
	if not ok: failures += 1; print("FAIL: ",message)
func _run() -> void:
	check(ClassDB.class_exists(&"FengNTCCodec"),"Native editor extension registered")
	if failures: quit(1); return
	var codec: Object = ClassDB.instantiate(&"FengNTCCodec")
	check(codec.get_sdk_status().get("ok",false),"SDK available")
	check(not codec.compress_material({},6.0,512,0).ok,"Malformed input rejected")
	check(not codec.prepare_portable(PackedByteArray([1,2,3,4])).ok,"Malformed NTC rejected")
	var source := StandardMaterial3D.new()
	var color := Image.create(128,128,false,Image.FORMAT_RGBA8)
	var normal := Image.create(128,128,false,Image.FORMAT_RGBA8)
	for y in range(128):
		for x in range(128):
			color.set_pixel(x,y,Color(0.18+x/256.0,0.35,0.6,1))
			normal.set_pixel(x,y,Color(0.5,0.65,0.97697,1))
	source.albedo_texture = ImageTexture.create_from_image(color)
	source.normal_texture = ImageTexture.create_from_image(normal)
	source.normal_enabled = true
	var snapshot := Tools.snapshot(source)
	check(snapshot.ok,"Source material accepted")
	check(Tools.virtual_unsupported(source).is_empty(),"Opaque default PBR is supported by VT")
	source.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	check(not Tools.virtual_unsupported(source).is_empty(),"VT rejects unsupported transparency")
	source.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	var packed := Tools.pack(snapshot)
	check(packed.size()==2 and not packed.has("orm"),"No redundant constant ORM texture")
	var worker := Thread.new()
	worker.start(func() -> Dictionary: return codec.compress_material(packed,8.0,2048,0))
	while worker.is_alive(): await process_frame
	var result: Dictionary = worker.wait_to_finish()
	check(result.get("ok",false),"Actual compression without mandatory BC7 transcode")
	if not result.get("ok",false): print(result); quit(1); return
	check(result.images.albedo.get_format()==Image.FORMAT_RGBA8,"Preview remains raw RGBA")
	check(result.package.maps.size()==2 and Decoder.validate(result.package).is_empty(),"Portable metadata validates")
	var asset := TextureSet.new()
	asset.payload = result.payload
	check(asset.ensure_portable() and asset.payload.is_empty(),"Legacy payload migrates without duplicate storage")
	check(asset.package==result.package,"CPU preparation deterministic")
	check(ResourceSaver.save(asset,"res://material.ntc.res",ResourceSaver.FLAG_COMPRESS)==OK,"Save portable asset")
	var loaded: Resource = load("res://material.ntc.res")
	check(loaded.package==asset.package and loaded.payload.is_empty(),"Round-trip portable asset")
	var file := FileAccess.open("res://material.ntc",FileAccess.WRITE)
	file.store_buffer(result.payload); file.close()
	var decoded: Dictionary = codec.decode_material(result.payload,0,false)
	check(decoded.get("ok",false),"Optional CUDA reference decode")
	check(decoded.images.albedo.get_data()==result.images.albedo.get_data(),"Raw preview matches reference")
	var bc: Dictionary = codec.encode_bc7_material(packed)
	check(bc.get("ok",false) and bc.images.size()==2,"Optional direct BC7 export remains available")
	check(bc.images.albedo.get_format()==Image.FORMAT_BPTC_RGBA,"BC7 baseline format correct")
	var cancelled: Object = ClassDB.instantiate(&"FengNTCCodec")
	cancelled.cancel()
	check(not cancelled.compress_material(packed,8.0,2048,0).ok,"Cancelled training returns no asset")
	worker = Thread.new()
	worker.start(func() -> Dictionary: return Cache.compress(codec,packed,8.0,2048))
	while worker.is_alive(): await process_frame
	check(worker.wait_to_finish().get("ok",false),"Training cache saves")
	var cached := Cache.compress(codec,packed,8.0,2048)
	check(cached.get("compression_cache_hit",false),"Training cache avoids retraining")
	check(Cache.fingerprint(packed,8.0,2048)!=Cache.fingerprint(packed,8.0,4096),"Training settings invalidate cache")
	print("RESULT: %s (%d checks, %d failures)" % ["PASS" if failures==0 else "FAIL",checks,failures])
	quit(0 if failures==0 else 1)
