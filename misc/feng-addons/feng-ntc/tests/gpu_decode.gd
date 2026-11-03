extends SceneTree
const Decoder = preload("res://addons/feng-ntc/gpu_decoder.gd")
func _init() -> void: _run.call_deferred()
func _run() -> void:
	var codec: Object = ClassDB.instantiate(&"FengNTCCodec")
	var payload := FileAccess.get_file_as_bytes("res://material.ntc")
	var prepared: Dictionary = codec.prepare_portable(payload)
	print("PREPARED: ", prepared.get("ok"), " ", prepared.get("error", ""))
	if not prepared.get("ok", false): quit(1); return
	var data: Dictionary = prepared.package
	print("PORTABLE_LAYOUT: ", [data.width,data.height,data.layers,data.latent_mips,data.weights.size(),data.latents.size()])
	var rd := RenderingServer.create_local_rendering_device()
	var decoder := Decoder.new()
	if not decoder.initialize(rd, data, Vector2i(data.width,data.height), data.mips):
		push_error(decoder.last_error); decoder.dispose(); rd.free(); quit(1); return
	rd.capture_timestamp("begin")
	for mip in range(data.mips):
		decoder.dispatch(Rect2i(0,0,maxi(1,data.width>>mip),maxi(1,data.height>>mip)), Vector2i.ZERO,mip,mip)
	rd.capture_timestamp("end")
	rd.submit(); rd.sync()
	var images := decoder.read_images()
	var reference: Dictionary = codec.decode_material(payload,0,false)
	var failed := false
	for name: String in images:
		var metrics: Dictionary = images[name].compute_image_metrics(reference.images[name],false)
		print("GPU_PARITY ", name, " ", metrics)
		if float(metrics.root_mean_squared) > 2.0: failed = true
		if name == "albedo":
			for xy in [Vector2i(0,0),Vector2i(1,1),Vector2i(64,64),Vector2i(127,127)]: print("PIXEL ",xy," ",images[name].get_pixelv(xy)," / ",reference.images[name].get_pixelv(xy))
		reference.images[name].save_png("res://reference_"+name+".png")
		images[name].save_png("res://gpu_"+name+".png")
	for i in range(rd.get_captured_timestamps_count()): print("GPU_STAMP ", rd.get_captured_timestamp_name(i), " ", rd.get_captured_timestamp_gpu_time(i))
	var output := FileAccess.open("res://portable.bin",FileAccess.WRITE)
	output.store_var(data); output.close()
	decoder.dispose(); rd.free()
	print("GPU_DECODE_COMPLETE: ", not failed)
	quit(1 if failed else 0)
