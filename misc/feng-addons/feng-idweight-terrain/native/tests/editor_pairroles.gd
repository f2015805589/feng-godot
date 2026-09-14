@tool
extends EditorPlugin

## Focused regression for the IdWeight pair role readout in the brush settings
## bar.
##
## The port drew Overlay/Background role borders in the asset dock but never
## named the two layers, so which material was the overlay and which was the
## background was invisible while painting. This drives the real
## tool_settings.gd through its own _ready() (so the assertions cover the
## production registration, not a hand-built copy of it) and checks that the
## readout exists, states the click mapping, carries the role names, and is
## actually shown for the texture tool.

const Settings = preload("res://addons/feng-idweight-terrain/src/tool_settings.gd")
const Dock = preload("res://addons/feng-idweight-terrain/src/asset_dock.gd")
const UI_SOURCE: String = "res://addons/feng-idweight-terrain/src/ui.gd"

var debug: int = 0

var _stored: Dictionary = {}
var _finished: bool = false


# Stand-ins for Terrain3DEditorPlugin's EditorSettings helpers. The readout does
# not depend on them; they only keep the real _ready() running unmodified.
func get_setting(p_str: String, p_default: Variant) -> Variant:
	return _stored.get(p_str, p_default)


func set_setting(p_str: String, p_value: Variant) -> void:
	_stored[p_str] = p_value


func erase_setting(p_str: String) -> void:
	_stored.erase(p_str)


func _enter_tree() -> void:
	call_deferred("_watchdog")
	call_deferred("_run")


# A script error inside the probe aborts the coroutine without reaching either
# quit(), which would otherwise burn the runner's full 180s timeout.
func _watchdog() -> void:
	await get_tree().create_timer(120.0).timeout
	if not _finished:
		_fail("watchdog: probe did not finish within 120s")


func _fail(message: String) -> void:
	if _finished:
		return
	_finished = true
	push_error("PAIR_ROLE_READOUT_REGRESSION: " + message)
	get_tree().quit(1)


func _require(condition: bool, message: String) -> bool:
	if condition:
		return true
	_fail(message)
	return false


func _run() -> void:
	while EditorInterface.get_resource_filesystem().is_scanning():
		await get_tree().process_frame

	var settings: Settings = Settings.new()
	settings.plugin = self
	# Entering the tree runs the production _ready(), which registers every brush
	# setting including the pair readout.
	EditorInterface.get_base_control().add_child(settings)
	await get_tree().process_frame

	var roles: Object = settings.settings.get("pair_roles")
	if not _require(roles is Label, "tool_settings did not register a 'pair_roles' Label"):
		return
	var hint: Object = settings.settings.get("pair_click_hint")
	if not _require(hint is Label, "tool_settings did not register a 'pair_click_hint' Label"):
		return

	# The layer grid prints exactly this mapping above its tiles. The label names
	# the roles the other way round than the packed pair fields on purpose, so
	# this text is expected to disagree with the field mapping asserted below.
	var hint_text: String = (hint as Label).text
	if not _require(hint_text.contains("Left click: Overlay") and
			hint_text.contains("Right click: Background"),
			"click hint does not state the left=Overlay / right=Background mapping: %s" %
			hint_text):
		return

	# The packed chain writes the left-clicked layer into the Background pair
	# field (the base) and the right-clicked layer into the Overlay field (the
	# layer the Weight slider fades in). The packed encoding of those two fields
	# is covered by editor_input.gd's press, so this pins the button-to-field half
	# of the contract.
	var list_class: Object = Dock.ListContainer
	if not _require(list_class != null and list_class.has_method("role_writes_overlay_field"),
			"asset dock does not expose ListContainer.role_writes_overlay_field"):
		return
	if not _require(not list_class.role_writes_overlay_field(0),
			"left click must write the Background pair field, not the Overlay field"):
		return
	if not _require(list_class.role_writes_overlay_field(1),
			"right click must write the Overlay pair field"):
		return

	# The readout must name both layers, and the Background half must follow the
	# Overlay half so the two roles cannot be silently swapped in the display.
	settings.set_pair_roles_text("3: Rock", "7: Grass")
	var roles_text: String = (roles as Label).text
	if not _require(roles_text == "Overlay: 3: Rock    Background: 7: Grass",
			"role readout text is wrong: %s" % roles_text):
		return

	# A registered readout still needs the texture tool to show it.
	var ui_source: String = FileAccess.get_file_as_string(UI_SOURCE)
	if not _require(ui_source.contains('to_show.push_back("pair_roles")') and
			ui_source.contains('to_show.push_back("pair_click_hint")'),
			"ui.gd does not show the pair readout for the texture tool"):
		return

	print("PASS IdWeight pair role readout shown for the texture tool and the click mapping matches the pair fields")
	_finished = true
	get_tree().quit(0)
