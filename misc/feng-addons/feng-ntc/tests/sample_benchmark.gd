extends SceneTree
const Neural=preload("res://addons/feng-ntc/neural_material.gd")
const Virtual=preload("res://addons/feng-ntc/virtual_material.gd")
func _init() -> void: _run.call_deferred()
func frames(n: int) -> void:
	for i in range(n): await RenderingServer.frame_post_draw
func _run() -> void:
	root.size=Vector2i(1280,720)
	var original: StandardMaterial3D=load("res://materials/grass_ground_original.tres").duplicate()
	original.texture_filter=BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	original.uv1_scale=Vector3(0.125,0.125,1)
	var neural:=Neural.new()
	neural.texture_set=load("res://materials/grass_ground.ntc.res")
	neural.set_shader_parameter("uv_scale",Vector2(0.125,0.125))
	neural.set_shader_parameter("roughness",original.roughness)
	var virtual:=Virtual.new(); virtual.texture_set=neural.texture_set
	virtual.set_shader_parameter("uv_scale",Vector2(0.125,0.125))
	virtual.set_shader_parameter("roughness",original.roughness)
	await frames(3)
	virtual.request_uv_rect(Rect2(0,0,0.125,0.125),0)
	await frames(80)
	if not virtual.ntc_error.is_empty() or int(virtual.get_runtime_stats().get("requested_mip",-1))!=0:
		push_error("Fine mip VT benchmark not ready: "+virtual.ntc_error); quit(1); return
	var scene:=Node3D.new(); root.add_child(scene)
	var camera:=Camera3D.new(); camera.projection=Camera3D.PROJECTION_ORTHOGONAL; camera.size=1.125
	camera.position=Vector3(0,0,1.5); scene.add_child(camera)
	var quad:=QuadMesh.new(); quad.size=Vector2(2,1.125)
	var mesh:=MeshInstance3D.new(); mesh.mesh=quad; mesh.material_override=original; scene.add_child(mesh)
	var light:=DirectionalLight3D.new(); light.light_intensity_lux=1; scene.add_child(light)
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(),true)
	var rows: Dictionary={"bc1_bc5":[],"ntc_direct":[],"ntc_vt_cache":[]}
	var dispatches: int=virtual.get_runtime_stats().dispatches
	for name in ["bc1_bc5","ntc_direct","ntc_vt_cache","ntc_vt_cache","ntc_direct","bc1_bc5"]:
		mesh.material_override={"bc1_bc5":original,"ntc_direct":neural,"ntc_vt_cache":virtual}[name]
		await frames(20)
		for i in range(40):
			await RenderingServer.frame_post_draw
			var t:=RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid())
			if t>0: rows[name].append(t)
		print("MEASURED ",name)
	var report: Dictionary={"scope":"Whole 1280x720 viewport, same PBR quad, 0.125x0.125 UV at mip 0, no shadows","stats":neural.get_runtime_stats(),"vt_stats":virtual.get_runtime_stats(),"cache_hit_new_dispatches":int(virtual.get_runtime_stats().dispatches)-dispatches,"samples":{}}
	for name: String in rows:
		var values: Array=rows[name]; values.sort()
		if values.is_empty(): push_error("No GPU timing samples"); quit(1); return
		report.samples[name]={"count":values.size(),"median_ms":values[values.size()/2],"p90_ms":values[int(values.size()*0.9)]}
	print("SAMPLE_BENCHMARK: ",JSON.stringify(report))
	var file:=FileAccess.open("res://comparison/sample_benchmark.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t")); file.close()
	mesh.material_override=null; neural.texture_set=null; virtual.texture_set=null; neural=null; virtual=null; scene.queue_free(); await frames(4)
	if report.cache_hit_new_dispatches!=0: push_error("Cache-hit benchmark dispatched inference"); quit(1); return
	quit()
