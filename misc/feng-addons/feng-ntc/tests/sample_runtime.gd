extends SceneTree
const TextureSet=preload("res://addons/feng-ntc/texture_set.gd")
const Neural=preload("res://addons/feng-ntc/neural_material.gd")
const SampleData=preload("res://addons/feng-ntc/sample_gpu_data.gd")
signal carrier_uploaded(rid: RID)
func _init() -> void: _run.call_deferred()
func frames(n: int) -> void:
	for i in range(n): await RenderingServer.frame_post_draw
func _run() -> void:
	root.size=Vector2i(128,128)
	if ClassDB.class_exists(&"FengNTCCodec"): push_error("Runtime test must not load CUDA SDK"); quit(1); return
	var asset: Resource=load("res://sample.ntc.res")
	var material:=Neural.new(); material.texture_set=asset
	material.set_shader_parameter("uv_scale",Vector2(0.0625,0.0625))
	material.set_shader_parameter("uv_offset",Vector2(0.25,0.25))
	material.set_shader_parameter("exact_texels",true)
	material.set_shader_parameter("trilinear",false)
	var scene:=Node3D.new(); root.add_child(scene)
	var environment:=WorldEnvironment.new(); environment.environment=Environment.new()
	environment.environment.background_mode=Environment.BG_COLOR
	environment.environment.background_color=Color.BLACK
	scene.add_child(environment)
	var cam:=Camera3D.new(); cam.projection=Camera3D.PROJECTION_ORTHOGONAL; cam.size=2.0
	cam.position=Vector3(0,0,2); scene.add_child(cam)
	var mesh:=MeshInstance3D.new(); var quad:=QuadMesh.new(); quad.size=Vector2(2,2)
	mesh.mesh=quad; mesh.material_override=material; scene.add_child(mesh)
	await frames(30)
	if not asset.get_runtime_stats().is_empty(): push_error("Production sampler started a full decode"); quit(1); return
	if ResourceSaver.save(asset,"res://runtime_model.res",ResourceSaver.FLAG_COMPRESS)!=OK: quit(1); return
	asset.take_over_path("res://runtime_model.res")
	if ResourceSaver.save(material,"res://runtime_material.tres")!=OK: quit(1); return
	var saved:=FileAccess.get_file_as_string("res://runtime_material.tres")
	if "Texture2DRD" in saved or "Texture2DArrayRD" in saved: push_error("GPU resources serialized"); quit(1); return
	for line: String in saved.split("\n"):
		if line.begins_with("shader_parameter/ntc_network = ") and line!="shader_parameter/ntc_network = PackedVector4Array()":
			push_error("Runtime network/default array serialized"); quit(1); return
	var shader:=Shader.new(); shader.code=material.shader.code.replace("render_mode diffuse_burley, specular_schlick_ggx;","render_mode unshaded;")
	material.shader=shader
	material._update()
	if not material.ntc_error.is_empty() or not material._session.ready:
		push_error(material.ntc_error); quit(1); return
	await frames(10)
	var actual:=root.get_texture().get_image(); actual.save_png("res://sample_direct.png")
	print("SAMPLE_STATS: ",material.get_runtime_stats())
	if not await _check_carriers(material,actual): quit(1); return
	# Comparing the two paths at texel centers isolates the actual neural decoder.
	var images: Dictionary=await asset.prepare_async()
	var reference:=StandardMaterial3D.new(); reference.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED
	reference.albedo_texture=images.albedo; reference.texture_filter=BaseMaterial3D.TEXTURE_FILTER_NEAREST
	reference.uv1_scale=Vector3(0.0625,0.0625,1); reference.uv1_offset=Vector3(0.25,0.25,0)
	mesh.material_override=reference; await frames(10)
	var expected:=root.get_texture().get_image(); expected.save_png("res://sample_reference.png")
	var metric:=expected.compute_image_metrics(actual,false)
	print("SAMPLE_PARITY: ",metric)
	var good: bool=metric.root_mean_squared<1.0
	if material.get_runtime_stats().gpu_compressed_bytes!=SampleData.footprint(asset.package).total_bytes: good=false
	var bc_bytes := 0
	for mip in range(int(asset.package.mips)):
		bc_bytes+=ceili(maxi(1,int(asset.package.width)>>mip)/4.0)*ceili(maxi(1,int(asset.package.height)>>mip)/4.0)*24
	if material.get_runtime_stats().gpu_compressed_bytes>=bc_bytes/4: good=false
	for region in [Rect2(0.2,0.2,0.25,0.25),Rect2(-0.03,-0.03,0.0625,0.0625)]:
		material.set_shader_parameter("uv_scale",region.size); material.set_shader_parameter("uv_offset",region.position)
		reference.uv1_scale=Vector3(region.size.x,region.size.y,1); reference.uv1_offset=Vector3(region.position.x,region.position.y,0)
		reference.texture_filter=BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
		mesh.material_override=reference; await frames(3)
		expected=root.get_texture().get_image()
		mesh.material_override=material; material._update(); await frames(3)
		actual=root.get_texture().get_image()
		metric=expected.compute_image_metrics(actual,false)
		print("SAMPLE_MIP_WRAP_PARITY: ",region," ",metric)
		if metric.root_mean_squared>=1.0: good=false
	mesh.material_override=null; material.texture_set=null; material=null; images.clear(); reference=null; asset=null
	scene.queue_free(); await frames(5)
	print("SAMPLE_RUNTIME_", "PASS" if good else "FAIL")
	quit(0 if good else 1)

func _check_carriers(material: ShaderMaterial,expected: Image) -> bool:
	# Exercise the low-uniform-limit texture fallback and the exact wide carrier,
	# even though the test model normally selects narrow uniform weights.
	var data: Dictionary=material.texture_set.package
	var encoding:=SampleData.encode_tensor(data)
	var original: Shader=material.shader
	for spec in [[false,false],[true,false],[true,true]]:
		var wide: bool=spec[0]; var uniform_tensor: bool=spec[1]
		var bytes: PackedByteArray=encoding.bytes
		if wide and not encoding.wide:
			var floats:=PackedFloat32Array()
			for i in range(0,bytes.size(),4):
				var word: int=bytes.decode_u32(i)^int(encoding.mask[(i/4)%4])
				floats.append(word&65535); floats.append(word>>16)
			bytes=floats.to_byte_array()
		elif not wide and encoding.wide: continue
		var shader:=Shader.new()
		shader.code=Neural._specialized_shader(data,wide,uniform_tensor).code.replace("render_mode diffuse_burley, specular_schlick_ggx;","render_mode unshaded;")
		material.shader=shader
		var rid:=RID(); var texture: Texture2DRD
		if uniform_tensor:
			var floats:=bytes.to_float32_array(); var values:=PackedVector4Array()
			for i in range(0,floats.size(),4): values.append(Vector4(floats[i],floats[i+1],floats[i+2],floats[i+3]))
			material._runtime_parameter("ntc_network",values)
		else:
			rid=await _upload_carrier(bytes)
			texture=Texture2DRD.new(); texture.texture_rd_rid=rid
			material._runtime_parameter("ntc_tensor",texture.get_rid())
		await frames(5)
		var metric:=expected.compute_image_metrics(root.get_texture().get_image(),false)
		print("SAMPLE_CARRIER_PARITY wide=",wide," uniform=",uniform_tensor,": ",metric)
		material.shader=original; material._update()
		material._runtime_parameter("ntc_tensor",null)
		texture=null; await frames(3)
		if rid.is_valid(): RenderingServer.call_on_render_thread(func(): RenderingServer.get_rendering_device().free_rid(rid))
		if metric.root_mean_squared>0.01: return false
	return true

func _upload_carrier(bytes: PackedByteArray) -> RID:
	RenderingServer.call_on_render_thread(func():
		var format:=RDTextureFormat.new()
		format.width=64; format.height=bytes.size()/1024
		format.format=RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
		format.usage_bits=RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		var rid:=RenderingServer.get_rendering_device().texture_create(format,RDTextureView.new(),[bytes])
		carrier_uploaded.emit.call_deferred(rid))
	return await carrier_uploaded
