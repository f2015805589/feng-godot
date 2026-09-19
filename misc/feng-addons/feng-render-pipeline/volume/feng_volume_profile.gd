@tool
class_name FengVolumeProfile
extends Resource
## Selected FRP modules. A pass author defines the Volume field list in code;
## this resource stores only values for those fields, never exposure permissions.
## Runtime filtering uses the current renderer's declarations, including for legacy
## dictionary profiles, so stale or hidden fields cannot bypass the pass contract.
## Add modules from the pipeline in the Inspector. The pass code owns their fields.
@export var modules: Array[FengVolumeModule] = []:
	set(value):
		for module in modules:
			if module != null and module.changed.is_connected(_on_module_changed):
				module.changed.disconnect(_on_module_changed)
		modules = value
		for module in modules:
			if module != null and not module.changed.is_connected(_on_module_changed):
				module.changed.connect(_on_module_changed)
		emit_changed()

func _on_module_changed() -> void:
	emit_changed()

func evaluation_key() -> Array:
	var key: Array = [get_instance_id(), pass_parameters.hash(), enabled_passes.hash(), disabled_passes.hash()]
	for module in modules:
		key.append(module.evaluation_key() if module != null else null)
	return key

## Compatibility storage for existing profiles. New profiles use typed modules.
@export_storage var pass_parameters: Dictionary = {}

func get_parameters() -> Dictionary:
	var result := pass_parameters.duplicate(true)
	for module in modules:
		if module == null or module.pass_source == null:
			continue
		var key: Variant = module.get_parameter_key()
		var parameters: Dictionary = result.get(key, {})
		parameters.merge(module.get_parameters(), true)
		result[key] = parameters
	return result

## Passes this volume switches on, and passes it switches off, by native pass id.
##
## This is how an effect is turned on for one area without editing the pass
## resources: the entry keeps its authored state, the volume overrides it while the
## camera is inside, and the schedule (and the engine's provided pass set) follows, so
## a pass that is off by default can run inside the volume and a pass that is on can be
## skipped there.
##
## A pass state cannot be interpolated: a volume applies it once its influence is at
## least half, and `enabled_passes` wins over `disabled_passes` at the same priority.
## A mandatory pass (see the pipeline spec) cannot be switched off this way; the
## renderer reports the incomplete schedule instead.
@export_storage var enabled_passes: Array[int] = []
@export_storage var disabled_passes: Array[int] = []
