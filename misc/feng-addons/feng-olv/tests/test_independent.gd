extends SceneTree
const Controller = preload("res://addons/feng-olv/feng_olv_volume.gd")
const Pass = preload("res://addons/feng-render-pipeline/passes/magic_gi_pass.gd")
const OUT := "res://.godot/feng-olv-tests/"
var checks := 0
var failures := 0
func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(message)
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var scene := (load("res://box_test.tscn") as PackedScene).instantiate()
	root.add_child(scene);current_scene=scene
	await process_frame
	var volume: Node = scene.get_node("MagicGIVolume")
	check(volume.call("has_bake"),"Existing GI remains current")
	var original_manifest: Resource = volume.get("bake_manifest")
	var original_manifest_path := original_manifest.resource_path
	var before: Dictionary = volume.call("_load_active_source_page")
	var source: Resource = before.source
	var transfer: PackedFloat32Array = source.transfer.duplicate()
	var operators: PackedFloat32Array = source.clv_prepared_operators.duplicate()
	var existing: Node = volume.call("get_olv_controller")
	var ensured: Node = volume.call("ensure_olv_controller")
	check(existing == ensured,"Opening OLV selects the existing component")
	check(volume.call("ensure_olv_controller") == ensured,"Repeated opening does not create another component")
	var component_count := 0
	for child in volume.get_children():
		if child is Controller: component_count += 1
	check(component_count == 1,"A MagicGI volume has one OLV component")
	var duplicate := Controller.new()
	duplicate.data = ensured.get("data")
	duplicate.data_path = "res://.godot/olv-independent-test/duplicate-must-not-write.res"
	volume.add_child(duplicate)
	check(duplicate.get_source_volume() == null and not duplicate._get_configuration_warnings().is_empty(),"Duplicate OLV cannot bind to the same parent")
	check(not duplicate.runtime_binding().enabled,"Duplicate OLV cannot publish runtime labels")
	check(not duplicate.set_probe_overrides({}),"Duplicate OLV cannot edit labels")
	check(volume.call("get_olv_controller") == ensured,"Duplicate OLV does not replace the active component")
	volume.remove_child(duplicate);duplicate.free()
	var orphan := Controller.new()
	scene.add_child(orphan)
	check(orphan.get_source_volume() == null and not orphan._get_configuration_warnings().is_empty(),"OLV requires its MagicGI parent")
	scene.remove_child(orphan);orphan.free()
	if existing != null: volume.remove_child(existing);existing.free()
	var node := Controller.new()
	node.name = "OLV"
	node.data_path = "res://.godot/olv-independent-test/domains.res"
	volume.add_child(node)
	check(volume.call("has_bake"),"Creating independent OLV does not stale GI")
	check(node.import_existing_labels(),"Existing labels migrate without inference")
	check(node.data.automatic_labels == source.olv_probe_domain_payload.labels,"Imported automatic labels are exact")
	check(volume.get("bake_manifest")==original_manifest,"Migration does not replace GI manifest")
	var pass_value := Pass.new()
	var snapshot := {"manifest":original_manifest,"olv_binding":node.runtime_binding()}
	check(not pass_value._validated_native_olv_binding(snapshot,source).is_empty(),"Renderer validates independent labels")
	node.enabled=false
	snapshot.olv_binding=node.runtime_binding()
	check(pass_value._validated_native_olv_binding(snapshot,source).is_empty(),"Disable overrides legacy baked OLV")
	check(volume.call("has_bake") and not volume.call("needs_rebake"),"Disable does not stale GI")
	node.enabled=true
	var selected := -1
	for index in source.probe_count:
		if source.cell_is_valid(index):selected=index;break
	node.select_probe(selected)
	var original_label := node.probe_label(selected)
	var edited_label := 1 if original_label==2 else 2
	var uid := ResourceUID.create_id()
	check(ResourceSaver.set_uid(node.data_path,uid)==OK,"Prepare stable resource UID")
	# Runtime ResourceLoader reads the UID registry; unlike the editor, it does
	# not scan the file header after ResourceSaver.set_uid(). Register the same
	# UID so this fixture has the editor's normal file/registry consistency.
	var previous_uid := ResourceLoader.get_resource_uid(node.data_path)
	if previous_uid >= 0 and ResourceUID.has_id(previous_uid): ResourceUID.remove_id(previous_uid)
	ResourceUID.add_id(uid,node.data_path)
	check(node.set_probe_overrides(node.overrides_for_selection(edited_label)),"Single-probe editing succeeds")
	check(ResourceLoader.get_resource_uid(node.data_path)==uid,"Label edits preserve existing resource UID")
	check(node.probe_label(selected)==edited_label,"Single-probe change is applied")
	check(node.data.automatic_labels[selected]==original_label,"Automatic result preserved for undo")
	check(node.set_probe_overrides({}),"Reverting edits succeeds")
	check(node.probe_label(selected)==original_label,"Undo restores automatic label")
	node.batch_size=Vector3(1,1,1)
	node.select_in_box()
	check(node.selected_probes.size()>1,"Box selection selects a batch")
	check(node.set_probe_overrides(node.overrides_for_selection(2)),"Batch editing succeeds without model")
	for index in node.selected_probes:check(node.probe_label(index)==2,"Each selected probe receives binary label")
	check(node.set_probe_overrides({}),"Batch edits can be reverted")
	check(volume.get("bake_manifest").resource_path==original_manifest_path,"Editing leaves GI manifest unchanged")
	check(source.transfer==transfer and source.clv_prepared_operators==operators,"Editing leaves transfer and operators exact")
	var model_before := node.model_directory
	node.model_directory=_make_test_bundle()
	check(volume.call("has_bake") and not volume.call("needs_rebake"),"Changing model does not invalidate GI")
	node.select_probe(selected)
	check(node.set_probe_overrides(node.overrides_for_selection(edited_label)),"Set correction before model update")
	var ok := await node.update_labels()
	check(ok,"Different model manifest updates independently")
	check(node.probe_label(selected)==edited_label,"Manual corrections survive model updates")
	check(node.data.model_bundle_sha256 != source.olv_probe_domain_payload.model_sha256,"New model binding is independent of old source payload")
	check(source.transfer==transfer and source.clv_prepared_operators==operators,"Model update does not alter GI arrays")
	check(volume.get("bake_manifest")==original_manifest,"Model update does not replace GI manifest")
	check(volume.call("has_bake") and not volume.call("needs_rebake"),"GI remains current after model update")
	snapshot.olv_binding=node.runtime_binding()
	check(not pass_value._validated_native_olv_binding(snapshot,source).is_empty(),"Renderer accepts updated model sidecar on retained GI")
	var report := {"checks":checks,"failures":failures,"ok":failures==0,"manifest_unchanged":true,"source_transfer_unchanged":true,"model_updates_without_gi_bake":true,"toggle_and_manual_edits":true}
	var file := FileAccess.open(OUT+"independent_report.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t"));file.close()
	print("OLV_INDEPENDENT_RESULT ",JSON.stringify(report))
	node.model_directory=model_before
	scene.queue_free();await process_frame;quit(0 if failures==0 else 1)

func _make_test_bundle() -> String:
	var folder := OUT + "model-update"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	for name in ["model.pt","normalizer.json"]:
		var file := FileAccess.open(folder.path_join(name),FileAccess.WRITE)
		file.store_buffer(FileAccess.get_file_as_bytes("res://addons/feng-olv/model/"+name));file.close()
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://addons/feng-olv/model/inference_manifest.json"))
	manifest["candidate_id"] = "independent-model-binding-regression"
	manifest["seeds"][0]["seed"] = int(manifest["seeds"][0]["seed"])
	var file := FileAccess.open(folder.path_join("inference_manifest.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify(manifest));file.close()
	return folder
