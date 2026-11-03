extends SceneTree
## Isolated decoder throughput, not total terrain frame time. No SDK or model training.
const Decoder=preload("res://addons/feng-ntc/gpu_decoder.gd")
var report: Dictionary={"scope":"GPU page decode only; CPU submit/sync separately; two-map 2K model", "cases":{}}
func _init() -> void: _run.call_deferred()
func distribution(values: Array) -> Dictionary:
	values.sort()
	return {"count":values.size(),"median_ms":values[values.size()/2],"p90_ms":values[int(values.size()*0.9)]}
func _run() -> void:
	var asset: Resource=load("res://sample.ntc.res")
	var data: Dictionary=asset.package
	var rd:=RenderingServer.create_local_rendering_device()
	for spec in [[64,2],[256,5]]:
		var size: int=spec[0]+2*spec[1]
		var decoder:=Decoder.new()
		if not decoder.initialize(rd,data,Vector2i(size,size),1,false):
			push_error(decoder.last_error); quit(1); return
		for batch in [1,4]:
			var gpu: Array=[]; var wall: Array=[]
			var prefix: String="%d_%d_" % [size,batch]
			for iteration in range(44):
				var begin:=Time.get_ticks_usec()
				rd.capture_timestamp(prefix+str(iteration)+"_begin")
				for page in range(batch):
					if not decoder.dispatch(Rect2i(101-spec[1],127-spec[1],size,size),Vector2i.ZERO,0):
						push_error("Cannot dispatch page"); quit(1); return
				rd.capture_timestamp(prefix+str(iteration)+"_end")
				rd.submit(); rd.sync()
				if iteration>=4: wall.append((Time.get_ticks_usec()-begin)/1000.0)
				_collect(rd,prefix,gpu)
			for flush in range(4):
				rd.submit(); rd.sync(); _collect(rd,prefix,gpu)
			report.cases[prefix]={"core":spec[0],"border":spec[1],"batch":batch,"gpu":distribution(gpu),"submit_sync":distribution(wall),"gpu_compressed_bytes":decoder.gpu_compressed_bytes}
		decoder.dispose()
	if not _check_reference(rd,data): quit(1); return
	rd.free()
	print("PAGE_BENCHMARK: ",JSON.stringify(report))
	var file:=FileAccess.open("res://page_benchmark.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t")); file.close()
	quit()
func _check_reference(rd: RenderingDevice,data: Dictionary) -> bool:
	# An original-kernel snapshot can be supplied in an isolated test directory.
	# It is intentionally not shipped with the plugin or used at runtime.
	if not FileAccess.file_exists("res://baseline_decoder.gd"): return true
	var reference: RefCounted=load("res://baseline_decoder.gd").new()
	var decoder:=Decoder.new()
	if not reference.initialize(rd,data,Vector2i(266,266),1,false) or not decoder.initialize(rd,data,Vector2i(266,266),1,false): return false
	report.parity=[]
	for mip in [0,2,int(data.mips)-1]:
		for origin in [Vector2i(-5,-5),Vector2i(517,137)]:
			var rect:=Rect2i(origin,Vector2i(266,266))
			reference.dispatch(rect,Vector2i.ZERO,mip); decoder.dispatch(rect,Vector2i.ZERO,mip)
			rd.submit(); rd.sync()
			var old_images: Dictionary=reference.read_images(); var new_images:=decoder.read_images()
			for map: String in old_images:
				var equal: bool=old_images[map].get_data()==new_images[map].get_data()
				report.parity.append({"mip":mip,"origin":str(origin),"map":map,"identical":equal})
				if not equal: push_error("Optimized page differs from original kernel"); return false
	reference.dispose(); decoder.dispose()
	return true
func _collect(rd: RenderingDevice,prefix: String,values: Array) -> void:
	for i in range(rd.get_captured_timestamps_count()-1):
		var name:=rd.get_captured_timestamp_name(i)
		if name.begins_with(prefix) and name.ends_with("_begin") and int(name.trim_prefix(prefix).trim_suffix("_begin"))>=4:
			values.append((rd.get_captured_timestamp_gpu_time(i+1)-rd.get_captured_timestamp_gpu_time(i))/1000000.0)
