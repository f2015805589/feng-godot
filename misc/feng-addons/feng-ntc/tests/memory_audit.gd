extends SceneTree
## Run in NTC材质测试. Reads actual imported GPU formats and actual NTC allocations.
const MemoryInfo = preload("res://addons/feng-ntc/memory_info.gd")
const Neural=preload("res://addons/feng-ntc/neural_material.gd")
const SampleData=preload("res://addons/feng-ntc/sample_gpu_data.gd")
var failed := false

func _init() -> void: _run.call_deferred()

func _run() -> void:
	var report := {"scope":"Actual deployed material. Full resolution, all mips. Texture data bytes exclude driver allocations and shader pipelines.","materials":[]}
	for name in ["gray_rocks","grass_ground"]:
		var source: StandardMaterial3D = load("res://materials/%s_original.tres" % name)
		var material: Material=load("res://materials/%s_ntc.tres" % name)
		if not material is Neural: push_error("Project still references a decoded material: "+name); quit(1); return
		var asset: Resource=material.texture_set
		var row := {"name":name,"imported_maps":{},"imported_total_bytes":0,"production_material_script":material.get_script().resource_path}
		for slot in ["albedo_texture","normal_texture"]:
			var texture: Texture2D = source.get(slot)
			var image := texture.get_image()
			row.imported_maps[slot]={"format":_format(image.get_format()),"bytes":image.get_data_size()}
			row.imported_total_bytes+=image.get_data_size()
		row.ntc_file_bytes=FileAccess.open(asset.resource_path,FileAccess.READ).get_length()
		var session: RefCounted=asset.get_sample_session()
		while not session.ready and session.last_error.is_empty(): await process_frame
		if not session.last_error.is_empty(): push_error(session.last_error); quit(1); return
		row.logical_resolution=[asset.package.width,asset.package.height]
		row.mip_count=asset.package.mips
		row.ntc_stats=material.get_runtime_stats()
		row.ntc_gpu_bytes=MemoryInfo.gpu_bytes(row.ntc_stats)
		row.bc_to_ntc_ratio=float(row.imported_total_bytes)/float(row.ntc_gpu_bytes)
		row.gpu_reduction_percent=100.0*(1.0-float(row.ntc_gpu_bytes)/float(row.imported_total_bytes))
		if not asset.get_runtime_stats().is_empty(): failed=true; push_error("Production path allocated full decoded textures")
		if row.ntc_gpu_bytes!=SampleData.footprint(asset.package).total_bytes: failed=true
		if row.bc_to_ntc_ratio<4.0: failed=true; push_error("Expected at least 4x texture-data reduction")
		report.materials.append(row)
		print("MEMORY_AUDIT: ",JSON.stringify(row))
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--report="):
			var file := FileAccess.open(argument.trim_prefix("--report="),FileAccess.WRITE)
			if file != null: file.store_string(JSON.stringify(report,"\t")); file.close()
	for frame in range(5): await process_frame
	print("MEMORY_AUDIT_", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)

func _format(format: int) -> String:
	return {Image.FORMAT_DXT1:"DXT1 / BC1",Image.FORMAT_DXT5:"DXT5 / BC3",Image.FORMAT_RGTC_RG:"BC5",Image.FORMAT_BPTC_RGBA:"BC7",Image.FORMAT_RGBA8:"RGBA8",Image.FORMAT_RGB8:"RGB8"}.get(format,str(format))
