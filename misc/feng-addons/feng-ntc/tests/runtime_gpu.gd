extends SceneTree
const TextureSet = preload("res://addons/feng-ntc/texture_set.gd")
const NTMaterial = preload("res://addons/feng-ntc/material.gd")
const VTMaterial = preload("res://addons/feng-ntc/virtual_material.gd")
const Decoder = preload("res://addons/feng-ntc/gpu_decoder.gd")
const MemoryInfo = preload("res://addons/feng-ntc/memory_info.gd")
const MaterialTools = preload("res://addons/feng-ntc/material_tools.gd")
var failures := 0
var checks := 0

func _init() -> void: _run.call_deferred()
func check(ok: bool,message: String) -> void:
	checks += 1
	if not ok: failures += 1; print("FAIL: ",message)
func frames(n: int) -> void:
	for i in range(n): await process_frame
func _run() -> void:
	for name in ["texture_set.gd","material.gd","virtual_material.gd","streamer.gd","gpu_session.gd","runtime.gd","gpu_decoder.gd","editor_plugin.gd","export_plugin.gd","compression_cache.gd","material_tools.gd","importer.gd"]:
		var script := load("res://addons/feng-ntc/"+name) as GDScript
		check(script != null and script.can_instantiate(),"Parse "+name)
	if failures: quit(1); return
	check(not ClassDB.class_exists(&"FengNTCCodec"),"Runtime has no SDK extension loaded")
	var file := FileAccess.open("res://portable.bin",FileAccess.READ)
	var data: Dictionary = file.get_var(false)
	file.close()
	check(Decoder.validate(data).is_empty(),"Portable metadata valid")
	var malformed := data.duplicate(true)
	malformed.latents = PackedByteArray([1,2,3,4])
	check(not Decoder.validate(malformed).is_empty(),"Reject out-of-range latent data")
	# Releasing a material before loading finishes must not resume a destroyed script instance.
	var transient_asset := TextureSet.new(); transient_asset.package=data
	var transient_material := NTMaterial.new(); transient_material.texture_set=transient_asset
	await frames(2)
	transient_material=null; transient_asset=null
	await frames(4)
	var asset := TextureSet.new()
	asset.package = data
	var started := Time.get_ticks_msec()
	var textures: Dictionary = await asset.prepare_async()
	check(textures.size() == data.maps.size(),"Generic compute decode without CUDA/DLL")
	var actual_texture_bytes := 0
	for texture: Texture2D in textures.values(): actual_texture_bytes+=texture.get_image().get_data_size()
	check(MemoryInfo.describe(data).full_rgba8_bytes==actual_texture_bytes,"Full-load memory estimate matches actual GPU texture bytes")
	print("FULL_LOAD_MS: ",Time.get_ticks_msec()-started)
	var reference := Image.load_from_file("res://gpu_albedo.png")
	var decoded: Image = textures.albedo.get_image()
	var metric := reference.compute_image_metrics(decoded,false)
	print("GLOBAL_LOCAL_PARITY: ",metric)
	check(metric.root_mean_squared < 0.01,"Global and local RD output identical")
	var before: int = asset.get_runtime_stats().dispatches
	await frames(20)
	check(asset.get_runtime_stats().dispatches == before,"Idle full material does no inference")
	var mat := NTMaterial.new()
	mat.texture_set = asset
	await frames(4)
	check(mat.albedo_texture != null,"Standard material receives RGBA GPU texture")
	check(ResourceSaver.save(asset,"res://runtime_model.res",ResourceSaver.FLAG_COMPRESS)==OK,"Save portable model")
	asset.take_over_path("res://runtime_model.res")
	check(ResourceSaver.save(mat,"res://runtime_material.tres")==OK,"Save portable material")
	var text := FileAccess.get_file_as_string("res://runtime_material.tres")
	check(not "Texture2DRD" in text,"No runtime texture serialized")
	var vt := VTMaterial.new()
	vt.cache_axis = 4
	vt.texture_set = asset
	await frames(150)
	check(vt.ntc_error.is_empty(),"VT no decode errors: "+vt.ntc_error)
	var stats: Dictionary = vt.get_runtime_stats()
	var estimated := MemoryInfo.describe(data,4)
	check(MemoryInfo.gpu_bytes(stats)==estimated.vt_total_bytes,"VT memory includes atlas, page table, staging and placeholder textures")
	check(stats.requested_mip==estimated.whole_uv_mip,"Whole-UV warning reports actual capacity-limited mip")
	print("VT_STATS: ",stats)
	check(stats.resident_pages<=16 and stats.resident_pages>0,"VT cache is bounded")
	before = stats.dispatches
	vt.request_uv_rect(Rect2(0,0,1,1),0)
	await frames(20)
	check(vt.get_runtime_stats().dispatches==before,"Resident requests do zero neural dispatches")
	check(ResourceSaver.save(vt,"res://runtime_virtual.tres")==OK,"Save VT material")
	text = FileAccess.get_file_as_string("res://runtime_virtual.tres")
	check(not "Texture2DRD" in text and not "ntc_pages =" in text,"No atlas/page table serialized")
	var vt_asset := TextureSet.new(); vt_asset.package=data
	var reused := MaterialTools.make_virtual(StandardMaterial3D.new(),vt_asset)
	await frames(4)
	check(reused.texture_set==vt_asset and vt_asset.get_runtime_stats().is_empty(),"Reusing an existing model for VT does not start a full RGBA8 decode")
	reused.texture_set=null; reused=null; vt_asset=null
	if int(data.width)>=512:
		for region in [Rect2(0,0,0.0625,0.0625),Rect2(0.3,0.3,0.0625,0.0625),Rect2(0.7,0.7,0.0625,0.0625),Rect2(-0.03,-0.03,0.0625,0.0625)]:
			vt.request_uv_rect(region,0)
			await frames(50)
		check(vt.get_runtime_stats().evictions>0,"Page cache evicts old detail pages")
		check(vt.get_runtime_stats().resident_pages<=16,"Page replacement respects capacity")
		var stable: int=vt.get_runtime_stats().dispatches
		await frames(20)
		check(vt.get_runtime_stats().dispatches==stable,"No background redecoding after page replacement")
		print("VT_STREAM_STATS: ",vt.get_runtime_stats())
	var root3d := Node3D.new()
	var unshaded := Shader.new()
	unshaded.code = VTMaterial.SHADER.code.replace("render_mode diffuse_burley, specular_schlick_ggx;","render_mode unshaded;")
	vt.shader = unshaded
	vt._update()
	root.add_child(root3d)
	var camera := Camera3D.new()
	root3d.add_child(camera)
	camera.position = Vector3(0,0,4)
	var mesh := MeshInstance3D.new()
	mesh.mesh = SphereMesh.new()
	mesh.material_override = vt
	root3d.add_child(mesh)
	var light := DirectionalLight3D.new()
	root3d.add_child(light)
	await frames(10)
	var screenshot := root.get_texture().get_image()
	screenshot.save_png("res://vt_runtime.png")
	check(not screenshot.is_empty(),"VT renders with spatial shader")
	var pixel := screenshot.get_pixel(screenshot.get_width()/2,screenshot.get_height()/2)
	print("VT_CENTER: ",pixel)
	check(pixel.b<0.95 and pixel.g>0.01,"VT samples the decoded color, not white fallback")
	# Compare the same GPU-decoded texels through ordinary and VT samplers, including a tile seam.
	var region := Rect2(0.3,0.3,0.03,0.03) if int(data.width)>=512 else Rect2(0,0,1,1)
	vt.set_shader_parameter("uv_scale",region.size)
	vt.set_shader_parameter("uv_offset",region.position)
	vt.request_uv_rect(region,0)
	await frames(40)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2.0
	var quad := QuadMesh.new(); quad.size=Vector2(2,2); mesh.mesh=quad
	await frames(10)
	var vt_image := root.get_texture().get_image()
	var ordinary := StandardMaterial3D.new()
	ordinary.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED
	ordinary.albedo_texture=textures.albedo
	ordinary.texture_filter=BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	ordinary.uv1_scale=Vector3(region.size.x,region.size.y,1)
	ordinary.uv1_offset=Vector3(region.position.x,region.position.y,0)
	mesh.material_override=ordinary
	await frames(10)
	var ordinary_image := root.get_texture().get_image()
	var sampling_metric := ordinary_image.compute_image_metrics(vt_image,false)
	print("VT_SAMPLING_PARITY: ",sampling_metric)
	check(sampling_metric.root_mean_squared<1.0,"VT page/gutter sampling agrees with ordinary texture within one 8-bit level RMS")
	# A returned texture may outlive its TextureSet. It must retain the GPU allocation.
	vt.texture_set=null; mat=null; textures.clear(); asset=null
	await frames(6)
	var retained := root.get_texture().get_image().compute_image_metrics(ordinary_image,false)
	check(retained.root_mean_squared<0.01,"Material texture retains GPU allocation after source asset release")
	root3d.queue_free()
	vt = null; ordinary = null
	await frames(5)
	print("RUNTIME_RESULT: %s (%d checks)" % ["PASS" if failures==0 else "FAIL",checks])
	quit(0 if failures==0 else 1)
