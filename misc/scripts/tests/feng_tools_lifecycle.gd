@tool
extends EditorPlugin
## Editor-only lifecycle checks; never starts RenderDoc, Tracy or a download.

const CapturePlugin = preload("res://addons/feng-renderdoc-capture/src/editor_plugin.gd")
const TracyPlugin = preload("res://addons/feng-godottracy/src/editor_plugin.gd")
const FOREIGN_SEPARATOR := 0x7F700101

class TracyProbe extends TracyPlugin:
	var test_warnings: Array[String] = []
	func _warning(message: String) -> void:
		test_warnings.append(message)

var failures := 0
var checks := 0

func _enter_tree() -> void:
	run.call_deferred()

func require(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("REGRESSION: " + message)

func visible_viewports() -> Array:
	var result: Array = []
	for index in 4:
		var viewport = EditorInterface.get_editor_viewport_3d(index)
		if viewport == null:
			continue
		var container = viewport.get_parent()
		if container is CanvasItem and not container.is_visible_in_tree():
			continue
		result.append(viewport)
	return result

func require_modes(viewports: Array, mode: int, label: String) -> void:
	for viewport in viewports:
		require(viewport.render_target_update_mode == mode, label)

func test_capture() -> void:
	var subject = CapturePlugin.new()
	add_child(subject)
	var viewports := visible_viewports()
	require(not viewports.is_empty(), "no actual visible editor3D viewport was available")
	var original: Array = []
	for viewport in viewports:
		original.append(viewport.render_target_update_mode)
		viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE

	# Immediate and queued capture share one snapshot until completion.
	subject._prepare_capture_viewports()
	require_modes(viewports, SubViewport.UPDATE_ALWAYS, "capture did not force the visible viewport")
	require(subject._capture_forced_viewports.size() == viewports.size(), "capture lost ownership of its snapshot")
	subject._busy = true
	subject.button.disabled = true
	subject._finish_capture()
	require_modes(viewports, SubViewport.UPDATE_WHEN_VISIBLE, "fallback cleanup left UPDATE_ALWAYS enabled")
	require(not subject._busy and not subject.button.disabled, "capture completion did not restore UI state")

	# Repeated preparation must retain the original modes; already-always views
	# are not owned and must never be reset by this plugin.
	subject._prepare_capture_viewports()
	subject._prepare_capture_viewports()
	subject._restore_capture_viewports()
	require_modes(viewports, SubViewport.UPDATE_WHEN_VISIBLE, "repeated preparation lost original modes")
	for viewport in viewports:
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	subject._prepare_capture_viewports()
	require(subject._capture_forced_viewports.is_empty(), "already-always viewports must not be owned")
	subject._restore_capture_viewports()
	require_modes(viewports, SubViewport.UPDATE_ALWAYS, "unowned viewport modes were changed")
	for viewport in viewports:
		viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE

	var doomed := SubViewport.new()
	subject._capture_forced_viewports.append({"viewport": doomed, "mode": SubViewport.UPDATE_ONCE})
	doomed.free()
	subject._restore_capture_viewports()
	require(subject._capture_forced_viewports.is_empty(), "freed viewport references were retained")

	# Real plugin detach/re-entry uses the same cleanup as completion and retires
	# an old async wait before another capture can begin.
	subject._prepare_capture_viewports()
	subject._busy = true
	var old_generation: int = subject._capture_generation
	remove_child(subject)
	require_modes(viewports, SubViewport.UPDATE_WHEN_VISIBLE, "plugin disable left forced viewports")
	require(not subject._busy and subject.button == null, "plugin disable retained busy/button state")
	require(subject._capture_generation != old_generation, "plugin disable did not retire the old wait")
	add_child(subject)
	subject._prepare_capture_viewports()
	require(subject._capture_generation != old_generation, "re-entry revived the old wait")
	remove_child(subject)
	subject._finish_capture()
	require_modes(viewports, SubViewport.UPDATE_WHEN_VISIBLE, "idempotent cleanup changed restored modes")
	for index in viewports.size():
		viewports[index].render_target_update_mode = original[index]
	subject.free()

func test_tracy() -> void:
	var subject := TracyProbe.new()
	add_child(subject)
	var menu: PopupMenu = subject._debug_menu
	require(menu != null, "Tracy did not find the editor Debug menu")
	if menu != null:
		var separator := menu.get_item_index(TracyPlugin.SEPARATOR_ID)
		require(separator >= 0, "Tracy separator has no owned ID")
		if separator >= 0:
			# Another addon has moved our separator and placed its own before the
			# item. Cleanup must use identities, not adjacency.
			menu.set_item_id(separator, FOREIGN_SEPARATOR)
			menu.add_separator("Moved Tracy separator", TracyPlugin.SEPARATOR_ID)
		if OS.get_name() != "Windows":
			var children_before := subject.get_child_count()
			subject._download_profiler()
			require(not subject._downloading and subject.get_child_count() == children_before, "non-Windows installation started a Windows archive request")
			require(subject.test_warnings.size() == 1, "unsupported automatic installation did not explain the native executable setting")
		remove_child(subject)
		require(menu.get_item_index(TracyPlugin.MENU_ID) == -1, "Tracy menu item survived disable")
		require(menu.get_item_index(TracyPlugin.SEPARATOR_ID) == -1, "moved Tracy separator survived disable")
		require(menu.get_item_index(FOREIGN_SEPARATOR) >= 0, "Tracy removed another addon's separator")
		require(not menu.id_pressed.is_connected(Callable(subject, "_on_menu_id_pressed")), "Tracy menu signal survived disable")
		var foreign := menu.get_item_index(FOREIGN_SEPARATOR)
		if foreign >= 0:
			menu.remove_item(foreign)
		add_child(subject)
		remove_child(subject)
		require(menu.get_item_index(TracyPlugin.MENU_ID) == -1 and menu.get_item_index(TracyPlugin.SEPARATOR_ID) == -1, "Tracy reload left duplicate items")
	else:
		remove_child(subject)
	subject.free()

func run() -> void:
	while EditorInterface.get_resource_filesystem().is_scanning():
		await get_tree().process_frame
	EditorInterface.set_main_screen_editor("3D")
	for index in 4:
		await get_tree().process_frame
	test_capture()
	test_tracy()
	for index in 3:
		await get_tree().process_frame
	while EditorInterface.get_resource_filesystem().is_scanning():
		await get_tree().process_frame
	if failures == 0:
		print("PASS Feng editor tools lifecycle: ", checks, " checks; capture fallback/reload and Tracy menu ownership")
	get_tree().quit(0 if failures == 0 else 1)
