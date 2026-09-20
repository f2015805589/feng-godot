@tool
class_name FengVolumeModule
extends Resource
## One selected pass module. Its field list is defined exclusively by pass code.

## Legacy storage: when the pass declares enabled, false disables the effect.
## New UI exposes only fields declared by the pass. Remove a module to stop
## overriding it and return to pipeline settings.
@export_storage var enabled := true
@export_storage var pass_source: FengPass:
	set(value):
		if pass_source != null and pass_source.changed.is_connected(_on_source_changed):
			pass_source.changed.disconnect(_on_source_changed)
		pass_source = value
		if pass_source != null:
			pass_source.changed.connect(_on_source_changed)
		_source_revision += 1
		notify_property_list_changed()
		emit_changed()
@export_storage var values: Dictionary = {}
## Empty preserves existing profiles: every declared field overrides by default.
@export_storage var disabled_overrides: PackedStringArray = []:
	set(value):
		disabled_overrides = value
		emit_changed()
var _source_revision := 0
var _parameters_key: Array = []
var _parameters_cache: Dictionary = {}

func _on_source_changed() -> void:
	_source_revision += 1
	emit_changed()

## Small change key, including in-place edits to the compatibility dictionary.
func evaluation_key() -> Array:
	return [get_instance_id(), enabled, values.hash(), _source_revision, disabled_overrides]

static func from_pass(source: FengPass, authored: Dictionary = {}) -> FengVolumeModule:
	var module := FengVolumeModule.new()
	module.pass_source = source
	module.resource_name = source.resource_name if source.resource_name != "" else str(source.get_parameter_key())
	var defaults := source.get_frp_parameters()
	defaults.merge(authored, true)
	for info in source.get_volume_parameter_list():
		module.values[String(info.name)] = defaults[String(info.name)]
	return module

func get_parameter_key() -> Variant:
	return pass_source.get_parameter_key() if pass_source != null else null

func get_parameters() -> Dictionary:
	var key := evaluation_key()
	if key != _parameters_key:
		_parameters_cache = _collect_parameters()
		_parameters_key = key
	# Public snapshots remain isolated, including nested dictionary/array values.
	return _parameters_cache.duplicate(true)

func _collect_parameters() -> Dictionary:
	var result := {}
	if pass_source == null:
		return result
	var defaults := pass_source.get_frp_parameters()
	if not enabled and not pass_source.get_volume_parameter_names().has("enabled"):
		return result
	for info in pass_source.get_volume_parameter_list():
		var key := String(info.name)
		if disabled_overrides.has(key):
			continue
		var fallback: Variant = false if key == "enabled" and not enabled else defaults[key]
		result[key] = values.get(key, fallback)
	return result

func _get_property_list() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if pass_source == null:
		return result
	for info in pass_source.get_volume_parameter_list():
		result.append({"name": "overrides/" + String(info.name), "type": TYPE_BOOL, "usage": PROPERTY_USAGE_EDITOR})
		var property := info.duplicate()
		property.name = "parameters/" + String(info.name)
		# Values are serialized in one dictionary, fields are editor-only views.
		property.usage = PROPERTY_USAGE_EDITOR
		result.append(property)
	return result

func _get(property: StringName) -> Variant:
	var path := String(property)
	if path.begins_with("overrides/") and pass_source != null:
		return not disabled_overrides.has(path.trim_prefix("overrides/"))
	if path.begins_with("parameters/") and pass_source != null:
		var key := path.trim_prefix("parameters/")
		if key == "enabled":
			return values.get(key, false if not enabled else pass_source.get_frp_parameters().get(key))
		return values.get(key, pass_source.get_frp_parameters().get(key))
	return null

func _set(property: StringName, value: Variant) -> bool:
	var path := String(property)
	if path.begins_with("overrides/") and pass_source != null:
		var field := path.trim_prefix("overrides/")
		for info in pass_source.get_volume_parameter_list():
			if String(info.name) == field:
				var excluded := disabled_overrides.duplicate()
				var index := excluded.find(field)
				if bool(value) and index >= 0:
					excluded.remove_at(index)
				elif not bool(value) and index < 0:
					excluded.append(field)
				disabled_overrides = excluded
				return true
		return false
	if not path.begins_with("parameters/") or pass_source == null:
		return false
	var key := path.trim_prefix("parameters/")
	for info in pass_source.get_volume_parameter_list():
		if String(info.name) == key:
			values[key] = value
			emit_changed()
			return true
	return false
