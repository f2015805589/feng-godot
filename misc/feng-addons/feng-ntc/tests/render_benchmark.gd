extends SceneTree
const TextureSet = preload("res://addons/feng-ntc/texture_set.gd")
const VTMaterial = preload("res://addons/feng-ntc/virtual_material.gd")
func _init() -> void: _run.call_deferred()
func frames(n: int) -> void:
	for i in range(n): await RenderingServer.frame_post_draw
func ordinary(textures: Dictionary) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_texture=textures.albedo
	mat.normal_enabled=true; mat.normal_texture=textures.get("normal")
	mat.roughness=0.8
	mat.roughness_texture=textures.get("orm"); mat.roughness_texture_channel=BaseMaterial3D.TEXTURE_CHANNEL_GREEN
	mat.metallic_texture=textures.get("orm"); mat.metallic_texture_channel=BaseMaterial3D.TEXTURE_CHANNEL_BLUE
	mat.ao_enabled=true; mat.ao_texture=textures.get("orm"); mat.ao_texture_channel=BaseMaterial3D.TEXTURE_CHANNEL_RED
	mat.uv1_scale=Vector3(0.125,0.125,1); mat.uv1_offset=Vector3(0.25,0.25,0)
	mat.texture_filter=BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	return mat
func _run() -> void:
	root.size=Vector2i(1280,720)
	var file := FileAccess.open("res://large_portable.bin",FileAccess.READ)
	var data: Dictionary=file.get_var(false); file.close()
	var asset:=TextureSet.new(); asset.package=data
	var textures: Dictionary=await asset.prepare_async()
	var raw:=ordinary(textures)
	var images: Dictionary={}
	for name: String in textures: images[name]=textures[name].get_image()
	var codec: Object=ClassDB.instantiate(&"FengNTCCodec")
	var result: Dictionary=codec.encode_bc7_material(images)
	if not result.get("ok",false): push_error(str(result)); quit(1); return
	var bc_textures: Dictionary={}
	for name: String in result.images: bc_textures[name]=ImageTexture.create_from_image(result.images[name])
	var bc:=ordinary(bc_textures)
	var vt:=VTMaterial.new(); vt.texture_set=asset
	vt.set_shader_parameter("uv_scale",Vector2(0.125,0.125))
	vt.set_shader_parameter("uv_offset",Vector2(0.25,0.25))
	vt.set_shader_parameter("roughness",0.8)
	vt.set_shader_parameter("ao_enabled",true)
	await frames(3)
	vt.request_uv_rect(Rect2(0.25,0.25,0.125,0.125),0)
	await frames(150)
	var root3d:=Node3D.new(); root.add_child(root3d)
	var cam:=Camera3D.new(); cam.projection=Camera3D.PROJECTION_ORTHOGONAL; cam.size=1.125
	root3d.add_child(cam); cam.position=Vector3(0,0,1.5)
	var quad:=QuadMesh.new(); quad.size=Vector2(2,1.125)
	var mesh:=MeshInstance3D.new(); mesh.mesh=quad; mesh.material_override=raw; root3d.add_child(mesh)
	var light:=DirectionalLight3D.new(); light.light_intensity_lux=1.0; root3d.add_child(light)
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(),true)
	var rows: Dictionary={"rgba8":[],"bc7":[],"vt_cache_hit":[]}
	var dispatches: int=vt.get_runtime_stats().dispatches
	for name: String in ["rgba8","bc7","vt_cache_hit","vt_cache_hit","bc7","rgba8"]:
		mesh.material_override={"rgba8":raw,"bc7":bc,"vt_cache_hit":vt}[name]
		await frames(40)
		for i in range(120):
			await RenderingServer.frame_post_draw
			var time:=RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid())
			if time>0.0: rows[name].append(time)
	var report: Dictionary={"resolution":[root.size.x,root.size.y],"scene":"single PBR quad, same UV1 0.125x0.125 window of 2K maps, no shadows, whole viewport GPU time","samples":{},"vt":vt.get_runtime_stats(),"cache_hit_new_dispatches":int(vt.get_runtime_stats().dispatches)-dispatches}
	for name: String in rows:
		var values: Array=rows[name]; values.sort()
		if values.is_empty(): push_error("No GPU timing samples"); quit(1); return
		report.samples[name]={"count":values.size(),"median_ms":values[values.size()/2],"p90_ms":values[int(values.size()*0.9)]}
	print("RENDER_BENCHMARK: ",JSON.stringify(report))
	file=FileAccess.open("res://render_benchmark.json",FileAccess.WRITE); file.store_string(JSON.stringify(report,"\t")); file.close()
	root3d.queue_free(); vt=null; raw=null; bc=null; asset=null; textures.clear(); bc_textures.clear()
	await frames(4)
	quit()
