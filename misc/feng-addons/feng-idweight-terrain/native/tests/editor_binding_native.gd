extends SceneTree
## Real GDExtension dispatch smoke test, without starting an editor UI or GPU terrain.

const Binding = preload("res://addons/feng-idweight-terrain/src/terrain_editor_binding.gd")
var failed := false


func _initialize() -> void:
	call_deferred("run")


func require(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error("NATIVE EDITOR BINDING: " + message)


func run() -> void:
	var status := GDExtensionManager.load_extension("res://terrain_test.gdextension")
	require(status == GDExtensionManager.LOAD_STATUS_OK or status == GDExtensionManager.LOAD_STATUS_ALREADY_LOADED, "extension did not load")
	require(ClassDB.class_exists(&"Terrain3D") and ClassDB.class_exists(&"Terrain3DEditor"), "native classes were not registered")
	if failed:
		quit(1)
		return
	var terrain_a: Object = ClassDB.instantiate(&"Terrain3D")
	var terrain_b: Object = ClassDB.instantiate(&"Terrain3D")
	var editor: Object = ClassDB.instantiate(&"Terrain3DEditor")
	var replacement_editor: Object = ClassDB.instantiate(&"Terrain3DEditor")
	var plugin := Node.new()
	var replacement_plugin := Node.new()
	for terrain in [terrain_a, terrain_b]:
		require(terrain.get_editor() == null and terrain.get_plugin() == null, "new terrain has unexpected owners")
		terrain.set_editor(null)
		terrain.set_plugin(null)
	# Bind A, hand off to B, then disable while both terrain nodes survive.
	terrain_a.set_plugin(plugin)
	terrain_a.set_editor(editor)
	editor.set_terrain(terrain_a)
	require(terrain_a.get_editor() == editor and terrain_a.get_plugin() == plugin and editor.get_terrain() == terrain_a, "native getters did not round-trip owners")
	Binding.release(terrain_a, editor, plugin)
	editor.set_terrain(null)
	require(terrain_a.get_editor() == null and terrain_a.get_plugin() == null and editor.get_terrain() == null, "handoff did not clear native pointers")
	terrain_b.set_plugin(plugin)
	terrain_b.set_editor(editor)
	editor.set_terrain(terrain_b)
	# A new owner takes A before the old plugin's final cleanup.
	terrain_a.set_plugin(replacement_plugin)
	terrain_a.set_editor(replacement_editor)
	Binding.release(terrain_a, editor, plugin)
	require(terrain_a.get_editor() == replacement_editor and terrain_a.get_plugin() == replacement_plugin, "late release removed replacement native owners")
	Binding.release(terrain_b, editor, plugin)
	Binding.release(terrain_b, editor, plugin)
	editor.set_terrain(null)
	editor.free()
	plugin.free()
	# Query the real native pointers after destruction, not merely before it.
	require(terrain_b.get_editor() == null and terrain_b.get_plugin() == null, "terrain retained destroyed native owners")
	require(terrain_a.get_editor() == replacement_editor and terrain_a.get_plugin() == replacement_plugin, "old-owner destruction affected replacement links")
	var third_plugin := Node.new()
	terrain_a.set_plugin(third_plugin)
	Binding.release(terrain_a, replacement_editor, replacement_plugin)
	require(terrain_a.get_editor() == null and terrain_a.get_plugin() == third_plugin, "independent editor release disturbed another plugin")
	terrain_a.set_editor(replacement_editor)
	Binding.release(terrain_a, null, third_plugin)
	require(terrain_a.get_editor() == replacement_editor and terrain_a.get_plugin() == null, "independent plugin release disturbed another editor")
	Binding.release(terrain_a, replacement_editor, replacement_plugin)
	replacement_editor.set_terrain(null)
	replacement_editor.free()
	replacement_plugin.free()
	third_plugin.free()
	require(terrain_a.get_editor() == null and terrain_a.get_plugin() == null, "final owner release failed")
	terrain_a.free()
	Binding.release(terrain_a, null, null)
	terrain_b.free()
	if not failed:
		print("TERRAIN NATIVE EDITOR BINDING PASS")
	quit(1 if failed else 0)
