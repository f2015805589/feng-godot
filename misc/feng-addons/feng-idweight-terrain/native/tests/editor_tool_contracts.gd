extends SceneTree
## Runs without the optional terrain GDExtension or editor UI.

const Packer = preload("res://addons/feng-idweight-terrain/menu/channel_packer_support.gd")
const Move = preload("res://addons/feng-idweight-terrain/tools/region_move_transaction.gd")
const Binding = preload("res://addons/feng-idweight-terrain/src/terrain_editor_binding.gd")
var failed := false
var fixture_root := ""


class MockTerrain extends RefCounted:
	var bound_editor: Object
	var bound_plugin: Object
	var editor_clear_count := 0
	var plugin_clear_count := 0

	func get_editor() -> Object:
		return bound_editor

	func set_editor(value: Object) -> void:
		bound_editor = value
		if value == null:
			editor_clear_count += 1

	func get_plugin() -> Object:
		return bound_plugin

	func set_plugin(value: Object) -> void:
		bound_plugin = value
		if value == null:
			plugin_clear_count += 1


func _initialize() -> void:
	call_deferred("run")


func require(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error("TOOL CONTRACT: " + message)


func run() -> void:
	test_editor_binding_lifetime()
	test_alignment()
	test_save_failures()
	test_packer_queue()
	fixture_root = "user://region_move_contract_" + str(Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(fixture_root)
	test_region_plan()
	test_region_execution()
	cleanup_fixture(fixture_root)
	if not failed:
		print("TERRAIN EDITOR TOOL CONTRACTS PASS")
	quit(1 if failed else 0)


func test_editor_binding_lifetime() -> void:
	var editor := RefCounted.new()
	var plugin := RefCounted.new()
	var replacement_editor := RefCounted.new()
	var replacement_plugin := RefCounted.new()
	var terrain_a := MockTerrain.new()
	var terrain_b := MockTerrain.new()
	# Bind A, hand off to B, then disable. Every previously selected terrain
	# must stop referencing the owners before those owners are freed.
	terrain_a.set_editor(editor)
	terrain_a.set_plugin(plugin)
	Binding.release(terrain_a, editor, plugin)
	terrain_b.set_editor(editor)
	terrain_b.set_plugin(plugin)
	require(terrain_a.get_editor() == null and terrain_a.get_plugin() == null, "selection handoff left A pointing at the old owners")
	Binding.release(terrain_b, editor, plugin)
	require(terrain_b.get_editor() == null and terrain_b.get_plugin() == null, "disable left B pointing at freed owners")
	Binding.release(terrain_b, editor, plugin)
	require(terrain_b.editor_clear_count == 1 and terrain_b.plugin_clear_count == 1, "release was not idempotent")
	# A late teardown from the old plugin must preserve all replacement links.
	terrain_a.set_editor(replacement_editor)
	terrain_a.set_plugin(replacement_plugin)
	Binding.release(terrain_a, editor, plugin)
	require(terrain_a.get_editor() == replacement_editor and terrain_a.get_plugin() == replacement_plugin, "late teardown removed replacement owners")
	# Links are independently owned, including partially completed handoffs.
	terrain_a.set_editor(editor)
	Binding.release(terrain_a, editor, plugin)
	require(terrain_a.get_editor() == null and terrain_a.get_plugin() == replacement_plugin, "editor cleanup removed another plugin's link")
	terrain_a.set_editor(replacement_editor)
	terrain_a.set_plugin(plugin)
	Binding.release(terrain_a, editor, plugin)
	require(terrain_a.get_editor() == replacement_editor and terrain_a.get_plugin() == null, "plugin cleanup removed another editor's link")
	Binding.release(null, editor, plugin)
	var freed_terrain := Node.new()
	freed_terrain.free()
	Binding.release(freed_terrain, editor, plugin)
	# Source integration checks complement the executed helper tests; the real
	# EditorPlugin/native extension is unavailable in this isolated project.
	var source := FileAccess.get_file_as_string("res://addons/feng-idweight-terrain/src/editor_plugin.gd")
	var exit_body := source.get_slice("func _exit_tree()", 1).get_slice("\nfunc ", 0)
	var edit_body := source.get_slice("func _edit(", 1).get_slice("\nfunc ", 0)
	var clear_body := source.get_slice("func _clear(", 1).get_slice("\nfunc ", 0)
	require(exit_body.find("_clear()") >= 0 and exit_body.find("_clear()") < exit_body.find("editor.free()"), "plugin frees native editor before releasing the active terrain")
	var last_release := exit_body.find("EDITOR_BINDING.release(_last_terrain, editor, self)")
	require(last_release >= 0 and last_release < exit_body.find("editor.free()"), "last terrain is not released before editor destruction")
	require(edit_body.find("_clear(false)") >= 0 and edit_body.find("_clear(false)") < edit_body.find("terrain = p_object"), "selection replaces terrain without releasing its old links")
	require(clear_body.find("EDITOR_BINDING.release(terrain, editor, self)") >= 0, "clear does not release owned native bindings")
	require(clear_body.find("ui.clear_picking()") < clear_body.find("terrain = null"), "picker cleanup loses the terrain before clearing highlights")
	var ui_source := FileAccess.get_file_as_string("res://addons/feng-idweight-terrain/src/ui.gd")
	var picker_body := ui_source.get_slice("func clear_picking()", 1).get_slice("\nfunc ", 0)
	require(picker_body.contains("tree != null") and picker_body.contains("is_instance_valid(plugin.terrain)"), "picker cleanup does not guard detached UI or freed terrain")


func test_alignment() -> void:
	for normal in [Vector3(0, 0, 1), Vector3(0, 0, -1), Vector3(0.00001, 0, -1), Vector3(0, 0.00001, 1), Vector3(0.3, -0.5, 0.4), Vector3(1.0e30, -2.0e30, 3.0e30), Vector3(1.0e-30, 2.0e-30, -3.0e-30)]:
		var basis := Packer.alignment_basis(normal)
		require(basis.is_finite(), "normal alignment must stay finite at both poles")
		require(absf(basis.determinant() - 1.0) < 0.00001, "normal alignment changed handedness or scale")
		require((basis.transposed() * basis).is_equal_approx(Basis.IDENTITY), "normal alignment is not orthonormal")
		var maximum: float = normal.abs()[normal.abs().max_axis_index()]
		var direction: Vector3 = (normal / maximum).normalized()
		require((direction * basis).distance_to(Vector3(0, 0, 1)) < 0.00001, "row-vector alignment does not take the average normal onto +Z")
		require(basis == Packer.alignment_basis(normal), "pole alignment is nondeterministic")
	for invalid in [Vector3.ZERO, Vector3(NAN, 0, 0), Vector3(INF, 0, 0)]:
		require(Packer.alignment_basis(invalid) == Basis.IDENTITY, "degenerate normal did not use identity fallback")
	# Preserve the original Rodrigues/tangent orientation for ordinary normals.
	var n := Vector3(0.3, -0.4, 0.8).normalized()
	var v := n.cross(Vector3(0, 0, 1))
	var c := n.z
	var k := 1.0 / (1.0 + c)
	var old := Basis(Vector3(v.x * v.x * k + c, v.x * v.y * k - v.z, v.x * v.z * k + v.y), Vector3(v.x * v.y * k + v.z, v.y * v.y * k + c, v.y * v.z * k - v.x), Vector3(v.x * v.z * k - v.y, v.y * v.z * k + v.x, v.z * v.z * k + c))
	var updated := Packer.alignment_basis(n)
	require(updated.x.distance_to(old.x) < 0.00001 and updated.y.distance_to(old.y) < 0.00001 and updated.z.distance_to(old.z) < 0.00001, "normal fix changed existing tangent orientation")


func test_save_failures() -> void:
	var calls := [0]
	var save_import := func() -> Error:
		calls[0] += 1
		return OK
	var failed_png := func() -> Error: return ERR_FILE_CANT_WRITE
	var successful_png := func() -> Error: return OK
	var failed_import := func() -> Error: return ERR_CANT_CREATE
	require(Packer.save_pair(failed_png, save_import) == ERR_FILE_CANT_WRITE and calls[0] == 0, "failed PNG write was reported as success or wrote a sidecar")
	require(Packer.save_pair(successful_png, failed_import) == ERR_CANT_CREATE, "failed import-settings write was reported as success")
	require(Packer.save_pair(successful_png, save_import) == OK and calls[0] == 1, "successful packed save did not write its import settings exactly once")
	var source := FileAccess.get_file_as_string("res://addons/feng-idweight-terrain/menu/channel_packer.gd")
	var failure_branch := source.find("if save_error != OK:")
	var failure_return := source.find("return save_error", failure_branch)
	var success_message := source.find('_show_message(INFO, "Packed to "', failure_branch)
	require(failure_branch >= 0 and failure_return > failure_branch and success_message > failure_return, "packer UI claims success before returning the save failure")


func test_packer_queue() -> void:
	# Execute the production handlers with a dialog stub, without loading editor UI.
	var source := FileAccess.get_file_as_string("res://addons/feng-idweight-terrain/menu/channel_packer.gd")
	var script := GDScript.new()
	script.source_code = """extends RefCounted
const IMAGE_ALBEDO = 0
const IMAGE_HEIGHT = 1
const IMAGE_NORMAL = 2
const IMAGE_ROUGHNESS = 3
const WARN = 1
var packing_albedo = false
var queue_pack_normal_roughness = false
var images = [null, null, null, null, null]
var last_saved_directory = ""
var no_op = func(): pass
var last_file_selected_fn = no_op
var window = Node.new()
var save_file_dialog = Dialog.new()
class Dialog extends RefCounted:
	var current_path = ""
	var title = ""
	func popup_centered_ratio(): pass
func _show_message(_level, _text): pass
"""
	for name in ["_on_pack_button_pressed", "_on_close_requested"]:
		script.source_code += "\nfunc " + name + source.get_slice("func " + name, 1).get_slice("\n\nfunc ", 0) + "\n"
	require(script.reload() == OK, "packer queue handlers did not compile")
	var packer = script.new()
	packer.images = [true, true, true, true, null]
	packer._on_pack_button_pressed()
	require(packer.queue_pack_normal_roughness, "both pairs did not queue the second save")
	packer.images = [true, true, null, null, null]
	packer._on_pack_button_pressed()
	require(not packer.queue_pack_normal_roughness, "single pair retained a previous second save")
	packer.queue_pack_normal_roughness = true
	packer._on_close_requested()
	require(not packer.queue_pack_normal_roughness and packer.images == [null, null, null, null, null], "closing retained the previous packing session")
	require(source.contains("save_file_dialog.canceled.connect(func() -> void: queue_pack_normal_roughness = false)"), "cancel does not clear the queued save")


func encode(location: Vector2i) -> String:
	return "terrain3d" + ("_%02d" % location.x if location.x >= 0 else "%03d" % location.x) + ("_%02d" % location.y if location.y >= 0 else "%03d" % location.y) + ".res"


func decode(filename: String) -> Vector2i:
	var coordinates := filename.trim_prefix("terrain3d").trim_suffix(".res")
	return Vector2i(coordinates.left(3).replace("_", "").to_int(), coordinates.right(3).replace("_", "").to_int())


func make_fixture(name: String, filenames: Array[String]) -> DirAccess:
	var path := fixture_root.path_join(name)
	DirAccess.make_dir_recursive_absolute(path)
	for filename in filenames:
		var file := FileAccess.open(path.path_join(filename), FileAccess.WRITE)
		file.store_string(filename)
		file.close()
	return DirAccess.open(path)


func exists_in(dir: DirAccess) -> Callable:
	return func(path: String) -> bool: return dir.file_exists(path) or dir.dir_exists(path) or dir.is_link(path)


func test_region_plan() -> void:
	var zero := encode(Vector2i.ZERO)
	var edge := encode(Vector2i(15, 0))
	var dir := make_fixture("late_bounds", [zero, edge])
	var plan := Move.build_plan(dir.get_files(), Vector2i(1, 0), decode, encode, exists_in(dir))
	require(plan["error"] != OK and dir.file_exists(zero) and dir.file_exists(edge) and dir.get_files().size() == 2, "late bounds error modified earlier region files")
	var collision := make_fixture("collision", [zero, encode(Vector2i(1, 0))])
	plan = Move.build_plan(PackedStringArray([zero]), Vector2i(1, 0), decode, encode, exists_in(collision))
	require(plan["error"] == ERR_ALREADY_EXISTS, "unrelated destination collision was accepted")
	var temp_name := "tmp_" + encode(Vector2i(1, 0))
	var temporary := make_fixture("temp_collision", [zero, temp_name])
	plan = Move.build_plan(temporary.get_files(), Vector2i(1, 0), decode, encode, exists_in(temporary))
	require(plan["error"] == ERR_ALREADY_EXISTS, "preexisting temporary path was accepted")
	var malformed := make_fixture("malformed", ["terrain3dBAD.res"])
	plan = Move.build_plan(malformed.get_files(), Vector2i(1, 0), decode, encode, exists_in(malformed))
	require(plan["error"] == ERR_INVALID_DATA, "noncanonical region filename was accepted")
	var overflow := make_fixture("overflow", [edge])
	plan = Move.build_plan(overflow.get_files(), Vector2i(2147483647, 0), decode, encode, exists_in(overflow))
	require(plan["error"] != OK, "32-bit coordinate overflow bypassed bounds validation")


func test_region_execution() -> void:
	var zero := encode(Vector2i.ZERO)
	var one := encode(Vector2i(1, 0))
	for failure_call in [0, 2, 4]:
		var dir := make_fixture("move_" + str(failure_call), [zero, one])
		var plan := Move.build_plan(dir.get_files(), Vector2i(1, 0), decode, encode, exists_in(dir))
		var calls := [0]
		var rename := func(source: String, target: String) -> Error:
			calls[0] += 1
			if calls[0] == failure_call:
				return ERR_FILE_CANT_WRITE
			return dir.rename(source, target)
		var result := Move.execute(plan, rename, exists_in(dir))
		if failure_call == 0:
			require(result["error"] == OK and not dir.file_exists(zero), "valid relocation failed")
			require(FileAccess.get_file_as_string(dir.get_current_dir().path_join(one)) == zero, "overlapping chain overwrote the first region")
			require(FileAccess.get_file_as_string(dir.get_current_dir().path_join(encode(Vector2i(2, 0)))) == one, "overlapping chain overwrote the second region")
		else:
			require(result["error"] != OK and result["rollback_complete"], "injected staging/publish failure did not roll back")
			require(dir.get_files().size() == 2 and FileAccess.get_file_as_string(dir.get_current_dir().path_join(zero)) == zero and FileAccess.get_file_as_string(dir.get_current_dir().path_join(one)) == one, "rollback did not restore original names and bytes")
	var cycle := make_fixture("cycle", ["a.res", "b.res"])
	var moves: Array[Dictionary] = [{"source": "a.res", "target": "b.res", "temporary": "tmp_a.res"}, {"source": "b.res", "target": "a.res", "temporary": "tmp_b.res"}]
	var result := Move.execute({"error": OK, "moves": moves}, cycle.rename, exists_in(cycle))
	require(result["error"] == OK and FileAccess.get_file_as_string(cycle.get_current_dir().path_join("a.res")) == "b.res" and FileAccess.get_file_as_string(cycle.get_current_dir().path_join("b.res")) == "a.res", "two-phase transaction did not preserve a swap cycle")
	var rollback_failure := make_fixture("rollback_failure", [zero, one])
	var plan := Move.build_plan(rollback_failure.get_files(), Vector2i(1, 0), decode, encode, exists_in(rollback_failure))
	var calls := [0]
	var permanently_failing := func(source: String, target: String) -> Error:
		calls[0] += 1
		return rollback_failure.rename(source, target) if calls[0] == 1 else ERR_FILE_CANT_WRITE
	result = Move.execute(plan, permanently_failing, exists_in(rollback_failure))
	require(result["error"] != OK and not result["rollback_complete"] and result["recovery"].size() == 1 and rollback_failure.get_files().size() == 2, "rollback failure hid its recovery map or deleted data")


func cleanup_fixture(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for child in dir.get_directories():
		cleanup_fixture(path.path_join(child))
	for filename in dir.get_files():
		dir.remove(filename)
	DirAccess.remove_absolute(path)
