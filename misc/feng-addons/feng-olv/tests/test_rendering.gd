extends SceneTree
const Pipeline = preload("res://addons/feng-render-pipeline/project_pipeline.gd")
const Controller = preload("res://addons/feng-olv/feng_olv_volume.gd")
const OUT := "res://.godot/feng-olv-tests/"
var magic: Resource
var controller: FOLVVolume
var results := {}
func _initialize() -> void:call_deferred("_run")
func _frames(count: int) -> void:
	for i in count:await process_frame
func _capture(label: String) -> Dictionary:
	await _frames(120)
	var image := root.get_texture().get_image()
	image.save_png(OUT+label+".png")
	var counts := {"indoor":0,"outdoor":0}
	for y in image.get_height():
		for x in image.get_width():
			var pixel := image.get_pixel(x,y)
			if pixel.g>.55 and pixel.b>.55 and pixel.r<.6:counts.indoor+=1
			if pixel.r>.65 and pixel.g>.5 and pixel.b<.65:counts.outdoor+=1
	var state: Dictionary = magic.call("get_magicdawn_runtime_state")
	results[label]={"pixels":counts,"active":state.get("renderer_path_active",false),"dynamic_volume":state.get("dynamic_volume",{})}
	print("OLV_GPU_STATE ",label," ",JSON.stringify(results[label]))
	return results[label]
func _run() -> void:
	DisplayServer.window_set_size(Vector2i(960,720));root.size=Vector2i(960,720)
	var scene := (load("res://box_test.tscn") as PackedScene).instantiate()
	root.add_child(scene);current_scene=scene
	await process_frame
	var volume: Node = scene.get_node("MagicGIVolume")
	var original: Resource = volume.get("bake_manifest")
	var existing: Node = volume.call("get_olv_controller")
	if existing != null: volume.remove_child(existing);existing.free()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	controller=Controller.new();controller.name="OLV";controller.data_path="res://.godot/olv-gpu-test/domains.res"
	volume.add_child(controller)
	assert(controller.import_existing_labels())
	var compositor := Pipeline.resolve()
	for value in compositor.renderer.passes:
		if String(value.stable_id)=="library:magic_gi":magic=value
		if String(value.stable_id)=="library:debug_buffers":
			value.set("enabled",true);value.set("buffer",6);value.set("gi_exposure",0.)
	magic.set("enabled",true);magic.set("clv_debug_view",6)
	var camera := scene.get_node("Camera3D") as Camera3D
	camera.cull_mask=1<<19
	var baseline := await _capture("olv_on")
	assert(baseline.active and baseline.pixels.indoor>1000)
	var source := controller.get_probe_source()
	var target: Vector3 = scene.get_node("Room/Sphere").global_position + Vector3(.185,.76,.22)
	var nearest := -1;var distance := INF
	for index in source.probe_count:
		if source.cell_is_valid(index):
			var d: float = source.cell_position(index).distance_squared_to(target)
			if d<distance:distance=d;nearest=index
	controller.select_probe(nearest)
	assert(controller.set_probe_overrides(controller.overrides_for_selection(1)))
	var edited := await _capture("olv_manual_outdoor")
	assert(edited.pixels.outdoor>baseline.pixels.outdoor)
	assert(controller.set_probe_overrides({}))
	var undone := await _capture("olv_undo")
	assert(undone.pixels==baseline.pixels)
	controller.enabled=false
	var off := await _capture("olv_off")
	assert(off.active and not bool(off.dynamic_volume.get("cache",{}).get("olv_enabled",true)))
	controller.enabled=true
	var on := await _capture("olv_reenabled")
	assert(on.active and bool(on.dynamic_volume.get("cache",{}).get("olv_enabled",false)))
	assert(on.pixels==baseline.pixels)
	assert(volume.get("bake_manifest")==original)
	var file:=FileAccess.open(OUT+"gpu_report.json",FileAccess.WRITE)
	file.store_string(JSON.stringify({"ok":true,"results":results,"gi_manifest_unchanged":true},"\t"));file.close()
	print("OLV_GPU_INDEPENDENT_PASS")
	scene.queue_free();await process_frame;quit()
