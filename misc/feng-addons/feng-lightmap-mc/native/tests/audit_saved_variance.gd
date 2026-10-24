extends SceneTree
func _initialize() -> void:
	var data:Resource=load("res://Temp/gi_quality_lightmap_20261022/white_box_lightmap_candidate.res")
	var report:=[]
	for layer in data.radiance_layers.size():
		var rgba:PackedFloat32Array=data.radiance_layers[layer]
		var variance:PackedFloat32Array=data.luminance_variance_layers[layer]
		var relative:=[]
		var abs_se:=[]
		for pixel in variance.size():
			if rgba[pixel*4+3]<=0.0: continue
			var mean:=rgba[pixel*4]*.2126+rgba[pixel*4+1]*.7152+rgba[pixel*4+2]*.0722
			var se:=sqrt(maxf(variance[pixel],0.0)/float(data.samples_per_texel))
			abs_se.append(se)
			if mean>0.000001: relative.append(se/mean)
		relative.sort()
		abs_se.sort()
		report.append({"mesh":str(data.mesh_relative_paths[layer]),"covered":abs_se.size(),"relative_se_median":relative[int(relative.size()*.5)],"relative_se_p90":relative[int(relative.size()*.9)],"relative_se_p99":relative[int(relative.size()*.99)],"absolute_se_median":abs_se[int(abs_se.size()*.5)]})
	var f:=FileAccess.open("F:/godot/feng-godot/Temp/lightmap_native_20261022/saved_variance_audit.json",FileAccess.WRITE)
	f.store_string(JSON.stringify(report,"  "))
	f.close()
	print("SAVED_VARIANCE ",JSON.stringify(report))
	quit(0)
