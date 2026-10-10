extends SceneTree
const Pass = preload("res://addons/feng-raytracing/passes/feng_rt_gi_pass.gd")
const Registry = preload("res://addons/feng-raytracing/scene/feng_rt_gi_world_snapshot.gd")
const Provider = preload("res://addons/feng-raytracing/rendering/rt_gi_gpu.gd")
const SceneGPU = preload("res://addons/feng-raytracing/rendering/rt_gi_scene_gpu.gd")
const ReflectionRenderer = preload("res://addons/feng-raytracing/rendering/rt_gi_reflections.gd")
var done := false
var passed := false
var snapshot: Dictionary

func quad_arrays(center_x: float, half_extent: float) -> Array:
	var points := [
		Vector3(center_x - half_extent, -half_extent, 0),
		Vector3(center_x + half_extent, -half_extent, 0),
		Vector3(center_x + half_extent, half_extent, 0),
		Vector3(center_x - half_extent, -half_extent, 0),
		Vector3(center_x + half_extent, half_extent, 0),
		Vector3(center_x - half_extent, half_extent, 0),
	]
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array(points)
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	for i in points.size():
		normals.append(Vector3.FORWARD)
		uvs.append(Vector2(float(i & 1), float((i >> 1) & 1)))
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	return arrays

func _initialize():
	call_deferred("run")
func run():
	var mesh := MeshInstance3D.new()
	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, quad_arrays(1000.0, 1.0))
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, quad_arrays(2000.0, 1.0))
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, quad_arrays(0.0, 50.0))
	mesh.mesh = array_mesh
	for i in 3:
		var surface_material := StandardMaterial3D.new()
		surface_material.cull_mode = BaseMaterial3D.CULL_DISABLED
		if i == 2:
			surface_material.emission_enabled = true
			surface_material.emission = Color(1,0.5,0.25)
			surface_material.emission_energy_multiplier = 2
		else:
			surface_material.albedo_color = Color(0.1 * (i + 1),0.2,0.3)
		mesh.mesh.surface_set_material(i, surface_material)
	root.add_child(mesh)
	mesh.position.z = 2
	var registry := Registry.new()
	registry.attach(root.world_3d, root, 1)
	var target := RenderingServer.viewport_get_render_target(root.get_viewport_rid())
	snapshot = registry.snapshot(target, [target])
	print("SNAPSHOT ",snapshot.get("valid")," ",snapshot.get("unsupported_reasons"))
	var third_material_ready: bool = snapshot.get("instances", []).size() == 1 \
			and snapshot.instances[0].mesh.materials.size() == 3 \
			and snapshot.instances[0].mesh.surfaces[2].material_index == 2
	print("RTGI_CASE material_row_stride_3 ", third_material_ready)
	RenderingServer.call_on_render_thread(execute)
	for i in 1800:
		await process_frame
		if done: break
	registry.detach()
	passed = passed and third_material_ready
	print("RTGI_GPU_TEST ",passed)
	quit(0 if passed else 1)
func execute():
	var rd := RenderingServer.get_rendering_device()
	var scene_owner = SceneGPU.new()
	if not scene_owner.initialize(rd):
		print("SCENE_OWNER_INITIALIZE_FAIL ",scene_owner.error)
		scene_owner.release()
		done = true
		return
	var gpu := Provider.new()
	gpu.scene = scene_owner
	if not gpu.initialize(rd,false):
		print("INITIALIZE_FAIL ",gpu.error)
		gpu.release()
		scene_owner.release()
		done = true
		return
	if not gpu.sync_scene(snapshot):
		print("SCENE_FAIL ",gpu.error)
		gpu.release()
		scene_owner.release()
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
		fmt.usage_bits=RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
		var tex := rd.texture_create(fmt,RDTextureView.new(),[PackedFloat32Array([color.r,color.g,color.b,color.a]).to_byte_array()])
		inputs.append(tex)
		owned.append(tex)
	var output_format := RDTextureFormat.new()
	output_format.width = 1
	output_format.height = 1
	output_format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	output_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	var output: RID = rd.texture_create(output_format, RDTextureView.new())
	if output.is_valid():
		rd.texture_clear(output, Color(0,0,0,0), 0, 1, 0, 1)
	owned.append(output)
	var dfg_image := Image.create(1,1,false,Image.FORMAT_RGBAH)
	dfg_image.set_pixel(0,0,Color(1,1,0,1))
	var dfg_format := RDTextureFormat.new()
	dfg_format.width = 1
	dfg_format.height = 1
	dfg_format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	dfg_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var dfg := rd.texture_create(dfg_format,RDTextureView.new(),[dfg_image.get_data()])
	owned.append(dfg)
	var frame := {"inverse_projection":Projection.IDENTITY,"camera_transform":Transform3D.IDENTITY,"pre_exposure":1.0,"scene_normalization":1.0}
	passed = true
	for case in [["emission",1.0,1.0,1.0,2.0,1.0],["pre_exposure",0.1,1.0,1.0,0.2,1.0],["normalization",2.0,0.25,1.0,1.0,1.0],["strength_half",1.0,1.0,0.5,1.0,0.5],["strength_two",1.0,1.0,2.0,4.0,1.0],["strength_zero",1.0,1.0,0.0,0.0,0.0]]:
		frame.pre_exposure=case[1]
		frame.scene_normalization=case[2]
		var bytes: PackedByteArray = pass_instance._pack_trace_frame(frame,Vector2i(1,1),1,0,case[3],{"samples_per_pixel":4})
		var success: bool = gpu.trace(inputs,bytes,{},output,dfg,Vector2i(1,1))
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
	var bytes: PackedByteArray = pass_instance._pack_trace_frame(frame,Vector2i(1,1),1,0,1.0,{"samples_per_pixel":4})
	gpu.trace(inputs,bytes,lighting,output,dfg,Vector2i(1,1))
	var sun_value := Image.create_from_data(1,1,false,Image.FORMAT_RGBAH,rd.texture_get_data(output,0)).get_pixel(0,0)
	var sun_ok := absf(sun_value.r-3.0)<0.02
	passed = passed and sun_ok
	print("RTGI_CASE secondary_sun_visibility ",sun_ok," ",sun_value)
	frame.directional_light_count=0
	snapshot.instances[0].mesh.materials[2].flags=0
	snapshot.snapshot_generation+=1
	gpu.sync_scene(snapshot)
	bytes=pass_instance._pack_trace_frame(frame,Vector2i(1,1),1,0,1.0,{"samples_per_pixel":4})
	gpu.trace(inputs,bytes,{},output,dfg,Vector2i(1,1))
	var front_value := Image.create_from_data(1,1,false,Image.FORMAT_RGBAH,rd.texture_get_data(output,0)).get_pixel(0,0)
	passed = passed and absf(front_value.r-2.0)<0.02
	print("RTGI_CASE frontface_emission ",absf(front_value.r-2.0)<0.02," ",front_value)
	frame.camera_transform=Transform3D(Basis(Vector3.UP,PI),Vector3(0,0,4))
	bytes=pass_instance._pack_trace_frame(frame,Vector2i(1,1),1,0,1.0,{"samples_per_pixel":4})
	gpu.trace(inputs,bytes,{},output,dfg,Vector2i(1,1))
	var back_value := Image.create_from_data(1,1,false,Image.FORMAT_RGBAH,rd.texture_get_data(output,0)).get_pixel(0,0)
	passed = passed and back_value.r < 0.01
	print("RTGI_CASE backface_rejected ",back_value.r < 0.01," ",back_value)
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
	bytes=pass_instance._pack_trace_frame(frame,Vector2i(1,1),1,0,1.0,{"samples_per_pixel":4})
	gpu.trace(inputs,bytes,{"sky_radiance_texture":sky},output,dfg,Vector2i(1,1))
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
	bytes=pass_instance._pack_trace_frame(frame,Vector2i(1,1),1,1,1.0,{"samples_per_pixel":4})
	array_ok = array_ok and gpu.trace(inputs,bytes,{"sky_radiance_texture":sky_array},output,dfg,Vector2i(1,1))
	var array_value := Image.create_from_data(1,1,false,Image.FORMAT_RGBAH,rd.texture_get_data(output,0)).get_pixel(0,0)
	array_ok = array_ok and absf(array_value.r-2.0)<0.02
	passed = passed and array_ok
	print("RTGI_CASE sky_array_base_layer ",array_ok," ",array_value)
	var reflection_backend := ReflectionRenderer.new()
	var reflection_ready := reflection_backend.initialize(rd, true)
	var shared_sbt_range := int(gpu.sbt_range) == int(reflection_backend.sbt_range)
	passed = passed and shared_sbt_range
	print("RTGI_CASE shared_scene_hit_sbt_range ", shared_sbt_range, " ", gpu.sbt_range, " ", reflection_backend.sbt_range)
	if not reflection_ready:
		print("RTGI_CASE sky_array_secondary_init_error ", reflection_backend.error)
	if reflection_ready:
		snapshot.instances[0].transform.origin = Vector3(0,0,2)
		snapshot.instances[0].mesh.materials[2].flags = 2
		snapshot.instances[0].mesh.materials[2].metallic = 1.0
		snapshot.instances[0].mesh.materials[2].roughness = 0.0
		snapshot.instances[0].mesh.materials[2].specular = 0.5
		snapshot.instances[0].mesh.materials[2].emission_enabled = false
		snapshot.snapshot_generation += 1
		reflection_ready = scene_owner.sync_scene(snapshot, reflection_backend.sbt_range)
	var reflection_layer0_ok := false
	var reflection_layer1_ok := false
	if reflection_ready:
		var material_model_opaque := 1.0 / 255.0
		var orm_bytes := PackedFloat32Array([1.0, 0.0, 1.0, material_model_opaque]).to_byte_array()
		reflection_ready = rd.texture_update(inputs[3], 0, orm_bytes) == OK
		var facing_normal_bytes := PackedFloat32Array([0.5,0.5,1.0,0.0]).to_byte_array()
		reflection_ready = reflection_ready and rd.texture_update(inputs[1], 0, facing_normal_bytes) == OK
		var emission_desc := RDTextureFormat.new()
		emission_desc.width = 1
		emission_desc.height = 1
		emission_desc.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
		emission_desc.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		var emission_tex := rd.texture_create(emission_desc, RDTextureView.new(),
				[PackedFloat32Array([0.0,0.0,0.0,0.5]).to_byte_array()])
		owned.append(emission_tex)
		var reflection_inputs: Array[RID] = [inputs[0], inputs[1], inputs[2], inputs[3], emission_tex]
		# With the identity inverse projection this sample is at +Z; keep the camera
		# at the origin so its reflected ray travels toward the z=2 secondary surface.
		frame.camera_transform = Transform3D.IDENTITY
		frame.sky_radiance_is_array = true
		frame.sky_max_roughness_lod = 1
		var reflection_frame: PackedByteArray = pass_instance._pack_trace_frame(frame, Vector2i.ONE, 2, 0, 1.0,
				{"samples_per_pixel": 1, "max_distance": 100.0})
		var first_layer_trace_ok := reflection_ready and reflection_backend.trace(scene_owner, reflection_inputs,
				reflection_frame, {"sky_radiance_texture": sky_array}, output, dfg, Vector2i.ONE)
		if not first_layer_trace_ok:
			print("RTGI_CASE sky_array_secondary_first_trace_error ", reflection_backend.error)
			reflection_ready = false
		if first_layer_trace_ok:
			var layer0_value := Image.create_from_data(1,1,false,Image.FORMAT_RGBAH,rd.texture_get_data(output,0)).get_pixel(0,0)
			reflection_layer0_ok = absf(layer0_value.r - 2.0) < 0.05 and layer0_value.a > 0.0
			print("RTGI_CASE sky_array_secondary_layer0 ", layer0_value)
			snapshot.instances[0].mesh.materials[2].roughness = 1.0
			snapshot.snapshot_generation += 1
			reflection_ready = scene_owner.sync_scene(snapshot, reflection_backend.sbt_range)
			reflection_frame = pass_instance._pack_trace_frame(frame, Vector2i.ONE, 3, 0, 1.0,
					{"samples_per_pixel": 1, "max_distance": 100.0})
			var second_layer_trace_ok := reflection_ready and reflection_backend.trace(scene_owner, reflection_inputs,
					reflection_frame, {"sky_radiance_texture": sky_array}, output, dfg, Vector2i.ONE)
			if not second_layer_trace_ok:
				print("RTGI_CASE sky_array_secondary_trace_error ", reflection_backend.error)
			reflection_ready = second_layer_trace_ok
		if reflection_ready:
			var layer1_value := Image.create_from_data(1,1,false,Image.FORMAT_RGBAH,rd.texture_get_data(output,0)).get_pixel(0,0)
			reflection_layer1_ok = absf(layer1_value.r - 50.0) < 0.5 and layer1_value.a > 0.0
			print("RTGI_CASE sky_array_secondary_layer1 ", layer1_value)
		else:
			print("RTGI_CASE sky_array_secondary_init_or_trace_error ", reflection_ready, " ", reflection_backend.error)
	passed = passed and reflection_layer0_ok and reflection_layer1_ok
	print("RTGI_CASE sky_array_secondary_roughness_layers ",reflection_layer0_ok,"/",reflection_layer1_ok)
	reflection_backend.release()
	if not pass_instance.ensure_diffuse_compute(rd):
		passed = false
	gpu.release()
	scene_owner.release()
	for rid in owned: rd.free_rid(rid)
	pass_instance._shared.reverse()
	for rid in pass_instance._shared: rd.free_rid(rid)
	pass_instance._shared.clear()
	done = true
