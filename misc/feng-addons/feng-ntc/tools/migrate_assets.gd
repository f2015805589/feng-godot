extends SceneTree
## godot --headless --path PROJECT --script res://addons/feng-ntc/tools/migrate_assets.gd -- res://materials/example.ntc.res
func _init() -> void:
	_run.call_deferred()
func _run() -> void:
	if not ClassDB.class_exists(&"FengNTCCodec"):
		GDExtensionManager.load_extension("res://addons/feng-ntc/tools/feng_ntc.gdextension")
	if not ClassDB.class_exists(&"FengNTCCodec"): push_error("NTC authoring extension unavailable"); quit(1); return
	for path: String in OS.get_cmdline_user_args():
		var asset: Resource = load(path)
		if asset == null or not asset.has_method("ensure_portable"):
			push_error("Not an NTC texture set: "+path); quit(1); return
		if not asset.ensure_portable(): push_error(asset.last_error); quit(1); return
		if ResourceSaver.save(asset,path,ResourceSaver.FLAG_COMPRESS)!=OK:
			push_error("Cannot save: "+path); quit(1); return
		print("PORTABLE_ASSET: ",path)
	quit()
