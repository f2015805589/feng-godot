extends SceneTree

var checks: Array = []
var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(name: String, success: bool, detail: Variant = null) -> void:
	checks.append({"name": name, "pass": success, "detail": detail})
	if not success:
		failures += 1
	print("NATIVE_V3 ", name, " ", success, " ", detail)

func _plane(rotation := Basis.IDENTITY) -> Dictionary:
	var vertices := PackedVector3Array([Vector3(-1,0,-1),Vector3(-1,0,1),Vector3(1,0,-1)])
	var normals := PackedVector3Array()
	for i in vertices.size():
		vertices[i] = rotation * vertices[i]
		normals.append(rotation * Vector3.UP)
	return {"vertices":vertices,"normals":normals,"uv2":PackedVector2Array([Vector2(0,0),Vector2(0,1),Vector2(1,0)]),"albedo":PackedColorArray([Color(0.5,0.5,0.5)]),"emission":PackedColorArray([Color.BLACK]),"material_flags":PackedByteArray([0]),"mesh_ids":PackedInt32Array([0]),"roughness":PackedFloat32Array([1]),"metallic":PackedFloat32Array([0]),"specular":PackedFloat32Array([0]),"diffuse_modes":PackedByteArray([0]),"environment_radiance":Color.BLACK}

func _options(samples := 8192, workers := 1) -> Dictionary:
	return {"mesh_count":1,"resolution":4,"samples_per_texel":samples,"seed":81561,"worker_count":workers}

func _bake(scene: Dictionary, samples := 8192, workers := 1) -> Dictionary:
	var integrator = ClassDB.instantiate("FengLightmapMCIntegrator")
	return integrator.bake_scene_atlases(scene, _options(samples,workers))

func _mean(result: Dictionary) -> float:
	if not result.get("ok",false):
		return -INF
	var layer: Dictionary = result.layers[0]
	var sum := 0.0
	var count := 0
	for i in layer.coverage.size():
		if layer.coverage[i] != 0:
			sum += layer.rgba[i*4]
			count += 1
	return sum / maxi(count,1)

func _add_quad(scene: Dictionary, a: Vector3, b: Vector3, c: Vector3, d: Vector3, receiver := false) -> void:
	var vs := [a,b,c,a,c,d]
	var uv := [Vector2(0,0),Vector2(0,1),Vector2(1,1),Vector2(0,0),Vector2(1,1),Vector2(1,0)]
	var normal: Vector3 = (b-a).cross(c-a).normalized()
	for i in 6:
		scene.vertices.append(vs[i])
		scene.normals.append(normal)
		scene.uv2.append(uv[i] if receiver else Vector2.ZERO)
	for i in 2:
		scene.albedo.append(Color(0.5,0.5,0.5))
		scene.emission.append(Color(0.5,0.5,0.5))
		scene.material_flags.append(0)
		scene.mesh_ids.append(0 if receiver else -1)
		scene.roughness.append(1.0)
		scene.metallic.append(0.0)
		scene.specular.append(0.0)
		scene.diffuse_modes.append(0)

func _cavity() -> Dictionary:
	var s := _plane()
	for key in ["vertices","normals","uv2","albedo","emission","material_flags","mesh_ids","roughness","metallic","specular","diffuse_modes"]:
		s[key].clear()
	_add_quad(s,Vector3(-1,-1,-1),Vector3(-1,-1,1),Vector3(1,-1,1),Vector3(1,-1,-1),true)
	_add_quad(s,Vector3(-1,1,-1),Vector3(1,1,-1),Vector3(1,1,1),Vector3(-1,1,1))
	_add_quad(s,Vector3(-1,-1,-1),Vector3(1,-1,-1),Vector3(1,1,-1),Vector3(-1,1,-1))
	_add_quad(s,Vector3(-1,-1,1),Vector3(-1,1,1),Vector3(1,1,1),Vector3(1,-1,1))
	_add_quad(s,Vector3(-1,-1,-1),Vector3(-1,1,-1),Vector3(-1,1,1),Vector3(-1,-1,1))
	_add_quad(s,Vector3(1,-1,-1),Vector3(1,-1,1),Vector3(1,1,1),Vector3(1,1,-1))
	return s

func _run() -> void:
	_check("backend_present",ClassDB.class_exists("FengLightmapMCIntegrator"))
	if failures:
		quit(1)
		return
	var backend = ClassDB.instantiate("FengLightmapMCIntegrator")
	_check("contract_v4",backend.get_backend_contract_version()==4)
	var s := _plane()
	s.environment_radiance = Color(100000,20000,3000)
	var r := _bake(s,64)
	_check("hdr_no_clamp",r.get("ok",false) and absf(_mean(r)-100000)<0.001,_mean(r))
	var v2: Dictionary = backend.bake_atlases(s.vertices,s.uv2,s.albedo,s.emission,s.material_flags,s.mesh_ids,1,4,64,81561,Color(1,1,1))
	_check("v2_compatibility",v2.get("ok",false) and absf(_mean(v2)-1.0)<1e-6,_mean(v2))
	s.environment_radiance=Color.BLACK
	s.directional_lights=[{"direction_to_light":Vector3.UP,"radiance":Color(PI,PI,PI),"direct_enabled":true,"indirect_energy":1.0}]
	r=_bake(s,64)
	_check("static_directional_exact",r.get("ok",false) and absf(_mean(r)-1)<1e-6,_mean(r))
	s.directional_lights[0].direct_enabled=false
	r=_bake(s,64)
	_check("dynamic_excludes_primary",r.get("ok",false) and _mean(r)==0,_mean(r))
	s.directional_lights[0].angular_distance=0.1
	r=_bake(s,64)
	_check("finite_dynamic_excludes_primary",r.get("ok",false) and _mean(r)==0,_mean(r))
	s.directional_lights[0].direct_enabled=true
	s.directional_lights[0].angular_distance=0.5
	r=_bake(s,512)
	_check("solar_disk_perpendicular_illuminance",r.get("ok",false) and absf(_mean(r)-1)<0.00001,_mean(r))
	s.directional_lights[0].angular_distance=90.0
	r=_bake(s,32768)
	_check("large_disk_perpendicular_illuminance",r.get("ok",false) and absf(_mean(r)-1)<0.003,_mean(r))
	s.directional_lights[0].direction_to_light=Vector3(0.5,sqrt(0.75),0)
	s.directional_lights[0].angular_distance=20.0
	r=_bake(s,16384)
	_check("tilted_finite_disk_integral",r.get("ok",false) and absf(_mean(r)-sqrt(0.75))<0.003,_mean(r))
	s.directional_lights[0].angular_distance=180.0
	r=_bake(s,64)
	_check("reject_invalid_angular_light",not r.get("ok",false),r.get("error"))
	s=_plane()
	for i in s.vertices.size():
		s.vertices[i]*=0.00001
	s.directional_lights=[{"direction_to_light":Vector3.UP,"radiance":Color(PI,PI,PI),"angular_distance":10.0,"direct_enabled":true}]
	# A black half-plane covers exactly half the finite sun at this receiver.
	# The center (delta) ray alone cannot represent this penumbra.
	_add_quad(s,Vector3(0,0.5,-4),Vector3(4,0.5,-4),Vector3(4,0.5,4),Vector3(0,0.5,4))
	for i in range(1,s.albedo.size()):
		s.albedo[i]=Color.BLACK
		s.emission[i]=Color.BLACK
	r=_bake(s,32768)
	_check("finite_sun_half_occluded_penumbra",r.get("ok",false) and absf(_mean(r)-0.5)<0.006,_mean(r))
	s=_plane()
	s.material_flags[0]=2
	r=_bake(s,1)
	_check("reject_back_emitter_without_back_geometry",not r.get("ok",false),r.get("error"))
	s=_plane()
	s.specular[0]=0.5
	s.roughness[0]=0.0
	r=_bake(s,1)
	_check("reject_delta_mirror",not r.get("ok",false),r.get("error"))
	s=_plane()
	s.environment_width=4
	s.environment_height=2
	s.environment_pixels=PackedColorArray([Color(4,4,4),Color.BLACK,Color.BLACK,Color.BLACK,Color.BLACK,Color.BLACK,Color.BLACK,Color.BLACK])
	r=_bake(s)
	_check("panorama_quarter_integral",r.get("ok",false) and absf(_mean(r)-1)<0.012,_mean(r))
	var r4 := _bake(s,8192,4)
	_check("thread_count_bit_identical",r.get("ok",false) and r4.get("ok",false) and r.layers[0].rgba==r4.layers[0].rgba and r.layers[0].variance==r4.layers[0].variance and r.bounce_count==r4.bounce_count)
	s=_plane(Basis(Vector3.RIGHT,-PI/2))
	s.environment_width=4
	s.environment_height=2
	s.environment_pixels=PackedColorArray([Color(2,2,2),Color.BLACK,Color.BLACK,Color(2,2,2),Color(2,2,2),Color.BLACK,Color.BLACK,Color(2,2,2)])
	r=_bake(s)
	_check("godot_panorama_negative_z",r.get("ok",false) and absf(_mean(r)-2)<0.015,_mean(r))
	s.environment_transform=Basis(Vector3.UP,PI)
	r=_bake(s)
	_check("panorama_rotation",r.get("ok",false) and absf(_mean(r))<1e-6,_mean(r))
	s=_plane()
	for i in s.vertices.size():
		s.vertices[i] *= 0.0001
	s.area_lights=[{"center":Vector3(0,1,0),"axis_u":Vector3(2,0,0),"axis_v":Vector3(0,0,2),"normal":Vector3.DOWN,"radiance":Color.WHITE,"range":4.0,"attenuation":2.0,"direct_enabled":true,"indirect_energy":1.0}]
	r=_bake(s,32768,1)
	var expected_rect := (4.0/PI/sqrt(2.0)*atan(1.0/sqrt(2.0))) * pow(1.0-pow(1.0/4.0,4.0),2.0)
	_check("analytic_rectangle_form_factor",r.get("ok",false) and absf(_mean(r)-expected_rect)<0.004,{"mean":_mean(r),"expected":expected_rect})
	s.area_lights[0].direct_enabled=false
	r=_bake(s,128)
	_check("dynamic_area_excludes_primary",r.get("ok",false) and _mean(r)==0,_mean(r))
	s.area_lights[0].direct_enabled=true
	s.area_lights[0].normal=Vector3.UP
	r=_bake(s,128)
	_check("area_backside_zero",r.get("ok",false) and _mean(r)==0,_mean(r))
	s.area_lights[0].normal=Vector3.DOWN
	_add_quad(s,Vector3(-4,0.5,-4),Vector3(4,0.5,-4),Vector3(4,0.5,4),Vector3(-4,0.5,4))
	for i in range(1,s.albedo.size()):
		s.albedo[i]=Color.BLACK
		s.emission[i]=Color.BLACK
	r=_bake(s,1024)
	_check("area_full_geometry_occlusion",r.get("ok",false) and _mean(r)==0,_mean(r))
	s=_cavity()
	r=_bake(s,16384,4)
	_check("closed_emissive_cavity_infinite_bounce",r.get("ok",false) and absf(_mean(r)-1)<0.012,{"mean":_mean(r),"bounces":r.get("average_path_bounces"),"rr":r.get("rr_survivals")})
	_check("roulette_exercised",r.get("rr_survivals",0)>1000)
	backend=ClassDB.instantiate("FengLightmapMCIntegrator")
	backend.request_cancel()
	r=backend.bake_scene_atlases(_plane(),_options())
	_check("preentry_cancel_sticky",r.get("cancelled",false) and not r.has("layers"))
	backend=ClassDB.instantiate("FengLightmapMCIntegrator")
	s=_plane()
	s.environment_radiance=Color.WHITE
	var thread := Thread.new()
	thread.start(backend.bake_scene_atlases.bind(s,_options(100000000,4)))
	OS.delay_msec(20)
	var cancel_start := Time.get_ticks_msec()
	backend.request_cancel()
	r=thread.wait_to_finish()
	var cancel_ms := Time.get_ticks_msec()-cancel_start
	_check("running_cancel_no_partial",r.get("cancelled",false) and not r.has("layers") and cancel_ms<1000,cancel_ms)
	var report := {"pass":failures==0,"failed":failures,"checks":checks}
	var f := FileAccess.open("F:/godot/feng-godot/Temp/lightmap_native_20261022/native_regression.json",FileAccess.WRITE)
	f.store_string(JSON.stringify(report,"  "))
	f.close()
	quit(1 if failures else 0)
