@tool
extends RefCounted
## Payload size and resident decoded texture size are different measurements.
## Estimates exclude driver allocation/alignment, descriptors and shader pipelines.
const Session = preload("gpu_session.gd")
const Decoder = preload("gpu_decoder.gd")
const SampleData = preload("sample_gpu_data.gd")

static func sample_summary(data: Dictionary) -> String:
	if not Decoder.validate(data).is_empty(): return "压缩数据不可用。"
	var info := SampleData.footprint(data)
	return "NTC 压缩数据直接采样：%d×%d，%d 张材质贴图；GPU 潜变量与网络合计 %s。完整 mip 可用，不分配解码后的 RGBA8 贴图。逐片元推理会增加计算量。不含驱动开销。" % [data.width,data.height,data.maps.size(),String.humanize_size(info.total_bytes)]

static func describe(data: Dictionary, axis := 8) -> Dictionary:
	if not Decoder.validate(data).is_empty(): return {}
	var pixels := 0
	var page_count := 0
	var rows := 0
	var pinned := 0
	for mip in range(int(data.mips)):
		var width := maxi(1,int(data.width)>>mip)
		var height := maxi(1,int(data.height)>>mip)
		pixels += width*height
		var grid := Vector2i(ceili(width/float(Session.TILE)),ceili(height/float(Session.TILE)))
		page_count += grid.x*grid.y
		rows += grid.y
		if grid == Vector2i.ONE: pinned += 1
	axis=mini(clampi(axis,4,16),ceili(sqrt(float(page_count))))
	var mip := 0
	while mip < int(data.mips)-1:
		var pages := ceili(maxi(1,int(data.width)>>mip)/float(Session.TILE))*ceili(maxi(1,int(data.height)>>mip)/float(Session.TILE))
		if pages+pinned<=axis*axis: break
		mip+=1
	var map_count: int=data.maps.size()
	var atlas := axis*axis*Session.STRIDE*Session.STRIDE*4*map_count
	var table := ceili(int(data.width)/float(Session.TILE))*rows*16
	var network: int=data.constants.size()+data.weights.size()+Decoder.PAGE_BUFFER_BYTES+2*int(data.layers)*32
	var placeholders := (3-map_count)*4
	return {"map_count":map_count, "maps":data.maps.keys(),
		"source_buffer_bytes":data.constants.size()+data.weights.size()+data.latents.size()+data.layout.size()*4,
		"full_rgba8_bytes":pixels*4*map_count, "rgba8_per_map_bytes":pixels*4,
		"vt_atlas_bytes":atlas, "vt_page_table_bytes":table, "vt_network_bytes":network,
		"vt_total_bytes":atlas+table+network+placeholders, "placeholder_bytes":placeholders,
		"cache_pages":axis*axis, "whole_uv_mip":mip,
		"whole_uv_size":Vector2i(maxi(1,int(data.width)>>mip),maxi(1,int(data.height)>>mip))}

static func gpu_bytes(stats: Dictionary) -> int:
	return int(stats.get("texture_bytes",0))+int(stats.get("page_table_bytes",0))+int(stats.get("gpu_compressed_bytes",0))+int(stats.get("placeholder_bytes",0))

static func summary(data: Dictionary, virtual: bool, axis := 8) -> String:
	var info := describe(data,axis)
	if info.is_empty(): return "压缩数据不可用。"
	var result := "整组 %d 张图：模型数据 %s（不是显存）。" % [info.map_count,String.humanize_size(info.source_buffer_bytes)]
	if virtual:
		result += " VT 预计显存 %s，含图集、页表及解码缓冲。" % String.humanize_size(info.vt_total_bytes)
		result += " 全 UV 请求受缓存容量限制时为 mip %d（%d×%d），不等于全分辨率常驻。" % [info.whole_uv_mip,info.whole_uv_size.x,info.whole_uv_size.y]
	else:
		result += " 完整 RGBA8 纹理显存 %s，每张 %s；此模式仅压缩发布数据，不压缩 GPU 纹理。" % [String.humanize_size(info.full_rgba8_bytes),String.humanize_size(info.rgba8_per_map_bytes)]
	return result + " 不含驱动开销。"
