@tool
class_name FengMagicGIDebugRequest
extends RefCounted
## Lets Magic GI publish its final apply sidecar while Debug Buffers requests it.

static var _debug_passes: Dictionary = {}
static var _target_passes: Dictionary = {}

static func register_debug_pass(pass_resource: Object) -> void:
	if pass_resource == null or not is_instance_valid(pass_resource):
		return
	var pass_id := pass_resource.get_instance_id()
	if int(pass_resource.get("buffer")) == 6:
		_debug_passes[pass_id] = weakref(pass_resource)
	else:
		_debug_passes.erase(pass_id)
		for target_id_value in _target_passes.keys():
			var target_id := int(target_id_value)
			if int(_target_passes[target_id]) == pass_id:
				_target_passes.erase(target_id)

static func set_target_request(target_id: int, pass_resource: Object, requested: bool) -> void:
	if target_id <= 0 or pass_resource == null or not is_instance_valid(pass_resource):
		return
	var pass_id := pass_resource.get_instance_id()
	if requested:
		_target_passes[target_id] = pass_id
	else:
		_target_passes.erase(target_id)

static func is_requested(target_id: int) -> bool:
	if target_id > 0 and _target_passes.has(target_id):
		var target_pass_id := int(_target_passes[target_id])
		if _is_active_debug_pass(target_pass_id):
			return true
		_target_passes.erase(target_id)
	# This live owner check is also the zero-black-frame bootstrap before the
	# Debug Buffers pass has recorded its first render target.
	for pass_id_value in _debug_passes.keys():
		if _is_active_debug_pass(int(pass_id_value)):
			return true
	return false

static func _is_active_debug_pass(pass_id: int) -> bool:
	if not _debug_passes.has(pass_id):
		return false
	var reference: WeakRef = _debug_passes[pass_id]
	var pass_resource: Object = reference.get_ref()
	if pass_resource == null or not is_instance_valid(pass_resource):
		_debug_passes.erase(pass_id)
		return false
	return int(pass_resource.get("buffer")) == 6 \
			and bool(pass_resource.call("is_enabled"))
