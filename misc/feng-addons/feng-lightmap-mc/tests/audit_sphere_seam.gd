extends SceneTree
const CANDIDATE := "res://Temp/gi_quality_lightmap_20261022/white_box_lightmap_candidate.res"
func _initialize() -> void:
	call_deferred("_run")
func _sample_alpha(rgba: PackedFloat32Array, uv: Vector2, size: int) -> float:
	var pixel := uv * float(size) - Vector2(0.5,0.5)
	var origin := Vector2i(floori(pixel.x),floori(pixel.y))
	var fraction := pixel - Vector2(origin)
	var alpha := 0.0
	for y in 2:
		for x in 2:
			var sx := clampi(origin.x+x,0,size-1)
			var sy := clampi(origin.y+y,0,size-1)
			var weight := (fraction.x if x else 1.0-fraction.x)*(fraction.y if y else 1.0-fraction.y)
			alpha += rgba[(sy*size+sx)*4+3]*weight
	return alpha
func _run() -> void:
	var data: Resource = load(CANDIDATE)
	var scene: Node = load("res://box_test.tscn").instantiate()
	var sphere: MeshInstance3D = scene.get_node("Room/Sphere")
	var sphere_mesh := sphere.mesh as SphereMesh
	var layer := -1
	for i in data.mesh_relative_paths.size():
		if str(data.mesh_relative_paths[i]).ends_with("/Sphere"):
			layer = i
	var raw: PackedFloat32Array = data.radiance_layers[layer]
	data.display_gutter_pixels = 1
	var original_bytes := raw.to_byte_array()
	var chart_started := Time.get_ticks_usec()
	var single_chart: bool = data._mesh_has_single_uv_chart(sphere_mesh)
	var chart_usec := Time.get_ticks_usec()-chart_started
	chart_started = Time.get_ticks_usec()
	data._mesh_has_single_uv_chart(sphere_mesh)
	var cached_chart_usec := Time.get_ticks_usec()-chart_started
	var display_started := Time.get_ticks_usec()
	var display: PackedFloat32Array = data._display_rgba(raw,single_chart)
	var display_usec := Time.get_ticks_usec()-display_started
	var previous_display: PackedFloat32Array = data._display_rgba(raw,false)
	var arrays := sphere_mesh.surface_get_arrays(0)
	var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
	var output: Array = []
	var low := 0
	var alpha_min := 1.0
	var previous_low := 0
	var previous_alpha_min := 1.0
	for row in sphere_mesh.rings+1:
		for step in 33:
			var t := float(step)/32.0
			for edge in [0,sphere_mesh.radial_segments]:
				var a: int = row*(sphere_mesh.radial_segments+1)+edge
				var b: int = (row+1)*(sphere_mesh.radial_segments+1)+edge
				var coordinate := uv[a].lerp(uv[b],t)
				var raw_alpha := _sample_alpha(raw,coordinate,data.atlas_resolution)
				var display_alpha := _sample_alpha(display,coordinate,data.atlas_resolution)
				var previous_alpha := _sample_alpha(previous_display,coordinate,data.atlas_resolution)
				previous_alpha_min = minf(previous_alpha_min,previous_alpha)
				if previous_alpha < 0.99999:
					previous_low += 1
				alpha_min = minf(alpha_min,display_alpha)
				if display_alpha < 0.99999:
					low += 1
					output.append({"row":row,"step":step,"edge":edge,"uv":[coordinate.x,coordinate.y],"raw_alpha":raw_alpha,"display_alpha":display_alpha})
	var report := {"layer":layer,"resolution":data.atlas_resolution,"samples":(sphere_mesh.rings+1)*33*2,"incomplete_footprints":low,"minimum_display_alpha":alpha_min,"dips":output,"single_chart":single_chart,"chart_usec":chart_usec,"cached_chart_usec":cached_chart_usec,"display_usec":display_usec,"raw_unchanged":original_bytes==raw.to_byte_array(),"previous_incomplete_footprints":previous_low,"previous_minimum_display_alpha":previous_alpha_min,"resource_sha256":FileAccess.get_sha256(CANDIDATE)}
	var path := "user://feng_lightmap_mc_test/sphere_seam_audit.json"
	var file := FileAccess.open(path,FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t"))
	print("SPHERE_SEAM_AUDIT ",ProjectSettings.globalize_path(path)," incomplete=",low," min=",alpha_min," topology_usec=",chart_usec," cached_usec=",cached_chart_usec," display_usec=",display_usec," raw_unchanged=",original_bytes==raw.to_byte_array())
	scene.free()
	quit(0)
