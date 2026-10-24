extends SceneTree
var checks := []
var failed := 0
func _initialize() -> void: call_deferred("_run")
func _check(name: String, passed: bool, details: Variant=null) -> void:
	checks.append({"name":name,"pass":passed,"details":details})
	if not passed: failed+=1
	print("UV_CONTRACT ",name," ",passed," ",details)
func _run() -> void:
	var fixture:=FileAccess.open("F:/godot/feng-godot/Temp/lightmap_native_20261022/actual_scene_inputs.bin",FileAccess.READ)
	var inputs:Dictionary=fixture.get_var()
	fixture.close()
	var backend=ClassDB.instantiate("FengLightmapMCIntegrator")
	var result:Dictionary=backend.bake_scene_atlases(inputs,{"mesh_count":9,"resolution":128,"samples_per_texel":4,"seed":1,"worker_count":1})
	var diagnostic:=result.duplicate()
	diagnostic.erase("layers")
	_check("all_nine_actual_receivers_128",result.get("ok",false) and result.get("layers",[]).size()==9,diagnostic)
	var small:=inputs.duplicate(true)
	for key in ["vertices","normals","uv2"]: small[key]=small[key].slice(0,6)
	for key in ["albedo","emission","material_flags","mesh_ids","roughness","metallic","specular","diffuse_modes"]: small[key]=small[key].slice(0,2)
	result=backend.bake_scene_atlases(small,{"mesh_count":1,"resolution":128,"samples_per_texel":4,"seed":1,"worker_count":1})
	_check("exact_shared_diagonal_rectangle",result.get("ok",false),result.get("error"))
	result=backend.bake_scene_atlases(small,{"mesh_count":1,"resolution":2048,"samples_per_texel":1,"seed":1,"worker_count":4})
	_check("shared_diagonal_at_2048",result.get("ok",false),result.get("error"))
	var overlap:=small.duplicate(true)
	for i in 3: overlap.uv2[3+i]=overlap.uv2[i]
	result=backend.bake_scene_atlases(overlap,{"mesh_count":1,"resolution":128,"samples_per_texel":1,"seed":1,"worker_count":1})
	_check("genuine_duplicate_overlap_rejected",not result.get("ok",false) and result.get("error_kind")=="uv2_overlap",result)
	_check("overlap_diagnostic_indices",result.get("mesh_id",-1)==0 and result.get("triangle_id",-1)==1 and result.get("other_triangle_id",-1)==0 and result.get("overlap_area",0)>0)
	overlap=small.duplicate(true)
	# Move the second triangle's unique corner through the shared diagonal;
	# this is a real overlap, not a roundoff sliver or a shared edge.
	overlap.uv2[5]=Vector2(0.7,0.58)
	result=backend.bake_scene_atlases(overlap,{"mesh_count":1,"resolution":128,"samples_per_texel":1,"seed":1,"worker_count":1})
	_check("same_edge_same_side_overlap_rejected",not result.get("ok",false) and result.get("error_kind")=="uv2_overlap",result)
	overlap=small.duplicate(true)
	for i in range(3,6): overlap.uv2[i].x += pow(2.0,-20.0)
	result=backend.bake_scene_atlases(overlap,{"mesh_count":1,"resolution":128,"samples_per_texel":1,"seed":1,"worker_count":1})
	_check("thin_real_overlap_rejected",not result.get("ok",false) and result.get("error_kind")=="uv2_overlap",result)
	var f:=FileAccess.open("F:/godot/feng-godot/Temp/lightmap_native_20261022/uv_regression.json",FileAccess.WRITE)
	f.store_string(JSON.stringify({"pass":failed==0,"failed":failed,"checks":checks},"  "))
	f.close()
	quit(0 if failed==0 else 1)
