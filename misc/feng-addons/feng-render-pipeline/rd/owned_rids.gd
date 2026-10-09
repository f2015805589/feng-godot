@tool
extends RefCounted


static func append(target: Array[RID], seen: Dictionary, rid: RID) -> void:
	if rid.is_valid() and not seen.has(rid):
		seen[rid] = true
		target.append(rid)


static func append_all(target: Array[RID], seen: Dictionary, rids: Array) -> void:
	for value in rids:
		if value is RID:
			append(target, seen, value)
