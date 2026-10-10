extends SceneTree
const Pass = preload("res://addons/feng-raytracing/passes/feng_rt_gi_pass.gd")
const Registry = preload("res://addons/feng-raytracing/scene/feng_rt_gi_world_snapshot.gd")
const Provider = preload("res://addons/feng-raytracing/rendering/rt_gi_gpu.gd")
var done := false
var passed := false
var snapshot: Dictionary
func _initialize():
	call_deferred("run")
func run():
	var mesh := MeshInstance3D.new()
	mesh.mesh = QuadMesh.new()
	mesh.mesh.size = Vector2(100,100)
	var material := StandardMaterial3D.new()
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.emission_enabled = true
	material.emission = Color(1,0.5,0.25)
	material.emission_energy_multiplier = 2
	mesh.material_override = material
	root.add_child(mesh)
	mesh.position.z = 2
	var registry := Registry.new()
	registry.attach(root.world_3d, root, 1)
	var target := RenderingServer.viewport_get_render_target(root.get_viewport_rid())
	snapshot = registry.snapshot(target, [target])
	print("SNAPSHOT ",snapshot.get("valid")," ",snapshot.get("unsupported_reasons"))
	RenderingServer.call_on_render_thread(execute)
	for i in 1800:
		await process_frame
		if done: break
	registry.detach()
	print("RTGI_GPU_TEST ",passed)
	quit(0 if passed else 1)
func execute():
	var rd := RenderingServer.get_rendering_device()
	var gpu := Provider.new()
	if not gpu.initialize(rd,false):
		print("INITIALIZE_FAIL ",gpu.error)
		gpu.release()
		done = true
		return
	if not gpu.sync_scene(snapshot):
		print("SCENE_FAIL ",gpu.error)
		gpu.release()
		done = true
		return
	var pass_instance := Pass.new()
	var owned: Array[RID] = []
	var inputs: Array[RID] = []
	for color in [Color(0.5,0,0,0),Color(0.5,0.5,1,0),Color(1,1,1,1),Color(1,0.5,0,1.0/255.0)]:
		var fmt := RDTextureFormat.new()
		fmt.width=1
		fmt.height=1
		fmt.format=RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
		fmt.usage_bits=RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		var tex := rd.texture_create(fmt,RDTextureView.new(),[PackedFloat32Array([color.r,color.g,color.b,color.a]).to_byte_array()])
		inputs.append(tex)
		owned.append(tex)
	var output := pass_instance.texture(rd,Vector2i(1,1),RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
	owned.append(output)
	var frame := {"inverse_projection":Projection.IDENTITY,"camera_transform":Transform3D.IDENTITY,"pre_exposure":1.0,"scene_normalization":1.0}
	passed = true
	for case in [["emission",1.0,1.0,1.0,2.0,1.0],["pre_exposure",0.1,1.0,1.0,0.2,1.0],["normalization",2.0,0.25,1.0,1.0,1.0],["strength_half",1.0,1.0,0.5,1.0,0.5],["strength_two",1.0,1.0,2.0,4.0,1.0],["strength_zero",1.0,1.0,0.0,0.0,0.0]]:
		frame.pre_exposure=case[1]
		frame.scene_normalization=case[2]
		var bytes := pass_instance.pack_frame(frame,Vector2i(1,1),1,0,case[3],{"samples_per_pixel":4})
		var success := gpu.trace(inputs,bytes,{},output,Vector2i(1,1))
		var value := Image.create_from_data(1,1,false,Image.FORMAT_RGBAH,rd.texture_get_data(output,0)).get_pixel(0,0)
		success = success and absf(value.r-case[4]) < 0.01 and absf(value.a-case[5]) < 0.01
		passed = passed and success
		print("RTGI_CASE ",case[0]," ",success," ",value)
	var lights := PackedByteArray()
	lights.resize(464*8)
	lights.encode_float(8,-1.0)
	lights.encode_float(12,PI)
	for offset in [16,20,24]: lights.encode_float(offset,1.0)
	lights.encode_u32(36,0xffffffff)
	var light_buffer := rd.uniform_buffer_create(lights.size(),lights)
	owned.append(light_buffer)
	frame.pre_exposure=1.0
	frame.scene_normalization=1.0
	frame.directional_light_count=1
	var lighting := {"directional_light_buffer":light_buffer}
	var bytes := pass_instance.pack_frame(frame,Vector2i(1,1),1,0,1.0,{"samples_per_pixel":4})
	gpu.trace(inputs,bytes,lighting,output,Vector2i(1,1))
	var sun_value := Image.create_from_data(1,1,false,Image.FORMAT_RGBAH,rd.texture_get_data(output,0)).get_pixel(0,0)
	var sun_ok := absf(sun_value.r-3.0)<0.02
	passed = passed and sun_ok
	print("RTGI_CASE secondary_sun_visibility ",sun_ok," ",sun_value)
	frame.directional_light_count=0
	snapshot.instances[0].mesh.materials[0].flags=0
	snapshot.snapshot_generation+=1
	gpu.sync_scene(snapshot)
	bytes=pass_instance.pack_frame(frame,Vector2i(1,1),1,0,1.0,{"samples_per_pixel":4})
	gpu.trace(inputs,bytes,{},output,Vector2i(1,1))
	var back_value := Image.create_from_data(1,1,false,Image.FORMAT_RGBAH,rd.texture_get_data(output,0)).get_pixel(0,0)
	passed = passed and back_value.r < 0.01
	print("RTGI_CASE backface_rejected ",back_value.r < 0.01," ",back_value)
	frame.camera_transform=Transform3D(Basis(Vector3.UP,PI),Vector3(0,0,4))
	bytes=pass_instance.pack_frame(frame,Vector2i(1,1),1,0,1.0,{"samples_per_pixel":4})
	gpu.trace(inputs,bytes,{},output,Vector2i(1,1))
	var front_value := Image.create_from_data(1,1,false,Image.FORMAT_RGBAH,rd.texture_get_data(output,0)).get_pixel(0,0)
	passed = passed and absf(front_value.r-2.0)<0.02
	print("RTGI_CASE frontface_emission ",absf(front_value.r-2.0)<0.02," ",front_value)
	frame.camera_transform=Transform3D.IDENTITY
	snapshot.instances[0].transform.origin=Vector3(1000,0,2)
	gpu.sync_scene(snapshot)
	var sky_desc := RDTextureFormat.new()
	sky_desc.width=1
	sky_desc.height=1
	sky_desc.format=RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	sky_desc.usage_bits=RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var sky := rd.texture_create(sky_desc,RDTextureView.new(),[PackedFloat32Array([4,4,4,1]).to_byte_array()])
	owned.append(sky)
	frame.sky_light_energy=2.0
	frame.sky_captured_exposure=4.0
	bytes=pass_instance.pack_frame(frame,Vector2i(1,1),1,0,1.0,{"samples_per_pixel":4})
	gpu.trace(inputs,bytes,{"sky_radiance_texture":sky},output,Vector2i(1,1))
	var sky_value := Image.create_from_data(1,1,false,Image.FORMAT_RGBAH,rd.texture_get_data(output,0)).get_pixel(0,0)
	var sky_ok := absf(sky_value.r-2.0)<0.02
	passed = passed and sky_ok
	print("RTGI_CASE sky_capture_exposure ",sky_ok," ",sky_value)

	var array_ok := gpu.initialize(rd,true) and gpu.sync_scene(snapshot)
	sky_desc.texture_type=RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	sky_desc.array_layers=2
	var sky_array := rd.texture_create(sky_desc,RDTextureView.new(),[PackedFloat32Array([4,4,4,1]).to_byte_array(),PackedFloat32Array([100,100,100,1]).to_byte_array()])
	owned.append(sky_array)
	frame.sky_radiance_is_array=true
	bytes=pass_instance.pack_frame(frame,Vector2i(1,1),1,1,1.0,{"samples_per_pixel":4})
	array_ok = array_ok and gpu.trace(inputs,bytes,{"sky_radiance_texture":sky_array},output,Vector2i(1,1))
	var array_value := Image.create_from_data(1,1,false,Image.FORMAT_RGBAH,rd.texture_get_data(output,0)).get_pixel(0,0)
	array_ok = array_ok and absf(array_value.r-2.0)<0.02
	passed = passed and array_ok
	print("RTGI_CASE sky_array_base_layer ",array_ok," ",array_value)
	if not pass_instance.ensure_compute(rd):
		passed = false
	gpu.release()
	for rid in owned: rd.free_rid(rid)
	pass_instance._shared.reverse()
	for rid in pass_instance._shared: rd.free_rid(rid)
	pass_instance._shared.clear()
	done = true
