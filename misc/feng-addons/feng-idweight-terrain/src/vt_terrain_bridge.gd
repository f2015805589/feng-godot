# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# Duck-typed access to the native Terrain3D API.
#
# The VT window is a @tool script in an addon that can be linked against a
# different build of the extension, so every native call is guarded: a method or
# property that is missing must read as "unavailable" rather than break the
# editor. Keeping that knowledge here is what lets the window be ordinary UI code,
# and it is the one place to touch when a native API is renamed.
@tool
class_name TerrainVTBridge
extends RefCounted


# Calls p_method when the target has it, otherwise returns null.
static func call_method(p_target: Object, p_method: StringName, p_args: Array = []) -> Variant:
	if p_target == null or not is_instance_valid(p_target) or not p_target.has_method(p_method):
		return null
	return p_target.callv(p_method, p_args)


static func has_property(p_target: Object, p_property: StringName) -> bool:
	if p_target == null or not is_instance_valid(p_target):
		return false
	for property_info: Dictionary in p_target.get_property_list():
		if StringName(property_info.get("name", "")) == p_property:
			return true
	return false


static func data_of(p_terrain: Object) -> Object:
	var value := call_method(p_terrain, "get_data")
	return value as Object


static func vt_settings(p_terrain: Object) -> Dictionary:
	var value := call_method(p_terrain, "get_vt_settings")
	return value if typeof(value) == TYPE_DICTIONARY else {}


# The property is the documented API; the getter is the fallback for a build that
# only exposes the method.
static func svt_auto_bake(p_terrain: Object, p_property: StringName) -> bool:
	if p_terrain == null or not is_instance_valid(p_terrain):
		return true
	if has_property(p_terrain, p_property):
		return bool(p_terrain.get(p_property))
	var getter := call_method(p_terrain, "is_svt_auto_bake")
	return bool(getter) if getter != null else true


static func resident_pages(p_terrain: Object, p_kind: String = "") -> Array:
	var value := call_method(p_terrain, "get_vt_pages")
	var result: Array = []
	if typeof(value) != TYPE_ARRAY:
		return result
	for record in value:
		if typeof(record) != TYPE_DICTIONARY:
			continue
		if p_kind.is_empty() or record_kind(record) == p_kind:
			result.append(record)
	return result


static func baked_pages(p_terrain: Object) -> Array:
	var value := call_method(p_terrain, "get_svt_baked_pages")
	return value if typeof(value) == TYPE_ARRAY else []


# A page record names its tier either as text or as the native enum value.
static func record_kind(p_record: Dictionary) -> String:
	var value = p_record.get("kind", "")
	if typeof(value) == TYPE_STRING:
		return str(value).to_upper()
	if int(value) == 1:
		return "SVT"
	return "AVT"


static func view_stats(p_terrain: Object, p_kind: String) -> Dictionary:
	var method := "get_surface_vt" if p_kind == "AVT" else "get_surface_svt"
	var view := call_method(p_terrain, method)
	var value := call_method(view, "get_stats")
	return value if typeof(value) == TYPE_DICTIONARY else {}


static func stats_text(p_stats: Dictionary) -> String:
	if p_stats.is_empty():
		return "stats unavailable"
	return "hits %d · misses %d · evictions %d · free %d" % [
		int(p_stats.get("hit_count", 0)), int(p_stats.get("miss_count", 0)),
		int(p_stats.get("evict_count", 0)), int(p_stats.get("free_count", 0))]


# The SVT bake's state as one sentence, read from the native report's own keys. The window's status
# label and the node inspector's both show it and used to spell the same states out separately, which
# is how the two drifted apart in wording. `p_auto_bake` is the fallback the report omits.
static func svt_bake_status(p_settings: Dictionary, p_auto_bake: bool = true) -> String:
	var auto_enabled := bool(p_settings.get("auto_bake", p_auto_bake))
	var regions := int(p_settings.get("auto_pending_regions", 0))
	var incremental := bool(p_settings.get("bake_incremental", false))
	var mode := "Automatic incremental" if incremental else "Manual full"
	if bool(p_settings.get("bake_failed", false)):
		return "%s SVT bake failed: %s" % [mode, str(p_settings.get("bake_error", "unknown error"))]
	var total := int(p_settings.get("bake_total", 0))
	var done := int(p_settings.get("bake_done", 0))
	var pending := int(p_settings.get("bake_pending", 0))
	if pending > 0 or total > 0 or done > 0:
		var state := "complete" if total > 0 and done >= total and pending == 0 else "progress"
		var queued := " · %d changed regions queued" % regions if auto_enabled and incremental and regions > 0 else ""
		return "%s SVT bake %s: %d/%d pages, %d pending%s" % [mode, state, done, total, pending, queued]
	if auto_enabled and regions > 0:
		return "Auto Bake: %d changed region(s) queued; updates merge after 500 ms without edits." % regions
	if auto_enabled:
		return "Auto Bake on · changed SVT cells rebake incrementally 500 ms after editing stops."
	return "Auto Bake off · use Bake All SVT Cells for a full persisted bake."


static func region_locations(p_data: Object) -> Array:
	var value := call_method(p_data, "get_region_locations")
	if typeof(value) != TYPE_ARRAY:
		return []
	var result: Array = []
	for location in value:
		result.append(Vector2i(location))
	return result


static func is_valid_image(p_value: Variant) -> bool:
	return p_value is Image and not p_value.is_empty() and p_value.get_width() > 0 and p_value.get_height() > 0
