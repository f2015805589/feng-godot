@tool
extends RefCounted
## Texture resources keep their allocation alive even if their source asset is released.
var decoder: RefCounted
var pages := RID()
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and decoder != null:
		preload("runtime.gd").retire.call_deferred(decoder,pages)
