extends SceneTree
const Pass = preload("res://addons/feng-raytracing/passes/feng_rt_gi_pass.gd")
const Renderer = preload("res://addons/feng-render-pipeline/renderer.gd")
const Composition = preload("res://addons/feng-render-pipeline/compositor.gd")
const Worlds = preload("res://addons/feng-render-pipeline/passes/snapshot_worlds.gd")
const Spec = preload("res://addons/feng-render-pipeline/pipeline/native_spec.gd")
var gi: FengRTGIPass
var renderer: FengRenderer
var compositor: FengCompositor
func _initialize(): call_deferred("run")
func box(position: Vector3, size: Vector3, material: Material):
	var mesh := MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	mesh.mesh.size = size
	mesh.material_override = material
	root.add_child(mesh)
	mesh.position = position
	return mesh
func run():
	root.size=Vector2i(640,480)
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(),true)
	var matte := StandardMaterial3D.new()
	matte.albedo_color=Color(0.8,0.8,0.8)
	matte.cull_mode=BaseMaterial3D.CULL_DISABLED
	box(Vector3(0,-0.1,0),Vector3(6,0.2,6),matte)
	box(Vector3(0,1,-2),Vector3(6,2,0.2),matte)
	var emissive := StandardMaterial3D.new()
	emissive.emission_enabled=true
	emissive.emission=Color(1,0.2,0.05)
	emissive.emission_energy_multiplier=5.0
	box(Vector3(-1,0.8,0),Vector3(0.8,0.8,0.8),emissive)
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.position=Vector3(0,3,6)
	camera.look_at(Vector3(0,0.5,0))
	camera.current=true
	var environment := WorldEnvironment.new()
	environment.environment=Environment.new()
	environment.environment.background_mode=Environment.BG_COLOR
	environment.environment.background_color=Color(0,0,0)
	root.add_child(environment)
	renderer=Renderer.new()
	var passes: Array[FengPass]=[]
	gi=Pass.new()
	gi.stable_id=&"test:rtgi"
	gi.samples_per_pixel=4
	for native_id in Spec.seed_order():
		passes.append(renderer._make_native_pass(native_id))
		if native_id == Spec.PASS_LIGHTING: passes.append(gi)
	renderer.passes=passes
	for entry in renderer.LibraryManager.DEFAULT_LIBRARY_ENTRIES:
		renderer._deleted_library_ids.append(entry.id)
	compositor=Composition.new()
	compositor.renderer=renderer
	environment.compositor=compositor
	Worlds.scan(root,self)
	for i in 80: await process_frame
	var on_gpu:=0.0
	var on_cpu:=0.0
	for i in 30:
		await process_frame
		on_gpu+=RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid())
		on_cpu+=RenderingServer.viewport_get_measured_render_time_cpu(root.get_viewport_rid())
	print("STATES ",gi._states.size()," REQUESTS ",gi.Runtime._requests," SNAPSHOTS ",gi.Runtime._published_by_target.keys()," WARNINGS ", renderer._last_validation_warnings)
	var image := root.get_texture().get_image()
	image.save_png("user://rtgi_on.png")
	var on_value := image.get_pixel(270,270).r
	gi.enabled=false
	for i in 20: await process_frame
	var off_gpu:=0.0
	var off_cpu:=0.0
	for i in 30:
		await process_frame
		off_gpu+=RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid())
		off_cpu+=RenderingServer.viewport_get_measured_render_time_cpu(root.get_viewport_rid())
	print("TIMING_MS ON CPU=",on_cpu/30.0," GPU=",on_gpu/30.0," OFF CPU=",off_cpu/30.0," GPU=",off_gpu/30.0)
	image=root.get_texture().get_image()
	image.save_png("user://rtgi_off.png")
	var off_value := image.get_pixel(270,270).r
	print("RTGI_SCENE ON=",on_value," OFF=",off_value," STATES=",gi._states.size())
	var success := on_value > 0.05 and off_value < 0.01
	Worlds.unregister_owner(self)
	environment.compositor=null
	compositor.renderer=null
	compositor=null
	renderer=null
	gi=null
	for i in 5: await process_frame
	quit(0 if success else 1)
